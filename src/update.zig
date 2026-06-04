const std = @import("std");
const cio = @import("cio.zig");
const sty = @import("style.zig");

const Out = struct {
    file: cio.File,
    alloc: std.mem.Allocator,

    fn p(self: Out, comptime fmt: []const u8, args: anytype) void {
        const str = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        defer self.alloc.free(str);
        self.file.writeAll(str) catch {};
    }
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
