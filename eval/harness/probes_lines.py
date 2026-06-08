#!/usr/bin/env python3
"""Probe 3+8: CRLF/BOM line-number fidelity + binary (NUL) misdetection.

Probe 3 — line-number fidelity on encoding-trap files (BOM, CRLF, mixed
line endings, missing trailing newline): codedb_search literal hits must
land on the exact ground-truth (path, line) from contract.SYNTH_TOKENS,
cross-checked against rg -n -F. Also exercises codedb_read \r/BOM
retention, regex $/^ anchor semantics on CRLF/BOM files (3-way against
rg default and rg --crlf), and codedb_tree line_count metadata vs wc -l.

Probe 8 — sizes/null-at-600.txt has its first NUL byte at offset 600,
past codedb's 512-byte binary sniff window, so codedb indexes it as
text. Ground-truth line numbers are computed from the raw file bytes
(NOT from contract.SYNTH_TOKENS, whose NEEDLE_NULLAT600_LATE entry says
line 2 while the real token is on line 12). codedb hits are checked for
line fidelity against rg -n -F -a, and for disclosure against rg
default, which flags the file as binary. sizes/image-renamed.txt (PNG
bytes, NUL in head) must yield zero hits — parity with rg default.
"""
import json
import os
import re
import subprocess
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from contract import (
    SYNTH_TOKENS,
    diff_sets,
    divergence,
    make_check,
    make_result,
    norm_hits,
    parse_rg_lines,
)
from driver import parse_search

PROBE_ID = "3+8"
PROBE_NAME = "CRLF/BOM line numbers + binary misdetection"
ROOT = "synth"
SELF_MANAGED = False

RG = "/opt/homebrew/bin/rg"

LINE_TOKENS = (
    "NEEDLE_BOM_L3",
    "NEEDLE_CRLF_L5",
    "NEEDLE_MIXED_L6",
    "NEEDLE_NOEOL_L3",
)

NULL_FILE = "sizes/null-at-600.txt"
PNG_FILE = "sizes/image-renamed.txt"

_READ_LINE_RE = re.compile(r"^ *(\d+) \| ")


# --- reference-command helpers -----------------------------------------------


def _run(cmd, cwd=None):
    """Run a read-only reference command; never raises on nonzero exit."""
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return proc.returncode, proc.stdout, proc.stderr


def _rg(args, root):
    """rg with deterministic flags, cwd=root. Returns (rc, text)."""
    cmd = [RG, "--no-config"] + args
    rc, out, _err = _run(cmd, cwd=root)
    return rc, out.decode("utf-8", "replace")


def _rg_hits(args, root):
    """rg -n ... '.' -> normalized ['path:line'] with './' stripped."""
    rc, text = _rg(args, root)
    hits = parse_rg_lines(text)
    cleaned = [
        (p[2:] if p.startswith("./") else p, ln, c) for (p, ln, c) in hits
    ]
    return rc, norm_hits(cleaned), cleaned


def _read_range_payload(text):
    """codedb_read range output -> (line_no, content) of the first body row.

    Format: 'hash:<hex>\\n{d:>5} | <content>\\n'. Manual split on the first
    '\\n' only — content may carry a trailing \\r that splitlines() would eat.
    """
    nl = text.find("\n")
    if nl == -1:
        return None, None
    body = text[nl + 1 :]
    if body.endswith("\n"):
        body = body[:-1]
    m = _READ_LINE_RE.match(body)
    if not m:
        return None, body
    return int(m.group(1)), body[m.end() :]


def _null_file_ground_truth(root):
    """Line numbers of the two NULLAT600 tokens, computed from raw bytes."""
    raw = open(os.path.join(root, NULL_FILE), "rb").read()
    early, late = [], []
    for i, line in enumerate(raw.split(b"\n"), 1):
        if b"NEEDLE_NULLAT600_EARLY" in line:
            early.append(i)
        if b"NEEDLE_NULLAT600_LATE" in line:
            late.append(i)
    return raw, early, late


# --- probe 3 checks ------------------------------------------------------------


