const std = @import("std");

const main = @import("main.zig");
const indexing = @import("file_indexing.zig");
const cryptio = @import("cryptio.zig");


/// Writer will **not** be explicitly flushed within this function
pub fn writeFileIndex(msg_writer: anytype, file_index: indexing.FileIndex) !void {
    // send file index length
    try msg_writer.putInt(@as(u64, file_index.files().len));

    // send files
    for (file_index.files()) |file| {
        try msg_writer.putInt(file.id);
        try msg_writer.putInt(file.size);
        try msg_writer.putInt(file.already_read);
        try msg_writer.writeMessage(file.path.bytes());
        try msg_writer.putInt(file.modified);
    }
}

/// The files in the returned `FileIndex` will **not** be open
///
/// File index needs to be deallocated using `deinit`
pub fn readFileIndex(alloc: std.mem.Allocator, msg_reader: anytype) !indexing.FileIndex {
    // receive file index length
    const index_len = try msg_reader.readInt(u64);
    var file_index = try indexing.FileIndex.initCapacity(alloc, @as(usize, index_len));

    // receive files
    for (0..index_len) |_| {
        try file_index.addRaw(.{
            .id = try msg_reader.readInt(u128),
            .size = try msg_reader.readInt(u64),
            .already_read = try msg_reader.readInt(u64),
            .path = indexing.PathBuf.from(try msg_reader.readMessage()),
            .modified = try msg_reader.readInt(i128),
            .file = undefined,
        });
    }

    return file_index;
}
