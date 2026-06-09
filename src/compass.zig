const std = @import("std");
const cio = @import("cio.zig");
const explore_mod = @import("explore.zig");
const Explorer = explore_mod.Explorer;
const Store = @import("store.zig").Store;
const path_security = @import("path_security.zig");
const render_mod = @import("compass_render.zig");
const reader_md = @import("reader_md.zig");
const shared = @import("compass_shared.zig");

pub const Intent = enum { overview, define, callers, blast_radius };
pub const Mode = enum { summary, minimal, evidence, raw };
pub const Format = enum { text, json };

pub const Settings = struct {
    max_files: u32 = 5,
    body: bool = false,
    overflow_keep: u32 = 50,
    callers_candidate_budget: ?usize = null,
};

pub var default_settings: Settings = .{};

pub const CompassRequest = struct {
    intent: ?Intent = null,
    task: []const u8 = "",
    target: ?[]const u8 = null,
    want_body: ?bool = null,
    max_files: ?u32 = null,
    mode: Mode = .summary,
    mode_explicit: bool = false,
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

const EffectiveRequest = struct {
    intent: Intent,
    target: ?[]const u8,
    state: RouteState,
    want_body: bool,
    max_files: u32,
    mode: Mode,
    task: []const u8,
};

pub const DefinitionItem = struct {
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

pub const CallerItem = struct {
    path: []const u8,
    line: u32,
    text: []const u8,
    scope_name: ?[]const u8 = null,
    scope_kind: ?explore_mod.SymbolKind = null,
    scope_start: u32 = 0,
    scope_end: u32 = 0,
};

const CalleeItem = struct {
    name: []const u8,
    kind: []const u8,
    path: []const u8,
    line: u32,
};

pub const CallersResult = struct {
    defs: []const DefinitionItem,
    callers: []const CallerItem,
    file_count: usize,
    def_rejects: usize,
    substring_rejects: usize,
    non_call_site_rejects: usize,
    case_variant_rejects: usize = 0,
    import_type_rejects: usize = 0,
    comment_string_rejects: usize = 0,
    type_position_rejects: usize = 0,
    stale_line_rejects: usize = 0,
    candidate_lines: usize = 0,
    word_index_used: bool = false,
    gather_capped: bool = false,
};

const DefineResult = struct {
    defs: []const DefinitionItem,
    fallback_sites: []const SiteItem,
    sites_total: usize,
    sites_lower_bound: bool = false,
    fuzzy_files: []const []const u8,
    stage_rows: []const render_mod.StageRow,
    exact_defs: usize,
};

const OverviewResult = struct {
    keywords: []const []const u8,
    defs: []const DefinitionItem,
    defs_total: usize,
    def_ambiguity_count: usize,
    files: []const RankedFile,
    callers: []const CallerItem,
    callers_total: usize,
    callees: []const CalleeItem,
    callees_total: usize,
    callees_capped: bool,
    excluded_test_files: usize,
    included_test_files_for_recall: usize,
    callers_list_capped: bool,
    callers_gather_capped: bool,
    caller_comment_string_rejects: usize,
    caller_type_position_rejects: usize,
    stage_rows: []const render_mod.StageRow,
};

const OverviewCallersResult = struct {
    callers: []const CallerItem,
    total: usize,
    list_capped: bool,
    gather_capped: bool,
    comment_string_rejects: usize,
    type_position_rejects: usize,
};

const OverviewCalleesResult = struct {
    callees: []const CalleeItem,
    total: usize,
    capped: bool,
};

const BlastResult = struct {
    target_file: ?[]const u8,
    target_defs: []const DefinitionItem,
    callers: ?CallersResult,
    dependents: []const explore_mod.DepthDependent,
    total_dependents: usize,
    depth_counts: []const usize,
};

const RenderResult = struct {
    text: []u8,
    full_text: []u8,
    coverage: []const render_mod.CoverageRow,
    limits: []const []const u8,

    fn deinit(self: *RenderResult, alloc: std.mem.Allocator) void {
        const full_shared_text = self.full_text.ptr == self.text.ptr and self.full_text.len == self.text.len;
        alloc.free(self.text);
        if (!full_shared_text) alloc.free(self.full_text);
        alloc.free(self.coverage);
        for (self.limits) |limit| alloc.free(limit);
        alloc.free(self.limits);
        self.* = .{
            .text = &.{},
            .full_text = &.{},
            .coverage = &.{},
            .limits = &.{},
        };
    }
};

const TextRender = struct {
    text: []u8,
    coverage: []const render_mod.CoverageRow,
    limits: []const []const u8,

    fn deinitMetadata(self: TextRender, alloc: std.mem.Allocator) void {
        alloc.free(self.coverage);
        for (self.limits) |limit| alloc.free(limit);
        alloc.free(self.limits);
    }
};

const overview_view_sites_per_file: usize = 3;
const callers_candidate_budget: usize = 50_000;
const overview_candidate_budget: usize = 4_000;
const overview_callers_keep: usize = 200;

pub fn parseIntent(value: []const u8) ?Intent {
    if (std.mem.eql(u8, value, "overview")) return .overview;
    if (std.mem.eql(u8, value, "define")) return .define;
    if (std.mem.eql(u8, value, "callers")) return .callers;
    if (std.mem.eql(u8, value, "blast_radius")) return .blast_radius;
    return null;
}

pub fn parseFormat(value: []const u8) ?Format {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    return null;
}

pub fn parseMode(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "summary")) return .summary;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "evidence")) return .evidence;
    if (std.mem.eql(u8, value, "raw")) return .raw;
    return null;
}

pub fn intentName(intent: Intent) []const u8 {
    return @tagName(intent);
}

