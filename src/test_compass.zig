const std = @import("std");
const testing = std.testing;
const io = std.testing.io;

const Explorer = @import("explore.zig").Explorer;
const Store = @import("store.zig").Store;
const compass = @import("compass.zig");

fn runCompassText(
    alloc: std.mem.Allocator,
    explorer: *Explorer,
    store: *Store,
    data_dir: []const u8,
    req: compass.CompassRequest,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var out: std.ArrayList(u8) = .empty;
    compass.run(io, arena.allocator(), req, explorer, store, data_dir, .{}, &out);
    return alloc.dupe(u8, out.items);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn moreToken(output: []const u8) ![]const u8 {
    const marker = "## MORE reqid=";
    const start = std.mem.indexOf(u8, output, marker) orelse return error.MissingMoreToken;
    const token_start = start + marker.len;
    const token_end = std.mem.indexOfPos(u8, output, token_start, "\n") orelse output.len;
    return output[token_start..token_end];
}

fn withoutMoreTrailer(output: []const u8) []const u8 {
    const marker = "\n## MORE reqid=";
    const start = std.mem.indexOf(u8, output, marker) orelse return output;
    return output[0..start];
}

fn makeTempDataDir(alloc: std.mem.Allocator, tmp: anytype) ![]u8 {
    return std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/compass-data", .{tmp.sub_path});
}

fn seedOverviewCorpus(explorer: *Explorer) !void {
    try explorer.indexFile("src/auth.zig",
        \\pub fn auth() void {}
        \\
        \\pub fn authorize() void {
        \\    auth();
        \\}
    );
    try explorer.indexFile("src/login.zig",
        \\pub fn login() void {
        \\    auth();
        \\}
    );
    try explorer.indexFile("src/render.zig",
        \\pub fn render() void {
        \\    auth();
        \\}
    );
    try explorer.indexFile("src/page.zig",
        \\pub fn renderPage() void {
        \\    render();
        \\}
    );
}

fn seedCallersPrecisionCorpus(explorer: *Explorer) !void {
    try explorer.indexFile("src/config.zig", "pub fn parseConfig() void {}\n");
    try explorer.indexFile("src/config_file.zig", "pub fn parseConfigFile() void {}\n");
    try explorer.indexFile("src/use_config.zig",
        \\pub fn loadConfig() void {
        \\    parseConfig();
        \\}
    );
    try explorer.indexFile("src/use_config_file.zig",
        \\pub fn loadConfigFile() void {
        \\    parseConfigFile();
        \\}
    );
}

fn seedWeakOverviewPhraseCorpus(explorer: *Explorer) !void {
    try explorer.indexFile("src/web_search.rs",
        \\pub fn web_search_action_detail() void {}
        \\
        \\pub fn run_web_search() void {
        \\    web_search_action_detail();
        \\}
    );
    try explorer.indexFile("src/web_search_config.rs",
        \\pub const WebSearchMode = enum { cached, live };
        \\
        \\pub fn enable_web_search(mode: WebSearchMode) void {
        \\    _ = mode;
        \\}
    );
    try explorer.indexFile("src/web_search_history.rs",
        \\pub fn record_web_search(query: []const u8) void {
        \\    _ = query;
        \\}
    );
    try explorer.indexFile("src/browser_search.rs",
        \\pub fn browser_search(query: []const u8) void {
        \\    // web search entry point for the browser integration
        \\    _ = query;
        \\}
    );
    try explorer.indexFile("src/search_runtime.rs",
        \\pub fn search_runtime() void {
        \\    // web search requests eventually flow through this runtime.
        \\}
    );
    try explorer.indexFile("tests/snapshots/web_search_history.snap",
        \\web search web search web search
        \\web search snapshot transcript
        \\web search event details
    );
}

test "compass: weak natural-language prompts stay broad and honest" {
    const Case = struct {
        prompt: []const u8,
        target: []const u8,
        section: []const u8,
        alt: ?[]const u8 = null,
    };

    const cases = [_]Case{
        .{ .prompt = "what calls auth", .target = "auth", .section = "## CALLERS", .alt = "callers" },
        .{ .prompt = "definition of render", .target = "render", .section = "## DEFS", .alt = "define" },
        .{ .prompt = "what does auth look like here", .target = "auth", .section = "## DEFS" },
        .{ .prompt = "show render flow", .target = "render", .section = "## FILES" },
    };

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try seedOverviewCorpus(&explorer);

    var store = Store.init(testing.allocator);
    defer store.deinit();

    for (cases) |case| {
        const output = try runCompassText(testing.allocator, &explorer, &store, ".", .{
            .task = case.prompt,
        });
        defer testing.allocator.free(output);

        const expected_route = try std.fmt.allocPrint(testing.allocator, "## ROUTE overview target={s}", .{case.target});
        defer testing.allocator.free(expected_route);

        try expectContains(output, expected_route);
        try expectContains(output, case.section);
        try expectContains(output, "## COVERAGE");
        if (case.alt) |alt| {
            const expected_alt = try std.fmt.allocPrint(testing.allocator, "## ALTS {s}", .{alt});
            defer testing.allocator.free(expected_alt);
            try expectContains(output, expected_alt);
        } else {
            try expectNotContains(output, "## ALTS ");
        }
        try expectNotContains(output, "## ROUTE callers ");
        try expectNotContains(output, "## ROUTE define ");
    }
}

test "compass: callers precision rejects substring matches like parseConfigFile" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try seedCallersPrecisionCorpus(&explorer);

    var store = Store.init(testing.allocator);
    defer store.deinit();

    const output = try runCompassText(testing.allocator, &explorer, &store, ".", .{
        .task = "what calls parseConfig",
        .intent = .callers,
    });
    defer testing.allocator.free(output);

    try expectContains(output, "## ROUTE callers target=parseConfig confidence=explicit");
    try expectContains(output, "src/use_config.zig");
    try expectContains(output, "substring-only hits");
    try expectNotContains(output, "src/config_file.zig");
    try expectNotContains(output, "parseConfigFile();");
}

