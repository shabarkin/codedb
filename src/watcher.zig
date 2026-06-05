const std = @import("std");
const ContentCache = @import("hot_cache.zig").ContentCache;
const cio = @import("cio.zig");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const TrigramIndex = @import("index.zig").TrigramIndex;
const explore_mod = @import("explore.zig");
const git_mod = @import("git.zig");
const path_security = @import("path_security.zig");
pub const EventKind = enum(u8) {
    created,
    modified,
    deleted,
};

pub const FsEvent = struct {
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize,
    kind: EventKind,
    seq: u64,

    pub fn init(src_path: []const u8, kind: EventKind, seq: u64) ?FsEvent {
        // Gracefully skip paths exceeding the max instead of panicking.
        if (src_path.len > std.fs.max_path_bytes) return null;
        var event = FsEvent{
            .path_len = src_path.len,
            .kind = kind,
            .seq = seq,
        };
        @memcpy(event.path_buf[0..src_path.len], src_path);
        return event;
    }

    pub fn path(self: *const FsEvent) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

pub const EventQueue = struct {
    const CAPACITY = 4096;

    events: [CAPACITY]?FsEvent = [_]?FsEvent{null} ** CAPACITY,
    head: usize = 0,
    tail: usize = 0,
    mu: cio.Mutex = .{},

    pub fn push(self: *EventQueue, event: FsEvent) bool {
        self.mu.lock();
        defer self.mu.unlock();

        const cur_tail = self.tail;
        const next_tail = (cur_tail + 1) % CAPACITY;
        if (next_tail == self.head) return false;
        self.events[cur_tail] = event;
        self.tail = next_tail;
        return true;
    }

    pub fn pop(self: *EventQueue) ?FsEvent {
        self.mu.lock();
        defer self.mu.unlock();

        const cur_head = self.head;
        if (cur_head == self.tail) return null;
        const event = self.events[cur_head];
        self.head = (cur_head + 1) % CAPACITY;
        return event;
    }
};

const FileState = struct {
    mtime: i64, // milliseconds since epoch — cheap stat check
    size: u64, // cheap change discriminator before hashing
    hash: u64, // wyhash of content — confirms actual change
    seen: bool, // set during current poll cycle for deletion detection
};

const FileMap = std.StringHashMap(FileState);

const InitialScanEntry = struct {
    path: []u8,
    skip_trigram: bool,
};

const ParsedScanFile = struct {
    path: []const u8,
    content: []const u8,
    outline: explore_mod.FileOutline,
    skip_trigram: bool,
};

const WorkerParsedResults = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(ParsedScanFile),

    fn init(backing: std.mem.Allocator) WorkerParsedResults {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .items = .empty,
        };
    }

    fn deinit(self: *WorkerParsedResults, backing: std.mem.Allocator) void {
        _ = backing;
        self.items.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

const skip_dirs = [_][]const u8{
    ".git",
    ".claude",
    ".codedb",
    "node_modules",
    ".zig-cache",
    "zig-out",
    ".next",
    ".nuxt",
    ".svelte-kit",
    "dist",
    "build",
    ".build",
    ".output",
    "out",
    "__pycache__",
    ".venv",
    "venv",
    ".env",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    "target", // rust, java/maven
    ".gradle",
    ".idea",
    ".vs",
    "vendor", // go, php
    "Pods", // cocoapods
    ".dart_tool",
    ".pub-cache",
    "coverage",
    ".nyc_output",
    ".turbo",
    ".parcel-cache",
    ".cache",
    ".tmp",
    ".temp",
    ".DS_Store",
    "bundle",
    ".bundle",
    ".swc",
    ".terraform",
    ".terragrunt-cache",
    ".serverless",
    "elm-stuff",
    ".stack-work",
    ".cabal-sandbox",
    ".cargo",
    "bower_components",
};

fn shouldSkip(path: []const u8) bool {
    // Check each path component against skip list
    var rest = path;
    while (true) {
        for (skip_dirs) |skip| {
            if (rest.len >= skip.len and
                std.mem.eql(u8, rest[0..skip.len], skip) and
                (rest.len == skip.len or rest[skip.len] == '/'))
                return true;
        }
        // Advance to next component
        if (std.mem.indexOfScalar(u8, rest, '/')) |sep| {
            rest = rest[sep + 1 ..];
        } else break;
    }
    return false;
}

fn shouldSkipDir(name: []const u8) bool {
    if (path_security.isSensitivePath(name)) return true;
    for (skip_dirs) |skip| {
        if (std.ascii.eqlIgnoreCase(name, skip)) return true;
    }
    return false;
}

/// Recursive directory walker that prunes skip_dirs before descending.
/// Unlike std.Io.Dir.walk(), this never enters .git, node_modules, etc.,
/// avoiding the CPU cost of traversing potentially huge directory trees.
const FilteredWalker = struct {
    const IgnorePattern = struct {
        pattern: []const u8,
        base_dir: []const u8,
        anchored: bool,
        dir_only: bool,
        negated: bool,
        has_slash: bool,
    };

    const StackItem = struct {
        dir_handle: std.Io.Dir,
        iter: std.Io.Dir.Iterator,
        ignore_len: usize,
    };

    stack: std.ArrayList(StackItem),
    name_buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_prefix_len: usize = 0,
    ignore_patterns: std.ArrayList(IgnorePattern) = .empty,
    real_root: []const u8 = &.{},
    visited_real_paths: std.StringHashMapUnmanaged(void) = .empty,

    pub const Entry = struct {
        path: []const u8, // relative path — valid until next call to next()
    };

    pub fn init(io: std.Io, root: std.Io.Dir, allocator: std.mem.Allocator) !FilteredWalker {
        var self = FilteredWalker{
            .stack = .empty,
            .name_buffer = .empty,
            .allocator = allocator,
            .io = io,
        };
        try self.stack.append(allocator, .{
            .dir_handle = root,
            .iter = root.iterate(),
            .ignore_len = 0,
        });

        var rr_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (root.realPathFile(io, ".", &rr_buf)) |rr_len| {
            const dup = try allocator.dupe(u8, rr_buf[0..rr_len]);
            self.real_root = dup;
            const seed = try allocator.dupe(u8, rr_buf[0..rr_len]);
            try self.visited_real_paths.put(allocator, seed, {});
        } else |_| {}

        try self.loadIgnoreFile(root, "", ".codedbignore");
        try self.loadIgnoreFile(root, "", ".gitignore");

        return self;
    }

    pub fn deinit(self: *FilteredWalker) void {
        for (self.stack.items, 0..) |*item, i| {
            if (i > 0) item.dir_handle.close(self.io);
        }
        self.stack.deinit(self.allocator);
        self.name_buffer.deinit(self.allocator);
        for (self.ignore_patterns.items) |pattern| self.deinitIgnorePattern(pattern);
        self.ignore_patterns.deinit(self.allocator);
        var it = self.visited_real_paths.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.visited_real_paths.deinit(self.allocator);
        if (self.real_root.len > 0) self.allocator.free(self.real_root);
    }

    fn deinitIgnorePattern(self: *FilteredWalker, pattern: IgnorePattern) void {
        self.allocator.free(pattern.pattern);
        if (pattern.base_dir.len > 0) self.allocator.free(pattern.base_dir);
    }

    fn trimIgnorePatterns(self: *FilteredWalker, len: usize) void {
        while (self.ignore_patterns.items.len > len) {
            self.deinitIgnorePattern(self.ignore_patterns.pop().?);
        }
    }

    fn loadIgnoreFile(self: *FilteredWalker, dir: std.Io.Dir, base_dir: []const u8, file_name: []const u8) !void {
        if (dir.readFileAlloc(self.io, file_name, self.allocator, .limited(64 * 1024))) |content| {
            defer self.allocator.free(content);
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;

                var negated = false;
                var pattern = trimmed;
                if (pattern[0] == '!') {
                    negated = true;
                    pattern = pattern[1..];
                    if (pattern.len == 0) continue;
                }

                var anchored = false;
                if (pattern[0] == '/') {
                    anchored = true;
                    pattern = pattern[1..];
                    if (pattern.len == 0) continue;
                }

                var dir_only = false;
                if (std.mem.endsWith(u8, pattern, "/")) {
                    dir_only = true;
                    pattern = pattern[0 .. pattern.len - 1];
                    if (pattern.len == 0) continue;
                }

                const pattern_copy = try self.allocator.dupe(u8, pattern);
                errdefer self.allocator.free(pattern_copy);
                const base_copy: []const u8 = if (base_dir.len == 0)
                    &.{}
                else
                    try self.allocator.dupe(u8, base_dir);
                errdefer if (base_dir.len > 0) self.allocator.free(base_copy);

                try self.ignore_patterns.append(self.allocator, .{
                    .pattern = pattern_copy,
                    .base_dir = base_copy,
                    .anchored = anchored,
                    .dir_only = dir_only,
                    .negated = negated,
                    .has_slash = std.mem.indexOfScalar(u8, pattern, '/') != null,
                });
            }
        } else |_| {}
    }

    fn pathRelativeToBase(path: []const u8, base_dir: []const u8) ?[]const u8 {
        if (base_dir.len == 0) return path;
        if (!std.mem.startsWith(u8, path, base_dir)) return null;
        if (path.len == base_dir.len) return "";
        if (path[base_dir.len] != '/') return null;
        return path[base_dir.len + 1 ..];
    }

    fn patternMatches(pattern: IgnorePattern, name: []const u8, full_path: []const u8, is_dir: bool) bool {
        const rel_path = pathRelativeToBase(full_path, pattern.base_dir) orelse return false;
        if (rel_path.len == 0) return false;
        if (pattern.dir_only and !is_dir) return false;
        if (pattern.anchored or pattern.has_slash) {
            return explore_mod.matchGlob(pattern.pattern, rel_path);
        }
        return explore_mod.matchGlob(pattern.pattern, name);
    }

    fn isIgnored(self: *FilteredWalker, name: []const u8, full_path: []const u8, is_dir: bool) bool {
        var ignored = false;
        for (self.ignore_patterns.items) |pattern| {
            if (patternMatches(pattern, name, full_path, is_dir)) {
                ignored = !pattern.negated;
            }
        }
        return ignored;
    }

    pub fn next(self: *FilteredWalker) !?Entry {
        // Trim any filename appended by the previous yield
        self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);

        while (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];
            if (try top.iter.next(self.io)) |entry| {
                if (entry.kind == .directory) {
                    if (shouldSkipDir(entry.name)) continue;
                    if (self.ignore_patterns.items.len > 0) {
                        var check_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const check_path = if (self.dir_prefix_len > 0)
                            std.fmt.bufPrint(&check_buf, "{s}/{s}", .{ self.name_buffer.items[0..self.dir_prefix_len], entry.name }) catch entry.name
                        else
                            entry.name;
                        if (self.isIgnored(entry.name, check_path, true)) continue;
                    }
                    const sub = top.dir_handle.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
                    errdefer sub.close(self.io);
                    const saved_len = self.name_buffer.items.len;
                    const saved_prefix_len = self.dir_prefix_len;
                    const saved_ignore_len = self.ignore_patterns.items.len;
                    errdefer {
                        self.trimIgnorePatterns(saved_ignore_len);
                        self.dir_prefix_len = saved_prefix_len;
                        self.name_buffer.shrinkRetainingCapacity(saved_len);
                    }

                    if (self.name_buffer.items.len > 0)
                        try self.name_buffer.append(self.allocator, '/');
                    try self.name_buffer.appendSlice(self.allocator, entry.name);
                    self.dir_prefix_len = self.name_buffer.items.len;
                    try self.loadIgnoreFile(sub, self.name_buffer.items[0..self.dir_prefix_len], ".gitignore");

                    try self.stack.append(self.allocator, .{
                        .dir_handle = sub,
                        .iter = sub.iterate(),
                        .ignore_len = saved_ignore_len,
                    });
                    continue;
                }

                if (entry.kind != .file) {
                    if (entry.kind != .sym_link) continue;
                    const target_stat = top.dir_handle.statFile(self.io, entry.name, .{}) catch continue;
                    if (target_stat.kind == .directory) {
                        if (shouldSkipDir(entry.name)) continue;
                        if (self.ignore_patterns.items.len > 0) {
                            var check_buf: [std.fs.max_path_bytes]u8 = undefined;
                            const check_path = if (self.dir_prefix_len > 0)
                                std.fmt.bufPrint(&check_buf, "{s}/{s}", .{ self.name_buffer.items[0..self.dir_prefix_len], entry.name }) catch entry.name
                            else
                                entry.name;
                            if (self.isIgnored(entry.name, check_path, true)) continue;
                            if (path_security.isSensitivePath(check_path)) continue;
                        }
                        var link_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const link_path = if (self.dir_prefix_len > 0)
                            std.fmt.bufPrint(&link_path_buf, "{s}/{s}", .{ self.name_buffer.items[0..self.dir_prefix_len], entry.name }) catch entry.name
                        else
                            entry.name;
                        if (path_security.isSensitivePath(link_path)) continue;
                        var rt_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const rt_len = top.dir_handle.realPathFile(self.io, entry.name, &rt_buf) catch continue;
                        const real_target = rt_buf[0..rt_len];
                        if (self.real_root.len == 0) continue;
                        if (!std.mem.startsWith(u8, real_target, self.real_root)) continue;
                        if (real_target.len != self.real_root.len and real_target[self.real_root.len] != '/') continue;
                        if (path_security.relativeFromRealRoot(real_target, self.real_root)) |real_rel| {
                            if (path_security.isSensitivePath(real_rel)) continue;
                        } else continue;
                        const gop = self.visited_real_paths.getOrPut(self.allocator, real_target) catch continue;
                        if (gop.found_existing) continue;
                        const dup = self.allocator.dupe(u8, real_target) catch {
                            _ = self.visited_real_paths.remove(real_target);
                            continue;
                        };
                        gop.key_ptr.* = dup;
                        const sub = top.dir_handle.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
                        errdefer sub.close(self.io);
                        const saved_len_sym = self.name_buffer.items.len;
                        const saved_prefix_len_sym = self.dir_prefix_len;
                        const saved_ignore_len_sym = self.ignore_patterns.items.len;
                        errdefer {
                            self.trimIgnorePatterns(saved_ignore_len_sym);
                            self.dir_prefix_len = saved_prefix_len_sym;
                            self.name_buffer.shrinkRetainingCapacity(saved_len_sym);
                        }
                        if (self.name_buffer.items.len > 0)
                            try self.name_buffer.append(self.allocator, '/');
                        try self.name_buffer.appendSlice(self.allocator, entry.name);
                        self.dir_prefix_len = self.name_buffer.items.len;
                        try self.loadIgnoreFile(sub, self.name_buffer.items[0..self.dir_prefix_len], ".gitignore");
                        try self.stack.append(self.allocator, .{
                            .dir_handle = sub,
                            .iter = sub.iterate(),
                            .ignore_len = saved_ignore_len_sym,
                        });
                        continue;
                    }
                    if (target_stat.kind == .file) continue;
                    continue;
                }

                // Build full relative path by appending filename
                if (self.dir_prefix_len > 0)
                    try self.name_buffer.append(self.allocator, '/');
                try self.name_buffer.appendSlice(self.allocator, entry.name);

                if (self.ignore_patterns.items.len > 0 and self.isIgnored(entry.name, self.name_buffer.items, false)) {
                    self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);
                    continue;
                }

                return .{ .path = self.name_buffer.items };
            } else {
                if (self.stack.items.len > 1) {
                    var item = self.stack.pop().?;
                    self.trimIgnorePatterns(item.ignore_len);
                    item.dir_handle.close(self.io);
                } else {
                    _ = self.stack.pop();
                }
                if (std.mem.lastIndexOfScalar(u8, self.name_buffer.items[0..self.dir_prefix_len], '/')) |pos| {
                    self.dir_prefix_len = pos;
                } else {
                    self.dir_prefix_len = 0;
                }
                self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);
            }
        }
        return null;
    }
};

