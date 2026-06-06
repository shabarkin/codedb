const std = @import("std");
const Store = @import("store.zig").Store;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const AgentId = @import("agent.zig").AgentId;
const Explorer = @import("explore.zig").Explorer;
const Op = @import("version.zig").Op;
const path_security = @import("path_security.zig");
const Language = @import("explore.zig").Language;
const detectLanguage = @import("explore.zig").detectLanguage;

pub const EditRequest = struct {
    path: []const u8,
    agent_id: AgentId,
    op: Op,
    range: ?[2]usize = null,
    after: ?usize = null,
    content: ?[]const u8 = null,
    if_hash: ?[]const u8 = null,
    dry_run: bool = false,
};

pub const EditResult = struct {
    seq: u64,
    new_hash: u64,
    new_size: u64,
    changed: bool = true,
    /// Unified-diff-style preview of the change. Only populated when
    /// `dry_run = true`. Caller owns the slice and must free it.
    preview: ?[]u8 = null,
    /// Advisory post-edit syntax warning (e.g. unbalanced delimiter) or null
    /// when the edited content looks structurally clean. Caller owns the slice
    /// and must free it. (trial/graph-based-codedb)
    health: ?[]u8 = null,
};

pub fn applyEdit(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *Store,
    agents: *AgentRegistry,
    explorer: ?*Explorer,
    req: EditRequest,
) !EditResult {
    const has_lock = try agents.tryLock(req.agent_id, req.path, 30_000);
    if (!has_lock) return error.FileLocked;
    errdefer agents.releaseLock(req.agent_id, req.path);

    if (!path_security.isPathSafe(req.path) or path_security.isSensitivePath(req.path)) return error.AccessDenied;

    // Validate required op-specific args BEFORE doing any work that
    // mutates Store.seq or rewrites the file (#401).
    switch (req.op) {
        .replace, .delete => if (req.range == null) return error.InvalidRange,
        .insert => if (req.after == null) return error.InvalidRange,
        else => {},
    }
    const edit_dir = if (explorer) |exp| exp.root_dir orelse std.Io.Dir.cwd() else std.Io.Dir.cwd();
    const root_real: []const u8 = if (explorer) |exp| exp.root_real else &.{};

    const source = if (root_real.len > 0)
        try path_security.readFileAlloc(io, edit_dir, root_real, req.path, allocator, .limited(10 * 1024 * 1024))
    else
        try edit_dir.readFileAlloc(io, req.path, allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(source);

    if (req.if_hash) |expected_hex| {
        const actual = std.hash.Wyhash.hash(0, source);
        var hash_buf: [16]u8 = undefined;
        const actual_hex = std.fmt.bufPrint(&hash_buf, "{x}", .{actual}) catch return error.HashMismatch;
        if (!std.mem.eql(u8, expected_hex, actual_hex)) return error.HashMismatch;
    }

    if (!req.dry_run and req.op == .replace) {
        const range = req.range.?;
        const new_content = req.content orelse return error.MissingContent;
        if (range[0] == 1 and std.mem.eql(u8, source, new_content) and fileLineCount(source) <= range[1]) {
            const hash = std.hash.Wyhash.hash(0, source);
            const seq = store.currentSeq();
            agents.releaseLock(req.agent_id, req.path);
            return .{
                .seq = seq,
                .new_hash = hash,
                .new_size = source.len,
                .changed = false,
            };
        }
    }

    if (!req.dry_run and req.op == .replace) {
        const range = req.range.?;
        const new_content = req.content orelse return error.MissingContent;
        if (new_content.len > 0) {
            const fast_result = try buildReplaceResultFast(allocator, source, range, new_content);
            defer allocator.free(fast_result);
            const hash = std.hash.Wyhash.hash(0, fast_result);

            if (std.mem.eql(u8, source, fast_result)) {
                const seq = store.currentSeq();
                agents.releaseLock(req.agent_id, req.path);
                return .{
                    .seq = seq,
                    .new_hash = hash,
                    .new_size = fast_result.len,
                    .changed = false,
                };
            }

            const health_msg = try describeHealth(allocator, fast_result, detectLanguage(req.path));
            errdefer if (health_msg) |h| allocator.free(h);

            try writeAtomic(io, edit_dir, req.path, fast_result);

            const seq = try store.recordEdit(req.path, req.agent_id, req.op, hash, fast_result.len, req.content);
            if (explorer) |exp| {
                try exp.indexFile(req.path, fast_result);
            }

            agents.releaseLock(req.agent_id, req.path);
            return .{
                .seq = seq,
                .new_hash = hash,
                .new_size = fast_result.len,
                .health = health_msg,
            };
        }
    }

    // Detect line-ending style: if the file has any "\r\n", treat it as
    // CRLF and rejoin with CRLF (#404). Strip the trailing '\r' from
    // each split chunk so the in-memory representation is uniform.
    const is_crlf = std.mem.indexOf(u8, source, "\r\n") != null;
    const sep: []const u8 = if (is_crlf) "\r\n" else "\n";

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| {
        const trimmed = if (is_crlf and line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        try lines.append(allocator, trimmed);
    }

    // A trailing newline produces an empty final element; don't count it as a line
    const had_trailing_newline = lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0;
    if (had_trailing_newline) {
        _ = lines.pop();
    }

    switch (req.op) {
        .replace => {
            const range = req.range.?;
            if (range[0] == 0 or range[1] < range[0] or range[0] > lines.items.len) return error.InvalidRange;
            const start = range[0] - 1;
            const end = @min(range[1], lines.items.len);
            const new_content = req.content orelse return error.MissingContent;
            var new_lines: std.ArrayList([]const u8) = .empty;
            defer new_lines.deinit(allocator);
            var ni = std.mem.splitScalar(u8, new_content, '\n');
            while (ni.next()) |nl| {
                const trimmed = if (is_crlf and nl.len > 0 and nl[nl.len - 1] == '\r') nl[0 .. nl.len - 1] else nl;
                try new_lines.append(allocator, trimmed);
            }
            try lines.replaceRange(allocator, start, end - start, new_lines.items);
        },
        .insert => {
            const after_line = req.after.?;
            const pos = @min(after_line, lines.items.len);
            const content = req.content orelse return error.MissingContent;
            try lines.insert(allocator, pos, content);
        },
        .delete => {
            const range = req.range.?;
            if (range[0] == 0 or range[1] < range[0] or range[0] > lines.items.len) return error.InvalidRange;
            const start = range[0] - 1;
            const end = @min(range[1], lines.items.len);
            // Remove lines [start..end) by replacing with nothing
            try lines.replaceRange(allocator, start, end - start, &.{});
        },
        else => {},
    }

    // Restore trailing newline if the original file had one — but not when
    // the operation reduced the buffer to truly empty content (#409).
    const result_is_empty = lines.items.len == 0 or (lines.items.len == 1 and lines.items[0].len == 0);
    if (had_trailing_newline and !result_is_empty) {
        try lines.append(allocator, "");
    }

    const result = if (result_is_empty)
        try allocator.dupe(u8, "")
    else
        try std.mem.join(allocator, sep, lines.items);
    defer allocator.free(result);

    const hash: u64 = std.hash.Wyhash.hash(0, result);

    if (!req.dry_run and std.mem.eql(u8, source, result)) {
        const seq = store.currentSeq();
        agents.releaseLock(req.agent_id, req.path);
        return .{
            .seq = seq,
            .new_hash = hash,
            .new_size = result.len,
            .changed = false,
        };
    }

    // Post-edit syntax health (trial/graph-based-codedb): a cheap, advisory
    // delimiter-balance scan so a mis-spliced multi-line edit (orphaned/
    // duplicated bracket) surfaces back to the agent instead of shipping a
    // file that no longer parses.
    const health_msg = try describeHealth(allocator, result, detectLanguage(req.path));
    errdefer if (health_msg) |h| allocator.free(h);

    if (req.dry_run) {
        // Preview-only: build a compact diff and skip disk write, store record,
        // and explorer indexing. Caller releases the lock via errdefer/return.
        const preview = try buildPreview(allocator, source, result, req);
        agents.releaseLock(req.agent_id, req.path);
        return .{
            .seq = 0,
            .new_hash = hash,
            .new_size = result.len,
            .preview = preview,
            .health = health_msg,
        };
    }

    try writeAtomic(io, edit_dir, req.path, result);

    // KNOWN LIMITATION: if recordEdit fails here, the file is already on disk but not
    // in the store. This leaves the disk and store inconsistent. Recovery would require
    // re-reading the file and re-recording, or a crash-recovery scan at startup.
    const seq = try store.recordEdit(req.path, req.agent_id, req.op, hash, result.len, req.content);
    if (explorer) |exp| {
        try exp.indexFile(req.path, result);
    }

    agents.releaseLock(req.agent_id, req.path);

    return .{
        .seq = seq,
        .new_hash = hash,
        .new_size = result.len,
        .health = health_msg,
    };
}

fn writeAtomic(io: std.Io, dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    var atomic_file = try dir.createFileAtomic(io, path, .{
        .replace = true,
    });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, content);
    try atomic_file.replace(io);
}

fn fileLineCount(source: []const u8) usize {
    if (source.len == 0) return 0;
    var count = std.mem.count(u8, source, "\n");
    if (source[source.len - 1] != '\n') count += 1;
    return count;
}

fn buildReplaceResultFast(
    allocator: std.mem.Allocator,
    source: []const u8,
    range: [2]usize,
    new_content: []const u8,
) ![]u8 {
    if (range[0] == 0 or range[1] < range[0]) return error.InvalidRange;

    const is_crlf = std.mem.indexOf(u8, source, "\r\n") != null;
    const sep: []const u8 = if (is_crlf) "\r\n" else "\n";

    var line_count: usize = 0;
    if (source.len > 0) {
        line_count = std.mem.count(u8, source, "\n");
        if (source[source.len - 1] != '\n') line_count += 1;
    }
    if (range[0] > line_count) return error.InvalidRange;

    var start_off: ?usize = if (range[0] == 1) 0 else null;
    var end_off: ?usize = null;
    var cur_line: usize = 1;
    for (source, 0..) |c, i| {
        if (c != '\n') continue;
        if (cur_line == range[1]) {
            end_off = i + 1;
            break;
        }
        cur_line += 1;
        if (cur_line == range[0] and start_off == null) {
            start_off = i + 1;
        }
    }

    const start = start_off orelse return error.InvalidRange;
    const end = end_off orelse source.len;
    const suffix = source[end..];
    const content_ends_line = new_content.len > 0 and new_content[new_content.len - 1] == '\n';

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, source.len + new_content.len + sep.len);
    try out.appendSlice(allocator, source[0..start]);
    try appendNormalizedReplacement(allocator, &out, new_content, sep);
    if (suffix.len > 0 and !content_ends_line) {
        try out.appendSlice(allocator, sep);
    }
    try out.appendSlice(allocator, suffix);
    return out.toOwnedSlice(allocator);
}

