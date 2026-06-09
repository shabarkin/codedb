#!/usr/bin/env python3
"""Probe 2a: codex full-inventory reconciliation.

Reconciles codedb's ENTIRE indexed file set for the codex repo
against refpolicy.expected_indexed (the mechanical replica of codedb's
documented visibility policy, with git check-ignore as gitignore oracle).

Checks:
  2a.inventory             tree_paths(codedb_tree) vs expected_indexed; every
                           missing/extra path bucketed and severity-rated
  2a.module-bazel-lock     MODULE.bazel.lock invisible (design: .lock + >512KB)
  2a.npmrc-sensitive       .npmrc invisible (design: sensitive) — zero disclosure
  2a.gitattributes-visible .gitattributes must be indexed
  2a.agents-md-visible     AGENTS.md must be indexed
  2a.dir-presence          patches/, tools/, third_party/ each have >0 indexed
                           files (refutes the plan hypothesis they are pruned)
  2a.count-reconciliation  codedb_status files/outlines vs tree count vs the
                           refpolicy-derived yielded-but-file-level-skipped set
  2a.glob-vs-tree          codedb_glob '**/*' (max 5000) set-equals tree set

Authoring-time notes (codex @ HEAD, read-only inspection):
  - codex .gitignore set (root + 5 nested) uses only constructs codedb's
    engine supports: bare names, '*' wildcards, '?' (Icon?), negation
    (!pnpm-lock.yaml, !.env.example), dir-only, anchored. NO char classes,
    NO backslash escapes — so zero gitignore-gap divergence is expected here.
  - .vscode/{extensions,launch,settings}.json are TRACKED but pattern-ignored;
    refpolicy buckets them 'gitignored_but_tracked' (codedb, like rg, is
    pattern-only and hides them; git itself never ignores tracked files).
  - codedb.snapshot (86MB) already sits untracked in the codex root from a
    prior run: walker yields it, size cap skips it -> files/outlines delta +1.
  - codex-rs/.../codex_app_server_protocol.schemas.json is 512,451 bytes —
    just UNDER the 524,288 cap; must be indexed.
"""
import fnmatch
import json
import os
import re
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import refpolicy
from contract import divergence, make_check, make_result
from driver import CodedbClient, parse_paths
from treeparse import tree_paths

PROBE_ID = "2a"
PROBE_NAME = "codex full-inventory reconciliation"
ROOT = "codex"
SELF_MANAGED = False

# refpolicy reasons for files the walker YIELDS (counted in status `files`)
# but then skips at parse time (never reaching outlines/tree).
YIELDED_BUT_SKIPPED_REASONS = {
    "skip_extension", "ds_store", "sensitive_file", "over_512kb",
    "binary_null_sniff", "unreadable", "unsafe_path",
}
# reasons that prevent the walker from yielding at all (dir pruned, ignored,
# or stat failure in collectInitialScanEntries).
NOT_YIELDED_REASONS = {
    "skip_dir", "sensitive_dir", "gitignored", "gitignored_but_tracked",
    "broken_symlink", "symlink_outside_root", "unstattable",
}

_FILE_ROW = re.compile(r"^(.*?)  (\S+)  (\d+)L  (\d+) sym")


# -- helpers -------------------------------------------------------------------


def _reason_base(reason):
    return reason.split(":")[0]


def _reason_histogram(excluded):
    hist = {}
    for reason in excluded.values():
        base = _reason_base(reason)
        hist[base] = hist.get(base, 0) + 1
    return hist


def _parse_status(text):
    """codedb_status text -> dict with files/outlines/scan (None if absent)."""
    out = {"files": None, "outlines": None, "scan": None}
    m = re.search(r"(?m)^\s*files:\s*(\d+)\s*$", text)
    if m:
        out["files"] = int(m.group(1))
    m = re.search(r"(?m)^\s*outlines:\s*(\d+)\s*$", text)
    if m:
        out["outlines"] = int(m.group(1))
    m = re.search(r"(?m)^\s*scan:\s*(\S+)", text)
    if m:
        out["scan"] = m.group(1)
    return out