def _check_token_lines(client, root, checks, notes):
    for token in LINE_TOKENS:
        relpath, gt_line = SYNTH_TOKENS[token]
        expect = ["%s:%d" % (relpath, gt_line)]

        resp = client.call(
            "codedb_search",
            {"query": token, "max_results": 10000, "max_per_file": 10000},
        )
        cdb_hits = parse_search(resp["text"])
        cdb_set = norm_hits(cdb_hits)

        rc, rg_set, _rg_rows = _rg_hits(
            ["-n", "-F", "-g", "!codedb.snapshot", token, "."], root
        )
        if rc not in (0, 1):
            notes.append("rg error (rc=%d) for token %s" % (rc, token))
        if rg_set != expect:
            notes.append(
                "oracle dispute: rg -n -F %s found %r, ground truth %r"
                % (token, rg_set, expect)
            )

        divs = []
        if cdb_set != expect:
            missing, extra = diff_sets(cdb_set, expect)
            same_file_off = [
                e for e in extra if e.split(":")[0] == relpath
            ]
            if same_file_off and missing:
                divs.append(
                    divergence(
                        "LINE_OFF",
                        "HIGH",
                        "codedb reports %s in the right file but on the "
                        "wrong line (ground truth %s:%d); silent, no "
                        "documented policy explains it"
                        % (same_file_off, relpath, gt_line),
                        examples=missing + extra,
                    )
                )
            else:
                if missing:
                    divs.append(
                        divergence(
                            "MISSING",
                            "HIGH",
                            "codedb misses ground-truth hit for %s" % token,
                            examples=missing,
                        )
                    )
                if extra:
                    divs.append(
                        divergence(
                            "EXTRA",
                            "HIGH",
                            "codedb reports hits beyond ground truth for %s"
                            % token,
                            examples=extra,
                        )
                    )
        detail = "codedb=%r rg=%r ground_truth=%r" % (cdb_set, rg_set, expect)
        if token == "NEEDLE_CRLF_L5" and "here\r\n" in resp["text"]:
            detail += (
                "; raw search row retains the trailing \\r of the CRLF line "
                "(byte-faithful, same as rg)"
            )
        checks.append(
            make_check(
                "p3.token.%s" % token,
                "codedb_search {query:%r, max_results:10000, "
                "max_per_file:10000}" % token,
                "rg -n -F -g '!codedb.snapshot' %s . (cwd=root)" % token,
                divs,
                detail,
            )
        )


def _check_read_crlf(client, root, checks, notes):
    resp = client.call(
        "codedb_read",
        {"path": "encodings/crlf.txt", "line_start": 5, "line_end": 5},
    )
    line_no, content = _read_range_payload(resp["text"])
    rc, sed_out, _ = _run(["sed", "-n", "5p", "encodings/crlf.txt"], cwd=root)
    sed_line = sed_out.decode("utf-8", "replace")
    if sed_line.endswith("\n"):
        sed_line = sed_line[:-1]  # keep any \r — sed emits raw bytes

    divs = []
    detail = "codedb line %r content=%r; sed -n 5p (sans \\n)=%r" % (
        line_no,
        content,
        sed_line,
    )
    if resp["is_error"] or content is None:
        divs.append(
            divergence(
                "OTHER",
                "HIGH",
                "codedb_read failed for a 1-line range read: %r"
                % resp["text"][:200],
            )
        )
    else:
        if line_no != 5 or content.rstrip("\r") != sed_line.rstrip("\r"):
            divs.append(
                divergence(
                    "LINE_OFF",
                    "HIGH",
                    "codedb_read line 5 of crlf.txt does not match sed -n 5p",
                    examples=["codedb=%r" % content, "sed=%r" % sed_line],
                )
            )
        if content is not None and content.endswith("\r"):
            divs.append(
                divergence(
                    "OTHER",
                    "INFO",
                    "codedb_read returns the trailing \\r of a CRLF line "
                    "verbatim in the line body (byte-faithful; identical to "
                    "sed -n 5p raw bytes). Agents diffing against "
                    "display-normalized text may see a phantom trailing "
                    "character.",
                    examples=[repr(content)],
                )
            )
    checks.append(
        make_check(
            "p3.read.crlf",
            "codedb_read {path:'encodings/crlf.txt', line_start:5, "
            "line_end:5}",
            "sed -n 5p encodings/crlf.txt (raw bytes)",
            divs,
            detail,
        )
    )


