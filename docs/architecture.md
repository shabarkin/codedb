# codedb — Architecture & Design

A lightweight code intelligence server written in Zig. Indexes a codebase at startup, watches for changes, and serves structural queries over HTTP and MCP (Model Context Protocol).

## Overview

codedb scans a project directory, builds in-memory indexes (outlines, symbols, trigrams, word index, dependency graph), and exposes them via two interfaces:

- **HTTP server** on `:7719` — REST-style JSON API
- **MCP server** over stdio — JSON-RPC for tool-calling LLMs

Both interfaces share the same core: `Explorer` (code intelligence) and `Store` (version tracking).

## Modules

### `main.zig` — CLI Entry Point

Parses args, resolves the project root, runs an initial scan, then dispatches to one of:

| Command | Description |
|---------|-------------|
| `tree` | Print file tree with symbol counts |
| `outline <path>` | Show symbols in a file |
| `find <name>` | Find a symbol definition |
| `search <query>` | Full-text search (trigram-accelerated; `--regex`, `--paths-only`, `--max-results`) |
| `word <id>` | Identifier/sub-token lookup (inverted index, O(1)) |
| `read <path>` | File contents (`-L FROM-TO`, `--compact`) |
| `hot` | Recently modified files |
| `status` | Index size, store seq, and index state |
| `symbol <name>` | All definition sites of a symbol (`--body`) |
| `callers <name>` | Every call site of a symbol |
| `deps <path>` | Dependency graph (`--depends-on`, `--transitive`, `--max-depth`) |
| `glob <pattern>` | Match indexed paths by glob |
| `ls [path]` | List a directory's indexed children |
| `file <fuzzy>` | Fuzzy file-name search |
| `context <task...>` | Task-shaped orientation bundle |
| `compass <task...>` | Intent-shaped overview / define / callers tunnel |
| `serve` | Start HTTP daemon on :7719 |
| `mcp` | Start MCP server (JSON-RPC over stdio) |
| `snapshot` | Write `codedb.snapshot` to the project root |
| `nuke` | Clear caches/snapshots, deregister integrations |

Navigation commands not rendered natively (`symbol`, `callers`, `deps`, `glob`, `ls`, `file`, `context`, `compass`) bridge to the same warm handlers the MCP surface exposes. When a `serve`/`mcp` daemon is already running for the project, query commands proxy to it over a per-project Unix socket instead of reloading the snapshot.

Data is stored per-project at `~/.codedb/projects/<hash>/`.

### `explore.zig` — Code Intelligence Engine

The central struct. Holds all indexed data behind a single mutex.

**Data structures:**
- `outlines: StringHashMap(FileOutline)` — per-file symbol lists (functions, structs, enums, imports)
- `contents: StringHashMap([]const u8)` — raw file content cache
- `dep_graph: StringHashMap(ArrayList([]const u8))` — file → imported files
- `word_index: WordIndex` — inverted word index for O(1) identifier lookup
- `trigram_index: TrigramIndex` — trigram index for fast substring search

**Language parsers:** Zig, C/C++, Python, TypeScript/JavaScript, Rust, Go, PHP, Ruby, HCL, R, and Dart. Each parser extracts functions, classes/structs, constants, imports, and test declarations from source lines. Lightweight outline support also covers Java, Kotlin, Swift, Svelte, Vue, Astro, ReScript, shell, CSS/SCSS, SQL, protobuf, Fortran, LLVM IR, MLIR, and TableGen.

**Key operations:**
- `indexFile(path, content)` — parse + index a file (outline, content, words, trigrams, deps)
- `indexFileOutlineOnly(path, content)` — fast path for initial scan (skips search indexes)
- `removeFile(path)` — clean removal from all maps and indexes
- `getTree()` — sorted file tree with directory nodes and symbol counts
- `findSymbol(name)` / `findAllSymbols(name)` — symbol lookup across all files
- `searchContent(query, max)` — high-recall, trigram-accelerated full-text search
- `searchWord(word)` — O(1) inverted index lookup
- `getImportedBy(path)` — reverse dependency lookup
- `getHotFiles(store, limit)` — files sorted by most recent change sequence

### `index.zig` — Search Indexes

**WordIndex** — inverted index mapping words to `(path, line_num)` hits. Tokenizes content into identifiers, skipping single-character tokens. Supports efficient re-indexing via per-file word tracking. Deduplicates results by `(path, line)`.

