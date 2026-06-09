const std = @import("std");
const testing = std.testing;
const io = std.testing.io;

const cio = @import("cio.zig");
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

fn runCompassTextWithSettings(
    alloc: std.mem.Allocator,
    explorer: *Explorer,
    store: *Store,
    data_dir: []const u8,
    req: compass.CompassRequest,
    settings: compass.Settings,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var out: std.ArrayList(u8) = .empty;
    compass.run(io, arena.allocator(), req, explorer, store, data_dir, settings, &out);
    return alloc.dupe(u8, out.items);
}

fn runCompassTextNoArena(
    alloc: std.mem.Allocator,
    explorer: *Explorer,
    store: *Store,
    data_dir: []const u8,
    req: compass.CompassRequest,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    compass.run(io, alloc, req, explorer, store, data_dir, .{}, &out);
    return alloc.dupe(u8, out.items);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn expectBefore(haystack: []const u8, first: []const u8, second: []const u8) !void {
    const first_idx = std.mem.indexOf(u8, haystack, first) orelse return error.MissingFirstNeedle;
    const second_idx = std.mem.indexOf(u8, haystack, second) orelse return error.MissingSecondNeedle;
    try testing.expect(first_idx < second_idx);
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

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try seedOverviewCorpus(&explorer);

    var store = Store.init(testing.allocator);
    defer store.deinit();

    for (cases) |case| {
        const output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
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
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try seedCallersPrecisionCorpus(&explorer);

    var store = Store.init(testing.allocator);
    defer store.deinit();

    const output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
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

test "compass: callers count uppercase namespace calls but exclude bare type references" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/construct.rs",
        \\pub struct Config;
        \\
        \\impl Config {
        \\    pub fn New() -> Self { Self }
        \\}
        \\
        \\pub fn boot() {
        \\    Config::New();
        \\    let _ctor = Config::New;
        \\}
    );
    try explorer.indexFile("src/event.rs",
        \\enum Event {
        \\    Started(i32),
        \\    Stopped,
        \\}
        \\
        \\fn build() {
        \\    let _event = Event::Started(42);
        \\    let _variant = Event::Started;
        \\    match _event {
        \\        Event::Started(code) => drop(code),
        \\        Event::Stopped => {}
        \\    }
        \\}
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();

    const new_output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "callers New",
        .intent = .callers,
        .target = "New",
    });
    defer testing.allocator.free(new_output);
    try expectContains(new_output, "## CALLERS showing 1 of 1");
    try expectContains(new_output, "src/construct.rs:8:     Config::New();");
    try expectNotContains(new_output, "Config::New;");

    const started_output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "callers Started",
        .intent = .callers,
        .target = "Started",
    });
    defer testing.allocator.free(started_output);
    try expectContains(started_output, "## CALLERS showing 1 of 1");
    try expectContains(started_output, "src/event.rs:7:     let _event = Event::Started(42);");
    try expectNotContains(started_output, "Event::Started;");
    try expectNotContains(started_output, "    Started,");
    try expectNotContains(started_output, "Event::Started(code) =>");
}

test "compass: default definition signature does not dump full symbol body" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

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

    const output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "definition of token_sink",
        .intent = .define,
    });
    defer testing.allocator.free(output);

    try expectContains(output, "signature: pub fn token_sink() {");
    try expectNotContains(output, "DEFAULT_SHOULD_NOT_DUMP_BODY");
}

test "compass: overview callers keep whole-word precision for weak prompts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try seedCallersPrecisionCorpus(&explorer);

    var store = Store.init(testing.allocator);
    defer store.deinit();

    const output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "what calls parseConfig",
    });
    defer testing.allocator.free(output);

    try expectContains(output, "## ROUTE overview target=parseConfig");
    try expectContains(output, "src/use_config.zig");
    try expectNotContains(output, "src/use_config_file.zig");
    try expectNotContains(output, "parseConfigFile();");
}

test "issue-C03: blast radius prompt binds single-hump PascalCase target" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/config.rs",
        \\pub struct Config;
        \\pub fn change() {}
        \\
        \\pub fn boot() {
        \\    let _config = Config;
        \\    change();
        \\}
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();

    const output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "what breaks if I change Config",
    });
    defer testing.allocator.free(output);

    try expectContains(output, "## ROUTE blast_radius target=Config");
    try expectNotContains(output, "target=change");
}

