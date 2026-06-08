const std = @import("std");
const cio = @import("cio.zig");
const explore_mod = @import("explore.zig");
const Explorer = explore_mod.Explorer;
const Store = @import("store.zig").Store;
const path_security = @import("path_security.zig");
const render_mod = @import("compass_render.zig");
const reader_md = @import("reader_md.zig");
const shared = @import("compass_shared.zig");

pub const Intent = enum { overview, define, callers };
pub const Mode = enum { summary, evidence, raw };
pub const Format = enum { text, json };

pub const Settings = struct {
    max_files: u32 = 5,
    body: bool = false,
    overflow_keep: u32 = 50,
};

pub var default_settings: Settings = .{};

pub const CompassRequest = struct {
    intent: ?Intent = null,
    task: []const u8 = "",
    target: ?[]const u8 = null,
    want_body: ?bool = null,
    max_files: ?u32 = null,
    mode: Mode = .summary,
    format: Format = .text,
    more: ?[]const u8 = null,
};

const AnchorKind = enum { quoted, path, identifier, word };
const Confidence = enum { explicit, strong, weak };
const RouteState = enum { exact, ambiguous, fallback };

const Anchor = struct {
    text: []const u8,
    kind: AnchorKind,
    salience: u8,
};

const Route = struct {
    intent: Intent,
    target: ?Anchor,
    confidence: Confidence,
    state: RouteState,
    runner_up: ?Intent = null,
    rationale: []const u8,
};

const Generation = struct {
    seq: u64,
    files: u32,
};

const StoredArtifact = struct {
    route_line: []const u8,
    alt_line: ?[]const u8,
    coverage: []const render_mod.CoverageRow,
    limits: []const []const u8,
    full_text: []const u8,
};

const DefinitionItem = struct {
    name: []const u8,
    kind: []const u8,
    path: []const u8,
    line: u32,
    line_end: u32,
    detail: ?[]const u8 = null,
    snippet: ?[]const u8 = null,
};

const SiteItem = struct {
    path: []const u8,
    line: u32,
    text: []const u8,
};

const OverviewPerFile = struct {
    total: u32 = 0,
    score: f32 = 0,
    sites: std.ArrayList(SiteItem) = .empty,
};

const RankedFile = struct {
    path: []const u8,
    hits: u32,
    score: f32,
    sites: []const SiteItem,
};

const CallerItem = struct {
    path: []const u8,
    line: u32,
    text: []const u8,
    scope_name: ?[]const u8 = null,
    scope_kind: ?explore_mod.SymbolKind = null,
    scope_start: u32 = 0,
    scope_end: u32 = 0,
};

const CallersResult = struct {
    defs: []const DefinitionItem,
    callers: []const CallerItem,
    file_count: usize,
    def_rejects: usize,
    substring_rejects: usize,
    non_call_site_rejects: usize,
};

const DefineResult = struct {
    defs: []const DefinitionItem,
    fallback_sites: []const SiteItem,
    fuzzy_files: []const []const u8,
    stage_rows: []const render_mod.StageRow,
    exact_defs: usize,
};

const OverviewResult = struct {
    keywords: []const []const u8,
    defs: []const DefinitionItem,
    files: []const RankedFile,
    callers: []const CallerItem,
    stage_rows: []const render_mod.StageRow,
};

const RenderResult = struct {
    text: []u8,
    full_text: []u8,
    coverage: []const render_mod.CoverageRow,
    limits: []const []const u8,
};

const TextRender = struct {
    text: []u8,
    coverage: []const render_mod.CoverageRow,
    limits: []const []const u8,
};

const overview_view_sites_per_file: usize = 3;

pub fn parseIntent(value: []const u8) ?Intent {
    if (std.mem.eql(u8, value, "overview")) return .overview;
    if (std.mem.eql(u8, value, "define")) return .define;
    if (std.mem.eql(u8, value, "callers")) return .callers;
    return null;
}

pub fn parseFormat(value: []const u8) ?Format {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    return null;
}

pub fn parseMode(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "summary")) return .summary;
    if (std.mem.eql(u8, value, "evidence")) return .evidence;
    if (std.mem.eql(u8, value, "raw")) return .raw;
    return null;
}

pub fn intentName(intent: Intent) []const u8 {
    return @tagName(intent);
}