def _check_read_bom(client, root, checks, notes):
    resp = client.call(
        "codedb_read",
        {"path": "encodings/bom.txt", "line_start": 1, "line_end": 1},
    )
    line_no, content = _read_range_payload(resp["text"])
    rc, sed_out, _ = _run(["sed", "-n", "1p", "encodings/bom.txt"], cwd=root)
    sed_line = sed_out.decode("utf-8", "replace")
    if sed_line.endswith("\n"):
        sed_line = sed_line[:-1]

    divs = []
    detail = "codedb line %r content=%r; sed -n 1p (sans \\n)=%r" % (
        line_no,
        content,
        sed_line,
    )
    if resp["is_error"] or content is None:
        divs.append(
            divergence(
                "OTHER",
                "HIGH",
                "codedb_read failed for a 1-line range read: %r"
                % resp["text"][:200],
            )
        )
    else:
        if line_no != 1 or content.lstrip("\ufeff") != sed_line.lstrip(
            "\ufeff"
        ):
            divs.append(
                divergence(
                    "LINE_OFF",
                    "HIGH",
                    "codedb_read line 1 of bom.txt does not match sed -n 1p",
                    examples=["codedb=%r" % content, "sed=%r" % sed_line],
                )
            )
        if content is not None and content.startswith("\ufeff"):
            divs.append(
                divergence(
                    "OTHER",
                    "INFO",
                    "codedb_read returns the UTF-8 BOM verbatim at the start "
                    "of line 1 (byte-faithful; identical to sed raw bytes; "
                    "rg strips the BOM before matching). A consumer "
                    "comparing line text against BOM-stripped sources sees "
                    "an invisible leading character.",
                    examples=[repr(content[:20])],
                )
            )
    checks.append(
        make_check(
            "p3.read.bom",
            "codedb_read {path:'encodings/bom.txt', line_start:1, "
            "line_end:1}",
            "sed -n 1p encodings/bom.txt (raw bytes)",
            divs,
            detail,
        )
    )


def _check_regex_crlf_anchor(client, root, checks, notes):
    pattern = "crlf NEEDLE_CRLF_L5 here$"
    resp = client.call(
        "codedb_search",
        {
            "query": pattern,
            "regex": True,
            "max_results": 10000,
            "max_per_file": 10000,
        },
    )
    cdb_set = norm_hits(parse_search(resp["text"]))

    rc_def, rg_def_set, _ = _rg_hits(
        ["-n", "-g", "!codedb.snapshot", pattern, "."], root
    )
    rc_crlf, rg_crlf_set, _ = _rg_hits(
        ["-n", "--crlf", "-g", "!codedb.snapshot", pattern, "."], root
    )

    divs = []
    detail = (
        "codedb(regex)=%r; rg default=%r (rc=%d); rg --crlf=%r (rc=%d). "
        "Ground truth: the literal text sits on encodings/crlf.txt:5 with a "
        "\\r before the newline."
        % (cdb_set, rg_def_set, rc_def, rg_crlf_set, rc_crlf)
    )
    missing_vs_crlf, _extra = diff_sets(cdb_set, rg_crlf_set)
    if missing_vs_crlf:
        divs.append(
            divergence(
                "MISSING",
                "MEDIUM",
                "codedb regex '$' fails to match CRLF lines because the "
                "trailing \\r is kept in the line slice; rg --crlf matches "
                "(encodings/crlf.txt:5). codedb agrees with rg's DEFAULT "
                "mode (which also misses), but rg offers --crlf as an "
                "escape hatch while codedb has none — '$' is silently "
                "unable to match any line of a CRLF file.",
                examples=missing_vs_crlf,
            )
        )
    if cdb_set != rg_def_set:
        divs.append(
            divergence(
                "OTHER",
                "MEDIUM",
                "codedb regex disagrees with rg default mode too "
                "(unexpected)",
                examples=sorted(set(cdb_set) ^ set(rg_def_set)),
            )
        )
    checks.append(
        make_check(
            "p3.regex.crlf_anchor",
            "codedb_search {query:%r, regex:true, max_results:10000, "
            "max_per_file:10000}" % pattern,
            "rg -n %r . ; rg -n --crlf %r . (cwd=root)" % (pattern, pattern),
            divs,
            detail,
        )
    )


