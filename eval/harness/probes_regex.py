#!/usr/bin/env python3
"""Probe 1 — silent regex divergence.

Sends a battery of regex patterns to codedb_search {regex: true,
max_results: 10000, max_per_file: 10000} and compares each match set
against the declared oracle: Python `re` in BYTES mode, applied per-line
over exactly the files refpolicy.expected_indexed(root) returns.

The oracle mirrors codedb's documented line model byte-for-byte:
  - read raw file bytes (BOM kept, no decoding)
  - split on b'\\n' (trailing b'\\r' KEPT in the line slice; a file ending
    in b'\\n' yields a final empty line, same as std.mem.splitScalar)
  - a line matches if re.search finds ANY match (max one hit per line)
  - line numbers are 1-based

Pattern classes:
  A  ERROR-class  — codedb is expected to refuse ('error: invalid regex
     pattern', is_error). Refusal = passing ERROR_DISCLOSED check; the
     oracle accepting the same pattern is a disclosed capability gap
     (INFO note, not a failure). codedb silently returning results
     instead = HIGH divergence.
  B  SILENT-class — codedb parses the pattern but with wrong semantics
     (unknown escapes silently demoted to literal chars). Any match-set
     mismatch without an error = HIGH divergence.
  C  PARITY-class — constructs codedb supports; expect identical sets.
     Mismatch = HIGH divergence.

Discriminating content lives in regex/traps.txt (eval/make-corpus.sh,
LF-only so $ anchors are clean), but the oracle scans ALL expected-indexed
files for full honesty.
"""
import json
import os
import re
import subprocess
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import contract
import refpolicy
from driver import CodedbClient, parse_search, search_total

PROBE_ID = "1"
PROBE_NAME = "silent regex divergence"
ROOT = "synth"
SELF_MANAGED = False

RG = "/opt/homebrew/bin/rg"

# (class, label, pattern)
PATTERNS = [
    ("A", "lookahead", "foo(?=bar)"),
    ("A", "neg-lookahead", "foo(?!bar)"),
    ("A", "lookbehind", "(?<=foo)bar"),
    ("A", "neg-lookbehind", "(?<!foo)bar"),
    ("A", "named-group", "(?P<x>foo)bar"),
    ("A", "inline-flag", "(?i)foo"),
    ("A", "unicode-prop-braced", "\\p{L}+"),
    ("B", "backref", "(a)\\1"),
    ("B", "end-anchor-Z", "foo\\Z"),
    ("B", "unicode-prop-bare", "\\pL"),
    ("C", "word-boundary", "\\bword\\b"),
    ("C", "char-class", "[bc]at"),
    ("C", "counted-quant", "a{2,3}"),
    ("C", "noncap-alt", "(?:foo|bar)baz"),
    ("C", "digit-dot", "\\d+\\.\\d+"),
    ("C", "line-start", "^aa"),
    ("C", "line-end", "foo$"),
]

CODEDB_CALL_FMT = (
    "codedb_search {query: %r, regex: true, max_results: 10000, "
    "max_per_file: 10000}"
)
REFERENCE_FMT = (
    "python3 re (bytes mode), re.search per line (split on b'\\n', "
    "trailing b'\\r' kept), 1-based lines, over "
    "refpolicy.expected_indexed file set; pattern %r"
)


def _load_corpus_lines(root, notes):
    """Read every expected-indexed file once: [(relpath, [line bytes])]."""
    expected, excluded = refpolicy.expected_indexed(root)
    corpus = []
    for rel in expected:
        try:
            with open(os.path.join(root, rel), "rb") as fh:
                data = fh.read()
        except OSError as exc:
            notes.append(
                "oracle could not read expected file %r: %s" % (rel, exc)
            )
            continue
        corpus.append((rel, data.split(b"\n")))
    return corpus, expected, excluded


def _oracle_scan(corpus, pattern):
    """('error', msg, None) or ('hits', None, sorted ['path:line'])."""
    try:
        rx = re.compile(pattern.encode("utf-8"))
    except re.error as exc:
        return ("error", str(exc), None)
    hits = set()
    for rel, lines in corpus:
        for i, line in enumerate(lines, 1):
            if rx.search(line) is not None:
                hits.add("%s:%d" % (rel, i))
    return ("hits", None, sorted(hits))


def _codedb_search(client, pattern):
    """('error', text, None, raw_text) or ('hits', None, set, raw_text)."""
    res = client.call(
        "codedb_search",
        {
            "query": pattern,
            "regex": True,
            "max_results": 10000,
            "max_per_file": 10000,
        },
    )
    text = res["text"]
    if res["is_error"] or text.strip().lower().startswith("error"):
        return ("error", text.strip(), None, text)
    hits = contract.norm_hits(parse_search(text))
    return ("hits", None, hits, text)


