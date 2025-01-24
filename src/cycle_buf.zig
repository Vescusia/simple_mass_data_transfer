const std = @import("std");

const AtomicValue = std.atomic.Value;
const Futex = std.Thread.Futex;


/// A Thread Safe Cyclic Buffer, with `buffer_amt` amount of Buffers of length `arr_len`
///
/// A larger `buffer_amt` will cushion latency spikes better.
///
/// The `arr_len` should be tuned to the Reader/Writer and allow them to fully use their IO Bursts
pub fn CycleBuffers(comptime buffer_amt: u32, comptime arr_len: usize) type {
    std.debug.assert(buffer_amt >= 3);

    return struct {
        buffers: [buffer_amt]Buffer,
        alloc: std.heap.ArenaAllocator,
        write_head: AtomicValue(u32) = AtomicValue(u32).init(0),
        write_tail: AtomicValue(u32) = AtomicValue(u32).init(0),
        read_pos: AtomicValue(u32) = AtomicValue(u32).init(0),

        const Buffer = struct {
            arr: []u8,
            written: usize = 0,
        };

        pub const buf_size = arr_len;

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
            pos: u32 = 0,

            const Self = @This();

            pub const WriteTxn = struct {
                pos: u32,
                finish_pos: u32,
                super: *Super,

                pub fn buf(self: @This()) []u8 {
                    return self.super.buffers[self.pos].arr;
                }

                /// Finishes the write transaction, allowing
                /// the reader to start reading the buffer
                ///
                /// * `written`: the amount of valid bytes written
                ///
                /// Finishing a write transaction out of order will implicitly finish all transactions before it.
                /// Finishing a write transaction after already having finished a later one, will cause a deadlock.
                pub fn finish(self: @This(), written: usize) void {
                    self.super.buffers[self.pos].written = written;

                    self.super.write_tail.store(self.finish_pos, .release);
                    Futex.wake(&self.super.write_tail, 1);
                }
            };


            /// Start a Write (`finishwrite()` to finish it)
            ///
            /// Returns a Pointer to the Buffered Array.
            ///
            /// Will block if the reader is too slow.
            pub fn startWrite(self: *Self) WriteTxn {
                const super = self.super;

                const old_write_head = super.write_head.load(.acquire);

                // progress write head
                const new_write_head = (old_write_head + 1) % buffer_amt;
                defer super.write_head.store(new_write_head, .release);
                defer Futex.wake(&super.write_head, 1);

                // wait for read tail to progress further, such that we can write to this buffer
                var read_pos = super.read_pos.load(.monotonic);
                while (new_write_head == read_pos) {
                    Futex.wait(&super.read_pos, new_write_head);
                    read_pos = super.read_pos.load(.monotonic);
                }
                super.read_pos.fence(.acquire);

                return .{
                    .pos = old_write_head,
                    .finish_pos = new_write_head,
                    .super = super,
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


            const ReadTxn = struct {
                pos: u32,
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
                    std.debug.assert(self.super.read_active);
                    defer self.super.read_active = false;

                    const super = self.super.super;

                    // progress reader
                    super.read_pos.store((self.pos + 1) % buffer_amt, .release);
                    Futex.wake(&super.read_pos, std.math.maxInt(u32));
                }
            };


            /// Start a Read (`finishRead()` to finish it)
            ///
            /// Returns a Pointer to the Buffered Array
            ///
            /// Will Block if the Writer is too slow.
            pub fn startRead(self: *@This()) ReadTxn {
                std.debug.assert(!self.read_active);
                self.read_active = true;

                const super = self.super;

                const read_pos = super.read_pos.load(.acquire);

                // wait for writer to progress if it's still writing to this buffer
                var write_tail = super.write_tail.load(.monotonic);
                while (write_tail == read_pos) {
                    Futex.wait(&super.write_tail, read_pos);
                    write_tail = super.write_tail.load(.monotonic);
                }
                super.write_tail.fence(.acquire);

                return .{
                    .pos = read_pos,
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

    var write_txn = writer.startWrite();    // write_head 1; write_tail: 0; reader 0
    @memcpy(write_txn.buf()[0..text0.len], text0);
    write_txn.finish(text0.len);            // write_head 1; write_tail: 1; reader 0
    write_txn = writer.startWrite();        // write_head 2; write_tail: 1; reader 0
    @memcpy(write_txn.buf()[0..text1.len], text1);
    write_txn.finish(text1.len);            // write_head 2; write_tail: 2; reader 0
    // starting another write would block here

    var read_txn = reader.startRead();      // write_head 2; write_tail: 2; reader 0
    try std.testing.expect(std.mem.eql(u8, read_txn.buf(), text0));
    read_txn.finish();                      // write_head 2; write_tail: 2; reader 1
    read_txn = reader.startRead();          // write_head 2; write_tail: 2; reader 1
    try std.testing.expect(std.mem.eql(u8, read_txn.buf(), text1));
    read_txn.finish();                      // write_head 2; write_tail: 2; reader 2
    // starting another read would block here
}

test {
    var buf = try CycleBuffers(8, 1 << 16).init(std.testing.allocator);
    defer buf.deinit();
    _ = buf.cycleWriter();
    _ = buf.cycleReader();
}