def _check_regex_bom_anchor(client, root, checks, notes):
    pattern = "^bom line one"
    resp = client.call(
        "codedb_search",
        {
            "query": pattern,
            "regex": True,
            "max_results": 10000,
            "max_per_file": 10000,
        },
    )
    cdb_set = norm_hits(parse_search(resp["text"]))

    rc_def, rg_def_set, _ = _rg_hits(
        ["-n", "-g", "!codedb.snapshot", pattern, "."], root
    )

    divs = []
    detail = (
        "codedb(regex)=%r; rg default=%r (rc=%d). Ground truth: "
        "'bom line one' is line 1 of encodings/bom.txt, preceded by a "
        "UTF-8 BOM (EF BB BF)." % (cdb_set, rg_def_set, rc_def)
    )
    missing, extra = diff_sets(cdb_set, rg_def_set)
    if missing:
        divs.append(
            divergence(
                "MISSING",
                "MEDIUM",
                "codedb regex '^' fails to match line 1 of a BOM-prefixed "
                "file because the BOM bytes are kept in the line slice; rg "
                "auto-strips the UTF-8 BOM and matches "
                "encodings/bom.txt:1. No codedb option exists to strip or "
                "skip the BOM, so '^'-anchored patterns silently never "
                "match the first line of BOM files.",
                examples=missing,
            )
        )
    if extra:
        divs.append(
            divergence(
                "EXTRA",
                "MEDIUM",
                "codedb regex reports hits rg does not for %r" % pattern,
                examples=extra,
            )
        )
    checks.append(
        make_check(
            "p3.regex.bom_anchor",
            "codedb_search {query:%r, regex:true, max_results:10000, "
            "max_per_file:10000}" % pattern,
            "rg -n %r . (cwd=root; rg auto-strips UTF-8 BOM)" % pattern,
            divs,
            detail,
        )
    )


def _check_tree_linecounts(client, root, checks, notes):
    import treeparse

    resp = client.call("codedb_tree", {})
    tree = {t[0]: t for t in treeparse.tree_files(resp["text"])}

    targets = ["encodings/crlf.txt", "encodings/bom.txt", "encodings/mixed.txt"]
    rows = []
    offenders = []
    for rel in targets + ["encodings/noeol.txt"]:
        rc, wc_out, _ = _run(["wc", "-l", rel], cwd=root)
        try:
            wc_lines = int(wc_out.split()[0])
        except (IndexError, ValueError):
            wc_lines = None
        entry = tree.get(rel)
        tree_lines = entry[2] if entry else None
        rows.append("%s: tree=%sL wc=%s" % (rel, tree_lines, wc_lines))
        if rel in targets and entry is not None and wc_lines is not None:
            if tree_lines != wc_lines:
                offenders.append(
                    "%s tree=%d wc=%d (delta %+d)"
                    % (rel, tree_lines, wc_lines, tree_lines - wc_lines)
                )
        if entry is None:
            notes.append("codedb_tree missing expected file %s" % rel)

    divs = []
    if offenders:
        divs.append(
            divergence(
                "OTHER",
                "INFO",
                "codedb_tree line_count is newline_count+1 for non-empty "
                "files (split-parts convention): every newline-terminated "
                "file reports one more line than wc -l (a phantom empty "
                "trailing line). The same convention makes noeol.txt "
                "correct at 3 lines where wc -l undercounts (2). "
                "Undocumented but internally consistent; an agent trusting "
                "'NL' metadata and requesting the last line gets an empty "
                "line.",
                examples=offenders,
            )
        )
    checks.append(
        make_check(
            "p3.tree.linecounts",
            "codedb_tree {} -> line_count column for encodings/*.txt",
            "wc -l encodings/{crlf,bom,mixed,noeol}.txt",
            divs,
            "; ".join(rows),
        )
    )


