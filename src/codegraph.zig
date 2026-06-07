//! codegraph.zig — deterministic resolved call graph (Phase 1 foundation).
//!
//! codedb already has the two ingredients a precise call graph needs: the parser
//! emits function symbols with line ranges, and `symbol_index` maps a name to its
//! definition sites. What was missing is the middle step — walking call sites and
//! resolving them — which this module provides, deterministically and without an
//! LLM. (Mirrors graphify's `extract.py` walk_calls + symbol-resolution facts, but
//! in codedb's fast/local model.)
//!
//! The graph is the foundation for: centrality-boosted ranking, edge-aware
//! context expansion, and community detection. It is always an ADDITIVE signal —
//! never a filter — so a misresolved edge can never drop a real result.

const std = @import("std");

pub const NodeId = u32;

/// A resolved call edge `from` → `to`. `weight` splits 1.0 across the candidate
/// definitions of an ambiguous callee name (1 candidate → 1.0), so a name that
/// resolves cleanly contributes full weight and an ambiguous one is discounted.
pub const Edge = struct {
    from: NodeId,
    to: NodeId,
    weight: f32,
};

pub const FuncInput = struct {
    id: NodeId,
    /// The function's body text (caller slices it from content via line ranges).
    body: []const u8,
};

/// True for identifiers that precede `(` but are language keywords / control flow,
/// not callees — so `if (`, `for (`, `while (`, `catch (`, `return (` etc. are not
/// counted as calls. Deliberately a cross-language superset (codedb indexes ~40
/// languages); over-filtering a rare real call only loses an additive boost.
fn isCallKeyword(name: []const u8) bool {
    const kws = [_][]const u8{
        "if",     "else",  "for",      "while", "switch", "return", "catch",
        "try",    "defer", "errdefer", "and",   "or",     "orelse", "sizeof",
        "typeof", "do",    "case",     "when",  "match",  "with",   "in",
        "not",    "is",    "await",    "yield", "throw",  "new",    "delete",
        "fn",     "func",  "function", "def",   "class",  "struct", "enum",
        "union",  "const", "var",      "let",   "static", "assert", "where",
        "select", "from",  "foreach",  "using", "unless", "until",  "elif",
    };
    for (kws) |kw| if (std.mem.eql(u8, name, kw)) return true;
    return false;
}

inline fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
inline fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// Extract deduped callee identifier names that appear as call sites (`ident(`)
/// in a function body. The identifier immediately preceding an unmatched `(` is
/// the candidate callee (`obj.foo(` yields `foo`; `a[i](` yields nothing). Items
/// are slices into `body`; caller frees the returned array.
pub fn extractCallees(allocator: std.mem.Allocator, body: []const u8) ![][]const u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '(') continue;
        // Skip spaces/tabs between the identifier and the '('.
        var end = i;
        while (end > 0 and (body[end - 1] == ' ' or body[end - 1] == '\t')) end -= 1;
        // Walk back over identifier characters.
        var start = end;
        while (start > 0 and isIdentChar(body[start - 1])) start -= 1;
        if (start == end) continue; // nothing before '(' (e.g. `(expr)`, `)(`)
        const name = body[start..end];
        if (!isIdentStart(name[0])) continue; // started on a digit → not an ident
        if (isCallKeyword(name)) continue;
        const g = try seen.getOrPut(name);
        if (!g.found_existing) try out.append(allocator, name);
    }
    return out.toOwnedSlice(allocator);
}

/// Build resolved call edges for a set of functions. `resolve` maps a callee name
/// to the node ids of its candidate definitions (codedb's `symbol_index`). Edge
/// weight is split across candidates; self-edges are dropped unless `allow_self`.
pub fn buildEdges(
    allocator: std.mem.Allocator,
    funcs: []const FuncInput,
    resolve: *const std.StringHashMap([]const NodeId),
    allow_self: bool,
) !std.ArrayList(Edge) {
    var edges: std.ArrayList(Edge) = .empty;
    errdefer edges.deinit(allocator);
    for (funcs) |f| {
        const callees = try extractCallees(allocator, f.body);
        defer allocator.free(callees);
        for (callees) |name| {
            const cands = resolve.get(name) orelse continue;
            if (cands.len == 0) continue;
            const w: f32 = 1.0 / @as(f32, @floatFromInt(cands.len));
            for (cands) |to| {
                if (!allow_self and to == f.id) continue;
                try edges.append(allocator, .{ .from = f.id, .to = to, .weight = w });
            }
        }
    }
    return edges;
}

/// Weighted in-degree centrality: how much a node is called by others. This is
/// the "god node" signal (graphify's most-connected nodes) and the additive
/// boost we fold into ranking in Phase 2.
pub fn inDegreeCentrality(allocator: std.mem.Allocator, edges: []const Edge, n_nodes: usize) ![]f32 {
    const c = try allocator.alloc(f32, n_nodes);
    @memset(c, 0);
    for (edges) |e| {
        if (e.to < n_nodes) c[e.to] += e.weight;
    }
    return c;
}
