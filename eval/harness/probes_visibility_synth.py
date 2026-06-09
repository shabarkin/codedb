#!/usr/bin/env python3
"""Probe 2b+4+9: skip-dir/gitignore/unicode visibility (synthetic corpus).

(2b) Full visibility reconciliation: codedb_tree vs refpolicy.expected_indexed
     (HIGH on any unexplained gap), then vs the raw filesystem with every
     invisible file bucketed by its refpolicy reason (INFO design choices).
     Named callouts: Build/real_code.c (skip_dir case-insensitive),
     Cargo.lock (.lock ext), sizes/over-cap-600kb.txt (>512KB),
     symlinks/escape-link (out-of-root symlink, security-positive).
(9)  Gitignore parity per-case with `git check-ignore` as the oracle
     (negation, dir-only vs plain file, **/, non-skip_dirs dir).
(4)  Unicode/NFD: content search for NFC/NFD/CJK needles must return the
     exact (path,line); codedb_glob with NFC vs NFD patterns is expected
     byte-exact (fd is byte-exact too — recorded as reference behavior).
Plus: symlink loop (a<->b) must not break indexing.
"""
import json
import os
import subprocess
import sys
import traceback
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import contract
import refpolicy
from contract import SYNTH_TOKENS, divergence, make_check, make_result, norm_hits
from driver import CodedbClient, parse_paths, parse_search
from treeparse import tree_paths

PROBE_ID = "2b+4+9"
PROBE_NAME = "skip-dir/gitignore/unicode visibility (synthetic)"
ROOT = "synth"
SELF_MANAGED = False

RG = "/opt/homebrew/bin/rg"
FD = os.path.expanduser("~/.local/bin/fd")

NFC_PY = SYNTH_TOKENS["NEEDLE_NFC_CAFE"][0]   # unicode/nfc/café.py (NFC bytes)
NFD_PY = SYNTH_TOKENS["NEEDLE_NFD_CAFE"][0]   # unicode/nfd/café.py (NFD bytes)


# -- subprocess helpers --------------------------------------------------------


