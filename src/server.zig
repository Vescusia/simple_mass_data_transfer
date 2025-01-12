const std = @import("std");
const net = std.net;

const indexing = @import("file_indexing.zig");
const cycbuf = @import("cycle_buf.zig");
const shared = @import("shared.zig");

const main = @import("main.zig");
const proto_version = main.proto_version;
const CryptIO = main.CryptIO;

const CycleBuf = cycbuf.CycleBuffers(512, CryptIO.max_block_size);

var working_dir: []const u8 = undefined;
var stdout: @TypeOf(std.io.getStdOut().writer()) = undefined;


pub fn server(alloc: std.mem.Allocator) !void {
    // create stdout
    stdout = std.io.getStdOut().writer();

    // instantiate address
    const address = try net.Address.parseIp("127.0.0.1", 5882);

    // create listener
    var listener = try address.listen(.{ .reuse_address = true, .reuse_port = true });

    // create absolute path
    //working_dir = try std.fs.realpathAlloc(alloc, "C:\\Users\\Administrator\\Programs\\Zig\\simple_mass_data_transfer");
    working_dir = try std.fs.realpathAlloc(alloc, "C:\\Users\\Administrator\\Programs\\Zig\\test1");
    defer alloc.free(working_dir);

    // index files
    var file_index = try indexing.indexFiles(alloc, .{ .mode = .read_only, .lock = .shared }, working_dir);
    defer file_index.closeAll();

    // sort index for binary search
    file_index.sort();
    try stdout.print("Working in {s}, containing {} files ({} kiB)\n", .{ working_dir, file_index.files().len, file_index.total_remaining_size / 1024 });


    // main loop
    try stdout.print("Server is listening on {} with protocol version {}\n", .{ address, proto_version });
    while (true)  {
        // accept client
        const client = try listener.accept();
        try stdout.print("Client<{}> connected!\n", .{ client.address });

        // handle client
        var index_clone = try file_index.clone();
        try handle_client(alloc, client, &index_clone);

        break;
    }
}


/// All allocated memory will be freed by the end of this function
fn handle_client(alloc: std.mem.Allocator, client: net.Server.Connection, file_index: *indexing.FileIndex) !void {
    defer file_index.deinit();
    defer client.stream.close();
    defer std.debug.print("Client<{}> disconnected.\n", .{client.address});


    // create encrypted io
    var writer = try CryptIO.EncryptedWriter(@TypeOf(client.stream.writer()), "raw_key: []const u8")
        .init(client.stream.writer());
    var reader = try CryptIO.EncryptedReader(@TypeOf(client.stream.reader()), "raw_key: []const u8")
        .init(client.stream.reader());


    // start timer
    const complete_start = try std.time.Instant.now();


    // exchange version
    try writer.putInt(proto_version); try writer.flush();
    const client_version = try reader.readInt(@TypeOf(proto_version));
    if (client_version != proto_version) {
        try stdout.print("{}: using invalid protocol version {}\n", .{ client.address, client_version });
    }
    else {
        try stdout.print("Correct protocol version\n", .{});
    }


    // receive and combine client progress file index
    const resume_len = try reader.readInt(u64);
    if (resume_len > 0) {
        try stdout.print("Got {} resumes\n", .{ resume_len });

        // completely finish all resume_len - 1 id's
        for (0..resume_len - 1) |_| {
            const id = try reader.readInt(u128);

            if (file_index.binaryFind(id)) |i| {
                file_index.files()[i].already_read = file_index.files()[i].size;
            }
        }

        // receive progress for last file
        const id = try reader.readInt(u128);
        const progress = try reader.readInt(u64);

        // set progress
        if (file_index.binaryFind(id)) |i| {
            const size = file_index.files()[i].size;
            file_index.files()[i].already_read = @min(size, progress);
        }

        // recalculate
        file_index.recalculateRenainingSize();
    }
    try stdout.print("Total remaining size: {} kiB\n", .{ file_index.total_remaining_size / 1024 });


    // send combined file index
    try shared.writeFileIndex(&writer, file_index.*);
    try writer.flush();


    // start pure write timer
    const pure_start = try std.time.Instant.now();


    // create cycle buffers
    var bufs = try CycleBuf.init(alloc);
    defer bufs.deinit();


    // start file reader thread
    const file_read_thread = try std.Thread.spawn(.{}, fileReader, .{ file_index, bufs.cycleWriter() });


    // send bytes
    var cycle_reader = bufs.cycleReader();
    while (true) {
        const read_txn = cycle_reader.startRead();

        try writer.writeBufToBlock(read_txn.buf());
		if (read_txn.len() < CycleBuf.buf_size) {
            break;
        }

        read_txn.finish();
    }


    // join with file reader
    try stdout.print("All files sent\n", .{});
    file_read_thread.join();

    // print stats
    const elapsed_s: f64 = @as(f64, @floatFromInt((try std.time.Instant.now()).since(complete_start))) / @as(f64, @floatFromInt(std.time.ns_per_s));
    const pure_elapsed_s: f64 = @as(f64, @floatFromInt((try std.time.Instant.now()).since(pure_start))) / @as(f64, @floatFromInt(std.time.ns_per_s));
    try stdout.print("{} kiB in {e} s ({d} min) ({d} kiB/s (pure: {d} kiB/s))\n", .{
        file_index.total_remaining_size / 1024,
        elapsed_s, elapsed_s / 60,
        @round(@as(f64, @floatFromInt(file_index.total_remaining_size / 1024)) / elapsed_s),
        @round(@as(f64, @floatFromInt(file_index.total_remaining_size / 1024)) / pure_elapsed_s)
    });
}