pub fn run(
    io: std.Io,
    alloc: std.mem.Allocator,
    req: CompassRequest,
    explorer: *Explorer,
    store: *Store,
    data_dir: []const u8,
    settings: Settings,
    out: *std.ArrayList(u8),
) void {
    if (req.more) |token| {
        replayStored(io, alloc, token, req.format, explorer, store, data_dir, out);
        return;
    }

    const raw_task = if (req.task.len > 0) req.task else req.target orelse "";
    const task = std.mem.trim(u8, raw_task, " \t\r\n");
    if (task.len < 3 or task.len > 1024) {
        out.appendSlice(alloc, "error: task must be 3-1024 chars") catch {};
        return;
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const A = arena.allocator();

    var route = classifyIntent(task, req.intent, req.target, A) catch {
        out.appendSlice(alloc, "error: route classification failed") catch {};
        return;
    };
    validateRoute(route.target, &route, explorer, A);

    const effective_max_files = @max(@as(u32, 1), req.max_files orelse settings.max_files);
    const want_body = req.want_body orelse settings.body;
    const generation = currentGeneration(explorer, store);

    const rendered = switch (route.intent) {
        .overview => renderOverview(io, alloc, A, task, route, effective_max_files, want_body, explorer),
        .define => renderDefine(io, alloc, A, task, route, effective_max_files, want_body, explorer),
        .callers => renderCallers(alloc, A, task, route, effective_max_files, want_body, explorer),
    } catch {
        out.appendSlice(alloc, "error: compass execution failed") catch {};
        return;
    };

    const truncated = isTruncated(rendered.coverage);
    const response_text = rendered.text;
    var more_id: ?[]const u8 = null;

    if (truncated) {
        const artifact = StoredArtifact{
            .route_line = route.rationale,
            .alt_line = if (route.state == .ambiguous and route.runner_up != null) @tagName(route.runner_up.?) else null,
            .coverage = rendered.coverage,
            .limits = rendered.limits,
            .full_text = rendered.full_text,
        };
        if (persistArtifact(io, alloc, data_dir, req, generation, artifact, settings.overflow_keep)) |token| {
            more_id = token;
        } else |_| {}
    }

    switch (req.format) {
        .text => {
            out.appendSlice(alloc, response_text) catch {};
            if (more_id) |token| {
                const w = cio.listWriter(out, alloc);
                w.print("\n## MORE reqid={s}\n", .{token}) catch {};
            }
        },
        .json => {
            appendJsonResponse(alloc, out, route.rationale, if (route.state == .ambiguous and route.runner_up != null) @tagName(route.runner_up.?) else null, rendered.coverage, rendered.limits, response_text, more_id) catch {
                out.appendSlice(alloc, "error: compass json render failed") catch {};
            };
        },
    }
}

fn classifyIntent(
    task: []const u8,
    intent_override: ?Intent,
    target_override: ?[]const u8,
    alloc: std.mem.Allocator,
) !Route {
    var anchors: std.ArrayList(Anchor) = .empty;
    try extractRoutingAnchors(task, alloc, &anchors);
    const has_strong_anchor = hasStrongAnchor(anchors.items);

    const target = if (target_override) |t|
        Anchor{ .text = t, .kind = classifyStandaloneTarget(t), .salience = 4 }
    else if (!has_strong_anchor)
        lastWordAnchor(anchors.items) orelse bestAnchor(anchors.items)
    else
        bestAnchor(anchors.items);

    if (intent_override) |intent| {
        return .{
            .intent = if ((intent == .define or intent == .callers) and target == null) .overview else intent,
            .target = target,
            .confidence = .explicit,
            .state = if ((intent == .define or intent == .callers) and target == null) .fallback else .exact,
            .rationale = try std.fmt.allocPrint(alloc, "{s} target={s} confidence=explicit", .{
                @tagName(if ((intent == .define or intent == .callers) and target == null) .overview else intent),
                if (target) |a| a.text else "none",
            }),
        };
    }

    const normalized = try normalizeTask(task, alloc);
    const strong_anchor_count = countStrongAnchors(anchors.items);

    var overview_score: i32 = 1;
    var define_score: i32 = 0;
    var callers_score: i32 = 0;

    overview_score += phraseScore(normalized, &.{
        .{ .phrase = "how does", .weight = 3 },
        .{ .phrase = "what does", .weight = 3 },
        .{ .phrase = "look like", .weight = 3 },
        .{ .phrase = "walk me through", .weight = 3 },
        .{ .phrase = "architecture", .weight = 3 },
        .{ .phrase = "overview", .weight = 3 },
        .{ .phrase = "flow", .weight = 3 },
        .{ .phrase = "explain", .weight = 3 },
    });
    define_score += phraseScore(normalized, &.{
        .{ .phrase = "where is", .weight = 3 },
        .{ .phrase = "definition of", .weight = 3 },
        .{ .phrase = "declared", .weight = 3 },
        .{ .phrase = "implementation of", .weight = 3 },
        .{ .phrase = "signature of", .weight = 3 },
        .{ .phrase = "what is", .weight = 1 },
        .{ .phrase = "defined", .weight = 1 },
    });
    callers_score += phraseScore(normalized, &.{
        .{ .phrase = "who calls", .weight = 3 },
        .{ .phrase = "callers of", .weight = 3 },
        .{ .phrase = "call sites", .weight = 3 },
        .{ .phrase = "used by", .weight = 3 },
        .{ .phrase = "references to", .weight = 3 },
        .{ .phrase = "usages of", .weight = 3 },
        .{ .phrase = "calls", .weight = 1 },
        .{ .phrase = "invoked", .weight = 1 },
        .{ .phrase = "uses", .weight = 1 },
        .{ .phrase = "called", .weight = 1 },
    });

    if (!has_strong_anchor) {
        define_score = @min(define_score, 1);
        callers_score = @min(callers_score, 1);
        overview_score += 2;
    } else {
        callers_score += 1;
        if (strong_anchor_count == 1) define_score += 2;
    }

    const scored = [_]struct { intent: Intent, score: i32, priority: i32 }{
        .{ .intent = .define, .score = define_score, .priority = 3 },
        .{ .intent = .callers, .score = callers_score, .priority = 2 },
        .{ .intent = .overview, .score = overview_score, .priority = 1 },
    };

    var winner = scored[0];
    var runner = scored[1];
    for (scored[1..]) |candidate| {
        if (candidate.score > winner.score or (candidate.score == winner.score and candidate.priority > winner.priority)) {
            runner = winner;
            winner = candidate;
        } else if (candidate.score > runner.score or (candidate.score == runner.score and candidate.priority > runner.priority)) {
            runner = candidate;
        }
    }

    var selected = winner.intent;
    var state: RouteState = .exact;
    var confidence: Confidence = if (winner.score >= 4 and has_strong_anchor) .strong else .weak;
    var runner_up: ?Intent = null;

    if ((selected == .define or selected == .callers) and target == null) {
        selected = .overview;
        state = .fallback;
        confidence = .weak;
        runner_up = winner.intent;
    } else if (winner.intent != .overview and winner.score - runner.score < 2) {
        selected = .overview;
        state = .ambiguous;
        confidence = .weak;
        runner_up = winner.intent;
    } else if (selected == .overview and state == .exact and !has_strong_anchor and target != null and runner.intent != .overview and runner.score > 0) {
        state = .ambiguous;
        confidence = .weak;
        runner_up = runner.intent;
    }

    return .{
        .intent = selected,
        .target = target,
        .confidence = confidence,
        .state = state,
        .runner_up = runner_up,
        .rationale = try std.fmt.allocPrint(alloc, "{s} target={s} confidence={s} state={s}", .{
            @tagName(selected),
            if (target) |a| a.text else "none",
            @tagName(confidence),
            @tagName(state),
        }),
    };
}

fn renderOverview(
    io: std.Io,
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    task: []const u8,
    route: Route,
    max_files: u32,
    want_body: bool,
    explorer: *Explorer,
) !RenderResult {
    _ = want_body;

    var keywords: std.ArrayList([]const u8) = .empty;
    var content_queries: std.ArrayList([]const u8) = .empty;
    var anchors: std.ArrayList(Anchor) = .empty;

    try extractRoutingAnchors(task, arena, &anchors);
    shared.extractContextCandidates(task, arena, &keywords, 3);
    for (keywords.items) |kw| {
        appendUniqueBorrow(arena, &content_queries, kw) catch {};
    }
    if (route.target) |target| {
        appendUniqueBorrow(arena, &keywords, target.text) catch {};
        appendUniqueBorrow(arena, &content_queries, target.text) catch {};
    }
    if (content_queries.items.len < 4) {
        for (anchors.items) |anchor| {
            appendUniqueBorrow(arena, &keywords, anchor.text) catch {};
            appendUniqueBorrow(arena, &content_queries, anchor.text) catch {};
            if (content_queries.items.len >= 4) break;
        }
    }

    const overview_has_strong_anchor = hasStrongAnchor(anchors.items);
    const phrase_query = if (!overview_has_strong_anchor)
        try buildWeakPhraseQuery(arena, anchors.items)
    else
        null;

    var by_file = std.StringHashMap(OverviewPerFile).init(arena);
    var defs = std.ArrayList(DefinitionItem).empty;
    var seen_defs = std.StringHashMap(void).init(arena);

    if (phrase_query) |phrase| {
        appendUniqueBorrow(arena, &keywords, phrase) catch {};
        const phrase_hits = explorer.searchContentWithOptions(phrase, arena, .{
            .max_results = 12,
            .max_per_file = 3,
            .compact = true,
        }) catch &.{};
        for (phrase_hits) |hit| {
            try addOverviewHit(arena, &by_file, hit.path, hit.line_num, hit.line_text, 2.5);
        }
        const fuzzy_paths = explorer.fuzzyFindFiles(phrase, arena, 6) catch &.{};
        for (fuzzy_paths) |match| {
            try addOverviewHit(arena, &by_file, match.path, 0, "", 3.0);
        }
    }

    for (content_queries.items) |kw| {
        const require_whole_word = shared.looksLikeContextIdentifier(kw);
        const is_route_target = if (route.target) |target| std.mem.eql(u8, target.text, kw) else false;
        const allow_word_definition_probe = !overview_has_strong_anchor and is_route_target;
        if (classifyStandaloneTarget(kw) != .word or allow_word_definition_probe) {
            const found_defs = explorer.findAllSymbols(kw, arena) catch &.{};
            for (found_defs[0..@min(found_defs.len, 3)]) |d| {
                const def_key = try std.fmt.allocPrint(arena, "{s}:{d}:{s}", .{ d.path, d.symbol.line_start, kw });
                if (seen_defs.contains(def_key)) continue;
                try seen_defs.put(def_key, {});
                const snippet = extractSymbolSnippet(explorer, arena, d.path, d.symbol.line_start, d.symbol.line_end, false);
                try defs.append(arena, .{
                    .name = kw,
                    .kind = @tagName(d.symbol.kind),
                    .path = d.path,
                    .line = d.symbol.line_start,
                    .line_end = d.symbol.line_end,
                    .detail = compactSymbolDetailFromSnippet(arena, snippet, d.symbol.detail),
                    .snippet = snippet,
                });
            }
        }

        const hits = explorer.searchContentRanked(kw, arena, 8) catch &.{};
        for (hits) |hit| {
            if (require_whole_word and !shared.hasWholeWordMatch(hit.line_text, kw)) continue;
            try addOverviewHit(arena, &by_file, hit.path, hit.line_num, hit.line_text, if (hit.score > 0) hit.score else 1.0);
        }
    }

    var stage_rows = std.ArrayList(render_mod.StageRow).empty;
    if (phrase_query != null) {
        try stage_rows.append(arena, .{ .name = "phrase-query", .count = by_file.count() });
        try stage_rows.append(arena, .{ .name = "path-fuzzy", .count = by_file.count() });
    }
    try stage_rows.append(arena, .{ .name = "keywords-ranked", .count = by_file.count() });

    if (by_file.count() == 0 and route.target != null) {
        const fallback = explorer.searchContentWithOptions(route.target.?.text, arena, .{
            .max_results = 12,
            .max_per_file = 3,
            .compact = true,
        }) catch &.{};
        for (fallback) |hit| {
            try addOverviewHit(arena, &by_file, hit.path, hit.line_num, hit.line_text, 1.0);
        }
        try stage_rows.append(arena, .{ .name = "literal-fallback", .count = by_file.count() });
    }

    var symbol_files = std.StringHashMap(void).init(arena);
    for (defs.items) |def| {
        try symbol_files.put(def.path, {});
    }

    var ranked = std.ArrayList(RankedFile).empty;
    var by_file_it = by_file.iterator();
    while (by_file_it.next()) |entry| {
        const path = entry.key_ptr.*;
        const lang = explore_mod.detectLanguage(path);
        const capped_hits = @min(entry.value_ptr.total, 3);
        var score = @as(f32, @floatFromInt(shared.scoreContextFile(path, capped_hits, symbol_files.contains(path))));
        score += @min(entry.value_ptr.score, 8.0);
        score += overviewPathBoost(path, keywords.items);
        score -= overviewPathPenalty(path, lang);
        try ranked.append(arena, .{
            .path = path,
            .hits = entry.value_ptr.total,
            .score = score,
            .sites = entry.value_ptr.sites.items,
        });
    }
    std.mem.sort(RankedFile, ranked.items, {}, struct {
        fn lt(_: void, a: RankedFile, b: RankedFile) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.hits > b.hits;
        }
    }.lt);

    const callers = collectOverviewCallers(explorer, arena, defs.items) catch &.{};
    const reader_prefix = maybeReaderPrefix(io, arena, task, explorer);
    const full = try renderOverviewText(alloc, route, .{
        .keywords = keywords.items,
        .defs = defs.items,
        .files = ranked.items,
        .callers = callers,
        .stage_rows = stage_rows.items,
    }, ranked.items.len, defs.items.len, std.math.maxInt(usize), callers.len, reader_prefix);
    const view = try renderOverviewText(alloc, route, .{
        .keywords = keywords.items,
        .defs = defs.items,
        .files = ranked.items,
        .callers = callers,
        .stage_rows = stage_rows.items,
    }, max_files, @min(defs.items.len, @as(usize, max_files)), overview_view_sites_per_file, @min(callers.len, @as(usize, max_files) * 2), reader_prefix);
    return .{
        .text = view.text,
        .full_text = full.text,
        .coverage = view.coverage,
        .limits = view.limits,
    };
}

