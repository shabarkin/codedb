<p align="center">
  <img src="assets/codedb.png" alt="codedb" width="200" />
</p>

<h1 align="center">codedb</h1>

<h3 align="center">Code intelligence server for AI agents. Zig core. MCP native.</h3>

<p align="center">
  Structural indexing · Trigram search · Word index · Dependency graph · File watching · MCP + HTTP
</p>

<p align="center">
  <a href="#-status">Status</a> ·
  <a href="#-build">Build</a> ·
  <a href="#-quick-start">Quick Start</a> ·
  <a href="#-mcp-tools">MCP Tools</a> ·
  <a href="#-benchmarks">Benchmarks</a> ·
  <a href="#️-architecture">Architecture</a> ·
  <a href="#-data--privacy">Data & Privacy</a> ·
  <a href="#-building-from-source">Building</a>
</p>

---

## Status

> **Alpha software — API is stabilizing but may change**
>
> codedb works and is used daily in production AI workflows, but:
> - **Parser support** — Zig, C/C++, Python, TypeScript/JavaScript, Rust, Go, PHP, Ruby, HCL, R, Dart/Flutter
> - **Lightweight outline support** — Java, Kotlin, Svelte, Vue, Astro, shell, CSS/SCSS, SQL, protobuf, Fortran, LLVM IR, MLIR, and TableGen
> - **HTTP auth** — localhost server requires `X-Codedb-Token` or `Authorization: Bearer ...`
> - **Snapshot format** may change between versions
> - **MCP protocol** is JSON-RPC 2.0 over stdio (stable)

| What works today                                       | What's in progress                       |
|--------------------------------------------------------|------------------------------------------|
| 22 MCP tools for full codebase intelligence            | Deeper parser coverage and edge-case handling |
| Trigram v2: integer doc IDs, batch-accumulate, merge intersect | Incremental segment-based indexing |
| Warm, pre-indexed MCP queries can be hundreds of times faster than one-shot ripgrep | WASM target experiments                  |
| O(1) inverted word index for identifier lookup         | Multi-project support                    |
| Structural outlines (functions, structs, imports)      | mmap-backed trigram index                |
| Reverse dependency graph                               |                                          |
| Atomic line-range edits with version tracking          |                                          |
| Polling file watcher with filtered directory walker    |                                          |
| Portable snapshot for instant MCP startup              |                                          |
| Sensitive file blocking (.env, credentials, keys)      |                                          |
| Cross-platform: macOS (ARM/x86), Linux (ARM/x86)      |                                          |

---

## ⚡ Build

codedb is source-build only. There is no curl, npm, npx, or release-binary installer path.

**Requirements:** Zig 0.16+

```bash
git clone https://github.com/justrach/codedb.git
cd codedb
zig build -Doptimize=ReleaseFast
```

Binary: `zig-out/bin/codedb`

Optionally copy or symlink the built binary into a directory on your `PATH`:

```bash
mkdir -p ~/.local/bin
ln -sf "$PWD/zig-out/bin/codedb" ~/.local/bin/codedb
```

When updating codedb, pull the source tree and rebuild:

```bash
git pull
zig build -Doptimize=ReleaseFast
```

## Documentation

- **[MCP setup](docs/mcp.md)** — per-client configurations (Claude Desktop, Cursor, VS Code, Claude Code, Codex CLI, Gemini CLI), root resolution, troubleshooting
- **[Skill base & context files](docs/skills.md)** — `agents.md` / `CLAUDE.md` / `GEMINI.md`, `.codedbrc`, per-developer memory
- **[CLI reference](docs/cli.md)** — every command, every flag
- **[Architecture](docs/architecture.md)** — engine internals, index layout
- **[Benchmarks](docs/benchmarks.md)** — micro-benchmarks + agentic-eval results vs codegraph, FTS5, lean-ctx

## ⚡ Quick Start

### As an MCP server (recommended)

Build codedb, then point your MCP client at the local binary.

```bash
zig-out/bin/codedb /path/to/your/project mcp
```

Set `CODEDB_MCP_LEAN=1` to suppress the colored summary header and guidance
blocks in MCP replies, leaving only the raw data payload. `0` and `false`
keep the default rich output.

### As an HTTP server

```bash
zig-out/bin/codedb /path/to/your/project serve
cat ~/.codedb/server-7719.token
curl -H "X-Codedb-Token: $(cat ~/.codedb/server-7719.token)" \
  "http://127.0.0.1:7719/explore/search?q=handleAuth"
```

### CLI