test "compass: default definition signature does not dump full symbol body" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/sample.rs",
        \\pub fn token_sink() {
        \\    let a = 1;
        \\    let b = 2;
        \\    let c = 3;
        \\    let d = 4;
        \\    let e = 5;
        \\    let marker = "DEFAULT_SHOULD_NOT_DUMP_BODY";
        \\    drop((a, b, c, d, e, marker));
        \\}
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();

    const output = try runCompassText(testing.allocator, &explorer, &store, ".", .{
        .task = "definition of token_sink",
        .intent = .define,
    });
    defer testing.allocator.free(output);

    try expectContains(output, "signature: pub fn token_sink() {");
    try expectNotContains(output, "DEFAULT_SHOULD_NOT_DUMP_BODY");
}

test "compass: overview callers keep whole-word precision for weak prompts" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try seedCallersPrecisionCorpus(&explorer);

    var store = Store.init(testing.allocator);
    defer store.deinit();

    const output = try runCompassText(testing.allocator, &explorer, &store, ".", .{
        .task = "what calls parseConfig",
    });
    defer testing.allocator.free(output);

    try expectContains(output, "## ROUTE overview target=parseConfig");
    try expectContains(output, "src/use_config.zig");
    try expectNotContains(output, "src/use_config_file.zig");
    try expectNotContains(output, "parseConfigFile();");
}

test "compass: overview expands weak phrases and demotes snapshot artifacts" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try seedWeakOverviewPhraseCorpus(&explorer);

    var store = Store.init(testing.allocator);
    defer store.deinit();

    const output = try runCompassText(testing.allocator, &explorer, &store, ".", .{
        .task = "what does web search look like here",
    });
    defer testing.allocator.free(output);

    try expectContains(output, "## ROUTE overview target=search");
    try expectContains(output, "## KEYWORDS");
    try expectContains(output, "- web");
    try expectContains(output, "- search");
    try expectContains(output, "- web search");
    try expectContains(output, "src/web_search.rs");
    try expectContains(output, "src/web_search_config.rs");
    try expectNotContains(output, "tests/snapshots/web_search_history.snap");
}