def _truncation_divergences(text, n_hits):
    """Disclosed truncation markers -> MEDIUM; header/parsed mismatch
    without any marker -> TRUNCATED_UNDISCLOSED HIGH."""
    divs = []
    disclosed = (
        "truncated by per-file cap" in text
        or "(more matches truncated)" in text
    )
    if disclosed:
        divs.append(
            contract.divergence(
                "OTHER",
                "MEDIUM",
                "codedb disclosed per-file truncation despite "
                "max_per_file=10000 / max_results=10000",
                [r for r in text.splitlines() if "truncat" in r][:10],
            )
        )
    total = search_total(text)
    if total is not None and total != n_hits and not disclosed:
        divs.append(
            contract.divergence(
                "TRUNCATED_UNDISCLOSED",
                "HIGH",
                "search header declares %d results but %d rows parsed, "
                "no truncation marker" % (total, n_hits),
                [],
            )
        )
    return divs


def _set_divergences(codedb_hits, oracle_hits, severity, context):
    missing, extra = contract.diff_sets(codedb_hits, oracle_hits)
    divs = []
    if missing:
        divs.append(
            contract.divergence(
                "MISSING",
                severity,
                "%s: codedb lacks %d path:line hits the Python re oracle "
                "finds" % (context, len(missing)),
                missing,
            )
        )
    if extra:
        divs.append(
            contract.divergence(
                "EXTRA",
                severity,
                "%s: codedb reports %d path:line hits the Python re oracle "
                "does not find" % (context, len(extra)),
                extra,
            )
        )
    return divs


def _describe(kind, err, hits):
    if kind == "error":
        return "error (%s)" % (err or "").splitlines()[0]
    return "%d hits %s" % (len(hits), hits[:10])