```bash
zig-out/bin/codedb /path/to/project tree          # file tree with symbol counts
zig-out/bin/codedb /path/to/project outline src/main.zig
zig-out/bin/codedb /path/to/project find AgentRegistry
zig-out/bin/codedb /path/to/project search "handleAuth"
zig-out/bin/codedb /path/to/project word Store
zig-out/bin/codedb /path/to/project hot
```

---

## 🔧 MCP Tools

22 tools over the Model Context Protocol (JSON-RPC 2.0 over stdio):

| Tool | Description |
|------|-------------|
| `codedb_tree` | Full file tree with language, line counts, symbol counts |
| `codedb_outline` | Symbols in a file: functions, structs, imports, with line numbers |
| `codedb_symbol` | Find where a symbol is defined across the codebase |
| `codedb_search` | Trigram-accelerated full-text search (supports regex, scoped results) |
| `codedb_word` | O(1) inverted index lookup for identifiers and their sub-tokens |
| `codedb_callers` | Heuristic call-site finder — word index ∩ outline scope, in one round-trip |
| `codedb_context` | Task-shaped composer — pass a NL task, get keywords + symbol defs + ranked files + top snippets in one block (replaces 3–5 sequential calls) |
| `codedb_hot` | Most recently modified files |
| `codedb_deps` | Dependency graph: `imported_by` (default) or `depends_on`; `transitive=true` for full BFS |
| `codedb_read` | Read file content (line ranges, `if_hash` skip-unchanged, `compact` mode) |
| `codedb_edit` | Apply line-range edits (replace, insert, delete — atomic writes, optional `if_hash` guard) |
| `codedb_changes` | Changed files since a sequence number |
| `codedb_status` | Index status (file count, current sequence, scan phase) |
| `codedb_snapshot` | Full pre-rendered JSON snapshot of the codebase |
| `codedb_projects` | List all locally indexed projects on this machine |
| `codedb_index` | Index a local folder and write `codedb.snapshot` |
| `codedb_find` | Fuzzy **file-name** search (typo-tolerant subsequence match against indexed paths — not a content/symbol search) |
| `codedb_glob` | Match indexed paths against a glob pattern (`src/**/*.zig`, `*.md`, …) |
| `codedb_ls` | List immediate children of a directory — dirs first, then files with language + counts |
| `codedb_query` | Composable pipeline — chain `find`, `search`, `filter`, `deps`, `outline`, `read`, `sort`, `limit` in one request |

Search is high-recall by default for indexed, non-sensitive files: accelerated
literal search expands to remaining eligible files when candidates do not fill
`max_results`, then ranks the collected hits. Results are still bounded by
`max_results`, `max_per_file`, ignore rules, compact filtering, and the
sensitive-file policy. Basename globs such as `*.ts` are promoted to `**/*.ts`
in MCP search/glob/query filters so nested files are included by default.

### CLI Commands

| Command | Description |
|---------|-------------|
| `codedb tree` | Show file tree with language and symbol counts |
| `codedb outline <path>` | List all symbols in a file |
| `codedb find <name>` | Find where a symbol is defined |
| `codedb search <query>` | Full-text search (trigram, case-insensitive) |
| `codedb search --regex <pattern>` | Regex search |
| `codedb word <identifier>` | Identifier/sub-token lookup via inverted index |
| `codedb read <path>` | Read file contents (supports `-L FROM-TO`, `--compact`) |
| `codedb hot` | Recently modified files |
| `codedb snapshot` | Write codedb.snapshot to project root |
| `codedb serve` | HTTP daemon on :7719 |
| `codedb [root] mcp` | JSON-RPC/MCP server over stdio |
| `codedb update` | Disabled for source-build workflow; rebuild with `zig build` |
| `codedb nuke` | Remove caches/snapshots and deregister MCP integrations |
| `codedb --version` | Print version |

### Example: agent explores a codebase

```bash
TOKEN=$(cat ~/.codedb/server-7719.token)

# 1. Get the file tree
curl -H "X-Codedb-Token: $TOKEN" http://127.0.0.1:7719/explore/tree

# 2. Drill into a file
curl -H "X-Codedb-Token: $TOKEN" \
  "http://127.0.0.1:7719/explore/outline?path=src/store.zig"

# 3. Find a symbol across the codebase
curl -H "X-Codedb-Token: $TOKEN" \
  "http://127.0.0.1:7719/explore/symbol?name=AgentRegistry"

# 4. Full-text search
curl -H "X-Codedb-Token: $TOKEN" \
  "http://127.0.0.1:7719/explore/search?q=handleAuth"

# 5. Check what changed
curl -H "X-Codedb-Token: $TOKEN" \
  "http://127.0.0.1:7719/changes?since=42"
```

