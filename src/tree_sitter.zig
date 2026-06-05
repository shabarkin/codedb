const std = @import("std");

pub const tree_sitter_language_version: u32 = 15;
pub const tree_sitter_min_compatible_language_version: u32 = 13;

pub const Grammar = enum {
    c,
    cpp,
    rust,
    typescript,
    tsx,
    python,
    go,
    dart,
    php,
    hcl,
    r,
    ruby,
};

pub const TSLanguage = opaque {};
pub const TSParser = opaque {};
pub const TSTree = opaque {};

pub const TSPoint = extern struct {
    row: u32,
    column: u32,
};

pub const TSNode = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const TSTree,
};

pub const TSTreeCursor = extern struct {
    tree: ?*const anyopaque,
    id: ?*const anyopaque,
    context: [3]u32,
};

extern fn ts_parser_new() ?*TSParser;
extern fn ts_parser_delete(self: *TSParser) void;
extern fn ts_parser_set_language(self: *TSParser, language: *const TSLanguage) bool;
extern fn ts_parser_parse_string(self: *TSParser, old_tree: ?*const TSTree, string: [*]const u8, length: u32) ?*TSTree;
extern fn ts_tree_delete(self: *TSTree) void;
extern fn ts_tree_root_node(self: *const TSTree) TSNode;
extern fn ts_node_type(self: TSNode) [*:0]const u8;
extern fn ts_node_start_byte(self: TSNode) u32;
extern fn ts_node_start_point(self: TSNode) TSPoint;
extern fn ts_node_end_byte(self: TSNode) u32;
extern fn ts_node_end_point(self: TSNode) TSPoint;
extern fn ts_node_is_null(self: TSNode) bool;
extern fn ts_node_is_named(self: TSNode) bool;
extern fn ts_node_named_child_count(self: TSNode) u32;
extern fn ts_node_named_child(self: TSNode, child_index: u32) TSNode;
extern fn ts_node_child_by_field_name(self: TSNode, name: [*]const u8, name_length: u32) TSNode;
extern fn ts_language_abi_version(self: *const TSLanguage) u32;
extern fn ts_tree_cursor_new(node: TSNode) TSTreeCursor;
extern fn ts_tree_cursor_delete(self: *TSTreeCursor) void;
extern fn ts_tree_cursor_current_node(self: *const TSTreeCursor) TSNode;
extern fn ts_tree_cursor_current_depth(self: *const TSTreeCursor) u32;
extern fn ts_tree_cursor_goto_parent(self: *TSTreeCursor) bool;
extern fn ts_tree_cursor_goto_next_sibling(self: *TSTreeCursor) bool;
extern fn ts_tree_cursor_goto_first_child(self: *TSTreeCursor) bool;

extern fn tree_sitter_c() *const TSLanguage;
extern fn tree_sitter_cpp() *const TSLanguage;
extern fn tree_sitter_rust() *const TSLanguage;
extern fn tree_sitter_typescript() *const TSLanguage;
extern fn tree_sitter_tsx() *const TSLanguage;
extern fn tree_sitter_python() *const TSLanguage;
extern fn tree_sitter_go() *const TSLanguage;
extern fn tree_sitter_dart() *const TSLanguage;
extern fn tree_sitter_php() *const TSLanguage;
extern fn tree_sitter_hcl() *const TSLanguage;
extern fn tree_sitter_r() *const TSLanguage;
extern fn tree_sitter_ruby() *const TSLanguage;

fn grammarLanguage(grammar: Grammar) *const TSLanguage {
    return switch (grammar) {
        .c => tree_sitter_c(),
        .cpp => tree_sitter_cpp(),
        .rust => tree_sitter_rust(),
        .typescript => tree_sitter_typescript(),
        .tsx => tree_sitter_tsx(),
        .python => tree_sitter_python(),
        .go => tree_sitter_go(),
        .dart => tree_sitter_dart(),
        .php => tree_sitter_php(),
        .hcl => tree_sitter_hcl(),
        .r => tree_sitter_r(),
        .ruby => tree_sitter_ruby(),
    };
}

pub const ParseError = error{
    IncompatibleLanguage,
    OutOfMemory,
    ParseFailed,
    SourceTooLong,
};

