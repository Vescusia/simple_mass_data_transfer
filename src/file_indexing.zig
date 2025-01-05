const std = @import("std");
const fs = std.fs;
const builtin = @import("builtin");


pub const max_path_len = 1 << 14;


/// Assumes that `root_dir` is absolute.
pub fn indexFiles(alloc: std.mem.Allocator, raw_root_dir: []const u8) !std.ArrayList(FileIndexEntry) {
    std.debug.assert(raw_root_dir.len > 0);
    std.debug.assert(fs.path.isAbsolute(raw_root_dir));

    var root_dir = PathBuf.from(raw_root_dir);
    if (!root_dir.lastIsSlash()) {
        root_dir.addSlash();
    }

    // create list of directories to explore
    var dir_stack = std.ArrayList(struct { dir: fs.Dir, path: PathBuf }).init(alloc);
    defer dir_stack.deinit();

    // create file index
    var file_index = std.ArrayList(FileIndexEntry).init(alloc);

    // define OpenOptions
    const dir_open_options: fs.Dir.OpenDirOptions = .{ .iterate = true };
    const file_open_options: fs.File.OpenFlags = .{ .mode = .read_only, .lock = .none };

    // add initial directory
    try dir_stack.append(.{
        .dir = try fs.openDirAbsolute(root_dir.bytes(), dir_open_options),
        .path = root_dir
    });

    // crawl directories
    while (dir_stack.items.len > 0) {
        // get directory from stack
        var curr_dir = dir_stack.pop();
        defer curr_dir.dir.close();

        // turn into actual directory path
        if (!curr_dir.path.lastIsSlash()) {
            curr_dir.path.addSlash();
        }

        // iterate over files
        var dir_iter = curr_dir.dir.iterate();
        while (try dir_iter.next()) |entry| {
            const real_path = curr_dir.path.join(entry.name);

            switch (entry.kind) {
                .file => {
                    const file = try fs.openFileAbsolute(real_path, file_open_options);
                    const meta = try file.metadata();
                    var path = PathBuf.from(real_path);

                    try file_index.append(.{
                        .path = path.relativize(root_dir.bytes()),
                        .file = file,
                        .size = meta.size(),
                        .id = FileIndexEntry.fileStatToId(entry.name, meta),
                    });
                },
                // add directory to stack
                .directory => {
                try dir_stack.append(.{
                    .dir = try fs.openDirAbsolute(real_path, dir_open_options),
                    .path = PathBuf.from(real_path)
                });
            },
                else => { }
            }
        }
    }

    return file_index;
}


pub const FileIndexEntry = struct {
    path: PathBuf,
    file: fs.File,
    id: u256,
    size: u64,
    lock: std.Thread.Mutex = undefined,

    const Self = @This();

    pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try std.fmt.format(writer, "'{s}': {} B - {x}\n", .{ self.path.bytes(), self.size, self.id });
    }

    pub fn fileStatToId(name: []const u8, meta: fs.File.Metadata) u256 {
        var id: u256 = @intCast(meta.created() orelse 0);
        id |= @as(u128, @bitCast(meta.modified())) << (255 - @typeInfo(@TypeOf(meta.modified())).Int.bits);

        // rotate by name len
        const shft_amt: u8 = @intCast(@as(u256, name.len *% name.len) % 255);
        id = (id << shft_amt) | (id >> 255 - shft_amt);

        // pad/trim name into 16 byte array
        var name_bytes: [256/8]u8 = undefined;
        for (0..(name_bytes.len / name.len)) |copies| {
            @memcpy(name_bytes[copies * name.len..(copies + 1) * name.len], name[0..]);
        }
        @memcpy(name_bytes[name_bytes.len - @min(name.len, name_bytes.len)..], name[0..@min(name.len, name_bytes.len)]);

        id |= std.mem.bytesToValue(u256, &name_bytes);

        return id;
    }
};


pub const PathBuf = struct {
    path_buf: [max_path_len]u8,
    base_len: usize,

    const Self = @This();

    pub fn from(path: []const u8) Self {
        std.debug.assert(max_path_len >= path.len);

        var path_buf: [max_path_len]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);

        return .{
            .path_buf = path_buf,
            .base_len = path.len,
        };
    }

    pub fn addSlash(self: *Self) void {
        std.debug.assert(max_path_len > self.base_len);

        self.path_buf[self.base_len] = switch (builtin.os.tag) {
            .windows => '\\',
            else => '/'
        };

        self.base_len += 1;
    }

    pub fn bytes(self: *const Self) []const u8 {
        return self.path_buf[0..self.base_len];
    }

    pub fn join(self: *Self, name: []const u8) []u8 {
        const total_len = self.base_len + name.len;
        std.debug.assert(max_path_len >= total_len);

        @memcpy(self.path_buf[self.base_len..total_len], name);
        return self.path_buf[0..total_len];
    }

    /// Cuts of `parent` from `self`.
    /// Assumes that `parent` is a a part of `self`
    pub fn relativize(self: *Self, parent: []const u8) Self {
        const up_to = @min(self.base_len, parent.len);

        // calculate up to which character the paths match
        const match_to =
            for (0.., self.path_buf[0..up_to], parent[0..up_to]) |i, self_char, parent_char| {
                if (self_char != parent_char) {
                    break i;
                }
            } else up_to;

        // copy the remaining bytes to the front
        const remaining_len = self.base_len - match_to;
        std.mem.copyForwards(u8, self.path_buf[0..remaining_len], self.path_buf[match_to..self.base_len]);
        self.base_len = remaining_len;

        return self.*;
    }

    /// Asserts that `self` contains at least one character.
    pub fn lastIsSlash(self: Self) bool {
        const last = self.path_buf[self.base_len - 1];
        return last == '/' or last == '\\';
    }
};