fn appendNormalizedReplacement(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    content: []const u8,
    sep: []const u8,
) !void {
    var first = true;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        if (!first) try out.appendSlice(allocator, sep);
        first = false;
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        try out.appendSlice(allocator, line);
    }
}

/// Build a compact unified-diff-style preview showing the affected range with up
/// to 3 lines of context on each side, removed lines prefixed with `-`, added
/// lines prefixed with `+`. Caller owns the returned slice.
fn buildPreview(
    allocator: std.mem.Allocator,
    before_bytes: []const u8,
    after_bytes: []const u8,
    req: EditRequest,
) ![]u8 {
    const ctx_lines: usize = 3;

    var before_lines: std.ArrayList([]const u8) = .empty;
    defer before_lines.deinit(allocator);
    var bi = std.mem.splitScalar(u8, before_bytes, '\n');
    while (bi.next()) |line| try before_lines.append(allocator, line);
    if (before_lines.items.len > 0 and before_lines.items[before_lines.items.len - 1].len == 0) {
        _ = before_lines.pop();
    }

    var after_lines: std.ArrayList([]const u8) = .empty;
    defer after_lines.deinit(allocator);
    var ai = std.mem.splitScalar(u8, after_bytes, '\n');
    while (ai.next()) |line| try after_lines.append(allocator, line);
    if (after_lines.items.len > 0 and after_lines.items[after_lines.items.len - 1].len == 0) {
        _ = after_lines.pop();
    }

    // Identify the changed range in 1-indexed line numbers (before file).
    var b_start: usize = 1;
    var b_end: usize = before_lines.items.len;
    var a_start: usize = 1;
    switch (req.op) {
        .replace => if (req.range) |r| {
            b_start = r[0];
            b_end = r[1];
            a_start = r[0];
        },
        .delete => if (req.range) |r| {
            b_start = r[0];
            b_end = r[1];
            a_start = r[0];
        },
        .insert => if (req.after) |after| {
            b_start = after + 1;
            b_end = after; // empty before-range
            a_start = after + 1;
        },
        else => {},
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const ctx_before_start = if (b_start > ctx_lines + 1) b_start - ctx_lines else 1;
    const ctx_after_end = @min(b_end + ctx_lines, before_lines.items.len);

    const before_hunk_len = ctx_after_end -| ctx_before_start + 1;
    const removed: usize = if (req.op == .delete or req.op == .replace) (b_end -| b_start + 1) else 0;
    const before_count = before_lines.items.len;
    const after_count = after_lines.items.len;
    const added_total = if (after_count + removed > before_count) after_count + removed - before_count else 0;
    const after_hunk_len = before_hunk_len -| removed + added_total;

    var hdr_buf: [128]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "@@ -{d},{d} +{d},{d} @@\n", .{
        ctx_before_start,
        before_hunk_len,
        ctx_before_start,
        after_hunk_len,
    });
    try buf.appendSlice(allocator, hdr);

    // Leading context (unchanged lines before the change)
    var i: usize = ctx_before_start;
    while (i < b_start and i <= before_lines.items.len) : (i += 1) {
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, before_lines.items[i - 1]);
        try buf.append(allocator, '\n');
    }

    // Removed lines from before
    if (req.op == .replace or req.op == .delete) {
        var j: usize = b_start;
        while (j <= b_end and j <= before_lines.items.len) : (j += 1) {
            try buf.append(allocator, '-');
            try buf.appendSlice(allocator, before_lines.items[j - 1]);
            try buf.append(allocator, '\n');
        }
    }

    // Added lines from after (replace + insert)
    if (req.op == .replace or req.op == .insert) {
        const inserted_count: usize = added_total;
        var k: usize = a_start;
        const stop = @min(a_start + inserted_count, after_lines.items.len + 1);
        while (k < stop) : (k += 1) {
            try buf.append(allocator, '+');
            try buf.appendSlice(allocator, after_lines.items[k - 1]);
            try buf.append(allocator, '\n');
        }
    }

    // Trailing context (unchanged lines after the change)
    var t: usize = b_end + 1;
    while (t <= ctx_after_end) : (t += 1) {
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, before_lines.items[t - 1]);
        try buf.append(allocator, '\n');
    }

    return buf.toOwnedSlice(allocator);
}

