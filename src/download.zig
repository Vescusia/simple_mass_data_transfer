const std = @import("std");
const net = std.net;
const debug = std.debug.print;

const msgio = @import("msgio.zig");
const cryptio = @import("cryptio.zig");


pub fn download(alloc: std.mem.Allocator) !void {
    const stream = try net.tcpConnectToHost(alloc, "127.0.0.1", 5882);
    debug("Stream: {}\n", .{stream});
    defer stream.close();

    var msgwriter = try cryptio.EncryptedWriter(1 << 16, @TypeOf(stream.writer())).withSize(alloc, stream.writer(), "ZATTY"[0..], 16);
    defer msgwriter.deinit();

    try msgwriter.writeMessage("HELLOASDASDASDASDASDASDASDSAD"[0..]);
}
