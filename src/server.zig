const std = @import("std");
const net = std.net;
const debug = std.debug.print;

const msgio = @import("msgio.zig");
const cryptio = @import("cryptio.zig");


const alloc = @import("main.zig").alloc;


pub fn server() !void {
    // instantiate address
    const address = try net.Address.parseIp("127.0.0.1", 5882);

    // create listener
    var listener = try address.listen(.{ .reuse_address = true, .reuse_port = true });


    // accept clients
    debug("Server is listening on {}!\n", .{address});
    while (true)  {
        const client = try listener.accept();
        defer client.stream.close();
        debug("Client connected: {}\n", .{client.address});

        var msgreader = try cryptio.EncryptedReader(1 << 10, @TypeOf(client.stream.reader())).init(alloc, client.stream.reader(), "ZATTY"[0..]);
        defer msgreader.deinit();

        var msg_opt = try msgreader.readMessage();
        while (msg_opt) |msg| : (msg_opt = try msgreader.readMessage()) {
            debug("{s}\n", .{msg});
        }
        else {
            debug("EOF!\n", .{});
        }
    }

    debug("Finished!", .{});
}
