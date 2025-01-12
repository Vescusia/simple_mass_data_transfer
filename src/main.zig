const std = @import("std");
const builtin = @import("builtin");

const server = @import("server.zig").server;
const download = @import("download.zig").download;
const cryptio = @import("cryptio.zig");


// Declare SMD-Transfer Protocol Version
pub const proto_version: u8 = 3;

// Create EncryptedIO
// 1 << 20 seems to work well on my system
pub const CryptIO = cryptio.EncryptedIO(1 << 20);



pub fn main() !void {
    // create gpa
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    // get args
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print("Please add a command!\n", .{});
        return error.InvalidUsage;
    }

    const cmd = args[1];

    const thread = blk: {
        if (std.mem.eql(u8, cmd, "host")) {
            std.debug.print("HOSTING\n\n", .{});
            break :blk try std.Thread.spawn(.{ .stack_size = CryptIO.max_block_size * 32 }, server, .{ alloc });
        }
        else if (std.mem.eql(u8, cmd, "dl")) {
            std.debug.print("DOWNLOADING\n\n", .{});
            break :blk try std.Thread.spawn(.{ .stack_size = CryptIO.max_block_size * 32 }, download, .{ alloc });
        }
        else {
            std.debug.print("Please use either 'host' or 'dl'!\n", .{});
            return error.InvalidArguments;
        }
    };

    thread.join();
}