fn renderDefine(
    io: std.Io,
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    task: []const u8,
    route: Route,
    max_files: u32,
    want_body: bool,
    explorer: *Explorer,
) !RenderResult {
    _ = io;
    _ = task;
    const target = route.target orelse return renderSimpleError(alloc, "error: no target bound for define");

    const result = collectDefine(explorer, arena, target.text, want_body) catch return renderSimpleError(alloc, "error: define gather failed");
    const full = try renderDefineText(alloc, route, result, std.math.maxInt(u32));
    const view = try renderDefineText(alloc, route, result, max_files);
    return .{
        .text = view.text,
        .full_text = full.text,
        .coverage = view.coverage,
        .limits = view.limits,
    };
}

fn renderCallers(
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    task: []const u8,
    route: Route,
    max_files: u32,
    want_body: bool,
    explorer: *Explorer,
) !RenderResult {
    _ = task;
    _ = want_body;
    const target = route.target orelse return renderSimpleError(alloc, "error: no target bound for callers");
    const result = collectCallers(explorer, arena, target.text) catch return renderSimpleError(alloc, "error: callers gather failed");
    const full = try renderCallersText(alloc, route, result, std.math.maxInt(u32));
    const view = try renderCallersText(alloc, route, result, max_files);
    return .{
        .text = view.text,
        .full_text = full.text,
        .coverage = view.coverage,
        .limits = view.limits,
    };
}

fn collectDefine(explorer: *Explorer, arena: std.mem.Allocator, target: []const u8, want_body: bool) !DefineResult {
    var defs = std.ArrayList(DefinitionItem).empty;
    var fallback_sites = std.ArrayList(SiteItem).empty;
    var fuzzy_files = std.ArrayList([]const u8).empty;
    var stages = std.ArrayList(render_mod.StageRow).empty;

    const exact_defs = explorer.findAllSymbols(target, arena) catch &.{};
    try stages.append(arena, .{ .name = "symbol", .count = exact_defs.len });
    if (exact_defs.len > 0) {
        for (exact_defs) |d| {
            const snippet = extractSymbolSnippet(explorer, arena, d.path, d.symbol.line_start, d.symbol.line_end, want_body);
            try defs.append(arena, .{
                .name = target,
                .kind = @tagName(d.symbol.kind),
                .path = d.path,
                .line = d.symbol.line_start,
                .line_end = d.symbol.line_end,
                .detail = compactSymbolDetailFromSnippet(arena, snippet, d.symbol.detail),
                .snippet = snippet,
            });
        }
        return .{
            .defs = defs.items,
            .fallback_sites = fallback_sites.items,
            .fuzzy_files = fuzzy_files.items,
            .stage_rows = stages.items,
            .exact_defs = exact_defs.len,
        };
    }

    const word_hits = explorer.searchWord(target, arena) catch &.{};
    try stages.append(arena, .{ .name = "word", .count = word_hits.len });
    if (word_hits.len > 0) {
        const take = @min(word_hits.len, 20);
        var seen = std.StringHashMap(void).init(arena);
        for (word_hits[0..take]) |hit| {
            const path = explorer.word_index.hitPath(hit);
            const key = try std.fmt.allocPrint(arena, "{s}:{d}", .{ path, hit.line_num });
            if (seen.contains(key)) continue;
            try seen.put(key, {});
            try fallback_sites.append(arena, .{
                .path = path,
                .line = hit.line_num,
                .text = extractSingleLine(explorer, arena, path, hit.line_num) orelse "",
            });
        }
        return .{
            .defs = defs.items,
            .fallback_sites = fallback_sites.items,
            .fuzzy_files = fuzzy_files.items,
            .stage_rows = stages.items,
            .exact_defs = 0,
        };
    }

    const search_hits = explorer.searchContentWithOptions(target, arena, .{
        .max_results = 20,
        .max_per_file = 3,
        .compact = true,
    }) catch &.{};
    try stages.append(arena, .{ .name = "search", .count = search_hits.len });
    if (search_hits.len > 0) {
        for (search_hits) |hit| {
            try fallback_sites.append(arena, .{
                .path = hit.path,
                .line = hit.line_num,
                .text = hit.line_text,
            });
        }
        return .{
            .defs = defs.items,
            .fallback_sites = fallback_sites.items,
            .fuzzy_files = fuzzy_files.items,
            .stage_rows = stages.items,
            .exact_defs = 0,
        };
    }

    if (looksPathLike(target)) {
        const fuzzy = explorer.fuzzyFindFiles(target, arena, 10) catch &.{};
        try stages.append(arena, .{ .name = "fuzzy-file", .count = fuzzy.len });
        for (fuzzy) |item| {
            try fuzzy_files.append(arena, item.path);
        }
    }

    return .{
        .defs = defs.items,
        .fallback_sites = fallback_sites.items,
        .fuzzy_files = fuzzy_files.items,
        .stage_rows = stages.items,
        .exact_defs = 0,
    };
}

