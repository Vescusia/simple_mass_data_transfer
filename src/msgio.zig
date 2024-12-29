const std = @import("std");


fn msg_size_t_is_valid(msg_size_t: type) bool {
    return @typeInfo(msg_size_t) == .Int and @typeInfo(msg_size_t).Int.signedness == .unsigned;
}


pub fn MessageReader(comptime msg_size_t: type, comptime reader_t: type) type {
    if (!msg_size_t_is_valid(msg_size_t)) {
        @compileError("Message Size Integer Type has to be unsigned and an Int.");
    }

    return struct {
        alloc: std.mem.Allocator,
        buf: []u8,
        reader: reader_t,
        msg_size: msg_size_t = 0,
        size_read: bool = false,
        bytes_read: usize = 0,

        const m_size_size = @sizeOf(msg_size_t);
        const Self = @This();

        /// Call `deinit` to free memory
        pub fn init(allocator: std.mem.Allocator, reader: reader_t) !Self {
            return withSize(allocator, reader, 1 << 10);
        }

        /// Call `deinit` to free memory
        pub fn withSize(allocator: std.mem.Allocator, reader: reader_t, size: usize) !Self {
            return .{ .alloc = allocator, .reader = reader, .buf = try allocator.alloc(u8, size), };
        }

        pub fn deinit(self: Self) void {
            self.alloc.free(self.buf);
        }

        /// This will read a Message from the underlying Reader.
        ///
        /// This will return null if the Reader reaches EOF before the complete Message could be read.
        ///
        /// **The returned array will be valid until this function is called again.**
        pub fn readMessage(self: *Self) !?[]u8 {
            // get size of message
            while (self.bytes_read < m_size_size) {
                const new_bytes_read = try self.reader.read(self.buf[self.bytes_read..]);
                if (new_bytes_read == 0) {
                    return null;
                }
                self.bytes_read += new_bytes_read;
            }

            // convert size bytes to int (in its own block because of variable scope)
            {
                const msg_size = std.mem.bytesToValue(msg_size_t, self.buf[0..m_size_size]);
                self.msg_size = std.mem.bigToNative(msg_size_t, msg_size);
                self.msg_size += m_size_size;
            }

            // check if buffer is large enough
            if (self.buf.len <= self.msg_size) {
                // std.debug.print("MsgReader: resizing {} to {}\n", .{self.buf.len, self.msg_size * 2});
                self.buf = try self.alloc.realloc(self.buf, self.msg_size * 2);
            }

            // fill up buffer
            while (self.bytes_read < self.msg_size) {
                const new_bytes_read = try self.reader.read(self.buf[self.bytes_read..]);
                if (new_bytes_read == 0) {
                    return null;
                }
                self.bytes_read += new_bytes_read;
            }

            // prepare return value
            const msg = self.buf[m_size_size..self.msg_size];

            // clean up
            self.bytes_read -= self.msg_size;
            self.msg_size = 0;

            // return message
            return msg;
        }
    };
}


/// This writing is not buffered! If you are sending many small messages, please consider buffering the underlying Writer.
pub fn MessageWriter(comptime msg_size_t: type, comptime writer_t: type) type {
    if (!msg_size_t_is_valid(msg_size_t)) {
        @compileError("Message Size Integer Type has to be unsigned and an Int.");
    }

    return struct {
        writer: writer_t,

        const Self = @This();

        pub fn init(writer: writer_t) !Self {
            return .{.writer = writer };
        }

        pub fn writeMessage(self: *const Self, msg: []const u8) !void {
            // message len to bytes
            const len: msg_size_t = std.mem.nativeToBig(msg_size_t, @intCast(msg.len));
            const size: [@sizeOf(msg_size_t)]u8 = std.mem.toBytes(len);

            // build iovecs
            var iovecs = [_]std.posix.iovec_const {
                .{ .base = &size, .len = size.len },
                .{ .base = msg.ptr,  .len = msg.len }
            };

            // write
            try self.writevAll(&iovecs);
        }

        // This is not part of std.io.GenericWriter??
        //
        // On windows, this will literally not offer any performance increase lol.
        // It does not have an equivalent syscall.
        fn writevAll(self: *const Self, iovecs: []std.posix.iovec_const) !void {
            var i: usize = 0;
            while (true) {
                var amt = try std.posix.writev(self.writer.context.handle, iovecs[i..]);
                while (amt >= iovecs[i].len) {
                    amt -= iovecs[i].len;
                    i += 1;
                    if (i >= iovecs.len) return;
                }
                iovecs[i].base += amt;
                iovecs[i].len -= amt;
            }
        }

        /// Combined write of multiple arrays into as message
        ///
        /// Allocates a very small `iovec` array. All memory is freed when the function returns.
        ///
        /// This is useful when you would have to merge multiple arrays into one for a complete message.
        pub fn writeMultiple(self: *const Self, alloc: std.mem.Allocator, contents: []const []const u8) !void {
            // allocate iovecs + one iovec for the size
            var iovecs = try alloc.alloc(std.posix.iovec_const, contents.len+1);
            defer alloc.free(iovecs);

            // initialize iovecs and calculate total length
            var total_len: msg_size_t = 0;
            for (1.., contents) |i, content| {
                iovecs[i].base = content.ptr;
                iovecs[i].len = content.len;
                total_len += @intCast(content.len);
            }

            // calculate bytes of total length
            const size: [@sizeOf(msg_size_t)]u8 = std.mem.toBytes(
                std.mem.nativeToBig(msg_size_t, total_len)
            );
            // add its iovec
            iovecs[0] = .{ .base = &size, .len = size.len };

            // write
            try self.writevAll(iovecs);
        }
    };
}
