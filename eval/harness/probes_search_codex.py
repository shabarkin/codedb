#!/usr/bin/env python3
"""Probe 5+6: truncation disclosure + literal set parity (codex corpus).

Probe 6 — literal set parity: five hardcoded literal queries, codedb_search
with max_results=10000/max_per_file=10000 vs rg -i -F -n --no-ignore --hidden
-g '!.git', reference filtered to the codedb_tree indexed-path set (isolates
search correctness from visibility policy, which probe 2a owns).

Probe 5 — truncation disclosure:
  (a) huge query with DEFAULT args -> header says 20, is any total/truncation
      marker present?
  (b) same query max_results=100000 (+ max_per_file=10000 to isolate the
      total cap) -> silent clamp to 10000?
  (c) tools/list schema: are default-20 / clamp-10000 / glob-200 / glob-5000
      disclosed? (verbatim evidence for severity judgment of a/b/d)
  (d) codedb_glob '**/*.rs' default args -> silent 200-path cap?
  (e) per-file cap positive control: default max_per_file (5 when >1 file
      matches) MUST disclose via '... (more matches truncated)' rows and the
      '(N shown, M truncated by per-file cap)' footer.

Measured at codex @ c9ae0f48a13022191285d998bf10234ccf20313a with
/opt/homebrew/bin/rg -i -F -c --no-ignore --hidden -g '!.git' (matched-line
totals, == codedb's one-hit-per-line counting):
    tokio::spawn   ->   387   (Rust, '::' punctuation)
    import type    ->   653   (TypeScript, multi-token with space)
    def test_      ->   191   (Python)
    unwrap()       ->  2698   (punctuation '()')
    Result<        ->  8432   (punctuation '<', large but < 9500 cap guard)
    fn             -> 32835   (truncation driver, >> 10000 hard cap)
    **/*.rs files  ->  2107   (rg --files -g '*.rs', > 200 glob default)
    per-file ctrl  ->  codex-rs/core-plugins/src/manager_tests.rs has 244
                       'unwrap()' matched lines (>10 in a single file)
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
import treeparse
from driver import CodedbClient, parse_search, search_total

PROBE_ID = "5+6"
PROBE_NAME = "truncation disclosure + literal set parity"
ROOT = "codex"
SELF_MANAGED = False

RG = "/opt/homebrew/bin/rg"

# (query, rough rg -i -F total at authoring time) — see module docstring.
CODEX_PARITY_QUERIES = [
    ("tokio::spawn", 387),
    ("import type", 653),
    ("def test_", 191),
    ("unwrap()", 2698),
    ("Result<", 8432),
]
# Self-test fallback (synthetic corpus copy): tiny known queries.
SYNTH_PARITY_QUERIES = [
    ("NEEDLE_CONTROL", 1),
    ("def ", 2),
]

TRUNC_QUERY = "fn "          # codex: ~32,835 matched lines (>> 10000)
GLOB_PATTERN = "**/*.rs"     # codex: 2107 files (> 200 default, < 5000 clamp)
CODEX_CAP_QUERY = "unwrap()"  # one codex file holds 244 matches (> default 5)
SYNTH_CAP_QUERY = "line"     # synth: under-cap-511kb.txt holds thousands

MARKER_RE = re.compile(r"^  .*\.\.\. \(more matches truncated\)$")
FOOTER_RE = re.compile(r"^\(\d+ shown, \d+ truncated by per-file cap\)$")


# --- helpers -----------------------------------------------------------------


def _rg_lines(root, query):
    """rg literal CI line hits at root -> ([(path,line,content)], stderr_note)."""
    proc = subprocess.run(
        [RG, "-i", "-F", "-n", "--no-ignore", "--hidden", "-g", "!.git",
         "--", query],
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    out = proc.stdout.decode("utf-8", "surrogateescape")
    err = proc.stderr.decode("utf-8", "surrogateescape").strip()
    note = ""
    if proc.returncode not in (0, 1):
        note = "rg exit=%d stderr=%s" % (proc.returncode, err[:300])
    elif err:
        note = "rg stderr (%d lines)" % len(err.splitlines())
    return contract.parse_rg_lines(out), note


def _rg_file_count(root, file_glob):
    proc = subprocess.run(
        [RG, "--files", "--no-ignore", "--hidden", "-g", "!.git",
         "-g", file_glob],
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return len([l for l in proc.stdout.decode("utf-8", "surrogateescape")
                .splitlines() if l])


def _fold(b):
    """ASCII-only lowercase fold over bytes — codedb's literal CI semantics."""
    return bytes((x + 32) if 0x41 <= x <= 0x5A else x for x in b)


