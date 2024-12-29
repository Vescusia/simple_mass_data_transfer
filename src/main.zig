const std = @import("std");
const debug = std.debug.print;


const server = @import("server.zig").server;
const download = @import("download.zig").download;
const msgio = @import("msgio.zig");


pub fn main() !void {
    // create gpa
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    // get args
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        debug("Please add a command!\n", .{});
        return error.InvalidUsage;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "host")) {
        debug("HOSTING\n", .{});
        return server(alloc);
    }
    else if (std.mem.eql(u8, cmd, "dl")) {
        debug("DOWNLOADING\n", .{});
        return download(alloc);
    }
    else {
        debug("Please use either 'host' or 'dl'!\n", .{});
        return error.InvalidArguments;
    }
}