fn collectCallers(explorer: *Explorer, arena: std.mem.Allocator, target: []const u8) !CallersResult {
    var defs = std.ArrayList(DefinitionItem).empty;
    const found_defs = explorer.findAllSymbols(target, arena) catch &.{};
    for (found_defs) |d| {
        try defs.append(arena, .{
            .name = target,
            .kind = @tagName(d.symbol.kind),
            .path = d.path,
            .line = d.symbol.line_start,
            .line_end = d.symbol.line_end,
            .detail = compactSymbolDetail(arena, d.symbol.detail),
        });
    }

    const scoped = explorer.searchContentWithScopeOptions(target, arena, .{
        .max_results = 200,
        .compact = true,
    }) catch &.{};

    var callers = std.ArrayList(CallerItem).empty;
    var file_set = std.StringHashMap(void).init(arena);
    var def_rejects: usize = 0;
    var substring_rejects: usize = 0;
    var non_call_site_rejects: usize = 0;

    for (scoped) |hit| {
        if (!shared.langHasCallSites(explore_mod.detectLanguage(hit.path))) {
            non_call_site_rejects += 1;
            continue;
        }
        var is_def = false;
        for (defs.items) |def| {
            if (def.line == hit.line_num and std.mem.eql(u8, def.path, hit.path)) {
                is_def = true;
                break;
            }
        }
        if (is_def) {
            def_rejects += 1;
            continue;
        }
        if (!shared.hasWholeWordMatch(hit.line_text, target)) {
            substring_rejects += 1;
            continue;
        }
        try callers.append(arena, .{
            .path = hit.path,
            .line = hit.line_num,
            .text = hit.line_text,
            .scope_name = hit.scope_name,
            .scope_kind = hit.scope_kind,
            .scope_start = hit.scope_start,
            .scope_end = hit.scope_end,
        });
        try file_set.put(hit.path, {});
    }

    return .{
        .defs = defs.items,
        .callers = callers.items,
        .file_count = file_set.count(),
        .def_rejects = def_rejects,
        .substring_rejects = substring_rejects,
        .non_call_site_rejects = non_call_site_rejects,
    };
}

fn collectOverviewCallers(explorer: *Explorer, arena: std.mem.Allocator, defs: []const DefinitionItem) ![]const CallerItem {
    var callers = std.ArrayList(CallerItem).empty;
    var seen = std.StringHashMap(void).init(arena);
    var searched = std.StringHashMap(void).init(arena);

    for (defs) |def| {
        if (searched.contains(def.name)) continue;
        try searched.put(def.name, {});
        const scoped = explorer.searchContentWithScopeOptions(def.name, arena, .{
            .max_results = 200,
            .compact = true,
        }) catch continue;
        for (scoped) |hit| {
            if (!shared.langHasCallSites(explore_mod.detectLanguage(hit.path))) continue;
            if (hit.line_num == def.line and std.mem.eql(u8, hit.path, def.path)) continue;
            if (!shared.hasWholeWordMatch(hit.line_text, def.name)) continue;
            if (shared.isTestLikePath(hit.path)) continue;
            if (hit.scope_kind) |kind| {
                if (kind == .import or kind == .type_alias or kind == .constant) continue;
            }
            const key = try std.fmt.allocPrint(arena, "{s}:{d}", .{ hit.path, hit.line_num });
            if (seen.contains(key)) continue;
            try seen.put(key, {});
            try callers.append(arena, .{
                .path = hit.path,
                .line = hit.line_num,
                .text = hit.line_text,
                .scope_name = hit.scope_name,
                .scope_kind = hit.scope_kind,
                .scope_start = hit.scope_start,
                .scope_end = hit.scope_end,
            });
        }
    }
    return callers.items;
}

fn renderOverviewText(
    alloc: std.mem.Allocator,
    route: Route,
    result: OverviewResult,
    max_files: usize,
    max_defs: usize,
    max_sites_per_file: usize,
    max_callers: usize,
    reader_prefix: ?[]const u8,
) !TextRender {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var coverage = std.ArrayList(render_mod.CoverageRow).empty;
    errdefer coverage.deinit(alloc);

    if (reader_prefix) |prefix| {
        try out.appendSlice(alloc, prefix);
    }
    render_mod.appendRoute(alloc, &out, route.rationale, if (route.state == .ambiguous and route.runner_up != null) @tagName(route.runner_up.?) else null);
    render_mod.appendStages(alloc, &out, result.stage_rows);

    const w = cio.listWriter(&out, alloc);
    if (result.keywords.len > 0) {
        w.writeAll("\n## KEYWORDS\n") catch {};
        for (result.keywords) |kw| {
            w.print("- {s}\n", .{kw}) catch {};
        }
    }

    const defs_shown = @min(result.defs.len, max_defs);
    if (result.defs.len > 0) {
        render_mod.appendSectionHeader(alloc, &out, "DEFS", defs_shown, result.defs.len);
        for (result.defs[0..defs_shown]) |def| {
            w.print("- {s} ({s}) {s}:{d}\n", .{ def.name, def.kind, def.path, def.line }) catch {};
            if (def.detail) |detail| {
                w.print("  signature: {s}\n", .{detail}) catch {};
            }
            if (def.snippet) |snippet| {
                w.print("```text\n{s}```\n", .{snippet}) catch {};
            }
        }
        try coverage.append(alloc, .{ .section = "defs", .shown = defs_shown, .total = result.defs.len });
    }

    const files_shown = @min(result.files.len, max_files);
    if (result.files.len > 0) {
        render_mod.appendSectionHeader(alloc, &out, "FILES", files_shown, result.files.len);
        for (result.files[0..files_shown]) |file| {
            w.print("- {s} ({d} hits)\n", .{ file.path, file.hits }) catch {};
        }
        try coverage.append(alloc, .{ .section = "files", .shown = files_shown, .total = result.files.len });
    }

    var total_sites: usize = 0;
    var shown_sites: usize = 0;
    for (result.files) |file| total_sites += file.sites.len;
    if (total_sites > 0) {
        var i: usize = 0;
        while (i < files_shown) : (i += 1) {
            shown_sites += @min(result.files[i].sites.len, max_sites_per_file);
        }
        render_mod.appendSectionHeader(alloc, &out, "SITES", shown_sites, total_sites);
        i = 0;
        while (i < files_shown) : (i += 1) {
            const shown_for_file = @min(result.files[i].sites.len, max_sites_per_file);
            for (result.files[i].sites[0..shown_for_file]) |site| {
                w.print("- {s}:{d}: {s}\n", .{ site.path, site.line, site.text }) catch {};
            }
        }
        try coverage.append(alloc, .{ .section = "sites", .shown = shown_sites, .total = total_sites });
    }

    const callers_shown = @min(result.callers.len, max_callers);
    if (result.callers.len > 0) {
        render_mod.appendSectionHeader(alloc, &out, "CALLERS", callers_shown, result.callers.len);
        for (result.callers[0..callers_shown]) |caller| {
            if (caller.scope_name) |scope_name| {
                w.print("- {s}:{d}: {s}  [in {s} ({s}, L{d}-L{d})]\n", .{
                    caller.path, caller.line, caller.text, scope_name, @tagName(caller.scope_kind.?), caller.scope_start, caller.scope_end,
                }) catch {};
            } else {
                w.print("- {s}:{d}: {s}\n", .{ caller.path, caller.line, caller.text }) catch {};
            }
        }
        try coverage.append(alloc, .{ .section = "callers", .shown = callers_shown, .total = result.callers.len });
    }

    render_mod.appendCoverage(alloc, &out, coverage.items);
    const limits = try alloc.dupe([]const u8, &.{
        "tests and docs are deprioritized during overview ranking",
    });
    render_mod.appendLimits(alloc, &out, limits);
    return .{
        .text = try out.toOwnedSlice(alloc),
        .coverage = try coverage.toOwnedSlice(alloc),
        .limits = limits,
    };
}