fn collectInitialScanEntries(io: std.Io, store: *Store, dir: std.Io.Dir, allocator: std.mem.Allocator, skip_trigram: bool) !std.ArrayList(InitialScanEntry) {
    var walker = try FilteredWalker.init(io, dir, allocator);
    defer walker.deinit();

    var entries: std.ArrayList(InitialScanEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    const max_trigram_files: usize = 15_000;
    var file_count: usize = 0;
    while (try walker.next()) |entry| {
        const stat = path_security.statSafeFile(io, dir, walker.real_root, entry.path) catch continue;
        _ = try store.recordSnapshot(entry.path, stat.size, 0);
        file_count += 1;
        try entries.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .skip_trigram = skip_trigram or (file_count > max_trigram_files),
        });
    }
    return entries;
}

fn parseInitialScanEntry(io: std.Io, root: []const u8, entry: InitialScanEntry, arena_alloc: std.mem.Allocator) !?ParsedScanFile {
    if (shouldSkipFile(entry.path)) return null;
    const dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    var real_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_root_len = try dir.realPathFile(io, ".", &real_root_buf);
    const real_root = real_root_buf[0..real_root_len];
    const stat = try path_security.statSafeFile(io, dir, real_root, entry.path);
    if (stat.size > 512 * 1024) return null;
    const content = try path_security.readFileAlloc(io, dir, real_root, entry.path, arena_alloc, .limited(512 * 1024));
    const check_len = @min(content.len, 512);
    for (content[0..check_len]) |c| {
        if (c == 0) return null;
    }
    // Threshold for including a file in the trigram index. Bumped from 64KB to
    // 1MB after the search-shootout bench (issue: large code files like
    // ReactFiberCompleteWork.js at 77KB were invisible to substring search,
    // causing agents to miss call sites in them). 1MB covers all reasonable
    // code files; minified/generated bundles past 1MB are correctly skipped.
    const effective_skip_trigram = entry.skip_trigram or (content.len > 1024 * 1024);
    const parsed = try explore_mod.Explorer.parseContentForIndexing(arena_alloc, entry.path, content);
    return .{
        .path = entry.path,
        .content = parsed.content,
        .outline = parsed.outline,
        .skip_trigram = effective_skip_trigram,
    };
}

