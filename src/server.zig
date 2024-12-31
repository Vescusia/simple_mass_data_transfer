const std = @import("std");
const net = std.net;
const debug = std.debug.print;

const msgio = @import("msgio.zig");
const cryptio = @import("cryptio.zig");


const max_msg_len = 32;


pub fn server(alloc: std.mem.Allocator) !void {
    // instantiate io
    var stdout = std.io.getStdOut().writer();
    var stdin = std.io.getStdIn().reader();

    // instantiate address
    const address = try net.Address.parseIp("127.0.0.1", 5882);

    // create listener
    var listener = try address.listen(.{ .reuse_address = true, .reuse_port = true });

    // index files

    // main loop
    try stdout.print("Server is listening on {}!\n", .{address});
    while (true)  {
        // accept client
        const client = try listener.accept();
        try stdout.print("Client<{}> connected!\n", .{client.address});

        // handle client
        try handle_client(alloc, client);

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
fn handle_client(alloc: std.mem.Allocator, client: net.Server.Connection) !void {
    defer client.stream.close();
    defer debug("Client<{}> disconnected.\n", .{client.address});

    // create encrypted io
    var reader = try cryptio.EncryptedReader(max_msg_len, @TypeOf(client.stream)).init(alloc, client.stream, "raw_key: []const u8");
    defer reader.deinit();

    const start = try std.time.Instant.now();
    var msg_opt = try reader.readMessage();
    while (msg_opt) |msg| : (msg_opt = try reader.readMessage()) {
        _ = msg;
    }
    const end = try std.time.Instant.now();
    debug("Time taken: {}\n", .{@as(f64, @floatFromInt(end.since(start))) / @as(f64, @floatFromInt(std.time.ns_per_s))});
}
