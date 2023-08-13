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
    var ast = try swig.compile(view_filename);
    defer ast.deinit(swig.gpa);

    const root_nodes = try ast.getRootNodesOrPrintError();

    var out_file = try out_dir.createFile(out_path, .{});
    defer out_file.close();

    var bw = std.io.bufferedWriter(out_file.writer());
    const w = bw.writer();

    switch (root_nodes[0]) {
        .extends => |filename| {
            var base_ast = try swig.compile(filename);
            defer base_ast.deinit(swig.gpa);

            const base_nodes = try base_ast.getRootNodesOrPrintError();

            var block_table = std.StringHashMap(*Ast.Block).init(swig.gpa);
            defer block_table.deinit();

            for (base_nodes) |*node| switch (node.*) {
                .block => |*block| {
                    try block_table.put(block.name, block);
                },
                else => continue,
            };

            for (root_nodes[1..]) |node| switch (node) {
                .block => |overriding_block| {
                    const base_block = block_table.get(overriding_block.name) orelse {
                        std.debug.print("base view '{s}' has no block named '{s}'\n", .{
                            filename, overriding_block.name,
                        });
                        return error.RenderFail;
                    };
                    base_block.inside = overriding_block.inside;
                },
                else => continue,
            };

            // Iterate over the base view again, this time writing to the output.
            try renderBody(w, base_nodes, args);
        },
        else => {
            std.debug.print("expected an 'extends' node", .{});
            return error.RenderFail;
        },
    }

    try bw.flush();
}

fn renderBody(w: anytype, body: []Ast.Node, args: anytype) (@TypeOf(w).Error || error{RenderFail})!void {
    for (body) |node| switch (node) {
        .extends => unreachable,
        .block => |block| {
            try renderBody(w, block.inside, args);
        },
        .content => |text| {
            try w.writeAll(text);
        },
        .for_loop => |for_loop| {
            const fields = switch (@typeInfo(@TypeOf(args))) {
                .Struct => |s| s.fields,
                else => {
                    std.debug.print("expected args to be struct, found {s}", .{
                        @tagName(@typeInfo(@TypeOf(args))),
                    });
                    return error.RenderFail;
                },
            };
            inline for (fields) |field| {
                if (mem.eql(u8, field.name, for_loop.collection_name)) {
                    const slice = @field(args, field.name);
                    for (slice) |element| {
                        try renderBody(w, for_loop.body, element);
                    }
                    break;
                }
            } else {
                std.debug.print("no parameter named '{s}'\n", .{for_loop.collection_name});
                return error.RenderFail;
            }
        },
        .auto_escape => {
            @panic("TODO auto escape");
        },
        .ident => {
            @panic("TODO ident");
        },
        .field_access => {
            @panic("TODO field_access");
        },
        .filter => {
            @panic("TODO filter");
        },
    };
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
        for_loop: For,
        auto_escape: AutoEscape,
        ident: []const u8,
        field_access: FieldAccess,
        filter: Filter,
    };

    const FieldAccess = struct {
        lhs: *Node,
        name: []const u8,
    };

    const Filter = struct {
        lhs: *Node,
        name: []const u8,
        arg: []const u8,
    };

    const For = struct {
        capture_name: []const u8,
        collection_name: []const u8,
        body: []Node,
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

    fn getRootNodesOrPrintError(ast: *Ast) ![]Node {
        switch (ast.root) {
            .fail_msg => |msg| {
                std.debug.print("{s}\n", .{msg});
                return error.ParseFailed;
            },
            .nodes => |nodes| return nodes,
        }
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

    fn fail(parse: *Parse, comptime format: []const u8, args: anytype) Error {
        parse.fail_msg = try std.fmt.allocPrint(parse.arena, "{s}:{d}:{d}: error: " ++ format, .{
            parse.file_name, parse.line + 1, parse.column + 1,
        } ++ args);
        return error.ParseFail;
    }

    fn eatNodeStart(parse: *Parse) Error!?[]const u8 {
        if (!parse.eatBytes("{%")) return null;
        parse.skipWhiteSpace();
        const ident = try parse.expectIdentifier();
        parse.skipWhiteSpace();
        return ident;
    }

    fn eatExpr(parse: *Parse) Error!?Ast.Node {
        if (!parse.eatBytes("{{")) return null;
        parse.skipWhiteSpace();
        const expr = try parse.expectExpr();
        parse.skipWhiteSpace();
        return expr;
    }

    fn expectNodeEnd(parse: *Parse) Error!void {
        parse.skipWhiteSpace();
        if (!parse.eatBytes("%}")) return parse.fail("expected '%}}'", .{});
        parse.skipWhiteSpace();
    }

    fn eatBytes(parse: *Parse, expected_bytes: []const u8) bool {
        if (parse.index + expected_bytes.len > parse.source.len) return false;
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
                '.', '|', '}' => {
                    const ident = parse.source[start_index..parse.index];
                    return ident;
                },
                else => return parse.fail("expected letter or space", .{}),
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
                    else => return parse.fail("expected double quote", .{}),
                },
                .inside => switch (byte) {
                    '"' => {
                        parse.column += 1;
                        parse.index += 1;
                        const unparsed_string = parse.source[start_index..parse.index];
                        const parsed = std.zig.string_literal.parseAlloc(parse.arena, unparsed_string) catch |err| switch (err) {
                            error.InvalidLiteral => return parse.fail("invalid string literal", .{}),
                            else => |e| return e,
                        };
                        return parsed;
                    },
                    '\n' => return parse.fail("newline in string literal", .{}),
                    '\\' => {
                        parse.column += 1;
                        state = .escape;
                    },
                    else => {
                        parse.column += 1;
                    },
                },
                .escape => switch (byte) {
                    '\n' => return parse.fail("newline in string literal", .{}),
                    else => {
                        parse.column += 1;
                        state = .inside;
                    },
                },
            }
        }
        return parse.fail("unexpected EOF", .{});
    }

    fn expectExpr(p: *Parse) Error!Ast.Node {
        const ident_name = try p.expectIdentifier();
        p.skipWhiteSpace();
        switch (p.source[p.index]) {
            '.' => {
                p.skipForward(1);
                const field_name = try p.expectIdentifier();
                const ident_node = try p.arena.create(Ast.Node);
                ident_node.* = .{ .ident = ident_name };
                return .{ .field_access = .{
                    .lhs = ident_node,
                    .name = field_name,
                } };
            },
            '|' => @panic("TODO | expr"),
            '}' => @panic("TODO end expr"),
            else => |c| return p.fail("unexpected byte: '{c}'", .{c}),
        }
    }

    fn expectContent(parse: *Parse) Error![]Ast.Node {
        var inside: std.ArrayListUnmanaged(Ast.Node) = .{};
        var opt_text_start: ?usize = null;
        while (parse.index < parse.source.len) {
            const node_start_index = parse.index;
            if (try parse.eatNodeStart()) |node_ident| {
                if (opt_text_start) |text_start| {
                    try inside.append(parse.arena, .{ .content = parse.source[text_start..node_start_index] });
                    opt_text_start = null;
                }
                if (mem.eql(u8, node_ident, "extends")) {
                    const filename = try parse.expectStringLiteral();
                    try inside.append(parse.arena, .{ .extends = filename });
                    try parse.expectNodeEnd();
                } else if (mem.eql(u8, node_ident, "block")) {
                    const block_name = try parse.expectIdentifier();
                    try parse.expectNodeEnd();
                    const sub_content = try parse.expectContent();
                    try inside.append(parse.arena, .{ .block = .{
                        .name = block_name,
                        .inside = sub_content,
                    } });
                } else if (mem.eql(u8, node_ident, "endblock") or
                    mem.eql(u8, node_ident, "endfor"))
                {
                    try parse.expectNodeEnd();
                    return inside.items;
                } else if (mem.eql(u8, node_ident, "for")) {
                    const capture_name = try parse.expectIdentifier();
                    const in_ident = try parse.expectIdentifier();
                    if (!mem.eql(u8, in_ident, "in")) {
                        return parse.fail("expected 'in', found '{s}'", .{in_ident});
                    }
                    const collection_name = try parse.expectIdentifier();
                    try parse.expectNodeEnd();
                    const body = try parse.expectContent();
                    try inside.append(parse.arena, .{ .for_loop = .{
                        .capture_name = capture_name,
                        .collection_name = collection_name,
                        .body = body,
                    } });
                } else {
                    return parse.fail("unrecognized node name: '{s}'", .{node_ident});
                }
                continue;
            } else if (try parse.eatExpr()) |expr_node| {
                if (opt_text_start) |text_start| {
                    try inside.append(parse.arena, .{
                        .content = parse.source[text_start..node_start_index],
                    });
                    opt_text_start = null;
                }
                try inside.append(parse.arena, expr_node);
                continue;
            }

            // Look for text in between special nodes.
            if (opt_text_start == null) {
                opt_text_start = parse.index;
            }
            parse.skipForward(1);
        }

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
    var arena_instance = std.heap.ArenaAllocator.init(swig.gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const view_source = try swig.views_dir.readFileAlloc(arena, view_filename, swig.max_size);

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

    //const input = @embedFile("../views/home.html");
    const input =
        \\{% extends "base.html" %}
        \\{% block content %}
        \\<h2>Posts</h2>
        \\{% for post in posts %}
        \\<p>post</p>
        \\ <li>{{ post.date }}
        \\{% endfor %}
        \\<p>after for</p>
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
                try debugPrintNode(node, 0);
            }
        },
    }
}