def _raw_tree_file_rows(tree_text):
    """Count rows in the raw tree text that LOOK like file rows, independent
    of treeparse's indent/stack logic — separates 'server omitted the file'
    from 'treeparse failed to parse the row'."""
    n = 0
    for row in tree_text.splitlines():
        if _FILE_ROW.match(row.strip()):
            n += 1
    return n


def _basename_in_tree_text(tree_text, basename):
    """Does any raw tree row carry this basename as a file leaf?"""
    probe = basename + "  "
    for row in tree_text.splitlines():
        if row.strip().startswith(probe):
            return True
    return False


def _collect_ignore_patterns(root, inventory):
    """All (source_file, base_dir, pattern, negated) from .codedbignore (root)
    plus every .gitignore in the raw inventory. Used only to BUCKET missing
    paths (which gitignore pattern codedb's engine may have over-applied)."""
    sources = [p for p in inventory if p.split("/")[-1] == ".gitignore"]
    if os.path.isfile(os.path.join(root, ".codedbignore")):
        sources.append(".codedbignore")
    patterns = []
    for src in sorted(set(sources)):
        base_dir = "/".join(src.split("/")[:-1])
        try:
            with open(os.path.join(root, src), encoding="utf-8",
                      errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        for line in lines:
            t = line.strip()
            if not t or t.startswith("#"):
                continue
            negated = t.startswith("!")
            if negated:
                t = t[1:]
            if t:
                patterns.append((src, base_dir, t, negated))
    return patterns


def _ignore_pattern_candidates(relpath, patterns):
    """Heuristic: which non-negated ignore patterns plausibly match relpath
    under pattern-only semantics. Bucketing aid only — git already said the
    path is NOT ignored, so any candidate marks a potential engine overmatch."""
    base = relpath.split("/")[-1]
    dir_comps = relpath.split("/")[:-1]
    found = []
    for (src, base_dir, pat, negated) in patterns:
        if negated:
            continue
        if base_dir:
            if not relpath.startswith(base_dir + "/"):
                continue
            rel = relpath[len(base_dir) + 1:]
        else:
            rel = relpath
        p = pat.rstrip("/").lstrip("/")
        if not p:
            continue
        if "/" in p:
            if (fnmatch.fnmatchcase(rel, p)
                    or fnmatch.fnmatchcase(rel, p + "/*")):
                found.append("%s -> %r" % (src, pat))
        else:
            if (fnmatch.fnmatchcase(base, p)
                    or any(fnmatch.fnmatchcase(c, p) for c in dir_comps)):
                found.append("%s -> %r" % (src, pat))
    return found


# -- check 1: inventory ---------------------------------------------------------


def _check_inventory(root, got, expected_set, excluded, tree_text, inventory):
    divs = []
    missing = sorted(expected_set - got)
    extra = sorted(got - expected_set)

    # ---- missing: policy says visible, codedb hides it
    patterns = _collect_ignore_patterns(root, inventory) if missing else []
    m_overmatch, m_parse, m_unexplained = [], [], []
    for p in missing:
        cands = _ignore_pattern_candidates(p, patterns)
        if cands:
            m_overmatch.append("%s (candidate pattern(s): %s)"
                               % (p, "; ".join(cands[:3])))
        elif _basename_in_tree_text(tree_text, p.split("/")[-1]):
            m_parse.append(p)
        else:
            m_unexplained.append(p)
    if m_overmatch:
        divs.append(divergence(
            "IGNORE_SEMANTICS", "HIGH",
            "%d file(s) hidden by codedb although git does NOT ignore them; "
            "an ignore pattern plausibly over-applied by codedb's pattern-only "
            "engine (all codex gitignore constructs are nominally supported, "
            "so any overmatch is a silent engine bug)" % len(m_overmatch),
            m_overmatch))
    if m_parse:
        divs.append(divergence(
            "OTHER", "MEDIUM",
            "%d expected file(s) absent from treeparse output but their "
            "basename DOES appear as a raw tree file row — possible "
            "treeparse.py parsing artifact rather than codedb omission; "
            "needs manual re-judging against the raw tree text"
            % len(m_parse), m_parse))
    if m_unexplained:
        divs.append(divergence(
            "MISSING", "HIGH",
            "%d file(s) the documented visibility policy says must be indexed "
            "are silently absent from codedb_tree (no candidate ignore "
            "pattern, no raw tree row)" % len(m_unexplained),
            m_unexplained))

    # ---- extra: codedb indexes what policy excludes
    buckets = {}
    for p in extra:
        reason = excluded.get(p)
        if reason is None:
            reason = ("not_in_inventory_but_on_disk"
                      if os.path.lexists(os.path.join(root, p))
                      else "ghost_not_on_disk")
        buckets.setdefault(_reason_base(reason), []).append(p)
    for base in sorted(buckets):
        paths = buckets[base]
        if base == "codedb_artifact":
            divs.append(divergence(
                "EXTRA", "INFO",
                "codedb indexed its own snapshot artifact written into the "
                "probed root (refpolicy tracks it separately)", paths))
        elif base == "gitignored":
            divs.append(divergence(
                "IGNORE_SEMANTICS", "HIGH",
                "%d git-ignored file(s) silently indexed (codedb's engine "
                "failed to apply a pattern git applies)" % len(paths), paths))
        elif base == "gitignored_but_tracked":
            divs.append(divergence(
                "IGNORE_SEMANTICS", "MEDIUM",
                "%d tracked-but-pattern-ignored file(s) indexed: matches "
                "git's EFFECTIVE semantics (tracked files are never ignored) "
                "but contradicts codedb's pattern-only engine, so the engine "
                "diverged from its own model" % len(paths), paths))
        elif base == "ghost_not_on_disk":
            divs.append(divergence(
                "STALE", "HIGH",
                "%d indexed path(s) do not exist on disk at all — stale/ghost "
                "index entries served with no staleness signal" % len(paths),
                paths))
        elif base == "not_in_inventory_but_on_disk":
            divs.append(divergence(
                "OTHER", "MEDIUM",
                "%d indexed path(s) exist on disk but were not produced by a "
                "plain (non-symlink-following) walk — likely reached through "
                "an in-root directory symlink or a path-case alias"
                % len(paths), paths))
        else:
            divs.append(divergence(
                "EXTRA", "HIGH",
                "%d file(s) indexed although codedb's own documented policy "
                "excludes them (refpolicy reason '%s')" % (len(paths), base),
                paths))

    hist = _reason_histogram(excluded)
    detail = ("indexed=%d expected=%d missing=%d extra=%d; "
              "excluded-by-policy histogram: %s"
              % (len(got), len(expected_set), len(missing), len(extra),
                 json.dumps(hist, sort_keys=True)))
    return make_check(
        "2a.inventory",
        "codedb_tree -> treeparse.tree_paths (full indexed file list, no cap)",
        "refpolicy.expected_indexed(root): raw walk minus documented skips, "
        "gitignore via git check-ignore --no-index (pattern-only oracle)",
        divs, detail=detail)


# -- check 2: targeted assertions -----------------------------------------------


def _check_absent_by_design(check_id, root, got, relpath, design_note,
                            disclosure_note):
    on_disk = os.path.isfile(os.path.join(root, relpath))
    divs = []
    if not on_disk:
        detail = ("%s not present on disk at this root — assertion "
                  "inapplicable (expected only on the codex corpus)" % relpath)
    elif relpath in got:
        divs.append(divergence(
            "EXTRA", "HIGH",
            "%s IS indexed although codedb's documented policy excludes it "
            "(%s)" % (relpath, design_note), [relpath]))
        detail = "%s on disk AND indexed — contradicts documented policy" % relpath
    else:
        divs.append(divergence(
            "MISSING", "INFO",
            "design choice: %s exists on disk (git-visible; rg/fd/cat all see "
            "it) but is invisible to every codedb tool. %s. %s"
            % (relpath, design_note, disclosure_note), [relpath]))
        detail = "%s on disk, not indexed (documented design)" % relpath
    return make_check(
        check_id,
        "codedb_tree membership of %r" % relpath,
        "ls/git ls-files: %s exists=%s at root" % (relpath, on_disk),
        divs, detail=detail)


def _check_present(check_id, root, got, relpath):
    on_disk = os.path.isfile(os.path.join(root, relpath))
    divs = []
    if not on_disk:
        detail = ("%s not present on disk at this root — assertion "
                  "inapplicable (expected only on the codex corpus)" % relpath)
    elif relpath not in got:
        skip = refpolicy.skip_reason(root, relpath)
        divs.append(divergence(
            "MISSING", "HIGH",
            "%s exists on disk, no documented policy excludes it "
            "(refpolicy skip_reason=%s), yet it is absent from codedb_tree"
            % (relpath, skip), [relpath]))
        detail = "%s on disk but NOT indexed" % relpath
    else:
        detail = "%s on disk and indexed" % relpath
    return make_check(
        check_id,
        "codedb_tree membership of %r" % relpath,
        "ls: %s exists=%s at root; refpolicy has no exclusion for it"
        % (relpath, on_disk),
        divs, detail=detail)


def _check_dir_presence(root, got, expected_set):
    prefixes = ("patches/", "tools/", "third_party/")
    divs = []
    parts = []
    for pre in prefixes:
        on_disk = os.path.isdir(os.path.join(root, pre.rstrip("/")))
        got_n = sum(1 for p in got if p.startswith(pre))
        exp_n = sum(1 for p in expected_set if p.startswith(pre))
        parts.append("%s indexed=%d expected=%d on_disk=%s"
                     % (pre, got_n, exp_n, on_disk))
        if not on_disk:
            continue
        if got_n == 0 and exp_n > 0:
            divs.append(divergence(
                "MISSING", "HIGH",
                "zero indexed files under %s although the documented policy "
                "expects %d — the directory is silently pruned (refutes "
                "nothing: confirms the plan hypothesis)" % (pre, exp_n),
                sorted(p for p in expected_set if p.startswith(pre))[:10]))
        elif got_n != exp_n:
            missing = sorted(p for p in expected_set
                             if p.startswith(pre) and p not in got)
            extra = sorted(p for p in got
                           if p.startswith(pre) and p not in expected_set)
            divs.append(divergence(
                "OTHER", "MEDIUM",
                "%s indexed count %d != expected %d (missing=%d extra=%d; "
                "full-set deltas already reported in 2a.inventory)"
                % (pre, got_n, exp_n, len(missing), len(extra)),
                (["missing:" + p for p in missing]
                 + ["extra:" + p for p in extra])))
    return make_check(
        "2a.dir-presence",
        "codedb_tree path-prefix counts for patches/, tools/, third_party/",
        "refpolicy.expected_indexed counts for the same prefixes",
        divs, detail="; ".join(parts))


# -- check 3: count reconciliation ----------------------------------------------


def _check_count_reconciliation(client, root, got, excluded, tree_text):
    status_text = client.call("codedb_status")["text"]
    st = _parse_status(status_text)
    divs = []
    if st["scan"] != "ready":
        divs.append(divergence(
            "OTHER", "HIGH",
            "codedb_status scan=%r (not 'ready') during reconciliation — "
            "counts below may be mid-scan" % st["scan"],
            [status_text[:200]]))
    if st["files"] is None or st["outlines"] is None:
        divs.append(divergence(
            "OTHER", "HIGH",
            "could not parse files/outlines from codedb_status text",
            [status_text[:200]]))
        return make_check(
            "2a.count-reconciliation", "codedb_status fields files/outlines",
            "refpolicy excluded-reason buckets", divs,
            detail="status unparseable")

    raw_rows = _raw_tree_file_rows(tree_text)
    if st["outlines"] != len(got):
        sev = "MEDIUM" if st["outlines"] == raw_rows else "HIGH"
        divs.append(divergence(
            "OTHER", sev,
            "status outlines=%d != %d files parsed from codedb_tree "
            "(raw tree file-row count=%d: %s)"
            % (st["outlines"], len(got), raw_rows,
               "treeparse artifact suspected" if st["outlines"] == raw_rows
               else "server-side tree/outline mismatch"),
            []))

    yielded_skipped = sorted(
        p for p, r in excluded.items()
        if _reason_base(r) in YIELDED_BUT_SKIPPED_REASONS)
    snapshot_on_disk = os.path.isfile(os.path.join(root, "codedb.snapshot"))
    snapshot_in_got = "codedb.snapshot" in got
    derived = len(yielded_skipped)
    acceptable = {derived}
    snap_note = "codedb.snapshot on_disk=%s in_tree=%s" % (
        snapshot_on_disk, snapshot_in_got)
    if snapshot_on_disk and not snapshot_in_got:
        # walker yields it (untracked, not ignored) then the size cap/binary
        # sniff skips it; poll timing may or may not have recorded it yet.
        acceptable.add(derived + 1)
        snap_note += " (delta tolerance +1 for the yielded-then-skipped artifact)"

    delta = st["files"] - st["outlines"]
    if delta not in acceptable:
        divs.append(divergence(
            "OTHER", "MEDIUM",
            "status files-outlines delta=%d does not reconcile with the %d "
            "refpolicy yielded-but-file-level-skipped path(s) (acceptable "
            "deltas %s). Causes to re-judge: codedb's gitignore engine "
            "yielding a different file set than git's pattern oracle, stat "
            "failures, or files churned between scan and probe"
            % (delta, derived, sorted(acceptable)),
            ["yielded-skipped: %s (%s)" % (p, excluded[p])
             for p in yielded_skipped]))

    detail = ("status files=%d outlines=%d scan=%s; tree files=%d (raw rows "
              "%d); delta=%d, derived yielded-but-skipped=%d %s; %s"
              % (st["files"], st["outlines"], st["scan"], len(got), raw_rows,
                 delta, derived,
                 json.dumps(sorted({_reason_base(excluded[p])
                                    for p in yielded_skipped})),
                 snap_note))
    return make_check(
        "2a.count-reconciliation",
        "codedb_status fields files/outlines/scan vs codedb_tree count",
        "refpolicy excluded reasons in %s (+codedb.snapshot artifact)"
        % sorted(YIELDED_BUT_SKIPPED_REASONS),
        divs, detail=detail)


# -- check 4: glob cross-check ---------------------------------------------------


def _check_glob_vs_tree(client, got):
    resp = client.call(
        "codedb_glob", {"pattern": "**/*", "max_results": 5000}, timeout=300)
    text = resp["text"]
    if text.strip() == "no matches":
        glob_set = set()
    else:
        glob_set = {p for p in parse_paths(text) if p != "no matches"}
    divs = []
    capped = len(got) >= 5000
    if capped:
        if not glob_set <= got:
            divs.append(divergence(
                "EXTRA", "HIGH",
                "glob (capped at 5000) returned paths missing from the tree",
                sorted(glob_set - got)))
        divs.append(divergence(
            "TRUNCATED_UNDISCLOSED", "MEDIUM",
            "indexed set (%d) exceeds codedb_glob's silent 5000 clamp; glob "
            "returned %d with no truncation marker — set parity not checkable"
            % (len(got), len(glob_set)), []))
    else:
        missing = sorted(got - glob_set)
        extra = sorted(glob_set - got)
        if missing:
            divs.append(divergence(
                "MISSING", "HIGH",
                "%d indexed file(s) absent from codedb_glob '**/*' — the two "
                "enumeration tools disagree about the same index"
                % len(missing), missing))
        if extra:
            divs.append(divergence(
                "EXTRA", "HIGH",
                "%d glob path(s) not present in codedb_tree — the two "
                "enumeration tools disagree about the same index"
                % len(extra), extra))
    return make_check(
        "2a.glob-vs-tree",
        "codedb_glob pattern='**/*' max_results=5000",
        "treeparse.tree_paths(codedb_tree) — no-cap enumeration of the index",
        divs,
        detail="glob=%d tree=%d capped=%s" % (len(glob_set), len(got), capped))


# -- entry point -----------------------------------------------------------------


def run(client, root, info):
    notes = []
    try:
        checks = []

        tree_text = client.call("codedb_tree", {}, timeout=300)["text"]
        got = set(tree_paths(tree_text))
        expected, excluded = refpolicy.expected_indexed(root)
        expected_set = set(expected)
        inventory = [p for p in refpolicy.walk_files(root)
                     if not p.startswith(".git/")]
        notes.append(
            "tree=%d files, expected=%d, excluded=%d (histogram %s)"
            % (len(got), len(expected_set), len(excluded),
               json.dumps(_reason_histogram(excluded), sort_keys=True)))

        checks.append(_check_inventory(
            root, got, expected_set, excluded, tree_text, inventory))

        checks.append(_check_absent_by_design(
            "2a.module-bazel-lock", root, got, "MODULE.bazel.lock",
            "double design exclusion: '.lock' is in skip_extensions AND the "
            "file is 1.4MB > 512KB cap",
            "Exclusion is silent per-call but the file does appear in the "
            "status files-count (see 2a.count-reconciliation)"))
        checks.append(_check_absent_by_design(
            "2a.npmrc-sensitive", root, got, ".npmrc",
            "'.npmrc' is in the sensitive-names list (path_security.zig)",
            "NOTE: ZERO disclosure to the client — no codedb response ever "
            "states that a root file was withheld for sensitivity; an agent "
            "auditing npm config from codedb alone cannot know .npmrc exists"))
        checks.append(_check_present(
            "2a.gitattributes-visible", root, got, ".gitattributes"))
        checks.append(_check_present(
            "2a.agents-md-visible", root, got, "AGENTS.md"))
        checks.append(_check_dir_presence(root, got, expected_set))

        checks.append(_check_count_reconciliation(
            client, root, got, excluded, tree_text))
        checks.append(_check_glob_vs_tree(client, got))

        return make_result(PROBE_ID, PROBE_NAME, root, checks, notes=notes)
    except Exception:
        tb = traceback.format_exc()
        notes.append(tb)
        crash = make_check(
            "2a.probe-crash",
            "probe module raised an exception",
            "n/a",
            [divergence("OTHER", "HIGH",
                        "probe crashed: %s" % tb.splitlines()[-1], [])],
            detail="see notes for full traceback")
        return make_result(PROBE_ID, PROBE_NAME, root, [crash], notes=notes)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: probes_visibility_codex.py <root>", file=sys.stderr)
        sys.exit(2)
    root_arg = os.path.abspath(sys.argv[1])
    client = CodedbClient(root_arg)
    try:
        client.wait_ready()
        info = {
            "synth_root": None,
            "codex_root": root_arg,
            "codedb_sha": "803db6b",
            "codex_sha": None,
            "binary": client.binary,
        }
        result = run(client, root_arg, info)
    finally:
        client.close()
    print(json.dumps(result, indent=2, ensure_ascii=False))