fn intentNeedsTarget(intent: Intent) bool {
    return intent == .define or intent == .callers or intent == .blast_radius;
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
        replayStored(io, alloc, token, req, explorer, store, data_dir, out);
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

    var rendered = switch (route.intent) {
        .overview => renderOverview(io, alloc, A, task, route, effective_max_files, want_body, explorer),
        .define => renderDefine(io, alloc, A, task, route, effective_max_files, want_body, explorer),
        .callers => renderCallers(alloc, A, task, route, effective_max_files, want_body, explorer, settings.callers_candidate_budget orelse callers_candidate_budget),
        .blast_radius => renderBlastRadius(alloc, A, task, route, effective_max_files, want_body, explorer),
    } catch {
        out.appendSlice(alloc, "error: compass execution failed") catch {};
        return;
    };
    defer rendered.deinit(alloc);
    if (req.mode == .minimal) applyMinimalMode(alloc, &rendered);

    const truncated = isTruncated(rendered.coverage);
    const response_text = rendered.text;
    var more_id: ?[]const u8 = null;

    if (truncated) {
        const effective = EffectiveRequest{
            .intent = route.intent,
            .target = if (route.target) |target| target.text else null,
            .state = route.state,
            .want_body = want_body,
            .max_files = effective_max_files,
            .mode = req.mode,
            .task = task,
        };
        const artifact = StoredArtifact{
            .route_line = route.rationale,
            .alt_line = if (route.state == .ambiguous and route.runner_up != null) @tagName(route.runner_up.?) else null,
            .coverage = rendered.coverage,
            .limits = rendered.limits,
            .full_text = rendered.full_text,
        };
        if (persistArtifact(io, alloc, data_dir, effective, generation, artifact, settings.overflow_keep)) |token| {
            more_id = token;
        } else |_| {}
    }
    defer if (more_id) |token| alloc.free(token);

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
    const normalized = try normalizeTask(task, alloc);
    const blast_phrase_score = blastRadiusPhraseScore(normalized);
    const blast_requested = (intent_override != null and intent_override.? == .blast_radius) or blast_phrase_score > 0;
    const blast_target = if (blast_requested) bestAnchorSkippingBlastScaffold(anchors.items) else null;
    const blast_phrase_with_target = intent_override == null and blast_phrase_score > 0 and blast_target != null;

    const target = if (target_override) |t|
        Anchor{ .text = t, .kind = classifyStandaloneTarget(t), .salience = 4 }
    else if (blast_requested)
        blast_target
    else
        bestAnchor(anchors.items);

    if (intent_override) |intent| {
        const routed_intent = if (intentNeedsTarget(intent) and target == null) .overview else intent;
        return .{
            .intent = routed_intent,
            .target = target,
            .confidence = .explicit,
            .state = if (intent != routed_intent) .fallback else .exact,
            .rationale = try std.fmt.allocPrint(alloc, "{s} target={s} confidence=explicit", .{
                @tagName(routed_intent),
                if (target) |a| a.text else "none",
            }),
        };
    }

    const strong_anchor_count = countStrongAnchors(anchors.items);

    var overview_score: i32 = 1;
    var define_score: i32 = 0;
    var callers_score: i32 = 0;
    var blast_score: i32 = 0;

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
    blast_score += blast_phrase_score;

    if (!has_strong_anchor) {
        define_score = @min(define_score, 1);
        callers_score = @min(callers_score, 1);
        if (target_override == null and blast_target == null) {
            blast_score = @min(blast_score, 1);
        }
        overview_score += 2;
    } else {
        callers_score += 1;
        if (strong_anchor_count == 1) define_score += 2;
    }

    const scored = [_]struct { intent: Intent, score: i32, priority: i32 }{
        .{ .intent = .blast_radius, .score = blast_score, .priority = 4 },
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

    if (intentNeedsTarget(selected) and target == null) {
        selected = .overview;
        state = .fallback;
        confidence = .weak;
        runner_up = winner.intent;
    } else if (winner.intent != .overview and winner.score - runner.score < 2 and !(winner.intent == .blast_radius and blast_phrase_with_target)) {
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
        if (phrase_hits.len > 0 or fuzzy_paths.len > 0) {
            appendUniqueBorrow(arena, &keywords, phrase) catch {};
        }
    }

    var defs_total: usize = 0;
    var def_ambiguity_count: usize = 0;
    for (content_queries.items) |kw| {
        const require_whole_word = shared.looksLikeContextIdentifier(kw);
        const is_route_target = if (route.target) |target| std.mem.eql(u8, target.text, kw) else false;
        const allow_word_definition_probe = !overview_has_strong_anchor and is_route_target;
        if (classifyStandaloneTarget(kw) != .word or allow_word_definition_probe) {
            const found_defs = explorer.findAllSymbols(kw, arena) catch &.{};
            if (found_defs.len > 1) def_ambiguity_count = @max(def_ambiguity_count, found_defs.len);
            var sampled_for_keyword: usize = 0;
            for (found_defs) |d| {
                const def_key = try std.fmt.allocPrint(arena, "{s}:{d}", .{ d.path, d.symbol.line_start });
                if (seen_defs.contains(def_key)) continue;
                try seen_defs.put(def_key, {});
                defs_total += 1;
                if (sampled_for_keyword >= 3) continue;
                sampled_for_keyword += 1;
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
    var excluded_ranked = std.ArrayList(RankedFile).empty;
    var excluded_test_files: usize = 0;
    var by_file_it = by_file.iterator();
    while (by_file_it.next()) |entry| {
        const path = entry.key_ptr.*;
        const lang = explore_mod.detectLanguage(path);
        const capped_hits = @min(entry.value_ptr.total, 3);
        var score = @as(f32, @floatFromInt(shared.scoreContextFile(path, capped_hits, symbol_files.contains(path))));
        score += @min(entry.value_ptr.score, 8.0);
        score += overviewPathBoost(path, keywords.items);
        score -= overviewPathPenalty(path, lang);
        const item = RankedFile{
            .path = path,
            .hits = entry.value_ptr.total,
            .score = score,
            .sites = entry.value_ptr.sites.items,
        };
        if (shared.isTestLikePath(path)) {
            excluded_test_files += 1;
            try excluded_ranked.append(arena, item);
        } else {
            try ranked.append(arena, item);
        }
    }
    std.mem.sort(RankedFile, ranked.items, {}, struct {
        fn lt(_: void, a: RankedFile, b: RankedFile) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.hits > b.hits;
        }
    }.lt);
    std.mem.sort(RankedFile, excluded_ranked.items, {}, struct {
        fn lt(_: void, a: RankedFile, b: RankedFile) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.hits > b.hits;
        }
    }.lt);
    var included_test_files_for_recall: usize = 0;
    if (ranked.items.len == 0 and excluded_ranked.items.len > 0) {
        for (excluded_ranked.items) |item| try ranked.append(arena, item);
        included_test_files_for_recall = excluded_ranked.items.len;
    }

    const callers = collectOverviewCallers(explorer, arena, defs.items) catch OverviewCallersResult{
        .callers = &.{},
        .total = 0,
        .list_capped = false,
        .gather_capped = false,
        .comment_string_rejects = 0,
        .type_position_rejects = 0,
    };
    const callees = collectOverviewCallees(explorer, arena, defs.items, route.target) catch OverviewCalleesResult{ .callees = &.{}, .total = 0, .capped = false };
    const reader_prefix = maybeReaderPrefix(io, arena, task, explorer);
    const full = try renderOverviewText(alloc, route, .{
        .keywords = keywords.items,
        .defs = defs.items,
        .defs_total = @max(defs_total, defs.items.len),
        .def_ambiguity_count = def_ambiguity_count,
        .files = ranked.items,
        .callers = callers.callers,
        .callers_total = callers.total,
        .callees = callees.callees,
        .callees_total = callees.total,
        .callees_capped = callees.capped,
        .excluded_test_files = excluded_test_files,
        .included_test_files_for_recall = included_test_files_for_recall,
        .callers_list_capped = callers.list_capped,
        .callers_gather_capped = callers.gather_capped,
        .caller_comment_string_rejects = callers.comment_string_rejects,
        .caller_type_position_rejects = callers.type_position_rejects,
        .stage_rows = stage_rows.items,
    }, ranked.items.len, defs.items.len, std.math.maxInt(usize), callers.callers.len, callees.callees.len, reader_prefix);
    errdefer alloc.free(full.text);
    defer full.deinitMetadata(alloc);
    const view = try renderOverviewText(alloc, route, .{
        .keywords = keywords.items,
        .defs = defs.items,
        .defs_total = @max(defs_total, defs.items.len),
        .def_ambiguity_count = def_ambiguity_count,
        .files = ranked.items,
        .callers = callers.callers,
        .callers_total = callers.total,
        .callees = callees.callees,
        .callees_total = callees.total,
        .callees_capped = callees.capped,
        .excluded_test_files = excluded_test_files,
        .included_test_files_for_recall = included_test_files_for_recall,
        .callers_list_capped = callers.list_capped,
        .callers_gather_capped = callers.gather_capped,
        .caller_comment_string_rejects = callers.comment_string_rejects,
        .caller_type_position_rejects = callers.type_position_rejects,
        .stage_rows = stage_rows.items,
    }, max_files, @min(defs.items.len, @as(usize, max_files)), overview_view_sites_per_file, @min(callers.callers.len, @as(usize, max_files) * 2), @min(callees.callees.len, @as(usize, max_files)), reader_prefix);
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
    errdefer alloc.free(full.text);
    defer full.deinitMetadata(alloc);
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
    candidate_budget: usize,
) !RenderResult {
    _ = task;
    _ = want_body;
    const target = route.target orelse return renderSimpleError(alloc, "error: no target bound for callers");
    const result = gatherCallersExact(explorer, arena, target.text, candidate_budget) catch return renderSimpleError(alloc, "error: callers gather failed");
    const full = try renderCallersText(alloc, route, result, std.math.maxInt(u32));
    errdefer alloc.free(full.text);
    defer full.deinitMetadata(alloc);
    const view = try renderCallersText(alloc, route, result, max_files);
    return .{
        .text = view.text,
        .full_text = full.text,
        .coverage = view.coverage,
        .limits = view.limits,
    };
}

fn renderBlastRadius(
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
    const target = route.target orelse return renderSimpleError(alloc, "error: no target bound for blast_radius");
    const result = collectBlastRadius(explorer, arena, target.text) catch return renderSimpleError(alloc, "error: blast_radius gather failed");
    const full = try renderBlastText(alloc, route, result, std.math.maxInt(u32));
    errdefer alloc.free(full.text);
    defer full.deinitMetadata(alloc);
    const view = try renderBlastText(alloc, route, result, max_files);
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
            .sites_total = fallback_sites.items.len,
            .sites_lower_bound = false,
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
            .sites_total = word_hits.len,
            .sites_lower_bound = false,
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
            .sites_total = search_hits.len,
            .sites_lower_bound = search_hits.len == 20,
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
        .sites_total = fallback_sites.items.len,
        .sites_lower_bound = false,
        .fuzzy_files = fuzzy_files.items,
        .stage_rows = stages.items,
        .exact_defs = 0,
    };
}

pub fn collectCallers(explorer: *Explorer, arena: std.mem.Allocator, target: []const u8) !CallersResult {
    return gatherCallersExact(explorer, arena, target, callers_candidate_budget);
}

pub fn gatherCallersExact(explorer: *Explorer, arena: std.mem.Allocator, target: []const u8, candidate_budget: usize) !CallersResult {
    if (!isIdentifierTarget(target)) return gatherCallersTrigramFallback(explorer, arena, target);

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

    const word_lines = explorer.searchWordLines(target, arena) catch {
        return gatherCallersTrigramFallbackWithDefs(explorer, arena, target, defs.items);
    };
    if (word_lines.len == 0) {
        const probe = explorer.searchContentWithOptions(target, arena, .{
            .max_results = 8,
            .compact = true,
        }) catch &.{};
        var word_index_missed = false;
        for (probe) |hit| {
            if (shared.hasWholeWordMatch(hit.line_text, target)) {
                word_index_missed = true;
                break;
            }
        }
        if (word_index_missed) return gatherCallersTrigramFallbackWithDefs(explorer, arena, target, defs.items);
        return .{
            .defs = defs.items,
            .callers = &.{},
            .file_count = 0,
            .def_rejects = 0,
            .substring_rejects = 0,
            .non_call_site_rejects = 0,
            .candidate_lines = 0,
            .word_index_used = true,
        };
    }

    var callers = std.ArrayList(CallerItem).empty;
    var file_set = std.StringHashMap(void).init(arena);
    var def_rejects: usize = 0;
    var substring_rejects: usize = 0;
    var non_call_site_rejects: usize = 0;
    var case_variant_rejects: usize = 0;
    var import_type_rejects: usize = 0;
    var comment_string_rejects: usize = 0;
    var type_position_rejects: usize = 0;
    var stale_line_rejects: usize = 0;

    const candidate_lines = word_lines.len;
    const take = @min(candidate_lines, candidate_budget);
    const selected_lines = word_lines[0..take];

    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();

    var i: usize = 0;
    while (i < selected_lines.len) {
        const path = selected_lines[i].path;
        var end = i + 1;
        while (end < selected_lines.len and std.mem.eql(u8, selected_lines[end].path, path)) : (end += 1) {}
        const line_run = selected_lines[i..end];
        if (!shared.langHasCallSites(explore_mod.detectLanguage(path))) {
            non_call_site_rejects += line_run.len;
            i = end;
            continue;
        }

        const content = (explorer.getContent(path, scratch.allocator()) catch null) orelse {
            _ = scratch.reset(.retain_capacity);
            i = end;
            continue;
        };
        var run_i: usize = 0;
        var line_num: u32 = 0;
        var block_comment_active = false;
        var enum_body_depth: usize = 0;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |raw_line| {
            line_num += 1;
            const line = stripTrailingCr(raw_line);
            while (run_i < line_run.len and line_run[run_i].line < line_num) : (run_i += 1) {}
            if (run_i < line_run.len and line_run[run_i].line == line_num) {
                while (run_i < line_run.len and line_run[run_i].line == line_num) : (run_i += 1) {
                    if (std.mem.indexOf(u8, line, target) == null) {
                        case_variant_rejects += 1;
                        continue;
                    }
                    if (!shared.hasWholeWordMatch(line, target)) {
                        substring_rejects += 1;
                        continue;
                    }
                    const scope = explorer.findEnclosingSymbolInfo(path, line_num, arena) catch null;
                    var in_enum_scope = enum_body_depth > 0;
                    if (scope) |s| {
                        if (scopeEnclosesLine(s, line_num) and s.kind == .enum_def) in_enum_scope = true;
                    }
                    if (!in_enum_scope and lineLooksLikeEnumVariantDeclaration(line, target) and lineInsideEnumBody(content, line_num)) {
                        in_enum_scope = true;
                    }
                    switch (classifyLineReference(line, target, block_comment_active, in_enum_scope)) {
                        .call => {},
                        .comment_string => {
                            comment_string_rejects += 1;
                            continue;
                        },
                        .type_position => {
                            type_position_rejects += 1;
                            continue;
                        },
                        .none => {
                            substring_rejects += 1;
                            continue;
                        },
                    }
                    if (isDefinitionLine(defs.items, path, line_num)) {
                        def_rejects += 1;
                        continue;
                    }
                    if (scope) |s| {
                        if (scopeEnclosesLine(s, line_num) and scopeKindIsImportTypeOnly(s.kind)) {
                            import_type_rejects += 1;
                            continue;
                        }
                        try callers.append(arena, .{
                            .path = path,
                            .line = line_num,
                            .text = try arena.dupe(u8, line),
                            .scope_name = s.name,
                            .scope_kind = s.kind,
                            .scope_start = s.line_start,
                            .scope_end = s.line_end,
                        });
                    } else {
                        try callers.append(arena, .{
                            .path = path,
                            .line = line_num,
                            .text = try arena.dupe(u8, line),
                        });
                    }
                    try file_set.put(path, {});
                }
            }
            block_comment_active = blockCommentStateAfterLine(line, block_comment_active);
            enum_body_depth = enumBodyDepthAfterLine(line, enum_body_depth);
            if (run_i >= line_run.len) break;
        }
        if (run_i < line_run.len) stale_line_rejects += line_run.len - run_i;
        _ = scratch.reset(.retain_capacity);
        i = end;
    }
    sortCallers(callers.items);

    return .{
        .defs = defs.items,
        .callers = callers.items,
        .file_count = file_set.count(),
        .def_rejects = def_rejects,
        .substring_rejects = substring_rejects,
        .non_call_site_rejects = non_call_site_rejects,
        .case_variant_rejects = case_variant_rejects,
        .import_type_rejects = import_type_rejects,
        .comment_string_rejects = comment_string_rejects,
        .type_position_rejects = type_position_rejects,
        .stale_line_rejects = stale_line_rejects,
        .candidate_lines = candidate_lines,
        .word_index_used = true,
        .gather_capped = candidate_lines > take,
    };
}

fn gatherCallersTrigramFallback(explorer: *Explorer, arena: std.mem.Allocator, target: []const u8) !CallersResult {
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
    return gatherCallersTrigramFallbackWithDefs(explorer, arena, target, defs.items);
}

fn gatherCallersTrigramFallbackWithDefs(explorer: *Explorer, arena: std.mem.Allocator, target: []const u8, defs: []const DefinitionItem) !CallersResult {
    const scoped = explorer.searchContentWithScopeOptions(target, arena, .{
        .max_results = 200,
        .compact = true,
    }) catch &.{};

    var callers = std.ArrayList(CallerItem).empty;
    var file_set = std.StringHashMap(void).init(arena);
    var def_rejects: usize = 0;
    var substring_rejects: usize = 0;
    var non_call_site_rejects: usize = 0;
    var case_variant_rejects: usize = 0;
    var import_type_rejects: usize = 0;
    var comment_string_rejects: usize = 0;
    var type_position_rejects: usize = 0;

    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();

    for (scoped) |hit| {
        if (!shared.langHasCallSites(explore_mod.detectLanguage(hit.path))) {
            non_call_site_rejects += 1;
            continue;
        }
        if (std.mem.indexOf(u8, hit.line_text, target) == null) {
            case_variant_rejects += 1;
            continue;
        }
        if (!shared.hasWholeWordMatch(hit.line_text, target)) {
            substring_rejects += 1;
            continue;
        }
        var in_enum_scope = false;
        if (hit.scope_kind) |kind| {
            if (kind == .enum_def and hit.scope_start <= hit.line_num and hit.line_num <= hit.scope_end) in_enum_scope = true;
        }
        const reference_kind = classifyFileLineReference(explorer, scratch.allocator(), hit.path, hit.line_num, hit.line_text, target, in_enum_scope);
        _ = scratch.reset(.retain_capacity);
        switch (reference_kind) {
            .call => {},
            .comment_string => {
                comment_string_rejects += 1;
                continue;
            },
            .type_position => {
                type_position_rejects += 1;
                continue;
            },
            .none => {
                substring_rejects += 1;
                continue;
            },
        }
        if (isDefinitionLine(defs, hit.path, hit.line_num)) {
            def_rejects += 1;
            continue;
        }
        if (hit.scope_kind) |kind| {
            if (hit.scope_start <= hit.line_num and hit.line_num <= hit.scope_end and scopeKindIsImportTypeOnly(kind)) {
                import_type_rejects += 1;
                continue;
            }
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
    sortCallers(callers.items);

    return .{
        .defs = defs,
        .callers = callers.items,
        .file_count = file_set.count(),
        .def_rejects = def_rejects,
        .substring_rejects = substring_rejects,
        .non_call_site_rejects = non_call_site_rejects,
        .case_variant_rejects = case_variant_rejects,
        .import_type_rejects = import_type_rejects,
        .comment_string_rejects = comment_string_rejects,
        .type_position_rejects = type_position_rejects,
        .candidate_lines = scoped.len,
        .word_index_used = false,
        .gather_capped = scoped.len == 200,
    };
}

fn collectOverviewCallers(explorer: *Explorer, arena: std.mem.Allocator, defs: []const DefinitionItem) !OverviewCallersResult {
    var callers = std.ArrayList(CallerItem).empty;
    var seen = std.StringHashMap(void).init(arena);
    var searched = std.StringHashMap(void).init(arena);
    var total: usize = 0;
    var list_capped = false;
    var gather_capped = false;
    var comment_string_rejects: usize = 0;
    var type_position_rejects: usize = 0;

    for (defs) |def| {
        if (searched.contains(def.name)) continue;
        try searched.put(def.name, {});
        const result = gatherCallersExact(explorer, arena, def.name, overview_candidate_budget) catch continue;
        if (result.gather_capped) gather_capped = true;
        comment_string_rejects += result.comment_string_rejects;
        type_position_rejects += result.type_position_rejects;
        for (result.callers) |hit| {
            if (shared.isTestLikePath(hit.path)) continue;
            const key = try std.fmt.allocPrint(arena, "{s}:{d}", .{ hit.path, hit.line });
            if (seen.contains(key)) continue;
            try seen.put(key, {});
            total += 1;
            if (callers.items.len < overview_callers_keep) {
                try callers.append(arena, hit);
            } else {
                list_capped = true;
            }
        }
    }
    sortCallers(callers.items);
    return .{
        .callers = callers.items,
        .total = total,
        .list_capped = list_capped,
        .gather_capped = gather_capped,
        .comment_string_rejects = comment_string_rejects,
        .type_position_rejects = type_position_rejects,
    };
}

fn collectOverviewCallees(explorer: *Explorer, arena: std.mem.Allocator, defs: []const DefinitionItem, target: ?Anchor) !OverviewCalleesResult {
    const bound = target orelse return .{ .callees = &.{}, .total = 0, .capped = false };
    var callees = std.ArrayList(CalleeItem).empty;
    var seen = std.StringHashMap(void).init(arena);
    var inspected: usize = 0;
    var capped = false;
    for (defs) |def| {
        if (!std.mem.eql(u8, def.name, bound.text)) continue;
        const refs = explorer.resolveCallees(def.path, def.line, def.line_end, arena, 64) catch &.{};
        if (refs.len == 64) capped = true;
        for (refs) |ref| {
            const key = ref.name;
            if (seen.contains(key)) continue;
            try seen.put(key, {});
            try callees.append(arena, .{
                .name = ref.name,
                .kind = @tagName(ref.kind),
                .path = ref.path,
                .line = ref.line,
            });
        }
        inspected += 1;
        if (inspected >= 4) break;
    }
    std.mem.sort(CalleeItem, callees.items, {}, struct {
        fn lessThan(_: void, a: CalleeItem, b: CalleeItem) bool {
            const name_order = std.mem.order(u8, a.name, b.name);
            if (name_order != .eq) return name_order == .lt;
            const path_order = std.mem.order(u8, a.path, b.path);
            if (path_order != .eq) return path_order == .lt;
            return a.line < b.line;
        }
    }.lessThan);
    return .{ .callees = callees.items, .total = callees.items.len, .capped = capped };
}

fn stripTrailingCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn isDefinitionLine(defs: []const DefinitionItem, path: []const u8, line_num: u32) bool {
    for (defs) |def| {
        if (def.line == line_num and std.mem.eql(u8, def.path, path)) return true;
    }
    return false;
}

const LineReferenceKind = enum { none, call, comment_string, type_position };

fn classifyFileLineReference(
    explorer: *Explorer,
    arena: std.mem.Allocator,
    path: []const u8,
    line_num: u32,
    fallback_line: []const u8,
    target: []const u8,
    in_enum_scope: bool,
) LineReferenceKind {
    const content = (explorer.getContent(path, arena) catch null) orelse return classifyLineReference(fallback_line, target, false, in_enum_scope);
    var current_line: u32 = 0;
    var block_comment_active = false;
    var enum_body_depth: usize = 0;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |raw_line| {
        current_line += 1;
        const line = stripTrailingCr(raw_line);
        if (current_line == line_num) {
            const lexical_enum_scope = enum_body_depth > 0 or (lineLooksLikeEnumVariantDeclaration(line, target) and lineInsideEnumBody(content, line_num));
            return classifyLineReference(line, target, block_comment_active, in_enum_scope or lexical_enum_scope);
        }
        block_comment_active = blockCommentStateAfterLine(line, block_comment_active);
        enum_body_depth = enumBodyDepthAfterLine(line, enum_body_depth);
    }
    return classifyLineReference(fallback_line, target, false, in_enum_scope);
}

fn classifyLineReference(line: []const u8, target: []const u8, initial_block_comment: bool, in_enum_scope: bool) LineReferenceKind {
    if (lineLooksLikeBracedVariantDeclaration(line, target)) return .type_position;
    if (in_enum_scope and lineLooksLikeEnumVariantDeclaration(line, target)) return .type_position;

    var saw_comment_string = false;
    var saw_type_position = false;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, pos, target)) |idx| {
        const end = idx + target.len;
        pos = end;
        if (!isWholeWordAt(line, target, idx)) continue;
        if (occurrenceIsCommentOrString(line, idx, initial_block_comment)) {
            saw_comment_string = true;
            continue;
        }
        if (occurrenceIsTypePosition(line, target, idx, end, in_enum_scope)) {
            saw_type_position = true;
            continue;
        }
        return .call;
    }
    if (saw_comment_string) return .comment_string;
    if (saw_type_position) return .type_position;
    return .none;
}

fn lineLooksLikeBracedVariantDeclaration(line: []const u8, target: []const u8) bool {
    if (target.len == 0 or !std.ascii.isUpper(target[0])) return false;
    var start: usize = 0;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) : (start += 1) {}
    if (start + target.len > line.len) return false;
    if (!std.mem.eql(u8, line[start .. start + target.len], target)) return false;
    var right = start + target.len;
    if (right < line.len and shared.isContextIdentCont(line[right])) return false;
    while (right < line.len and (line[right] == ' ' or line[right] == '\t')) : (right += 1) {}
    return right < line.len and line[right] == '{';
}

