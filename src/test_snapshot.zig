const std = @import("std");
const cio = @import("cio.zig");
const testing = std.testing;
const io = std.testing.io;
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const explore = @import("explore.zig");
const Language = explore.Language;
const SymbolKind = explore.SymbolKind;
const WordIndex = @import("index.zig").WordIndex;
const TrigramIndex = @import("index.zig").TrigramIndex;
const SparseNgramIndex = @import("index.zig").SparseNgramIndex;
const snapshot_mod = @import("snapshot.zig");
const snapshot_json = @import("snapshot_json.zig");
const watcher = @import("watcher.zig");
const git_mod = @import("git.zig");
const AgentRegistry = @import("agent.zig").AgentRegistry;
const edit_mod = @import("edit.zig");

test "issue-35: edits immediately update explorer and snapshot output" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-live-sync.zig", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile(io, "edit-live-sync.zig", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "pub fn oldName() void {}\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile(rel_path, "pub fn oldName() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    _ = try store.recordSnapshot(rel_path, "pub fn oldName() void {}\n".len, std.hash.Wyhash.hash(0, "pub fn oldName() void {}\n"));

    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-35-agent");

    const before_snap = try snapshot_json.buildSnapshot(&explorer, &store, testing.allocator);
    defer testing.allocator.free(before_snap);
    try testing.expect(std.mem.indexOf(u8, before_snap, "oldName") != null);

    _ = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, &explorer, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 1, 1 },
        .content = "pub fn newName() void {}",
    });

    const new_results = try explorer.searchContent("newName", testing.allocator, 10);
    defer {
        for (new_results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(new_results);
    }
    try testing.expect(new_results.len == 1);

    const old_results = try explorer.searchContent("oldName", testing.allocator, 10);
    defer {
        for (old_results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(old_results);
    }
    try testing.expect(old_results.len == 0);

    const after_snap = try snapshot_json.buildSnapshot(&explorer, &store, testing.allocator);
    defer testing.allocator.free(after_snap);
    try testing.expect(std.mem.indexOf(u8, after_snap, "newName") != null);
    try testing.expect(std.mem.indexOf(u8, after_snap, "oldName") == null);
}

test "snapshot_json: snapshot builds and is valid JSON" {
    // Explorer uses arena for internal data
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile("src/main.zig", "pub fn main() void {}");
    try explorer.indexFile("src/lib.zig", "pub const version = 1;");

    var store = @import("store.zig").Store.init(alloc);
    defer store.deinit();
    _ = try store.recordSnapshot("src/main.zig", 100, 0xABC);

    const snap = try snapshot_json.buildSnapshot(&explorer, &store, testing.allocator);
    defer testing.allocator.free(snap);

    // Must be valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, snap, .{});
    defer parsed.deinit();

    // Must have expected top-level keys (matches buildSnapshot output)
    try testing.expect(parsed.value.object.contains("seq"));
    try testing.expect(parsed.value.object.contains("tree"));
    try testing.expect(parsed.value.object.contains("outlines"));
    try testing.expect(parsed.value.object.contains("symbol_index"));
    try testing.expect(parsed.value.object.contains("dep_graph"));

    const tree = parsed.value.object.get("tree").?.string;
    try testing.expect(std.mem.indexOf(u8, tree, "src/") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "main.zig") != null);

    const symbol_index = parsed.value.object.get("symbol_index").?.object;
    try testing.expect(symbol_index.contains("main"));
    try testing.expect(symbol_index.contains("version"));
}

