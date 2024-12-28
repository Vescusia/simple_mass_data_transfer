const std = @import("std");
const chacha = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

const msgio = @import("msgio.zig");


const ad: [0]u8 = undefined;


/// It is absolutely crucial that both Writer and Reader have the same `max_msg_len`.
/// Otherwise, behavior is undefined!
pub fn EncryptedWriter(comptime max_msg_len: usize, comptime WriterT: type) type {
    const MsgSizeT = SmallestInt(max_msg_len);
    const MsgWriterT = msgio.MessageWriter(MsgSizeT, WriterT);

    const rand = std.crypto.random;

    return struct {
        msgwriter: MsgWriterT,
        buf: []u8,
        alloc: std.mem.Allocator,
        key: [chacha.key_length] u8,

        const Self = @This();

        /// Call `deinit` to free memory
        pub fn withSize(alloc: std.mem.Allocator, writer: WriterT, key: []const u8, buffersize: usize) !Self {
            const self = .{
                .msgwriter = try MsgWriterT.init(writer),
                .buf = try alloc.alloc(u8, buffersize),
                .alloc = alloc,
                .key = padKey(key),
            };

            return self;
        }

        /// Call `deinit` to free memory
        pub fn init(alloc: std.mem.Allocator, writer: WriterT, key: []const u8) !Self {
            return Self.withSize(alloc, writer, key, 1 << 10);
        }

        pub fn deinit(self: Self) void {
            self.alloc.free(self.buf);
        }

        pub fn writeMessage(self: *Self, content: []const u8) !void {
            // generate nonce
            var nonce: [chacha.nonce_length]u8 = undefined;
            rand.bytes(&nonce);

            // tag (will get filled by encrypt)
            var tag: [chacha.tag_length]u8 = undefined;

            // ensure that buffer is big enough
            if (self.buf.len < content.len) {
                self.buf = try self.alloc.realloc(self.buf, content.len * 2);
            }

            // ensure that message fits into msg_size_t
            std.debug.assert(nonce.len + tag.len + content.len < max_msg_len);

            // encrypt into self.buf
            chacha.encrypt(self.buf[0..content.len], &tag, content, &ad, nonce, self.key);

            // write
            const parts = [_][]const u8 {
                &nonce,
                &tag,
                self.buf[0..content.len]
            };
            try self.msgwriter.writeMultiple(self.alloc, &parts);
        }
    };
}


pub fn EncryptedReader(comptime max_msg_len: usize, comptime ReaderT: type) type {
    const MsgSizeT = SmallestInt(max_msg_len);
    const msgreader_t = msgio.MessageReader(MsgSizeT, ReaderT);

    return struct {
        msgreader: msgreader_t,
        key: [chacha.key_length] u8,
        alloc: std.mem.Allocator,
        buf: []u8,

        const Self = @This();

        /// Call `deinit` to free memory
        pub fn withSize(alloc: std.mem.Allocator, reader: ReaderT, key: []const u8, buffersize: usize) !Self {
            const self = .{
                .msgreader = try msgreader_t.withSize(alloc, reader, buffersize),
                .key = padKey(key),
                .alloc = alloc,
                .buf = try alloc.alloc(u8, buffersize),
            };

            return self;
        }

        /// Call `deinit` to free memory
        pub fn init(alloc: std.mem.Allocator, reader: ReaderT, key: []const u8) !Self {
            return Self.withSize(alloc, reader, key, 1 << 10);
        }

        pub fn deinit(self: Self) void {
            self.msgreader.deinit();
            self.alloc.free(self.buf);
        }

        /// **Returned slice will be valid until this function is called again.**
        pub fn readMessage(self: *Self) !?[]u8 {
            // get whole message
            const everything = blk: {
                const everything_opt = try self.msgreader.readMessage();
                if (everything_opt == null) {
                    return null;
                }
                break :blk everything_opt.?;
            };

            // extract nonce
            const nonce = everything[0..chacha.nonce_length];

            // extract tag
            const tag = everything[nonce.len..nonce.len + chacha.tag_length];

            // ensure that there is enough space in our buffer
            if (self.buf.len < everything.len) {
                self.buf = try self.alloc.realloc(self.buf, everything.len * 2);
            }

            // decrypt
            const crypted = everything[nonce.len + tag.len..];
            try chacha.decrypt(self.buf[0..crypted.len], crypted, tag.*, &ad, nonce.*, self.key);

            return self.buf[0..crypted.len];
        }
    };
}


/// Calculate the smallest integer that can represent the `max_size` and is a multiple of 8 (bits)
fn SmallestInt(comptime max_size: usize) type {
    const bits = @as(u16, @floor(@log2(@as(f64, max_size))));
    return @Type(.{ .Int = .{ .signedness = .unsigned, .bits = bits + 8 - bits % 8 } });  // needs to be a multiple of 8
}

test "basic_smallest_int" {
    const max_size = 1027;
    try std.testing.expect(SmallestInt(max_size) == u16);
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
