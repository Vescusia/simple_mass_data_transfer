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
    const EncryptedIO = cryptio.EncryptedIO(max_msg_len, @TypeOf(stream), "raw_key: []const u8");
    var writer = EncryptedIO.writer(stream.writer());
    var reader = try EncryptedIO.reader(alloc, stream.reader());
    defer reader.deinit();

    // exchange version
    debug("Using protocol version {s}\n", .{ proto_version });
    try writer.writeMessage(proto_version);
    if (!std.mem.eql(u8, try reader.readMessage() orelse return, proto_version)) {
        debug("Server is using icompatible protocol version.", .{});
        return;
    }
}