fn initialScanWorker(io: std.Io, results: *WorkerParsedResults, root: []const u8, entries: []const InitialScanEntry) void {
    const arena_alloc = results.arena.allocator();
    for (entries) |entry| {
        const parsed = parseInitialScanEntry(io, root, entry, arena_alloc) catch null;
        if (parsed) |file| {
            results.items.append(arena_alloc, file) catch return;
        }
    }
}

pub fn initialScanWithWorkerCount(io: std.Io, store: *Store, explorer: *Explorer, root: []const u8, allocator: std.mem.Allocator, skip_trigram: bool, worker_count: usize) !void {
    const dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var entries = try collectInitialScanEntries(io, store, dir, allocator, skip_trigram);
    defer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    if (entries.items.len == 0) return;
    const n_workers = @max(@as(usize, 1), @min(worker_count, entries.items.len));
    if (n_workers == 1) {
        for (entries.items) |entry| {
            {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const parsed = try parseInitialScanEntry(io, root, entry, arena.allocator());
                if (parsed) |file| {
                    try explorer.commitParsedFileOwnedOutline(file.path, file.content, file.outline, true, file.skip_trigram);
                }
            }
        }
        return;
    }

    const workers = try allocator.alloc(WorkerParsedResults, n_workers);
    var workers_committed: usize = 0;
    defer {
        // Free any workers not yet committed (on error path)
        for (workers[workers_committed..]) |*worker| worker.deinit(allocator);
        allocator.free(workers);
    }
    const threads = try allocator.alloc(std.Thread, n_workers);
    defer allocator.free(threads);

    const chunk_size = entries.items.len / n_workers;
    const remainder = entries.items.len % n_workers;
    var offset: usize = 0;
    for (workers, 0..) |*worker, i| {
        worker.* = WorkerParsedResults.init(std.heap.page_allocator);
        const extra: usize = if (i < remainder) 1 else 0;
        const count = chunk_size + extra;
        const chunk = entries.items[offset .. offset + count];
        offset += count;
        threads[i] = try std.Thread.spawn(.{}, initialScanWorker, .{ io, worker, root, chunk });
    }
    for (threads) |thread| thread.join();

    for (workers) |*worker| {
        for (worker.items.items) |file| {
            try explorer.commitParsedFileOwnedOutline(file.path, file.content, file.outline, true, file.skip_trigram);
        }
        // Free this worker's arena immediately — releases pages to OS,
        // prevents holding all workers' content simultaneously.
        worker.deinit(allocator);
        workers_committed += 1;
    }
}