def _split_path_line(item):
    """'path:line' -> (path, line int)."""
    path, _, ln = item.rpartition(":")
    return path, int(ln)


def _line_contains_ascii_ci(root, item, query):
    """Does file line (1-based, split on \\n) ASCII-CI-contain query?
    Returns True/False, or None if unreadable."""
    path, ln = _split_path_line(item)
    try:
        with open(os.path.join(root, path), "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    lines = data.split(b"\n")
    if ln < 1 or ln > len(lines):
        return False
    return _fold(query.encode("utf-8")) in _fold(lines[ln - 1])


def _explain_extra(root, item):
    """Why might rg lack a hit codedb reports? Returns (reason or None)."""
    path, _ln = _split_path_line(item)
    full = os.path.join(root, path)
    if os.path.islink(full):
        return "symlink (rg does not follow symlinks by default)"
    try:
        with open(full, "rb") as fh:
            data = fh.read()
    except OSError:
        return "unreadable_now"
    if b"\x00" in data:
        return ("contains NUL beyond codedb's 512B sniff window; "
                "rg treats whole file as binary and suppresses it")
    return None


def _response_anatomy(text):
    """Split a codedb_search response into structural parts."""
    lines = text.splitlines()
    header = lines[0] if lines else ""
    markers, footers, other = [], [], []
    for row in lines[1:]:
        if not row.strip():
            continue
        if MARKER_RE.match(row):
            markers.append(row)
        elif FOOTER_RE.match(row):
            footers.append(row)
        elif row.startswith("  "):
            continue  # hit row (or unparsed indented row; hits counted via parse_search)
        else:
            other.append(row)
    return header, markers, footers, other


# --- check implementations ----------------------------------------------------


def _check_schema(client, checks):
    """(c) tools/list disclosure evidence. Returns disclosure dict."""
    cid = "5c-schema-disclosure"
    call_desc = "MCP tools/list -> codedb_search + codedb_glob schemas"
    ref_desc = ("source contract @ 803db6b: search default 20 / silent clamp "
                "10000 (mcp.zig:1469); glob default 200 / silent clamp 5000")
    disc = {
        "search_default20": False, "search_clamp10000": False,
        "glob_default200": False, "glob_clamp5000": False,
    }
    resp = client._request("tools/list", {}, 60)
    tools = resp.get("result", {}).get("tools", [])
    blobs = {}
    for t in tools:
        if t.get("name") in ("codedb_search", "codedb_glob"):
            desc = t.get("description", "")
            mr = (t.get("inputSchema", {}).get("properties", {})
                  .get("max_results", {}).get("description", ""))
            blobs[t["name"]] = {"description": desc, "max_results": mr}
    s = blobs.get("codedb_search", {})
    g = blobs.get("codedb_glob", {})
    s_all = (s.get("description", "") + " " + s.get("max_results", ""))
    g_all = (g.get("description", "") + " " + g.get("max_results", ""))
    disc["search_default20"] = "default: 20" in s_all or "default 20" in s_all
    disc["search_clamp10000"] = "10000" in s_all or "10,000" in s_all
    disc["glob_default200"] = "default: 200" in g_all or "default 200" in g_all
    disc["glob_clamp5000"] = "5000" in g_all or "5,000" in g_all
    divs = []
    undisclosed = [k for k, v in disc.items() if not v]
    if undisclosed:
        divs.append(contract.divergence(
            "OTHER", "INFO",
            "tool schema does not disclose: %s (defaults that ARE disclosed "
            "make downstream truncation MEDIUM; undisclosed clamps make the "
            "matching silent truncation HIGH)" % ", ".join(undisclosed),
            undisclosed))
    detail = json.dumps({"disclosure": disc, "verbatim": blobs},
                        ensure_ascii=False)
    checks.append(contract.make_check(cid, call_desc, ref_desc, divs, detail))
    return disc


def _check_parity(client, root, tree_set, query, rough, idx, checks):
    """(6) set parity for one literal query."""
    cid = "6-parity-%d-%s" % (idx, re.sub(r"[^A-Za-z0-9]+", "_", query).strip("_"))
    call_desc = ("codedb_search {query: %r, max_results: 10000, "
                 "max_per_file: 10000}" % query)
    ref_desc = ("rg -i -F -n --no-ignore --hidden -g '!.git' -- %r @ root, "
                "hits filtered to codedb_tree indexed paths "
                "(authoring-time rough total: %d)" % (query, rough))
    res = client.call("codedb_search",
                      {"query": query, "max_results": 10000,
                       "max_per_file": 10000},
                      timeout=300)
    if res["is_error"]:
        checks.append(contract.make_check(cid, call_desc, ref_desc, [
            contract.divergence("OTHER", "HIGH",
                                "codedb_search returned is_error",
                                [res["text"][:200]])],
            detail=res["text"][:500]))
        return
    hits = parse_search(res["text"])
    cd_set = contract.norm_hits(hits)
    ref_all, rg_note = _rg_lines(root, query)
    ref_idx = [(p, l, c) for (p, l, c) in ref_all if p in tree_set]
    ref_set = contract.norm_hits(ref_idx)
    missing, extra = contract.diff_sets(cd_set, ref_set)

    divs = []
    cap_hit = len(hits) >= 10000
    if cap_hit and missing:
        # at the 10000 hard cap the tail is legitimately absent — classify
        # missing as cap fallout, not lost hits
        divs.append(contract.divergence(
            "TRUNCATED_UNDISCLOSED", "MEDIUM",
            "codedb returned exactly %d hits (hard cap); %d reference hits "
            "absent are cap fallout, not verified losses" % (len(hits),
                                                             len(missing)),
            missing[:10]))
        missing = []
    genuine_missing, artifact_missing, unknown_missing = [], [], []
    for item in missing:
        has = _line_contains_ascii_ci(root, item, query)
        if has is True:
            genuine_missing.append(item)
        elif has is False:
            artifact_missing.append(item)
        else:
            unknown_missing.append(item)
    if genuine_missing:
        divs.append(contract.divergence(
            "MISSING", "HIGH",
            "codedb lost %d hit(s) in files it indexed; line verified to "
            "ASCII-CI-contain the query" % len(genuine_missing),
            genuine_missing))
    if unknown_missing:
        divs.append(contract.divergence(
            "MISSING", "HIGH",
            "%d reference hit(s) absent from codedb; file unreadable for "
            "verification — conservatively HIGH" % len(unknown_missing),
            unknown_missing))
    if artifact_missing:
        divs.append(contract.divergence(
            "MISSING", "INFO",
            "%d rg-only hit(s) whose line does NOT ASCII-CI-contain the "
            "query (rg Unicode case folding or line-numbering artifact) — "
            "reference artifact, not a codedb loss" % len(artifact_missing),
            artifact_missing))
    explained_extra, bad_extra = [], []
    for item in extra:
        reason = _explain_extra(root, item)
        verified = _line_contains_ascii_ci(root, item, query)
        if reason and verified is True:
            explained_extra.append("%s [%s]" % (item, reason))
        else:
            bad_extra.append("%s [reason=%s verified=%s]"
                             % (item, reason, verified))
    if explained_extra:
        divs.append(contract.divergence(
            "EXTRA", "INFO",
            "%d codedb-only hit(s) explained: real matches in files rg "
            "suppresses (binary-after-512B / symlink); codedb 512B-sniff "
            "design choice" % len(explained_extra),
            explained_extra))
    if bad_extra:
        divs.append(contract.divergence(
            "EXTRA", "HIGH",
            "%d codedb-only hit(s) with no benign explanation"
            % len(bad_extra),
            bad_extra))
    detail = ("codedb=%d (header=%s, cap_hit=%s) rg_raw=%d rg_on_indexed=%d "
              "missing=%d extra=%d%s"
              % (len(hits), search_total(res["text"]), cap_hit, len(ref_all),
                 len(ref_idx), len(missing) + len(artifact_missing)
                 + len(genuine_missing) + len(unknown_missing), len(extra),
                 ("; " + rg_note) if rg_note else ""))
    checks.append(contract.make_check(cid, call_desc, ref_desc, divs, detail))


def _check_default_truncation(client, ref_idx_total, disc, checks, res):
    """(a) default-args truncation disclosure on a huge query."""
    cid = "5a-default-truncation"
    call_desc = "codedb_search {query: %r} (DEFAULT args)" % TRUNC_QUERY
    ref_desc = ("rg -i -F -n --no-ignore --hidden -g '!.git' -- %r filtered "
                "to indexed paths -> %d matched lines"
                % (TRUNC_QUERY, ref_idx_total))
    hits = parse_search(res["text"])
    header, markers, footers, other = _response_anatomy(res["text"])
    divs = []
    if res["is_error"]:
        checks.append(contract.make_check(cid, call_desc, ref_desc, [
            contract.divergence("OTHER", "HIGH",
                                "default-args search returned is_error",
                                [res["text"][:200]])],
            detail=res["text"][:500]))
        return
    if ref_idx_total > len(hits) and not markers and not footers:
        sev = "MEDIUM" if disc.get("search_default20") else "HIGH"
        divs.append(contract.divergence(
            "TRUNCATED_UNDISCLOSED", sev,
            "default call shows %d of ~%d available hits; header presents "
            "the shown count as the result count with no 'more available' "
            "or total marker anywhere in the response (default-20 %s in the "
            "tool schema, hence %s)"
            % (len(hits), ref_idx_total,
               "IS disclosed" if disc.get("search_default20")
               else "is NOT disclosed", sev),
            [header]))
    detail = ("header=%r shown=%d header_count=%s ref_total=%d markers=%d "
              "footers=%d other_lines=%r"
              % (header, len(hits), search_total(res["text"]), ref_idx_total,
                 len(markers), len(footers), other[:3]))
    checks.append(contract.make_check(cid, call_desc, ref_desc, divs, detail))


def _check_silent_clamp(client, ref_idx_total, disc, checks):
    """(b) max_results=100000 silently clamped to 10000."""
    cid = "5b-silent-clamp"
    call_desc = ("codedb_search {query: %r, max_results: 100000, "
                 "max_per_file: 10000}" % TRUNC_QUERY)
    ref_desc = ("same rg reference: %d matched lines on indexed paths; "
                "source: mcp.zig:1469 clamps max_results to 10000"
                % ref_idx_total)
    res = client.call("codedb_search",
                      {"query": TRUNC_QUERY, "max_results": 100000,
                       "max_per_file": 10000},
                      timeout=600)
    hits = parse_search(res["text"])
    header, markers, footers, other = _response_anatomy(res["text"])
    divs = []
    if res["is_error"]:
        divs.append(contract.divergence(
            "OTHER", "MEDIUM",
            "requesting max_results=100000 errored instead of clamping",
            [res["text"][:200]]))
    elif ref_idx_total > 10000:
        if len(hits) <= 10000 and not markers and not footers and not other:
            sev = "HIGH" if not disc.get("search_clamp10000") else "MEDIUM"
            divs.append(contract.divergence(
                "TRUNCATED_UNDISCLOSED", sev,
                "asked for 100000 results, got %d (~%d exist); no clamp "
                "notice, no truncation marker, header presents shown count "
                "as the result count; the 10000 clamp is %s in the tool "
                "schema" % (len(hits), ref_idx_total,
                            "not mentioned" if not disc.get("search_clamp10000")
                            else "mentioned"),
                [header]))
        elif len(hits) > 10000:
            divs.append(contract.divergence(
                "OTHER", "INFO",
                "clamp did not engage: %d results returned" % len(hits), []))
    detail = ("header=%r shown=%d ref_total=%d clamp_disclosed_in_schema=%s "
              "markers=%d footers=%d other_lines=%r"
              % (header, len(hits), ref_idx_total,
                 disc.get("search_clamp10000"), len(markers), len(footers),
                 other[:3]))
    checks.append(contract.make_check(cid, call_desc, ref_desc, divs, detail))


def _check_glob_cap(client, root, tree_set, disc, checks):
    """(d) codedb_glob default-200 silent cap."""
    cid = "5d-glob-default-cap"
    call_desc = ("codedb_glob {pattern: %r} default args, then "
                 "max_results=5000" % GLOB_PATTERN)
    rg_count = _rg_file_count(root, "*.rs")
    tree_count = len([p for p in tree_set if p.endswith(".rs")])
    ref_desc = ("rg --files --no-ignore --hidden -g '!.git' -g '*.rs' -> %d "
                "files; codedb_tree .rs paths -> %d" % (rg_count, tree_count))
    res_d = client.call("codedb_glob", {"pattern": GLOB_PATTERN}, timeout=120)
    res_f = client.call("codedb_glob",
                        {"pattern": GLOB_PATTERN, "max_results": 5000},
                        timeout=120)

    def glob_paths(res):
        text = res["text"].strip()
        if text == "no matches":
            return []
        return [r.strip() for r in text.splitlines()
                if r.strip() and not r.startswith("(")]

    n_default = len(glob_paths(res_d))
    n_full = len(glob_paths(res_f))
    non_path = [r for r in res_d["text"].splitlines()
                if r.strip() and (r.startswith("(") or " " in r.strip())
                and r.strip() != "no matches"]
    divs = []
    if n_full > n_default and not non_path:
        sev = "MEDIUM" if disc.get("glob_default200") else "HIGH"
        divs.append(contract.divergence(
            "TRUNCATED_UNDISCLOSED", sev,
            "default glob returned %d of %d matching paths as a bare list "
            "with no count/truncation marker (default-200 %s in the tool "
            "schema)" % (n_default, n_full,
                         "IS disclosed" if disc.get("glob_default200")
                         else "is NOT disclosed"),
            []))
    if n_full == 5000:
        divs.append(contract.divergence(
            "TRUNCATED_UNDISCLOSED", "MEDIUM",
            "max_results=5000 result hit the silent 5000 clamp exactly; "
            "full set may be larger", []))
    if n_full and tree_count and n_full != tree_count:
        divs.append(contract.divergence(
            "OTHER", "MEDIUM",
            "glob(max_results=5000) count %d != codedb_tree .rs count %d "
            "(same server, same index — internal inconsistency)"
            % (n_full, tree_count), []))
    detail = ("n_default=%d n_full=%d rg_files=%d tree_rs=%d "
              "non_path_rows=%r" % (n_default, n_full, rg_count, tree_count,
                                    non_path[:3]))
    checks.append(contract.make_check(cid, call_desc, ref_desc, divs, detail))


def _check_perfile_disclosure(client, root, tree_set, cap_query, checks):
    """(e) per-file cap disclosure positive control + footer accuracy."""
    cid = "5e-perfile-cap-disclosure"
    call_desc = ("codedb_search {query: %r, max_results: 10000} "
                 "(max_per_file unset -> default 5/file when >1 file matches)"
                 % cap_query)
    ref_desc = ("rg -i -F -c shows files with >10 matches for %r (codex: "
                "codex-rs/core-plugins/src/manager_tests.rs has 244); "
                "disclosure contract: '  <path>: ... (more matches "
                "truncated)' rows + '(N shown, M truncated by per-file "
                "cap)' footer (mcp.zig:1529,1549)" % cap_query)
    res = client.call("codedb_search",
                      {"query": cap_query, "max_results": 10000},
                      timeout=300)
    hits = parse_search(res["text"])
    header, markers, footers, other = _response_anatomy(res["text"])
    n_files = len({p for (p, _l, _c) in hits})
    ref_all, _ = _rg_lines(root, cap_query)
    ref_idx = [(p, l, c) for (p, l, c) in ref_all if p in tree_set]
    per_file = {}
    for (p, _l, _c) in ref_idx:
        per_file[p] = per_file.get(p, 0) + 1
    files_over_5 = [p for p, n in per_file.items() if n > 5]
    ref_idx_total = len(ref_idx)
    claimed_total = None
    if footers:
        m = re.match(r"^\((\d+) shown, (\d+) truncated", footers[0])
        if m:
            claimed_total = int(m.group(1)) + int(m.group(2))
    divs = []
    if n_files <= 1:
        divs.append(contract.divergence(
            "OTHER", "INFO",
            "control did not engage: query matched %d file(s), per-file "
            "default widens to max_results" % n_files, []))
    elif files_over_5 and not (markers and footers):
        divs.append(contract.divergence(
            "TRUNCATED_UNDISCLOSED", "HIGH",
            "per-file cap truncated files with >5 matches (%d such files "
            "exist) but the documented disclosure markers/footer are absent "
            "(markers=%d footers=%d)" % (len(files_over_5), len(markers),
                                         len(footers)),
            files_over_5[:10]))
    if (claimed_total is not None
            and ref_idx_total - claimed_total > max(5, ref_idx_total // 20)):
        divs.append(contract.divergence(
            "OTHER", "MEDIUM",
            "truncation IS disclosed but the footer total understates "
            "reality: footer implies %d total matches, rg counts %d on "
            "indexed paths — the truncated-count is computed against an "
            "internal collection cap, not the true match count"
            % (claimed_total, ref_idx_total),
            [footers[0]]))
    detail = ("DISCLOSED=%s shown=%d files=%d files_over_5_in_ref=%d "
              "marker_rows=%d footer=%r claimed_total=%s "
              "rg_total_on_indexed=%d example_marker=%r"
              % (bool(markers and footers), len(hits), n_files,
                 len(files_over_5), len(markers),
                 footers[0] if footers else None, claimed_total,
                 ref_idx_total, markers[0] if markers else None))
    checks.append(contract.make_check(cid, call_desc, ref_desc, divs, detail))


# --- entry point ----------------------------------------------------------------


def run(client, root, info):
    checks = []
    notes = []
    try:
        root = os.path.abspath(root)
        is_codex = os.path.isdir(os.path.join(root, "codex-rs"))
        queries = CODEX_PARITY_QUERIES if is_codex else SYNTH_PARITY_QUERIES
        cap_query = CODEX_CAP_QUERY if is_codex else SYNTH_CAP_QUERY
        if not is_codex:
            notes.append("non-codex root: self-test mode with tiny synthetic "
                         "queries; codex expectations not asserted")

        tree_text = client.call("codedb_tree", {}, timeout=600)["text"]
        tree_set = set(treeparse.tree_paths(tree_text))
        notes.append("codedb_tree indexed files: %d" % len(tree_set))

        # (c) first: disclosure evidence feeds severity of (a)/(b)/(d)
        try:
            disc = _check_schema(client, checks)
        except Exception:
            disc = {}
            notes.append("5c failed: " + traceback.format_exc()[-800:])
            checks.append(contract.make_check(
                "5c-schema-disclosure", "tools/list", "n/a",
                [contract.divergence("OTHER", "HIGH",
                                     "schema fetch crashed; see notes")], ""))

        # (6) parity
        for i, (q, rough) in enumerate(queries, 1):
            try:
                _check_parity(client, root, tree_set, q, rough, i, checks)
            except Exception:
                notes.append("parity %r failed: " % q
                             + traceback.format_exc()[-800:])
                checks.append(contract.make_check(
                    "6-parity-%d-error" % i, "codedb_search %r" % q, "rg",
                    [contract.divergence("OTHER", "HIGH",
                                         "check crashed; see notes")], ""))

        # shared rg reference for (a)+(b)
        ref_all, rg_note = _rg_lines(root, TRUNC_QUERY)
        ref_idx_total = len([1 for (p, _l, _c) in ref_all if p in tree_set])
        if rg_note:
            notes.append("trunc-query rg note: " + rg_note)

        try:
            res_a = client.call("codedb_search", {"query": TRUNC_QUERY},
                                timeout=300)
            _check_default_truncation(client, ref_idx_total, disc, checks,
                                      res_a)
        except Exception:
            notes.append("5a failed: " + traceback.format_exc()[-800:])
            checks.append(contract.make_check(
                "5a-default-truncation", "codedb_search default", "rg",
                [contract.divergence("OTHER", "HIGH",
                                     "check crashed; see notes")], ""))
        try:
            _check_silent_clamp(client, ref_idx_total, disc, checks)
        except Exception:
            notes.append("5b failed: " + traceback.format_exc()[-800:])
            checks.append(contract.make_check(
                "5b-silent-clamp", "codedb_search max_results=100000", "rg",
                [contract.divergence("OTHER", "HIGH",
                                     "check crashed; see notes")], ""))
        try:
            _check_glob_cap(client, root, tree_set, disc, checks)
        except Exception:
            notes.append("5d failed: " + traceback.format_exc()[-800:])
            checks.append(contract.make_check(
                "5d-glob-default-cap", "codedb_glob", "rg --files",
                [contract.divergence("OTHER", "HIGH",
                                     "check crashed; see notes")], ""))
        try:
            _check_perfile_disclosure(client, root, tree_set, cap_query,
                                      checks)
        except Exception:
            notes.append("5e failed: " + traceback.format_exc()[-800:])
            checks.append(contract.make_check(
                "5e-perfile-cap-disclosure", "codedb_search", "rg -c",
                [contract.divergence("OTHER", "HIGH",
                                     "check crashed; see notes")], ""))

        return contract.make_result(PROBE_ID, PROBE_NAME, root, checks, notes)
    except Exception:
        tb = traceback.format_exc()
        checks.append(contract.make_check(
            "fatal", "probe body", "n/a",
            [contract.divergence("OTHER", "HIGH",
                                 "probe crashed; traceback in notes")],
            tb[-1500:]))
        notes.append(tb)
        return contract.make_result(PROBE_ID, PROBE_NAME, root, checks, notes)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: probes_search_codex.py <root>", file=sys.stderr)
        sys.exit(2)
    test_root = os.path.abspath(sys.argv[1])
    test_client = CodedbClient(test_root)
    try:
        test_client.wait_ready()
        test_info = {"synth_root": None, "codex_root": None,
                     "codedb_sha": None, "codex_sha": None,
                     "binary": test_client.binary}
        out = run(test_client, test_root, test_info)
    finally:
        test_client.close()
    print(json.dumps(out, indent=2, ensure_ascii=False))
