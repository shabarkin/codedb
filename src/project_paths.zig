const std = @import("std");
const cio = @import("cio.zig");

pub fn projectDataDir(allocator: std.mem.Allocator, project_path: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(0, project_path);
    const home_env = cio.posixGetenv("HOME") orelse {
        return std.fmt.allocPrint(allocator, "{s}/.codedb", .{project_path});
    };
    return std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}", .{ home_env, hash });
}

pub fn ensureProjectDataDir(io: std.Io, allocator: std.mem.Allocator, project_path: []const u8) ![]u8 {
    const dir = try projectDataDir(allocator, project_path);
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        std.log.warn("could not create data dir {s}: {}", .{ dir, err });
    };
    return dir;
}
