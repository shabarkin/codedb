#!/usr/bin/env python3
"""Probe 10+symbols: determinism, staleness honesty, CLI surface, symbol
spot-parity. ROOT='codex', SELF_MANAGED — run(make_client, root, info).

Sub-checks:
  10a  warm determinism (literal x5 ordered, regex x5 set+order) on one server
  10b  restart determinism (fresh server, same queries, vs 10a run 1)
  sym  codedb_symbol spot-parity vs hand-verified rg ground truth (codex only)
  outl codedb_outline contains expected symbol at expected line (codex only)
  10c  one-shot CLI `codedb <root> search <q>` surface (no server open)
  10d  staleness honesty on info['synth_root'] (mutate control.c, poll)

Ground truth for the symbol table was collected read-only with rg 15.1.0 on
/Users/shabarkin/codex @ c9ae0f48a13022191285d998bf10234ccf20313a.
"""
import json
import os
import re
import subprocess
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from driver import CodedbClient, DEFAULT_BINARY, parse_search, search_total
from contract import make_result, make_check, divergence

PROBE_ID = "10+symbols"
PROBE_NAME = "determinism, staleness honesty, CLI surface, symbol spot-parity"
ROOT = "codex"
SELF_MANAGED = True

CODEX_LIT_Q = "tokio::spawn"          # 387 rg lines @ c9ae0f48 (case-sens)
CODEX_RE_Q = "fn [a-z_]+_test"        # 194 rg lines @ c9ae0f48 >> 50 cap
FALLBACK_LIT_Q = "NEEDLE"             # synthetic corpus self-test
FALLBACK_RE_Q = "[a-z]+ line [0-9]"   # synthetic corpus self-test

STALE_TOKEN = "STALENESS_PROBE_XYZQ"
STALE_POLL_S = 0.25
STALE_WINDOW_S = 15.0

# (name, expected_relpath, expected_line, kind, rg_evidence, known_other_defs)
SYMBOLS = [
    ("format_user_shell_command_record", "codex-rs/core/src/user_shell_command.rs", 19,
     "rust fn", "rg -n 'fn format_user_shell_command_record' -> user_shell_command.rs:19 (unique; #[cfg(test)] attr on line 18)", []),
    ("normalize_thread_name", "codex-rs/core/src/util.rs", 109,
     "rust fn", "rg -n 'fn normalize_thread_name' -> util.rs:109 (unique def)", []),
    ("set_default_oss_provider", "codex-rs/core/src/config/mod.rs", 1957,
     "rust fn", "rg -n 'fn set_default_oss_provider' -> config/mod.rs:1957 (unique)", []),
    ("syntax_theme_edit", "codex-rs/core/src/config/edit.rs", 86,
     "rust fn", "rg -n 'fn syntax_theme_edit' -> config/edit.rs:86 (unique)", []),
    ("web_search_action_detail", "codex-rs/core/src/web_search.rs", 18,
     "rust fn", "rg -n 'fn web_search_action_detail' -> web_search.rs:18 (+second def)",
     ["codex-rs/tui/src/history_cell/search.rs:13"]),
    ("prependPathDirs", "sdk/typescript/src/exec.ts", 441,
     "ts fn", "rg -n 'function prependPathDirs' -> exec.ts:441 (unique)", []),
    ("codexExecSpy", "sdk/typescript/tests/codexExecSpy.ts", 12,
     "ts fn", "rg -n 'function codexExecSpy' -> codexExecSpy.ts:12 (unique)", []),
    ("resolveNativePackage", "sdk/typescript/src/exec.ts", 412,
     "ts fn", "rg -n 'function resolveNativePackage' -> exec.ts:412 (+JS def)",
     ["codex-cli/bin/codex.js:85"]),
    ("formatter_groups", "scripts/format.py", 37,
     "py def", "rg -n 'def formatter_groups' -> scripts/format.py:37 (unique)", []),
    ("write_tar_zst_archive", "scripts/codex_package/archive.py", 71,
     "py def", "rg -n 'def write_tar_zst_archive' -> archive.py:71 (unique)", []),
]

OUTLINE_FILES = [
    ("codex-rs/core/src/util.rs", "normalize_thread_name", 109),
    ("sdk/typescript/src/exec.ts", "prependPathDirs", 441),
    ("scripts/format.py", "formatter_groups", 37),
]