/// Fast scan: walk + parse outlines + build trigrams in one pass.
/// Avoids re-reading files for trigram build. Returns a TrigramIndex
/// allocated with the given trigram_alloc (caller owns).
fn readFileEntry(io: std.Io, root: []const u8, entry: InitialScanEntry, arena_alloc: std.mem.Allocator) ?struct { path: []const u8, content: []const u8 } {
    if (shouldSkipFile(entry.path)) return null;
    const dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return null;
    defer dir.close(io);
    var real_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_root_len = dir.realPathFile(io, ".", &real_root_buf) catch return null;
    const real_root = real_root_buf[0..real_root_len];
    const stat = path_security.statSafeFile(io, dir, real_root, entry.path) catch return null;
    if (stat.size > 512 * 1024) return null;
    const c = path_security.readFileAlloc(io, dir, real_root, entry.path, arena_alloc, .limited(512 * 1024)) catch return null;
    const check_len = @min(c.len, 512);
    for (c[0..check_len]) |ch| {
        if (ch == 0) return null;
    }
    return .{ .path = entry.path, .content = c };
}

const ReadResult = struct { path: []const u8, content: []const u8 };
const ReadResults = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(ReadResult),

    fn init(backing: std.mem.Allocator) ReadResults {
        return .{ .arena = std.heap.ArenaAllocator.init(backing), .items = .empty };
    }
    fn deinit(self: *ReadResults, _: std.mem.Allocator) void {
        self.items.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

fn readWorker(io: std.Io, results: *ReadResults, root: []const u8, entries: []const InitialScanEntry) void {
    const alloc = results.arena.allocator();
    for (entries) |entry| {
        if (readFileEntry(io, root, entry, alloc)) |r| {
            results.items.append(alloc, r) catch {};
        }
    }
}

const TriExtractEntry = TrigramIndex.BulkEntry;
const TriExtractResult = struct { path: []const u8, trigrams: []TriExtractEntry };
const TriExtractResults = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(TriExtractResult),
    fn init(backing: std.mem.Allocator) TriExtractResults {
        return .{ .arena = std.heap.ArenaAllocator.init(backing), .items = .empty };
    }
    fn deinit(self: *TriExtractResults, _: std.mem.Allocator) void {
        self.items.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

// Extract trigrams from a chunk of (path, content) entries that are already
// in memory — no file reads. Used by the cold-run non-search path to
// parallelize what was previously a serial main-thread loop.
const CachedEntry = struct { path: []const u8, content: []const u8 };

fn cachedTrigramExtractWorker(results: *TriExtractResults, entries: []const CachedEntry) void {
    const alloc = results.arena.allocator();
    const index_m = @import("index.zig");
    var local = std.AutoHashMap(index_m.Trigram, index_m.PostingMask).init(std.heap.c_allocator);
    defer local.deinit();
    local.ensureTotalCapacity(4096) catch {};
    for (entries) |entry| {
        if (entry.content.len > 1024 * 1024) continue;
        local.clearRetainingCapacity();
        if (entry.content.len >= 3) {
            for (0..entry.content.len - 2) |i| {
                const c0 = entry.content[i];
                const c1 = entry.content[i + 1];
                const c2 = entry.content[i + 2];
                if ((c0 == ' ' or c0 == '\t' or c0 == '\n' or c0 == '\r') and
                    (c1 == ' ' or c1 == '\t' or c1 == '\n' or c1 == '\r') and
                    (c2 == ' ' or c2 == '\t' or c2 == '\n' or c2 == '\r')) continue;
                const tri = index_m.packTrigram(index_m.normalizeChar(c0), index_m.normalizeChar(c1), index_m.normalizeChar(c2));
                const gop = local.getOrPut(tri) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = index_m.PostingMask{};
                gop.value_ptr.loc_mask |= @as(u8, 1) << @intCast(i % 8);
                if (i + 3 < entry.content.len) {
                    gop.value_ptr.next_mask |= @as(u8, 1) << @intCast(index_m.normalizeChar(entry.content[i + 3]) % 8);
                }
            }
        }
        const tri_entries = alloc.alloc(TriExtractEntry, local.count()) catch continue;
        var ti: usize = 0;
        var iter = local.iterator();
        while (iter.next()) |e| {
            tri_entries[ti] = .{ .tri = e.key_ptr.*, .mask = e.value_ptr.* };
            ti += 1;
        }
        results.items.append(alloc, .{ .path = entry.path, .trigrams = tri_entries }) catch {};
    }
}

/// Build a TrigramIndex from contents already in memory, parallelized across
/// `n_workers` threads. Caller owns the returned index (must deinit + destroy).
pub fn buildTrigramsFromCache(
    contents: *ContentCache,
    allocator: std.mem.Allocator,
    trigram_alloc: std.mem.Allocator,
    worker_count: usize,
) !*TrigramIndex {
    var tmp_tri = try trigram_alloc.create(TrigramIndex);
    tmp_tri.* = TrigramIndex.init(trigram_alloc);
    tmp_tri.owns_paths = true;
    tmp_tri.index.ensureTotalCapacity(131072) catch {};
    tmp_tri.path_to_id.ensureTotalCapacity(@intCast(@min(contents.count(), 65536))) catch {};

    if (contents.count() == 0) return tmp_tri;

    var entries: std.ArrayList(CachedEntry) = .empty;
    defer entries.deinit(allocator);
    try entries.ensureTotalCapacity(allocator, contents.count());
    var iter = contents.iterator();
    while (iter.next()) |e| {
        if (e.value_ptr.*.len > 1024 * 1024) continue;
        entries.appendAssumeCapacity(.{ .path = e.key_ptr.*, .content = e.value_ptr.* });
    }
    if (entries.items.len == 0) return tmp_tri;

    const n_workers = @max(@as(usize, 1), @min(worker_count, entries.items.len));
    if (n_workers == 1) {
        var results = TriExtractResults.init(std.heap.page_allocator);
        defer results.deinit(allocator);
        cachedTrigramExtractWorker(&results, entries.items);
        for (results.items.items) |r| tmp_tri.insertBulkNew(r.path, r.trigrams) catch {};
        return tmp_tri;
    }

    const extractors = try allocator.alloc(TriExtractResults, n_workers);
    var extractors_done: usize = 0;
    defer {
        for (extractors[extractors_done..]) |*r| r.deinit(allocator);
        allocator.free(extractors);
    }
    const threads = try allocator.alloc(std.Thread, n_workers);
    defer allocator.free(threads);

    const chunk_size = entries.items.len / n_workers;
    const remainder = entries.items.len % n_workers;
    var offset: usize = 0;
    for (extractors, 0..) |*ext, i| {
        ext.* = TriExtractResults.init(std.heap.page_allocator);
        const extra: usize = if (i < remainder) 1 else 0;
        const count = chunk_size + extra;
        const chunk = entries.items[offset .. offset + count];
        offset += count;
        threads[i] = try std.Thread.spawn(.{}, cachedTrigramExtractWorker, .{ ext, chunk });
    }
    for (threads) |t| t.join();

    for (extractors) |*ext| {
        for (ext.items.items) |r| tmp_tri.insertBulkNew(r.path, r.trigrams) catch {};
        ext.deinit(allocator);
        extractors_done += 1;
    }
    return tmp_tri;
}

fn trigramExtractWorker(io: std.Io, results: *TriExtractResults, root: []const u8, entries: []const InitialScanEntry) void {
    const alloc = results.arena.allocator();
    const index_m = @import("index.zig");
    var local = std.AutoHashMap(index_m.Trigram, index_m.PostingMask).init(std.heap.c_allocator);
    defer local.deinit();
    local.ensureTotalCapacity(4096) catch {};
    for (entries) |entry| {
        const r = readFileEntry(io, root, entry, alloc) orelse continue;
        if (r.content.len > 1024 * 1024) continue;
        local.clearRetainingCapacity();
        if (r.content.len >= 3) {
            for (0..r.content.len - 2) |i| {
                const c0 = r.content[i];
                const c1 = r.content[i + 1];
                const c2 = r.content[i + 2];
                if ((c0 == ' ' or c0 == '\t' or c0 == '\n' or c0 == '\r') and
                    (c1 == ' ' or c1 == '\t' or c1 == '\n' or c1 == '\r') and
                    (c2 == ' ' or c2 == '\t' or c2 == '\n' or c2 == '\r')) continue;
                const tri = index_m.packTrigram(index_m.normalizeChar(c0), index_m.normalizeChar(c1), index_m.normalizeChar(c2));
                const gop = local.getOrPut(tri) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = index_m.PostingMask{};
                gop.value_ptr.loc_mask |= @as(u8, 1) << @intCast(i % 8);
                if (i + 3 < r.content.len) {
                    gop.value_ptr.next_mask |= @as(u8, 1) << @intCast(index_m.normalizeChar(r.content[i + 3]) % 8);
                }
            }
        }
        const tri_entries = alloc.alloc(TriExtractEntry, local.count()) catch continue;
        var ti: usize = 0;
        var iter = local.iterator();
        while (iter.next()) |e| {
            tri_entries[ti] = .{ .tri = e.key_ptr.*, .mask = e.value_ptr.* };
            ti += 1;
        }
        results.items.append(alloc, .{ .path = r.path, .trigrams = tri_entries }) catch {};
    }
}
pub fn initialScanWithTrigrams(
    io: std.Io,
    store: *Store,
    explorer: *Explorer,
    root: []const u8,
    allocator: std.mem.Allocator,
    trigram_alloc: std.mem.Allocator,
    skip_outlines: bool,
) !?*TrigramIndex {
    const dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var entries = try collectInitialScanEntries(io, store, dir, allocator, true);
    defer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }
    if (entries.items.len == 0) return null;

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_workers = @max(@as(usize, 1), @min(@as(usize, @intCast(cpu_count)), @min(entries.items.len, 8)));

    // Single-worker fast path
    var tmp_tri = try trigram_alloc.create(TrigramIndex);
    tmp_tri.* = TrigramIndex.init(trigram_alloc);
    tmp_tri.owns_paths = true;
    // Pre-size to avoid resize copies during bulk insert (~99K unique trigrams typical)
    tmp_tri.index.ensureTotalCapacity(131072) catch {};
    tmp_tri.path_to_id.ensureTotalCapacity(@intCast(@min(entries.items.len, 65536))) catch {};

    if (n_workers == 1) {
        for (entries.items) |entry| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const parsed = parseInitialScanEntry(io, root, entry, arena.allocator()) catch null;
            if (parsed) |file| {
                if (!skip_outlines) {
                    explorer.commitParsedFileOwnedOutline(file.path, file.content, file.outline, true, true) catch continue;
                }
                // Build trigrams from same content — no re-read needed
                if (file.content.len <= 1024 * 1024) {
                    tmp_tri.indexFile(file.path, file.content) catch {};
                }
            }
        }
        return tmp_tri;
    }

    if (skip_outlines) {
        // Fast path: read files + extract trigrams in parallel workers
        const extractors = try allocator.alloc(TriExtractResults, n_workers);
        var extractors_done: usize = 0;
        defer {
            for (extractors[extractors_done..]) |*r| r.deinit(allocator);
            allocator.free(extractors);
        }
        const threads = try allocator.alloc(std.Thread, n_workers);
        defer allocator.free(threads);

        const chunk_size = entries.items.len / n_workers;
        const remainder = entries.items.len % n_workers;
        var offset: usize = 0;
        for (extractors, 0..) |*ext, i| {
            ext.* = TriExtractResults.init(std.heap.page_allocator);
            const extra: usize = if (i < remainder) 1 else 0;
            const count = chunk_size + extra;
            const chunk = entries.items[offset .. offset + count];
            offset += count;
            threads[i] = try std.Thread.spawn(.{}, trigramExtractWorker, .{ io, ext, root, chunk });
        }
        for (threads) |thread| thread.join();

        for (extractors) |*ext| {
            for (ext.items.items) |r| {
                tmp_tri.insertBulkNew(r.path, r.trigrams) catch {};
            }
            ext.deinit(allocator);
            extractors_done += 1;
        }
    } else {
        // Full path: parse outlines + build trigrams
        const workers = try allocator.alloc(WorkerParsedResults, n_workers);
        var workers_committed: usize = 0;
        defer {
            for (workers[workers_committed..]) |*worker| worker.deinit(allocator);
            allocator.free(workers);
        }
        const threads = try allocator.alloc(std.Thread, n_workers);
        defer allocator.free(threads);

        const chunk_size = entries.items.len / n_workers;
        const remainder = entries.items.len % n_workers;
        var offset: usize = 0;
        for (workers, 0..) |*worker, i| {
            worker.* = WorkerParsedResults.init(std.heap.page_allocator);
            const extra: usize = if (i < remainder) 1 else 0;
            const count = chunk_size + extra;
            const chunk = entries.items[offset .. offset + count];
            offset += count;
            threads[i] = try std.Thread.spawn(.{}, initialScanWorker, .{ io, worker, root, chunk });
        }
        for (threads) |thread| thread.join();

        for (workers) |*worker| {
            for (worker.items.items) |file| {
                explorer.commitParsedFileOwnedOutline(file.path, file.content, file.outline, true, true) catch continue;
                if (file.content.len <= 1024 * 1024) {
                    tmp_tri.indexFile(file.path, file.content) catch {};
                }
            }
            worker.deinit(allocator);
            workers_committed += 1;
        }
    }
    return tmp_tri;
}

