const std = @import("std");
const chacha = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

const msgio = @import("msgio.zig");


const ad: [0]u8 = undefined;


/// Creates a XChaCha20Poly1305 encrypted File from an underlying File.
///
/// It is absolutely crucial that both communicating Partners use the same `max_msg_len`!.
/// Otherwise Communication will not be possible.
///
/// * `max_msg_len`: the maximum length (in bytes) of the sent messages;
/// it is UB if these boundaries are exceeded!
/// Also, this directly controls the length of the Cipher Buffers (on Stack), so it should be kept somewhat small.
/// (but big enough to not get overly many `writeMessage`/`readMessage` calls, along their overhead)
/// * `file`: the underlying IO object; must have `.reader()` and `.writer()` implemented.
/// * `key`: does not need to be padded, will be done internally
pub fn EncryptedIO(max_msg_len: usize, FileT: type, key: []const u8) type {
    // construct the type of the underlying Writer and Reader
    const WriterT = @typeInfo(@TypeOf(FileT.writer)).Fn.return_type.?;
    const ReaderT = @typeInfo(@TypeOf(FileT.reader)).Fn.return_type.?;

    // construct the type of the encrypted Writer and Reader
    const EncryptedWriterT = EncryptedWriter(max_msg_len, WriterT);
    const EncryptedReaderT = EncryptedReader(max_msg_len, ReaderT);

    std.debug.assert(EncryptedWriterT.MsgSizeT == EncryptedReaderT.MsgSizeT);

    return struct {
        pub const MsgSizeT = EncryptedWriterT.MsgSizeT;

        pub fn writer(underlying_writer: WriterT) EncryptedWriterT {
            return EncryptedWriterT.init(underlying_writer, key);
        }

        /// Caller has to `.deinit()` to deallocate the memory
        pub fn reader(alloc: std.mem.Allocator, underlying_reader: ReaderT) !EncryptedReaderT {
            return EncryptedReaderT.init(alloc, underlying_reader, key);
        }
    };
}


/// It is absolutely crucial that both Writer and Reader have the same `max_msg_len`.
/// Otherwise, behavior is undefined!
pub fn EncryptedWriter(max_msg_len: usize, WriterT: type) type {
    return struct {
        msgwriter: MsgWriterT,
        key: [chacha.key_length] u8,
        buf: [total_max_msg_len]u8,

        pub const total_max_msg_len = chacha.nonce_length + chacha.tag_length + max_msg_len;

        pub const MsgSizeT = SmallestInt(total_max_msg_len + chacha.nonce_length + chacha.tag_length);
        const MsgWriterT = msgio.MessageWriter(MsgSizeT, WriterT);

        const rand = std.crypto.random;

        const Self = @This();

        pub fn init(writer: WriterT, key: []const u8) Self {
            return .{
                .msgwriter = msgio.MessageWriter(MsgSizeT, WriterT).init(writer),
                .key = padKey(key),
                .buf = std.mem.zeroes([total_max_msg_len]u8),
            };
        }

        /// Write an encrypted Message
        ///
        /// All memory allocated with `alloc` will be freed before this method returns.
        pub fn writeMessage(self: *Self, content: []const u8) !void {
            // generate nonce
            var nonce: [chacha.nonce_length]u8 = undefined;
            rand.bytes(&nonce);

            // tag (will get filled by encrypt)
            var tag: [chacha.tag_length]u8 = undefined;

            // ensure that message fits into buffer (and msg_size_t)
            std.debug.assert(nonce.len + tag.len + content.len <= total_max_msg_len);

            // encrypt into self.buf
            chacha.encrypt(self.buf[0..content.len], &tag, content, &ad, nonce, self.key);

            // write
            const parts = [_][]const u8 {
                &nonce,
                &tag,
                self.buf[0..content.len]
            };
            try self.msgwriter.writeMultiple(parts.len, parts);
        }
    };
}


/// It is absolutely crucial that both Writer and Reader have the same `max_msg_len`.
/// Otherwise, behavior is undefined!
pub fn EncryptedReader(max_msg_len: usize, ReaderT: type) type {
    return struct {
        msgreader: MsgReaderT,
        key: [chacha.key_length] u8,
        buf: [total_max_msg_len]u8,

        pub const total_max_msg_len = chacha.nonce_length + chacha.tag_length + max_msg_len;

        const MsgReaderT = msgio.MessageReader(MsgSizeT, ReaderT);
        pub const MsgSizeT = SmallestInt(total_max_msg_len + chacha.nonce_length + chacha.tag_length);

        const Self = @This();

        /// Call `deinit` to free memory
        pub fn init(alloc: std.mem.Allocator, reader: ReaderT, key: []const u8) !Self {
            return .{
                .msgreader = try msgio.MessageReader(MsgSizeT, ReaderT).withSize(alloc, reader, total_max_msg_len),
                .key = padKey(key),
                .buf = undefined,
            };
        }

        pub fn deinit(self: Self) void {
            self.msgreader.deinit();
        }

        /// **Returned slice will be valid until this function is called again.**
        pub fn readMessage(self: *Self) !?[]u8 {
            // get whole message
            const everything = try self.msgreader.readMessage() orelse return null;

            // ensure that message fits into buffer
            std.debug.assert(everything.len <= total_max_msg_len);

            // extract nonce
            const nonce = everything[0..chacha.nonce_length];

            // extract tag
            const tag = everything[nonce.len..nonce.len + chacha.tag_length];

            // extract encrypted data
            const crypted = everything[nonce.len + tag.len..];

            // decrypt
            try chacha.decrypt(self.buf[0..crypted.len], crypted, tag.*, &ad, nonce.*, self.key);

            return self.buf[0..crypted.len];
        }
    };
}


/// Calculate the smallest Integer Type that can represent the `max_size` and is a multiple of 8 (bits)
fn SmallestInt(comptime max_size: usize) type {
    const bits = @as(u16, @floor(@log2(@as(f64, max_size))));
    return @Type(.{ .Int = .{ .signedness = .unsigned, .bits = bits + 8 - bits % 8 } });  // needs to be a multiple of 8
}

test "basic_smallest_int" {
    try std.testing.expect(SmallestInt(1027) == u16);
    try std.testing.expect(SmallestInt(256) == u16);
    try std.testing.expect(SmallestInt(255) == u8);
}


pub fn padKey(key: []const u8) [chacha.key_length]u8 {
    var padded_key: [chacha.key_length]u8 = undefined;

    var i: usize = 0;
    while (i < padded_key.len) {
        const copy_amount = @min(padded_key.len - i, key.len);
        @memcpy(padded_key[i..i+copy_amount], key[0..copy_amount]);
        i += copy_amount;
    }

    return padded_key;
}

test "pad_key" {
    const text = "ZATY";
    const padded = padKey(text);
    try std.testing.expect(std.mem.eql(u8, &padded, "ZATYZATYZATYZATYZATYZATYZATYZATYZATYZATYZATYZATY"[0..chacha.key_length]));
}


test {
    _ = EncryptedWriter;
}
