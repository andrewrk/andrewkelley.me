const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Swig = @This();

gpa: Allocator,
views_dir: fs.Dir,
max_size: usize = 10 * 1024 * 1024,

pub fn render(
    swig: *Swig,
    out_dir: fs.Dir,
    out_path: []const u8,
    view_filename: []const u8,
    args: anytype,
) !void {
    const ast = try swig.compile(view_filename);
    _ = ast;
    _ = out_dir;
    _ = out_path;
    _ = args;
    @panic("TODO implement render()");
}

const Ast = struct {
    root: Root,
    arena_state: std.heap.ArenaAllocator.State,

    const Root = union(enum) {
        nodes: []Node,
        fail_msg: []const u8,
    };

    const Node = union(enum) {
        extends: []const u8,
        content: []const u8,
        block: Block,
        for_loop: []Node,
        auto_escape: AutoEscape,
    };

    const Block = struct {
        name: []const u8,
        inside: []Node,
    };

    const AutoEscape = struct {
        setting: bool,
        inside: []Node,
    };

    fn deinit(ast: *Ast, gpa: Allocator) void {
        ast.arena_state.promote(gpa).deinit();
        ast.* = undefined;
    }
};

const Parse = struct {
    gpa: Allocator,
    arena: Allocator,
    source: []const u8,
    index: usize,
    line: usize,
    column: usize,
    file_name: []const u8,
    top_level: std.ArrayListUnmanaged(Ast.Node),
    fail_msg: []const u8,

    const Error = error{ OutOfMemory, ParseFail };

    fn deinit(parse: *Parse) void {
        parse.top_level.deinit(parse.gpa);
    }

    fn fail(parse: *Parse, msg: []const u8) Error {
        parse.fail_msg = try std.fmt.allocPrint(parse.arena, "{s}:{d}:{d}: error: {s}", .{
            parse.file_name, parse.line, parse.column, msg,
        });
        return error.ParseFail;
    }

    fn eatNodeStart(parse: *Parse) Error!?[]const u8 {
        if (!parse.eatBytes("{%")) return null;
        parse.skipWhiteSpace();
        const ident = try parse.expectIdentifier();
        parse.skipWhiteSpace();
        return ident;
    }

    fn eatBytes(parse: *Parse, expected_bytes: []const u8) bool {
        if (parse.index + expected_bytes.len >= parse.source.len) return false;
        const source_bytes = parse.source[parse.index..][0..expected_bytes.len];
        if (!mem.eql(u8, expected_bytes, source_bytes)) return false;
        parse.skipForward(expected_bytes.len);
        return true;
    }

    fn expectIdentifier(parse: *Parse) Error![]const u8 {
        const start_index = parse.index;
        while (parse.index < parse.source.len) : (parse.index += 1) {
            switch (parse.source[parse.index]) {
                'a'...'z' => {
                    parse.column += 1;
                },
                ' ' => {
                    const ident = parse.source[start_index..parse.index];
                    parse.skipWhiteSpace();
                    return ident;
                },
                else => return parse.fail("expected letter or space"),
            }
        }
        return parse.source[start_index..parse.index];
    }

    fn expectStringLiteral(parse: *Parse) Error![]const u8 {
        const start_index = parse.index;
        var state: enum { start, inside, escape } = .start;
        while (parse.index < parse.source.len) : (parse.index += 1) {
            const byte = parse.source[parse.index];
            switch (state) {
                .start => switch (byte) {
                    '"' => {
                        parse.column += 1;
                        state = .inside;
                    },
                    else => return parse.fail("expected double quote"),
                },
                .inside => switch (byte) {
                    '"' => {
                        parse.column += 1;
                        parse.index += 1;
                        const unparsed_string = parse.source[start_index..parse.index];
                        const parsed = std.zig.string_literal.parseAlloc(parse.arena, unparsed_string) catch |err| switch (err) {
                            error.InvalidLiteral => return parse.fail("invalid string literal"),
                            else => |e| return e,
                        };
                        return parsed;
                    },
                    '\n' => return parse.fail("newline in string literal"),
                    '\\' => {
                        parse.column += 1;
                        state = .escape;
                    },
                    else => {
                        parse.column += 1;
                    },
                },
                .escape => switch (byte) {
                    '\n' => return parse.fail("newline in string literal"),
                    else => {
                        parse.column += 1;
                        state = .inside;
                    },
                },
            }
        }
        return parse.fail("unexpected EOF");
    }

    fn expectContent(parse: *Parse) Error![]Ast.Node {
        var inside: std.ArrayListUnmanaged(Ast.Node) = .{};

        while (true) {
            if (try parse.eatNodeStart()) |node_ident| {
                if (mem.eql(u8, node_ident, "extends")) {
                    const filename = try parse.expectStringLiteral();
                    try inside.append(parse.arena, .{ .extends = filename });
                } else if (mem.eql(u8, node_ident, "block")) {
                    const block_name = try parse.expectIdentifier();
                    const sub_content = try parse.expectContent();
                    try inside.append(parse.arena, .{ .block = .{
                        .name = block_name,
                        .inside = sub_content,
                    } });
                } else {
                    return parse.fail("unrecognized node name");
                }
                continue;
            }

            break;
        }

        // TODO: look for normal text

        return inside.items;
    }

    fn skipWhiteSpace(parse: *Parse) void {
        while (parse.index < parse.source.len) : (parse.index += 1) {
            switch (parse.source[parse.index]) {
                '\n' => {
                    parse.line += 1;
                    parse.column = 0;
                },
                ' ' => {
                    parse.column += 1;
                },
                else => return,
            }
        }
    }

    fn skipForward(parse: *Parse, len: usize) void {
        const new_index = parse.index + len;
        while (parse.index < new_index) : (parse.index += 1) {
            switch (parse.source[parse.index]) {
                '\n' => {
                    parse.line += 1;
                    parse.column = 0;
                },
                else => {
                    parse.column += 1;
                },
            }
        }
    }

    fn appendNode(parse: *Parse, node: Ast.Node) !void {
        try parse.top_level.append(parse.gpa, node);
    }
};

