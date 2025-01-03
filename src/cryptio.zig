const std = @import("std");

const chacha = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

const msgio = @import("msgio.zig");


const ad: [0]u8 = undefined;


pub fn EncryptedMessageReader(ReaderT: type, max_msg_size: u64, raw_key: []const u8) type {
    const MsgSizeT = SmallestInt(max_msg_size);
    const msg_size_size = @sizeOf(MsgSizeT);

    const block_header_size = chacha.nonce_length + chacha.tag_length + msg_size_size;

    const padded_key = padKey(raw_key);

    return struct {
        block_buf: [block_header_size + msg_size_size + max_msg_size]u8 = undefined,
        block_end: MsgSizeT = undefined,
        block_read: usize = 0,
        content_buf: [(max_msg_size + msg_size_size) * 2]u8 = undefined,
        content_end: usize = 0,
        content_start: usize = 0,
        reader: ReaderT,

        const Self = @This();

        pub fn init(reader: ReaderT) Self {
            return Self {
                .reader = reader,
            };
        }

        /// Reads a new block into the block buffer,
        /// decrypts it into the second half of the content buffer,
        /// after shifting the already present content directly in front of it,
        /// into the first half such that the content remains contiguous
        fn refillContentBuf(self: *Self) !?void {
            // copy first part of message to into first half of content buffer
            @memcpy(self.content_buf[max_msg_size - self.contentLeft()..max_msg_size], self.content_buf[self.content_start..self.content_end]);
            self.content_start = max_msg_size - self.contentLeft();

            // read new block into block buffer
            try self.readBlock() orelse return null;

            // decrypt it into second half of content buffer
            try self.decryptBlock();
        }

        /// Will completely renew current block state
        fn readBlock(self: *Self) !?void {
            // handle block overreading of previous call and reset self.block_read
            if (self.block_read > self.block_end) {
                std.mem.copyForwards(u8,
                    self.block_buf[0..self.block_read - self.block_end],
                    self.block_buf[self.block_end..self.block_read]
                );
                self.block_read -= self.block_end;
            }
            else {
                self.block_read = 0;
            }

            // read the block crypto header into buffer
            while (self.block_read < block_header_size) {
                const new_read = try self.reader.read(self.block_buf[self.block_read..]);
                if (new_read == 0) {
                    return null;
                }
                self.block_read += new_read;
            }

            // read the block size
            const raw_block_size = std.mem.bytesToValue(MsgSizeT, self.block_buf[0..msg_size_size]);
            self.block_end = std.mem.bigToNative(MsgSizeT, raw_block_size) + block_header_size;
            std.debug.assert(self.block_end <= self.block_buf.len);

            // fill up block buffer
            while (self.block_read < self.block_end) {
                const new_read = try self.reader.read(self.block_buf[self.block_read..]);
                if (new_read == 0) {
                    return null;
                }
                self.block_read += new_read;
            }
        }

        /// Decrypts block buffer into second half of content buffer
        fn decryptBlock(self: *Self) !void {
            const nonce = self.block_buf[msg_size_size..msg_size_size + chacha.nonce_length];
            const tag = self.block_buf[msg_size_size + chacha.nonce_length..block_header_size];
            const crypted = self.block_buf[block_header_size..self.block_end];

            self.content_end = max_msg_size + self.block_end - block_header_size;

            try chacha.decrypt(
                self.content_buf[max_msg_size..self.content_end],
                crypted,
                tag.*,
                &ad,
                nonce.*,
                padded_key
            );
        }

        fn contentLeft(self: Self) usize {
            return self.content_end - self.content_start;
        }

        /// Reads a message from the encrypted underlying reader.
        pub fn readMessage(self: *Self) !?[]u8 {
            // fill content buffer if it's basically empty
            while (self.contentLeft() < msg_size_size) {
                try self.refillContentBuf() orelse return null;
            }

            // extract message size
            const msg_size = std.mem.bigToNative(MsgSizeT, std.mem.bytesToValue(MsgSizeT, self.content_buf[self.content_start..self.content_start + msg_size_size]));
            self.content_start += msg_size_size;

            //std.debug.print("MsgSizeReceived: {d}\n", .{msg_size});
            std.debug.assert(msg_size <= max_msg_size);

            // refill the content buffer if we do not have enough content
            while (msg_size > self.contentLeft()) {
                try self.refillContentBuf() orelse return null;
            }

            // extract message
            const message = self.content_buf[self.content_start..self.content_start + msg_size];
            self.content_start += msg_size;

            return message;
        }
    };
}


