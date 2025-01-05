const std = @import("std");
const net = std.net;

const cryptio = @import("cryptio.zig");
const indexing = @import("file_indexing.zig");
const utils = @import("utils.zig");
const cycbuf = @import("cycle_buf.zig");

const main = @import("main.zig");
const proto_version = main.proto_version;
const max_msg_len = main.max_msg_len;


var working_dir: []const u8 = undefined;
const CycleBuf = cycbuf.CycleBuffers(1024, max_msg_len);


pub fn server(alloc: std.mem.Allocator) !void {
    // instantiate io
    var stdout = std.io.getStdOut().writer();
    var stdin = std.io.getStdIn().reader();

    // instantiate address
    const address = try net.Address.parseIp("127.0.0.1", 5882);

    // create listener
    var listener = try address.listen(.{ .reuse_address = true, .reuse_port = true });

    // create absolute path
    working_dir = try std.fs.realpathAlloc(alloc, ".");
    defer alloc.free(working_dir);
    std.debug.print("Working in '{s}'", .{ working_dir });

    // index files
    const file_index = try indexing.indexFiles(alloc, working_dir);
    defer file_index.deinit();
    std.debug.print("containing {} files ()\n", .{ file_index.items.len,  });

    // main loop
    try stdout.print("Server is listening on {} with protocol version {}\n", .{ address, proto_version });
    while (true)  {
        // accept client
        const client = try listener.accept();
        try stdout.print("Client<{}> connected!\n", .{ client.address });

        // handle client
        try handle_client(alloc, client, file_index.items);

        // ask user if they want to continue
        try stdout.print("Continue? y/N > ", .{});
        var buf: [128]u8 = undefined;
        _ = try stdin.readAtLeast(&buf, 1);

        if (buf[0] != 'Y' and buf[0] != 'y') {
            try stdout.print("Shutting down.\n", .{});
            break;
        }
    }
}


/// All allocated memory will be freed by the end of this function
fn handle_client(alloc: std.mem.Allocator, client: net.Server.Connection, file_index: []indexing.FileIndexEntry) !void {
    defer client.stream.close();
    defer std.debug.print("Client<{}> disconnected.\n", .{client.address});

    // create encrypted io
    var writer = cryptio.EncryptedWriter(@TypeOf(client.stream.writer()), max_msg_len, "raw_key: []const u8")
        .init(client.stream.writer());
    var reader = cryptio.EncryptedReader(@TypeOf(client.stream.reader()), max_msg_len, "raw_key: []const u8")
        .init(client.stream.reader());

    // starting timer
    const start = try std.time.Instant.now();

    // exchange version
    try writer.putInt(proto_version); try writer.flush();
    const client_version = try reader.readInt(@TypeOf(proto_version)) orelse return;
    if (client_version != proto_version) {
        std.debug.print("{}: using invalid protocol version {}\n", .{ client.address, client_version });
    }
    else {
        std.debug.print("Correct protocol version\n", .{});
    }

    // send current length of file index
    try writer.putInt(@as(u64, file_index.len));

    // receive file progress


    // send files in index
    for (file_index) |file| {
        try writer.putInt(file.id);
        try writer.putInt(@as(u64, file.size));
        try writer.writeMessage(file.path.bytes());
    }
    try writer.flush();

    // start file reader thread
    var bufs = try CycleBuf.init(alloc);
    defer bufs.deinit();
    std.debug.print("{}\n", .{@sizeOf(@TypeOf(bufs))});
    const file_thread = try std.Thread.spawn(.{}, file_reader, .{ file_index, bufs.cycleWriter() });
    
    // send bytes
    var cycle_reader = bufs.cycleReader();
    while (true) {
        const read = cycle_reader.startRead();
        std.debug.print("Writing\n", .{});
        defer cycle_reader.finishRead();

        try writer.writeMessage(read);

        if (read.len < max_msg_len) {
            std.debug.print("AHH\n", .{});
            break;
        }
    }



    file_thread.join();
    // print stats
    const elapsed: f64 = @as(f64, @floatFromInt((try std.time.Instant.now()).since(start))) / @as(f64, @floatFromInt(std.time.ns_per_s));
    std.debug.print("Time taken: {e} s ({e} min)\n", .{ elapsed, elapsed / 60 });
}


fn file_reader(file_index: []indexing.FileIndexEntry, raw_cycle_writer: CycleBuf.CycleWriter) !void {
    var cycle_writer = raw_cycle_writer;

    var write_buf = cycle_writer.startWrite();
    var buf_written: usize = 0;

    for (file_index) |*file| {
        // aquire file mutex
        file.lock.lock();
        defer file.lock.unlock();

        var file_written: usize = 0;
        while (file_written < file.size) {
            const new_written = try file.file.readAll(write_buf[buf_written..]);
            if (new_written == 0) {
                return error.UnexpectedEOF;
            }
            file_written += new_written;
            buf_written += new_written;

            if (buf_written == write_buf.len) {
                std.debug.print("Reading {s}\n", .{file.path.bytes()});
                cycle_writer.finishWrite(buf_written);
                write_buf = cycle_writer.startWrite();
                buf_written = 0;
            }
        }

        // reset file seek for next reader
        try file.file.seekTo(0);
    }
    std.debug.print("Done\n", .{});

    if (buf_written != 0) {
        cycle_writer.finishWrite(buf_written);
    } else {
        _ = cycle_writer.startWrite();
        cycle_writer.finishWrite(0);
    }
}