// ── Post-edit syntax health check (trial/graph-based-codedb) ──────────────
//
// codedb_edit is a blind line-splice: historically it never checked whether
// the resulting file still parsed. The deep-SWE benchmark showed Sonnet-4.6
// routinely regenerates a multi-line bracketed region (a parenthesized import
// block or a function signature + body) and mis-splices the hunk boundaries,
// leaving an orphaned/duplicated delimiter — shipping a file that does not
// even import. The scan below is a cheap, dependency-free, language-aware
// delimiter-balance pass that surfaces such breaks back to the agent.

const Imbalance = struct {
    line: usize,
    open_char: u8,
    found_char: u8,
    kind: enum { unmatched_close, unclosed_open, mismatched },
};

/// Languages where a ()/[]/{} balance scan is meaningful and low-noise.
/// Deliberately excludes shell (case-pattern `)`), ruby (%w[] / heredocs),
/// sql, css and markup, where false positives would be common.
fn isCheckableCode(lang: Language) bool {
    return switch (lang) {
        .python, .javascript, .typescript, .zig, .c, .cpp, .rust, .go_lang, .java, .kotlin, .swift, .dart, .php => true,
        else => false,
    };
}

/// Scan `content` for the first unbalanced ()/[]/{} delimiter, skipping
/// language-appropriate comments and string / char literals. Advisory only:
/// returns null (stay silent) for unsupported languages or anything it cannot
/// analyse confidently (nesting deeper than the fixed stack).
fn scanDelimiterBalance(content: []const u8, language: Language) ?Imbalance {
    if (!isCheckableCode(language)) return null;

    const py = language == .python;
    const php = language == .php;
    const hash_comments = py or php;
    const slash_comments = !py; // // line + /* */ block for every c-like lang here
    const sq_is_string = py or php or language == .javascript or language == .typescript;
    const backtick = language == .javascript or language == .typescript;
    const zig_lang = language == .zig;

    var stack: [512]struct { ch: u8, line: usize } = undefined;
    var sp: usize = 0;
    var line: usize = 1;
    var i: usize = 0;
    const n = content.len;

    while (i < n) {
        const ch = content[i];
        if (ch == '\n') {
            line += 1;
            i += 1;
            continue;
        }

        // Zig multi-line string: a `\\`-prefixed line runs to EOL with no closer.
        if (zig_lang and ch == '\\' and i + 1 < n and content[i + 1] == '\\') {
            while (i < n and content[i] != '\n') i += 1;
            continue;
        }

        // Line comments.
        if (hash_comments and ch == '#') {
            while (i < n and content[i] != '\n') i += 1;
            continue;
        }
        if (slash_comments and ch == '/' and i + 1 < n and content[i + 1] == '/') {
            while (i < n and content[i] != '\n') i += 1;
            continue;
        }
        // Block comment /* ... */
        if (slash_comments and ch == '/' and i + 1 < n and content[i + 1] == '*') {
            i += 2;
            while (i + 1 < n and !(content[i] == '*' and content[i + 1] == '/')) {
                if (content[i] == '\n') line += 1;
                i += 1;
            }
            i = @min(i + 2, n);
            continue;
        }

        // Triple-quoted Python string.
        if (py and (ch == '"' or ch == '\'') and i + 2 < n and content[i + 1] == ch and content[i + 2] == ch) {
            const q = ch;
            i += 3;
            while (i + 2 < n and !(content[i] == q and content[i + 1] == q and content[i + 2] == q)) {
                if (content[i] == '\n') line += 1;
                if (content[i] == '\\') i += 1;
                i += 1;
            }
            i = @min(i + 3, n);
            continue;
        }

        // Backtick template literal (JS/TS): may span newlines; skip wholesale.
        if (backtick and ch == '`') {
            i += 1;
            while (i < n and content[i] != '`') {
                if (content[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (content[i] == '\n') line += 1;
                i += 1;
            }
            i = @min(i + 1, n);
            continue;
        }

        // Double-quoted string (single line).
        if (ch == '"') {
            i += 1;
            while (i < n and content[i] != '"') {
                if (content[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (content[i] == '\n') break; // unterminated; bail conservatively
                i += 1;
            }
            if (i < n and content[i] == '"') i += 1;
            continue;
        }

        // Single quote: a string (py/php/js/ts) or a char literal (c-family).
        if (ch == '\'') {
            if (sq_is_string) {
                i += 1;
                while (i < n and content[i] != '\'') {
                    if (content[i] == '\\') {
                        i += 2;
                        continue;
                    }
                    if (content[i] == '\n') break;
                    i += 1;
                }
                if (i < n and content[i] == '\'') i += 1;
                continue;
            }
            // Char literal: only consume as a literal if a closing ' is near
            // (<= 12 bytes). Otherwise it is a Rust lifetime (&'a) or a label —
            // leave it as plain punctuation so we do not eat real delimiters.
            var j = i + 1;
            const cap = @min(n, i + 13);
            var closed = false;
            while (j < cap) {
                if (content[j] == '\\') {
                    j += 2;
                    continue;
                }
                if (content[j] == '\'') {
                    closed = true;
                    break;
                }
                if (content[j] == '\n') break;
                j += 1;
            }
            if (closed) {
                i = j + 1;
                continue;
            }
            i += 1;
            continue;
        }

        switch (ch) {
            '(', '[', '{' => {
                if (sp == stack.len) return null; // too deep to analyse; stay silent
                stack[sp] = .{ .ch = ch, .line = line };
                sp += 1;
            },
            ')', ']', '}' => {
                const want: u8 = switch (ch) {
                    ')' => '(',
                    ']' => '[',
                    '}' => '{',
                    else => 0,
                };
                if (sp == 0) return .{ .line = line, .open_char = 0, .found_char = ch, .kind = .unmatched_close };
                if (stack[sp - 1].ch != want) return .{ .line = line, .open_char = stack[sp - 1].ch, .found_char = ch, .kind = .mismatched };
                sp -= 1;
            },
            else => {},
        }
        i += 1;
    }

    if (sp > 0) return .{ .line = stack[sp - 1].line, .open_char = stack[sp - 1].ch, .found_char = 0, .kind = .unclosed_open };
    return null;
}

/// Returns an owned advisory message when the edited content has a delimiter
/// imbalance, else null. Caller frees. Pure helper — exposed for tests.
pub fn describeHealth(allocator: std.mem.Allocator, content: []const u8, language: Language) !?[]u8 {
    const imb = scanDelimiterBalance(content, language) orelse return null;
    return switch (imb.kind) {
        .unmatched_close => try std.fmt.allocPrint(allocator, "\n⚠ syntax check: unmatched '{c}' at line {d} — this edit may have broken the file; re-read and verify before continuing.", .{ imb.found_char, imb.line }),
        .mismatched => try std.fmt.allocPrint(allocator, "\n⚠ syntax check: '{c}' at line {d} closes the wrong delimiter (open '{c}') — possible broken edit; re-read and verify.", .{ imb.found_char, imb.line, imb.open_char }),
        .unclosed_open => try std.fmt.allocPrint(allocator, "\n⚠ syntax check: '{c}' opened at line {d} is never closed — possible broken edit; re-read and verify.", .{ imb.open_char, imb.line }),
    };
}
