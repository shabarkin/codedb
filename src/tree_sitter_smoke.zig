const std = @import("std");
const cio = @import("cio.zig");
const build_options = @import("build_options");
const tree_sitter = @import("tree_sitter.zig");

pub fn main() !void {
    if (!build_options.tree_sitter) {
        try cio.File.stderr().writeAll("tree-sitter support is disabled; rerun with -Dtree-sitter=true\n");
        return;
    }

    const source =
        \\pub struct Greeter;
        \\
        \\impl Greeter {
        \\    pub fn greet(&self) {}
        \\}
    ;

    var parser = try tree_sitter.Parser.initRust();
    defer parser.deinit();

    var tree = try parser.parseString(source);
    defer tree.deinit();

    try cio.File.stdout().print("rust abi {d}\n", .{tree_sitter.rustLanguageVersion()});
    try tree_sitter.dumpNamedNodes(cio.File.stdout(), tree.rootNode());
}