pub fn EncryptedMessageWriter(WriterT: type, max_msg_size: u64, raw_key: []const u8) type {
    const MsgSizeT = SmallestInt(max_msg_size);
    const msg_size_size = @sizeOf(MsgSizeT);

    const padded_key = padKey(raw_key);

    // integer type with nonce length size
    const NonceIntT = @Type(.{
        .Int = .{ .signedness = .unsigned, .bits = chacha.nonce_length * 8 }
    });

    const block_header_size = chacha.nonce_length + chacha.tag_length + msg_size_size;

    return struct {
        block_buf: [block_header_size + msg_size_size + max_msg_size]u8 = undefined,
        write_buf: [msg_size_size + max_msg_size]u8 = undefined,
        start: usize = 0,
        nonce: [chacha.nonce_length]u8,
        writer: WriterT,

        const Self = @This();

        pub fn init(writer: WriterT) Self {
            var nonce: [chacha.nonce_length]u8 = undefined;
            std.crypto.random.bytes(&nonce);

            return .{
                .nonce = nonce,
                .writer = writer
            };
        }

        /// Write a message into the buffer
        pub fn writeMessage(self: *Self, content: []const u8) !void {
            std.debug.assert(content.len <= max_msg_size);

            // flush the buffer if full
            if (self.bufSpaceLeft() < msg_size_size + content.len) {
                try self.flush();
            }

            // add message size
            const msg_size = std.mem.asBytes(&std.mem.nativeToBig(MsgSizeT, @truncate(content.len)));
            @memcpy(self.write_buf[self.start..self.start + msg_size_size], msg_size);
            self.start += msg_size_size;

            // copy in content
            @memcpy(self.write_buf[self.start..self.start + content.len], content);
            self.start += content.len;
        }

        pub fn bufSpaceLeft(self: Self) usize {
            return self.write_buf.len - self.start;
        }

        /// Flush the buffer,
        /// writing the encrpyted messages upon the underlying writer
        pub fn flush(self: *Self) !void {
            try self.directWriteMessage(self.write_buf[0..self.start]);
            self.start = 0;
        }

        /// Directly write and encrypt a message, instantly flushing it.
        ///
        /// This will be more performant than calling `writeMessage` and then `flush`.
        pub fn directWriteMessage(self: *Self, content: []const u8) !void {
            // copy in nonce
            @memcpy(self.block_buf[msg_size_size..msg_size_size + chacha.nonce_length], &self.nonce);
            defer std.mem.bytesAsValue(NonceIntT, &self.nonce).* +%= 1;

            // copy in block size
            @memcpy(
                self.block_buf[0..msg_size_size],
                std.mem.asBytes(&std.mem.nativeToBig(MsgSizeT, @truncate(content.len)))
            );

            // calculate tag
            var tag: [chacha.tag_length]u8 = undefined;

            // encrypt in content
            chacha.encrypt(
                self.block_buf[block_header_size..content.len + block_header_size],
                &tag,
                content,
                &ad,
                self.nonce,
                padded_key
            );

            // copy in tag
            @memcpy(self.block_buf[msg_size_size + chacha.nonce_length..block_header_size], &tag);

            // write complete block buffer
            const total_block_size = block_header_size + content.len;
            var amt_written: usize = 0;
            while (amt_written < total_block_size) {
                const new_written = try self.writer.write(self.block_buf[amt_written..total_block_size]);
                amt_written += new_written;
            }
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
