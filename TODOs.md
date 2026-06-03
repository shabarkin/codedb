# TODOs

Snapshot of in-flight work after the v0.2.5815 release. Updated 2026-05-21.

---

## Shipped in v0.2.5815

Released 2026-05-20, [tag](https://github.com/justrach/codedb/releases/tag/v0.2.5815).

- **#474** — `codedb_status` 9.4× faster (cache `approxIndexSizeBytes`)
- **#475** — `codedb word X` 2.4–4.9× faster (persist `word.index` on first call)
- **#476** — `codedb_search` / `codedb_callers` default `max_results` trimmed (−31% / −35% tokens)
- **#477** — new `codedb_context` MCP tool (task-shaped composer)
- **#478** — `codedb_find` accepts `query` / `name` / `path` / `pattern` / `q` aliases (fixes 71% real-user failure rate)
- **#479** — `codedb_context` multi-line snippets + source-over-test ranking
- **#460** (cherry-picked from `release/v0.2.5814`) — `.codedbrc max_cached` wires through `ContentCache.init`
- This PR (#461 docs): `docs/mcp.md`, `docs/skills.md`, README pointers, TODOs.md

Cross-corpus eval ([code-search-shootout §18](https://github.com/justrach/code-search-shootout)) puts codedb ahead of codegraph on every axis: quality 4.62 vs 4.44, tokens 2.2× cheaper, wall 1.9× faster, calls 2.2× fewer, RSS lighter in every corpus.

---

## Open issues worth tackling next

- **#44** (pre-existing) — `snapshot stale after working tree changes cause stale query results`. Regression test `issue-44` lives in `src/test_snapshot.zig` and currently passes (suite green, 633/633); revisit if stale-snapshot query results resurface.
- **misc agents/clients still pass `q` / `pattern`** even after #478 — if support reports show this remains common after v0.2.5815 propagates, consider promoting `q` / `pattern` from "accepted" to "documented" in the tool description.
- **codedb_context paraphrasing edge cases** — bench eval still shows agents occasionally summarising the snippet field even with fenced multi-line context blocks. Two candidate followups: (1) explicit prompt-side instruction at the tool description level, (2) restructure the answer schema so the "trace" field is split from the "quote" field.

---

## Branch hygiene — needs maintainer call

After v0.2.5815 there are ~179 remote branches. Safe-to-delete buckets:

1. **Session feature branches (merged)** — confirmed reachable from `main`:
   - `perf-status-cache`, `perf-word-hot`, `perf-lean-defaults`
   - `feat-codedb-context`, `feat-codedb-context-quality`
   - `fix-codedb-find-aliases`
2. **Superseded release branches** — no tag was ever cut:
   - `release/v0.2.5814` (its only unique commit was cherry-picked into v0.2.5815)
3. **Tagged release branches** — tag is the source of truth; the branch is redundant:
   - `release/v0.2.3`, `release/v0.2.4`, `release/v0.2.5`, `release/v0.2.52`, `release/v0.2.55`, `release/v0.2.57`, `release/v0.2.571`, `release/v0.2.5798`, `release/v0.2.5799`, `release/v0.2.5813`
4. **Stale feature work** — 25+ `feat/`, `bench-`, `claude/`, `codex/`, `docs/` branches predating this session. **Maintainer review needed** before deletion — some may have unmerged WIP.

---

## Post-release checks

- `codedb_find` failure rate (was 71%, expected to drop near 0 once v0.2.5815 propagates)
- `codedb_context` adoption — how many sessions use it vs the older `codedb_search` + `codedb_symbol` chain
- `codedb_word` p50 / p99 latency — confirm the disk-persist path is hitting the cache after warmup
- `codedb_status` p99 — confirm cache TTL keeps it under 100 µs on a busy index
