const std = @import("std");
const path = std.fs.path;
const fs = std.fs;
const fmt = std.fmt;
const Swig = @import("./Swig.zig");
const Rss = @import("./Rss.zig");
const Allocator = std.mem.Allocator;

const Post = struct {
    filename: []const u8,
    date: []const u8,
    title: []const u8,
    content: []const u8 = undefined,
};

var post_list = [_]Post{
    .{
        .filename = "zig-cc-powerful-drop-in-replacement-gcc-clang.html",
        .date = "2020-03-24T14:39:47.141Z",
        .title = "`zig cc`: a Powerful Drop-In Replacement for GCC/Clang",
    },
    .{
        .filename = "why-donating-to-musl-libc-project.html",
        .date = "2019-06-24T20:15:06.864Z",
        .title = "Why I'm donating $150/month (10% of my income) to the musl libc project",
    },
    .{
        .filename = "zig-stack-traces-kernel-panic-bare-bones-os.html",
        .date = "2018-12-04T18:02:47.913Z",
        .title = "Using Zig to Provide Stack Traces on Kernel Panic for a Bare Bones Operating System",
    },
    .{
        .filename = "string-matching-comptime-perfect-hashing-zig.html",
        .date = "2018-09-15T16:06:33.275Z",
        .title = "String Matching based on Compile Time Perfect Hashing in Zig",
    },
    .{
        .filename = "full-time-zig.html",
        .date = "2018-06-07T14:20:30.323Z",
        .title = "I Quit My Cushy Job at OkCupid to Live on Donations to Zig",
    },
    .{
        .filename = "zig-january-2018-in-review.html",
        .date = "2018-02-11T06:54:50.195Z",
        .title = "Zig = January 2018 in Review",
    },
    .{
        .filename = "unsafe-zig-safer-than-unsafe-rust.html",
        .date = "2018-01-24T20:17:36.495Z",
        .title = "Unsafe Zig is Safer Than Unsafe Rust",
    },
    .{
        .filename = "zig-december-2017-in-review.html",
        .date = "2018-01-03T07:23:11.402Z",
        .title = "Zig: December 2017 in Review",
    },
    .{
        .filename = "a-better-way-to-implement-bit-fields.html",
        .date = "2017-02-17T00:43:53.543Z",
        .title = "A Better Way to Implement Bit Fields",
    },
    .{
        .filename = "zig-already-more-knowable-than-c.html",
        .date = "2017-02-14T04:49:59.989Z",
        .title = "Zig: Already More Knowable Than C",
    },
    .{
        .filename = "zig-programming-language-blurs-line-compile-time-run-time.html",
        .date = "2017-01-30T08:19:59.949Z",
        .title = "Zig Programming Language Blurs the Line Between Compile-Time and Run-Time",
    },
    .{
        .filename = "troubleshooting-zig-regression-apitrace.html",
        .date = "2017-01-17T23:25:58.562Z",
        .title = "Troubleshooting a Zig Regression with apitrace",
    },
    .{
        .filename = "intro-to-zig.html",
        .date = "2016-02-08T16:07:35.206Z",
        .title = "Introduction to the Zig Programming Language",
    },
    .{
        .filename = "raspberry-pi-music-player-server.html",
        .date = "2014-06-20T00:58:08.071Z",
        .title = "Turn Your Raspberry Pi into a Music Player Server",
    },
    .{
        .filename = "laptop-review-bonobo-extreme.html",
        .date = "2014-06-12T23:25:14.054Z",
        .title = "Laptop Review - Bonobo Extreme",
    },
    .{
        .filename = "quest-build-ultimate-music-player.html",
        .date = "2014-04-22T17:39:04.442Z",
        .title = "My Quest to Build the Ultimate Music Player",
    },
    .{
        .filename = "do-not-use-bodyparser-with-express-js.html",
        .date = "2013-09-06T22:37:07.244Z",
        .title = "Do Not Use bodyParser with Express.js",
    },
    .{
        .filename = "js-callback-organization.html",
        .date = "2013-08-17T04:41:14.188Z",
        .title = "JavaScript Callbacks are Pretty Okay",
    },
    .{
        .filename = "not-a-js-developer.html",
        .date = "2013-08-14T15:29:13.996Z",
        .title = "I am not a \"JavaScript Developer\".",
    },
    .{
        .filename = "7drts-game-reviews.html",
        .date = "2013-07-30T09:54:32.905Z",
        .title = "7dRTS Game Reviews",
    },
    .{
        .filename = "pillagers-7drts-game-dev-journal.html",
        .date = "2013-07-23T10:09:53.701Z",
        .title = "Pillagers! 7dRTS Game Development Journal",
    },
    .{
        .filename = "js-private-methods.html",
        .date = "2013-07-17T02:20:54.462Z",
        .title = "Private Methods in JavaScript",
    },
    .{
        .filename = "spot-the-fail.html",
        .date = "2013-07-10T21:47:20.875Z",
        .title = "Spot the Fail",
    },
    .{
        .filename = "jamulator.html",
        .date = "2013-06-07T08:48:00.721Z",
        .title = "Statically Recompiling NES Games into Native Executables with LLVM and Go",
    },
    .{
        .filename = "swig-email-templates.html",
        .date = "2013-01-30T12:00:00.000Z",
        .title = "Rapid Development Email Templates with Node.js",
    },
    .{
        .filename = "pyweek-success.html",
        .date = "2011-08-07T12:00:00.000Z",
        .title = "How to be Successful at PyWeek",
    },
    .{
        .filename = "jmt.html",
        .date = "2011-08-04T12:00:00.000Z",
        .title = "John Muir Trail from the Perspective of Andrew Kelley",
    },
    .{
        .filename = "lemming-pyweek-12.html",
        .date = "2011-04-02T12:00:00.000Z",
        .title = "Lemming - PyWeek #12 Game Development Journal",
    },
};

