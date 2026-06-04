# codedb — Agent Instructions

## Project

Zig 0.16.x code intelligence server. codedb is source-build only: contributors and users build the local binary with `zig build`; do not add remote binary installers, curl installers, npm/npx launchers, or release-download update paths.

Tests live in the split `src/test_*.zig` files listed in `build.zig`. Build and test with `zig build test`.

## Rules

### Filing Issues

**Every GitHub issue must include a failing test case.** No exceptions.

When creating an issue:

1. Write a `test "issue-XX: <description>"` block in the relevant `src/test_*.zig` file from the `test_files` list in `build.zig` (for example: search in `src/test_search.zig`, MCP tools in `src/test_mcp.zig`, indexing in `src/test_index.zig`) that **fails** on the current `main` branch
2. Verify it fails: `zig build test -Dtest-filter=issue-XX`
3. File the issue via `gh issue create` with this structure:
   - **Title:** `<module>: <concise description>`
   - **Body sections:** Problem, Failing Test (the zig test block), Expected, Fix
   - **Labels:** `bug` for defects, `priority:p0` for crashes, `priority:p2` for correctness
4. Commit the failing test on a branch: `issue-XX-failing-test`
5. Do **not** fix the bug in the same commit as the failing test

If you cannot write a failing test, the issue is not well-defined enough to file.

### Test Style

- Use `std.testing` and `testing.allocator`
- Use `std.heap.ArenaAllocator` for Explorer tests
- Always `defer` cleanup (arena.deinit, allocator.free)
- One test per issue, named `test "issue-XX: <short description>"`
- Keep tests minimal — only exercise the specific broken code path

### Code Style

- No comments or documentation changes unless explicitly asked
- Prefer minimal, targeted fixes over refactors
- Follow existing patterns in the module you're editing

### Distribution

- Build locally with `zig build` or `zig build -Doptimize=ReleaseFast`
- MCP docs should point clients at `zig-out/bin/codedb` or a user-created local symlink/copy
- `codedb update` must remain disabled and tell users to rebuild from source
- Do not restore deleted installer or npm package surfaces
