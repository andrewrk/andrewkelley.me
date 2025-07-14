const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Swig = @This();
const Writer = std.Io.Writer;

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
    var arena_instance = std.heap.ArenaAllocator.init(swig.gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var map: Map = .{};
    try map.ensureUnusedCapacity(arena, @typeInfo(@TypeOf(args)).@"struct".fields.len);
    inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |field| {
        map.putAssumeCapacityNoClobber(field.name, try toValue(arena, @field(args, field.name)));
    }
    return renderMap(swig, arena, out_dir, out_path, view_filename, map);
}

fn toValue(arena: Allocator, arg: anytype) Allocator.Error!Value {
    switch (@TypeOf(arg)) {
        []u8, []const u8 => return .{ .string = arg },
        else => {},
    }
    switch (@typeInfo(@TypeOf(arg))) {
        .@"struct" => |s| {
            var map: Map = .{};
            try map.ensureUnusedCapacity(arena, s.fields.len);
            inline for (s.fields) |field| {
                map.putAssumeCapacityNoClobber(field.name, try toValue(arena, @field(arg, field.name)));
            }
            return .{ .map = map };
        },
        .pointer => @compileError("TODO pointer type erasure: " ++ @typeName(@TypeOf(arg))),
        .array => |a| {
            const list = try arena.alloc(Value, a.len);
            for (list, arg) |*dest, src| {
                dest.* = try toValue(arena, src);
            }
            return .{ .list = list };
        },
        else => @compileError("TODO type erasure code: " ++ @typeName(@TypeOf(arg))),
    }
}

const Map = std.StringHashMapUnmanaged(Value);

const Value = union(enum) {
    string: []const u8,
    list: []const Value,
    map: Map,
};

fn renderMap(
    swig: *Swig,
    arena: Allocator,
    out_dir: fs.Dir,
    out_path: []const u8,
    view_filename: []const u8,
    map: Map,
) !void {
    var ast = try swig.compile(view_filename);
    defer ast.deinit(swig.gpa);

    const root_nodes = try ast.getRootNodesOrPrintError();

    var out_file = try out_dir.createFile(out_path, .{});
    defer out_file.close();

    var buffer: [1024]u8 = undefined;
    var file_writer = out_file.writer(&buffer);
    const w = &file_writer.interface;

    var context: RenderContext = .{
        .arena = arena,
        .captures = .{},
        .auto_escape = true,
    };

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
                    base_block.parent_inside = base_block.inside;
                    base_block.inside = overriding_block.inside;
                },
                else => continue,
            };

            // Iterate over the base view again, this time writing to the output.
            try renderBody(w, &context, base_nodes, &.{}, map);
        },
        else => {
            try renderBody(w, &context, root_nodes, &.{}, map);
        },
    }

    try w.flush();
}

const RenderContext = struct {
    arena: Allocator,
    captures: Map,
    auto_escape: bool,
};

fn renderBody(
    w: *Writer,
    context: *RenderContext,
    body: []Ast.Node,
    parent_body: []Ast.Node,
    map: Map,
) error{ WriteFailed, RenderFail, OutOfMemory }!void {
    for (body) |node| switch (node) {
        .extends => unreachable,
        .block => |block| {
            try renderBody(w, context, block.inside, block.parent_inside, map);
        },
        .parent => {
            try renderBody(w, context, parent_body, &.{}, map);
        },
        .content => |text| {
            try w.writeAll(text);
        },
        .for_loop => |for_loop| {
            const value =
                context.captures.get(for_loop.collection_name) orelse
                map.get(for_loop.collection_name) orelse
                {
                    std.debug.print("no parameter named '{s}'\n", .{for_loop.collection_name});
                    return error.RenderFail;
                };
            const slice = switch (value) {
                .list => |slice| slice,
                else => {
                    std.debug.print("for loop over non-list '{s}\n", .{@tagName(value)});
                    return error.RenderFail;
                },
            };

            try context.captures.ensureUnusedCapacity(context.arena, 1);

            for (slice) |element| {
                context.captures.putAssumeCapacity(for_loop.capture_name, element);
                try renderBody(w, context, for_loop.body, parent_body, map);
                assert(context.captures.remove(for_loop.capture_name));
            }
        },
        .auto_escape => |auto_escape| {
            const prev = context.auto_escape;
            context.auto_escape = auto_escape.setting;
            try renderBody(w, context, auto_escape.inside, parent_body, map);
            context.auto_escape = prev;
        },
        .ident => |name| {
            const v = try identifier(name, map, &context.captures);
            try renderValue(w, v);
        },
        .field_access => |field_access| {
            const v = try fieldAccess(context, field_access, map);
            try renderValue(w, v);
        },
        .filter => |f| {
            const v = try evalFilter(context, f, map);
            try renderValue(w, v);
        },
    };
}

fn renderValue(w: *Writer, v: Value) !void {
    switch (v) {
        .string => |s| try w.writeAll(s),
        .list => {
            std.debug.print("cannot render list value\n", .{});
            return error.RenderFail;
        },
        .map => {
            std.debug.print("cannot render map value\n", .{});
            return error.RenderFail;
        },
    }
}