test "issue-44: snapshot stale after working tree changes cause stale query results" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.snapshot", .{dir_path});
    defer testing.allocator.free(snap_path);
    // Step 1: write file with old content, index it, write snapshot.
    try tmp.dir.writeFile(io, .{ .sub_path = "stale.zig", .data = "pub fn oldFunc() void {}" });
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
        defer exp.deinit();
        exp.setRoot(io, dir_path);
        try exp.indexFile("stale.zig", "pub fn oldFunc() void {}");
        try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, arena.allocator());
    }

    // Step 2: modify file AFTER snapshot creation (simulating uncommitted working tree change).
    // Sleep 10ms so the file mtime is strictly greater than the snapshot's indexed_at timestamp.
    cio.sleepMs(10);
    try tmp.dir.writeFile(io, .{ .sub_path = "stale.zig", .data = "pub fn newFunc() void {}" });

    // Step 3: load snapshot into a fresh explorer (what MCP startup does).
    // scan_done is set to true immediately; watcher then builds known-FileMap
    // from current disk mtimes, recording the already-modified file's mtime as
    // the baseline. It will never be re-indexed unless changed a second time.
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp2.deinit();
    exp2.setRoot(io, dir_path);
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store2, arena2.allocator());
    try testing.expect(loaded);

    // Step 4: after the fix, loadSnapshot should detect that the disk file's
    // mtime > snapshot indexed_at and re-index it from disk, making "newFunc"
    // visible. Currently no such path exists.
    // Expected (after fix): results.len == 1
    // Current (bug): results.len == 0 — stale snapshot content is never evicted.
    const results = try exp2.searchContent("newFunc", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 1);
}

test "issue-46: empty-repo snapshot rejected on load" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, testing.allocator);
    try testing.expect(!loaded);
    try testing.expect(exp2.outlines.count() == 0);
}

test "issue-220: snapshot fast load restores outlines and lazily rebuilds word index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile("src/store.zig", "pub const Store = struct {};\n");
    try exp.indexFile("src/main.zig", "const Store = @import(\"store.zig\").Store;\npub fn main() void {}\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/fast.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, arena2.allocator());
    try testing.expect(loaded);
    try testing.expectEqual(@as(usize, 2), exp2.outlines.count());
    try testing.expectEqual(@as(u32, 0), exp2.trigram_index.fileCount());
    try testing.expectEqual(@as(usize, 0), exp2.word_index.index.count());
    try testing.expect(exp2.wordIndexCanLoadFromDisk());
    try testing.expect(!exp2.wordIndexIsComplete());
    try testing.expect(!exp2.wordIndexNeedsPersist());

    const deps = try exp2.getImportedBy("src/store.zig", testing.allocator);
    defer {
        for (deps) |dep| testing.allocator.free(dep);
        testing.allocator.free(deps);
    }
    try testing.expectEqual(@as(usize, 1), deps.len);
    try testing.expect(std.mem.eql(u8, deps[0], "src/main.zig"));

    const hits = try exp2.searchWord("Store", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len >= 1);
    try testing.expect(exp2.word_index.index.count() > 0);
    try testing.expect(exp2.wordIndexIsComplete());
    try testing.expect(exp2.wordIndexNeedsPersist());
}

test "snapshot load rejects sensitive content paths before restore" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const original_path = "src/a.zig";
    const sensitive_path = ".env.zigx";
    try testing.expectEqual(original_path.len, sensitive_path.len);

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile(original_path, "pub const leaked_secret = 1;\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/sensitive.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    {
        var sections = (try snapshot_mod.readSections(io, snap_path, testing.allocator)).?;
        defer sections.deinit();
        const content = sections.get(@intFromEnum(snapshot_mod.SectionId.content)) orelse return;
        const file = try std.Io.Dir.cwd().openFile(io, snap_path, .{ .mode = .read_write });
        defer file.close(io);
        try file.writePositionalAll(io, sensitive_path, content.offset + 2);
    }

    var exp2 = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp2.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, testing.allocator);
    try testing.expect(!loaded);
    try testing.expectEqual(@as(usize, 0), exp2.outlines.count());
    try testing.expectEqual(@as(u64, 0), store.currentSeq());
}

