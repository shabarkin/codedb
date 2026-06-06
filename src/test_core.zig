const std = @import("std");
const cio = @import("cio.zig");
const testing = std.testing;
const io = std.testing.io;
const Store = @import("store.zig").Store;
const ChangeEntry = @import("store.zig").ChangeEntry;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const Config = @import("config.zig").Config;
const edit_mod = @import("edit.zig");
const explore = @import("explore.zig");
const Explorer = explore.Explorer;


test "store: record and retrieve snapshots" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const seq1 = try store.recordSnapshot("foo.zig", 100, 0xABC);
    const seq2 = try store.recordSnapshot("bar.zig", 200, 0xDEF);

    try testing.expect(seq1 == 1);
    try testing.expect(seq2 == 2);
    try testing.expect(store.currentSeq() == 2);
}


test "store: getLatest returns most recent version" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("foo.zig", 100, 0x111);
    _ = try store.recordSnapshot("foo.zig", 200, 0x222);

    const latest = store.getLatest("foo.zig").?;
    try testing.expect(latest.seq == 2);
    try testing.expect(latest.size == 200);
    try testing.expect(latest.hash == 0x222);
}


test "store: getLatest returns null for unknown file" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expect(store.getLatest("nope.zig") == null);
}


test "store: changesSince counts correctly" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("a.zig", 10, 0);
    _ = try store.recordSnapshot("b.zig", 20, 0);
    _ = try store.recordSnapshot("c.zig", 30, 0);

    try testing.expect(store.changesSince(0) == 3);
    try testing.expect(store.changesSince(1) == 2);
    try testing.expect(store.changesSince(3) == 0);
}


test "store: changesSinceDetailed" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("a.zig", 10, 0);
    _ = try store.recordSnapshot("b.zig", 20, 0);
    _ = try store.recordSnapshot("a.zig", 15, 0);

    const changes = try store.changesSinceDetailed(1, testing.allocator);
    defer testing.allocator.free(changes);

    try testing.expect(changes.len == 2); // a.zig and b.zig both changed
}


test "store: recordDelete creates tombstone" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("del.zig", 50, 0);
    _ = try store.recordDelete("del.zig", 0);

    const latest = store.getLatest("del.zig").?;
    try testing.expect(latest.op == .tombstone);
    try testing.expect(latest.size == 0);
}


test "store: getAtCursor" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("f.zig", 10, 0x10);
    _ = try store.recordSnapshot("f.zig", 20, 0x20);
    _ = try store.recordSnapshot("f.zig", 30, 0x30);

    const at1 = store.getAtCursor("f.zig", 1).?;
    try testing.expect(at1.size == 10);

    const at2 = store.getAtCursor("f.zig", 2).?;
    try testing.expect(at2.size == 20);

    const at3 = store.getAtCursor("f.zig", 99).?;
    try testing.expect(at3.size == 30);
}


test "store: recordEdit persists diff data to data log" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    const log_path = try std.fmt.allocPrint(testing.allocator, "{s}/data.log", .{dir_path});
    defer testing.allocator.free(log_path);

    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.openDataLog(io, log_path);

    const diff = "replace body";
    _ = try store.recordEdit("foo.zig", 1, .replace, 0x1234, diff.len, diff);

    const latest = store.getLatest("foo.zig").?;
    try testing.expectEqual(@as(?u64, 0), latest.data_offset);
    try testing.expectEqual(@as(u32, diff.len), latest.data_len);

    const log_file = try std.Io.Dir.cwd().openFile(io, log_path, .{});
    defer log_file.close(io);

    var buf: [32]u8 = undefined;
    const read_len = try log_file.readPositionalAll(io, buf[0..diff.len], 0);
    try testing.expectEqual(diff.len, read_len);
    try testing.expectEqualStrings(diff, buf[0..diff.len]);
}


test "agent: register and heartbeat" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("test-agent");
    try testing.expect(id == 1);

    agents.heartbeat(id);
    // No crash = success
}


test "agent: register multiple agents" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const a = try agents.register("alpha");
    const b = try agents.register("beta");
    try testing.expect(a == 1);
    try testing.expect(b == 2);
}


test "agent: lock and unlock" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("locker");

    const got = try agents.tryLock(id, "file.zig", 60_000);
    try testing.expect(got == true);

    agents.releaseLock(id, "file.zig");
}


test "agent: lock contention between agents" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const a = try agents.register("agent-a");
    const b = try agents.register("agent-b");

    // A locks the file
    const got_a = try agents.tryLock(a, "shared.zig", 60_000);
    try testing.expect(got_a == true);

    // B should be denied
    const got_b = try agents.tryLock(b, "shared.zig", 60_000);
    try testing.expect(got_b == false);

    // A releases
    agents.releaseLock(a, "shared.zig");

    // B can now lock
    const got_b2 = try agents.tryLock(b, "shared.zig", 60_000);
    try testing.expect(got_b2 == true);
}


