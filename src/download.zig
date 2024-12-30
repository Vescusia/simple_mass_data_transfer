const std = @import("std");
const net = std.net;
const debug = std.debug.print;

const msgio = @import("msgio.zig");
const cryptio = @import("cryptio.zig");


const max_msg_len = 32;


pub fn download(alloc: std.mem.Allocator) !void {
    const stream = try net.tcpConnectToHost(alloc, "127.0.0.1", 5882);
    debug("Stream: {}\n", .{stream});
    defer stream.close();

    // create encrypted io
    const encrypted_io = cryptio.EncryptedIO(max_msg_len, @TypeOf(stream), "raw_key: []const u8");
    var writer = encrypted_io.writer(stream.writer());

    // write message
    for (0..128) |_| {
        try writer.writeMessage(" ty"[0..]);
    }
}
