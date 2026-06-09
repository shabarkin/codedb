# search-shootout — react

**Date:** 2026-05-20 13:10
**Corpus:** `/Users/dev/codedb-bench/react`
**Indexed files:** 6,619
**Corpus bytes:** 26.5 MB
**Iterations:** 25 warm

## Build phase

| Backend | Cold index time | On-disk size |
|---|---|---|
| codedb | 1.11s | 67.1 MB |
| lean-ctx | 8.34s | — |

## Query latency (warm, ms)

> codedb: MCP stdio (one server, many calls).
> fts5_*: persistent SQLite connection.
> lean-ctx: per-call CLI spawn (includes ~700ms binary startup).
> Hit counts are NOT directly comparable across backends — use them as recall sanity (zero vs non-zero).

| query | kind | codedb p50 | codedb p99 | codedb hits | leanctx p50 | leanctx p99 | leanctx hits |
|---|---|---|---|---|---|---|---|
| `useState` | common-identifier | 3.74 | 310.79 | 50 | 40.04 | 43.72 | 20 |
| `useEffect` | common-identifier | 1.05 | 291.76 | 50 | 41.64 | 43.64 | 20 |
| `forwardRef` | camelcase-identifier | 0.29 | 241.65 | 50 | 44.43 | 46.68 | 20 |
| `createElement` | camelcase-identifier | 0.92 | 312.13 | 50 | 66.81 | 79.51 | 20 |
| `Fiber` | substring-identifier | 0.66 | 385.01 | 50 | 106.01 | 115.69 | 20 |
| `Lane` | substring-identifier | 0.48 | 664.59 | 50 | 119.88 | 126.95 | 20 |
| `Suspense` | substring-identifier | 0.56 | 333.40 | 50 | 41.96 | 44.42 | 20 |
| `flushPassiveEffects` | rare-camelcase | 0.46 | 418.34 | 9 | 160.47 | 182.63 | 20 |
| `enableTransitionTracing` | rare-flag | 0.46 | 177.24 | 28 | 154.85 | 166.62 | 20 |
| `scheduleCallback` | camelcase-identifier | 0.67 | 227.25 | 39 | 112.63 | 132.37 | 20 |
| `concurrent` | lowercase-word | 0.66 | 267.79 | 50 | 109.18 | 116.54 | 20 |
| `function` | lang-keyword | 15.76 | 481.71 | 50 | 44.10 | 44.96 | 20 |
| `set` | short-trigram-exact | 4.01 | 242.84 | 50 | 43.42 | 44.57 | 20 |
| `ReactDOMRoot` | rare-camelcase | 0.19 | 283.93 | 12 | 200.73 | 213.33 | 12 |
| `xyzzy_react_does_not_exist` | negative | 0.13 | 315.22 | 0 | 182.45 | 187.21 | 0 |

