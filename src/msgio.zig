const std = @import("std");
const print = std.debug.print;


const debug = true and switch (@import("builtin").mode) {
    .Debug => true,
    else => false,
};


fn msg_size_t_is_valid(msg_size_t: type) bool {
    return @typeInfo(msg_size_t) == .Int and @typeInfo(msg_size_t).Int.signedness == .unsigned;
}


pub fn MessageReader(comptime MsgSizeT: type, comptime ReaderT: type) type {
    if (!msg_size_t_is_valid(MsgSizeT)) {
        @compileError("Message Size Integer Type has to be unsigned and an Int.");
    }

    return struct {
        alloc: std.mem.Allocator,
        reader: ReaderT,
        total_msg_size: MsgSizeT = undefined,
        super_arr: []u8,
        main_buf: Buf,
        aux_buf: Buf,

        const Buf = struct {
            arr: []u8,
            total_read: usize = 0,
        };


        const m_size_size = @sizeOf(MsgSizeT);
        const Self = @This();

        const using_context_readv: bool = blk: {
            for (@typeInfo(ReaderT).Struct.fields) |field| {
                if (std.mem.eql(u8, field.name, "context")) {
                    for (@typeInfo(field.type).Struct.decls) |decl| {
                        if (std.mem.eql(u8, decl.name, "readv")) {
                            break :blk true;
                        }
                    }
                }
            }
            break :blk false;
        };

        /// Will be true if the `MessageReader` is using vectored Reads.
        /// Not using vectored Reads will (probably) result in a small performance reduction.
        ///
        /// If this returns `false`, consider using an underlying Reader that implements `readv`.
        pub const using_readv: bool = using_context_readv or blk: {
            for (@typeInfo(ReaderT).Struct.decls) |decl| {
                if (std.mem.eql(u8, decl.name, "readv")) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        /// Call `deinit` to free memory
        pub fn init(allocator: std.mem.Allocator, reader: ReaderT) !Self {
            return withSize(allocator, reader, 1 << 24);
        }

        /// Call `deinit` to free memory
        pub fn withSize(allocator: std.mem.Allocator, reader: ReaderT, size: usize) !Self {
            // use a big array that the main and auxillary buffers actually point to
            // for cache completeness
            const super_arr = try allocator.alloc(u8, size * 2);

            return .{
                .alloc = allocator,
                .reader = reader,
                .super_arr = super_arr,
                .main_buf = .{ .arr = super_arr[0..size] },
                .aux_buf = .{ .arr = super_arr[size..] },
            };
        }

        pub fn deinit(self: Self) void {
            self.alloc.free(self.super_arr);
        }

        fn growBufs(self: *Self, new_size: usize) !void {
            std.debug.assert(new_size * 2 > self.super_arr.len);

            // allocate new, bigger super array
            const new_big_arr = try self.alloc.alloc(u8, new_size * 2);
            defer { self.alloc.free(self.super_arr); self.super_arr = new_big_arr; }

            // copy old data
            @memcpy(new_big_arr[0..self.main_buf.total_read], self.main_buf.arr[0..self.main_buf.total_read]);
            @memcpy(new_big_arr[new_size..self.aux_buf.total_read],  self.aux_buf.arr[0..self.aux_buf.total_read]);

            // reassign buffers into super array
            self.main_buf.arr = new_big_arr[0..new_size];
            self.aux_buf.arr = new_big_arr[new_size..];
        }

        fn doubleBufs(self: *Self) !void {
            return self.growBufs(self.main_buf.arr.len * 2);
        }

        /// This will read a Message from the underlying Reader.
        ///
        /// This will return null if the Reader reaches EOF before the complete Message could be read.
        ///
        /// **The returned array will be valid until this function is called again.**
        pub fn readMessage(self: *Self) !?[]u8 {
            // clean up last call
            self.main_buf.total_read = 0;
            self.total_msg_size = undefined;
            std.mem.swap(Buf, &self.main_buf, &self.aux_buf);

            // get new message size
            self.total_msg_size = try self.getTotalMsgSize() orelse return null;

            // read message bytes
            // decide which readToSize function to use
            if (using_readv) {
                try self.readToSizeVectored(self.total_msg_size) orelse return null;
            }
            else {
                // less efficient :(
                try self.readToSize(self.total_msg_size) orelse return null;
            }

            // return
            return self.main_buf.arr[m_size_size..self.total_msg_size];
        }

        // uses iovecs to efficiently handle read overflows
        // std.io.GenericReader has no readv LMAO imma kms
        fn readToSizeVectored(self: *Self, total_size: usize) !?void {
            if (self.main_buf.total_read == total_size) {
                return;
            }
            std.debug.assert(self.main_buf.arr.len > total_size);

            // build iovecs
            var iovecs = [_]std.posix.iovec {
                .{ .base = self.main_buf.arr.ptr + self.main_buf.total_read, .len = total_size - self.main_buf.total_read },
                .{ .base = self.aux_buf.arr.ptr + self.aux_buf.total_read, .len = self.aux_buf.arr.len - self.aux_buf.total_read }
            };

            // read up to total_size
            while (true) {
                const amt_read = try if (using_context_readv) self.reader.context.readv(&iovecs) else self.reader.readv(&iovecs);
                if (amt_read == 0) {
                    return null;
                }

                if (iovecs[0].len <= amt_read) {
                    self.aux_buf.total_read += amt_read - iovecs[0].len;
                    self.main_buf.total_read = total_size;
                    break;
                }
                iovecs[0].base += amt_read;
                iovecs[0].len -= amt_read;
            }

            // increase buffer sizes if we hit the limit on the aux array
            if (self.aux_buf.total_read == self.aux_buf.arr.len) {
                if (debug) print("Doubling {} B Bufs in readToSizeVectored\n", .{ self.main_buf.arr.len });
                try self.doubleBufs();
            }
        }

        fn readToSize(self: *Self, total_size: usize) !?void {
            if (self.main_buf.total_read == total_size) {
                return;
            }
            std.debug.assert(self.main_buf.arr.len > total_size);

            // read to at least total size
            while (self.main_buf.total_read < total_size) {
                const read = try self.reader.read(self.main_buf.arr[self.main_buf.total_read..]);
                if (read == 0) {
                    return null;
                }
                self.main_buf.total_read += read;
            }

            // handle overread
            if (self.main_buf.total_read > self.total_msg_size) {
                const overread = self.main_buf.total_read - self.total_msg_size;
                @memcpy(
                    self.aux_buf.arr[self.aux_buf.total_read..self.aux_buf.total_read + overread],
                    self.main_buf.arr[total_size..total_size + overread]
                );
                self.aux_buf.total_read += overread;
            }

            // if we completely filled the buffer with this read
            // increase their size to prevent not fully using read syscalls
            if (self.main_buf.total_read == self.main_buf.arr.len) {
                if (debug) print("Doubling {} B Bufs in readToSize\n", .{ self.main_buf.arr.len });
                try self.doubleBufs();
            }

            self.main_buf.total_read = total_size;
        }

        /// Resizes the buffers to fit the message
        fn getTotalMsgSize(self: *Self) !?MsgSizeT {
            // gather bytes (read overflows into message, as long as main array is big enough)
            // could possibly read more bytes than are part of the message
            while (self.main_buf.total_read < m_size_size) {
                const read = try self.reader.read(self.main_buf.arr[self.main_buf.total_read..]);
                if (read == 0) {
                    return null;
                }
                self.main_buf.total_read += read;
            }

            // convert bytes to int
            var total_msg_size = std.mem.bytesToValue(MsgSizeT, self.main_buf.arr[0..m_size_size]);
            total_msg_size = std.mem.bigToNative(MsgSizeT, total_msg_size);  // network to native byte order
            total_msg_size += m_size_size;

            // check if the main buffer got copletely filled
            // or if the message does not fit into the buffer
            if (self.main_buf.arr.len == self.main_buf.total_read or self.main_buf.arr.len < total_msg_size) {
                // resize both buffers, as this should not happen
                // for performance reasons (not every byte of the last read syscall is actually "being used")
                // and of course, because we might not be able to fit the message!
                const new_len = @max(self.main_buf.arr.len, self.total_msg_size) * 2;
                if (debug) print("Resizing {} B Bufs in getTotalMsgSize to {}\n", .{ self.main_buf.arr.len, new_len });
                try self.growBufs(new_len);
            }

            // handle message overreading
            if (self.main_buf.total_read > total_msg_size) {
                const overread = self.main_buf.total_read - total_msg_size;
                @memcpy(self.aux_buf.arr[0..overread], self.main_buf.arr[total_msg_size..self.main_buf.total_read]);

                self.aux_buf.total_read = overread;
                self.main_buf.total_read = total_msg_size;
            }

            return total_msg_size;
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

        pub fn init(writer: writer_t) Self {
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
            try self.writevAll(iovecs.len, &iovecs);
        }

        // This is not part of std.io.GenericWriter??
        // Well, I do not care, it is too important. If the writer does not work with std.posix.writev, get fucked.
        //
        // On windows, this will literally not offer any performance increase lol.
        // It does not have an equivalent syscall.
        fn writevAll(self: *const Self, comptime len: usize, iovecs: *[len]std.posix.iovec_const) !void {
            var i: usize = 0;

            while (true) {
                var amt = try std.posix.writev(self.writer.context.handle, iovecs[i..]);
                while (amt >= iovecs[i].len) {
                    amt -= iovecs[i].len;
                    i += 1;
                    if (i >= len) return;
                }
                iovecs[i].base += amt;
                iovecs[i].len -= amt;
            }
        }

        /// Combined write of multiple arrays into as message
        ///
        /// This is useful when you would have to merge multiple arrays into one for a complete message.
        pub fn writeMultiple(self: *const Self, comptime len: usize, contents: [len][]const u8) !void {
            // allocate iovecs + one iovec for the size
            var iovecs: [len+1]std.posix.iovec_const = undefined;

            // initialize iovecs and calculate total length
            var total_len: msg_size_t = 0;
            inline for (1.., contents) |i, content| {
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
            try self.writevAll(iovecs.len, &iovecs);
        }
    };
}
