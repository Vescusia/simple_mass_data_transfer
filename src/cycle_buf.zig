const std = @import("std");

const Condition = std.Thread.Condition;
const Mutex = std.Thread.Mutex;


/// A Thread Safe Cyclic Buffer, with `buffer_amt` amount of Buffers of length `arr_len`
///
/// A larger `buffer_amt` will cushion latency spikes better.
///
/// The `arr_len` should be tuned to the Reader/Writer and allow them to fully use their IO Bursts
pub fn CycleBuffers(comptime buffer_amt: usize, comptime arr_len: usize) type {
    std.debug.assert(buffer_amt >= 3);

    return struct {
        buffers: [buffer_amt]Buffer,
        alloc: std.heap.ArenaAllocator,
        write_update: Condition = .{},

        const Buffer = struct {
            arr: []u8,
            written: usize = 0,
            mutex: Mutex = .{},
            /// Just for the initial reader state
            valid: bool = false,
        };


        const Super = @This();

        /// Initialize the CycleBuffers
        ///
        /// Use `cycleWriter()` and `cycleReader()` to interact with the Buffers.
        ///
        /// Call `deinit` to deallocate the memory allocated by this function.
        pub fn init(alloc: std.mem.Allocator) !Super {
            // wrap in ArenaAllocator
            var arena_alloc = std.heap.ArenaAllocator.init(alloc);

            // create buffers
            var buffers: [buffer_amt]Buffer = undefined;
            for (&buffers) |*buf| {
                buf.* = .{
                    .arr = try arena_alloc.allocator().alloc(u8, arr_len),
                };
            }

            return Super{
                .buffers = buffers,
                .alloc = arena_alloc
            };
        }

        pub fn deinit(self: Super) void {
            self.alloc.deinit();
        }


        pub const CycleWriter = struct {
            super: *Super,
            pos: usize = 0,

            const Self = @This();


            pub const WriteTxn = struct {
                pos: usize,
                super: *Super,

                pub fn buf(self: @This()) []u8 {
                    return self.super.buffers[self.pos].arr;
                }

                /// Finishes the write transaction, allowing
                /// the reader to start reading the buffer
                pub fn finish(self: @This(), written: usize) void {
                    const current_buf = &self.super.buffers[self.pos];

                    defer self.super.write_update.signal();
                    defer current_buf.mutex.unlock();

                    current_buf.valid = true;
                    current_buf.written = written;
                }
            };


            /// Start a Write (`finishwrite()` to finish it)
            ///
            /// Returns a Pointer to the Buffered Array.
            ///
            /// Will block if the reader is too slow.
            pub fn startWrite(self: *Self) WriteTxn {
                const super = self.super;

                const buf = &super.buffers[self.pos];
                buf.mutex.lock();

                defer self.pos = (self.pos + 1) % buffer_amt;

                return .{
                    .pos = self.pos,
                    .super = self.super,
                };
            }
        };

        /// Only one Thread may be the Writer.
        pub fn cycleWriter(super: *Super) CycleWriter {
            return CycleWriter{
                .super = super,
            };
        }


        pub const CycleReader = struct {
            super: *Super,
            read_active: bool = false,
            pos: usize = 0,


            const ReadTxn = struct {
                pos: usize,
                super: *CycleReader,

                pub fn buf(self: @This()) []const u8 {
                    return self.super.super.buffers[self.pos].arr[0..self.len()];
                }

                /// The length of the buffer
                ///
                /// equivalent to `.buf().len`
                pub fn len(self: @This()) usize {
                    return self.super.super.buffers[self.pos].written;
                }

                /// Finish reading the buffer,
                /// allowing writers to overwrite it
                pub fn finish(self: @This()) void {
                    const super = self.super.super;

                    defer self.super.read_active = false;

                    super.buffers[self.pos].mutex.unlock();
                }
            };


            /// Start a Read (`finishRead()` to finish it)
            ///
            /// Returns a Pointer to the Buffered Array
            ///
            /// Will Block if the Writer is too slow.
            pub fn startRead(self: *@This()) ReadTxn {
                const super = self.super;

                std.debug.assert(self.read_active == false);
                defer self.read_active = true;

                const buf = &super.buffers[self.pos];

                buf.mutex.lock();
                while (!buf.valid) {
                    super.write_update.wait(&buf.mutex);
                }

                defer self.pos = (self.pos + 1) % buffer_amt;

                return .{
                    .pos = self.pos,
                    .super = self,
                };
            }
        };

        /// Only one Thread may be the Reader.
        pub fn cycleReader(super: *Super) CycleReader {
            return CycleReader{
                .super = super
            };
        }
    };
}


test "basic functionality" {
    var cycle_bufs = try CycleBuffers(3, 16).init(std.testing.allocator);
    defer cycle_bufs.deinit();
    var writer = cycle_bufs.cycleWriter();
    var reader = cycle_bufs.cycleReader();

    const text0 = "01234567"[0..];
    const text1 = "ZATTYZAT"[0..];

    var write_buf = writer.startWrite();    // writer 0; reader 0
    @memcpy(write_buf[0..text0.len], text0);
    writer.finishWrite(text0.len);          // writer 1; reader 0
    write_buf = writer.startWrite();        // writer 1; reader 0
    @memcpy(write_buf[0..text1.len], text1);
    writer.finishWrite(text1.len);          // writer 2; reader 0
    // another finishWrite would have to wait for the reader to advance.

    var read_buf = reader.startRead();      // writer 2; reader 0
    try std.testing.expect(std.mem.eql(u8, read_buf, text0));
    reader.finishRead();                    // writer 2; reader 1
    read_buf= reader.startRead();           // writer 2; reader 1
    try std.testing.expect(std.mem.eql(u8, read_buf, text1));
    // another finishRead would have to wait for the writer to advance.
}

test {
    var buf = try CycleBuffers(8, 1 << 16).init(std.testing.allocator);
    defer buf.deinit();
    _ = buf.cycleWriter();
    _ = buf.cycleReader();
}