**TrigramIndex** — maps 3-byte character sequences to file sets. Used to narrow full-text search candidates before brute-force scanning. Queries < 3 chars fall back to brute force. Intersection of trigram sets gives candidate files. Literal search treats recall as the default contract for indexed, non-sensitive files: if accelerated candidates produce a partial eligible result set, `Explorer` scans remaining indexed files before ranking and truncating to `max_results`. Sensitive paths, ignored files, compact filtering, `max_results`, and `max_per_file` still bound the visible result set.

### `store.zig` — Version Store

Append-only version log per file. Each mutation (snapshot, edit, delete) gets a monotonically increasing sequence number.

**Key features:**
- `recordSnapshot/recordEdit/recordDelete` — append a version entry
- `getLatest(path)` / `getAtCursor(path, cursor)` — version queries (return by value for safety)
- `changesSince(seq)` / `changesSinceDetailed(seq)` — change tracking for polling clients
- `currentSeq()` — atomic sequence counter
- Optional `data.log` file for persisting diff data
- Version history capped at 100 entries per file

### `version.zig` — Version Types

- `Version` — seq, agent, timestamp, op, hash, size, data offset/len
- `Op` — snapshot | replace | insert | delete | tombstone
- `FileVersions` — ordered list of versions for a single file path

### `watcher.zig` — File System Watcher

Polling-based file watcher (2-second interval). Uses mtime + content hash to detect changes.

**FilteredWalker** — custom directory walker that prunes `.git`, `node_modules`, `.next`, `target`, `zig-out`, `zig-cache`, `__pycache__`, `.venv`, `dist`, `build` directories *before* descending. This prevents the CPU-hogging bug where `std.fs.Dir.walk()` would traverse tens of thousands of files in ignored directories every poll cycle.

**Flow:**
1. `initialScan` — walk all files, index outlines (fast path, no search indexes)
2. `incrementalLoop` — poll every 2s, detect added/modified/deleted files
3. `incrementalDiff` — compare current filesystem state against cached `FileMap`, push `FsEvent`s to `EventQueue`

**EventQueue** — bounded ring buffer (256 entries) for filesystem events. Non-blocking push, blocking pop.

### `server.zig` — HTTP Server

Thread-per-connection HTTP server on `:7719`. Parses raw HTTP/1.1 requests, requires a per-port token on every route except `/health`, and caps concurrent handlers.

**Endpoints:**

| Route | Method | Description |
|-------|--------|-------------|
| `/health` | GET | Health check (no auth required) |
| `/agent/register` | POST | Register an editing agent |
| `/agent/heartbeat?id=` | POST | Refresh agent liveness |
| `/lock?agent=&path=` | POST | Acquire a file lock |
| `/unlock?agent=&path=` | POST | Release a file lock |
| `/edit` | POST | Apply a line-range edit |
| `/file/read?path=` | GET | Read file content |
| `/changes?since=` | GET | Changed files since sequence N |
| `/explore/tree` | GET | File tree |
| `/explore/outline?path=` | GET | File outline |
| `/explore/symbol?name=` | GET | Find symbol definitions |
| `/explore/hot` | GET | Recently modified files |
| `/explore/deps?path=` | GET | Reverse dependencies |
| `/explore/word?q=` | GET | Inverted index word lookup |
| `/explore/search?q=` | GET | Full-text search |
| `/compass` | POST | Compass navigation (`task`, `intent`, `target`, `body`, `max_files`, `mode`, `format`, `more`) |
| `/snapshot` | GET | Full pre-rendered JSON snapshot |
| `/seq` | GET | Current sequence number |

**Safety:** token auth (`X-Codedb-Token` or `Authorization: Bearer ...`), path traversal prevention (`isPathSafe`), sensitive-file blocking, POST body size cap, request read timeout, and bounded concurrent handlers.

### `mcp.zig` — MCP Server

JSON-RPC 2.0 over stdio with Content-Length framing. Implements the Model Context Protocol for LLM tool use.

**22 tools exposed:**

| Tool | Description |
|------|-------------|
| `codedb_tree` | File tree |
| `codedb_outline` | File outline |
| `codedb_symbol` | Symbol lookup |
| `codedb_search` | Full-text search (trigram, regex, scoped) |
| `codedb_word` | Word index lookup |
| `codedb_callers` | Heuristic call-site finder (word index ∩ outline scope) |
| `codedb_context` | Task-shaped composer: NL task → keywords + defs + ranked files + snippets |
| `codedb_compass` | Intent-shaped navigation tunnel (overview / define / callers) |
| `codedb_hot` | Hot files |
| `codedb_deps` | Reverse dependencies |
| `codedb_read` | Read file content (line ranges, hash caching) |
| `codedb_edit` | Apply edits (replace, insert, delete) |
| `codedb_changes` | Changes since seq |
| `codedb_status` | Index status |
| `codedb_snapshot` | Full snapshot |
| `codedb_bundle` | Batch multiple queries (max 20 ops) |
| `codedb_projects` | List locally indexed projects |
| `codedb_index` | Index a local folder |
| `codedb_find` | Fuzzy file-name search (typo-tolerant subsequence match) |
| `codedb_query` | Composable pipeline (chain find/glob/search/word/symbol/filter/deps/outline/read/sort/limit) |
| `codedb_glob` | Match indexed paths against a glob |
| `codedb_ls` | List immediate children of a directory |

