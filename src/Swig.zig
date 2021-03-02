const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Swig = @This();

root: []const u8,

pub fn render(
    swig: *Swig,
    out_dir: fs.Dir,
    out_path: []const u8,
    view_filename: []const u8,
    args: anytype,
) !void {
    @panic("TODO implement render()");
}
