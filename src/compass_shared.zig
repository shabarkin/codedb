const std = @import("std");
const explore_mod = @import("explore.zig");

pub fn isContextIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

pub fn isContextIdentCont(c: u8) bool {
    return isContextIdentStart(c) or (c >= '0' and c <= '9');
}

pub fn looksLikeContextIdentifier(tok: []const u8) bool {
    if (tok.len < 3) return false;
    if (std.mem.indexOfScalar(u8, tok, '_') != null) return true;

    var all_upper = true;
    for (tok) |c| {
        if (c < 'A' or c > 'Z') {
            all_upper = false;
            break;
        }
    }
    if (all_upper) return tok.len <= 8;

    var i: usize = 1;
    while (i < tok.len) : (i += 1) {
        const prev_lower = tok[i - 1] >= 'a' and tok[i - 1] <= 'z';
        const cur_upper = tok[i] >= 'A' and tok[i] <= 'Z';
        if (prev_lower and cur_upper) return true;
    }
    return false;
}

pub fn extractContextCandidates(
    task: []const u8,
    alloc: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    max_candidates: usize,
) void {
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    var i: usize = 0;
    while (i < task.len) {
        const c = task[i];
        if (c == '"' or c == '`') {
            const q = c;
            const start = i + 1;
            var j = start;
            while (j < task.len and task[j] != q) : (j += 1) {}
            if (j > start and j - start <= 64 and j - start >= 3) {
                const slice = task[start..j];
                if (!seen.contains(slice)) {
                    seen.put(slice, {}) catch {};
                    out.append(alloc, slice) catch {};
                    if (out.items.len >= max_candidates) return;
                }
            }
            i = j + 1;
            continue;
        }

        if (isContextIdentStart(c)) {
            const start = i;
            while (i < task.len and isContextIdentCont(task[i])) : (i += 1) {}
            const tok = task[start..i];
            if (tok.len >= 3 and tok.len <= 64 and looksLikeContextIdentifier(tok) and !seen.contains(tok)) {
                seen.put(tok, {}) catch {};
                out.append(alloc, tok) catch {};
                if (out.items.len >= max_candidates) return;
            }
            continue;
        }
        i += 1;
    }
}

pub fn isTestLikePath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "tests/") or
        std.mem.startsWith(u8, path, "test/") or
        std.mem.indexOf(u8, path, "/test") != null or
        std.mem.indexOf(u8, path, "_test.") != null or
        std.mem.indexOf(u8, path, ".test.") != null or
        std.mem.indexOf(u8, path, "/__tests__/") != null or
        std.mem.indexOf(u8, path, "/spec/") != null or
        std.mem.indexOf(u8, path, "/fixtures/") != null;
}

pub fn isDocLikePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or
        std.mem.endsWith(u8, path, ".rst") or
        std.mem.indexOf(u8, path, "/docs/") != null;
}

pub fn scoreContextFile(path: []const u8, hits: u32, has_symbol_def: bool) i32 {
    var score: i32 = @intCast(hits);
    if (has_symbol_def) score += 5;
    if (isTestLikePath(path)) score -= 3;
    if (isDocLikePath(path)) score -= 2;
    return score;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

pub fn hasWholeWordMatch(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, search_from, needle)) |pos| {
        const before_ok = pos == 0 or !isIdentChar(haystack[pos - 1]);
        const after_idx = pos + needle.len;
        const after_ok = after_idx >= haystack.len or !isIdentChar(haystack[after_idx]);
        if (before_ok and after_ok) return true;
        search_from = pos + 1;
    }
    return false;
}

pub fn langHasCallSites(lang: explore_mod.Language) bool {
    return switch (lang) {
        .markdown, .json, .yaml, .css, .scss, .protobuf, .unknown => false,
        else => true,
    };
}
