const std = @import("std");
const native_endian = @import("builtin").cpu.arch.endian();

const chacha = std.crypto.aead.chacha_poly.XChaCha20Poly1305;


const ad: [0]u8 = undefined;


pub fn EncryptedIO(maximum_message_size: usize) type {
    return struct {
        /// The maximum size a message may be
        pub const max_msg_size = maximum_message_size;

        const MsgSizeT = SmallestInt(max_msg_size);
        const msg_size_size = @sizeOf(MsgSizeT);

        /// The maximum size a block may be.
        /// A block in this case being `max_msg_size` plus the size of the length prefix for the messages
        pub const max_block_size = msg_size_size + max_msg_size;


        pub fn EncryptedReader(ReaderT: type, raw_key: []const u8) type {
            const block_header_size = msg_size_size + chacha.tag_length;

            const padded_key = padKey(raw_key);

            return struct {
                block_buf: [block_header_size + max_block_size]u8 = undefined,
                block_end: MsgSizeT = undefined,
                block_read: usize = 0,
                content_buf: [max_block_size * 2]u8 = undefined,
                content_end: usize = 0,
                content_start: usize = 0,
                reader: ReaderT,
                nonce: [chacha.nonce_length]u8,

                const Self = @This();

                /// Will instantly read the initial nonce from the reader.
                /// Make sure that every reader `.init` matches exactly one writer `.init`.
                ///
                /// Returns `null`, when the reader reaches EOF before the initial nonce could be read.
                pub fn init(reader: ReaderT) !?Self {
                    // read initial nonce
                    var nonce: [chacha.nonce_length]u8 = undefined;
                    if (try reader.readAll(&nonce) < nonce.len) {
                        return null;
                    }

                    return Self {
                        .reader = reader,
                        .nonce = nonce
                    };
                }

                /// Reads and decrypts a block of arbitrary size into the `content_buf`.
                /// Asserts that `self.validContentLeft() < max_block_size` i.e.
                /// do not call this method if there is, by definition, still enough content left.
                fn readBlock(self: *Self) !?void {
                    // copy old content into first half of content buffer
                    @memcpy(
                        self.content_buf[max_block_size - self.validContentLeft()..max_block_size],
                        self.content_buf[self.content_start..self.content_end]
                    );
                    self.content_start = max_block_size - self.validContentLeft();

                    // read and decrypt a new block into the content buffer
                    const amt_read = try self.readBlockToBuf(self.content_buf[max_block_size..]) orelse return null;
                    self.content_end = max_block_size + amt_read;
                }

                /// Will read a block (encrypted bytes with a length prefix) from the reader and decrypt it into buf.
                /// Returns the amount of bytes written to `buf`
                ///
                /// Asserts that `buf.len >= max_block_size`
                pub fn readBlockToBuf(self: *Self, buf: []u8) !?usize {
                    std.debug.assert(buf.len >= max_block_size);

                    // handle block overreading of previous call and reset self.block_read
                    if (self.block_read > self.block_end) {
                        std.debug.print("Block overreading!\n", .{});
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

                    if (self.block_end < block_header_size + max_block_size) {
                        std.debug.print("Read {} of maximum {} B Block\n", .{ self.block_end - block_header_size, max_block_size});
                    }

                    // fill up block buffer
                    while (self.block_read < self.block_end) {
                        const new_read = try self.reader.read(self.block_buf[self.block_read..]);
                        if (new_read == 0) {
                            return null;
                        }
                        self.block_read += new_read;
                    }

                    // increment nonce
                    defer incrementNonce(&self.nonce);

                    // read tag and cypher text
                    const tag = self.block_buf[msg_size_size..block_header_size];
                    const crypted = self.block_buf[block_header_size..self.block_end];

                    // decrypt
                    const content_amt = self.block_end - block_header_size;
                    try chacha.decrypt(
                        buf[0..content_amt],
                        crypted,
                        tag.*,
                        &ad,
                        self.nonce,
                        padded_key
                    );

                    return content_amt;
                }

                /// Amount of valid content bytes in the `content_buf`
                fn validContentLeft(self: Self) usize {
                    return self.content_end - self.content_start;
                }

                /// Ensure that at least `space` valid bytes are in `self.content_buf`
                fn ensureContent(self: *Self, space: usize) !?void {
                    while (self.validContentLeft() < space) {
                        try self.readBlock() orelse return null;
                    }
                }

                /// Reads a message from the encrypted underlying reader.
                pub fn readMessage(self: *Self) !?[]const u8 {
                    // fill content buffer if it's basically empty
                    try self.ensureContent(msg_size_size) orelse return null;

                    // extract message size
                    const msg_size = std.mem.bigToNative(MsgSizeT, std.mem.bytesToValue(MsgSizeT, self.content_buf[self.content_start..self.content_start + msg_size_size]));
                    self.content_start += msg_size_size;

                    std.debug.assert(msg_size <= max_msg_size);

                    // refill the content buffer if we do not have enough content
                    try self.ensureContent(msg_size) orelse return null;
                    defer self.content_start += msg_size;

                    // extract message
                    const message = self.content_buf[self.content_start..self.content_start + msg_size];

                    return message;
                }

                /// Reads a raw integer from the buffer.
                ///
                /// See `EncryptedWriter.putInt`
                pub fn readInt(self: *Self, IntT: type) !?IntT {
                    std.debug.assert(IntT != usize);

                    try self.ensureContent(@sizeOf(IntT)) orelse return null;
                    defer self.content_start += @sizeOf(IntT);

                    const int_bytes = self.content_buf[self.content_start..self.content_start + @sizeOf(IntT)];

                    return std.mem.bigToNative(IntT, std.mem.bytesToValue(IntT, int_bytes));
                }
            };
        }


        pub fn EncryptedWriter(WriterT: type, raw_key: []const u8) type {
            const padded_key = padKey(raw_key);

            const block_header_size = msg_size_size + chacha.tag_length;

            return struct {
                block_buf: [block_header_size + max_block_size]u8 = undefined,
                write_buf: [max_block_size]u8 = undefined,
                start: usize = 0,
                nonce: [chacha.nonce_length]u8,
                writer: WriterT,

                const Self = @This();

                /// Will instantly write the initial nonce to the writer.
                /// Make sure that every writer `.init` matches exactly one reader `.init`.
                pub fn init(writer: WriterT) !Self {
                    // generate initial nonce
                    var nonce: [chacha.nonce_length]u8 = undefined;
                    std.crypto.random.bytes(&nonce);

                    // send initial nonce
                    try writer.writeAll(&nonce);

                    return .{
                        .nonce = nonce,
                        .writer = writer
                    };
                }

                /// Write a message into the write buffer
                ///
                /// Call `flush` to flush the messages upon the writer.
                pub fn writeMessage(self: *Self, content: []const u8) !void {
                    std.debug.assert(content.len <= max_msg_size);

                    // flush the buffer if full
                    try self.ensureSpace(msg_size_size);

                    // add message size
                    const msg_size = std.mem.asBytes(&std.mem.nativeToBig(MsgSizeT, @truncate(content.len)));
                    @memcpy(self.write_buf[self.start..self.start + msg_size_size], msg_size);
                    self.start += msg_size_size;

                    // copy in content
                    const buf_space_left = self.bufSpaceLeft();
                    if (buf_space_left < content.len) {
                        // if it does not wholely fit copy in first part
                        @memcpy(self.write_buf[self.start..max_block_size], content[0..buf_space_left]);
                        // flush
                        try self.flush();
                        // and copy in second part
                        // to try to call .flush only on full write buffers
                        @memcpy(self.write_buf[0..content.len - buf_space_left], content[buf_space_left..]);

                        std.debug.print("Partial message write\n", .{});
                        self.start += content.len - buf_space_left;
                    }
                    else {
                        @memcpy(self.write_buf[self.start..self.start + content.len], content);
                        self.start += content.len;
                    }
                }

                pub fn bufSpaceLeft(self: Self) usize {
                    return self.write_buf.len - self.start;
                }

                /// Encrypt `buf`, writing it's block
                /// (i.e. the encrypted bytes with a length prefix) to the writer
                ///
                /// This is the more direct version of `flush`, seperate from the buffered message API
                /// and has to be matched, on the message reader side with, `readBlockToBuf`
                ///
                /// Asserts that `buf.len <= max_block_size`
                pub fn writeBufToBlock(self: *Self, buf: []const u8) !void {
                    std.debug.assert(buf.len <= max_block_size);

                    if (buf.len < max_block_size) {
                        std.debug.print("flushing {} of maximum {} B\n", .{ buf.len, max_block_size });
                    }

                    // increment nonce
                    defer incrementNonce(&self.nonce);

                    // copy in block size
                    @memcpy(
                        self.block_buf[0..msg_size_size],
                        std.mem.asBytes(&std.mem.nativeToBig(MsgSizeT, @truncate(buf.len)))
                    );

                    // calculate tag
                    var tag: [chacha.tag_length]u8 = undefined;

                    // encrypt in content
                    chacha.encrypt(
                        self.block_buf[block_header_size..buf.len + block_header_size],
                        &tag,
                        buf,
                        &ad,
                        self.nonce,
                        padded_key
                    );

                    // copy in tag
                    @memcpy(
                        self.block_buf[msg_size_size..block_header_size],
                        &tag
                    );

                    // write complete block buffer
                    const total_block_size = block_header_size + buf.len;
                    var amt_written: usize = 0;
                    while (amt_written < total_block_size) {
                        const new_written = try self.writer.write(self.block_buf[amt_written..total_block_size]);
                        amt_written += new_written;
                    }
                }

                pub fn flush(self: *Self) !void {
                    defer self.start = 0;
                    return self.writeBufToBlock(self.write_buf[0..self.start]);
                }

                /// Write a message and instantly flush it.
                pub fn directWriteMessage(self: *Self, content: []const u8) !void {
                    try self.writeMessage(content);
                    return self.flush();
                }

                /// Ensure that at least `space` free bytes are in `self.write_buf`
                fn ensureSpace(self: *Self, space: usize) !void {
                    if (self.bufSpaceLeft() < space) {
                        try self.flush();
                    }
                }

                /// Write a raw integer into the buffer.
                ///
                /// This is not a message.
                /// And must be read from the `EncryptedReader` using `readInt` with the same type.
                ///
                /// Endianness is handled under the hood.
                pub fn putInt(self: *Self, int: anytype) !void {
                    const IntT = @TypeOf(int);
                    std.debug.assert(IntT != usize);

                    try self.ensureSpace(@sizeOf(IntT));
                    defer self.start += @sizeOf(IntT);

                    @memcpy(
                        self.write_buf[self.start..self.start + @sizeOf(IntT)],
                        std.mem.asBytes(&std.mem.nativeToBig(IntT, int))
                    );
                }
            };
        }
    };
}


/// Increment the provided nonce as if it were an integer
fn incrementNonce(nonce: *[chacha.nonce_length]u8) void {
    const NonceIntT = @Type(.{
        .Int = .{ .signedness = .unsigned, .bits = chacha.nonce_length * 8 }
    });

    std.mem.writePackedInt(
        NonceIntT, nonce, 0, std.mem.bytesToValue(NonceIntT, nonce) +% 1, native_endian
    );
}


/// Calculate the smallest Integer Type that can represent the `max_size` and is a multiple of 8 (bits)
fn SmallestInt(max_size: usize) type {
    const bits = @as(u16, @floor(@log2(@as(f64, max_size)))) + 1;
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