_SYM_ROW = re.compile(r"^  (.+):(\d+) \((\w+)\)")
_OUTLINE_ROW = re.compile(r"^  L(\d+): (\w+) (.+?)(?:  // .*)?$")
_SEQ_RE = re.compile(r"seq: (\d+)")
_COUNT_RE = re.compile(r"(\d+) results for")

STALE_MARKERS = ("stale", "scanning", "scan in progress", "rescan",
                 "indexing", "pending", "refresh", "debounce", "out of date")


def _key(hits):
    return ["%s:%d" % (p, ln) for (p, ln, _c) in hits]


def _search(client, query, **kw):
    args = {"query": query}
    args.update(kw)
    r = client.call("codedb_search", args)
    return parse_search(r["text"]), r


def _det_divergences(runs, label, capped):
    """runs: list of [(path,line,content)] from repeated identical calls.
    Returns divergences comparing every run to run 1."""
    divs = []
    base = runs[0]
    set_examples, order_examples = [], []
    set_changed = order_changed = False
    bset = set(_key(base))
    for i, r in enumerate(runs[1:], start=2):
        if r == base:
            continue
        rset = set(_key(r))
        if rset != bset:
            set_changed = True
            only1 = sorted(bset - rset)[:4]
            onlyi = sorted(rset - bset)[:4]
            set_examples.append(
                "run1 vs run%d: only-run1=%s only-run%d=%s" % (i, only1, i, onlyi))
        else:
            order_changed = True
            for j, (x, y) in enumerate(zip(_key(base), _key(r))):
                if x != y:
                    order_examples.append(
                        "run1 vs run%d first diff idx %d: %s vs %s" % (i, j, x, y))
                    break
            else:
                order_examples.append(
                    "run1 vs run%d: same path:line order, content text differs" % i)
    if set_changed:
        divs.append(divergence(
            "ORDER", "HIGH",
            "%s: result SET changed across identical warm calls%s" % (
                label, " (capped query: cap-subset selection unstable)" if capped else ""),
            set_examples))
    elif order_changed:
        divs.append(divergence(
            "ORDER", "MEDIUM",
            "%s: same result set but ordering differs across identical warm calls" % label,
            order_examples))
    return divs


def _restart_divergences(a_run, b_run, label, capped):
    divs = []
    a_k, b_k = _key(a_run), _key(b_run)
    a_set, b_set = set(a_k), set(b_k)
    if a_set != b_set:
        missing = sorted(a_set - b_set)
        extra = sorted(b_set - a_set)
        if capped:
            divs.append(divergence(
                "ORDER", "HIGH",
                "%s: capped result SET changed across server restart "
                "(silent nondeterminism: cap selects a different subset; "
                "no marker discloses that results are a cap-dependent sample). "
                "%d hits dropped, %d gained" % (label, len(missing), len(extra)),
                ["lost: %s" % m for m in missing[:5]] +
                ["gained: %s" % e for e in extra[:5]]))
        else:
            if missing:
                divs.append(divergence(
                    "MISSING", "HIGH",
                    "%s: uncapped result set lost %d hits after restart" % (
                        label, len(missing)), missing))
            if extra:
                divs.append(divergence(
                    "EXTRA", "HIGH",
                    "%s: uncapped result set gained %d hits after restart" % (
                        label, len(extra)), extra))
    elif a_k != b_k:
        ex = []
        for j, (x, y) in enumerate(zip(a_k, b_k)):
            if x != y:
                ex.append("first diff idx %d: pre-restart=%s post-restart=%s" % (j, x, y))
                break
        divs.append(divergence(
            "ORDER", "MEDIUM",
            "%s: same set, different ordering after server restart "
            "(an agent diffing two sessions sees reshuffled output)" % label, ex))
    return divs


def _parse_cli_rows(text):
    """One-shot CLI rows: '  path:line  content' (two spaces, no colon after
    line — different from MCP's 'path:line: content')."""
    hits = []
    for row in text.splitlines():
        if not row.startswith("  "):
            continue
        body = row[2:]
        i = 0
        while True:
            i = body.find(":", i)
            if i == -1:
                break
            j = i + 1
            while j < len(body) and body[j].isdigit():
                j += 1
            if j > i + 1 and (j == len(body) or body[j:j + 2] == "  "):
                hits.append((body[:i], int(body[i + 1:j]), body[j:].strip()))
                break
            i += 1
    return hits