---

## 📊 Benchmarks

Measured on Apple M4 Pro, 48GB RAM. MCP = pre-indexed warm queries (20 iterations avg). CLI/external tools include process startup (3 iterations avg). Ground truth verified against Python reference implementation.

### Latency — codedb MCP vs codedb CLI vs ast-grep vs ripgrep vs grep

**codedb repo** (20 files, 12.6k lines):

| Query | codedb MCP | codedb CLI | ast-grep | ripgrep | grep | MCP speedup |
|-------|-----------|-----------|----------|---------|------|-------------|
| File tree | **0.04 ms** | 52.9 ms | — | — | — | **1,253x** vs CLI |
| Symbol search (`init`) | **0.10 ms** | 54.1 ms | 3.2 ms | 6.3 ms | 6.5 ms | **549x** vs CLI |
| Full-text search (`allocator`) | **0.05 ms** | 60.7 ms | 3.2 ms | 5.3 ms | 6.6 ms | **1,340x** vs CLI |
| Word index (`self`) | **0.04 ms** | 59.7 ms | n/a | 7.2 ms | 6.5 ms | **1,404x** vs CLI |
| Structural outline | **0.05 ms** | 53.5 ms | 3.1 ms | — | 2.4 ms | **1,143x** vs CLI |
| Dependency graph | **0.05 ms** | 2.2 ms | n/a | n/a | n/a | **45x** vs CLI |

**merjs repo** (100 files, 17.3k lines):

| Query | codedb MCP | codedb CLI | ast-grep | ripgrep | grep | MCP speedup |
|-------|-----------|-----------|----------|---------|------|-------------|
| File tree | **0.05 ms** | 54.0 ms | — | — | — | **1,173x** vs CLI |
| Symbol search (`init`) | **0.07 ms** | 54.4 ms | 3.4 ms | 6.3 ms | 3.6 ms | **758x** vs CLI |
| Full-text search (`allocator`) | **0.03 ms** | 54.1 ms | 2.9 ms | 5.1 ms | 3.7 ms | **1,554x** vs CLI |
| Word index (`self`) | **0.04 ms** | 54.7 ms | n/a | 6.3 ms | 4.2 ms | **1,518x** vs CLI |
| Structural outline | **0.04 ms** | 54.9 ms | 3.4 ms | — | 2.5 ms | **1,243x** vs CLI |

**rtk-ai/rtk repo** (329 files) — codedb vs rtk vs ripgrep vs grep:

| Tool | Search "agent" | Speedup |
|------|---------------|---------|
| codedb (pre-indexed) | **0.065 ms** | baseline |
| rtk | 37 ms | 569x slower |
| ripgrep | 45 ms | 692x slower |
| grep | 80 ms | 1,231x slower |

### Token Efficiency

codedb returns structured, relevant results — not raw line dumps. For AI agents, this means dramatically fewer tokens per query:

| Repo | codedb MCP | ripgrep / grep | Reduction |
|------|-----------|---------------|-----------|
| codedb (search `allocator`) | ~20 tokens | ~32,564 tokens | **1,628x fewer** |
| merjs (search `allocator`) | ~20 tokens | ~4,007 tokens | **200x fewer** |

### Indexing Speed

codedb v0.2.57 uses worker-local parallel scan with deterministic merge — each worker builds its own partial index, then results are merged on the main thread:

