const std = @import("std");

const Condition = std.Thread.Condition;
const Mutex = std.Thread.Mutex;


/// A Thread Safe Cyclic Buffer, with `buffer_amt` amount of Buffers of length `arr_len`
///
/// A larger `buffer_amt` will cushion latency spikes better.
///
/// The `arr_len` should be tuned to the Reader/Writer and allow them to fully use their IO Bursts
pub fn CycleBuffers(comptime buffer_amt: usize, comptime arr_len: usize) type {
    std.debug.assert(buffer_amt >= 2);

    return struct {
        buffers: [buffer_amt]Buffer,
        writer_i: usize = 0,
        reader_i: usize = 0,
        mutex: Mutex = Mutex{},
        write_update: Condition = Condition{},
        read_update: Condition = Condition{},


        const Buffer = struct {
            arr: [arr_len]u8,
            written: usize,
        };


        const Super = @This();

        /// Initialize the CycleBuffers
        ///
        /// Use `cycleWriter()` and `cycleReader()` to interact with the Buffers.
        ///
        /// The Caller of this Function must also be the Writer.
        pub fn init() Super {
            return Super{
                .buffers = undefined,
            };
        }


        const CycleWriter = struct {
            super: *Super,
            written: usize = 0,
            write: *[arr_len]u8 = undefined,

            const Self = @This();

            /// Start a Write (`finishwrite()` to finish it)
            ///
            /// Returns a Pointer to the Buffered Array.
            ///
            /// Will **not** block.
            pub fn startWrite(self: *Self) *[arr_len]u8 {
                const super = self.super;

                super.mutex.lock();
                defer super.mutex.unlock();

                // return buffer
                return &super.buffers[super.writer_i].arr;
            }

            /// Finish a Write, advancing to the next Buffer
            /// and allowing the Reader to start Reading this one
            ///
            /// Will Block if the Reader is too slow.
            pub fn finishWrite(self: *Self, written: usize) void {
                const super = self.super;

                super.mutex.lock();
                defer super.mutex.unlock();

                // set current Buffers written bytes
                super.buffers[super.writer_i].written = written;

                // wait for Reader to finish reading from next Buffer
                const next_i = (super.writer_i + 1) % buffer_amt;
                while (next_i == super.reader_i) {
                    super.read_update.wait(&super.mutex);
                }

                // move to next Buffer
                super.writer_i = next_i;

                // signal Reader that a Buffer has been finished
                super.write_update.signal();
            }
        };

        /// Only one Thread may be the Writer.
        pub fn cycleWriter(super: *Super) CycleWriter {
            return CycleWriter{
                .super = super,
            };
        }


        const CycleReader = struct {
            super: *Super,
            reader_i: usize = 0,

            const Self = @This();

            /// Start a Read (`finishRead()` to finish it)
            ///
            /// Returns a Pointer to the Buffered Array
            ///
            /// Will Block if the Writer is too slow.
            pub fn startRead(self: *Self) []u8 {
                const super = self.super;

                super.mutex.lock();
                defer super.mutex.unlock();

                // wait for Writer to finish writing to current Buffer
                while (super.reader_i == super.writer_i) {
                    super.write_update.wait(&super.mutex);
                }

                // return the Bytes
                const written = super.buffers[super.reader_i].written;
                return super.buffers[super.reader_i].arr[0..written];
            }

            /// Finish a Read, advancing to the next Buffer
            /// and allowing the Writer to overwrite this one
            pub fn finishRead(self: *Self) void {
                const super = self.super;

                super.mutex.lock();
                defer super.mutex.unlock();

                // move to next Buffer
                super.reader_i = (super.reader_i + 1) % buffer_amt;

                // signal Writer that a Buffer has been finished
                super.read_update.signal();
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
    var cycle_bufs = CycleBuffers(3, 16).init();
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
    var buf = CycleBuffers(8, 1 << 16).init();
    _ = buf.cycleWriter();
    _ = buf.cycleReader();
}