def _run(cmd, cwd=None):
    proc = subprocess.run(
        cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    return (
        proc.returncode,
        proc.stdout.decode("utf-8", "surrogateescape"),
        proc.stderr.decode("utf-8", "surrogateescape"),
    )


def _rg_fixed(root, token):
    """rg -n -F token: [(path,line,content)], paths relative to root."""
    rc, out, _err = _run([RG, "-n", "-F", "--no-config", token], cwd=root)
    return contract.parse_rg_lines(out)


def _fd(root, args):
    rc, out, _err = _run([FD] + args, cwd=root)
    paths = [p[2:] if p.startswith("./") else p for p in out.splitlines() if p]
    return sorted(paths)


def _git_ignore_verdict(root, relpath):
    """(is_ignored, evidence_line) via git check-ignore.

    Verdict comes from the plain exit code (with -v even negation matches
    print a line AND exit 0, so -v alone cannot be the verdict source).
    """
    rc_plain, _o, _e = _run(["git", "-C", root, "check-ignore", relpath])
    rc_v, out_v, _e2 = _run(["git", "-C", root, "check-ignore", "-v", relpath])
    evidence = out_v.strip() or "(no .gitignore pattern matched; exit %d)" % rc_v
    return rc_plain == 0, evidence


# -- codedb call helpers -------------------------------------------------------


def _search(client, query, **extra):
    args = {"query": query, "max_results": 100, "max_per_file": 10000}
    args.update(extra)
    resp = client.call("codedb_search", args)
    return parse_search(resp["text"]), resp


def _glob(client, pattern, max_results=5000):
    resp = client.call("codedb_glob", {"pattern": pattern, "max_results": max_results})
    text = resp["text"]
    if text.strip() == "no matches":
        return [], resp
    # local workaround: driver.parse_paths would return the literal
    # 'no matches' sentinel as a path row
    paths = [p for p in parse_paths(text) if p != "no matches"]
    return sorted(paths), resp


def _u(s):
    """Readable repr of a possibly-NFD/NFC path for examples."""
    return "%s [%s]" % (s, s.encode("utf-8").hex())


# -- check builders ------------------------------------------------------------


def _check_tree_vs_policy(indexed, expected_set, excluded):
    divs = []
    missing = sorted(expected_set - indexed)
    extra = sorted(indexed - expected_set)
    if missing:
        divs.append(divergence(
            "MISSING", "HIGH",
            "%d file(s) the documented visibility policy says must be indexed "
            "are absent from codedb_tree (silent invisibility)" % len(missing),
            missing,
        ))
    if extra:
        examples = [
            "%s (refpolicy: %s)" % (p, excluded.get(p, "no exclusion reason — not even in raw inventory?"))
            for p in extra
        ]
        divs.append(divergence(
            "EXTRA", "HIGH",
            "%d file(s) indexed by codedb that the documented policy excludes" % len(extra),
            examples,
        ))
    return make_check(
        "2b.tree-vs-policy",
        "codedb_tree -> treeparse.tree_paths (full indexed file list)",
        "refpolicy.expected_indexed(root) — mechanical replica of documented policy + git check-ignore",
        divs,
        detail="indexed=%d expected=%d missing=%d extra=%d"
        % (len(indexed), len(expected_set), len(missing), len(extra)),
    )


def _check_invisible_census(root, indexed, excluded):
    inventory = [p for p in refpolicy.walk_files(root) if not p.startswith(".git/")]
    invisible = [p for p in inventory if p not in indexed]
    buckets, unexplained = {}, []
    for p in invisible:
        reason = excluded.get(p)
        if reason is None:
            unexplained.append(p)
        else:
            buckets.setdefault(reason, []).append(p)
    divs = []
    for reason in sorted(buckets):
        paths = sorted(buckets[reason])
        divs.append(divergence(
            "MISSING", "INFO",
            "design choice (refpolicy reason '%s'): %d file(s) on disk are "
            "invisible to codedb" % (reason, len(paths)),
            paths,
        ))
    detail = "raw files (excl .git/)=%d, invisible=%d across %d reason bucket(s)" % (
        len(inventory), len(invisible), len(buckets)
    )
    if unexplained:
        detail += "; %d invisible file(s) had NO refpolicy reason (already flagged HIGH in 2b.tree-vs-policy): %s" % (
            len(unexplained), ", ".join(unexplained[:5])
        )
    return make_check(
        "2b.invisible-bucket-census",
        "codedb_tree file list vs raw filesystem walk",
        "refpolicy.walk_files(root) minus .git/ + refpolicy reason per excluded path",
        divs,
        detail=detail,
    )


def _check_designed_invisibility(client, root, check_id, token, reason_desc):
    relpath, line = SYNTH_TOKENS[token]
    hits, resp = _search(client, token)
    rg_hits = _rg_fixed(root, token)
    rg_norm = norm_hits(rg_hits)
    cd_norm = norm_hits(hits)
    divs = []
    if not rg_norm:
        divs.append(divergence(
            "OTHER", "MEDIUM",
            "reference rg -F '%s' found nothing — corpus anomaly, cannot "
            "attest the content exists" % token, []))
    if cd_norm:
        divs.append(divergence(
            "OTHER", "MEDIUM",
            "codedb unexpectedly returned results for %s despite documented "
            "skip policy (%s)" % (token, reason_desc), cd_norm))
    elif rg_norm:
        divs.append(divergence(
            "MISSING", "INFO",
            "design choice: codedb_search '%s' -> 0 results while rg finds %s "
            "(%s)" % (token, ", ".join(rg_norm), reason_desc), rg_norm))
    return make_check(
        check_id,
        "codedb_search query=%r max_results=100 max_per_file=10000" % token,
        "%s -n -F %r (cwd=root); ground truth %s:%d" % (RG, token, relpath, line),
        divs,
        detail="codedb hits=%d rg hits=%d; %s" % (len(cd_norm), len(rg_norm), reason_desc),
    )


def _check_symlink_escape(client, root):
    token = "NEEDLE_OUTSIDE_ROOT"
    link = os.path.join(root, "symlinks", "escape-link")
    target = os.path.realpath(link)
    reachable = False
    try:
        with open(link, "r", encoding="utf-8", errors="replace") as fh:
            reachable = token in fh.read()
    except OSError:
        reachable = False
    hits, resp = _search(client, token)
    cd_norm = norm_hits(hits)
    divs = []
    if cd_norm:
        divs.append(divergence(
            "EXTRA", "HIGH",
            "codedb indexed content reachable only through an out-of-root "
            "symlink (symlinks/escape-link -> %s) — root-escape" % target,
            cd_norm))
    detail = (
        "security-positive: codedb_search '%s' -> %d results; symlink target %s "
        "%s readable directly through the link" % (
            token, len(cd_norm), target,
            "IS" if reachable else "is NOT (target missing — exclusion reason "
            "degrades to broken_symlink, escape not attestable)",
        )
    )
    return make_check(
        "2b.symlink-escape",
        "codedb_search query=%r" % token,
        "open(root/symlinks/escape-link) — content outside root via symlink",
        divs,
        detail=detail,
    )


GITIGNORE_CASES = [
    # (check_id, token, cause_note)
    ("9.debug-log", "TOKEN_DEBUG_LOG",
     "ignored by root pattern '*.log'"),
    ("9.important-log", "TOKEN_IMPORTANT_LOG",
     "rescued by negation '!important.log' in nested logs/.gitignore — must be PRESENT"),
    ("9.build-dironly", "TOKEN_BUILD_DIRONLY",
     "ignored by dir-only 'build/'; DOUBLE-CAUSE: 'build' is also in codedb skip_dirs, "
     "so this case does NOT isolate gitignore handling"),
    ("9.outdir", "TOKEN_OUTDIR",
     "ignored by dir-only 'outdir/'; 'outdir' is NOT in skip_dirs — isolates gitignore"),
    ("9.generated", "TOKEN_GENERATED",
     "ignored by '**/generated'"),
    ("9.build-plainfile", "TOKEN_BUILD_PLAINFILE",
     "FILE named 'build': dir-only pattern 'build/' must NOT match it — must be PRESENT"),
    ("9.gitignore-visible", "TOKEN_GITIGNORE_VISIBLE",
     "control: plain visible file — must be PRESENT"),
]


def _check_gitignore_case(client, root, indexed, check_id, token, cause_note):
    relpath, line = SYNTH_TOKENS[token]
    git_ignored, evidence = _git_ignore_verdict(root, relpath)
    skip = refpolicy.skip_reason(root, relpath)
    expected_visible = (not git_ignored) and (skip is None)
    in_tree = relpath in indexed
    hits, resp = _search(client, token)
    cd_norm = norm_hits(hits)
    want = "%s:%d" % (relpath, line)
    divs = []
    if expected_visible and not in_tree:
        divs.append(divergence(
            "IGNORE_SEMANTICS", "HIGH",
            "%s should be visible (git: NOT ignored%s) but is absent from "
            "codedb_tree. %s" % (
                relpath, "" if skip is None else "; refpolicy skip=" + skip,
                cause_note),
            ["git check-ignore -v: %s" % evidence]))
    if not expected_visible and in_tree:
        divs.append(divergence(
            "IGNORE_SEMANTICS", "HIGH",
            "%s should be invisible (git-ignored=%s, refpolicy skip=%s) but "
            "IS in codedb_tree. %s" % (relpath, git_ignored, skip, cause_note),
            ["git check-ignore -v: %s" % evidence]))
    if expected_visible and in_tree:
        if not cd_norm:
            divs.append(divergence(
                "OTHER", "HIGH",
                "%s is in codedb_tree but its token %s is unsearchable "
                "(0 results)" % (relpath, token), []))
        elif cd_norm != [want]:
            extra = [h for h in cd_norm if h != want]
            same_file_other_line = [
                h for h in extra if h.rsplit(":", 1)[0] == relpath]
            dtype = "LINE_OFF" if (same_file_other_line and want not in cd_norm) else "EXTRA"
            divs.append(divergence(
                dtype, "HIGH",
                "search '%s' expected exactly [%s], got %s" % (
                    token, want, cd_norm), cd_norm))
    if not expected_visible and not in_tree and cd_norm:
        divs.append(divergence(
            "EXTRA", "HIGH",
            "%s absent from codedb_tree but token %s searchable — "
            "inconsistent index" % (relpath, token), cd_norm))
    return make_check(
        check_id,
        "codedb_tree membership + codedb_search query=%r" % token,
        "git -C root check-ignore [-v] %r -> %s" % (relpath, evidence),
        divs,
        detail="git_ignored=%s refpolicy_skip=%s expected_visible=%s in_tree=%s "
        "search=%s | %s" % (git_ignored, skip, expected_visible, in_tree,
                            cd_norm or "[]", cause_note),
    )


def _check_unicode_search(client, root, check_id, token):
    relpath, line = SYNTH_TOKENS[token]
    want = ["%s:%d" % (relpath, line)]
    hits, resp = _search(client, token)
    cd_norm = norm_hits(hits)
    rg_norm = norm_hits(_rg_fixed(root, token))
    divs = []
    if cd_norm == want:
        pass
    elif [unicodedata.normalize("NFC", h) for h in cd_norm] == [
            unicodedata.normalize("NFC", w) for w in want]:
        divs.append(divergence(
            "OTHER", "MEDIUM",
            "same file/line but path emitted in a different Unicode "
            "normalization form than stored on disk: got %s want %s" % (
                [_u(h) for h in cd_norm], [_u(w) for w in want]),
            [_u(h) for h in cd_norm]))
    else:
        miss, extra = contract.diff_sets(cd_norm, want)
        if miss:
            divs.append(divergence(
                "MISSING", "HIGH",
                "search '%s' missing expected hit(s) %s (got %s; rg got %s)" % (
                    token, [_u(m) for m in miss], cd_norm, rg_norm),
                [_u(m) for m in miss]))
        if extra:
            divs.append(divergence(
                "EXTRA", "HIGH",
                "search '%s' returned unexpected hit(s)" % token,
                [_u(e) for e in extra]))
    return make_check(
        check_id,
        "codedb_search query=%r" % token,
        "%s -n -F %r (rg hits: %s); SYNTH_TOKENS ground truth %s" % (
            RG, token, rg_norm, [_u(w) for w in want]),
        divs,
        detail="codedb=%s expected=%s" % ([_u(h) for h in cd_norm], [_u(w) for w in want]),
    )


def _check_glob_form(client, check_id, pattern, own_path, sibling_path,
                     fd_ref_desc, fd_own, fd_sibling):
    matches, resp = _glob(client, pattern)
    mset = set(matches)
    divs = []
    if own_path not in mset:
        if {unicodedata.normalize("NFC", m) for m in mset} >= {
                unicodedata.normalize("NFC", own_path)}:
            divs.append(divergence(
                "OTHER", "MEDIUM",
                "glob %r matched the file only under a different Unicode "
                "normalization form: %s" % (pattern, [_u(m) for m in matches]),
                [_u(m) for m in matches]))
        else:
            divs.append(divergence(
                "MISSING", "HIGH",
                "glob %r failed to match even its byte-identical file %s" % (
                    pattern, _u(own_path)),
                [_u(m) for m in matches] or ["(no matches)"]))
    if sibling_path in mset:
        divs.append(divergence(
            "OTHER", "INFO",
            "glob %r ALSO matched the other-normalization sibling %s — "
            "codedb normalizes where fd is byte-exact (%s)" % (
                pattern, _u(sibling_path), fd_ref_desc),
            [_u(m) for m in matches]))
    elif own_path in mset:
        divs.append(divergence(
            "MISSING", "MEDIUM",
            "glob %r does not match the visually-identical sibling %s — "
            "byte-exact (no Unicode normalization). macOS-specific trap: APFS "
            "preserves creation form, so NFC keyboard input misses NFD-named "
            "files. fd 10.4.2 behaves identically (%s), so this is parity "
            "with the reference tool, recorded per spec" % (
                pattern, _u(sibling_path), fd_ref_desc),
            [_u(m) for m in matches]))
    unexpected = sorted(mset - {own_path, sibling_path})
    if unexpected:
        divs.append(divergence(
            "EXTRA", "HIGH",
            "glob %r matched unrelated paths" % pattern,
            [_u(u) for u in unexpected]))
    return make_check(
        check_id,
        "codedb_glob pattern=%r" % pattern,
        "fd -g (byte-exact reference): own-form -> %s, sibling-form -> %s" % (
            fd_own, fd_sibling),
        divs,
        detail="codedb matches=%s" % [_u(m) for m in matches],
    )


def _check_glob_all_py(client, root, indexed):
    matches, resp = _glob(client, "**/*.py")
    fd_py = _fd(root, ["-e", "py"])
    tree_py = sorted(p for p in indexed if p.endswith(".py"))
    divs = []
    miss, extra = contract.diff_sets(sorted(matches), fd_py)
    if miss:
        divs.append(divergence(
            "MISSING", "HIGH",
            "codedb_glob '**/*.py' missing file(s) fd -e py finds",
            [_u(m) for m in miss]))
    if extra:
        divs.append(divergence(
            "EXTRA", "HIGH",
            "codedb_glob '**/*.py' returned file(s) fd -e py does not",
            [_u(e) for e in extra]))
    if sorted(matches) != tree_py:
        divs.append(divergence(
            "OTHER", "HIGH",
            "glob '**/*.py' disagrees with the indexed tree's .py set: "
            "glob=%s tree=%s" % ([_u(m) for m in matches], [_u(t) for t in tree_py]),
            []))
    return make_check(
        "4.glob-all-py",
        "codedb_glob pattern='**/*.py'",
        "%s -e py (cwd=root) -> %s" % (FD, [_u(p) for p in fd_py]),
        divs,
        detail="codedb=%s tree_py=%s" % ([_u(m) for m in matches], [_u(t) for t in tree_py]),
    )


def _check_symlink_loop(client, indexed):
    status_text = client.status()
    ready = "scan: ready" in status_text
    sym_paths = sorted(p for p in indexed if p.startswith("symlinks/"))
    divs = []
    if not ready:
        divs.append(divergence(
            "OTHER", "HIGH",
            "codedb_status no longer reports 'scan: ready' after probing — "
            "symlink loop may have destabilized the scan", [status_text[:200]]))
    if sym_paths:
        divs.append(divergence(
            "EXTRA", "HIGH",
            "codedb_tree contains symlink-derived paths; loop (a<->b), broken, "
            "and out-of-root links should all be dropped", sym_paths))
    return make_check(
        "symlink-loop-tolerance",
        "codedb_status + codedb_tree",
        "corpus contains symlink loop a<->b, broken-link, escape-link; "
        "expectation: ready server, zero symlinks/ paths indexed",
        divs,
        detail="scan_ready=%s symlinks_paths_indexed=%s" % (ready, sym_paths or "[]"),
    )


# -- entry point ---------------------------------------------------------------


def run(client, root, info):
    notes = []
    try:
        checks = []

        tree_resp = client.call("codedb_tree")
        indexed = set(tree_paths(tree_resp["text"]))
        expected, excluded = refpolicy.expected_indexed(root)
        expected_set = set(expected)
        notes.append("codedb_tree parsed %d indexed files; refpolicy expects %d "
                     "(%d excluded with reasons)" % (
                         len(indexed), len(expected_set), len(excluded)))

        # (2b) reconciliation + census
        checks.append(_check_tree_vs_policy(indexed, expected_set, excluded))
        checks.append(_check_invisible_census(root, indexed, excluded))

        # (2b) named design-choice callouts
        checks.append(_check_designed_invisibility(
            client, root, "2b.build-dir-source", "NEEDLE_BUILD_DIR_SOURCE",
            "real C source invisible: dir named 'Build' matches skip_dirs "
            "case-insensitively"))
        checks.append(_check_designed_invisibility(
            client, root, "2b.cargo-lock", "NEEDLE_CARGO_LOCK",
            "'.lock' is in skip_extensions"))
        checks.append(_check_designed_invisibility(
            client, root, "2b.over-cap", "NEEDLE_OVER_CAP_START",
            "file is 600KB > 512KB size cap; token sits on line 1 so only the "
            "whole-file skip explains a miss"))
        checks.append(_check_symlink_escape(client, root))

        # (9) gitignore parity battery
        for check_id, token, cause_note in GITIGNORE_CASES:
            checks.append(_check_gitignore_case(
                client, root, indexed, check_id, token, cause_note))

        # (4) unicode content search
        checks.append(_check_unicode_search(client, root, "4.search-nfc", "NEEDLE_NFC_CAFE"))
        checks.append(_check_unicode_search(client, root, "4.search-nfd", "NEEDLE_NFD_CAFE"))
        checks.append(_check_unicode_search(client, root, "4.search-japanese", "NEEDLE_JAPANESE"))

        # (4) unicode glob forms — fd reference behavior recorded first
        nfc_base = NFC_PY.split("/")[-1]        # 'café.py'
        nfd_base = NFD_PY.split("/")[-1]        # 'café.py'
        fd_caf = _fd(root, ["caf"])
        fd_nfc = _fd(root, ["-g", nfc_base])
        fd_nfd = _fd(root, ["-g", nfd_base])
        notes.append("fd reference: fd 'caf' -> %s; fd -g %r -> %s; fd -g %r -> %s"
                     % ([_u(p) for p in fd_caf], nfc_base, [_u(p) for p in fd_nfc],
                        nfd_base, [_u(p) for p in fd_nfd]))
        fd_desc = "fd -g NFC -> %d file(s), fd -g NFD -> %d file(s)" % (
            len(fd_nfc), len(fd_nfd))
        checks.append(_check_glob_form(
            client, "4.glob-nfc-pattern", "**/" + nfc_base, NFC_PY, NFD_PY,
            fd_desc, fd_nfc, fd_nfd))
        checks.append(_check_glob_form(
            client, "4.glob-nfd-pattern", "**/" + nfd_base, NFD_PY, NFC_PY,
            fd_desc, fd_nfd, fd_nfc))
        checks.append(_check_glob_all_py(client, root, indexed))

        # symlink loop tolerance
        checks.append(_check_symlink_loop(client, indexed))

        return make_result(PROBE_ID, PROBE_NAME, root, checks, notes=notes)
    except Exception:
        tb = traceback.format_exc()
        notes.append(tb)
        crash = make_check(
            "probe-crash",
            "probe module raised an exception",
            "n/a",
            [divergence("OTHER", "HIGH", "probe crashed: %s" % tb.splitlines()[-1], [])],
            detail="see notes for full traceback",
        )
        return make_result(PROBE_ID, PROBE_NAME, root, [crash], notes=notes)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: probes_visibility_synth.py <corpus-root>", file=sys.stderr)
        sys.exit(2)
    root_arg = os.path.abspath(sys.argv[1])
    client = CodedbClient(root_arg)
    try:
        client.wait_ready()
        info = {
            "synth_root": root_arg,
            "codex_root": None,
            "codedb_sha": "803db6b",
            "codex_sha": None,
            "binary": client.binary,
        }
        result = run(client, root_arg, info)
    finally:
        client.close()
    print(json.dumps(result, indent=2, ensure_ascii=False))