fn renderDefineText(
    alloc: std.mem.Allocator,
    route: Route,
    result: DefineResult,
    max_files: u32,
) !TextRender {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var coverage = std.ArrayList(render_mod.CoverageRow).empty;
    errdefer coverage.deinit(alloc);
    render_mod.appendRoute(alloc, &out, route.rationale, if (route.state == .ambiguous and route.runner_up != null) @tagName(route.runner_up.?) else null);
    render_mod.appendStages(alloc, &out, result.stage_rows);
    const w = cio.listWriter(&out, alloc);

    if (result.defs.len > 0) {
        const defs_shown = @min(result.defs.len, @as(usize, max_files));
        render_mod.appendSectionHeader(alloc, &out, "DEFS", defs_shown, result.defs.len);
        for (result.defs[0..defs_shown]) |def| {
            w.print("- {s} ({s}) {s}:{d}\n", .{ def.name, def.kind, def.path, def.line }) catch {};
            if (def.detail) |detail| {
                w.print("  signature: {s}\n", .{detail}) catch {};
            }
            if (def.snippet) |snippet| {
                w.print("```text\n{s}```\n", .{snippet}) catch {};
            }
        }
        try coverage.append(alloc, .{ .section = "defs", .shown = defs_shown, .total = result.defs.len });
    }

    if (result.fallback_sites.len > 0) {
        const shown = @min(result.fallback_sites.len, @as(usize, max_files) * 2);
        render_mod.appendSectionHeader(alloc, &out, "SITES", shown, result.fallback_sites.len);
        for (result.fallback_sites[0..shown]) |site| {
            w.print("- {s}:{d}: {s}\n", .{ site.path, site.line, site.text }) catch {};
        }
        try coverage.append(alloc, .{ .section = "sites", .shown = shown, .total = result.fallback_sites.len });
    }

    if (result.fuzzy_files.len > 0) {
        const shown = @min(result.fuzzy_files.len, @as(usize, max_files));
        render_mod.appendSectionHeader(alloc, &out, "FILES", shown, result.fuzzy_files.len);
        for (result.fuzzy_files[0..shown]) |path| {
            w.print("- {s}\n", .{path}) catch {};
        }
        try coverage.append(alloc, .{ .section = "files", .shown = shown, .total = result.fuzzy_files.len });
    }

    var limits = std.ArrayList([]const u8).empty;
    if (result.exact_defs > 1) {
        try limits.append(alloc, try std.fmt.allocPrint(alloc, "multiple exact definitions share this name ({d})", .{result.exact_defs}));
    }
    if (result.defs.len == 0 and result.fallback_sites.len > 0) {
        try limits.append(alloc, "no indexed definition found; showing fallback usage hits");
    }
    render_mod.appendCoverage(alloc, &out, coverage.items);
    render_mod.appendLimits(alloc, &out, limits.items);
    return .{
        .text = try out.toOwnedSlice(alloc),
        .coverage = try coverage.toOwnedSlice(alloc),
        .limits = try limits.toOwnedSlice(alloc),
    };
}

fn renderCallersText(
    alloc: std.mem.Allocator,
    route: Route,
    result: CallersResult,
    max_files: u32,
) !TextRender {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var coverage = std.ArrayList(render_mod.CoverageRow).empty;
    errdefer coverage.deinit(alloc);
    var limits = std.ArrayList([]const u8).empty;
    errdefer limits.deinit(alloc);

    render_mod.appendRoute(alloc, &out, route.rationale, if (route.state == .ambiguous and route.runner_up != null) @tagName(route.runner_up.?) else null);
    const w = cio.listWriter(&out, alloc);

    if (result.defs.len > 0) {
        const shown = @min(result.defs.len, @as(usize, max_files));
        render_mod.appendSectionHeader(alloc, &out, "DEFS", shown, result.defs.len);
        for (result.defs[0..shown]) |def| {
            w.print("- {s} ({s}) {s}:{d}\n", .{ def.name, def.kind, def.path, def.line }) catch {};
        }
        try coverage.append(alloc, .{ .section = "defs", .shown = shown, .total = result.defs.len });
        if (result.defs.len > 1) {
            try limits.append(alloc, try std.fmt.allocPrint(alloc, "name-ambiguous across {d} exact definitions", .{result.defs.len}));
        }
    }

    const callers_shown = @min(result.callers.len, @as(usize, max_files) * 3);
    render_mod.appendSectionHeader(alloc, &out, "CALLERS", callers_shown, result.callers.len);
    for (result.callers[0..callers_shown]) |caller| {
        if (caller.scope_name) |scope_name| {
            w.print("- {s}:{d}: {s}  [in {s} ({s}, L{d}-L{d})]\n", .{
                caller.path, caller.line, caller.text, scope_name, @tagName(caller.scope_kind.?), caller.scope_start, caller.scope_end,
            }) catch {};
        } else {
            w.print("- {s}:{d}: {s}\n", .{ caller.path, caller.line, caller.text }) catch {};
        }
    }
    try coverage.append(alloc, .{ .section = "callers", .shown = callers_shown, .total = result.callers.len });
    try limits.append(alloc, try std.fmt.allocPrint(alloc, "filtered {d} definition hits, {d} substring-only hits, and {d} non-call-site matches", .{
        result.def_rejects,
        result.substring_rejects,
        result.non_call_site_rejects,
    }));
    if (result.file_count > 0) {
        try limits.append(alloc, try std.fmt.allocPrint(alloc, "callers span {d} files", .{result.file_count}));
    }
    render_mod.appendCoverage(alloc, &out, coverage.items);
    render_mod.appendLimits(alloc, &out, limits.items);
    return .{
        .text = try out.toOwnedSlice(alloc),
        .coverage = try coverage.toOwnedSlice(alloc),
        .limits = try limits.toOwnedSlice(alloc),
    };
}

fn validateRoute(target: ?Anchor, route: *Route, explorer: *Explorer, alloc: std.mem.Allocator) void {
    if (route.intent == .define and target != null and target.?.kind != .word) {
        const defs = explorer.findAllSymbols(target.?.text, alloc) catch return;
        if (defs.len == 0) {
            route.intent = .overview;
            route.state = .fallback;
            route.confidence = .weak;
            route.runner_up = .define;
            route.rationale = std.fmt.allocPrint(alloc, "overview target={s} confidence=weak state=fallback", .{target.?.text}) catch route.rationale;
        }
    } else if (route.intent == .callers and target != null and target.?.kind != .word) {
        const result = collectCallers(explorer, alloc, target.?.text) catch return;
        if (result.callers.len == 0) {
            route.intent = .overview;
            route.state = .fallback;
            route.confidence = .weak;
            route.runner_up = .callers;
            route.rationale = std.fmt.allocPrint(alloc, "overview target={s} confidence=weak state=fallback", .{target.?.text}) catch route.rationale;
        }
    }
}

fn currentGeneration(explorer: *Explorer, store: *Store) Generation {
    explorer.mu.lockShared();
    const files: u32 = @intCast(explorer.outlines.count());
    explorer.mu.unlockShared();
    return .{
        .seq = @intCast(store.currentSeq()),
        .files = files,
    };
}

