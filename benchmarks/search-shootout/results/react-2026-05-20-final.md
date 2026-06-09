# search-shootout — react

**Date:** 2026-05-20 18:12
**Corpus:** `/Users/dev/codedb-bench/react`
**Indexed files:** 6,619
**Corpus bytes:** 26.5 MB
**Iterations:** 500 warm × 3 sessions (median-of-medians)

## Build phase

| Backend | Cold index time | On-disk size |
|---|---|---|
| fts5_trigram | 1.73s | 93.5 MB |
| fts5_unicode61 | 0.44s | 36.3 MB |
| codedb | 1.02s | 67.1 MB |
| lean-ctx | 8.35s | — |

## Query latency (warm, ms)

> codedb: MCP stdio (one server, many calls).
> fts5_*: persistent SQLite connection.
> lean-ctx: per-call CLI spawn (includes ~700ms binary startup).
> Hit counts are NOT directly comparable across backends — use them as recall sanity (zero vs non-zero).

| query | kind | fts5_tri min | fts5_tri p50 | fts5_tri p95 | fts5_tri p99 | fts5_tri hits | fts5_uni min | fts5_uni p50 | fts5_uni p95 | fts5_uni p99 | fts5_uni hits | codedb min | codedb p50 | codedb p95 | codedb p99 | codedb hits | leanctx min | leanctx p50 | leanctx p95 | leanctx p99 | leanctx hits |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `useState` | common-identifier | 0.81 | 0.83 | 1.18 | 2.22 | 674 | 0.02 | 0.02 | 0.02 | 0.02 | 674 | 1.57 | 1.63 | 1.74 | 1.81 | 50 | 44.13 | 47.68 | 64.09 | 65.95 | 20 |
| `useEffect` | common-identifier | 0.41 | 0.42 | 0.44 | 0.46 | 434 | 0.01 | 0.01 | 0.01 | 0.02 | 426 | 0.87 | 0.92 | 0.98 | 1.03 | 50 | 44.22 | 47.74 | 64.03 | 66.64 | 20 |
| `forwardRef` | camelcase-identifier | 0.17 | 0.19 | 0.19 | 0.21 | 129 | 0.01 | 0.01 | 0.01 | 0.01 | 127 | 0.24 | 0.26 | 0.28 | 0.29 | 50 | 46.10 | 49.95 | 66.67 | 69.01 | 20 |
| `createElement` | camelcase-identifier | 1.02 | 1.06 | 1.12 | 1.19 | 403 | 0.01 | 0.01 | 0.01 | 0.02 | 401 | 0.75 | 0.80 | 0.89 | 0.95 | 50 | 70.06 | 74.46 | 93.96 | 99.97 | 20 |
| `Fiber` | substring-identifier | 0.13 | 0.14 | 0.15 | 0.15 | 303 | 0.01 | 0.01 | 0.01 | 0.01 | 180 | 0.26 | 0.30 | 0.32 | 0.37 | 50 | 108.08 | 112.64 | 137.88 | 144.45 | 20 |
| `Lane` | substring-identifier | 0.05 | 0.06 | 0.07 | 0.07 | 72 | 0.01 | 0.01 | 0.01 | 0.01 | 40 | 0.14 | 0.16 | 0.18 | 0.26 | 50 | 124.91 | 128.34 | 153.88 | 159.34 | 20 |
| `Suspense` | substring-identifier | 0.40 | 0.41 | 0.42 | 0.46 | 314 | 0.01 | 0.01 | 0.01 | 0.01 | 259 | 0.39 | 0.45 | 0.47 | 0.52 | 50 | 44.17 | 48.01 | 64.28 | 68.12 | 20 |
| `flushPassiveEffects` | rare-camelcase | 0.20 | 0.22 | 0.22 | 0.24 | 8 | 0.01 | 0.01 | 0.01 | 0.01 | 7 | 0.07 | 0.08 | 0.09 | 0.12 | 9 | 163.84 | 167.87 | 191.78 | 198.92 | 20 |
| `enableTransitionTracing` | rare-flag | 0.72 | 0.73 | 0.76 | 0.82 | 25 | 0.01 | 0.01 | 0.01 | 0.01 | 25 | 0.16 | 0.19 | 0.22 | 0.34 | 28 | 160.69 | 165.63 | 220.65 | 232.77 | 20 |
| `scheduleCallback` | camelcase-identifier | 0.43 | 0.44 | 0.46 | 0.48 | 22 | 0.01 | 0.01 | 0.01 | 0.01 | 22 | 0.15 | 0.17 | 0.19 | 0.27 | 39 | 114.62 | 120.10 | 165.88 | 171.19 | 20 |
| `concurrent` | lowercase-word | 0.41 | 0.43 | 0.45 | 0.47 | 127 | 0.01 | 0.01 | 0.01 | 0.01 | 75 | 0.21 | 0.25 | 0.27 | 0.36 | 50 | 113.02 | 118.47 | 160.15 | 167.94 | 20 |
| `function` | lang-keyword | 1.76 | 1.79 | 1.85 | 1.91 | 5286 | 0.08 | 0.09 | 0.09 | 0.09 | 5245 | 15.74 | 16.47 | 17.25 | 17.53 | 50 | 46.94 | 50.27 | 70.75 | 71.66 | 20 |
| `set` | short-trigram-exact | 0.04 | 0.04 | 0.04 | 0.05 | 2038 | 0.02 | 0.02 | 0.02 | 0.02 | 851 | 3.22 | 3.44 | 3.61 | 3.69 | 50 | 45.21 | 50.77 | 70.78 | 76.43 | 20 |
| `ReactDOMRoot` | rare-camelcase | 0.14 | 0.15 | 0.18 | 0.20 | 8 | 0.01 | 0.01 | 0.01 | 0.01 | 6 | 0.07 | 0.08 | 0.10 | 0.17 | 12 | 195.41 | 200.42 | 240.47 | 256.67 | 12 |
| `xyzzy_react_does_not_exist` | negative | 0.20 | 0.21 | 0.22 | 0.24 | 0 | 0.03 | 0.03 | 0.04 | 0.04 | 0 | 0.03 | 0.03 | 0.04 | 0.07 | 0 | 186.89 | 190.70 | 224.65 | 242.25 | 0 |

