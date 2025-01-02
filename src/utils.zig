const std = @import("std");


/// Encodes an Integer to network byte order
pub fn toNetworkBytes(into: type, num: anytype) [@sizeOf(into)]u8 {
    if (@typeInfo(@TypeOf(num)).Int.bits > @typeInfo(into).Int.bits) {
        return std.mem.toBytes(std.mem.nativeToBig(into, @truncate(num)));
    } else {
        return std.mem.toBytes(std.mem.nativeToBig(into, @intCast(num)));
    }
}