fn isTruncated(coverage: []const render_mod.CoverageRow) bool {
    for (coverage) |row| {
        if (row.shown < row.total) return true;
    }
    return false;
}

fn normalizeTask(task: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var prev_space = false;
    for (task) |c| {
        const lower = std.ascii.toLower(c);
        const is_space = lower == ' ' or lower == '\n' or lower == '\r' or lower == '\t';
        if (is_space) {
            if (!prev_space) {
                try out.append(alloc, ' ');
                prev_space = true;
            }
        } else {
            try out.append(alloc, lower);
            prev_space = false;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        out.items.len -= 1;
    }
    return out.items;
}

const PhraseWeight = struct {
    phrase: []const u8,
    weight: i32,
};

fn phraseScore(normalized: []const u8, phrases: []const PhraseWeight) i32 {
    var total: i32 = 0;
    for (phrases) |phrase| {
        if (std.mem.indexOf(u8, normalized, phrase.phrase) != null) total += phrase.weight;
    }
    return total;
}

fn hasStrongAnchor(anchors: []const Anchor) bool {
    for (anchors) |anchor| {
        if (anchor.kind != .word) return true;
    }
    return false;
}

fn countStrongAnchors(anchors: []const Anchor) usize {
    var count: usize = 0;
    for (anchors) |anchor| {
        if (anchor.kind != .word) count += 1;
    }
    return count;
}

fn classifyStandaloneTarget(target: []const u8) AnchorKind {
    if (std.mem.indexOfScalar(u8, target, '/') != null or explore_mod.detectLanguage(target) != .unknown) return .path;
    if (shared.looksLikeContextIdentifier(target)) return .identifier;
    return .word;
}

fn bestAnchor(anchors: []const Anchor) ?Anchor {
    if (anchors.len == 0) return null;
    var best = anchors[0];
    for (anchors[1..]) |anchor| {
        if (anchor.salience > best.salience or
            (anchor.salience == best.salience and anchor.text.len > best.text.len))
        {
            best = anchor;
        }
    }
    return best;
}

fn lastWordAnchor(anchors: []const Anchor) ?Anchor {
    var i = anchors.len;
    while (i > 0) {
        i -= 1;
        if (anchors[i].kind == .word) return anchors[i];
    }
    return null;
}

fn isRoutingTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '/' or c == '.' or c == '-';
}

fn trimToken(tok: []const u8) []const u8 {
    return std.mem.trim(u8, tok, " \t\r\n,.;:!?()[]{}<>");
}

fn extractRoutingAnchors(task: []const u8, alloc: std.mem.Allocator, out: *std.ArrayList(Anchor)) !void {
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
            if (j > start) {
                const slice = trimToken(task[start..j]);
                if (slice.len >= 3 and !seen.contains(slice)) {
                    try seen.put(slice, {});
                    try out.append(alloc, .{ .text = slice, .kind = .quoted, .salience = 3 });
                }
            }
            i = j + 1;
            continue;
        }

        if (isRoutingTokenChar(c)) {
            const start = i;
            while (i < task.len and isRoutingTokenChar(task[i])) : (i += 1) {}
            const raw = trimToken(task[start..i]);
            if (raw.len < 3 or seen.contains(raw)) continue;
            if (isStopWord(raw)) continue;
            if (std.mem.indexOfScalar(u8, raw, '/') != null or explore_mod.detectLanguage(raw) != .unknown) {
                try seen.put(raw, {});
                try out.append(alloc, .{ .text = raw, .kind = .path, .salience = 2 });
            } else if (shared.looksLikeContextIdentifier(raw)) {
                try seen.put(raw, {});
                try out.append(alloc, .{ .text = raw, .kind = .identifier, .salience = 2 });
            } else {
                try seen.put(raw, {});
                try out.append(alloc, .{ .text = raw, .kind = .word, .salience = 1 });
            }
            continue;
        }
        i += 1;
    }
}

fn isStopWord(tok: []const u8) bool {
    const stopwords = [_][]const u8{
        "what",       "how",          "does",      "the",            "is",
        "are",        "and",          "work",
        "find",       "show",         "where",     "who",            "calls",
        "call",       "called",       "used",      "uses",           "of",
        "this",       "code",         "here",      "with",           "from",
        "into",       "that",         "like",      "look",           "through",
        "definition", "defined",      "declared",  "implementation", "signature",
        "overview",   "architecture", "flow",      "explain",        "walk",
        "me",         "references",   "reference", "usages",         "usage",
        "invoked",
    };
    for (stopwords) |stopword| {
        if (std.ascii.eqlIgnoreCase(tok, stopword)) return true;
    }
    return false;
}

fn maybeReaderPrefix(
    io: std.Io,
    alloc: std.mem.Allocator,
    task: []const u8,
    explorer: *Explorer,
) ?[]const u8 {
    if (task.len <= 80) return null;
    var reader_state = reader_md.load(io, alloc, explorer.root_real) catch return null;
    defer reader_state.free(alloc);

    return switch (reader_state.state) {
        .ready => if (reader_state.body) |body|
            std.fmt.allocPrint(alloc, "<!-- reader.md (hash-verified): -->\n{s}\n<!-- end reader.md -->\n\n", .{body}) catch null
        else
            null,
        .stale => std.fmt.allocPrint(alloc, "<!-- reader.md is stale (source_hash drifted). Regenerate by writing a new .codedb/reader.md with current source_hash. -->\n\n", .{}) catch null,
        .missing, .malformed => null,
    };
}

fn addOverviewHit(
    alloc: std.mem.Allocator,
    by_file: *std.StringHashMap(OverviewPerFile),
    path: []const u8,
    line: u32,
    text: []const u8,
    score: f32,
) !void {
    const gop = try by_file.getOrPut(path);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.total += 1;
    gop.value_ptr.score = @max(gop.value_ptr.score, score);
    if (line == 0 or text.len == 0) return;
    for (gop.value_ptr.sites.items) |site| {
        if (site.line == line and std.mem.eql(u8, site.text, text)) return;
    }
    try gop.value_ptr.sites.append(alloc, .{
        .path = path,
        .line = line,
        .text = text,
    });
}

fn buildWeakPhraseQuery(alloc: std.mem.Allocator, anchors: []const Anchor) !?[]const u8 {
    var words: [2][]const u8 = undefined;
    var count: usize = 0;
    for (anchors) |anchor| {
        if (anchor.kind != .word) continue;
        if (count > 0 and std.mem.eql(u8, words[count - 1], anchor.text)) continue;
        words[count] = anchor.text;
        count += 1;
        if (count == words.len) break;
    }
    if (count < 2) return null;
    const phrase: []const u8 = try std.fmt.allocPrint(alloc, "{s} {s}", .{ words[0], words[1] });
    return phrase;
}

fn overviewPathPenalty(path: []const u8, lang: explore_mod.Language) f32 {
    var penalty: f32 = 0;
    if (shared.isTestLikePath(path) or
        std.mem.indexOf(u8, path, "_tests.") != null or
        std.mem.indexOf(u8, path, ".tests.") != null)
    {
        penalty += 4;
    }
    if (explore_mod.isDocLanguage(lang)) penalty += 3;
    if (std.mem.endsWith(u8, path, ".patch")) penalty += 4;
    if (std.mem.endsWith(u8, path, ".snap") or
        std.mem.indexOf(u8, path, "/snapshots/") != null or
        std.mem.indexOf(u8, path, "/__snapshots__/") != null)
    {
        penalty += 5;
    }
    if (std.mem.endsWith(u8, path, "/BUILD") or std.mem.endsWith(u8, path, "BUILD.bazel")) {
        penalty += 2;
    }
    return penalty;
}