fn lineLooksLikeEnumVariantDeclaration(line: []const u8, target: []const u8) bool {
    if (target.len == 0 or !std.ascii.isUpper(target[0])) return false;
    var start: usize = 0;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) : (start += 1) {}
    if (start + target.len > line.len) return false;
    if (!std.mem.eql(u8, line[start .. start + target.len], target)) return false;
    var right = start + target.len;
    if (right < line.len and shared.isContextIdentCont(line[right])) return false;
    while (right < line.len and (line[right] == ' ' or line[right] == '\t')) : (right += 1) {}
    if (right >= line.len) return true;
    return line[right] == '(' or line[right] == '{' or line[right] == ',' or line[right] == '=';
}

fn isWholeWordAt(line: []const u8, target: []const u8, idx: usize) bool {
    if (idx > 0 and shared.isContextIdentCont(line[idx - 1])) return false;
    const end = idx + target.len;
    if (end < line.len and shared.isContextIdentCont(line[end])) return false;
    return true;
}

fn occurrenceIsCommentOrString(line: []const u8, idx: usize, initial_block_comment: bool) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!initial_block_comment and (std.mem.startsWith(u8, trimmed, "//") or
        std.mem.startsWith(u8, trimmed, "///") or
        std.mem.startsWith(u8, trimmed, "//!") or
        std.mem.startsWith(u8, trimmed, "#") or
        std.mem.startsWith(u8, trimmed, "--")))
    {
        return true;
    }

    var quote: ?u8 = null;
    var escaped = false;
    var block_comment = initial_block_comment;
    var i: usize = 0;
    while (i < idx and i < line.len) : (i += 1) {
        const c = line[i];
        if (block_comment) {
            if (c == '*' and i + 1 < line.len and line[i + 1] == '/') {
                block_comment = false;
                i += 1;
            }
            continue;
        }
        if (quote) |q| {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == q) {
                quote = null;
            }
            continue;
        }
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') return true;
        if (c == '#' or (c == '-' and i + 1 < line.len and line[i + 1] == '-')) return true;
        if (c == '/' and i + 1 < line.len and line[i + 1] == '*') {
            block_comment = true;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') quote = c;
    }
    return quote != null or block_comment;
}