| Repo | Files | Cold start | Per file | vs v0.2.56 |
|------|-------|-----------|----------|-----------|
| codedb | 20 | **17 ms** | 0.85 ms | — |
| merjs | 100 | **16 ms** | 0.16 ms | — |
| 5,200 mixed files | 5,200 | **310 ms** | 0.06 ms | — |
| [openclaw/openclaw](https://github.com/openclaw/openclaw) | 6,315 | **346 ms** | 0.05 ms | **10× faster** |

Indexes are built once on startup. After that, the file watcher keeps them updated incrementally (single-file re-index: **<2ms**). Queries never re-scan the filesystem. For repos >1000 files, file contents are released after indexing to save ~300-500MB.

### Background Resource Usage (`openclaw`, 6,315 files, Apple M4 Pro)

| Metric | v0.2.56 | v0.2.57 | Delta |
|--------|---------|---------|-------|
| Steady-state RSS | 1,867 MB | 1,706 MB | −161 MB |
| `git` subprocesses / min (idle) | ~30 | ~0 | **mtime-gated** |

The watcher now stats `.git/HEAD` mtime before forking `git rev-parse HEAD`. On an idle repo the subprocess never fires.
### Why codedb is fast

- **MCP server** indexes once on startup → all queries hit in-memory data structures (O(1) hash lookups)
- **CLI** pays ~55ms process startup + full filesystem scan on every invocation
- **ast-grep** re-parses all files through tree-sitter on every call (~3ms)
- **ripgrep/grep** brute-force scan every file on every call (~5-7ms)
- The MCP advantage: **index once, query thousands of times at sub-millisecond latency**

### Feature Matrix

| Feature | codedb MCP | codedb CLI | ast-grep | ripgrep | grep | ctags |
|---------|-----------|-----------|----------|---------|------|-------|
| Structural parsing | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ |
| Trigram search index | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Inverted word index | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Dependency graph | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Version tracking | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Multi-agent locking | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Pre-indexed (warm) | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| No process startup | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| MCP protocol | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Full-text search | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Atomic file edits | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| File watcher | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |

> **codedb = tree-sitter + search index + dependency graph + agent runtime.** Single binary, source-built, with vendored tree-sitter C grammars.


---

## 🏗️ Architecture

```
┌─────────────┐     ┌─────────────┐
│  HTTP :7719 │     │  MCP stdio  │
│  server.zig │     │  mcp.zig    │
└──────┬──────┘     └──────┬──────┘
       │                   │
       └───────┬───────────┘
               │
    ┌──────────▼──────────┐
    │     Explorer        │
    │   explore.zig       │
    │  ┌───────────────┐  │
    │  │ WordIndex      │  │
    │  │ TrigramIndex   │  │
    │  │ Outlines       │  │
    │  │ Contents       │  │
    │  │ DepGraph       │  │
    │  └───────────────┘  │
    └──────────┬──────────┘
               │
    ┌──────────▼──────────┐
    │      Store          │──── data.log
    │    store.zig        │
    └──────────┬──────────┘
               │
    ┌──────────▼──────────┐
    │     Watcher         │ ← polls every 2s
    │   watcher.zig       │
    │  (FilteredWalker)   │
    └─────────────────────┘
```

**No SQLite. No dependencies.** Purpose-built data model:

- **Explorer** — structural index engine. Parses Zig, Python, TypeScript/JavaScript, Rust, Go, PHP, Ruby, HCL, R, and Dart. Maintains outlines, trigram index, inverted word index, content cache, and dependency graph behind a single mutex.
- **Store** — append-only version log. Every mutation (snapshot, edit, delete) gets a monotonically increasing sequence number. Version history capped at 100 per file.
- **Watcher** — polling file watcher (2s interval). `FilteredWalker` prunes `.git`, `node_modules`, `zig-cache`, `__pycache__`, etc. before descending.
- **Agents** — first-class structs with cursors, heartbeats, and exclusive file locks. Stale agents reaped after 30s.

### Threading Model

| Thread | Role |
|--------|------|
| Main | HTTP accept loop or MCP read loop |
| Watcher | Polls filesystem every 2s via `FilteredWalker` |
| ISR | Rebuilds snapshot when stale flag is set |
| Reap | Cleans up stale agents every 5s |
| Per-connection | HTTP server spawns a thread per connection |

All threads share a `shutdown: atomic.Value(bool)` for graceful termination.

---

## 🔒 Data & Privacy

codedb does not collect usage analytics or send source code, file contents, file paths, or search queries off the machine during normal indexing and search.

| Location | Contents | Purpose |
|----------|----------|---------|
| `~/.codedb/projects/<hash>/` | Trigram index, frequency table, data log | Persistent index cache |
| `./codedb.snapshot` | File tree, outlines, content, frequency table | Portable snapshot for instant MCP startup |

**Not stored:** Sensitive files are auto-excluded (`.env*`, `credentials.json`, `secrets.*`, `.pem`, `.key`, SSH keys, AWS configs).

```bash
codedb nuke                # clear caches/snapshots and remove MCP registrations
rm -rf ~/.codedb/          # cache-only cleanup
rm -f codedb.snapshot      # remove snapshot from current project only
```

---

## 🔨 Building from Source

**Requirements:** Zig 0.16+

```bash
git clone https://github.com/justrach/codedb.git
cd codedb
zig build                              # debug build
zig build -Doptimize=ReleaseFast       # release build
zig build test                         # run tests
zig build bench                        # run benchmarks
```

Binary: `zig-out/bin/codedb`

### Cross-compilation

```bash
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-macos
```

### Releasing

There is no release-binary publishing flow. Consumers build from source, using
the vendored Zig package dependencies in this repository.

---

## License

See [LICENSE](LICENSE) for details.
