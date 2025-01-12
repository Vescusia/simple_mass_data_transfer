const std = @import("std");
const net = std.net;

const indexing = @import("file_indexing.zig");
const shared = @import("shared.zig");
const cyclebuf = @import("cycle_buf.zig");

const main = @import("main.zig");
const proto_version = main.proto_version;
const CryptIO = main.CryptIO;


var stdout: @TypeOf(std.io.getStdOut().writer()) = undefined;
const write: bool = true;


const CycleBuffers = cyclebuf.CycleBuffers(512, CryptIO.max_block_size);

pub fn download(alloc: std.mem.Allocator) !void {
    const stream = try net.tcpConnectToHost(alloc, "127.0.0.1", 5882);
    defer stream.close();

    // get stdout
    stdout = std.io.getStdOut().writer();
    // defer finishing write
    defer std.debug.print("Disconnected from server", .{});


    // get base dir
    //const base_dir = try std.fs.realpathAlloc(alloc, "E:\\test");
    const base_dir = try std.fs.realpathAlloc(alloc, "C:\\Users\\Administrator\\Programs\\Zig\\test");
    defer alloc.free(base_dir);


    // create encrypted io
    var writer = try CryptIO.EncryptedWriter(@TypeOf(stream.writer()), "raw_key: []const u8")
        .init(stream.writer());
    var reader = try CryptIO.EncryptedReader(@TypeOf(stream.reader()), "raw_key: []const u8")
        .init(stream.reader());


    // exchange version
    try writer.putInt(proto_version); try writer.flush();
    const server_version = try reader.readInt(@TypeOf(proto_version));
    if (server_version != proto_version) {
        try stdout.print("Server is using incompatible protocol version {}\n", .{ server_version });
    } else {
        try stdout.print("Using protcol version {}\n", .{ proto_version });
    }


    // try to read a leftover smd-resume file
    if (try readSmdRes(base_dir)) |smdres| {
        // index existing files
        var local_file_index = try indexing.indexFiles(alloc, .{}, base_dir);
        // sort them to deterministic order
        local_file_index.sort();

        defer local_file_index.deinit();

        // find index of the last file of the last attempt
        if (local_file_index.binaryFind(smdres.id)) |last_i| {
            try stdout.print("Found valid .smdres\n", .{});

            // send server total amount of resume files
            try writer.putInt(@as(u64, last_i));

            // iterate over all completely finished files
            for (0..last_i) |finished_file_i| {
                try writer.putInt(local_file_index.files()[finished_file_i].id);
            }

            // send progress of last (and only incomplete) file
            const last_file = local_file_index.files()[last_i];
            try writer.putInt(last_file.id);
            try writer.putInt(last_file.already_read);
        }
        else {
            // invalid smdres
            try writer.putInt(@as(u64, 0));
        }
    }
    else {
        // send the server that we have nothing to resume
        try writer.putInt(@as(u64, 0));
    }
    try writer.flush();


    // receive updated file index from server
    var file_index = try shared.readFileIndex(alloc, &reader);
    defer file_index.deinit();
    try stdout.print("Advertised file index ends on {s} and includes {} files ({} kiB)\n", .{ file_index.files()[file_index.files().len - 1].path.bytes(), file_index.files().len, file_index.total_remaining_size / 1024 });

    if (file_index.total_remaining_size == 0) {
        try stdout.print("No need to download anything!\n", .{});
        return;
    }

    // create cycle buffers
    var cycle_bufs = try CycleBuffers.init(alloc);
    var cycle_writer = cycle_bufs.cycleWriter();
    defer cycle_bufs.deinit();


    // start file writer thread
    const file_write_thread = try std.Thread.spawn(.{}, fileWriter, .{ &file_index,  cycle_bufs.cycleReader(), base_dir});
    defer file_write_thread.join();


    // receive bytes
    var total_read: usize = 0;
    while (total_read < file_index.total_remaining_size) {
        const write_txn = cycle_writer.startWrite();
        // tell file writer that it's over
        errdefer write_txn.finish(0);

        const amt_read = try reader.readBlockToBuf(write_txn.buf());

        total_read += amt_read;
        write_txn.finish(amt_read);
    }


    // print stats
    try stdout.print("All files read\n", .{});
}


