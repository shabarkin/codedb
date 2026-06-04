# RFC: MCP root resolution — issue #346

## Problem

`codedb mcp` resolves its scan root from the process `cwd` at startup
(`main.zig` L97: `root = "."`, resolved via `cwd().realpath`). Editors like
Cursor, Windsurf, and VS Code launch MCP server processes from their own
application cwd — typically `/Applications`, `/usr/local`, `~`, or similar —
not the user's open project directory. The result is a silent scan of the
wrong directory.

Two compounding bugs:

1. **`root_policy.isIndexableRoot` is under-specified.** System paths like
   `/Applications`, `/usr/local`, `/opt`, and `/opt/homebrew` all return
   `true` today. A misrouted scan on any of these would index gigabytes of
   data the user never requested.

2. **`scanBg` fires before roots handshake completes.** The MCP protocol
   supports a `roots/list` request that editors use to advertise open
   workspaces. `codedb` already sends this request
   (`mcp.zig:requestRoots`), but `scanBg` is spawned unconditionally at
   startup (`main.zig` L636–638), before the first JSON-RPC message arrives.
   The roots response always loses the race.

## Proposed Fix — two independent parts

### Part A: harden `root_policy.isIndexableRoot` (immediate)

Block all well-known system directory prefixes on macOS and Linux that are
never legitimate project roots:

```
/Applications, /Applications/*
/System, /Library, /usr, /opt, /bin, /sbin, /etc, /var (except /var/home)
/snap, /nix, /proc, /sys, /dev
```

Rule: deny any path whose first two components are a known system prefix.
Allow `/usr/home/...` or `/opt/projects/...` only if a third component exists
and the second component is not itself a well-known system subtree.

Minimal concrete change to `root_policy.zig`:

```zig
const system_prefixes = [_][]const u8{
    "/Applications", "/System", "/Library",
    "/usr", "/opt", "/bin", "/sbin",
    "/etc", "/var/folders", "/private/var/folders",
    "/snap", "/nix", "/proc", "/sys", "/dev",
};

for (system_prefixes) |pfx| {
    if (isExactOrChild(path, pfx)) return false;
}
```

This fixes the failing test in `src/test_mcp.zig` (`issue-346`).

### Part B: defer scan until root is confirmed (safe startup)

The core invariant codedb should enforce:

> In MCP mode, never start a filesystem scan until a root has been
> confirmed by either (a) a CLI positional argument or (b) the MCP
> `roots/list` response from the client.

**Option B1 — CLI positional arg (lowest friction, ships first)**

Already supported by the arg parser (`main.zig` L100–103):
`codedb /path/to/project mcp` sets `root = args[1]`.

Action: document this as the required invocation for Cursor/Windsurf and
update the MCP registration examples in README and docs.

MCP config example:
```json
{
  "mcpServers": {
    "codedb": {
      "command": "/Users/you/bin/codedb",
      "args": ["${workspaceFolder}", "mcp"]
    }
  }
}
```

`${workspaceFolder}` is expanded by VS Code-family editors before process
launch. The existing `main.zig` L140–142 already handles the literal string
`"${workspaceFolder}"` as a fallback to `"."` — that fallback should become
an error instead.

**Option B2 — defer scan until roots handshake (robust, ships second)**

Split startup into two phases:

```
Phase 1 (before first tool call):
  - Parse args. If explicit root arg → use it, skip phase 2.
  - If no root arg → set root = nil, enter "waiting_for_roots" scan state.
  - Send initialize response immediately (MCP requires this).
  - On notifications/initialized → send roots/list request.
  - On roots/list response → pick first acceptable root, transition to phase 2.
  - Any tool call that arrives before phase 2 completes returns:
      {"error": "codedb: no project root yet — waiting for roots/list response"}

Phase 2 (root confirmed):
  - Validate root with isIndexableRoot (exit with error if rejected).
  - Spawn scanBg / load snapshot as today.
  - Process queued tool calls normally.
```

Key changes required:
- `main.zig`: skip `scanBg` spawn when `root == "."` and `cmd == "mcp"`.
  Pass a `root_confirmed: *std.atomic.Value(bool)` flag to `mcp_server.run`.
- `mcp.zig Session`: add `root_confirmed` field; block `dispatch` until set.
  On roots response, set the confirmed root on the cache's `default_path`
  and signal `root_confirmed`.
- `ProjectCache`: expose a `setDefaultPath` method.

**Option B3 — `CODEDB_ROOT` env var (middle ground)**

For editors that don't support `${workspaceFolder}` in args:

```json
{
  "mcpServers": {
    "codedb": {
      "command": "/Users/you/bin/codedb",
      "args": ["mcp"],
      "env": { "CODEDB_ROOT": "${workspaceFolder}" }
    }
  }
}
```

`main.zig` reads `CODEDB_ROOT` before falling back to `"."`:

```zig
root = cio.posixGetenv("CODEDB_ROOT") orelse ".";
```

## Recommended rollout

1. **Now:** merge Part A (`root_policy` hardening). Fixes the test, prevents
   worst-case large-directory scans with zero behaviour change for correct
   setups.
2. **Next:** ship B1 + B3 (positional arg + env var) and update docs/README.
   Low risk — additive only.
3. **Follow-up:** ship B2 (deferred scan). Requires more careful threading
   work but is the only solution that is correct for all editors regardless
   of their MCP config capabilities.

## What this does NOT change

- Behaviour when `codedb mcp` is launched correctly (explicit arg or correct
  cwd) is identical.
- The `ProjectCache` multi-project tool (the `project=` arg on every MCP
  tool) is unaffected.
- Linux home-dir and `/tmp` blocking in `isIndexableRoot` is preserved.