test "snapshot: writer streams uncached file contents for large repos" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    var rel_buf: [64]u8 = undefined;
    var content_buf: [128]u8 = undefined;
    for (0..1002) |i| {
        const rel = try std.fmt.bufPrint(&rel_buf, "src/file_{d}.zig", .{i});
        const content = try std.fmt.bufPrint(&content_buf, "pub fn func_{d}() usize {{ return {d}; }}\n", .{ i, i });
        try tmp.dir.writeFile(io, .{ .sub_path = rel, .data = content });
        try exp.indexFileOutlineOnly(rel, content);
    }

    try testing.expectEqual(@as(usize, 1002), exp.outlines.count());
    // With CLOCK eviction (#208) the ContentCache holds up to 16384 entries — all 1002 fit.
    try testing.expectEqual(@as(u32, 1002), exp.contents.count());

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/large.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var loaded_without_root = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer loaded_without_root.deinit();
    var store_without_root = Store.init(testing.allocator);
    defer store_without_root.deinit();

    try testing.expect(snapshot_mod.loadSnapshot(io, snap_path, &loaded_without_root, &store_without_root, testing.allocator));
    try testing.expectEqual(@as(usize, 1002), loaded_without_root.outlines.count());
    // CLOCK cache holds all 1002 — word index can be rebuilt from memory without root dir.
    const hits_no_root = try loaded_without_root.searchWord("func_1001", testing.allocator);
    defer testing.allocator.free(hits_no_root);
    try testing.expectEqual(@as(usize, 1), hits_no_root.len);

    var loaded = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    loaded.setRoot(io, dir_path);
    defer loaded.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expect(snapshot_mod.loadSnapshot(io, snap_path, &loaded, &store, testing.allocator));
    try testing.expectEqual(@as(usize, 1002), loaded.outlines.count());

    const hits = try loaded.searchWord("func_1001", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("src/file_1001.zig", loaded.word_index.hitPath(hits[0]));
    try testing.expect(loaded.wordIndexIsComplete());
}

test "issue-p2-dep: snapshot restore resolves relative imports and dedupes forward deps" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/features");

    try tmp.dir.writeFile(io, .{
        .sub_path = "src/util.zig",
        .data = "pub fn helper() void {}\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/features/worker.zig",
        .data =
        \\const util = @import("../util.zig");
        \\const alias = @import("../util.zig");
        \\pub fn work() void {
        \\    util.helper();
        \\    alias.helper();
        \\}
        \\
        ,
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();
    exp.setRoot(io, dir_path);
    try exp.indexFile("src/util.zig", "pub fn helper() void {}\n");
    try exp.indexFile("src/features/worker.zig",
        \\const util = @import("../util.zig");
        \\const alias = @import("../util.zig");
        \\pub fn work() void {
        \\    util.helper();
        \\    alias.helper();
        \\}
        \\
    );

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/deps-fast.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    exp2.setRoot(io, dir_path);
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, arena2.allocator());
    try testing.expect(loaded);

    const importers = try exp2.getImportedBy("src/util.zig", testing.allocator);
    defer {
        for (importers) |dep| testing.allocator.free(dep);
        testing.allocator.free(importers);
    }
    try testing.expectEqual(@as(usize, 1), importers.len);
    try testing.expectEqualStrings("src/features/worker.zig", importers[0]);

    exp2.mu.lockShared();
    const fwd_opt = exp2.dep_graph.getForwardDeps("src/features/worker.zig");
    exp2.mu.unlockShared();
    try testing.expect(fwd_opt != null);
    const fwd = fwd_opt.?;
    try testing.expectEqual(@as(usize, 1), fwd.len);
    try testing.expectEqualStrings("src/util.zig", fwd[0]);
}

test "issue-220: partial word index state rebuilds before search" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();
    try exp.indexFile("src/a.zig", "pub const Alpha = 1;\n");
    try exp.indexFile("src/b.zig", "pub const Beta = 2;\n");

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/partial.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var exp2 = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp2.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expect(snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, testing.allocator));
    try testing.expect(exp2.wordIndexCanLoadFromDisk());
    try testing.expect(!exp2.wordIndexIsComplete());

    try exp2.indexFileSkipTrigram("src/b.zig", "pub const Gamma = 3;\n");
    try testing.expect(!exp2.wordIndexCanLoadFromDisk());
    try testing.expect(!exp2.wordIndexIsComplete());

    const alpha_hits = try exp2.searchWord("Alpha", testing.allocator);
    defer testing.allocator.free(alpha_hits);
    try testing.expectEqual(@as(usize, 1), alpha_hits.len);
    try testing.expect(std.mem.eql(u8, exp2.word_index.hitPath(alpha_hits[0]), "src/a.zig"));

    const gamma_hits = try exp2.searchWord("Gamma", testing.allocator);
    defer testing.allocator.free(gamma_hits);
    try testing.expectEqual(@as(usize, 1), gamma_hits.len);
    try testing.expect(std.mem.eql(u8, exp2.word_index.hitPath(gamma_hits[0]), "src/b.zig"));
    try testing.expect(exp2.wordIndexIsComplete());
    try testing.expect(exp2.wordIndexNeedsPersist());
}