fn fileWriter(file_index: *indexing.FileIndex, raw_cycle_reader: CycleBuffers.CycleReader, base_dir_path: []const u8) !void {
    var base_dir = try std.fs.openDirAbsolute(base_dir_path, .{});

    // open all files
    for (file_index.files()) |*file| {
        if (file.path.parent()) |parent| {
            try base_dir.makePath(parent);
        }
        file.file = try base_dir.createFile(file.path.bytes(), .{});

        // initialize file to this index
        try file.file.setEndPos(file.size);
        try file.file.updateTimes(1, file.modified);
        try file.file.seekTo(file.already_read);
    }

    var cycle_reader = raw_cycle_reader;

    var read_txn = cycle_reader.startRead();
    var buf_amt_read: usize = 0;

    // TODO: writev
    // iterate over all files
    for (file_index.files()) |*file| {
        defer file.file.close();

        // handle error by writing progress to resume file
        errdefer writeSmdRes(base_dir_path, file.*);

        while (file.size > file.already_read) {
            if (buf_amt_read == read_txn.len()) {
                read_txn.finish();
                read_txn = cycle_reader.startRead();
                buf_amt_read = 0;

                // check for main thread error condition
                if (read_txn.len() == 0) {
                    return error.MainThreadPoisoned;
                }
            }

            // write
            const new_amt_written = @min(file.size - file.already_read, read_txn.len() - buf_amt_read);
            if (write) {
                try file.file.writeAll(read_txn.buf()[buf_amt_read..buf_amt_read + new_amt_written]);
            }

            file.already_read += new_amt_written;
            buf_amt_read += new_amt_written;
        }
    }

    try stdout.print("All files written\n", .{});
}


/// Write the progress of `file` to the '.smdres' File
fn writeSmdRes(base_dir_path: []const u8, file: indexing.FileIndex.FileIndexEntry) void {
    const exit = std.process.exit;
    std.debug.print("Download Failed. Trying to write progress to '.smdres'...\n", .{});

    // open base dir
    var base_dir = std.fs.openDirAbsolute(base_dir_path, .{}) catch exit(255);

    // create resume file
    var res_file = base_dir.createFile(".smdres", .{ .truncate = true }) catch exit(255);

    // encode progress
    var progress: [@sizeOf(@TypeOf(file.id)) + @sizeOf(@TypeOf(file.already_read))]u8 = undefined;
    @memcpy(progress[0..@sizeOf(@TypeOf(file.id))], std.mem.asBytes(&file.id));
    @memcpy(progress[@sizeOf(@TypeOf(file.id))..], std.mem.asBytes(&file.already_read));

    // write progress
    res_file.writeAll(&progress) catch exit(255);

    std.debug.print("Progress written. Program will crash successfully now...\n", .{});
}

/// Reads from the '.smdres' File the last file the last writer was able to write and it's progress.
fn readSmdRes(base_dir_path: []const u8) !?struct { id: u128, already_read: u64 } {
    // open base dir
    var base_dir = try std.fs.openDirAbsolute(base_dir_path, .{});

    // try to open .smdres file
    var res_file = base_dir.openFile(".smdres", .{ .mode = .read_only }) catch |err| {
        switch (err) {
            error.FileNotFound => return null,
            else => return err
        }
    };

    // read id
    var id: [@sizeOf(u128)]u8 = undefined;
    if (try res_file.readAll(&id) != id.len) {
        return error.UnexpectedEOF;
    }

    // read progress
    var already_read: [@sizeOf(u64)]u8 = undefined;
    if (try res_file.readAll(&already_read) != already_read.len) {
        return error.UnexpectedEOF;
    }

    const already_read_int = std.mem.bytesToValue(u64, &already_read);
    try stdout.print("Found .smdres of file {x} with {} kiB progress\n", .{ id, already_read_int / 1024 });
    return .{
        .id = std.mem.bytesToValue(u128, &id),
        .already_read = already_read_int
    };
}