def _rg_accepts(pattern, root):
    """Does rg --pcre2 accept the pattern? (capability-gap documentation
    only; never affects verdicts)."""
    try:
        proc = subprocess.run(
            [RG, "--pcre2", "-n", "--no-messages", pattern, "regex/"],
            cwd=root,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
        return proc.returncode in (0, 1)  # 2 = pattern/usage error
    except Exception:
        return None


def _check_class_a(label, pattern, codedb, oracle, notes):
    c_kind, c_err, c_hits, c_text = codedb
    o_kind, o_err, o_hits = oracle
    divs = []
    if c_kind == "error":
        detail = (
            "ERROR_DISCLOSED: codedb refused with %r (is_error). "
            "Oracle: %s."
            % (c_err, _describe(o_kind, o_err, o_hits))
        )
        if o_kind == "hits":
            notes.append(
                "capability gap (INFO, disclosed): codedb refuses %r which "
                "Python re accepts (oracle finds %d hits) — refusal is the "
                "safe behavior, not a failure" % (pattern, len(o_hits))
            )
        else:
            notes.append(
                "pattern %r rejected by BOTH codedb and Python re "
                "(codedb: %r, oracle: %s)" % (pattern, c_err, o_err)
            )
    else:
        detail = (
            "codedb silently ACCEPTED an unsupported construct: %s. "
            "Oracle: %s."
            % (
                _describe(c_kind, c_err, c_hits),
                _describe(o_kind, o_err, o_hits),
            )
        )
        if o_kind == "error":
            divs.append(
                contract.divergence(
                    "OTHER",
                    "HIGH",
                    "pattern %r: codedb silently returned %d results for a "
                    "pattern the Python re oracle rejects (%s) — no error, "
                    "no warning" % (pattern, len(c_hits), o_err),
                    c_hits,
                )
            )
        else:
            divs.extend(
                _set_divergences(
                    c_hits,
                    o_hits,
                    "HIGH",
                    "pattern %r silently accepted with wrong semantics"
                    % pattern,
                )
            )
            if not divs:
                divs.append(
                    contract.divergence(
                        "OTHER",
                        "MEDIUM",
                        "pattern %r: codedb accepted a construct expected "
                        "to error and the match set happens to agree with "
                        "the oracle — semantics unverified beyond this "
                        "corpus" % pattern,
                        c_hits,
                    )
                )
        divs.extend(_truncation_divergences(c_text, len(c_hits)))
    return divs, detail


def _check_class_b(label, pattern, codedb, oracle, notes):
    c_kind, c_err, c_hits, c_text = codedb
    o_kind, o_err, o_hits = oracle
    divs = []
    if c_kind == "error":
        detail = (
            "ERROR_DISCLOSED: codedb refused %r with %r instead of the "
            "expected silent literal fallback. Oracle: %s."
            % (pattern, c_err, _describe(o_kind, o_err, o_hits))
        )
        notes.append(
            "class-B pattern %r unexpectedly REFUSED by codedb (disclosed "
            "error — safe, but contradicts the documented silent-literal "
            "escape fallback)" % pattern
        )
        return divs, detail
    detail = "codedb: %s. Oracle: %s." % (
        _describe(c_kind, c_err, c_hits),
        _describe(o_kind, o_err, o_hits),
    )
    if o_kind == "error":
        divs.append(
            contract.divergence(
                "OTHER",
                "HIGH",
                "pattern %r: Python re oracle rejects it (%s) but codedb "
                "silently matched %d lines, treating the unknown escape as "
                "literal characters — no error, no warning"
                % (pattern, o_err, len(c_hits)),
                c_hits,
            )
        )
    else:
        divs.extend(
            _set_divergences(
                c_hits,
                o_hits,
                "HIGH",
                "pattern %r silently compiled with non-standard semantics "
                "(unknown escape demoted to literal)" % pattern,
            )
        )
    divs.extend(_truncation_divergences(c_text, len(c_hits)))
    return divs, detail


def _check_class_c(label, pattern, codedb, oracle, notes):
    c_kind, c_err, c_hits, c_text = codedb
    o_kind, o_err, o_hits = oracle
    divs = []
    if o_kind == "error":
        # should not happen for class C; surface loudly if it does
        detail = "oracle unexpectedly rejected %r: %s" % (pattern, o_err)
        notes.append(detail)
        return divs, detail
    if c_kind == "error":
        detail = (
            "codedb refused supported construct %r with %r; oracle finds "
            "%d hits" % (pattern, c_err, len(o_hits))
        )
        divs.append(
            contract.divergence(
                "MISSING",
                "MEDIUM",
                "pattern %r: codedb errored on a construct its own engine "
                "documents as supported (disclosed error, but a parity "
                "gap vs Python re)" % pattern,
                o_hits,
            )
        )
        return divs, detail
    detail = "codedb: %s. Oracle: %s." % (
        _describe(c_kind, c_err, c_hits),
        _describe(o_kind, o_err, o_hits),
    )
    divs.extend(
        _set_divergences(
            c_hits,
            o_hits,
            "HIGH",
            "supported construct %r" % pattern,
        )
    )
    divs.extend(_truncation_divergences(c_text, len(c_hits)))
    return divs, detail


_CLASS_FN = {"A": _check_class_a, "B": _check_class_b, "C": _check_class_c}


def run(client, root, info):
    checks = []
    notes = []
    try:
        corpus, expected, excluded = _load_corpus_lines(root, notes)
        notes.append(
            "oracle scanned %d expected-indexed files (%d excluded by "
            "refpolicy)" % (len(corpus), len(excluded))
        )
        if not any(rel == contract.REGEX_TRAPS_FILE for rel, _ in corpus):
            notes.append(
                "WARNING: %s not in expected-indexed set — discriminating "
                "lines unavailable" % contract.REGEX_TRAPS_FILE
            )
        for cls, label, pattern in PATTERNS:
            check_id = "regex-%s-%s" % (cls, label)
            try:
                oracle = _oracle_scan(corpus, pattern)
                codedb = _codedb_search(client, pattern)
                divs, detail = _CLASS_FN[cls](
                    label, pattern, codedb, oracle, notes
                )
            except Exception:
                divs = [
                    contract.divergence(
                        "OTHER",
                        "HIGH",
                        "probe exception on pattern %r (probe error, not a "
                        "measured codedb divergence)" % pattern,
                        [],
                    )
                ]
                detail = "probe exception"
                notes.append(
                    "traceback for %s:\n%s"
                    % (check_id, traceback.format_exc())
                )
            checks.append(
                contract.make_check(
                    check_id,
                    CODEDB_CALL_FMT % pattern,
                    REFERENCE_FMT % pattern,
                    divs,
                    detail,
                )
            )
        # capability documentation: is \p{L}+ valid PCRE2 even though both
        # codedb and Python re reject it?
        rg_ok = _rg_accepts("\\p{L}+", root)
        if rg_ok is not None:
            notes.append(
                "rg --pcre2 %s pattern '\\p{L}+' (documentation only: the "
                "declared oracle is Python re, which rejects it)"
                % ("ACCEPTS" if rg_ok else "rejects")
            )
    except Exception:
        checks.append(
            contract.make_check(
                "regex-fatal",
                "probe body",
                "n/a",
                [
                    contract.divergence(
                        "OTHER",
                        "HIGH",
                        "probe crashed before completing (probe error, not "
                        "a measured codedb divergence)",
                        [],
                    )
                ],
                "fatal probe exception — see notes",
            )
        )
        notes.append("fatal traceback:\n%s" % traceback.format_exc())
    return contract.make_result(PROBE_ID, PROBE_NAME, root, checks, notes)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: probes_regex.py <corpus-root>", file=sys.stderr)
        sys.exit(2)
    root_arg = os.path.abspath(sys.argv[1])
    client = CodedbClient(root_arg)
    try:
        client.wait_ready()
        minimal_info = {
            "synth_root": root_arg,
            "codex_root": None,
            "codedb_sha": "803db6b",
            "codex_sha": None,
            "binary": client.binary,
        }
        result = run(client, root_arg, minimal_info)
    finally:
        client.close()
    print(json.dumps(result, indent=2, ensure_ascii=False))