/// Called from main thread to do the initial scan before listening.
pub fn initialScan(io: std.Io, store: *Store, explorer: *Explorer, root: []const u8, allocator: std.mem.Allocator, skip_trigram: bool) !void {
    const worker_count = blk: {
        if (cio.posixGetenv("CODEDB_SCAN_WORKERS")) |raw| {
            const parsed = std.fmt.parseInt(usize, raw, 10) catch 0;
            if (parsed > 0) break :blk parsed;
        }
        const cpu_count = std.Thread.getCpuCount() catch 1;
        break :blk @min(@as(usize, @intCast(cpu_count)), 8);
    };
    try initialScanWithWorkerCount(io, store, explorer, root, allocator, skip_trigram, worker_count);
}

/// Fast index: parse symbols/outline only, skip expensive word+trigram indexes.
fn indexFileOutline(io: std.Io, explorer: *Explorer, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) !void {
    if (shouldSkipFile(path)) return;
    var real_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_root_len = try dir.realPathFile(io, ".", &real_root_buf);
    const real_root = real_root_buf[0..real_root_len];
    const stat = try path_security.statSafeFile(io, dir, real_root, path);
    if (stat.size > 512 * 1024) return;
    const content = try path_security.readFileAlloc(io, dir, real_root, path, allocator, .limited(512 * 1024));
    defer allocator.free(content);
    const check_len = @min(content.len, 512);
    for (content[0..check_len]) |c| {
        if (c == 0) return;
    }
    try explorer.indexFileOutlineOnly(path, content);
}