# --- probe 8 checks ------------------------------------------------------------


def _check_null_file(client, root, checks, notes):
    raw, gt_early, gt_late = _null_file_ground_truth(root)
    nul_off = raw.index(b"\x00") if b"\x00" in raw else -1
    notes.append(
        "%s: %d bytes, first NUL at offset %d; byte-derived ground truth: "
        "EARLY lines %s, LATE lines %s (contract.SYNTH_TOKENS claims LATE "
        "at line 2 — stale; worked around locally)"
        % (NULL_FILE, len(raw), nul_off, gt_early, gt_late)
    )

    cases = (
        (
            "early",
            "NEEDLE_NULLAT600_EARLY",
            gt_early,
            "pre-null padding line with NEEDLE_NULLAT600_EARLY token",
        ),
        (
            "late",
            "NEEDLE_NULLAT600_LATE",
            gt_late,
            "post-null text with NEEDLE_NULLAT600_LATE token",
        ),
    )

    rg_default_binary = None
    for short, token, gt_lines, expect_content in cases:
        expect = sorted("%s:%d" % (NULL_FILE, n) for n in gt_lines)

        resp = client.call(
            "codedb_search",
            {"query": token, "max_results": 10000, "max_per_file": 10000},
        )
        cdb_hits = parse_search(resp["text"])
        cdb_set = norm_hits(cdb_hits)

        rc_def, def_text = _rg(["-n", "-F", token, NULL_FILE], root)
        is_binary_msg = "binary file matches" in def_text
        if rg_default_binary is None:
            rg_default_binary = is_binary_msg
        rc_a, rg_a_set, _ = _rg_hits(
            ["-n", "-H", "-F", "-a", token, NULL_FILE], root
        )

        divs = []
        bad_content = [
            (p, ln, c)
            for (p, ln, c) in cdb_hits
            if c != expect_content
        ]
        if set(cdb_set) != set(expect):
            missing, extra = diff_sets(cdb_set, expect)
            divs.append(
                divergence(
                    "LINE_OFF" if (missing and extra) else
                    ("MISSING" if missing else "EXTRA"),
                    "HIGH",
                    "codedb hits for %s diverge from byte-derived ground "
                    "truth in the NUL-bearing file" % token,
                    examples=(missing + extra)[:10],
                )
            )
        if set(cdb_set) != set(rg_a_set):
            missing, extra = diff_sets(cdb_set, rg_a_set)
            divs.append(
                divergence(
                    "OTHER",
                    "HIGH",
                    "codedb disagrees with the rg -a text-mode oracle for "
                    "%s" % token,
                    examples=(missing + extra)[:10],
                )
            )
        if bad_content:
            divs.append(
                divergence(
                    "OTHER",
                    "MEDIUM",
                    "codedb returned mangled content for %s hits" % token,
                    examples=["%s:%d:%r" % b for b in bad_content[:5]],
                )
            )
        detail = (
            "codedb=%r (content clean ASCII, no mojibake: %s); "
            "rg default on file: %s (rc=%d); rg -a: %r"
            % (
                cdb_set,
                not bad_content,
                repr(def_text.strip()[:80]) if def_text.strip() else "no output",
                rc_def,
                rg_a_set,
            )
        )
        checks.append(
            make_check(
                "p8.null.%s.lines" % short,
                "codedb_search {query:%r, max_results:10000, "
                "max_per_file:10000}" % token,
                "python byte split of %s; rg -n -F -a %s %s (line oracle)"
                % (NULL_FILE, token, NULL_FILE),
                divs,
                detail,
            )
        )

    # Disclosure check: codedb serves text hits from a NUL-containing file
    # with no binary signal of any kind; rg default discloses.
    divs = [
        divergence(
            "EXTRA",
            "MEDIUM",
            "codedb_search returns plain text hits (with line numbers) from "
            "%s, whose first NUL byte sits at offset %d — past codedb's "
            "documented 512-byte binary sniff window — with ZERO disclosure "
            "that the file contains NUL bytes. rg default mode discloses "
            "('binary file matches') when given the file explicitly and "
            "silently skips it in recursive mode; rg -a is an explicit "
            "opt-in. The 512-byte sniff window itself is the documented "
            "design choice (refpolicy binary_null_sniff replicates it); the "
            "divergence recorded here is purely the absence of any "
            "binary/NUL disclosure on served results once the sniff is "
            "defeated." % (NULL_FILE, nul_off),
            examples=[
                "rg default: 'binary file matches (found \"\\0\" byte "
                "around offset 600)'",
                "codedb: '10 results for ...' + '1 results for ...' rows, "
                "no marker",
            ],
        )
    ]
    checks.append(
        make_check(
            "p8.null.disclosure",
            "codedb_search on NEEDLE_NULLAT600_* (responses carry no "
            "binary/NUL marker)",
            "rg -n -F <token> %s (default binary handling: 'binary file "
            "matches', no line numbers)" % NULL_FILE,
            divs,
            "rg default flagged file as binary: %r; codedb returned "
            "undisclosed text hits from the same file" % rg_default_binary,
        )
    )