test "compass: overview expands weak phrases and demotes snapshot artifacts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try seedWeakOverviewPhraseCorpus(&explorer);

    var store = Store.init(testing.allocator);
    defer store.deinit();

    const output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
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
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

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

    const mcp_output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "where are MCP tools defined and dispatched",
    });
    defer testing.allocator.free(mcp_output);
    try expectContains(mcp_output, "## ROUTE overview target=MCP");
    try expectContains(mcp_output, "- MCP");
    try expectNotContains(mcp_output, "- are");
    try expectNotContains(mcp_output, "- and");

    const shell_output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
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

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();

    for (bad_tokens) |token| {
        const output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
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

test "issue-C02: callers exclude string and multi-line block comment matches" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/config.zig",
        \\pub fn parseConfig() void {}
        \\
        \\pub fn run() void {
        \\    parseConfig();
        \\    const label = "parseConfig() is shown in help text";
        \\    /*
        \\       parseConfig();
        \\    */
        \\}
    );

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try compass.collectCallers(&explorer, arena.allocator(), "parseConfig");

    try testing.expectEqual(@as(usize, 1), result.callers.len);
    try testing.expectEqualStrings("src/config.zig", result.callers[0].path);
    try testing.expectEqual(@as(u32, 4), result.callers[0].line);
    try testing.expectEqual(@as(usize, 2), result.comment_string_rejects);
}

test "issue-C12: callers keep uppercase qualified constructor calls" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/factory.rs",
        \\pub struct Config;
        \\
        \\impl Config {
        \\    pub fn New() -> Config { Config }
        \\}
        \\
        \\pub enum Event {
        \\    Started(i32),
        \\    Stopped,
        \\}
        \\
        \\pub enum Input {
        \\    Name(String),
        \\    Config {
        \\        name: String,
        \\    },
        \\}
        \\
        \\fn build() {
        \\    let _ = Config::New();
        \\    let _ = Event::Started(42);
        \\    match Event::Started(7) {
        \\        Event::Started(code) => drop(code),
        \\        Event::Stopped => {}
        \\    }
        \\    match maybe_input() {
        \\        Some(Input::Config(config)) => drop(config),
        \\        Some(Input::Name(name)) => drop(name),
        \\        None => {}
        \\    }
        \\}
        \\
        \\fn references() {
        \\    let _ctor = Config::New;
        \\    let _variant = Event::Started;
        \\}
    );

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const new_result = try compass.collectCallers(&explorer, aa, "New");
    try testing.expectEqual(@as(usize, 1), new_result.callers.len);
    try expectContains(new_result.callers[0].text, "Config::New()");
    try testing.expectEqual(@as(usize, 1), new_result.type_position_rejects);

    const config_result = try compass.collectCallers(&explorer, aa, "Config");
    var saw_config_call = false;
    for (config_result.callers) |caller| {
        if (std.mem.indexOf(u8, caller.text, "Config::New()") != null) saw_config_call = true;
        try expectNotContains(caller.text, "Input::Config(config)");
        try expectNotContains(caller.text, "= Config::New;");
    }
    try testing.expect(saw_config_call);

    try explorer.indexFile("src/settings.rs",
        \\pub enum Env {
        \\    Settings {
        \\        name: String,
        \\    },
        \\}
    );
    const settings_result = try compass.collectCallers(&explorer, aa, "Settings");
    try testing.expectEqual(@as(usize, 0), settings_result.callers.len);
    try testing.expect(settings_result.type_position_rejects > 0);

    const started_result = try compass.collectCallers(&explorer, aa, "Started");
    try testing.expectEqual(@as(usize, 2), started_result.callers.len);
    try expectContains(started_result.callers[0].text, "Event::Started(42)");
    try expectContains(started_result.callers[1].text, "Event::Started(7)");
    try testing.expectEqual(@as(usize, 3), started_result.type_position_rejects);
}

test "issue-C01: callers keep calls in const and static initializers" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/init.rs",
        \\fn real_call() {}
        \\const VALUE: () = real_call();
        \\static OTHER: () = real_call();
    );

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try compass.collectCallers(&explorer, arena.allocator(), "real_call");

    try testing.expectEqual(@as(usize, 2), result.callers.len);
    try testing.expectEqual(@as(usize, 0), result.import_type_rejects);
    try expectContains(result.callers[0].text, "real_call();");
    try expectContains(result.callers[1].text, "real_call();");
}