fn overviewPathBoost(path: []const u8, keywords: []const []const u8) f32 {
    var boost: f32 = 0;
    for (keywords) |kw| {
        if (kw.len < 3 or std.mem.indexOfScalar(u8, kw, ' ') != null) continue;
        if (containsIgnoreCaseAscii(path, kw)) {
            boost += 1.25;
            if (boost >= 2.5) break;
        }
    }
    return boost;
}

fn containsIgnoreCaseAscii(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn extractSymbolSnippet(explorer: *Explorer, alloc: std.mem.Allocator, path: []const u8, line_start: u32, line_end: u32, want_body: bool) ?[]const u8 {
    const content = (explorer.getContent(path, alloc) catch return null) orelse return null;
    const lang = explore_mod.detectLanguage(path);
    if (want_body) {
        return explore_mod.extractLines(content, line_start, line_end, true, false, lang, alloc) catch null;
    }
    const end = @min(line_end, line_start + 5);
    return explore_mod.extractLines(content, line_start, end, true, true, lang, alloc) catch null;
}

fn compactSymbolDetail(alloc: std.mem.Allocator, detail: ?[]const u8) ?[]const u8 {
    const raw = detail orelse return null;
    var start: usize = 0;
    while (start < raw.len) {
        while (start < raw.len and (raw[start] == '\n' or raw[start] == '\r')) : (start += 1) {}
        var end = start;
        while (end < raw.len and raw[end] != '\n' and raw[end] != '\r') : (end += 1) {}
        const trimmed = std.mem.trim(u8, raw[start..end], " \t");
        if (trimmed.len > 0) return alloc.dupe(u8, trimmed) catch null;
        start = end + 1;
    }
    return null;
}

fn compactSymbolDetailFromSnippet(alloc: std.mem.Allocator, snippet: ?[]const u8, fallback: ?[]const u8) ?[]const u8 {
    if (snippet) |text| {
        var line_it = std.mem.splitScalar(u8, text, '\n');
        while (line_it.next()) |line| {
            var code = line;
            if (std.mem.indexOfScalar(u8, code, '|')) |pipe| {
                code = code[pipe + 1 ..];
            }
            const trimmed = std.mem.trim(u8, code, " \t\r\n");
            if (trimmed.len == 0) continue;
            return alloc.dupe(u8, trimmed) catch null;
        }
    }
    return compactSymbolDetail(alloc, fallback);
}

fn extractSingleLine(explorer: *Explorer, alloc: std.mem.Allocator, path: []const u8, line: u32) ?[]const u8 {
    const content = (explorer.getContent(path, alloc) catch return null) orelse return null;
    const lang = explore_mod.detectLanguage(path);
    return explore_mod.extractLines(content, line, line, false, true, lang, alloc) catch null;
}

fn looksPathLike(target: []const u8) bool {
    return std.mem.indexOfScalar(u8, target, '/') != null or
        std.mem.indexOfScalar(u8, target, '.') != null or
        std.mem.endsWith(u8, target, ".zig") or
        std.mem.endsWith(u8, target, ".rs") or
        std.mem.endsWith(u8, target, ".ts") or
        std.mem.endsWith(u8, target, ".py");
}

fn appendUniqueBorrow(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try list.append(alloc, value);
}

fn renderSimpleError(alloc: std.mem.Allocator, message: []const u8) RenderResult {
    const text = alloc.dupe(u8, message) catch @constCast(message);
    return .{
        .text = text,
        .full_text = text,
        .coverage = &.{},
        .limits = &.{},
    };
}

fn persistArtifact(
    io: std.Io,
    alloc: std.mem.Allocator,
    data_dir: []const u8,
    req: CompassRequest,
    generation: Generation,
    artifact: StoredArtifact,
    overflow_keep: u32,
) ![]const u8 {
    const token = try makeReqId(alloc, req, generation);
    errdefer alloc.free(token);

    const compass_dir_path = try std.fmt.allocPrint(alloc, "{s}/compass", .{data_dir});
    defer alloc.free(compass_dir_path);
    std.Io.Dir.cwd().createDirPath(io, compass_dir_path) catch {};

    var root_dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{});
    defer root_dir.close(io);
    var compass_dir = try root_dir.openDir(io, "compass", .{ .iterate = true });
    defer compass_dir.close(io);

    const json = try buildArtifactJson(alloc, req, generation, artifact);
    defer alloc.free(json);

    var tmp_name_buf: [32]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, "{s}.tmp", .{token});
    {
        const tmp = try compass_dir.createFile(io, tmp_name, .{});
        defer tmp.close(io);
        try tmp.writeStreamingAll(io, json);
    }
    const final_name = try std.fmt.allocPrint(alloc, "{s}.json", .{token});
    defer alloc.free(final_name);
    try compass_dir.rename(tmp_name, compass_dir, final_name, io);
    pruneOverflow(io, alloc, compass_dir, overflow_keep);
    return token;
}

fn replayStored(
    io: std.Io,
    alloc: std.mem.Allocator,
    token: []const u8,
    format: Format,
    explorer: *Explorer,
    store: *Store,
    data_dir: []const u8,
    out: *std.ArrayList(u8),
) void {
    if (!isValidMoreToken(token)) {
        out.appendSlice(alloc, "error: invalid more token") catch {};
        return;
    }
    var root_dir = std.Io.Dir.cwd().openDir(io, data_dir, .{}) catch {
        out.appendSlice(alloc, "error: overflow store unavailable") catch {};
        return;
    };
    defer root_dir.close(io);
    var compass_dir = root_dir.openDir(io, "compass", .{}) catch {
        out.appendSlice(alloc, "error: no stored overflow for this project") catch {};
        return;
    };
    defer compass_dir.close(io);

    var file_name_buf: [32]u8 = undefined;
    const file_name = std.fmt.bufPrint(&file_name_buf, "{s}.json", .{token}) catch {
        out.appendSlice(alloc, "error: invalid more token") catch {};
        return;
    };
    const raw = compass_dir.readFileAlloc(io, file_name, alloc, .limited(4 * 1024 * 1024)) catch {
        out.appendSlice(alloc, "error: overflow handle not found") catch {};
        return;
    };
    defer alloc.free(raw);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch {
        out.appendSlice(alloc, "error: overflow artifact is corrupt") catch {};
        return;
    };
    defer parsed.deinit();
    const root = parsed.value.object;
    const manifest = root.get("manifest") orelse {
        out.appendSlice(alloc, "error: overflow artifact is corrupt") catch {};
        return;
    };
    if (manifest != .object) {
        out.appendSlice(alloc, "error: overflow artifact is corrupt") catch {};
        return;
    }
    const current = currentGeneration(explorer, store);
    const seq = jsonU64(manifest.object, "seq") orelse 0;
    const files = jsonU64(manifest.object, "files") orelse 0;
    if (seq != current.seq or files != current.files) {
        out.appendSlice(alloc, "overflow stale, re-run query") catch {};
        return;
    }

    const full_text = jsonString(root, "full_text") orelse {
        out.appendSlice(alloc, "error: overflow artifact is corrupt") catch {};
        return;
    };
    switch (format) {
        .text => out.appendSlice(alloc, full_text) catch {},
        .json => {
            const route_line = jsonString(root, "route_line") orelse "";
            const alt_line = jsonNullableString(root, "alt_line");
            const coverage = parseCoverageArray(alloc, root.get("coverage")) catch &.{};
            const limits = parseStringArray(alloc, root.get("limits")) catch &.{};
            appendJsonResponse(alloc, out, route_line, alt_line, coverage, limits, full_text, null) catch {
                out.appendSlice(alloc, "error: compass json render failed") catch {};
            };
        },
    }
}