fn evalFilter(context: *RenderContext, filter: Ast.Filter, map: Map) !Value {
    const v = switch (filter.lhs.*) {
        .ident => |ident_name| try identifier(ident_name, map, &context.captures),
        .field_access => |fa| try fieldAccess(context, fa, map),
        .filter => |f| try evalFilter(context, f, map),
        else => {
            std.debug.print("field access of '{s}' node\n", .{@tagName(filter.lhs.*)});
            return error.RenderFail;
        },
    };
    if (mem.eql(u8, filter.name, "date")) {
        return evalFilterDate(context.arena, v, filter.arg);
    } else if (mem.eql(u8, filter.name, "cdata")) {
        return evalFilterCdata(context.arena, v, filter.arg);
    } else if (mem.eql(u8, filter.name, "first")) {
        return evalFilterFirst(v, filter.arg);
    } else {
        std.debug.print("unrecognized filter name: '{s}'\n", .{filter.name});
        return error.RenderFail;
    }
}

fn evalFilterDate(arena: Allocator, v: Value, arg: []const u8) !Value {
    const s = switch (v) {
        .string => |s| s,
        else => {
            std.debug.print("date filter on non-string value '{s}'\n", .{@tagName(v)});
            return error.RenderFail;
        },
    };
    const year_text = s[0..4];
    const year = std.fmt.parseInt(u16, year_text, 10) catch {
        std.debug.print("bad year: {s}\n", .{year_text});
        return error.RenderFail;
    };
    const month_text = s[5..][0..2];
    const month_1 = std.fmt.parseInt(u8, month_text, 10) catch {
        std.debug.print("bad month: {s}\n", .{month_text});
        return error.RenderFail;
    };
    if (month_1 < 1 or month_1 > 12) {
        std.debug.print("bad month (out of range): {s}\n", .{month_text});
        return error.RenderFail;
    }
    const month = month_1 - 1;
    const day_text = s[8..][0..2];
    const day = std.fmt.parseInt(u8, day_text, 10) catch {
        std.debug.print("bad day: {s}\n", .{day_text});
        return error.RenderFail;
    } - 1;
    const month_abbr = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    const hour_text = s[11..][0..2];
    const minute_text = s[14..][0..2];
    const second_text = s[17..][0..2];

    const hour = std.fmt.parseInt(u8, hour_text, 10) catch {
        std.debug.print("bad hour: {s}\n", .{hour_text});
        return error.RenderFail;
    };

    const minute = std.fmt.parseInt(u8, minute_text, 10) catch {
        std.debug.print("bad minute: {s}\n", .{minute_text});
        return error.RenderFail;
    };

    const second = std.fmt.parseInt(u8, second_text, 10) catch {
        std.debug.print("bad second: {s}\n", .{second_text});
        return error.RenderFail;
    };

    var buffer = std.ArrayList(u8).init(arena);

    for (arg) |b| {
        switch (b) {
            'D' => try buffer.appendSlice(@tagName(WeekDay.from_ymd(year, month, day))),
            'd' => try buffer.writer().print("{d:0>2}", .{day}),
            'm' => try buffer.writer().print("{d:0>2}", .{month + 1}),
            'M' => try buffer.appendSlice(month_abbr[month]),
            'Y' => try buffer.writer().print("{d:0>4}", .{year}),
            'H' => try buffer.writer().print("{d:0>2}", .{hour}),
            'i' => try buffer.writer().print("{d:0>2}", .{minute}),
            's' => try buffer.writer().print("{d:0>2}", .{second}),
            'Z' => try buffer.appendSlice("GMT"),
            else => try buffer.append(b),
        }
    }

    return .{ .string = buffer.items };
}

const WeekDay = enum {
    Sun,
    Mon,
    Tue,
    Wed,
    Thu,
    Fri,
    Sat,

    fn from_ymd(year: u32, m: u32, d: u32) WeekDay {
        return from_ymd1(year, m + 1, d);
    }
    fn from_ymd1(year: u32, m: u32, d: u32) WeekDay {
        const t = [_]u32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
        const y = year - @intFromBool(m < 3);
        return @enumFromInt((y + y / 4 - y / 100 + y / 400 + t[m - 1] + d) % 7);
    }
};

fn evalFilterCdata(arena: Allocator, v: Value, arg: []const u8) !Value {
    if (!mem.eql(u8, "", arg)) {
        std.debug.print("only the cdata filter '' is supported currently (found '{s}')\n", .{
            arg,
        });
        return error.RenderFail;
    }
    const s = switch (v) {
        .string => |s| s,
        else => {
            std.debug.print("cdata filter on non-string value '{s}'\n", .{@tagName(v)});
            return error.RenderFail;
        },
    };

    // To escape a CDATA end sequence you have to do this replacement:
    const escaped = try mem.replaceOwned(u8, arena, s, "]]>", "]]]]><![CDATA[>");

    return .{ .string = escaped };
}

