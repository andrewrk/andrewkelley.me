const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Rss = @This();

arena: *Allocator,
title: []const u8,
description: []const u8,
feed_url: []const u8,
site_url: []const u8,
image_url: []const u8,
author: []const u8,

pub const Item = struct {
    title: []const u8,
    description: []const u8,
    url: []const u8,
    date: []const u8,
};

pub fn add(rss: *Rss, item: Item) !void {
    @panic("TODO implement Rss.add()");
}

pub fn render(rss: *Rss, dir: fs.Dir, sub_path: []const u8) !void {
    @panic("TODO implement Rss.render()");
}