def _parse_symbol_rows(text):
    out = []
    for row in text.splitlines():
        m = _SYM_ROW.match(row)
        if m:
            out.append((m.group(1), int(m.group(2)), m.group(3)))
    return out


def _parse_outline_rows(text):
    out = []
    for row in text.splitlines():
        m = _OUTLINE_ROW.match(row)
        if m:
            out.append((int(m.group(1)), m.group(2), m.group(3)))
    return out


def _parse_seq(text):
    m = _SEQ_RE.search(text)
    return int(m.group(1)) if m else None


def _tool_names(client):
    try:
        resp = client._request("tools/list", {}, 30)
        return {t.get("name") for t in resp.get("result", {}).get("tools", [])}
    except Exception:
        return set()


def _stale_signal(text):
    scrubbed = text.replace(STALE_TOKEN, "").lower()
    return [m for m in STALE_MARKERS if m in scrubbed]


def _exc_check(check_id, what):
    return make_check(
        check_id, what, "-",
        [divergence("OTHER", "HIGH", "probe section raised: see detail", [])],
        traceback.format_exc())


def run(make_client, root, info):
    checks = []
    notes = []
    try:
        binary = info.get("binary") or DEFAULT_BINARY
        is_codex = os.path.isdir(os.path.join(root, "codex-rs"))
        lit_q = CODEX_LIT_Q if is_codex else FALLBACK_LIT_Q
        re_q = CODEX_RE_Q if is_codex else FALLBACK_RE_Q
        notes.append("root=%s is_codex=%s lit_q=%r re_q=%r binary=%s" % (
            root, is_codex, lit_q, re_q, binary))
        if not is_codex:
            notes.append("SELF-TEST MODE: root is not the codex repo; symbol/"
                         "outline ground-truth checks are skipped and "
                         "fallback queries are used for 10a/10b/10c.")

        lit_args = {"max_results": 10000, "max_per_file": 10000}
        re_args = {"regex": True, "max_results": 50}

        lit_runs_a, re_runs_a = [], []
        lit_total_a = None

        # ---- 10a: warm determinism on one server -------------------------
        client_a = None
        try:
            client_a = make_client(root)
            try:
                client_a.wait_ready()
            except Exception:
                notes.append("client A wait_ready failed: %s" % traceback.format_exc(limit=1))
            notes.append("server_version=%s" % getattr(client_a, "server_version", "?"))

            for _ in range(5):
                hits, r = _search(client_a, lit_q, **lit_args)
                lit_runs_a.append(hits)
                if lit_total_a is None:
                    lit_total_a = search_total(r["text"])
            divs = _det_divergences(lit_runs_a, "literal %r warm x5" % lit_q, capped=False)
            checks.append(make_check(
                "10a-literal-warm",
                "codedb_search query=%r max_results=10000 max_per_file=10000 x5 (same server)" % lit_q,
                "self-consistency (no external oracle): identical ordered lists expected",
                divs,
                "run lengths=%s header total=%s" % ([len(x) for x in lit_runs_a], lit_total_a)))

            for _ in range(5):
                hits, r = _search(client_a, re_q, **re_args)
                re_runs_a.append(hits)
            divs = _det_divergences(re_runs_a, "regex %r warm x5 (cap 50)" % re_q, capped=True)
            checks.append(make_check(
                "10a-regex-warm",
                "codedb_search query=%r regex=true max_results=50 x5 (same server)" % re_q,
                "self-consistency: source predicts hash-map iteration order for "
                "regex candidates (explore.zig searchContentRegexCapped)",
                divs,
                "run lengths=%s (match population >> 50 on codex: rg counts 194 lines)"
                % [len(x) for x in re_runs_a]))
        except Exception:
            checks.append(_exc_check("10a-error", "10a warm determinism section"))
        finally:
            if client_a is not None:
                try:
                    client_a.close()
                except Exception:
                    pass

        # ---- 10b: restart determinism + symbols (client B) ----------------
        client_b = None
        try:
            client_b = make_client(root)
            try:
                client_b.wait_ready()
            except Exception:
                notes.append("client B wait_ready failed: %s" % traceback.format_exc(limit=1))

            if lit_runs_a:
                lit_b, _ = _search(client_b, lit_q, **lit_args)
                divs = _restart_divergences(lit_runs_a[0], lit_b,
                                            "literal %r restart" % lit_q, capped=False)
                checks.append(make_check(
                    "10b-literal-restart",
                    "codedb_search query=%r (fresh server) vs same query on previous server" % lit_q,
                    "self-consistency across server restart (snapshot/trigram reload path)",
                    divs,
                    "pre-restart n=%d post-restart n=%d" % (len(lit_runs_a[0]), len(lit_b))))
            else:
                notes.append("10b-literal-restart skipped: no 10a literal baseline")

            if re_runs_a:
                re_b, _ = _search(client_b, re_q, **re_args)
                divs = _restart_divergences(re_runs_a[0], re_b,
                                            "regex %r restart (cap 50)" % re_q, capped=True)
                checks.append(make_check(
                    "10b-regex-restart",
                    "codedb_search query=%r regex=true max_results=50 (fresh server)" % re_q,
                    "self-consistency across server restart",
                    divs,
                    "pre-restart n=%d post-restart n=%d" % (len(re_runs_a[0]), len(re_b))))
            else:
                notes.append("10b-regex-restart skipped: no 10a regex baseline")

            # ---- symbols spot-parity (codex only) -------------------------
            if is_codex:
                tools = _tool_names(client_b)
                if tools and "codedb_symbol" not in tools:
                    checks.append(make_check(
                        "sym-tool-present", "tools/list", "codedb_symbol expected per source @803db6b",
                        [divergence("OTHER", "HIGH",
                                    "codedb_symbol missing from tools/list", sorted(tools)[:10])],
                        ""))
                for (name, exp_path, exp_line, kind, evidence, other_defs) in SYMBOLS:
                    try:
                        r = client_b.call("codedb_symbol", {"name": name})
                        rows = _parse_symbol_rows(r["text"])
                        divs = []
                        same_path = [(p, ln, k) for (p, ln, k) in rows if p == exp_path]
                        exact = [t for t in same_path if t[1] == exp_line]
                        extras = ["%s:%d (%s)" % (p, ln, k) for (p, ln, k) in rows
                                  if p != exp_path and
                                  "%s:%d" % (p, ln) not in other_defs]
                        if exact:
                            detail = "found %s:%d among %d result(s)" % (exp_path, exp_line, len(rows))
                        elif same_path:
                            got = same_path[0][1]
                            delta = abs(got - exp_line)
                            sev = "INFO" if delta <= 2 else "MEDIUM"
                            divs.append(divergence(
                                "LINE_OFF", sev,
                                "symbol %r: right file %s but line %d != expected %d "
                                "(delta %d; <=2 may be attribute/decorator attachment)" % (
                                    name, exp_path, got, exp_line, delta),
                                ["%s:%d (%s)" % t for t in same_path[:5]]))
                            detail = "file matched, line off; rows=%d" % len(rows)
                        else:
                            divs.append(divergence(
                                "MISSING", "HIGH",
                                "symbol %r (%s): expected def %s:%d absent from codedb_symbol "
                                "results (%d rows)" % (name, kind, exp_path, exp_line, len(rows)),
                                ["%s:%d (%s)" % t for t in rows[:6]] or
                                [r["text"].splitlines()[0] if r["text"] else "(empty)"]))
                            detail = "expected location absent"
                        if extras:
                            detail += "; unexpected extra defs (noted, not judged): %s" % extras[:5]
                        if other_defs:
                            detail += "; known other defs: %s" % other_defs
                        checks.append(make_check(
                            "sym-%s" % name,
                            "codedb_symbol name=%r" % name,
                            evidence, divs, detail))
                    except Exception:
                        checks.append(_exc_check("sym-%s" % name,
                                                 "codedb_symbol name=%r" % name))

                for (rel, sym_name, exp_line) in OUTLINE_FILES:
                    try:
                        r = client_b.call("codedb_outline", {"path": rel})
                        divs = []
                        if r["is_error"] or r["text"].startswith("error:"):
                            divs.append(divergence(
                                "MISSING", "HIGH",
                                "codedb_outline %r errored: %s" % (
                                    rel, r["text"].splitlines()[0] if r["text"] else "(empty)"),
                                []))
                            detail = "outline call failed"
                        else:
                            rows = _parse_outline_rows(r["text"])
                            named = [(ln, k) for (ln, k, n) in rows if n == sym_name]
                            if any(ln == exp_line for (ln, _k) in named):
                                detail = "%s present at L%d (rows=%d)" % (sym_name, exp_line, len(rows))
                            elif named:
                                got = named[0][0]
                                delta = abs(got - exp_line)
                                sev = "INFO" if delta <= 2 else "MEDIUM"
                                divs.append(divergence(
                                    "LINE_OFF", sev,
                                    "outline %s: symbol %r at L%d, expected L%d (delta %d)" % (
                                        rel, sym_name, got, exp_line, delta),
                                    ["L%d (%s)" % t for t in named[:5]]))
                                detail = "symbol present, line off"
                            else:
                                divs.append(divergence(
                                    "MISSING", "HIGH",
                                    "outline %s: symbol %r absent (%d outline rows)" % (
                                        rel, sym_name, len(rows)),
                                    [("L%d %s %s" % (ln, k, n)) for (ln, k, n) in rows[:6]]))
                                detail = "symbol absent from outline"
                        checks.append(make_check(
                            "outline-%s" % rel,
                            "codedb_outline path=%r" % rel,
                            "rg ground truth: %s defined at %s:%d" % (sym_name, rel, exp_line),
                            divs, detail))
                    except Exception:
                        checks.append(_exc_check("outline-%s" % rel,
                                                 "codedb_outline path=%r" % rel))
        except Exception:
            checks.append(_exc_check("10b-error", "10b restart/symbols section"))
        finally:
            if client_b is not None:
                try:
                    client_b.close()
                except Exception:
                    pass

        # ---- 10c: one-shot CLI surface (no server open on root) ----------
        try:
            cmd = [binary, root, "search", lit_q]
            t0 = time.monotonic()
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  timeout=300)
            elapsed = time.monotonic() - t0
            out_text = proc.stdout.decode("utf-8", "replace")
            err_text = proc.stderr.decode("utf-8", "replace")
            cli_hits = _parse_cli_rows(out_text)
            m = _COUNT_RE.search(out_text)
            declared = int(m.group(1)) if m else None
            divs = []
            if proc.returncode != 0:
                divs.append(divergence(
                    "OTHER", "HIGH",
                    "one-shot CLI exited %d" % proc.returncode,
                    [out_text[:200], err_text[:200]]))
            checks.append(make_check(
                "10c-cli-runs",
                "subprocess: codedb <root> search %r (no MCP server running)" % lit_q,
                "CLI must run standalone; format observed: status header "
                "'<check> N results for \"q\"  <dur>' then '  path:line  content' rows "
                "(NOT the MCP 'path:line: content' format)",
                divs,
                "exit=%d rows=%d declared=%s elapsed=%.1fs first_lines=%r" % (
                    proc.returncode, len(cli_hits), declared, elapsed,
                    out_text.splitlines()[:2])))

            mcp_set = set(_key(lit_runs_a[0])) if lit_runs_a else set()
            divs = []
            disclosure = ("truncat" in out_text.lower() or "more match" in out_text.lower()
                          or "shown" in out_text.lower())
            if len(cli_hits) == 50 and len(mcp_set) > 50 and not disclosure:
                divs.append(divergence(
                    "TRUNCATED_UNDISCLOSED", "MEDIUM",
                    "CLI search hard-caps at 50 (main.zig searchContent(...,50)); header "
                    "declares '%s results' with no marker that %d+ more exist (MCP total "
                    "for the same query: %d). docs/cli.md documents 'search <query> [max]' "
                    "only for the separate codedb-cli HTTP client; the one-shot binary "
                    "accepts no max argument." % (declared, len(mcp_set) - 50, len(mcp_set)),
                    []))
            elif len(cli_hits) < 50 and len(mcp_set) > len(cli_hits) and not disclosure:
                divs.append(divergence(
                    "TRUNCATED_UNDISCLOSED", "MEDIUM",
                    "CLI returned %d rows but MCP uncapped total is %d, with no truncation "
                    "marker and the header confidently declaring '%s results'. Consistent "
                    "with the engine default per-file cap (min(max_results,5) when >1 file "
                    "matches): the MCP surface discloses per-file truncation via "
                    "'(more matches truncated)' rows, the one-shot CLI does not." % (
                        len(cli_hits), len(mcp_set), declared),
                    sorted(mcp_set - set(_key(cli_hits)))[:6]))
            checks.append(make_check(
                "10c-cli-truncation",
                "codedb <root> search %r (one-shot)" % lit_q,
                "MCP codedb_search same query max_results=10000 -> %d hits" % len(mcp_set),
                divs,
                "cli rows=%d declared=%s disclosure_marker=%s" % (
                    len(cli_hits), declared, disclosure)))

            divs = []
            if mcp_set:
                cli_keys = _key(cli_hits)
                inter = [k for k in cli_keys if k in mcp_set]
                frac = (len(inter) / len(cli_keys)) if cli_keys else 0.0
                if not cli_hits:
                    divs.append(divergence(
                        "MISSING", "HIGH",
                        "CLI returned 0 rows where MCP found %d hits" % len(mcp_set),
                        [out_text[:200]]))
                elif frac < 0.8:
                    only_cli = [k for k in cli_keys if k not in mcp_set]
                    divs.append(divergence(
                        "OTHER", "MEDIUM",
                        "CLI/MCP overlap only %.0f%% (CLI hits not in MCP uncapped set)" % (
                            frac * 100), only_cli[:8]))
                detail = "overlap %d/%d (%.0f%%) of CLI hits present in MCP set" % (
                    len(inter), len(cli_keys), frac * 100)
            else:
                detail = "no MCP baseline (10a failed); overlap not computed"
            checks.append(make_check(
                "10c-cli-mcp-overlap",
                "codedb <root> search %r vs MCP codedb_search baseline" % lit_q,
                "same engine both sides; CLI top-50 expected subset of MCP uncapped set",
                divs, detail))
        except Exception:
            checks.append(_exc_check("10c-error", "10c CLI section"))

        # ---- 10d: staleness honesty on synth_root -------------------------
        synth_root = info.get("synth_root")
        client_s = None
        control = os.path.join(synth_root, "control.c") if synth_root else None
        orig_bytes = None
        mutated = False
        try:
            if not synth_root or not os.path.isfile(control):
                notes.append("10d skipped: synth_root missing or has no control.c (%r)" % synth_root)
            else:
                with open(control, "rb") as fh:
                    orig_bytes = fh.read()
                client_s = make_client(synth_root)
                try:
                    client_s.wait_ready()
                except Exception:
                    notes.append("client S wait_ready failed: %s" % traceback.format_exc(limit=1))

                pre_hits, _ = _search(client_s, STALE_TOKEN, max_results=10)
                divs = []
                if pre_hits:
                    divs.append(divergence(
                        "OTHER", "MEDIUM",
                        "corpus dirty: %r already present before mutation "
                        "(leftover from a previous aborted run?)" % STALE_TOKEN,
                        _key(pre_hits)[:5]))
                checks.append(make_check(
                    "10d-token-absent-baseline",
                    "codedb_search query=%r before mutation" % STALE_TOKEN,
                    "token must not pre-exist in the synthetic corpus",
                    divs, "pre-mutation hits=%d" % len(pre_hits)))

                # uncapped NEEDLE baseline — used after the mutation cycle to
                # detect persisted-index poisoning across a cold restart
                needle_args = {"max_results": 10000, "max_per_file": 10000}
                needle_before, _ = _search(client_s, "NEEDLE", **needle_args)

                ch_before = client_s.call("codedb_changes", {"since": 0})
                seq_before = _parse_seq(ch_before["text"])

                with open(control, "ab") as fh:
                    fh.write(b"// " + STALE_TOKEN.encode() + b"\n")
                mutated = True
                t0 = time.monotonic()
                first_hit = None
                polls_zero = 0
                signals = []
                hit_rows = []
                while time.monotonic() - t0 < STALE_WINDOW_S:
                    hits, r = _search(client_s, STALE_TOKEN, max_results=10)
                    sig = _stale_signal(r["text"])
                    if sig:
                        signals.append("t=%.2fs markers=%s" % (time.monotonic() - t0, sig))
                    if hits:
                        first_hit = time.monotonic() - t0
                        hit_rows = _key(hits)
                        break
                    polls_zero += 1
                    time.sleep(STALE_POLL_S)

                ch_after = client_s.call("codedb_changes", {"since": 0})
                seq_after = _parse_seq(ch_after["text"])

                doc_quote = ("docs/mcp.md:237 claims 'The watcher debounces filesystem "
                             "events for ~500 ms'; no such debounce exists in source — "
                             "src/watcher.zig incrementalLoop sleeps 2000ms per cycle "
                             "('Poll every 2s — gentle on CPU, fast enough to catch saves')")
                divs = []
                if first_hit is None:
                    divs.append(divergence(
                        "STALE", "HIGH",
                        "appended token never appeared in codedb_search within %.0fs "
                        "(%d polls returned 0 results, no staleness marker in any "
                        "response). %s" % (STALE_WINDOW_S, polls_zero, doc_quote), []))
                elif first_hit > 6.0:
                    divs.append(divergence(
                        "STALE", "HIGH",
                        "stale (0-result) responses served for %.2fs after the write with "
                        "no staleness marker — exceeds even the real 2s poll cycle. %s" % (
                            first_hit, doc_quote), []))
                elif first_hit > 0.6:
                    divs.append(divergence(
                        "STALE", "MEDIUM",
                        "stale (0-result) responses served for %.2fs (%d polls) after the "
                        "write; NO response carried any staleness signal, so an agent "
                        "cannot distinguish 'no match' from 'not yet indexed'. %s" % (
                            first_hit, polls_zero, doc_quote), []))
                detail = ("first-hit latency=%s polls_zero=%d hit_rows=%s "
                          "staleness_signals_seen=%s" % (
                              ("%.2fs" % first_hit) if first_hit is not None else "never",
                              polls_zero, hit_rows[:3], signals[:5] or "none"))
                if first_hit is not None and hit_rows and hit_rows[0] != "control.c:3":
                    divs.append(divergence(
                        "LINE_OFF", "MEDIUM",
                        "appended token expected at control.c:3, got %s" % hit_rows[0],
                        hit_rows[:3]))
                checks.append(make_check(
                    "10d-staleness-appear",
                    "append '// %s' to control.c then poll codedb_search every %.2fs" % (
                        STALE_TOKEN, STALE_POLL_S),
                    "filesystem truth: token on disk at t=0; %s" % doc_quote,
                    divs, detail))

                divs = []
                if seq_before is not None and seq_after is not None:
                    if first_hit is not None and seq_after <= seq_before:
                        divs.append(divergence(
                            "OTHER", "MEDIUM",
                            "search picked up the edit but codedb_changes seq did not "
                            "advance (%s -> %s): change feed understates activity" % (
                                seq_before, seq_after), []))
                    detail = "seq before=%d after=%d; control.c in changes: %s" % (
                        seq_before, seq_after, "control.c" in ch_after["text"])
                else:
                    divs.append(divergence(
                        "OTHER", "MEDIUM",
                        "could not parse seq from codedb_changes header",
                        [ch_before["text"][:80], ch_after["text"][:80]]))
                    detail = "unparseable changes header"
                checks.append(make_check(
                    "10d-changes-seq",
                    "codedb_changes since=0 before/after the control.c mutation",
                    "store seq must advance when a watched file changes",
                    divs, detail))

                # restore and watch the token disappear
                with open(control, "wb") as fh:
                    fh.write(orig_bytes)
                mutated = False
                t0 = time.monotonic()
                gone = None
                polls_present = 0
                while time.monotonic() - t0 < STALE_WINDOW_S:
                    hits, r = _search(client_s, STALE_TOKEN, max_results=10)
                    if not hits:
                        gone = time.monotonic() - t0
                        break
                    polls_present += 1
                    time.sleep(STALE_POLL_S)
                divs = []
                if gone is None:
                    divs.append(divergence(
                        "STALE", "HIGH",
                        "token still served %.0fs after the file was restored to its "
                        "original bytes (deleted content kept being returned, no "
                        "staleness marker). %s" % (STALE_WINDOW_S, doc_quote), []))
                elif gone > 6.0:
                    divs.append(divergence(
                        "STALE", "HIGH",
                        "deleted line still served for %.2fs after restore — exceeds the "
                        "real 2s poll cycle. %s" % (gone, doc_quote), []))
                elif gone > 0.6:
                    divs.append(divergence(
                        "STALE", "MEDIUM",
                        "deleted line still served for %.2fs (%d polls) after restore "
                        "with no staleness signal. %s" % (gone, polls_present, doc_quote),
                        []))
                checks.append(make_check(
                    "10d-staleness-restore",
                    "restore control.c original bytes, poll until token disappears",
                    "filesystem truth: token gone from disk at t=0",
                    divs,
                    "disappear latency=%s polls_still_present=%d" % (
                        ("%.2fs" % gone) if gone is not None else "never", polls_present)))

                # cold restart after the mutation cycle: the server persists
                # snapshot + trigram state at/after incremental updates; a
                # fresh process must still see the full corpus
                needle_warm, _ = _search(client_s, "NEEDLE", **needle_args)
                client_s.close()
                client_s = None
                client_s2 = make_client(synth_root)
                try:
                    try:
                        client_s2.wait_ready()
                    except Exception:
                        notes.append("client S2 wait_ready failed: %s"
                                     % traceback.format_exc(limit=1))
                    needle_cold, _ = _search(client_s2, "NEEDLE", **needle_args)
                finally:
                    try:
                        client_s2.close()
                    except Exception:
                        pass
                divs = []
                before_set = set(_key(needle_before))
                warm_set = set(_key(needle_warm))
                cold_set = set(_key(needle_cold))
                if warm_set != before_set:
                    divs.append(divergence(
                        "MISSING" if (before_set - warm_set) else "EXTRA", "HIGH",
                        "warm 'NEEDLE' result set changed after the mutate/restore cycle "
                        "on the SAME server (file bytes are identical to baseline)",
                        sorted(before_set ^ warm_set)[:8]))
                if cold_set != before_set:
                    lost = sorted(before_set - cold_set)
                    divs.append(divergence(
                        "MISSING", "HIGH",
                        "index persistence poisoned: after one incremental update cycle, "
                        "a COLD restart on the same root returns %d 'NEEDLE' hits vs %d "
                        "before (silent — fresh server reports scan: ready and serves a "
                        "fraction of the corpus). Repro @ authoring: clean state 21 hits; "
                        "mutate+restore control.c on a live server; every later cold "
                        "start (CLI and MCP) returns 1 hit until ~/.codedb/projects/"
                        "<hash> and codedb.snapshot are deleted." % (
                            len(cold_set), len(before_set)),
                        lost[:8] + sorted(cold_set - before_set)[:2]))
                checks.append(make_check(
                    "10d-cold-restart-after-mutation",
                    "codedb_search 'NEEDLE' uncapped: baseline vs warm-after-cycle vs "
                    "fresh-server-after-cycle on synth_root",
                    "file contents byte-identical to baseline at all three points; "
                    "result sets must match",
                    divs,
                    "baseline n=%d warm n=%d cold-restart n=%d" % (
                        len(before_set), len(warm_set), len(cold_set))))
                if cold_set != before_set:
                    notes.append(
                        "WARNING: synth_root persisted index state "
                        "(~/.codedb/projects/<hash> + codedb.snapshot) is now "
                        "poisoned; later cold starts on this root will serve "
                        "partial results until that state is deleted.")
        except Exception:
            checks.append(_exc_check("10d-error", "10d staleness section"))
        finally:
            if mutated and orig_bytes is not None:
                try:
                    with open(control, "wb") as fh:
                        fh.write(orig_bytes)
                except OSError:
                    notes.append("FAILED to restore %s — corpus left mutated!" % control)
            if client_s is not None:
                try:
                    client_s.close()
                except Exception:
                    pass

    except Exception:
        checks.append(make_check(
            "fatal", "probe body", "-",
            [divergence("OTHER", "HIGH", "unhandled exception in run()", [])],
            traceback.format_exc()))
    return make_result(PROBE_ID, PROBE_NAME, root, checks, notes)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: probes_meta_codex.py <root>", file=sys.stderr)
        sys.exit(2)
    test_root = os.path.abspath(sys.argv[1])

    def _mk(r):
        return CodedbClient(r)

    test_info = {
        "synth_root": test_root,
        "codex_root": test_root,
        "codedb_sha": "",
        "codex_sha": "",
        "binary": DEFAULT_BINARY,
    }
    result = run(_mk, test_root, test_info)
    print(json.dumps(result, indent=2, ensure_ascii=False))