fn evalFilterFirst(v: Value, arg: []const u8) !Value {
    if (!mem.eql(u8, "", arg)) {
        std.debug.print("only the first filter '' is supported currently (found '{s}')\n", .{
            arg,
        });
        return error.RenderFail;
    }
    const list = switch (v) {
        .list => |list| list,
        else => {
            std.debug.print("first filter on non-list value '{s}'\n", .{@tagName(v)});
            return error.RenderFail;
        },
    };

    return list[0];
}

fn identifier(name: []const u8, map: Map, captures: *Map) !Value {
    return captures.get(name) orelse map.get(name) orelse {
        std.debug.print("no value in scope named '{s}'\n", .{name});
        return error.RenderFail;
    };
}

fn fieldAccess(
    context: *RenderContext,
    field_access: Ast.FieldAccess,
    map: Map,
) error{ RenderFail, OutOfMemory }!Value {
    const aggregate = switch (field_access.lhs.*) {
        .ident => |ident_name| try identifier(ident_name, map, &context.captures),
        .field_access => |fa| try fieldAccess(context, fa, map),
        .filter => |f| try evalFilter(context, f, map),
        else => {
            std.debug.print("field access of '{s}' node\n", .{@tagName(field_access.lhs.*)});
            return error.RenderFail;
        },
    };

    switch (aggregate) {
        .map => |sub_map| {
            return sub_map.get(field_access.name) orelse {
                std.debug.print("map has no field named '{s}'\n", .{field_access.name});
                return error.RenderFail;
            };
        },
        else => {
            std.debug.print("field access of '{s}' value\n", .{@tagName(aggregate)});
            return error.RenderFail;
        },
    }
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
        /// Paste the parent's content here
        parent: void,
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
        // Non-overridden inside.
        parent_inside: []Node,
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
                'a'...'z', '_' => {
                    parse.column += 1;
                },
                ' ' => {
                    const ident = parse.source[start_index..parse.index];
                    parse.skipWhiteSpace();
                    return ident;
                },
                '.', '|', '}', '(', ')' => {
                    const ident = parse.source[start_index..parse.index];
                    return ident;
                },
                else => |c| return parse.fail("expected letter or space, found '{c}'", .{c}),
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
        return p.finishExpr(.{ .ident = ident_name });
    }

    fn finishExpr(p: *Parse, lhs: Ast.Node) Error!Ast.Node {
        const result: Ast.Node = switch (p.source[p.index]) {
            '.' => r: {
                p.skipForward(1);
                const field_name = try p.expectIdentifier();
                break :r .{ .field_access = .{
                    .lhs = blk: {
                        const copy = try p.arena.create(Ast.Node);
                        copy.* = lhs;
                        break :blk copy;
                    },
                    .name = field_name,
                } };
            },
            '|' => r: {
                p.skipForward(1);
                p.skipWhiteSpace();
                const filter_name = try p.expectIdentifier();
                if (!p.eatBytes("(")) return p.fail("expected '('", .{});
                const arg = try p.expectStringLiteral();
                if (!p.eatBytes(")")) return p.fail("expected ')'", .{});

                break :r .{ .filter = .{
                    .lhs = blk: {
                        const copy = try p.arena.create(Ast.Node);
                        copy.* = lhs;
                        break :blk copy;
                    },
                    .name = filter_name,
                    .arg = arg,
                } };
            },
            '}' => lhs,
            else => |c| return p.fail("expected '.', '|', or '}}', found '{c}'", .{c}),
        };

        p.skipWhiteSpace();

        if (p.eatBytes("}}"))
            return result;

        return p.finishExpr(result);
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
                        .parent_inside = sub_content,
                    } });
                } else if (mem.eql(u8, node_ident, "autoescape")) {
                    const on_or_off = try parse.expectIdentifier();
                    const setting = if (mem.eql(u8, on_or_off, "on"))
                        true
                    else if (mem.eql(u8, on_or_off, "off"))
                        false
                    else
                        return parse.fail("expected 'on' or 'off', found '{s}'", .{on_or_off});

                    try parse.expectNodeEnd();
                    const sub_content = try parse.expectContent();
                    try inside.append(parse.arena, .{ .auto_escape = .{
                        .setting = setting,
                        .inside = sub_content,
                    } });
                } else if (mem.eql(u8, node_ident, "endblock") or
                    mem.eql(u8, node_ident, "endfor") or
                    mem.eql(u8, node_ident, "endautoescape"))
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
                } else if (mem.eql(u8, node_ident, "parent")) {
                    try inside.append(parse.arena, .parent);
                    try parse.expectNodeEnd();
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

        if (opt_text_start) |text_start| {
            try inside.append(parse.arena, .{
                .content = parse.source[text_start..],
            });
            opt_text_start = null;
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
        \\ <li>{{ post.date | date("Y M d") }}</li>
        \\{% endfor %}
        \\<p>after for</p>
        \\{% endblock %}
        \\<p>after end block</p>
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
        .parent => {
            try w.print("parent\n", .{});
        },
    }
}