fn makeReqId(alloc: std.mem.Allocator, req: CompassRequest, generation: Generation) ![]const u8 {
    const intent = if (req.intent) |i| @tagName(i) else "";
    const target = req.target orelse "";
    const basis = try std.fmt.allocPrint(alloc, "{s}|{s}|{s}|{any}|{any}|{d}|{d}", .{
        intent,
        target,
        req.task,
        req.want_body,
        req.max_files,
        generation.seq,
        generation.files,
    });
    defer alloc.free(basis);
    const hash = std.hash.Wyhash.hash(0, basis);
    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>16}", .{hash}) catch unreachable;
    return alloc.dupe(u8, &buf);
}

fn isValidMoreToken(token: []const u8) bool {
    if (token.len != 16) return false;
    for (token) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

fn buildArtifactJson(
    alloc: std.mem.Allocator,
    req: CompassRequest,
    generation: Generation,
    artifact: StoredArtifact,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const w = cio.listWriter(&out, alloc);
    w.writeAll("{\"manifest\":{") catch return error.OutOfMemory;
    w.print("\"intent\":\"{s}\",\"task_hash\":{d},\"want_body\":{s},\"max_files\":{d},\"seq\":{d},\"files\":{d}", .{
        if (req.intent) |intent| @tagName(intent) else "",
        std.hash.Wyhash.hash(0, req.task),
        if (req.want_body orelse false) "true" else "false",
        req.max_files orelse 0,
        generation.seq,
        generation.files,
    }) catch return error.OutOfMemory;
    if (req.target) |target| {
        w.writeAll(",\"target\":\"") catch return error.OutOfMemory;
        try writeJsonEscaped(&out, alloc, target);
        w.writeAll("\"") catch return error.OutOfMemory;
    }
    w.writeAll("},\"route_line\":\"") catch return error.OutOfMemory;
    try writeJsonEscaped(&out, alloc, artifact.route_line);
    w.writeAll("\",\"alt_line\":") catch return error.OutOfMemory;
    if (artifact.alt_line) |alt| {
        w.writeAll("\"") catch return error.OutOfMemory;
        try writeJsonEscaped(&out, alloc, alt);
        w.writeAll("\"") catch return error.OutOfMemory;
    } else {
        w.writeAll("null") catch return error.OutOfMemory;
    }
    w.writeAll(",\"coverage\":[") catch return error.OutOfMemory;
    for (artifact.coverage, 0..) |row, i| {
        if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
        w.writeAll("{\"section\":\"") catch return error.OutOfMemory;
        try writeJsonEscaped(&out, alloc, row.section);
        w.print("\",\"shown\":{d},\"total\":{d}}}", .{ row.shown, row.total }) catch return error.OutOfMemory;
    }
    w.writeAll("],\"limits\":[") catch return error.OutOfMemory;
    for (artifact.limits, 0..) |line, i| {
        if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
        w.writeAll("\"") catch return error.OutOfMemory;
        try writeJsonEscaped(&out, alloc, line);
        w.writeAll("\"") catch return error.OutOfMemory;
    }
    w.writeAll("],\"full_text\":\"") catch return error.OutOfMemory;
    try writeJsonEscaped(&out, alloc, artifact.full_text);
    w.writeAll("\"}") catch return error.OutOfMemory;
    return out.toOwnedSlice(alloc);
}

fn pruneOverflow(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir, keep: u32) void {
    var entries = std.ArrayList(struct { name: []u8, mtime: i128 }).empty;
    defer {
        for (entries.items) |entry| alloc.free(entry.name);
        entries.deinit(alloc);
    }

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        entries.append(alloc, .{
            .name = alloc.dupe(u8, entry.name) catch continue,
            .mtime = stat.mtime.nanoseconds,
        }) catch continue;
    }

    if (entries.items.len <= keep) return;
    std.mem.sort(@TypeOf(entries.items[0]), entries.items, {}, struct {
        fn lt(_: void, a: @TypeOf(entries.items[0]), b: @TypeOf(entries.items[0])) bool {
            return a.mtime > b.mtime;
        }
    }.lt);
    for (entries.items[keep..]) |entry| {
        dir.deleteFile(io, entry.name) catch {};
    }
}

fn writeJsonEscaped(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (ch < 0x20) {
                    const hex = "0123456789abcdef";
                    const esc = [6]u8{ '\\', 'u', '0', '0', hex[ch >> 4], hex[ch & 0x0f] };
                    try out.appendSlice(alloc, &esc);
                } else {
                    try out.append(alloc, ch);
                }
            },
        }
    }
}

fn appendJsonResponse(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    route_line: []const u8,
    alt_line: ?[]const u8,
    coverage: []const render_mod.CoverageRow,
    limits: []const []const u8,
    text: []const u8,
    more_id: ?[]const u8,
) !void {
    const w = cio.listWriter(out, alloc);
    w.writeAll("{\"route\":\"") catch return error.OutOfMemory;
    try writeJsonEscaped(out, alloc, route_line);
    w.writeAll("\",\"alts\":") catch return error.OutOfMemory;
    if (alt_line) |alt| {
        w.writeAll("\"") catch return error.OutOfMemory;
        try writeJsonEscaped(out, alloc, alt);
        w.writeAll("\"") catch return error.OutOfMemory;
    } else {
        w.writeAll("null") catch return error.OutOfMemory;
    }
    w.writeAll(",\"coverage\":[") catch return error.OutOfMemory;
    for (coverage, 0..) |row, i| {
        if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
        w.writeAll("{\"section\":\"") catch return error.OutOfMemory;
        try writeJsonEscaped(out, alloc, row.section);
        w.print("\",\"shown\":{d},\"total\":{d}}}", .{ row.shown, row.total }) catch return error.OutOfMemory;
    }
    w.writeAll("],\"limits\":[") catch return error.OutOfMemory;
    for (limits, 0..) |line, i| {
        if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
        w.writeAll("\"") catch return error.OutOfMemory;
        try writeJsonEscaped(out, alloc, line);
        w.writeAll("\"") catch return error.OutOfMemory;
    }
    w.writeAll("],\"text\":\"") catch return error.OutOfMemory;
    try writeJsonEscaped(out, alloc, text);
    w.writeAll("\",\"more\":") catch return error.OutOfMemory;
    if (more_id) |token| {
        w.writeAll("\"") catch return error.OutOfMemory;
        try writeJsonEscaped(out, alloc, token);
        w.writeAll("\"") catch return error.OutOfMemory;
    } else {
        w.writeAll("null") catch return error.OutOfMemory;
    }
    w.writeAll("}") catch return error.OutOfMemory;
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonNullableString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        .null => null,
        else => null,
    };
}

fn jsonU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| @intCast(n),
        else => null,
    };
}

fn parseCoverageArray(alloc: std.mem.Allocator, value: ?std.json.Value) ![]const render_mod.CoverageRow {
    const val = value orelse return &.{};
    if (val != .array) return &.{};
    var rows = std.ArrayList(render_mod.CoverageRow).empty;
    for (val.array.items) |item| {
        if (item != .object) continue;
        try rows.append(alloc, .{
            .section = try alloc.dupe(u8, jsonString(item.object, "section") orelse ""),
            .shown = @intCast(jsonU64(item.object, "shown") orelse 0),
            .total = @intCast(jsonU64(item.object, "total") orelse 0),
        });
    }
    return rows.toOwnedSlice(alloc);
}

fn parseStringArray(alloc: std.mem.Allocator, value: ?std.json.Value) ![]const []const u8 {
    const val = value orelse return &.{};
    if (val != .array) return &.{};
    var rows = std.ArrayList([]const u8).empty;
    for (val.array.items) |item| {
        if (item != .string) continue;
        try rows.append(alloc, try alloc.dupe(u8, item.string));
    }
    return rows.toOwnedSlice(alloc);
}