test "agent: same-agent relock does not duplicate lock key" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("agent-relock");

    try testing.expect(try agents.tryLock(id, "shared.zig", 60_000));
    try testing.expect(try agents.tryLock(id, "shared.zig", 60_000));

    const agent = agents.agents.getPtr(id) orelse return error.TestUnexpectedResult;
    try testing.expect(agent.locked_paths.count() == 1);

    agents.releaseLock(id, "shared.zig");
    try testing.expect(agent.locked_paths.count() == 0);
}


test "agent: reapStale frees lock keys and clears map" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("agent-stale");
    try testing.expect(try agents.tryLock(id, "a.zig", 60_000));
    try testing.expect(try agents.tryLock(id, "b.zig", 60_000));

    const agent = agents.agents.getPtr(id) orelse return error.TestUnexpectedResult;
    agent.last_seen = 0;
    agents.reapStale(0);

    try testing.expect(agent.state == .crashed);
    try testing.expect(agent.locked_paths.count() == 0);
}


test "issue-411: tryLock grants new locks to a crashed agent" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("zombie");

    // Force the agent into the crashed state via reapStale.
    const a = agents.agents.getPtr(id) orelse return error.TestUnexpectedResult;
    a.last_seen = 0;
    agents.reapStale(0);
    try testing.expectEqual(@as(@TypeOf(a.state), .crashed), a.state);

    // A crashed agent should not be allowed to acquire new advisory locks
    // until it heartbeats back to .active. Today tryLock ignores .state and
    // happily grants the lock — leaving the registry inconsistent (a
    // .crashed agent suddenly holds fresh locks again).
    const got = try agents.tryLock(id, "post-crash.zig", 60_000);
    try testing.expect(got == false);
}


test "issue-401: insert with after=null is a no-op but consumes seq and writes file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-401.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    const original = "line 1\nline 2\nline 3\n";
    var file = try tmp.dir.createFile(io, "edit-401.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-401-agent");

    // insert without after must not silently succeed and must not consume a seq.
    const res = edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .insert,
        .after = null,
        .content = "INJECT\n",
    });
    // Either explicit error, or — at minimum — must not increment the store seq
    // for an operation that did nothing.
    if (res) |ok| {
        _ = ok;
        try testing.expectEqual(@as(u64, 0), store.currentSeq());
    } else |_| {
        try testing.expectEqual(@as(u64, 0), store.currentSeq());
    }
}


test "issue-404: applyEdit corrupts CRLF line endings into mixed LF/CRLF" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-404.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    // Windows-style CRLF original
    const original = "alpha\r\nbeta\r\ngamma\r\n";
    var file = try tmp.dir.createFile(io, "edit-404.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-404-agent");

    // Replace line 1 with new content (no trailing newline in replacement).
    _ = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 1, 1 },
        .content = "ALPHA",
    });

    const after = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(after);

    // The original file used CRLF line endings. After a single-line replace
    // the file must still be a valid CRLF file: every '\n' must be preceded
    // by '\r'. Currently splitScalar on '\n' leaves the '\r' attached to the
    // *unchanged* lines (e.g. "beta\r"), and the rejoin uses bare "\n", so
    // the new line 1 lacks its CR while the surviving line 2 still has it —
    // mixed line endings.
    var i: usize = 0;
    while (i < after.len) : (i += 1) {
        if (after[i] == '\n') {
            try testing.expect(i > 0);
            try testing.expectEqual(@as(u8, '\r'), after[i - 1]);
        }
    }
}


test "issue-409: replacing whole file with empty content leaves a stray newline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-409.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    // Single-line file with trailing newline.
    const original = "abc\n";
    var file = try tmp.dir.createFile(io, "edit-409.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-409-agent");

    // Replace the only line with empty content. The caller's intent is "make
    // this file empty" — content has zero bytes.
    const result = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 1, 1 },
        .content = "",
    });

    const after = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(after);

    // Expectation: the file is empty. Currently the file ends up as "\n"
    // because applyEdit unconditionally restores the trailing newline that
    // existed in the source, even after the replacement reduced the file
    // to a single empty line.
    try testing.expectEqual(@as(usize, 0), after.len);
    try testing.expectEqual(@as(u64, 0), result.new_size);
}


// ── Post-edit syntax health (trial/graph-based-codedb) ────────────────────

