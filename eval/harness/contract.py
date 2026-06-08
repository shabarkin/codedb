#!/usr/bin/env python3
"""Shared contract for codedb trust probes.

Every probe module exposes:
    PROBE_ID   = <int>              # 1..10 (or string like "symbols")
    PROBE_NAME = "<short name>"
    ROOT       = "synth" | "codex"  # which corpus the probe runs against
    SELF_MANAGED = False            # True -> run(make_client, root, info)
                                    # gets a factory and may restart servers
    def run(client, root, info) -> dict   # client: open, scan-ready CodedbClient

run() returns a dict shaped like make_result() below. NEVER let an exception
escape — catch, and return a result with verdict "ERROR" and the traceback in
notes, so one broken probe cannot sink the run.

Divergence taxonomy (plan Phase C):
    MISSING                 codedb lacks a path/line the reference finds
    EXTRA                   codedb reports a path/line the reference does not
    LINE_OFF                same file, line numbers differ
    ORDER                   same set, unstable/different ordering
    TRUNCATED_UNDISCLOSED   results silently capped, no marker/total
    IGNORE_SEMANTICS        ignore/skip rules diverge from git/docs
    STALE                   stale data served with no staleness signal
    ERROR_DISCLOSED         codedb refused with an explicit error (GOOD case)
    OTHER

Severity guidance: divergence matching a DOCUMENTED design choice -> "INFO";
silent wrongness -> "HIGH"; disclosed-but-surprising -> "MEDIUM".
"""

# --- canonical corpus token map (eval/make-corpus.sh) -----------------------
# token -> (relpath, 1-based line) where the token lives. Line numbers are
# load-bearing ground truth for LINE_OFF checks.
SYNTH_TOKENS = {
    "NEEDLE_CONTROL":          ("control.c", 2),
    "NEEDLE_NFC_CAFE":         ("unicode/nfc/caf\u00e9.py", 2),   # NFC name (escape = exact bytes)
    "NEEDLE_NFD_CAFE":         ("unicode/nfd/cafe\u0301.py", 2),  # NFD name (escape = exact bytes)
    "NEEDLE_JAPANESE":         ("unicode/日本語.ts", 1),
    "NEEDLE_BOM_L3":           ("encodings/bom.txt", 3),
    "NEEDLE_CRLF_L5":          ("encodings/crlf.txt", 5),
    "NEEDLE_MIXED_L6":         ("encodings/mixed.txt", 6),
    "NEEDLE_NOEOL_L3":         ("encodings/noeol.txt", 3),
    "NEEDLE_UNDER_CAP_START":  ("sizes/under-cap-511kb.txt", 1),
    "NEEDLE_OVER_CAP_START":   ("sizes/over-cap-600kb.txt", 1),       # >512KB: skipped by design
    "NEEDLE_NULLAT600_EARLY":  ("sizes/null-at-600.txt", 1),   # on lines 1-10; NUL at 600 defeats sniff
    "NEEDLE_NULLAT600_LATE":   ("sizes/null-at-600.txt", 12),  # byte-derived (post-NUL line)
    "NEEDLE_PNG_AS_TXT":       ("sizes/image-renamed.txt", 1),        # NUL in head: skipped
    "TOKEN_DEBUG_LOG":         ("gitignore-battery/logs/debug.log", 1),        # gitignored
    "TOKEN_IMPORTANT_LOG":     ("gitignore-battery/logs/important.log", 1),    # negation-rescued
    "TOKEN_BUILD_DIRONLY":     ("gitignore-battery/build/keep.c", 1),          # ignored + skip_dir
    "TOKEN_BUILD_FILE":        ("gitignore-battery/subdir-holder.txt", 1),
    "TOKEN_BUILD_PLAINFILE":   ("gitignore-battery/filetrap/build", 1),        # FILE named build
    "TOKEN_OUTDIR":            ("gitignore-battery/outdir/artifact.c", 1),     # gitignored only
    "TOKEN_GENERATED":         ("gitignore-battery/deep/nested/generated/gen.c", 1),
    "TOKEN_GITIGNORE_VISIBLE": ("gitignore-battery/visible.c", 1),
    "NEEDLE_OUTSIDE_ROOT":     ("symlinks/escape-link", 1),           # out-of-root: dropped
    "NEEDLE_BUILD_DIR_SOURCE": ("Build/real_code.c", 2),              # skip_dir prunes (case-insens)
    "NEEDLE_CARGO_LOCK":       ("Cargo.lock", 5),                     # .lock ext: skipped
}

REGEX_TRAPS_FILE = "regex/traps.txt"   # content: see eval/make-corpus.sh

# --- result shape ------------------------------------------------------------

VERDICTS = ("PARITY", "PARTIAL", "DIVERGENT", "ERROR")


def make_result(probe_id, name, corpus_root, checks, notes=None):
    """checks: list of make_check() dicts. Verdict derivation: any silent
    HIGH divergence -> DIVERGENT; only INFO/MEDIUM (documented/disclosed)
    divergences -> PARTIAL; none -> PARITY."""
    sev = [d["severity"] for c in checks for d in c["divergences"]]
    if any(s == "HIGH" for s in sev):
        verdict = "DIVERGENT"
    elif sev:
        verdict = "PARTIAL"
    else:
        verdict = "PARITY"
    return {
        "probe": probe_id,
        "name": name,
        "corpus": corpus_root,
        "checks": checks,
        "verdict": verdict,
        "notes": notes or [],
    }


def make_check(check_id, codedb_call, reference_cmd, divergences, detail=""):
    return {
        "id": check_id,
        "codedb": codedb_call,
        "reference": reference_cmd,
        "divergences": divergences,
        "pass": not divergences,
        "detail": detail,
    }


def divergence(dtype, severity, detail, examples=None):
    assert severity in ("INFO", "MEDIUM", "HIGH")
    return {
        "type": dtype,
        "severity": severity,
        "detail": detail,
        "examples": (examples or [])[:10],
    }


# --- normalization helpers ----------------------------------------------------


def norm_hits(hits):
    """[(path, line, content)] -> sorted set of 'path:line' strings."""
    return sorted({"%s:%d" % (p, ln) for (p, ln, *_rest) in hits})


def diff_sets(codedb_set, ref_set):
    """Both sorted lists/sets of 'path:line'. Returns (missing, extra)."""
    c, r = set(codedb_set), set(ref_set)
    return sorted(r - c), sorted(c - r)


def parse_rg_lines(output):
    """rg -n output 'path:line:content' -> [(path, line, content)]."""
    hits = []
    for row in output.splitlines():
        if not row:
            continue
        parts = row.split(":", 2)
        if len(parts) < 2 or not parts[1].isdigit():
            continue
        hits.append((parts[0], int(parts[1]), parts[2] if len(parts) > 2 else ""))
    return hits