## Normalized files-list comparison

Each backend asked the same question: return the SET of files containing the query.
`agree` is the pairwise Jaccard similarity (1.00 = all backends agree on the set).

| query | codedb files | fts5_tri files | fts5_uni files | leanctx files | agree-jaccard |
|---|---|---|---|---|---|
| `useState` | 716 | 674 | 674 | 719 | 0.957 |
| `useEffect` | 436 | 434 | 426 | 443 | 0.964 |
| `forwardRef` | 129 | 129 | 127 | 99 | 0.866 |
| `createElement` | 403 | 403 | 401 | 407 | 0.989 |
| `Fiber` | 275 | 303 | 180 | 248 | 0.731 |
| `Lane` | 69 | 72 | 40 | 53 | 0.671 |
| `Suspense` | 310 | 314 | 259 | 294 | 0.883 |
| `flushPassiveEffects` | 8 | 8 | 7 | 7 | 0.917 |
| `enableTransitionTracing` | 25 | 25 | 25 | 25 | 1.000 |
| `scheduleCallback` | 22 | 22 | 22 | 22 | 1.000 |
| `concurrent` | 118 | 127 | 75 | 92 | 0.630 |
| `function` | 5328 | 5286 | 5245 | 5341 | 0.981 |
| `set` | 1614 | 2038 | 851 | 1837 | 0.599 |
| `ReactDOMRoot` | 8 | 8 | 6 | 8 | 0.875 |
| `xyzzy_react_does_not_exist` | 0 | 0 | 0 | 0 | 1.000 |