/// Background thread: polls for incremental FS changes.
pub fn incrementalLoop(io: std.Io, store: *Store, explorer: *Explorer, queue: *EventQueue, root: []const u8, shutdown: *std.atomic.Value(bool), scan_done: *std.atomic.Value(bool)) void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const backing = gpa.allocator();

    // Wait for initial scan to finish before building our known-file snapshot.
    // This prevents double-indexing: initialScan does full indexing, then we
    // only pick up changes that happen after.
    while (!scan_done.load(.acquire)) {
        if (shutdown.load(.acquire)) return;
        cio.sleepMs(100);
    }

    var known = FileMap.init(backing);
    defer {
        var iter = known.iterator();
        while (iter.next()) |kv| {
            backing.free(kv.key_ptr.*);
        }
        known.deinit();
    }
    // Build initial snapshot: stat every file, defer expensive hashing until mtime changes.
    {
        var snap_arena = std.heap.ArenaAllocator.init(backing);
        defer snap_arena.deinit();
        const tmp = snap_arena.allocator();
        const dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var walker = FilteredWalker.init(io, dir, tmp) catch return;
        defer walker.deinit();
        while (walker.next() catch null) |entry| {
            const stat = path_security.statSafeFile(io, dir, walker.real_root, entry.path) catch continue;
            const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
            const duped = backing.dupe(u8, entry.path) catch continue;
            known.put(duped, .{ .mtime = mtime, .size = stat.size, .hash = 0, .seen = false }) catch backing.free(duped);
        }
    }

    // Track current git HEAD to detect branch switches (#116)
    var last_git_head: ?[40]u8 = git_mod.getGitHead(root, backing) catch null;

    // Cache .git/HEAD mtime so we only fork git rev-parse when the file changes (#254)
    var git_head_mtime: i128 = blk: {
        const root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch break :blk -1;
        defer root_dir.close(io);
        const st = root_dir.statFile(io, ".git/HEAD", .{}) catch break :blk -1;
        break :blk @intCast(st.mtime.nanoseconds);
    };

    while (!shutdown.load(.acquire)) {
        // Check for muonry edit notifications (instant re-index, no 2s delay)
        drainNotifyFile(io, store, explorer, queue, &known, root, backing);

        // Poll every 2s — gentle on CPU, fast enough to catch saves
        cio.sleepMs(2 * std.time.ns_per_s / 1_000_000);

        // Check if git HEAD changed — stat .git/HEAD mtime first to skip fork+exec (#254)
        var current_head: ?[40]u8 = last_git_head;
        const head_changed = blk: {
            {
                const root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch break :blk false;
                defer root_dir.close(io);
                const st = root_dir.statFile(io, ".git/HEAD", .{}) catch break :blk false;
                const st_mtime: i128 = @intCast(st.mtime.nanoseconds);
                if (st_mtime == git_head_mtime) break :blk false;
                git_head_mtime = st_mtime;
            }
            current_head = git_mod.getGitHead(root, backing) catch null;
            if (last_git_head == null and current_head == null) break :blk false;
            if (last_git_head == null or current_head == null) break :blk true;
            break :blk !std.mem.eql(u8, &last_git_head.?, &current_head.?);
        };

        if (head_changed) {
            std.log.info("git HEAD changed — re-scanning", .{});
            last_git_head = current_head;

            // Remove stale files from Explorer that may not exist on the new branch
            var remove_list: std.ArrayList([]const u8) = .empty;
            defer remove_list.deinit(backing);
            var kiter = known.iterator();
            while (kiter.next()) |kv| {
                remove_list.append(backing, kv.key_ptr.*) catch {};
            }
            for (remove_list.items) |path| {
                explorer.removeFile(path);
            }

            // Clear known map
            var kiter2 = known.iterator();
            while (kiter2.next()) |kv| backing.free(kv.key_ptr.*);
            known.clearRetainingCapacity();

            // Re-scan with trigram cap
            var rescan_arena = std.heap.ArenaAllocator.init(backing);
            defer rescan_arena.deinit();
            const tmp = rescan_arena.allocator();
            const dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var walker = FilteredWalker.init(io, dir, tmp) catch continue;
            defer walker.deinit();
            const max_trigram_files: usize = 15_000;
            var file_count: usize = 0;
            while (walker.next() catch null) |entry| {
                const stat = path_security.statSafeFile(io, dir, walker.real_root, entry.path) catch continue;
                _ = store.recordSnapshot(entry.path, stat.size, 0) catch {};
                file_count += 1;
                const effective_skip = file_count > max_trigram_files;
                indexFileContent(io, explorer, dir, entry.path, backing, effective_skip) catch {};
                const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
                const duped = backing.dupe(u8, entry.path) catch continue;
                known.put(duped, .{ .mtime = mtime, .size = stat.size, .hash = 0, .seen = false }) catch backing.free(duped);
            }
            continue;
        }

        // Each diff cycle gets its own arena so temporaries are freed
        var cycle_arena = std.heap.ArenaAllocator.init(backing);
        defer cycle_arena.deinit();

        incrementalDiff(io, store, explorer, queue, &known, root, backing, cycle_arena.allocator()) catch |err| {
            std.log.err("watcher: diff failed: {}", .{err});
        };
    }
}

