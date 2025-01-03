const std = @import("std");
const net = std.net;
const debug = std.debug.print;

const msgio = @import("msgio.zig");
const cryptio = @import("cryptio.zig");

const main = @import("main.zig");
const proto_version = main.proto_version;
const max_msg_len = main.max_msg_len;


pub fn download(alloc: std.mem.Allocator) !void {
    const stream = try net.tcpConnectToHost(alloc, "127.0.0.1", 5882);
    defer stream.close();

    // create encrypted io
    var writer = cryptio.EncryptedMessageWriter(@TypeOf(stream.writer()), max_msg_len, "raw_key: []const u8")
        .init(stream.writer());
    // var reader = cryptio.EncryptedMessageReader(@TypeOf(stream.reader()), max_msg_len, "raw_key: []const u8")
       // .init(stream.reader());

    // exchange version
    const msg: [max_msg_len]u8 = undefined;
    for (0..128) |_| {
        try writer.writeMessage(&msg);
    }
}