test "issue-C06: callers disclose case variants and use trigram fallback" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/case.rs",
        \\fn Foo() {}
        \\fn use_case() {
        \\    Foo();
        \\    foo();
        \\}
    );
    try explorer.indexFile("src/qualified.rs",
        \\fn use_qualified() {
        \\    foo::bar();
        \\}
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();

    const case_output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "callers Foo",
        .intent = .callers,
        .target = "Foo",
    });
    defer testing.allocator.free(case_output);
    try expectContains(case_output, "Foo();");
    try expectNotContains(case_output, "foo();");
    try expectContains(case_output, "case-variant-only lines");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fallback = try compass.collectCallers(&explorer, arena.allocator(), "foo::bar");
    try testing.expectEqual(@as(usize, 1), fallback.callers.len);
    try testing.expect(!fallback.word_index_used);
    try expectContains(fallback.callers[0].text, "foo::bar();");
}

test "issue-C16: callers disclose gather-capped lower-bound totals" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/target.rs", "fn capped_target() {}\n");
    for (0..8) |i| {
        const path = try std.fmt.allocPrint(testing.allocator, "src/caller_{d}.rs", .{i});
        defer testing.allocator.free(path);
        const body = try std.fmt.allocPrint(testing.allocator,
            \\fn caller_{d}() {{
            \\    capped_target();
            \\}}
        , .{i});
        defer testing.allocator.free(body);
        try explorer.indexFile(path, body);
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try compass.gatherCallersExact(&explorer, arena.allocator(), "capped_target", 3);
    try testing.expect(result.gather_capped);
    try testing.expect(result.candidate_lines > 3);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    const output = try runCompassTextWithSettings(testing.allocator, &explorer, &store, data_dir, .{
        .task = "callers capped_target",
        .intent = .callers,
        .target = "capped_target",
    }, .{ .callers_candidate_budget = 3 });
    defer testing.allocator.free(output);
    try expectContains(output, "totals are a lower bound");
}

test "issue-C17: overview caller list cap preserves honest total" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/target.rs", "pub fn target_fn() {}\n");
    for (0..205) |i| {
        const path = try std.fmt.allocPrint(testing.allocator, "src/many/caller_{d}.rs", .{i});
        defer testing.allocator.free(path);
        const body = try std.fmt.allocPrint(testing.allocator,
            \\pub fn caller_{d}() {{
            \\    target_fn();
            \\}}
        , .{i});
        defer testing.allocator.free(body);
        try explorer.indexFile(path, body);
    }

    var store = Store.init(testing.allocator);
    defer store.deinit();
    const output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "how does target_fn work",
        .intent = .overview,
        .target = "target_fn",
        .max_files = 100,
    });
    defer testing.allocator.free(output);

    try expectContains(output, "## CALLERS showing 200 of 205");
    try expectContains(output, "overview callers list capped at 200 of 205");
}

test "issue-C19: overview demotes generated lock and vendor files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/widget.rs", "pub fn WidgetSignal() {}\n");
    try explorer.indexFile("src/widget.pb.rs", "pub fn WidgetSignal_pb() { WidgetSignal(); }\n");
    try explorer.indexFile("src/widget_generated.rs", "pub fn WidgetSignal_generated() { WidgetSignal(); }\n");
    try explorer.indexFile("Cargo.lock", "WidgetSignal WidgetSignal WidgetSignal\n");
    try explorer.indexFile("vendor/widget.rs", "pub fn vendored() { WidgetSignal(); }\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    const output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "what does WidgetSignal look like here",
        .intent = .overview,
        .target = "WidgetSignal",
        .max_files = 5,
    });
    defer testing.allocator.free(output);

    try expectContains(output, "src/widget.rs");
    try expectBefore(output, "src/widget.rs", "src/widget.pb.rs");
    try expectBefore(output, "src/widget.rs", "src/widget_generated.rs");
    try expectBefore(output, "src/widget.rs", "Cargo.lock");
    try expectBefore(output, "src/widget.rs", "vendor/widget.rs");
}

test "issue-C30: blast radius reports depth buckets and no-target fallback" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/core.zig", "pub fn blastTarget() void {}\n");
    try explorer.indexFile("src/direct.zig", "const core = @import(\"core.zig\");\npub fn direct() void { core.blastTarget(); }\n");
    try explorer.indexFile("src/indirect.zig", "const direct = @import(\"direct.zig\");\npub fn indirect() void { direct.direct(); }\n");

    var deps_direct: std.ArrayList([]const u8) = .empty;
    try deps_direct.append(testing.allocator, "src/core.zig");
    try explorer.dep_graph.setDeps("src/direct.zig", deps_direct);
    var deps_indirect: std.ArrayList([]const u8) = .empty;
    try deps_indirect.append(testing.allocator, "src/direct.zig");
    try explorer.dep_graph.setDeps("src/indirect.zig", deps_indirect);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    const output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "blast radius blastTarget",
        .intent = .blast_radius,
        .target = "blastTarget",
    });
    defer testing.allocator.free(output);
    try expectContains(output, "- depth 1: 1 files");
    try expectContains(output, "- depth 2: 1 files");

    const fallback = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "blast radius",
        .intent = .blast_radius,
    });
    defer testing.allocator.free(fallback);
    try expectContains(fallback, "## ROUTE overview target=none");
}