fn hashFile(io: std.Io, dir: std.Io.Dir, path: []const u8, size: u64) !u64 {
    // Returns 0 for intentional skip (large files, filtered extensions).
    // Returns maxInt(u64) on IO error so the value always differs from a valid
    // previously stored hash of 0, preventing a false "content unchanged" conclusion.
    if (shouldSkipFile(path)) return 0;
    if (size > 512 * 1024) return 0;
    var real_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_root_len = dir.realPathFile(io, ".", &real_root_buf) catch return std.math.maxInt(u64);
    const real_root = real_root_buf[0..real_root_len];
    const file = path_security.openSafeFile(io, dir, real_root, path) catch return std.math.maxInt(u64);
    defer file.close(io);

    var hasher = std.hash.Wyhash.init(0);
    var buf: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = file.readPositionalAll(io, &buf, offset) catch return std.math.maxInt(u64);
        if (n == 0) break;
        hasher.update(buf[0..n]);
        offset += n;
        if (n < buf.len) break;
    }
    return hasher.final();
}

fn pushEventOrWait(queue: *EventQueue, event: FsEvent) void {
    // Preserve prior drop-on-full behavior so producer never stalls permanently.
    _ = queue.push(event);
}

fn incrementalDiff(io: std.Io, store: *Store, explorer: *Explorer, queue: *EventQueue, known: *FileMap, root: []const u8, persistent: std.mem.Allocator, tmp: std.mem.Allocator) !void {
    const dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    // Mark all known files unseen for this cycle.
    var known_iter = known.iterator();
    while (known_iter.next()) |kv| {
        kv.value_ptr.seen = false;
    }

    var walker = try FilteredWalker.init(io, dir, tmp);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const stat = path_security.statSafeFile(io, dir, walker.real_root, entry.path) catch continue;
        const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));

        if (known.getEntry(entry.path)) |known_entry| {
            const old = known_entry.value_ptr;
            old.seen = true;

            // Mtime unchanged -> skip (cheap path, no IO)
            if (old.mtime == mtime) continue;

            // Size changed -> definitely changed, skip expensive hash.
            var hash: u64 = 0;
            if (old.size == stat.size) {
                // Same size + changed mtime -> hash to confirm content actually differs.
                hash = hashFile(io, dir, entry.path, stat.size) catch 0;
            }
            if (old.size == stat.size and hash != 0 and old.hash != 0 and hash == old.hash) {
                // Content identical (e.g. touch, git checkout) -> update metadata only.
                old.mtime = mtime;
                old.size = stat.size;
                continue;
            }

            const seq = try store.recordSnapshot(entry.path, stat.size, hash);
            old.mtime = mtime;
            old.size = stat.size;
            old.hash = hash;
            const stable_path = known_entry.key_ptr.*;
            if (FsEvent.init(stable_path, .modified, seq)) |ev| pushEventOrWait(queue, ev);
            indexFileContent(io, explorer, dir, stable_path, tmp, false) catch {};
        } else {
            // New files always generate an event, so skip the extra full-file hash pass.
            const duped = try persistent.dupe(u8, entry.path);
            errdefer persistent.free(duped);
            const seq = try store.recordSnapshot(duped, stat.size, 0);
            try known.put(duped, .{ .mtime = mtime, .size = stat.size, .hash = 0, .seen = true });
            if (FsEvent.init(duped, .created, seq)) |ev| pushEventOrWait(queue, ev);
            indexFileContent(io, explorer, dir, duped, tmp, false) catch {};
        }
    }

    // Detect deleted files
    var to_remove: std.ArrayList([]const u8) = .empty;
    defer to_remove.deinit(tmp);

    var iter = known.iterator();
    while (iter.next()) |kv| {
        if (!kv.value_ptr.seen) {
            try to_remove.append(tmp, kv.key_ptr.*);
        }
    }
    for (to_remove.items) |path| {
        const seq = store.recordDelete(path, 0) catch continue;
        explorer.removeFile(path);
        if (known.fetchRemove(path)) |kv| {
            if (FsEvent.init(kv.key, .deleted, seq)) |ev| pushEventOrWait(queue, ev);
            persistent.free(kv.key);
        }
    }
}

