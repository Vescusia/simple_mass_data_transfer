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
    working_dir = try std.fs.realpathAlloc(alloc, "C:\\Users\\Administrator\\Programs\\Zig\\simple_mass_data_transfer");
    defer alloc.free(working_dir);


    // index files
    var file_index = try indexing.indexFiles(alloc, .{ .mode = .read_only, .lock = .shared }, working_dir);
    defer file_index.closeAll();
    try stdout.print("Working in {s}, containing {} files ({} kiB)\n", .{ working_dir, file_index.files().len, file_index.total_size / 1024 });

    // main loop
    try stdout.print("Server is listening on {} with protocol version {}\n", .{ address, proto_version });
    while (true)  {
        // accept client
        const client = try listener.accept();
        try stdout.print("Client<{}> connected!\n", .{ client.address });

        // handle client
        try handle_client(alloc, client, file_index);

        break;
    }
}


/// All allocated memory will be freed by the end of this function
fn handle_client(alloc: std.mem.Allocator, client: net.Server.Connection, file_index: indexing.FileIndex) !void {
    defer client.stream.close();
    defer std.debug.print("Client<{}> disconnected.\n", .{client.address});

    // create encrypted io
    var writer = try CryptIO.EncryptedWriter(@TypeOf(client.stream.writer()), "raw_key: []const u8")
        .init(client.stream.writer());
    var reader = try CryptIO.EncryptedReader(@TypeOf(client.stream.reader()), "raw_key: []const u8")
        .init(client.stream.reader()) orelse return;


    // start timer
    const complete_start = try std.time.Instant.now();


    // exchange version
    try writer.putInt(proto_version); try writer.flush();
    const client_version = try reader.readInt(@TypeOf(proto_version)) orelse return;
    if (client_version != proto_version) {
        try stdout.print("{}: using invalid protocol version {}\n", .{ client.address, client_version });
    }
    else {
        try stdout.print("Correct protocol version\n", .{});
    }


    // receive client progress file index
    const client_index = try shared.readFileIndex(alloc, &reader) orelse return;
    defer client_index.deinit();

    // TODO: combine


    // send combined file index
    try shared.writeFileIndex(&writer, file_index);
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
        const read = cycle_reader.startRead();
        //std.debug.print("Writing\n", .{});
        defer cycle_reader.finishRead();

        try writer.writeBufToBlock(read);

        if (read.len < CryptIO.max_block_size) {
            break;
        }
    }


    // join with file reader
    try stdout.print("All files sent\n", .{});
    file_read_thread.join();


    // print stats
    const elapsed_s: f64 = @as(f64, @floatFromInt((try std.time.Instant.now()).since(complete_start))) / @as(f64, @floatFromInt(std.time.ns_per_s));
    const pure_elapsed_s: f64 = @as(f64, @floatFromInt((try std.time.Instant.now()).since(pure_start))) / @as(f64, @floatFromInt(std.time.ns_per_s));
    try stdout.print("{} kiB in {e} s ({d} min) ({d} kiB/s (pure: {d} kiB/s))\n", .{
        file_index.total_size / 1024,
        elapsed_s, elapsed_s / 60,
        @round(@as(f64, @floatFromInt(file_index.total_size / 1024)) / elapsed_s),
        @round(@as(f64, @floatFromInt(file_index.total_size / 1024)) / pure_elapsed_s)
    });
}


fn fileReader(file_index: indexing.FileIndex, raw_cycle_writer: CycleBuf.CycleWriter) !void {
    defer std.debug.print("All files read\n", .{});

    var cycle_writer = raw_cycle_writer;

    var write_buf = cycle_writer.startWrite();
    var buf_amt_written: usize = 0;

    for (file_index.files()) |*file| {
        // aquire file mutex
        file.lock.lock();
        defer file.lock.unlock();

        var file_amt_read: usize = 0;
        while (file_amt_read < file.size) {
            const new_amt_read = try file.file.readAll(write_buf[buf_amt_written..]);
            if (new_amt_read == 0) {
                return error.UnexpectedEOF;
            }
            file_amt_read += new_amt_read;
            buf_amt_written += new_amt_read;

            if (buf_amt_written == write_buf.len) {
                //std.debug.print("Reading {s}\n", .{file.path.bytes()});
                cycle_writer.finishWrite(buf_amt_written);
                write_buf = cycle_writer.startWrite();
                buf_amt_written = 0;
            }
        }

        // reset file seek for next reader
        try file.file.seekTo(0);
    }

    if (buf_amt_written != 0) {
        cycle_writer.finishWrite(buf_amt_written);
    } else {
        _ = cycle_writer.startWrite();
        cycle_writer.finishWrite(0);
    }
}