fn blockCommentStateAfterLine(line: []const u8, initial_block_comment: bool) bool {
    var quote: ?u8 = null;
    var escaped = false;
    var block_comment = initial_block_comment;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (block_comment) {
            if (c == '*' and i + 1 < line.len and line[i + 1] == '/') {
                block_comment = false;
                i += 1;
            }
            continue;
        }
        if (quote) |q| {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == q) {
                quote = null;
            }
            continue;
        }
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') break;
        if (c == '#' or (c == '-' and i + 1 < line.len and line[i + 1] == '-')) break;
        if (c == '/' and i + 1 < line.len and line[i + 1] == '*') {
            block_comment = true;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') quote = c;
    }
    return block_comment;
}

fn enumBodyDepthAfterLine(line: []const u8, initial_depth: usize) usize {
    var depth = initial_depth;
    var quote: ?u8 = null;
    var escaped = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote) |q| {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == q) {
                quote = null;
            }
            continue;
        }
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') break;
        if (c == '"' or c == '\'' or c == '`') {
            quote = c;
            continue;
        }
        if (c == '{') {
            if (depth > 0 or containsKeyword(line[0..i], "enum")) depth += 1;
        } else if (c == '}') {
            if (depth > 0) depth -= 1;
        }
    }
    return depth;
}