**Safety:** path validation, oversized message handling (drains >1MB lines instead of killing the loop).

### `compass.zig` — Intent-Shaped Navigation

Collapses multi-step navigation (find → search → symbol → callers) into one in-process call against the warm `Explorer`. Exposed as the `codedb_compass` MCP tool, the `compass` CLI command, and `POST /compass` over HTTP.

- **Intents:** `overview` (keywords, definitions, ranked files, callers), `define` (definitions + fallback sites), `callers` (call sites of a symbol). Declared explicitly or routed from the natural-language task by a rule-based scorer.
- **Modes:** `summary` (default), `evidence`, `raw`; output `format` is `text` or `json`.
- **Coverage:** results report "X of N" — truncation is always explicit. When a reduced view truncates, the full result persists as an overflow artifact recoverable via `more`.
- **Tuning:** `.codedbrc` keys `compass_max_files` (default 5), `compass_body` (default false), `compass_overflow_keep` (default 50).

Shared request/render types live in `compass_shared.zig` and `compass_render.zig`; per-project artifact paths in `project_paths.zig`.

### `config.zig` — `.codedbrc` Loader

INI-style `key = value` config. Resolution order: `--config-file=<path>` → `$CWD/.codedbrc` → `<binary_dir>/.codedbrc` → defaults. Keys: `max_versions` (100), `max_cached` (16384), `compass_max_files` (5), `compass_body` (false), `compass_overflow_keep` (50). Unknown keys are ignored; malformed values for known keys are errors.

### `edit.zig` — File Editor

Line-range editing engine. Supports `replace` and `delete` operations on line ranges.

**Atomic writes:** writes to a `.codedb_tmp` temp file then renames, preventing corruption on crash. Returns `EditResult` with new content, hash, size, and line count.

### `snapshot_json.zig` — Snapshot Renderer

Builds a full JSON snapshot on demand containing tree, all outlines, symbol index, and dependency graph.

- `buildSnapshot()` — streams JSON from Explorer state; object key order is not part of the snapshot contract

### `agent.zig` — Agent Registry

Multi-agent support. Agents register with names, get assigned integer IDs. Supports file locking (exclusive per-agent) and heartbeat-based stale agent reaping (30s timeout).

### `build.zig` — Build Configuration

Zig 0.16 build system. Produces:
- `codedb` CLI executable
- Test runner (`zig build test`, filter with `-Dtest-filter=<substring>`); each `src/test_*.zig` suite also has its own step (`test-core`, `test-explore`, `test-index`, `test-parser`, `test-search`, `test-snapshot`, `test-mcp`, `test-compass`, `test-query`, `test-bench`)
- Benchmarks (`zig build bench`; repo benchmark via `zig build benchmark -- --root /path`)
- WASM module for Cloudflare Workers (`zig build wasm`)
- Importable `codedb` module via `src/lib.zig`

Build options: `-Dtree-sitter` (vendored tree-sitter parsers, default true), `-Dcodesign-identity` (macOS), `-Dtest-filter`.

## Architecture Diagram

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

## Threading Model

- **Main thread** — runs HTTP accept loop or MCP read loop
- **Watcher thread** — `incrementalLoop`, polls filesystem every 2s
- **ISR thread** — `isrLoop`, rebuilds snapshot when stale flag is set
- **Reap thread** — `reapLoop`, cleans up stale agents every 5s
- **Per-connection threads** — HTTP server spawns a thread per connection

All threads share a `shutdown: std.atomic.Value(bool)` flag for graceful termination.

## Data Flow

1. **Startup:** `initialScan` walks the project (via `FilteredWalker`), indexes each file's outline and content into `Explorer`, records snapshots in `Store`
2. **Steady state:** `incrementalLoop` detects changes, re-indexes modified files, and pushes events to `EventQueue`
3. **Queries:** HTTP/MCP handlers call `Explorer` methods under its mutex, return JSON responses
4. **Edits:** `/edit` applies line-range changes atomically, re-indexes the file, records the edit in `Store`