const skip_extensions = [_][]const u8{
    ".png",     ".jpg",  ".jpeg", ".gif",  ".bmp",   ".ico",   ".icns",  ".webp",
    ".svg",     ".ttf",  ".otf",  ".woff", ".woff2", ".eot",   ".zip",   ".tar",
    ".gz",      ".bz2",  ".xz",   ".7z",   ".rar",   ".pdf",   ".doc",   ".docx",
    ".xls",     ".xlsx", ".pptx", ".mp3",  ".mp4",   ".wav",   ".avi",   ".mov",
    ".flv",     ".ogg",  ".webm", ".exe",  ".dll",   ".so",    ".dylib", ".o",
    ".a",       ".lib",  ".wasm", ".pyc",  ".pyo",   ".class", ".db",    ".sqlite",
    ".sqlite3", ".lock", ".sum",
};

fn shouldSkipFile(path: []const u8) bool {
    if (!path_security.isPathSafe(path)) return true;
    for (skip_extensions) |ext| {
        if (path_security.endsWithIgnoreCase(path, ext)) return true;
    }
    // Skip dotfiles like .DS_Store, .gitignore etc at any depth
    if (path_security.endsWithIgnoreCase(path, ".DS_Store")) return true;
    // Skip sensitive files (.env, credentials, keys) — same rules as snapshot filtering
    if (isSensitivePath(path)) return true;
    return false;
}

/// Check if a path refers to a sensitive file (secrets, keys, credentials).
/// Replicates the filter from snapshot.zig so live indexing and snapshots
/// apply the same exclusion rules. Optimized: basename check + early exit.
pub fn isSensitivePath(path: []const u8) bool {
    return path_security.isSensitivePath(path);
}

fn indexFileContent(io: std.Io, explorer: *Explorer, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator, skip_trigram: bool) !void {
    _ = allocator;
    if (shouldSkipFile(path)) return;
    var real_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_root_len = try dir.realPathFile(io, ".", &real_root_buf);
    const real_root = real_root_buf[0..real_root_len];
    const stat = try path_security.statSafeFile(io, dir, real_root, path);
    // Skip files over 512KB (likely minified bundles or generated)
    if (stat.size > 512 * 1024) return;
    // Use page_allocator arena for content — pages returned to OS immediately
    // via munmap on deinit, eliminating GPA page retention from content churn.
    var content_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer content_arena.deinit();
    const content = try path_security.readFileAlloc(io, dir, real_root, path, content_arena.allocator(), .limited(512 * 1024));
    // Skip binary content (check first 512 bytes for null bytes)
    const check_len = @min(content.len, 512);
    for (content[0..check_len]) |c| {
        if (c == 0) return;
    }
    // Skip trigram indexing for files > 64KB to prevent OOM on large repos
    const effective_skip_trigram = skip_trigram or (content.len > 1024 * 1024);
    if (effective_skip_trigram) {
        try explorer.indexFileSkipTrigram(path, content);
    } else {
        try explorer.indexFile(path, content);
    }
}

// ── muonry interop ───────────────────────────────────────────────────────────
//
// muonry appends changed file paths to /tmp/codedb-notify after each edit.
// We drain this file on every poll cycle and re-index the listed files
// immediately, eliminating the 2s polling delay for muonry-sourced edits.

fn drainNotifyFile(io: std.Io, store: *Store, explorer: *Explorer, queue: *EventQueue, known: *FileMap, root: []const u8, alloc: std.mem.Allocator) void {
    // Atomically read + truncate
    const notify_path = "/tmp/codedb-notify";
    const file = std.Io.Dir.cwd().openFile(io, notify_path, .{ .mode = .read_write }) catch return;
    defer file.close(io);

    const file_len = file.length(io) catch return;
    if (file_len == 0) return;
    const cap: u64 = 64 * 1024;
    const read_len: usize = @intCast(@min(file_len, cap));
    const data = alloc.alloc(u8, read_len) catch return;
    defer alloc.free(data);
    const n = file.readPositionalAll(io, data, 0) catch return;
    if (n == 0) return;
    const data_slice = data[0..n];

    // Truncate after reading
    file.setLength(io, 0) catch return;

    // Re-index each notified path
    const dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return;
    defer dir.close(io);
    var real_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_root_len = dir.realPathFile(io, ".", &real_root_buf) catch return;
    const real_root = real_root_buf[0..real_root_len];

    var lines = std.mem.splitScalar(u8, data_slice, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, " \t\r");
        if (path.len == 0) continue;

        // Make path relative to the canonical root if it is absolute.
        const rel = if (path[0] == '/') blk: {
            var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const real_path_len = std.Io.Dir.realPathFileAbsolute(io, path, &real_path_buf) catch continue;
            const real_path = real_path_buf[0..real_path_len];
            break :blk path_security.relativeFromRealRoot(real_path, real_root) orelse continue;
        } else path;
        if (!path_security.isPathSafe(rel) or path_security.isSensitivePath(rel)) continue;

        // Skip re-indexing if file hasn't changed since last known state (#228)
        const stat = path_security.statSafeFile(io, dir, real_root, rel) catch continue;
        const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
        if (known.getPtr(rel)) |existing| {
            if (existing.mtime == mtime and existing.size == stat.size) continue;
        }

        indexFileContent(io, explorer, dir, rel, alloc, false) catch continue;

        // Update known-file state so incrementalDiff doesn't double-process
        const hash = hashFile(io, dir, rel, stat.size) catch continue;
        if (known.getPtr(rel)) |existing| {
            existing.mtime = mtime;
            existing.size = stat.size;
            existing.hash = hash;
        }

        // Push event to queue
        if (FsEvent.init(rel, .modified, store.currentSeq())) |ev| {
            _ = queue.push(ev);
        }
    }
}