test "issue-220: word index persistence tracking skips redundant rewrites" {
    var exp = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp.deinit();

    try exp.indexFile("src/a.zig", "pub const Alpha = 1;\n");
    try testing.expect(exp.wordIndexIsComplete());
    try testing.expect(exp.wordIndexNeedsPersist());

    const first_gen = exp.wordIndexGenerationToPersist() orelse return error.TestUnexpectedResult;
    exp.markWordIndexPersisted(first_gen);
    try testing.expect(!exp.wordIndexNeedsPersist());
    try testing.expect(exp.wordIndexGenerationToPersist() == null);

    try exp.indexFile("src/a.zig", "pub const Beta = 2;\n");
    try testing.expect(exp.wordIndexNeedsPersist());

    const second_gen = exp.wordIndexGenerationToPersist() orelse return error.TestUnexpectedResult;
    try testing.expect(second_gen != first_gen);
    exp.markWordIndexPersisted(first_gen);
    try testing.expect(exp.wordIndexNeedsPersist());
    exp.markWordIndexPersisted(second_gen);
    try testing.expect(!exp.wordIndexNeedsPersist());
}

test "issue-45: snapshot written in non-git directory cannot be loaded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile("dummy.zig", "const x = 1;");

    const snap_path = try std.fs.path.join(aa, &.{ dir_path, "test.codedb" });

    // Write snapshot with a non-git root_path — git_head will be all-zeros
    try snapshot_mod.writeSnapshot(io, &exp, "/tmp", snap_path, aa);

    // Snapshot file was created
    std.Io.Dir.cwd().access(io, snap_path, .{}) catch {
        return error.TestUnexpectedResult;
    };

    // readSnapshotGitHead returns null for non-git dirs (all-zero sentinel).
    // The snapshot loading logic in main.zig handles this by checking if the
    // current project also has no git — if so, it loads the snapshot.
    const snap_head = snapshot_mod.readSnapshotGitHead(io, snap_path);
    try testing.expect(snap_head == null);
}

test "issue-47: concurrent snapshot writes from parallel instances corrupt file" {
    // BUG: Two codedb instances indexing the same repo write codedb.snapshot
    // concurrently with no file locking. The second writer can overwrite a
    // partially-written snapshot, producing a corrupt file that loadSnapshot
    // rejects or — worse — reads garbage section offsets from.
    //
    // Simulate: two threads write snapshots to the same path concurrently,
    // then verify the final file is still loadable.
    var arena1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena1.deinit();
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();

    var exp1 = Explorer.init(arena1.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp1.indexFile("a.zig", "pub fn alpha() void {}");
    var exp2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp2.indexFile("b.zig", "pub fn beta() void {}");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/concurrent.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    const WriterCtx = struct {
        exp: *Explorer,
        path: []const u8,
        dir: []const u8,
        alloc: std.mem.Allocator,
        failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(ctx: *@This()) void {
            for (0..10) |_| {
                snapshot_mod.writeSnapshot(io, ctx.exp, ctx.dir, ctx.path, ctx.alloc) catch {
                    ctx.failed.store(true, .release);
                    return;
                };
            }
        }
    };

    var ctx1 = WriterCtx{ .exp = &exp1, .path = snap_path, .dir = dir_path, .alloc = arena1.allocator() };
    var ctx2 = WriterCtx{ .exp = &exp2, .path = snap_path, .dir = dir_path, .alloc = arena2.allocator() };

    const t1 = try std.Thread.spawn(.{}, WriterCtx.run, .{&ctx1});
    const t2 = try std.Thread.spawn(.{}, WriterCtx.run, .{&ctx2});
    t1.join();
    t2.join();

    // Neither writer should have errored
    try testing.expect(!ctx1.failed.load(.acquire));
    try testing.expect(!ctx2.failed.load(.acquire));

    // The final snapshot must be loadable (not corrupt)
    var arena3 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena3.deinit();
    var exp3 = Explorer.init(arena3.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store3 = Store.init(testing.allocator);
    defer store3.deinit();
    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp3, &store3, arena3.allocator());

    // Expected: loaded == true (snapshot is valid, written atomically)
    // Current (bug): may be false — last writer's rename can land mid-write of
    // the first writer's tmp file, or both rename the same .tmp path.
    try testing.expect(loaded);
}

test "issue-42: scan thread is joined before allocator-backed state is freed" {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    const data_dir = try allocator.dupe(u8, "/tmp/codedb_test_issue42");

    const SharedCtx = struct {
        data_dir: []const u8,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(ctx: *@This()) void {
            cio.sleepMs(10);
            if (ctx.data_dir.len > 0) {
                _ = ctx.data_dir[0];
                ctx.ok.store(true, .release);
            }
            ctx.done.store(true, .release);
        }
    };

    var ctx = SharedCtx{ .data_dir = data_dir };
    const t = try std.Thread.spawn(.{}, SharedCtx.run, .{&ctx});
    t.join();

    try testing.expect(ctx.done.load(.acquire));
    try testing.expect(ctx.ok.load(.acquire));
    allocator.free(data_dir);
    _ = gpa.deinit();
}

test "issue-40: truncated snapshot silently loads partial data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try exp.indexFile("src/a.zig", "const a = 1;\n");
    try exp.indexFile("src/b.zig", "const b = 2;\n");
    try exp.indexFile("src/c.zig", "const c = 3;\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    const trunc_path = try std.fmt.allocPrint(testing.allocator, "{s}/trunc.codedb", .{dir_path});
    defer testing.allocator.free(trunc_path);
    {
        const orig = try std.Io.Dir.cwd().readFileAlloc(io, snap_path, testing.allocator, .limited(1024 * 1024));
        defer testing.allocator.free(orig);
        const trunc_file = try std.Io.Dir.cwd().createFile(io, trunc_path, .{});
        defer trunc_file.close(io);
        // Keep only header (256 bytes) — content section data will be missing
        try trunc_file.writeStreamingAll(io, orig[0..@min(256, orig.len)]);
    }

    var arena2 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(arena2.allocator());

    const loaded = snapshot_mod.loadSnapshot(io, trunc_path, &exp2, &store, arena2.allocator());
    try testing.expect(!loaded);
}

test "issue-41: snapshot not validated against repo identity allows cross-project loading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try exp.indexFile("src/projectA.zig", "const project = \"A\";\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshotValidated(io, snap_path, "/some/other/project", &exp2, &store, testing.allocator);
    try testing.expect(!loaded);
}