fn debugPrintNode(node: Ast.Node, indent: usize) std.fs.File.WriteError!void {
    const w = std.io.getStdErr().writer();
    try w.writeByteNTimes(' ', indent);
    switch (node) {
        .extends => |name| {
            try w.print("extends '{s}'\n", .{name});
        },
        .content => |text| {
            try w.print("content '{s}'\n", .{text});
        },
        .block => |block| {
            try w.print("block '{s}'\n", .{block.name});
            for (block.inside) |sub_node| {
                try debugPrintNode(sub_node, indent + 1);
            }
        },
        .for_loop => |for_loop| {
            try w.print("for_loop '{s}' in '{s}'\n", .{
                for_loop.capture_name, for_loop.collection_name,
            });
            for (for_loop.body) |sub_node| {
                try debugPrintNode(sub_node, indent + 1);
            }
        },
        .auto_escape => |auto_escape| {
            try w.print("auto_escape {}\n", .{auto_escape.setting});
            for (auto_escape.inside) |sub_node| {
                try debugPrintNode(sub_node, indent + 1);
            }
        },
        .field_access => |field_access| {
            try w.print("field_access '{s}'\n", .{field_access.name});
            try debugPrintNode(field_access.lhs.*, indent + 1);
        },
        .filter => |filter| {
            try w.print("filter | {s}('{s}')\n", .{ filter.name, filter.arg });
            try debugPrintNode(filter.lhs.*, indent + 1);
        },
        .ident => |ident| {
            try w.print("ident '{s}'\n", .{ident});
        },
    }
}
