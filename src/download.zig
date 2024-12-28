const std = @import("std");
const net = std.net;
const debug = std.debug.print;

const msgio = @import("msgio.zig");
const cryptio = @import("cryptio.zig");

const alloc = @import("main.zig").alloc;


pub fn download() !void {
    const stream = try net.tcpConnectToHost(alloc, "localhost", 5882);
    debug("Stream: {}\n", .{stream});
    defer stream.close();

    var msgwriter = try cryptio.EncryptedWriter(1 << 10, @TypeOf(stream.writer())).init(alloc, stream.writer(), "ZATTY"[0..]);

    try msgwriter.writeMessage("HELLO?"[0..]);
}