test "snapshot: oversized symbol detail is truncated and survives round-trip" {
    // Regression coverage for two cases:
    // 1. loadSnapshot must still accept detail lengths above 4096 bytes.
    // 2. writeSnapshot must not panic when a parser emits detail > u16 max.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile("src/big.zig", "pub fn bigSig() void {}\n");

    const outline = exp.outlines.getPtr("src/big.zig") orelse return error.TestUnexpectedResult;
    try testing.expect(outline.symbols.items.len >= 1);

    const max_detail_len = @as(usize, std.math.maxInt(u16));
    const oversized_detail = try aa.alloc(u8, max_detail_len + 1024);
    @memset(oversized_detail, 'x');
    outline.symbols.items[0].detail = oversized_detail;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/big.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var exp2 = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp2.deinit();
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store2, testing.allocator);
    try testing.expect(loaded);

    const loaded_outline = exp2.outlines.get("src/big.zig") orelse return error.TestUnexpectedResult;
    try testing.expect(loaded_outline.symbols.items.len >= 1);
    const loaded_detail = loaded_outline.symbols.items[0].detail orelse return error.TestUnexpectedResult;
    try testing.expectEqual(max_detail_len, loaded_detail.len);
    try testing.expect(std.mem.eql(u8, oversized_detail[0..max_detail_len], loaded_detail));

    var sym_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer sym_arena.deinit();
    const results = try exp2.findAllSymbols("bigSig", sym_arena.allocator());
    try testing.expect(results.len >= 1);
}