def _check_png_parity(client, root, checks, notes):
    token = "NEEDLE_PNG_AS_TXT"
    resp = client.call(
        "codedb_search",
        {"query": token, "max_results": 10000, "max_per_file": 10000},
    )
    cdb_set = norm_hits(parse_search(resp["text"]))

    rc, rg_set, _ = _rg_hits(
        ["-n", "-F", "-g", "!codedb.snapshot", token, "."], root
    )

    divs = []
    if cdb_set:
        divs.append(
            divergence(
                "EXTRA",
                "HIGH",
                "codedb indexed %s despite NUL bytes in the first 16 bytes "
                "(documented sniff should skip it)" % PNG_FILE,
                examples=cdb_set,
            )
        )
    if rg_set:
        notes.append(
            "unexpected: rg recursive default found %r for %s (it normally "
            "skips binary files silently)" % (rg_set, token)
        )
    checks.append(
        make_check(
            "p8.png.parity",
            "codedb_search {query:%r, max_results:10000, "
            "max_per_file:10000} -> expect 0 hits (NUL in sniff window)"
            % token,
            "rg -n -F %s . (recursive default skips binary files)" % token,
            divs,
            "codedb=%r (expected []); rg recursive default=%r (rc=%d); "
            "refpolicy reason for %s: binary_null_sniff"
            % (cdb_set, rg_set, rc, PNG_FILE),
        )
    )


# --- entry point ----------------------------------------------------------------


def run(client, root, info):
    checks = []
    notes = []
    try:
        _check_token_lines(client, root, checks, notes)
        _check_read_crlf(client, root, checks, notes)
        _check_read_bom(client, root, checks, notes)
        _check_regex_crlf_anchor(client, root, checks, notes)
        _check_regex_bom_anchor(client, root, checks, notes)
        _check_tree_linecounts(client, root, checks, notes)
        _check_null_file(client, root, checks, notes)
        _check_png_parity(client, root, checks, notes)
        return make_result(PROBE_ID, PROBE_NAME, root, checks, notes)
    except Exception:
        tb = traceback.format_exc()
        notes.append(tb)
        checks.append(
            make_check(
                "p3p8.exception",
                "probe body",
                "n/a",
                [
                    divergence(
                        "OTHER",
                        "HIGH",
                        "probe raised an exception; see notes for traceback",
                    )
                ],
                "unhandled exception",
            )
        )
        result = make_result(PROBE_ID, PROBE_NAME, root, checks, notes)
        return {**result, "verdict": "ERROR"}


if __name__ == "__main__":
    from driver import CodedbClient

    if len(sys.argv) < 2:
        print("usage: probes_lines.py <corpus-root>", file=sys.stderr)
        sys.exit(2)
    test_root = os.path.abspath(sys.argv[1])
    client = CodedbClient(test_root)
    try:
        client.wait_ready()
        info = {
            "synth_root": test_root,
            "codex_root": None,
            "codedb_sha": None,
            "codex_sha": None,
            "binary": client.binary,
        }
        result = run(client, test_root, info)
    finally:
        client.close()
    print(json.dumps(result, indent=2, ensure_ascii=False))