fn compile(swig: *Swig, view_filename: []const u8) !Ast {
    const view_source = try swig.views_dir.readFileAlloc(swig.gpa, view_filename, swig.max_size);
    defer swig.gpa.free(view_source);

    var arena_instance = std.heap.ArenaAllocator.init(swig.gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var parse: Parse = .{
        .gpa = swig.gpa,
        .arena = arena,
        .source = view_source,
        .file_name = view_filename,
        .line = 0,
        .column = 0,
        .index = 0,
        .top_level = .{},
        .fail_msg = undefined,
    };
    defer parse.deinit();

    const nodes = parse.expectContent() catch |err| switch (err) {
        error.ParseFail => {
            return Ast{
                .root = .{ .fail_msg = parse.fail_msg },
                .arena_state = arena_instance.state,
            };
        },
        else => |e| return e,
    };

    return Ast{
        .root = .{ .nodes = nodes },
        .arena_state = arena_instance.state,
    };
}

test "basic parsing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input =
        \\{% block content %}
        \\<h2>Posts</h2>
        \\<p>blah blah</p>
        \\{% endblock %}
    ;

    try tmp.dir.writeFile("home.html", input);

    var swig: Swig = .{
        .gpa = std.testing.allocator,
        .views_dir = tmp.dir,
    };
    var ast = try swig.compile("home.html");
    defer ast.deinit(swig.gpa);
    switch (ast.root) {
        .fail_msg => |msg| {
            std.debug.print("{s}\n", .{msg});
        },
        .nodes => |nodes| {
            std.debug.print("\n", .{});
            for (nodes) |node| {
                std.debug.print("tag={s}\n", .{@tagName(std.meta.activeTag(node))});
            }
        },
    }
}