test "issue-C34: overview discloses callee cap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    const writer = cio.listWriter(&body, testing.allocator);
    try body.appendSlice(testing.allocator, "pub fn entry() void {\n");
    for (0..70) |i| {
        try writer.print("    callee{d}();\n", .{i});
    }
    try body.appendSlice(testing.allocator, "}\n");
    for (0..70) |i| {
        try writer.print("pub fn callee{d}() void {{}}\n", .{i});
    }
    try explorer.indexFile("src/entry.zig", body.items);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    const output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "how does entry work",
        .intent = .overview,
        .target = "entry",
        .max_files = 5,
    });
    defer testing.allocator.free(output);
    try expectContains(output, "## CALLEES showing 5 of 64");
    try expectContains(output, "overview callees capped at 64 per inspected definition");
}

test "issue-C35: detail first-line trimming handles multiline detail" {
    try testing.expectEqualStrings("pub fn sample() void {", compass.detailFirstLineForTest("pub fn sample() void {\n    body();\n}"));
    try testing.expectEqualStrings("pub fn sample() void {", compass.detailFirstLineForTest("pub fn sample() void {\r\n    body();"));
}

test "issue-C38: define fallback sites render without blank rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/text.rs",
        \\fn unrelated() {
        \\    let value = "fallbackNeedle";
        \\}
    );
    try explorer.indexFile("src/text2.rs",
        \\fn unrelated_two() {
        \\    let other = "fallbackNeedle";
        \\}
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();
    const output = try runCompassText(testing.allocator, &explorer, &store, data_dir, .{
        .task = "definition of fallbackNeedle",
        .intent = .define,
        .target = "fallbackNeedle",
    });
    defer testing.allocator.free(output);

    try expectContains(output, "src/text.rs:2:     let value = \"fallbackNeedle\";");
    try expectContains(output, "src/text2.rs:2:     let other = \"fallbackNeedle\";");
    try expectNotContains(output, "fallbackNeedle\";\n\n- src/text");
}

test "issue-C20-C29: minimal mode frees owned render buffers with testing allocator" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/render.zig",
        \\pub fn renderPage() void {
        \\    renderChild();
        \\}
        \\
        \\pub fn renderChild() void {}
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    compass.run(io, testing.allocator, .{
        .task = "definition of renderPage",
        .intent = .define,
        .mode = .minimal,
    }, &explorer, &store, data_dir, .{}, &out);

    try expectContains(out.items, "## DEFS");
    try expectContains(out.items, "renderPage");
    try expectNotContains(out.items, "## ROUTE");
}

test "compass: minimal overflow replay releases owned buffers without arena masking" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try makeTempDataDir(testing.allocator, tmp);
    defer testing.allocator.free(data_dir);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try seedOverviewCorpus(&explorer);
    try explorer.indexFile("src/minimal_scene.zig",
        \\pub fn composeMinimalScene() void {
        \\    render();
        \\    render();
        \\    render();
        \\}
    );
    try explorer.indexFile("src/minimal_sidebar.zig", "pub fn renderMinimalSidebar() void { render(); }\n");
    try explorer.indexFile("src/minimal_modal.zig", "pub fn renderMinimalModal() void { render(); }\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();

    const first = try runCompassTextNoArena(testing.allocator, &explorer, &store, data_dir, .{
        .task = "show render flow",
        .max_files = 1,
        .mode = .minimal,
    });
    defer testing.allocator.free(first);
    try expectContains(first, "## MORE reqid=");
    try expectNotContains(first, "--- stages ---");

    const token = try moreToken(first);
    const replay = try runCompassTextNoArena(testing.allocator, &explorer, &store, data_dir, .{
        .more = token,
        .mode = .minimal,
        .mode_explicit = true,
    });
    defer testing.allocator.free(replay);
    try expectNotContains(replay, "## MORE reqid=");
    try expectNotContains(replay, "--- stages ---");
    try expectContains(replay, "src/minimal_scene.zig");
}
