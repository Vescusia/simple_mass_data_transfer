const std = @import("std");
const debug = std.debug.print;


const server = @import("server.zig").server;
const download = @import("download.zig").download;
const msgio = @import("msgio.zig");


var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const alloc = gpa.allocator();


pub fn main() !void {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        debug("Please add a command!\n", .{});
        return error.InvalidUsage;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "host")) {
        debug("HOSTING\n", .{});
        return server();
    }
    else if (std.mem.eql(u8, cmd, "dl")) {
        debug("DOWNLOADING\n", .{});
        return download();
    }
    else {
        debug("Please use either 'host' or 'dl'!\n", .{});
        return error.InvalidArguments;
    }
}
