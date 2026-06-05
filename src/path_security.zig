const std = @import("std");
const builtin = @import("builtin");

const max_path_bytes = if (builtin.os.tag == .freestanding) 4096 else std.fs.max_path_bytes;

pub fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (component.len == 0) continue;
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

pub fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn envName(base: []const u8) bool {
    return base.len >= 4 and
        std.ascii.eqlIgnoreCase(base[0..4], ".env") and
        (base.len == 4 or base[4] == '.' or base[4] == '-' or base[4] == '_');
}

pub fn isSensitivePath(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(component, ".ssh")) return true;
        if (std.ascii.eqlIgnoreCase(component, ".gnupg")) return true;
        if (std.ascii.eqlIgnoreCase(component, ".aws")) return true;
        if (envName(component)) return true;
    }

    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| path[sep + 1 ..] else path;
    if (basename.len == 0) return false;
    if (endsWithIgnoreCase(basename, ".env")) return true;

    const sensitive_names = [_][]const u8{
        ".dev.vars",
        ".envrc",
        ".npmrc",
        ".pypirc",
        ".netrc",
        ".pgpass",
        ".htpasswd",
        "application.properties",
        "application.yml",
        "application.yaml",
        "credentials.json",
        "service-account.json",
        "secrets.json",
        "secrets.yaml",
        "secrets.yml",
        "id_rsa",
        "id_ed25519",
    };
    for (sensitive_names) |name| {
        if (std.ascii.eqlIgnoreCase(basename, name)) return true;
    }

    const sensitive_extensions = [_][]const u8{
        ".pem",
        ".key",
        ".p12",
        ".pfx",
        ".jks",
        ".crt",
        ".cer",
        ".der",
        ".crl",
    };
    for (sensitive_extensions) |ext| {
        if (endsWithIgnoreCase(basename, ext)) return true;
    }
    return false;
}

pub fn isUnderRoot(real_path: []const u8, real_root: []const u8) bool {
    if (real_root.len == 0) return false;
    if (!std.mem.startsWith(u8, real_path, real_root)) return false;
    return real_path.len == real_root.len or real_path[real_root.len] == '/';
}

pub fn relativeFromRealRoot(real_path: []const u8, real_root: []const u8) ?[]const u8 {
    if (!isUnderRoot(real_path, real_root)) return null;
    if (real_path.len == real_root.len) return "";
    return std.mem.trimStart(u8, real_path[real_root.len..], "/");
}

pub fn realPathWithinRoot(
    io: std.Io,
    dir: std.Io.Dir,
    real_root: []const u8,
    path: []const u8,
    out_buffer: []u8,
) ![]const u8 {
    if (!isPathSafe(path) or isSensitivePath(path)) return error.AccessDenied;
    if (real_root.len == 0) return error.AccessDenied;
    const n = try dir.realPathFile(io, path, out_buffer);
    const real_path = out_buffer[0..n];
    if (!isUnderRoot(real_path, real_root)) return error.AccessDenied;
    if (relativeFromRealRoot(real_path, real_root)) |real_rel| {
        if (isSensitivePath(real_rel)) return error.AccessDenied;
    } else {
        return error.AccessDenied;
    }
    return real_path;
}

pub fn openSafeFile(
    io: std.Io,
    dir: std.Io.Dir,
    real_root: []const u8,
    path: []const u8,
) !std.Io.File {
    var real_buf: [max_path_bytes]u8 = undefined;
    _ = try realPathWithinRoot(io, dir, real_root, path, &real_buf);
    return dir.openFile(io, path, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
}

pub fn statSafeFile(
    io: std.Io,
    dir: std.Io.Dir,
    real_root: []const u8,
    path: []const u8,
) !std.Io.File.Stat {
    var file = try openSafeFile(io, dir, real_root, path);
    defer file.close(io);
    return file.stat(io);
}

pub fn readFileAlloc(
    io: std.Io,
    dir: std.Io.Dir,
    real_root: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,
    limit: std.Io.Limit,
) ![]u8 {
    var file = try openSafeFile(io, dir, real_root, path);
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, limit) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

test "path safety rejects traversal and absolutes" {
    try std.testing.expect(!isPathSafe(""));
    try std.testing.expect(!isPathSafe("/etc/passwd"));
    try std.testing.expect(!isPathSafe("../secret"));
    try std.testing.expect(!isPathSafe("a/../../secret"));
    try std.testing.expect(!isPathSafe("a\\..\\secret"));
    try std.testing.expect(isPathSafe("src/main.zig"));
}

test "sensitive path matching is case-insensitive and precise" {
    try std.testing.expect(isSensitivePath(".env"));
    try std.testing.expect(isSensitivePath(".ENV.production"));
    try std.testing.expect(isSensitivePath("Config/Credentials.json"));
    try std.testing.expect(isSensitivePath("keys/SERVER.KEY"));
    try std.testing.expect(isSensitivePath(".SSH/known_hosts"));
    try std.testing.expect(!isSensitivePath(".envoy.json"));
    try std.testing.expect(!isSensitivePath("src/main.zig"));
}