fn lineInsideEnumBody(content: []const u8, target_line: u32) bool {
    var depth: usize = 0;
    var current_line: u32 = 0;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |raw_line| {
        current_line += 1;
        if (current_line >= target_line) return depth > 0;
        depth = enumBodyDepthAfterLine(stripTrailingCr(raw_line), depth);
    }
    return false;
}

fn occurrenceIsTypePosition(line: []const u8, target: []const u8, start: usize, end: usize, in_enum_scope: bool) bool {
    var left = start;
    while (left > 0 and (line[left - 1] == ' ' or line[left - 1] == '\t')) : (left -= 1) {}

    var right = end;
    while (right < line.len and (line[right] == ' ' or line[right] == '\t')) : (right += 1) {}
    const followed_by_call = right < line.len and line[right] == '(';

    if (left >= 2 and line[left - 1] == ':' and line[left - 2] == ':') {
        if (followed_by_call and qualifiedCallLooksLikePattern(line, right)) return true;
        if (followed_by_call) return false;
        if (target.len > 0 and std.ascii.isUpper(target[0])) return true;
        return true;
    }

    if (right + 1 < line.len and line[right] == ':' and line[right + 1] == ':') {
        var member_end = right + 2;
        while (member_end < line.len and shared.isContextIdentCont(line[member_end])) : (member_end += 1) {}
        while (member_end < line.len and (line[member_end] == ' ' or line[member_end] == '\t')) : (member_end += 1) {}
        return !(member_end < line.len and line[member_end] == '(');
    }

    if (in_enum_scope and occurrenceIsEnumVariantDeclaration(line, target, left, right)) return true;
    if (occurrenceIsSameLineEnumVariantDeclaration(line, left)) return true;

    if (precededByTypeKeyword(line, left)) return true;

    if (left > 0) {
        const prev = line[left - 1];
        if (prev == ':' or prev == '<' or prev == '|') return true;
        if (prev == '>' and left >= 2 and line[left - 2] == '-') return true;
        if (prev == ',' and hasGenericOpenBefore(line[0 .. left - 1])) return true;
    }

    var scan = left;
    while (scan > 0) {
        scan -= 1;
        const c = line[scan];
        if (c == ':' or c == '<') return true;
        if (c == '>' and scan > 0 and line[scan - 1] == '-') return true;
        if (c == '=' or c == ';' or c == '{' or c == '}') break;
    }

    if (right < line.len) {
        const next = line[right];
        if (next == ',' or next == ')' or next == '>' or next == ';') return true;
    }
    return false;
}

fn qualifiedCallLooksLikePattern(line: []const u8, paren: usize) bool {
    const close = matchingParen(line, paren) orelse return false;
    var right = close + 1;
    while (right < line.len and (line[right] == ' ' or line[right] == '\t' or line[right] == ')')) : (right += 1) {}
    return right + 1 < line.len and line[right] == '=' and line[right + 1] == '>';
}

fn matchingParen(line: []const u8, paren: usize) ?usize {
    if (paren >= line.len or line[paren] != '(') return null;
    var depth: usize = 0;
    var i = paren;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn precededByTypeKeyword(line: []const u8, left: usize) bool {
    var end = left;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}
    var start = end;
    while (start > 0 and shared.isContextIdentCont(line[start - 1])) : (start -= 1) {}
    if (start == end) return false;
    const word = line[start..end];
    const keywords = [_][]const u8{
        "type", "interface", "class", "struct", "enum", "trait", "impl", "alias",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

fn occurrenceIsEnumVariantDeclaration(line: []const u8, target: []const u8, left: usize, right: usize) bool {
    if (target.len == 0 or !std.ascii.isUpper(target[0])) return false;
    var first: usize = 0;
    while (first < line.len and (line[first] == ' ' or line[first] == '\t')) : (first += 1) {}
    if (first != left) return false;
    if (right >= line.len) return true;
    return line[right] == '(' or line[right] == '{' or line[right] == ',' or line[right] == '=';
}

fn occurrenceIsSameLineEnumVariantDeclaration(line: []const u8, left: usize) bool {
    const prefix = line[0..left];
    const brace = std.mem.lastIndexOfScalar(u8, prefix, '{') orelse return false;
    return containsKeyword(prefix[0..brace], "enum");
}

fn containsKeyword(text: []const u8, keyword: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, keyword)) |idx| {
        pos = idx + keyword.len;
        if (isWholeWordAt(text, keyword, idx)) return true;
    }
    return false;
}

fn hasGenericOpenBefore(prefix: []const u8) bool {
    var depth: usize = 0;
    var i = prefix.len;
    while (i > 0) {
        i -= 1;
        switch (prefix[i]) {
            '>' => depth += 1,
            '<' => {
                if (depth == 0) return true;
                depth -= 1;
            },
            ';', '=', '{', '}' => return false,
            else => {},
        }
    }
    return false;
}

fn scopeEnclosesLine(scope: Explorer.EnclosingScope, line_num: u32) bool {
    return scope.line_start <= line_num and line_num <= scope.line_end;
}

fn scopeKindIsImportTypeOnly(kind: explore_mod.SymbolKind) bool {
    return kind == .import or kind == .type_alias;
}

fn sortCallers(callers: []CallerItem) void {
    std.mem.sort(CallerItem, callers, {}, struct {
        fn lessThan(_: void, a: CallerItem, b: CallerItem) bool {
            const order = std.mem.order(u8, a.path, b.path);
            if (order != .eq) return order == .lt;
            if (a.line != b.line) return a.line < b.line;
            return std.mem.order(u8, a.text, b.text) == .lt;
        }
    }.lessThan);
}