test "compass: overview ignores sentence scaffolding words as routing anchors" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/mcp_tools.zig",
        \\pub const MCP_TOOLS = 1;
        \\pub fn dispatch_mcp_tool() void {}
    );
    try explorer.indexFile("src/shell_approval.zig",
        \\pub fn approve_shell_command() void {}
        \\pub fn shell_command_approval_flow() void {
        \\    approve_shell_command();
        \\}
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();

    const mcp_output = try runCompassText(testing.allocator, &explorer, &store, ".", .{
        .task = "where are MCP tools defined and dispatched",
    });
    defer testing.allocator.free(mcp_output);
    try expectContains(mcp_output, "## ROUTE overview target=MCP");
    try expectContains(mcp_output, "- MCP");
    try expectNotContains(mcp_output, "- are");
    try expectNotContains(mcp_output, "- and");

    const shell_output = try runCompassText(testing.allocator, &explorer, &store, ".", .{
        .task = "how does shell command approval work",
    });
    defer testing.allocator.free(shell_output);
    try expectContains(shell_output, "## ROUTE overview target=approval");
    try expectNotContains(shell_output, "target=work");
}

test "compass: invalid more tokens are rejected before any replay" {
    const bad_tokens = [_][]const u8{
        "",
        "abcd",
        "../deadbeefdead",
        "DEADBEEFDEADBEEF",
        "123456789012345g",
        "/tmp/1234567890123456",
    };

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();

    for (bad_tokens) |token| {
        const output = try runCompassText(testing.allocator, &explorer, &store, ".", .{
            .more = token,
        });
        defer testing.allocator.free(output);
        try testing.expectEqualStrings("error: invalid more token", output);
    }
}

test "compass: truncated results persist and replay through more handles" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try seedOverviewCorpus(&explorer);
    try explorer.indexFile("src/scene.zig",
        \\pub fn composeScene() void {
        \\    render();
        \\    renderBackground();
        \\    render();
        \\    render();
        \\    renderForeground();
        \\    render();
        \\}
    );
    try explorer.indexFile("src/sidebar.zig", "pub fn renderSidebar() void { render(); }\n");
    try explorer.indexFile("src/modal.zig", "pub fn renderModal() void { render(); }\n");
    try explorer.indexFile("src/footer.zig", "pub fn renderFooter() void { render(); }\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();

    const first = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "show render flow",
        .max_files = 1,
    });
    defer testing.allocator.free(first);

    try expectContains(first, "## MORE reqid=");
    try expectContains(first, "files showing 1 of");
    try expectContains(first, "sites showing 1 of");
    try expectContains(first, "callers showing 2 of");

    const token = try moreToken(first);
    try testing.expectEqual(@as(usize, 16), token.len);

    const artifact_path = try std.fmt.allocPrint(testing.allocator, "{s}/compass/{s}.json", .{ data_dir, token });
    defer testing.allocator.free(artifact_path);
    const artifact = try std.Io.Dir.cwd().readFileAlloc(io, artifact_path, testing.allocator, .limited(256 * 1024));
    defer testing.allocator.free(artifact);
    try expectContains(artifact, "\"manifest\"");

    const replay = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .more = token,
    });
    defer testing.allocator.free(replay);

    try expectNotContains(replay, "## MORE reqid=");
    try testing.expect(!std.mem.eql(u8, withoutMoreTrailer(first), replay));
    try expectContains(replay, "files showing");
    try expectNotContains(replay, "files showing 1 of");
    try expectContains(replay, "sites showing");
    try expectNotContains(replay, "sites showing 1 of");
    try expectContains(replay, "callers showing");
    try expectNotContains(replay, "callers showing 2 of");
    try expectContains(replay, "src/footer.zig");
    try expectContains(replay, "src/scene.zig:7:     render();");
}

test "compass: stale more handles are rejected after generation changes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try seedOverviewCorpus(&explorer);
    try explorer.indexFile("src/scene.zig",
        \\pub fn composeScene() void {
        \\    render();
        \\    render();
        \\}
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();

    const first = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "show render flow",
        .max_files = 1,
    });
    defer testing.allocator.free(first);

    const token = try moreToken(first);
    try explorer.indexFile("src/new_file.zig", "pub fn later() void {}\n");

    const replay = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .more = token,
    });
    defer testing.allocator.free(replay);

    try testing.expectEqualStrings("overflow stale, re-run query", replay);
}
