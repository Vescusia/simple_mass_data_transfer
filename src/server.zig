const std = @import("std");
const net = std.net;
const debug = std.debug.print;

const msgio = @import("msgio.zig");
const cryptio = @import("cryptio.zig");
const indexing = @import("file_indexing.zig");
const utils = @import("utils.zig");

const main = @import("main.zig");
const proto_version = main.proto_version;
const max_msg_len = main.max_msg_len;


pub fn server(alloc: std.mem.Allocator) !void {
    // instantiate io
    var stdout = std.io.getStdOut().writer();
    var stdin = std.io.getStdIn().reader();

    // instantiate address
    const address = try net.Address.parseIp("127.0.0.1", 5882);

    // create listener
    var listener = try address.listen(.{ .reuse_address = true, .reuse_port = true });

    // index files
    const file_index = try indexing.indexFiles(alloc, ".");
    defer file_index.deinit();

    // main loop
    try stdout.print("Server is listening on {} with protocol version {s}\n", .{ address, proto_version });
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
    defer debug("Client<{}> disconnected.\n", .{client.address});

    // create encrypted io
    const writer = cryptio.EncryptedMessageWriter(@TypeOf(client.stream.writer()), max_msg_len, "raw_key: []const u8")
        .init(client.stream.writer());
    var reader = cryptio.EncryptedMessageReader(@TypeOf(client.stream.reader()), max_msg_len, "raw_key: []const u8")
        .init(client.stream.reader());

    // starting timer
    const start = try std.time.Instant.now();

    _ = alloc;
    _ = writer;
    _ = file_index;

    // exchange version
    var msg_opt = try reader.readMessage();
    while (msg_opt) |msg| : (msg_opt = try reader.readMessage()) {
        _ = msg;
    }

    // receive file progress


    // send files in index


    // print stats
    const elapsed: f64 = @as(f64, @floatFromInt((try std.time.Instant.now()).since(start))) / @as(f64, @floatFromInt(std.time.ns_per_s));
    debug("Time taken: {e} s ({e} min)\n", .{ elapsed, elapsed / 60 });
}
