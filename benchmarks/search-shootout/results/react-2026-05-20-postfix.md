# search-shootout — react

**Date:** 2026-05-20 12:24
**Corpus:** `/Users/dev/codedb-bench/react`
**Indexed files:** 6,619
**Corpus bytes:** 26.5 MB
**Iterations:** 15 warm

## Build phase

| Backend | Cold index time | On-disk size |
|---|---|---|
| codedb | 1.72s | 67.1 MB |

## Query latency (warm, ms)

> codedb: MCP stdio (one server, many calls).
> fts5_*: persistent SQLite connection.
> lean-ctx: per-call CLI spawn (includes ~700ms binary startup).
> Hit counts are NOT directly comparable across backends — use them as recall sanity (zero vs non-zero).

| query | kind | codedb p50 | codedb p99 | codedb hits |
|---|---|---|---|---|
| `useState` | common-identifier | 3.47 | 184.31 | 50 |
| `useEffect` | common-identifier | 3.09 | 271.54 | 50 |
| `forwardRef` | camelcase-identifier | 1.22 | 252.94 | 50 |
| `createElement` | camelcase-identifier | 2.16 | 237.79 | 50 |
| `Fiber` | substring-identifier | 1.40 | 469.44 | 50 |
| `Lane` | substring-identifier | 0.63 | 439.92 | 50 |
| `Suspense` | substring-identifier | 1.85 | 346.56 | 50 |
| `flushPassiveEffects` | rare-camelcase | 0.36 | 294.20 | 9 |
| `enableTransitionTracing` | rare-flag | 0.95 | 184.02 | 28 |
| `scheduleCallback` | camelcase-identifier | 1.07 | 288.61 | 39 |
| `concurrent` | lowercase-word | 1.43 | 206.59 | 50 |
| `function` | lang-keyword | 16.99 | 463.90 | 50 |
| `set` | short-trigram-exact | 3.80 | 213.23 | 50 |
| `ReactDOMRoot` | rare-camelcase | 0.37 | 220.33 | 12 |
| `xyzzy_react_does_not_exist` | negative | 0.29 | 252.61 | 0 |

