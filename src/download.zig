const std = @import("std");
const net = std.net;

const cryptio = @import("cryptio.zig");
const indexing = @import("file_indexing.zig");

const main = @import("main.zig");
const proto_version = main.proto_version;
const max_msg_len = main.max_msg_len;


pub fn download(alloc: std.mem.Allocator) !void {
    const stream = try net.tcpConnectToHost(alloc, "127.0.0.1", 5882);
    defer stream.close();

    defer std.debug.print("Disconnected from server", .{});

    // create encrypted io
    var writer = cryptio.EncryptedWriter(@TypeOf(stream.writer()), max_msg_len, "raw_key: []const u8")
        .init(stream.writer());
    var reader = cryptio.EncryptedReader(@TypeOf(stream.reader()), max_msg_len, "raw_key: []const u8")
       .init(stream.reader());

    // exchange version
    try writer.putInt(proto_version); try writer.flush();
    const server_version = try reader.readInt(@TypeOf(proto_version)) orelse return;
    if (server_version != proto_version) {
        std.debug.print("Server is using incompatible protocol version {}\n", .{ server_version });
    } else {
        std.debug.print("Using protcol version {}\n", .{ proto_version });
    }

    // create file index
    const index_len = try reader.readInt(u64) orelse return;
    std.debug.print("Advertised file index includes {} files.\n", .{index_len});
    var file_index = try std.ArrayList(indexing.FileIndexEntry).initCapacity(alloc, @as(usize, index_len));
    defer file_index.deinit();

    // send saved file index

    // receive new or updated files
    var size_sum: u64 = 0;
    for (0..index_len) |i| {
        try file_index.append(.{
            .id = try reader.readInt(u256) orelse return,
            .size = try reader.readInt(u64) orelse return,
            .path = indexing.PathBuf.from(try reader.readMessage() orelse return),
            .file = undefined,
            .lock = undefined
        });
        size_sum += file_index.items[i].size;
    }

    // integrate new and updated files
    std.debug.print("Total size: {} kiB\n", .{ size_sum / 1024 });

    // receive bytes
    var total_read: usize = 0;
    while (try reader.readMessage()) |msg| {
        total_read += msg.len;
    }
    std.debug.print("Received {}\n", .{total_read / 1024});
}
