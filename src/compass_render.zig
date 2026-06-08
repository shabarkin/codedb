const std = @import("std");
const cio = @import("cio.zig");

pub const CoverageRow = struct {
    section: []const u8,
    shown: usize,
    total: usize,
};

pub const StageRow = struct {
    name: []const u8,
    count: usize,
};

pub fn appendRoute(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    route_line: []const u8,
    alt_line: ?[]const u8,
) void {
    const w = cio.listWriter(out, alloc);
    w.print("## ROUTE {s}\n", .{route_line}) catch {};
    if (alt_line) |line| {
        w.print("## ALTS {s}\n", .{line}) catch {};
    }
}

pub fn appendStages(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    stages: []const StageRow,
) void {
    if (stages.len == 0) return;
    const w = cio.listWriter(out, alloc);
    w.writeAll("--- stages ---\n") catch {};
    for (stages) |stage| {
        w.print("{s}: {d}\n", .{ stage.name, stage.count }) catch {};
    }
}

pub fn appendSectionHeader(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    title: []const u8,
    shown: usize,
    total: usize,
) void {
    const w = cio.listWriter(out, alloc);
    w.print("\n## {s} showing {d} of {d}\n", .{ title, shown, total }) catch {};
}

pub fn appendCoverage(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    rows: []const CoverageRow,
) void {
    if (rows.len == 0) return;
    const w = cio.listWriter(out, alloc);
    w.writeAll("\n## COVERAGE\n") catch {};
    for (rows) |row| {
        w.print("- {s} showing {d} of {d}\n", .{ row.section, row.shown, row.total }) catch {};
    }
}

pub fn appendLimits(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    limits: []const []const u8,
) void {
    if (limits.len == 0) return;
    const w = cio.listWriter(out, alloc);
    w.writeAll("\n## LIMITS\n") catch {};
    for (limits) |line| {
        w.print("- {s}\n", .{line}) catch {};
    }
}