test "snapshot: corrupted OUTLINE_STATE section falls back to CONTENT load" {
    // Regression for the codedb 0.2.56 writer u16 overflow bug: when OUTLINE_STATE
    // contains a detail that overflows u16 the section cursor de-syncs, making
    // subsequent file records parse as garbage and loadOutlineStateMap throws.
    // The catch fallback must produce an empty map so loadSnapshotFast falls
    // through to indexFileOutlineOnly for every file in CONTENT.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile("src/a.zig", "pub fn aFunc() void {}\n");
    try exp.indexFile("src/b.zig", "pub fn bFunc() void {}\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/corrupt.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    // Overwrite the first 16 bytes of OUTLINE_STATE data with 0xFF.
    // This makes the file_count field read as 0xFFFFFFFF — far more records
    // than the data contains — causing readSectionString to eventually fail
    // with error.InvalidData (runs off the end of the bytes slice).
    {
        var sections = (try snapshot_mod.readSections(io, snap_path, testing.allocator)).?;
        defer sections.deinit();
        const ols = sections.get(@intFromEnum(snapshot_mod.SectionId.outline_state)) orelse return;
        const f = try std.Io.Dir.cwd().openFile(io, snap_path, .{ .mode = .read_write });
        defer f.close(io);
        try f.writePositionalAll(io, &([_]u8{0xFF} ** 16), ols.offset);
    }

    var exp2 = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp2.deinit();
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store2, testing.allocator);
    try testing.expect(loaded); // must survive OUTLINE_STATE corruption

    // Symbols must still be found — re-indexed from CONTENT
    var sym_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer sym_arena.deinit();
    const results = try exp2.findAllSymbols("aFunc", sym_arena.allocator());
    try testing.expect(results.len >= 1);
}

test "issue-379: snapshot loader returns true with zero outlines for empty-explorer snapshot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/empty.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var exp2 = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp2.deinit();
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store2, testing.allocator);
    if (loaded) {
        try testing.expect(exp2.outlines.count() > 0);
    }
}

test "issue-p0-2: corrupt META offset beyond EOF returns false without panicking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile("src/main.zig", "pub fn main() void {}\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/bad-meta-offset.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    {
        const file = try std.Io.Dir.cwd().openFile(io, snap_path, .{ .mode = .read_write });
        defer file.close(io);
        const stat = try file.stat(io);
        var offset_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &offset_buf, stat.size + 1, .little);
        try file.writePositionalAll(io, &offset_buf, 52 + 4);
    }

    var exp2 = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer exp2.deinit();
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshotValidated(io, snap_path, dir_path, &exp2, &store2, testing.allocator);
    try testing.expect(!loaded);
}

test "issue-528: isSensitivePath parity between snapshot.zig and watcher.zig" {
    // Snapshot persistence and live indexing must agree on the centralized
    // secret/credential filter. Drift here would mean a secret could leak into
    // one path but not the other.
    const cases = [_][]const u8{
        // secrets — both copies must block
        ".env",                         ".env.local",         ".env.production",
        ".env.development",             ".env.staging",       ".env.test",
        ".dev.vars",                    ".npmrc",             ".pypirc",
        ".netrc",                       "credentials.json",   "service-account.json",
        "secrets.json",                 "secrets.yaml",       "secrets.yml",
        "id_rsa",                       "id_ed25519",         "server.key",
        "cert.pem",                     "keystore.jks",       "identity.pfx",
        "bundle.p12",                   "config/.env.local",  "a/b/secrets.yaml",
        "deep/nested/.ssh/known_hosts", ".gnupg/secring.gpg", "x/.aws/credentials",
        // non-secrets — both copies must allow (esp. the .env-prefix edge cases)
        ".envoy.json",                  ".environment",       ".envrc",
        ".envconfig.yaml",              "main.zig",           "src/server.zig",
        "README.md",                    "package.json",       "id_rsa.pub",
        "envvars.ts",                   "Makefile",           "Dockerfile",
    };
    for (cases) |p| {
        try testing.expectEqual(watcher.isSensitivePath(p), snapshot_mod.isSensitivePath(p));
    }
    // Anchor the contract so parity can't be satisfied by both copies being
    // wrong in the same direction.
    try testing.expect(snapshot_mod.isSensitivePath(".env"));
    try testing.expect(snapshot_mod.isSensitivePath("credentials.json"));
    try testing.expect(snapshot_mod.isSensitivePath("deep/.ssh/id_rsa"));
    try testing.expect(snapshot_mod.isSensitivePath("keystore.jks")); // fast-path ext
    try testing.expect(!snapshot_mod.isSensitivePath(".envoy.json")); // issue-409
    try testing.expect(!snapshot_mod.isSensitivePath(".environment"));
    try testing.expect(!snapshot_mod.isSensitivePath("main.zig"));
    try testing.expect(!snapshot_mod.isSensitivePath("package.json"));
}