test "edit-health: flags unmatched close from a mis-spliced import edit (httpx-style)" {
    // Faithful to the real codedb httpx break: regenerating a
    // `from x import (...)` block left a duplicate ')' after the close,
    // making httpx/_models.py unparseable (SyntaxError: unmatched ')').
    const broken =
        \\from ._exceptions import (
        \\    CookieConflict,
        \\    DecodingError,
        \\    StreamConsumed,
        \\)
        \\)
        \\x = 1
    ;
    const msg = (try edit_mod.describeHealth(testing.allocator, broken, .python)).?;
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "unmatched") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "line 6") != null);
}

test "edit-health: flags an unclosed opener (orphaned signature, narwhals-style)" {
    // Faithful to narwhals _sql/expr.py: a regenerated body left the original
    // signature open, so the '(' never closes.
    const broken =
        \\def rolling(
        \\    window_size,
        \\    min_samples,
        \\:
        \\    return window_size
    ;
    const msg = (try edit_mod.describeHealth(testing.allocator, broken, .python)).?;
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "never closed") != null);
}

test "edit-health: no false positive on balanced python with brackets in strings/comments" {
    const ok =
        \\import re
        \\x = f"{a}({b}"   # a comment with ) and ] and }
        \\s = "a string with ( and { and ["
        \\def g(n):
        \\    return [i for i in range(n)]
    ;
    const msg = try edit_mod.describeHealth(testing.allocator, ok, .python);
    try testing.expect(msg == null);
}

test "edit-health: stays silent on non-code content (unknown language)" {
    const txt = "a note with ( an unbalanced paren which is perfectly fine\n";
    const msg = try edit_mod.describeHealth(testing.allocator, txt, .unknown);
    try testing.expect(msg == null);
}

test "edit-health: applyEdit surfaces a warning when an edit breaks a python file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/health.py", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    const original = "import os\n\n\ndef main():\n    return os.getcwd()\n";
    var file = try tmp.dir.createFile(io, "health.py", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("edit-health-broken");

    // Insert a stray unbalanced ')' after line 1 — a mis-spliced edit.
    const result = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .insert,
        .after = 1,
        .content = ")",
    });
    defer if (result.health) |h| testing.allocator.free(h);
    try testing.expect(result.health != null);
    try testing.expect(std.mem.indexOf(u8, result.health.?, "unmatched") != null);
}

test "edit-health: a clean python edit produces no warning (happy path unchanged)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/clean.py", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    const original = "import os\n\n\ndef main():\n    return os.getcwd()\n";
    var file = try tmp.dir.createFile(io, "clean.py", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("edit-health-clean");

    // Insert a balanced statement — must not trip the syntax warning.
    const result = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .insert,
        .after = 1,
        .content = "y = (1 + 2) * [3, 4][0]",
    });
    defer if (result.health) |h| testing.allocator.free(h);
    try testing.expect(result.health == null);
}


test "issue-101: Store.max_versions is configurable (caps per-file history)" {
    // Default cap is 100. After setting max_versions = 3, writing 5 versions
    // of the same file must leave exactly 3 in-memory.
    var store = Store.init(testing.allocator);
    defer store.deinit();

    store.max_versions = 3;

    _ = try store.recordSnapshot("foo.zig", 10, 0x111);
    _ = try store.recordSnapshot("foo.zig", 20, 0x222);
    _ = try store.recordSnapshot("foo.zig", 30, 0x333);
    _ = try store.recordSnapshot("foo.zig", 40, 0x444);
    _ = try store.recordSnapshot("foo.zig", 50, 0x555);

    const entry = store.files.get("foo.zig") orelse return error.MissingFile;
    try testing.expectEqual(@as(usize, 3), entry.versions.items.len);
    // Oldest two dropped — newest survives.
    try testing.expectEqual(@as(u64, 0x555), entry.versions.items[2].hash);
}


test "issue-102: Explorer.init capacity flows to ContentCache" {
    // Verifies that the capacity arg to Explorer.init actually sets the
    // ContentCache capacity — the bug that issue-102 was filed for.
    var explorer = Explorer.init(testing.allocator, 8);
    defer explorer.deinit();

    try testing.expectEqual(@as(u32, 8), explorer.contents.capacity);
}


test "issue-101+102: .codedbrc max_cached threads through to ContentCache capacity" {
    // End-to-end: parse a .codedbrc body, construct Explorer with the parsed
    // max_cached, verify the ContentCache capacity matches.
    const body =
        \\# test config
        \\max_versions = 7
        \\max_cached = 32
        \\
    ;
    const cfg = try Config.parse(body);
    try testing.expectEqual(@as(usize, 7), cfg.max_versions);
    try testing.expectEqual(@as(u32, 32), cfg.max_cached);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    store.max_versions = cfg.max_versions;

    var explorer = Explorer.init(testing.allocator, cfg.max_cached);
    defer explorer.deinit();

    try testing.expectEqual(@as(usize, 7), store.max_versions);
    try testing.expectEqual(@as(u32, 32), explorer.contents.capacity);
}

