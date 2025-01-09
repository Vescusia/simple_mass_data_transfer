const std = @import("std");
const net = std.net;

const indexing = @import("file_indexing.zig");
const shared = @import("shared.zig");
const cyclebuf = @import("cycle_buf.zig");

const main = @import("main.zig");
const proto_version = main.proto_version;
const CryptIO = main.CryptIO;


const write: bool = true;


const CycleBuffers = cyclebuf.CycleBuffers(512, CryptIO.max_block_size);

pub fn download(alloc: std.mem.Allocator) !void {
    const stream = try net.tcpConnectToHost(alloc, "127.0.0.1", 5882);
    defer stream.close();


    // get stdout
    var stdout = std.io.getStdOut().writer();
    // defer finishing write
    defer std.debug.print("Disconnected from server", .{});


    // get base dir
    //const base_dir = try std.fs.realpathAlloc(alloc, "E:\\test");
    const base_dir = try std.fs.realpathAlloc(alloc, "C:\\Users\\Administrator\\Programs\\Zig\\test1");
    defer alloc.free(base_dir);


    // create encrypted io
    var writer = try CryptIO.EncryptedWriter(@TypeOf(stream.writer()), "raw_key: []const u8")
        .init(stream.writer());
    var reader = try CryptIO.EncryptedReader(@TypeOf(stream.reader()), "raw_key: []const u8")
        .init(stream.reader()) orelse return;


    // exchange version
    try writer.putInt(proto_version); try writer.flush();
    const server_version = try reader.readInt(@TypeOf(proto_version)) orelse return;
    if (server_version != proto_version) {
        try stdout.print("Server is using incompatible protocol version {}\n", .{ server_version });
    } else {
        try stdout.print("Using protcol version {}\n", .{ proto_version });
    }


    // create file index
    const current_file_index = try indexing.indexFiles(alloc, .{}, base_dir);
    defer current_file_index.deinit();

    // send file index
    try shared.writeFileIndex(&writer, current_file_index);
    try writer.flush();


    // receive updated file index from server
    var file_index = try shared.readFileIndex(alloc, &reader) orelse return;
     defer file_index.deinit();
    try stdout.print("Advertised file index includes {} files ({} kiB)\n", .{ file_index.files().len, file_index.total_size / 1024 });


    // create cycle buffers
    var cycle_bufs = try CycleBuffers.init(alloc);
    var cycle_writer = cycle_bufs.cycleWriter();
    defer cycle_bufs.deinit();

    // start file writer thread
    const file_write_thread = try std.Thread.spawn(.{}, fileWriter, .{ &file_index,  cycle_bufs.cycleReader(), base_dir});


    // receive bytes
    var total_read: usize = 0;
    while (total_read < file_index.total_size) {
        const write_txn = cycle_writer.startWrite();
        const amt_read = try reader.readBlockToBuf(write_txn.buf()) orelse return;

        total_read += amt_read;
        write_txn.finish(amt_read);
    }


    // join with file writer
    try stdout.print("All files read\n", .{});
    file_write_thread.join();
}


fn fileWriter(file_index: *indexing.FileIndex, raw_cycle_reader: CycleBuffers.CycleReader, base_dir_path: []const u8) !void {
    defer std.debug.print("All files written\n", .{});

    var base_dir = try std.fs.openDirAbsolute(base_dir_path, .{});

    // open all files
    for (file_index.files()) |*file| {
        if (file.path.parent()) |parent| {
            try base_dir.makePath(parent);
        }
        file.file = try base_dir.createFile(file.path.bytes(), .{ .truncate = true });
    }

    var cycle_reader = raw_cycle_reader;

    var read_txn = cycle_reader.startRead();
    var buf_amt_read: usize = 0;

    // TODO: writev
    for (file_index.files()) |*file| {
        file.lock.lock();
        defer file.lock.unlock();
        defer file.file.close();

        var file_amt_written: usize = 0;
        while (file_amt_written < file.size) {
            if (buf_amt_read == read_txn.len()) {
                //std.debug.print("Finishing Write to File\n", .{});
                read_txn.finish();
                read_txn = cycle_reader.startRead();
                buf_amt_read = 0;
            }

            const new_amt_written = @min(file.size - file_amt_written, read_txn.len() - buf_amt_read);
            if (write) {
                try file.file.writeAll(read_txn.buf()[buf_amt_read..buf_amt_read + new_amt_written]);
            }

            file_amt_written += new_amt_written;
            buf_amt_read += new_amt_written;
        }

        try file.file.updateTimes(1, file.modified);
    }
}
