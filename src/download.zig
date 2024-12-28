const std = @import("std");
const net = std.net;
const debug = std.debug.print;

const msgio = @import("msgio.zig");

const alloc = @import("main.zig").alloc;


pub fn download() !void {
    const stream = try net.tcpConnectToHost(alloc, "localhost", 5882);
    debug("Stream: {}\n", .{stream});
    defer stream.close();

    var msgwriter = try msgio.MessageWriter(u16, @TypeOf(stream.writer())).init(stream.writer());

    const msgs = [_][]const u8 {"ZATTA1\n"[0..7], "ZATTAY2"[0..8], "ZATTAYY3\n"[0..8]};
    try msgwriter.write_multiple(alloc, &msgs);
}