pub fn main() anyerror!void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = &arena_instance.allocator;

    var build_dir = try fs.cwd().makeOpenPath("www", .{});
    defer build_dir.close();

    var build_post_dir = try build_dir.makeOpenPath("post", .{});
    defer build_post_dir.close();

    var posts_dir = try fs.cwd().openDir("posts", .{});
    defer posts_dir.close();

    var swig = Swig{ .root = "views" };

    try readPostContentAndGenerateRss(arena, &swig, build_dir, posts_dir);

    try swig.render(build_dir, "index.html", "home.html", .{ .posts = post_list });
    try swig.render(build_dir, "donate/index.html", "donate.html", .{});
    for (post_list) |post| {
        try swig.render(build_post_dir, post.filename, "post.html", .{ .post = post });
    }
}

fn readPostContentAndGenerateRss(
    arena: *Allocator,
    swig: *Swig,
    build_dir: fs.Dir,
    posts_dir: fs.Dir,
) !void {
    // cache the file content for each post in memory
    // also create a list of posts ordered by date
    // also create the RSS feed
    var feed: Rss = .{
        .arena = arena,
        .title = "Andrew Kelley",
        .description = "My personal website - thoughts, project demos, research.",
        .feed_url = "http://andrewkelley.me/rss.xml",
        .site_url = "http://andrewkelley.me/",
        .image_url = "https://s3.amazonaws.com/superjoe/blog-files/profile-48x58.jpg",
        .author = "Andrew Kelley",
    };
    for (post_list) |*post, i| {
        post.content = try posts_dir.readFileAlloc(arena, post.filename, 10 * 1024 * 1024);
        if (i < 25) {
            try feed.add(.{
                .title = post.title,
                .description = post.content,
                .url = try fmt.allocPrint(arena, "http://andrewkelley.me/post/{s}", .{
                    post.filename,
                }),
                .date = post.date,
            });
        }
    }
    try feed.render(build_dir, "rss.xml");
}
