const std = @import("std");
const fs = std.fs;
const builtin = @import("builtin");


pub const max_path_len = 1 << 14;


pub const FileIndex = struct {
    list: std.ArrayList(FileIndexEntry),
    total_size: u64 = 0,

    pub const FileIndexEntry = struct {
        path: PathBuf,
        file: fs.File,
        id: u256,
        size: u64,
        lock: std.Thread.Mutex = std.Thread.Mutex{},

        pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;

            try std.fmt.format(writer, "'{s}': {} B - {x}\n", .{ self.path.bytes(), self.size, self.id });
        }

        fn fileMetaToId(name: []const u8, meta: fs.File.Metadata) u256 {
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

        /// * `path`: the path to the file (may be relative)
        /// * `file`: open file descriptor
        pub fn fromFile(path: PathBuf, file: fs.File) !@This() {
            const meta = try file.metadata();

            return .{
                .path = path,
                .file = file,
                .size = meta.size(),
                .id = fileMetaToId(path.name(), meta)
            };
        }
    };

    /// Recalculates the `total_size` by summing all `size`'s from the `FileIndexEntry`'s
    pub fn recalculateSize(self: *@This()) void {
        self.total_size = 0;
        for (self.list.items) |file| {
            self.total_size += file.size;
        }
    }

    pub fn rawAdd(self: *@This(), entry: FileIndexEntry) !void {
        try self.list.append(entry);
        self.total_size += entry.size;
    }

    /// Add a file, by providing a (normally *relative*) `path` and a open `file`
    pub fn addFile(self: *@This(), path: PathBuf, file: fs.File) !void {
        try self.rawAdd(try FileIndexEntry.fromFile(path, file));
    }

    /// Call `deinit` or `closeAll`
    pub fn initCapacity(alloc: std.mem.Allocator, capacity: usize) !@This() {
        return .{
            .list = try std.ArrayList(FileIndexEntry).initCapacity(alloc, capacity),
        };
    }

    /// Call `deinit` or `closeAll`
    pub fn init(alloc: std.mem.Allocator) !@This() {
        return try initCapacity(alloc, 1 << 10);
    }

    /// Will deallocate the memory, however **not** close the files.
    pub fn deinit(self: @This()) void {
        self.list.deinit();
    }

    /// Will deallocate the memory and close all files.
    pub fn closeAll(self: @This()) void {
        for (self.files()) |file| {
            file.file.close();
        }
        self.list.deinit();
    }

    pub fn files(self: @This()) []FileIndexEntry {
        return self.list.items;
    }

    /// Relativize all paths to `rel_path`
    pub fn relativizeAll(self: @This(), rel_path: []const u8) void {
        for (self.files()) |*file| {
            file.path.relativize(rel_path);
        }
    }
};


/// Assumes that `root_dir` is absolute.
///
/// Relativizes the paths to `raw_root_dir`
pub fn indexFiles(alloc: std.mem.Allocator, raw_root_dir: []const u8) !FileIndex {
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
    var file_index = try FileIndex.init(alloc);

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
                    const path = PathBuf.from(real_path);

                    try file_index.addFile(path, file);
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

    file_index.relativizeAll(root_dir.bytes());

    return file_index;
}


pub const PathBuf = struct {
    path_buf: [max_path_len]u8,
    len: usize,

    const Self = @This();

    pub fn from(path: []const u8) Self {
        std.debug.assert(max_path_len >= path.len);

        var path_buf: [max_path_len]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);

        return .{
            .path_buf = path_buf,
            .len = path.len,
        };
    }

    pub fn addSlash(self: *Self) void {
        std.debug.assert(max_path_len > self.len);

        self.path_buf[self.len] = switch (builtin.os.tag) {
            .windows => '\\',
            else => '/'
        };

        self.len += 1;
    }

    pub fn bytes(self: *const Self) []const u8 {
        return self.path_buf[0..self.len];
    }

    /// Will join `other` to `self` **without actually affecting `self`**
    pub fn join(self: *Self, other: []const u8) []const u8 {
        const total_len = self.len + other.len;
        std.debug.assert(max_path_len >= total_len);

        @memcpy(self.path_buf[self.len..total_len], other);
        return self.path_buf[0..total_len];
    }

    /// Gets the last "part" of the Path.
    /// Asserts `!lastIsSlash`
    ///
    /// "/home/example/media/.config/cache" -> "cache"
    pub fn name(self: *const Self) []const u8 {
        std.debug.assert(!self.lastIsSlash());

        for (0..self.len) |i| {
            const rev_i = self.len - i;
            const char = self.path_buf[rev_i];

            if (char == '/' or char == '\\') {
                return self.path_buf[rev_i + 1..self.len];
            }
        }
        else {
            return self.path_buf[0..self.len];
        }
    }

    /// Cuts of `parent` from `self`.
    /// Assumes that `parent` is a a part of `self`
    pub fn relativize(self: *Self, parent: []const u8) void {
        const up_to = @min(self.len, parent.len);

        // calculate up to which character the paths match
        const match_to =
            for (0.., self.path_buf[0..up_to], parent[0..up_to]) |i, self_char, parent_char| {
                if (self_char != parent_char) {
                    break i;
                }
            } else up_to;

        // copy the remaining bytes to the front
        const remaining_len = self.len - match_to;
        std.mem.copyForwards(u8, self.path_buf[0..remaining_len], self.path_buf[match_to..self.len]);
        self.len = remaining_len;
    }

    /// Asserts that `self` contains at least one character.
    pub fn lastIsSlash(self: Self) bool {
        const last = self.path_buf[self.len - 1];
        return last == '/' or last == '\\';
    }
};

test "PathBuf" {
    const assert = std.debug.assert;

    var path = PathBuf.from("/testing/src/uol.id");
    assert(std.mem.eql(u8, path.bytes(), "/testing/src/uol.id"));

    assert(std.mem.eql(u8, path.name(), "uol.id"));

    path.relativize("/testing/src/");
    assert(std.mem.eql(u8, path.bytes(), "uol.id"));

    assert(!path.lastIsSlash());
    path.addSlash();
    assert(path.lastIsSlash());

    assert(std.mem.eql(u8, "uol.id\\hoho", path.join("hoho")) or std.mem.eql(u8, "uol.id/hoho", path.join("hoho")));
}