fn collectBlastRadius(explorer: *Explorer, arena: std.mem.Allocator, target: []const u8) !BlastResult {
    var defs = std.ArrayList(DefinitionItem).empty;
    var target_file: ?[]const u8 = null;

    if (looksPathLike(target)) {
        if ((explorer.getContent(target, arena) catch null) != null) {
            target_file = target;
        }
    }

    const found_defs = if (target_file == null) explorer.findAllSymbols(target, arena) catch &.{} else &.{};
    for (found_defs) |d| {
        if (target_file == null) target_file = d.path;
        const snippet = extractSymbolSnippet(explorer, arena, d.path, d.symbol.line_start, d.symbol.line_end, false);
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

    const callers: ?CallersResult = if (isIdentifierTarget(target))
        gatherCallersExact(explorer, arena, target, callers_candidate_budget) catch null
    else
        null;

    const dependents = if (target_file) |path|
        explorer.getTransitiveDependentsWithDepth(path, arena, 3) catch &.{}
    else
        &.{};

    var counts = try arena.alloc(usize, 4);
    @memset(counts, 0);
    for (dependents) |dep| {
        if (dep.depth < counts.len) counts[dep.depth] += 1;
    }

    return .{
        .target_file = target_file,
        .target_defs = defs.items,
        .callers = callers,
        .dependents = dependents,
        .total_dependents = dependents.len,
        .depth_counts = counts,
    };
}

fn renderBlastText(
    alloc: std.mem.Allocator,
    route: Route,
    result: BlastResult,
    max_files: u32,
) !TextRender {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var coverage = std.ArrayList(render_mod.CoverageRow).empty;
    errdefer coverage.deinit(alloc);
    var limits = std.ArrayList([]const u8).empty;
    errdefer limits.deinit(alloc);
    errdefer freeLimitItems(alloc, limits.items);

    render_mod.appendRoute(alloc, &out, route.rationale, if (route.state == .ambiguous and route.runner_up != null) @tagName(route.runner_up.?) else null);
    const w = cio.listWriter(&out, alloc);

    w.writeAll("\n## TARGET\n") catch {};
    if (result.target_file) |path| {
        w.print("- file {s}\n", .{path}) catch {};
    } else {
        w.writeAll("- file unknown\n") catch {};
    }
    if (result.target_defs.len > 0) {
        const primary = result.target_defs[0];
        w.print("- primary {s} ({s}) {s}:{d}\n", .{ primary.name, primary.kind, primary.path, primary.line }) catch {};
        if (result.target_defs.len > 1) {
            try appendLimitFmt(alloc, &limits, "target name is ambiguous across {d} exact definitions; ripple uses the first definition's file", .{result.target_defs.len});
        }
    }

    if (result.callers) |callers| {
        const shown = @min(callers.callers.len, @as(usize, max_files) * 3);
        render_mod.appendSectionHeader(alloc, &out, "DIRECT CALLERS", shown, callers.callers.len);
        for (callers.callers[0..shown]) |caller| {
            w.print("- {s}:{d}: {s}\n", .{ caller.path, caller.line, caller.text }) catch {};
        }
        try coverage.append(alloc, .{ .section = "direct-callers", .shown = shown, .total = callers.callers.len });
        if (callers.comment_string_rejects > 0) {
            try appendLimitFmt(alloc, &limits, "excluded {d} comment/string matches from direct caller totals", .{callers.comment_string_rejects});
        }
        if (callers.type_position_rejects > 0) {
            try appendLimitFmt(alloc, &limits, "excluded {d} type-position references from direct caller totals", .{callers.type_position_rejects});
        }
    }

    w.writeAll("\n## RIPPLE\n") catch {};
    const depth1_total = if (result.depth_counts.len > 1) result.depth_counts[1] else 0;
    const depth1_cap = @as(usize, max_files) * 2;
    const depth1_shown = @min(depth1_total, depth1_cap);
    var shown_d1: usize = 0;
    if (result.depth_counts.len > 1) w.print("- depth 1: {d} files\n", .{result.depth_counts[1]}) catch {};
    if (result.depth_counts.len > 2) w.print("- depth 2: {d} files\n", .{result.depth_counts[2]}) catch {};
    if (result.depth_counts.len > 3) w.print("- depth 3: {d} files\n", .{result.depth_counts[3]}) catch {};
    for (result.dependents) |dep| {
        if (dep.depth != 1) continue;
        if (shown_d1 >= depth1_cap) break;
        w.print("- {s}\n", .{dep.path}) catch {};
        shown_d1 += 1;
    }
    if (depth1_total > 0) {
        try coverage.append(alloc, .{ .section = "dependents-d1", .shown = depth1_shown, .total = depth1_total });
    }

    try appendLimitOwned(alloc, &limits, "ripple follows the import graph (max depth 3); call-graph edges beyond direct callers are not traversed");
    render_mod.appendCoverage(alloc, &out, coverage.items);
    render_mod.appendLimits(alloc, &out, limits.items);
    return .{
        .text = try out.toOwnedSlice(alloc),
        .coverage = try coverage.toOwnedSlice(alloc),
        .limits = try limits.toOwnedSlice(alloc),
    };
}

fn renderOverviewText(
    alloc: std.mem.Allocator,
    route: Route,
    result: OverviewResult,
    max_files: usize,
    max_defs: usize,
    max_sites_per_file: usize,
    max_callers: usize,
    max_callees: usize,
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

    const defs_total = @max(result.defs_total, result.defs.len);
    const defs_shown = @min(result.defs.len, max_defs);
    if (result.defs.len > 0) {
        render_mod.appendSectionHeader(alloc, &out, "DEFS", defs_shown, defs_total);
        for (result.defs[0..defs_shown]) |def| {
            w.print("- {s} ({s}) {s}:{d}\n", .{ def.name, def.kind, def.path, def.line }) catch {};
            if (def.detail) |detail| {
                w.print("  signature: {s}\n", .{detailFirstLine(detail)}) catch {};
            }
            if (def.snippet) |snippet| {
                w.print("```text\n{s}```\n", .{snippet}) catch {};
            }
        }
        try coverage.append(alloc, .{ .section = "defs", .shown = defs_shown, .total = defs_total });
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

    const callers_total = @max(result.callers_total, result.callers.len);
    const callers_shown = @min(result.callers.len, max_callers);
    if (result.callers.len > 0 or callers_total > 0) {
        render_mod.appendSectionHeader(alloc, &out, "CALLERS", callers_shown, callers_total);
        for (result.callers[0..callers_shown]) |caller| {
            if (caller.scope_name) |scope_name| {
                w.print("- {s}:{d}: {s}  [in {s} ({s}, L{d}-L{d})]\n", .{
                    caller.path, caller.line, caller.text, scope_name, @tagName(caller.scope_kind.?), caller.scope_start, caller.scope_end,
                }) catch {};
            } else {
                w.print("- {s}:{d}: {s}\n", .{ caller.path, caller.line, caller.text }) catch {};
            }
        }
        try coverage.append(alloc, .{ .section = "callers", .shown = callers_shown, .total = callers_total });
    }

    const callees_total = @max(result.callees_total, result.callees.len);
    const callees_shown = @min(result.callees.len, max_callees);
    if (result.callees.len > 0 or callees_total > 0) {
        render_mod.appendSectionHeader(alloc, &out, "CALLEES", callees_shown, callees_total);
        for (result.callees[0..callees_shown]) |callee| {
            w.print("- {s} ({s}) {s}:{d}\n", .{ callee.name, callee.kind, callee.path, callee.line }) catch {};
        }
        try coverage.append(alloc, .{ .section = "callees", .shown = callees_shown, .total = callees_total });
    }

    render_mod.appendCoverage(alloc, &out, coverage.items);
    var limits = std.ArrayList([]const u8).empty;
    errdefer limits.deinit(alloc);
    errdefer freeLimitItems(alloc, limits.items);
    try appendLimitOwned(alloc, &limits, "tests and docs are deprioritized during overview ranking");
    if (result.included_test_files_for_recall > 0) {
        try appendLimitFmt(alloc, &limits, "only test-like files matched; included {d} for recall", .{result.included_test_files_for_recall});
    } else if (result.excluded_test_files > 0) {
        try appendLimitFmt(alloc, &limits, "{d} test-like files excluded from FILES/SITES", .{result.excluded_test_files});
    }
    if (result.def_ambiguity_count > 1) {
        try appendLimitFmt(alloc, &limits, "multiple exact definitions share this name ({d})", .{result.def_ambiguity_count});
    }
    if (defs_total > result.defs.len) {
        try appendLimitOwned(alloc, &limits, "defs sampled at 3 per keyword; run define <name> for the full list");
    }
    if (result.callers_list_capped) {
        try appendLimitFmt(alloc, &limits, "overview callers list capped at {d} of {d}", .{ result.callers.len, callers_total });
    }
    if (result.callers_gather_capped) {
        try appendLimitOwned(alloc, &limits, "overview caller gather capped before all candidate lines; totals are a lower bound");
    }
    if (result.callees_capped) {
        try appendLimitOwned(alloc, &limits, "overview callees capped at 64 per inspected definition");
    }
    if (result.caller_comment_string_rejects > 0) {
        try appendLimitFmt(alloc, &limits, "excluded {d} comment/string matches from caller totals", .{result.caller_comment_string_rejects});
    }
    if (result.caller_type_position_rejects > 0) {
        try appendLimitFmt(alloc, &limits, "excluded {d} type-position references from caller totals", .{result.caller_type_position_rejects});
    }
    render_mod.appendLimits(alloc, &out, limits.items);
    return .{
        .text = try out.toOwnedSlice(alloc),
        .coverage = try coverage.toOwnedSlice(alloc),
        .limits = try limits.toOwnedSlice(alloc),
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
                w.print("  signature: {s}\n", .{detailFirstLine(detail)}) catch {};
            }
            if (def.snippet) |snippet| {
                w.print("```text\n{s}```\n", .{snippet}) catch {};
            }
        }
        try coverage.append(alloc, .{ .section = "defs", .shown = defs_shown, .total = result.defs.len });
    }

    if (result.fallback_sites.len > 0) {
        const shown = @min(result.fallback_sites.len, @as(usize, max_files) * 2);
        const sites_total = @max(result.sites_total, result.fallback_sites.len);
        render_mod.appendSectionHeader(alloc, &out, "SITES", shown, sites_total);
        for (result.fallback_sites[0..shown]) |site| {
            w.print("- {s}:{d}: {s}\n", .{ site.path, site.line, site.text }) catch {};
        }
        try coverage.append(alloc, .{ .section = "sites", .shown = shown, .total = sites_total });
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
    errdefer limits.deinit(alloc);
    errdefer freeLimitItems(alloc, limits.items);
    if (result.exact_defs > 1) {
        try appendLimitFmt(alloc, &limits, "multiple exact definitions share this name ({d})", .{result.exact_defs});
    }
    if (result.defs.len == 0 and result.fallback_sites.len > 0) {
        try appendLimitOwned(alloc, &limits, "no indexed definition found; showing fallback usage hits");
    }
    if (result.sites_lower_bound) {
        try appendLimitOwned(alloc, &limits, "sites total is a lower bound; search fallback capped at 20");
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
    errdefer freeLimitItems(alloc, limits.items);

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
            try appendLimitFmt(alloc, &limits, "name-ambiguous across {d} exact definitions", .{result.defs.len});
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
    try appendLimitFmt(alloc, &limits, "filtered {d} definition hits, {d} substring-only hits, and {d} non-call-site matches", .{
        result.def_rejects,
        result.substring_rejects,
        result.non_call_site_rejects,
    });
    if (result.import_type_rejects > 0) {
        try appendLimitFmt(alloc, &limits, "excluded {d} import/type-only matches", .{result.import_type_rejects});
    }
    if (result.comment_string_rejects > 0) {
        try appendLimitFmt(alloc, &limits, "excluded {d} comment/string matches", .{result.comment_string_rejects});
    }
    if (result.type_position_rejects > 0) {
        try appendLimitFmt(alloc, &limits, "excluded {d} type-position references", .{result.type_position_rejects});
    }
    if (result.stale_line_rejects > 0) {
        try appendLimitFmt(alloc, &limits, "skipped {d} stale-index candidate lines past EOF", .{result.stale_line_rejects});
    }
    if (result.case_variant_rejects > 0) {
        try appendLimitFmt(alloc, &limits, "skipped {d} case-variant-only lines (exact-case whole-word match required)", .{result.case_variant_rejects});
    }
    if (result.gather_capped) {
        try appendLimitFmt(alloc, &limits, "gather capped at {d} of {d} candidate lines; totals are a lower bound", .{ result.callers.len + result.def_rejects + result.substring_rejects + result.non_call_site_rejects + result.case_variant_rejects + result.import_type_rejects + result.comment_string_rejects + result.type_position_rejects + result.stale_line_rejects, result.candidate_lines });
    }
    if (result.file_count > 0) {
        try appendLimitFmt(alloc, &limits, "callers span {d} files", .{result.file_count});
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
        if (!isIdentifierTarget(target.?.text)) {
            route.intent = .overview;
            route.state = .fallback;
            route.confidence = .weak;
            route.runner_up = .callers;
            route.rationale = std.fmt.allocPrint(alloc, "overview target={s} confidence=weak state=fallback", .{target.?.text}) catch route.rationale;
        }
    } else if (route.intent == .blast_radius and target != null) {
        const defs = explorer.findAllSymbols(target.?.text, alloc) catch &.{};
        const known_file = looksPathLike(target.?.text) and ((explorer.getContent(target.?.text, alloc) catch null) != null);
        if (defs.len == 0 and !known_file) {
            route.intent = .overview;
            route.state = .fallback;
            route.confidence = .weak;
            route.runner_up = .blast_radius;
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
        if (containsBoundedPhrase(normalized, phrase.phrase)) total += phrase.weight;
    }
    return total;
}

fn containsBoundedPhrase(haystack: []const u8, phrase: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, phrase)) |idx| {
        const end = idx + phrase.len;
        const before_ok = idx == 0 or !shared.isContextIdentCont(haystack[idx - 1]);
        const after_ok = end >= haystack.len or !shared.isContextIdentCont(haystack[end]);
        if (before_ok and after_ok) return true;
        pos = idx + 1;
    }
    return false;
}

fn blastRadiusPhraseScore(normalized: []const u8) i32 {
    return phraseScore(normalized, &.{
        .{ .phrase = "blast radius", .weight = 3 },
        .{ .phrase = "impact of", .weight = 3 },
        .{ .phrase = "what breaks", .weight = 3 },
        .{ .phrase = "affected by", .weight = 3 },
        .{ .phrase = "ripple", .weight = 3 },
    });
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

fn isIdentifierTarget(target: []const u8) bool {
    if (target.len == 0 or !shared.isContextIdentStart(target[0])) return false;
    for (target) |c| {
        if (!shared.isContextIdentCont(c)) return false;
    }
    return true;
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

fn bestAnchorSkippingBlastScaffold(anchors: []const Anchor) ?Anchor {
    var best: ?Anchor = null;
    for (anchors) |anchor| {
        if (anchor.kind == .word and isBlastScaffoldAnchor(anchor.text)) continue;
        if (best == null or anchor.salience > best.?.salience or
            (anchor.salience == best.?.salience and anchor.text.len > best.?.text.len))
        {
            best = anchor;
        }
    }
    return best;
}

fn isBlastScaffoldAnchor(tok: []const u8) bool {
    const scaffolding = [_][]const u8{ "blast", "radius", "impact", "breaks", "affected", "ripple", "change", "changes", "touch", "touches" };
    for (scaffolding) |word| {
        if (std.ascii.eqlIgnoreCase(tok, word)) return true;
    }
    return false;
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
        "what",         "how",       "does",           "the",       "is",
        "are",          "and",       "when",           "why",       "can",
        "could",        "should",    "would",          "will",      "you",
        "your",         "our",       "they",           "them",      "their",
        "then",         "than",      "not",            "but",       "all",
        "any",          "was",       "were",           "has",       "have",
        "had",          "its",       "did",            "work",      "find",
        "show",         "where",     "who",            "calls",     "call",
        "called",       "used",      "uses",           "of",        "this",
        "code",         "here",      "with",           "from",      "into",
        "that",         "like",      "look",           "through",   "definition",
        "defined",      "declared",  "implementation", "signature", "overview",
        "architecture", "flow",      "explain",        "walk",      "me",
        "references",   "reference", "usages",         "usage",     "invoked",
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
    if (shared.isTestLikePath(path)) {
        penalty += 4;
    }
    if (explore_mod.isDocLanguage(lang)) penalty += 3;
    if (std.mem.endsWith(u8, path, ".pb.go") or
        std.mem.endsWith(u8, path, ".pb.rs") or
        std.mem.indexOf(u8, path, "_generated.") != null or
        std.mem.indexOf(u8, path, ".generated.") != null or
        std.mem.endsWith(u8, path, ".g.dart") or
        std.mem.indexOf(u8, path, "/gen/") != null or
        std.mem.indexOf(u8, path, "/generated/") != null)
    {
        penalty += 5;
    }
    if (std.mem.endsWith(u8, path, ".lock")) {
        penalty += 6;
    }
    if (std.mem.indexOf(u8, path, "/vendor/") != null or
        std.mem.indexOf(u8, path, "/third_party/") != null or
        std.mem.endsWith(u8, path, ".min.js"))
    {
        penalty += 5;
    }
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

fn detailFirstLine(detail: []const u8) []const u8 {
    const first = if (std.mem.indexOfScalar(u8, detail, '\n')) |idx| detail[0..idx] else detail;
    var end = first.len;
    while (end > 0 and (first[end - 1] == ' ' or first[end - 1] == '\t' or first[end - 1] == '\r')) {
        end -= 1;
    }
    return first[0..end];
}

pub fn detailFirstLineForTest(detail: []const u8) []const u8 {
    return detailFirstLine(detail);
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
    const extracted = explore_mod.extractLines(content, line, line, false, true, lang, alloc) catch return null;
    return std.mem.trimEnd(u8, extracted, "\r\n");
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

fn renderSimpleError(alloc: std.mem.Allocator, message: []const u8) !RenderResult {
    const text = try alloc.dupe(u8, message);
    return .{
        .text = text,
        .full_text = text,
        .coverage = &.{},
        .limits = &.{},
    };
}

fn appendLimitOwned(alloc: std.mem.Allocator, limits: *std.ArrayList([]const u8), text: []const u8) !void {
    const owned = try alloc.dupe(u8, text);
    errdefer alloc.free(owned);
    try limits.append(alloc, owned);
}

fn appendLimitFmt(
    alloc: std.mem.Allocator,
    limits: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const owned = try std.fmt.allocPrint(alloc, fmt, args);
    errdefer alloc.free(owned);
    try limits.append(alloc, owned);
}

fn freeLimitItems(alloc: std.mem.Allocator, limits: []const []const u8) void {
    for (limits) |limit| alloc.free(limit);
}

fn applyMinimalMode(alloc: std.mem.Allocator, rendered: *RenderResult) void {
    const old_text = rendered.text;
    const old_full_text = rendered.full_text;
    const full_shared_text = old_full_text.ptr == old_text.ptr and old_full_text.len == old_text.len;

    if (minimalText(alloc, old_text)) |new_text| {
        rendered.text = new_text;
        alloc.free(old_text);
    } else |_| {}

    if (full_shared_text) {
        rendered.full_text = rendered.text;
        return;
    }

    if (minimalText(alloc, old_full_text)) |new_full_text| {
        rendered.full_text = new_full_text;
        alloc.free(old_full_text);
    } else |_| {}
}

fn minimalText(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var skip_section = false;
    var skip_stages = false;
    var skip_fence = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (skip_fence) {
            if (std.mem.startsWith(u8, line, "```")) skip_fence = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "```")) {
            skip_fence = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "  signature:")) continue;
        if (std.mem.startsWith(u8, line, "## ROUTE") or std.mem.startsWith(u8, line, "## ALTS")) continue;
        if (std.mem.eql(u8, line, "--- stages ---")) {
            skip_stages = true;
            continue;
        }
        if (skip_stages) {
            if (!std.mem.startsWith(u8, line, "## ") and line.len > 0) continue;
            skip_stages = false;
        }
        if (std.mem.startsWith(u8, line, "## KEYWORDS") or std.mem.startsWith(u8, line, "## LIMITS")) {
            skip_section = true;
            continue;
        }
        if (skip_section) {
            if (!std.mem.startsWith(u8, line, "## ")) continue;
            skip_section = false;
        }
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

fn persistArtifact(
    io: std.Io,
    alloc: std.mem.Allocator,
    data_dir: []const u8,
    req: EffectiveRequest,
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
    req: CompassRequest,
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
    const stored_intent = jsonString(manifest.object, "intent") orelse "";
    const stored_mode = jsonString(manifest.object, "mode") orelse "summary";
    if (req.intent) |intent| {
        if (!std.mem.eql(u8, stored_intent, @tagName(intent))) {
            const w = cio.listWriter(out, alloc);
            w.print("overflow request mismatch: stored intent={s}", .{stored_intent}) catch {};
            return;
        }
    }
    if (req.mode_explicit and !std.mem.eql(u8, stored_mode, @tagName(req.mode))) {
        const w = cio.listWriter(out, alloc);
        w.print("overflow request mismatch: stored mode={s}", .{stored_mode}) catch {};
        return;
    }

    const full_text = jsonString(root, "full_text") orelse {
        out.appendSlice(alloc, "error: overflow artifact is corrupt") catch {};
        return;
    };
    switch (req.format) {
        .text => out.appendSlice(alloc, full_text) catch {},
        .json => {
            const route_line = jsonString(root, "route_line") orelse "";
            const alt_line = jsonNullableString(root, "alt_line");
            const coverage = parseCoverageArray(alloc, root.get("coverage")) catch &.{};
            defer alloc.free(coverage);
            defer freeParsedCoverageRows(alloc, coverage);
            const limits = parseStringArray(alloc, root.get("limits")) catch &.{};
            defer alloc.free(limits);
            defer freeLimitItems(alloc, limits);
            appendJsonResponse(alloc, out, route_line, alt_line, coverage, limits, full_text, null) catch {
                out.appendSlice(alloc, "error: compass json render failed") catch {};
            };
        },
    }
}

fn makeReqId(alloc: std.mem.Allocator, req: EffectiveRequest, generation: Generation) ![]const u8 {
    const intent = @tagName(req.intent);
    const target = req.target orelse "";
    const basis = try std.fmt.allocPrint(alloc, "{s}|{s}|{s}|{s}|{s}|{d}|{d}|{d}|{d}", .{
        intent,
        target,
        req.task,
        @tagName(req.state),
        @tagName(req.mode),
        @intFromBool(req.want_body),
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
    req: EffectiveRequest,
    generation: Generation,
    artifact: StoredArtifact,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const w = cio.listWriter(&out, alloc);
    w.writeAll("{\"manifest\":{") catch return error.OutOfMemory;
    w.print("\"intent\":\"{s}\",\"state\":\"{s}\",\"mode\":\"{s}\",\"task_hash\":{d},\"want_body\":{s},\"max_files\":{d},\"seq\":{d},\"files\":{d}", .{
        @tagName(req.intent),
        @tagName(req.state),
        @tagName(req.mode),
        std.hash.Wyhash.hash(0, req.task),
        if (req.want_body) "true" else "false",
        req.max_files,
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
    errdefer {
        freeParsedCoverageRows(alloc, rows.items);
        rows.deinit(alloc);
    }
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
    errdefer {
        freeLimitItems(alloc, rows.items);
        rows.deinit(alloc);
    }
    for (val.array.items) |item| {
        if (item != .string) continue;
        try appendLimitOwned(alloc, &rows, item.string);
    }
    return rows.toOwnedSlice(alloc);
}

fn freeParsedCoverageRows(alloc: std.mem.Allocator, rows: []const render_mod.CoverageRow) void {
    for (rows) |row| alloc.free(row.section);
}
