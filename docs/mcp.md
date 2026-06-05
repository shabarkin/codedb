# codedb MCP Setup

`codedb mcp` runs as a stdio JSON-RPC server speaking the
[Model Context Protocol](https://spec.modelcontextprotocol.io/). It exposes
22 tools for code intelligence — search, outline, callers, deps, edit,
context, etc. — backed by the indexes in `~/.codedb/projects/<hash>/`.

This guide covers per-client setup, how codedb decides which project to
scan, and the most common failure modes.

---

## 1. Build codedb

```bash
git clone https://github.com/justrach/codedb.git
cd codedb
zig build -Doptimize=ReleaseFast
```

Use the built binary at `zig-out/bin/codedb`, or create a local symlink/copy:

```bash
mkdir -p ~/.local/bin
ln -sf "$PWD/zig-out/bin/codedb" ~/.local/bin/codedb
```

codedb is source-build only. There is no hosted installer, package-manager
launcher, prebuilt artifact fetch, or client auto-registration flow. Wire each
client to the local binary you built.

---

## 2. Client-specific configuration

All clients launch `codedb mcp` as a stdio child process. Replace
`/Users/me/code/codedb/zig-out/bin/codedb` with your built binary path or
with `which codedb` if you created a local symlink/copy.

### Claude Code

```bash
claude mcp add codedb -s user -- /Users/me/code/codedb/zig-out/bin/codedb mcp
```

Or edit `~/.claude.json` directly:

```json
{
  "mcpServers": {
    "codedb": {
      "command": "/Users/me/code/codedb/zig-out/bin/codedb",
      "args": ["mcp"]
    }
  }
}
```

Verify: `claude mcp list` should show `codedb: /usr/local/bin/codedb mcp - ✓ Connected`.

### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`
(macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "codedb": {
      "command": "/Users/me/code/codedb/zig-out/bin/codedb",
      "args": ["mcp"]
    }
  }
}
```

Restart Claude Desktop. The tools should appear in the slash-command menu.

### Cursor

Edit `~/.cursor/mcp.json` (per-user) or `<project>/.cursor/mcp.json`
(per-project):

```json
{
  "mcpServers": {
    "codedb": {
      "command": "/Users/me/code/codedb/zig-out/bin/codedb",
      "args": ["mcp"]
    }
  }
}
```

Cursor advertises the open workspace via the `roots/list` MCP handshake,
so codedb scans the right project automatically (see Root Resolution
below).

### VS Code (with an MCP extension)

Same `mcpServers` block as Cursor, scoped to whichever extension you use.

### Codex CLI

```bash
codex mcp add codedb -- /Users/me/code/codedb/zig-out/bin/codedb mcp
```

### Gemini CLI / opencode

Both read MCP configuration from `~/.gemini/mcp.json` (Gemini) and
`~/.config/opencode/mcp.json` (opencode):

```json
{
  "mcpServers": {
    "codedb": {
      "command": "/Users/me/code/codedb/zig-out/bin/codedb",
      "args": ["mcp"]
    }
  }
}
```

---

## 3. Root resolution — which project does `codedb mcp` scan?

`codedb mcp` figures out the project root in this order (first match wins):

1. **MCP `roots/list` handshake** (preferred). When a client supports it
   (Cursor, Windsurf, recent VS Code MCP extensions), codedb requests
   `roots/list` immediately after `initialize` and uses the first workspace
   root the client returns. This is the most reliable path — codedb scans
   exactly the project the user has open in their editor.

2. **Per-call `project` argument**. Every tool accepts an optional
   `project: "<abs path>"` field that switches the active project for that
   single call. Useful for cross-project queries:

   ```json
   {
     "name": "codedb_search",
     "arguments": {
       "query": "scheduleUpdateOnFiber",
       "project": "/Users/me/code/react"
     }
   }
   ```

3. **Process `cwd`**. If the client doesn't speak `roots/list` and no
   per-call `project` is set, codedb falls back to the directory it was
   launched from. Some editors launch MCP servers from `/Applications` or
   `~`, which is almost certainly the wrong directory — set the `project`
   arg explicitly for those.

System directories (`/`, `/Applications`, `/usr`, `/opt`, `~`,
`/tmp`, etc.) are blocked from being indexed as project roots — see
[`docs/rfc-346-mcp-root-resolution.md`](rfc-346-mcp-root-resolution.md)
for the full safety logic.

---

## 4. `.codedbrc` — per-project configuration

Drop a `.codedbrc` at the root of any project to override defaults for
that project. INI-style `key = value` pairs, one per line, `#` for
comments. Unknown keys are ignored.

```ini
# .codedbrc
max_cached   = 16384   # in-memory ContentCache size (files); default 16384
max_versions = 100     # versions kept per file in the change log; default 100
rerank_trace = false   # write per-search rerank-trace.jsonl (debug only)
```

Pass an alternative path with `--config-file <path>` to the CLI for
testing.

---

## 5. Verifying the build

```bash
zig-out/bin/codedb --version
zig-out/bin/codedb status
```

In a client, the simplest tool to smoke-test is `codedb_status` — it
takes no arguments and returns `files: N, seq: N, scan: ready` in <50 ms.

---

## 6. Lean MCP output

Set `CODEDB_MCP_LEAN=1` before launching `codedb mcp` to strip the rich
summary header and trailing guidance hints from tool responses. In lean mode
the server emits only the raw data block, which is useful for agents that do
not render ANSI escapes or when you want to minimize token usage.

Any non-empty value enables lean mode except `0` and `false`.

---

## 7. Troubleshooting

### "No project root yet" / empty tree

The MCP server hasn't received a project root. Either:
- the client doesn't speak `roots/list`, or
- the client launched codedb from a system directory that's blocked from
  indexing (`/Applications`, `/usr`, `~`, etc.).

**Fix:** pass `project: "/abs/path/to/your/project"` on the first tool
call, or restart the client from inside the project directory.

### `codedb_find` returns `missing 'query'`

`codedb_find` accepts `query`, `name`, `path`, `pattern`, and `q` as aliases.
If you're still seeing this error, rebuild from the latest source and verify
the client points at the rebuilt binary.

### Tools list looks short / `codedb_context` is missing

`codedb_context` requires a current source build. Rebuild with
`zig build -Doptimize=ReleaseFast` and verify the client points at the rebuilt
binary.

### Snapshot indexer keeps re-scanning

The watcher debounces filesystem events for ~500 ms. If your editor saves
files in quick succession (e.g. a formatter that rewrites everything),
back-to-back saves can extend the scan phase. Check `codedb status` —
`scan: ready` means it's caught up.

### Permission errors on macOS

The first time you run a locally built codedb binary on macOS, Gatekeeper may
quarantine it. If needed, codesign the binary locally:

```bash
codesign --force --sign - zig-out/bin/codedb
```

Avoid codesigning locally built x86_64-macos binaries on macOS 26 until
the upstream Zig/Mach-O issue is resolved.

### Stale signatures after `cp` over an existing binary

macOS caches codesignatures by path. After replacing the binary,
re-codesign Apple Silicon builds or the MCP server may fail to launch:

```bash
codesign --force --sign - zig-out/bin/codedb
```

---

## 8. Going deeper

- [Architecture](architecture.md) — engine internals, index layout
- [CLI reference](cli.md) — every command, every flag
- [Skill base & context files](skills.md) — `agents.md`, `CLAUDE.md`,
  `GEMINI.md`, and the per-project skill hierarchy
- [RFC #346 — MCP root resolution](rfc-346-mcp-root-resolution.md) —
  full design + safety logic for project-root detection
