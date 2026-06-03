const std = @import("std");
const builtin = @import("builtin");
const cio = @import("cio.zig");
const sty = @import("style.zig");
const release_info = @import("release_info.zig");

const Out = struct {
    file: cio.File,
    alloc: std.mem.Allocator,

    fn p(self: Out, comptime fmt: []const u8, args: anytype) void {
        const str = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        defer self.alloc.free(str);
        self.file.writeAll(str) catch {};
    }
};

const SupersededRelease = struct {
    current: []const u8,
    minimum_target: []const u8,
};

const superseded_releases = [_]SupersededRelease{
    .{ .current = "0.2.58181", .minimum_target = "0.2.5823" },
};

pub fn run(io: std.Io, stdout: cio.File, s: sty.Style, allocator: std.mem.Allocator) void {
    _ = io;
    const out = Out{ .file = stdout, .alloc = allocator };
    out.p(
        "{s}update disabled{s}: codedb is built from source in this tree; rebuild with `zig build` instead of downloading a release binary.\n",
        .{ s.yellow, s.reset },
    );
}

pub fn maybeAutoUpdate(io: std.Io, allocator: std.mem.Allocator) void {
    _ = io;
    _ = allocator;
}

pub fn shouldRunAutoUpdate(now_ms: i64, last_check_ms: ?i64, env_disabled: bool) bool {
    _ = now_ms;
    _ = last_check_ms;
    _ = env_disabled;
    return false;
}

pub fn assetNameForTarget(os_tag: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (os_tag) {
        .macos => switch (arch) {
            .aarch64 => "codedb-darwin-arm64",
            .x86_64 => "codedb-darwin-x86_64",
            else => null,
        },
        .linux => switch (arch) {
            .aarch64 => "codedb-linux-arm64",
            .x86_64 => "codedb-linux-x86_64",
            else => null,
        },
        else => null,
    };
}

pub fn currentAssetName() ?[]const u8 {
    return assetNameForTarget(builtin.os.tag, builtin.cpu.arch);
}

pub fn currentVersion() []const u8 {
    return release_info.semver;
}

pub fn compareVersions(current: []const u8, target: []const u8) !std.math.Order {
    var current_it = std.mem.splitScalar(u8, trimVersionPrefix(current), '.');
    var target_it = std.mem.splitScalar(u8, trimVersionPrefix(target), '.');

    while (true) {
        const current_part = current_it.next();
        const target_part = target_it.next();

        if (current_part == null and target_part == null) return .eq;

        const current_num = if (current_part) |part| try parseVersionPart(part) else 0;
        const target_num = if (target_part) |part| try parseVersionPart(part) else 0;

        if (current_num < target_num) return .lt;
        if (current_num > target_num) return .gt;
    }
}

pub fn compareVersionsForUpdate(current: []const u8, target: []const u8) !std.math.Order {
    const order = try compareVersions(current, target);
    if (order == .gt and try targetSupersedesCurrent(current, target)) return .lt;
    return order;
}

pub fn targetSupersedesCurrent(current: []const u8, target: []const u8) !bool {
    const normalized_current = trimVersionPrefix(current);
    for (superseded_releases) |release| {
        if (!std.mem.eql(u8, normalized_current, release.current)) continue;
        return (try compareVersions(target, release.minimum_target)) != .lt;
    }
    return false;
}

pub fn checksumForBinary(manifest: []const u8, binary_name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        const hash_end = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const hash = line[0..hash_end];
        var name = std.mem.trimStart(u8, line[hash_end..], " \t");
        if (name.len == 0) continue;
        if (name[0] == '*') name = name[1..];
        if (std.mem.eql(u8, name, binary_name)) return hash;
    }

    return null;
}

fn trimVersionPrefix(value: []const u8) []const u8 {
    return std.mem.trimStart(u8, value, "vV");
}

fn parseVersionPart(part: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, part, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidVersion;
    return std.fmt.parseInt(u64, trimmed, 10);
}