fn fileReader(file_index: *indexing.FileIndex, raw_cycle_writer: CycleBuf.CycleWriter) !void {
    var cycle_writer = raw_cycle_writer;
    const buf_size = CycleBuf.buf_size;

    // create initial buffer write transactions
    var write_txns: [4]@TypeOf(cycle_writer.startWrite()) = undefined;
    for (&write_txns) |*txn| {
        txn.* = cycle_writer.startWrite();
    }

    // create iovecs for reading
    var iovecs: [write_txns.len]std.posix.iovec = undefined;
    for (&write_txns, &iovecs) |*write_txn, *iovec| {
        iovec.* = .{
            .base = write_txn.buf().ptr,
            .len = buf_size,
        };
    }

    for (file_index.files()) |*file| {
        try file.file.seekTo(file.already_read);

        while (file.size > file.already_read) {
            // read into cycle buffer
            var new_amt_read = try file.file.readv(&iovecs);
            file.already_read += new_amt_read;

            if (new_amt_read == 0) {
                return error.UnexpectedEOF;
            }

            // index of the first write_txn/iovec that still can still be written to
            var first_unfinished_i: usize = 0;
            {
                // resize iovecs
                var i: usize = 0;
                while (new_amt_read > 0) : (i += 1) {
                    const iovec = &iovecs[i];

                    // @min(new_amt_read, iovec.len)
                    const min = blk: {
                        if (new_amt_read >= iovec.len) {
                            // finish full buffer
                            write_txns[i].finish(buf_size);
                            first_unfinished_i = i + 1;
                            break :blk iovec.len;
                        }
                        else break :blk new_amt_read;
                    };

                    iovec.base += min;
                    iovec.len -= min;
                    new_amt_read -= min;
                }
            }

            // renew buffers and empty iovecs
            if (first_unfinished_i > 0) {
                // move valid iovecs and write_txns to the front
                std.mem.copyForwards(std.posix.iovec, iovecs[0..iovecs.len - first_unfinished_i], iovecs[first_unfinished_i..]);
                std.mem.copyForwards(@TypeOf(cycle_writer.startWrite()), write_txns[0..write_txns.len - first_unfinished_i], write_txns[first_unfinished_i..]);

                // fill end with new ones
                for ((iovecs.len - first_unfinished_i)..iovecs.len) |i| {
                    write_txns[i] = cycle_writer.startWrite();
                    iovecs[i] = .{
                        .base = write_txns[i].buf().ptr,
                        .len = buf_size,
                    };
                }
            }
        }
    }

    // finish buffer
    write_txns[0].finish(buf_size - iovecs[0].len);
    try stdout.print("All files read\n", .{});
}