pub const Parser = struct {
    raw: *TSParser,

    pub fn init(grammar: Grammar) ParseError!Parser {
        const raw = ts_parser_new() orelse return error.OutOfMemory;
        errdefer ts_parser_delete(raw);
        if (!ts_parser_set_language(raw, grammarLanguage(grammar))) return error.IncompatibleLanguage;
        return .{ .raw = raw };
    }

    pub fn initRust() ParseError!Parser {
        return init(.rust);
    }

    pub fn initC() ParseError!Parser {
        return init(.c);
    }

    pub fn initCpp() ParseError!Parser {
        return init(.cpp);
    }

    pub fn initTypeScript() ParseError!Parser {
        return init(.typescript);
    }

    pub fn initTsx() ParseError!Parser {
        return init(.tsx);
    }

    pub fn initPython() ParseError!Parser {
        return init(.python);
    }

    pub fn initGo() ParseError!Parser {
        return init(.go);
    }

    pub fn initDart() ParseError!Parser {
        return init(.dart);
    }

    pub fn initPhp() ParseError!Parser {
        return init(.php);
    }

    pub fn initHcl() ParseError!Parser {
        return init(.hcl);
    }

    pub fn initR() ParseError!Parser {
        return init(.r);
    }

    pub fn initRuby() ParseError!Parser {
        return init(.ruby);
    }

    pub fn deinit(self: *Parser) void {
        ts_parser_delete(self.raw);
    }

    pub fn parseString(self: *Parser, source: []const u8) ParseError!Tree {
        const length = std.math.cast(u32, source.len) orelse return error.SourceTooLong;
        const raw = ts_parser_parse_string(self.raw, null, source.ptr, length) orelse return error.ParseFailed;
        return .{ .raw = raw };
    }
};

pub const Tree = struct {
    raw: *TSTree,

    pub fn deinit(self: *Tree) void {
        ts_tree_delete(self.raw);
    }

    pub fn rootNode(self: *const Tree) TSNode {
        return ts_tree_root_node(self.raw);
    }
};

pub fn rustLanguage() *const TSLanguage {
    return grammarLanguage(.rust);
}

pub fn cLanguageVersion() u32 {
    return grammarVersion(.c);
}

pub fn cppLanguageVersion() u32 {
    return grammarVersion(.cpp);
}

pub fn rustLanguageVersion() u32 {
    return grammarVersion(.rust);
}

pub fn grammarVersion(grammar: Grammar) u32 {
    return ts_language_abi_version(grammarLanguage(grammar));
}

pub fn typescriptLanguageVersion() u32 {
    return grammarVersion(.typescript);
}

pub fn tsxLanguageVersion() u32 {
    return grammarVersion(.tsx);
}

pub fn pythonLanguageVersion() u32 {
    return grammarVersion(.python);
}

pub fn goLanguageVersion() u32 {
    return grammarVersion(.go);
}

pub fn dartLanguageVersion() u32 {
    return grammarVersion(.dart);
}

pub fn phpLanguageVersion() u32 {
    return grammarVersion(.php);
}

pub fn hclLanguageVersion() u32 {
    return grammarVersion(.hcl);
}

pub fn rLanguageVersion() u32 {
    return grammarVersion(.r);
}

pub fn rubyLanguageVersion() u32 {
    return grammarVersion(.ruby);
}

pub fn nodeType(node: TSNode) []const u8 {
    return std.mem.span(ts_node_type(node));
}

pub fn nodeStartByte(node: TSNode) u32 {
    return ts_node_start_byte(node);
}

pub fn nodeEndByte(node: TSNode) u32 {
    return ts_node_end_byte(node);
}

pub fn nodeStartPoint(node: TSNode) TSPoint {
    return ts_node_start_point(node);
}

pub fn nodeEndPoint(node: TSNode) TSPoint {
    return ts_node_end_point(node);
}

pub fn nodeIsNull(node: TSNode) bool {
    return ts_node_is_null(node);
}

pub fn namedChildCount(node: TSNode) u32 {
    return ts_node_named_child_count(node);
}

pub fn namedChild(node: TSNode, child_index: u32) TSNode {
    return ts_node_named_child(node, child_index);
}

pub fn childByFieldName(node: TSNode, field_name: []const u8) ?TSNode {
    const child = ts_node_child_by_field_name(node, field_name.ptr, @intCast(field_name.len));
    return if (ts_node_is_null(child)) null else child;
}

fn writeIndent(writer: anytype, depth: u32) !void {
    var i: u32 = 0;
    while (i < depth) : (i += 1) try writer.writeAll("  ");
}

fn writeCurrentNode(writer: anytype, cursor: *TSTreeCursor) !void {
    const node = ts_tree_cursor_current_node(cursor);
    if (!ts_node_is_named(node)) return;
    try writeIndent(writer, ts_tree_cursor_current_depth(cursor));
    try writer.print("{s} [{d},{d})\n", .{
        nodeType(node),
        ts_node_start_byte(node),
        ts_node_end_byte(node),
    });
}

pub fn dumpNamedNodes(writer: anytype, root: TSNode) !void {
    var cursor = ts_tree_cursor_new(root);
    defer ts_tree_cursor_delete(&cursor);

    try writeCurrentNode(writer, &cursor);

    while (true) {
        if (ts_tree_cursor_goto_first_child(&cursor)) {
            try writeCurrentNode(writer, &cursor);
            continue;
        }
        if (ts_tree_cursor_goto_next_sibling(&cursor)) {
            try writeCurrentNode(writer, &cursor);
            continue;
        }

        while (ts_tree_cursor_goto_parent(&cursor)) {
            if (ts_tree_cursor_goto_next_sibling(&cursor)) {
                try writeCurrentNode(writer, &cursor);
                break;
            }
        } else {
            return;
        }
    }
}
