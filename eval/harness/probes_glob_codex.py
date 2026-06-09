#!/usr/bin/env python3
"""Probe 7: codedb_glob parity + [...] character-class contract gap (codex root).

Isolates glob-MATCHING correctness from visibility policy: an in-module
reference matcher (faithful port of src/explore.zig matchGlob —
full-path anchored; '*' non-'/' run; '**' across '/'; '?' one non-'/' byte;
single-level '{a,b}' needing a comma, else literal '{'; '[a-z]' character
classes that never match '/'; byte-case-sensitive; bare slash-free p promoted to '**/p' when
len(p)+3 < 256) is applied to the indexed list from codedb_tree (uncapped).

Checks (codex patterns; auto-adapts to the synthetic corpus for self-test):
  7.1 brace+recursive set parity vs reference matcher (diff = HIGH engine
      bug); filesystem-truth counts in detail only (visibility = probe 2a)
  7.2 '[ac]*' character class parity vs the documented matcher and mainstream
      glob tools
  7.3 documented bare-pattern auto-promotion '*.rs' == '**/*.rs'
  7.4 single '*' does not recurse past '/'
  7.5 byte-case-sensitivity '**/*.RS' -> 'no matches' (fd/zsh ecosystem
      comparison, INFO)
  7.6 nested brace '**/*.{r{s,on}}' -> silent 'no matches', no diagnostic
      (MEDIUM); fd/rg handle nested braces

All codedb_glob calls pass max_results=5000 (documented silent clamp); a
side returning exactly 5000 is flagged as possibly truncated.
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
from treeparse import tree_paths

PROBE_ID = "7"
PROBE_NAME = "glob parity + [...] classes"
ROOT = "codex"
SELF_MANAGED = False

FD = os.path.expanduser("~/.local/bin/fd")
RG = "/opt/homebrew/bin/rg"
ZSH = "/bin/zsh"
GLOB_CAP = 5000


# --- reference matcher: faithful port of explore.zig matchGlob ---------------


def _find_brace(pat, open_i):
    """explore.zig findBraceAlternatives: index of closing '}' iff the group
    contains a comma and no nested '{'; else None (=> '{' is literal)."""
    has_comma = False
    i = open_i + 1
    while i < len(pat):
        c = pat[i]
        if c == "{":
            return None
        if c == ",":
            has_comma = True
        elif c == "}":
            return i if has_comma else None
        i += 1
    return None


def _seg_boundary(path, pos):
    return pos == 0 or (pos <= len(path) and path[pos - 1] == "/")


def _match_char_class(pat, gi, ch):
    """Return (matched, next_gi) for a valid [...] class, or None if '[' is
    unterminated/invalid and should be treated literally."""
    if gi >= len(pat) or pat[gi] != "[":
        return None
    i = gi + 1
    negated = False
    if i < len(pat) and pat[i] in ("!", "^"):
        negated = True
        i += 1

    saw_member = False
    matched = False
    if i < len(pat) and pat[i] == "]":
        saw_member = True
        if ch == "]":
            matched = True
        i += 1

    while i < len(pat):
        if pat[i] == "]" and saw_member:
            raw_match = not matched if negated else matched
            return (ch != "/" and raw_match, i + 1)

        start = pat[i]
        saw_member = True
        if i + 2 < len(pat) and pat[i + 1] == "-" and pat[i + 2] != "]":
            finish = pat[i + 2]
            lo, hi = (start, finish) if start <= finish else (finish, start)
            if lo <= ch <= hi:
                matched = True
            i += 3
        else:
            if ch == start:
                matched = True
            i += 1

    return None


def _match_fragment_then(frag, gi, path, ti, rest):
    """explore.zig matchGlobFragmentThen: match brace alternative `frag`
    (no braces inside by construction), then continue with `rest`."""
    while gi < len(frag):
        c = frag[gi]
        if c == "*":
            if gi + 1 < len(frag) and frag[gi + 1] == "*":
                slash_term = gi + 2 < len(frag) and frag[gi + 2] == "/"
                nxt = gi + 2 + (1 if slash_term else 0)
                if _match_fragment_then(frag, nxt, path, ti, rest):
                    return True
                for k in range(ti, len(path)):
                    if slash_term and not _seg_boundary(path, k + 1):
                        continue
                    if _match_fragment_then(frag, nxt, path, k + 1, rest):
                        return True
                return False
            if _match_fragment_then(frag, gi + 1, path, ti, rest):
                return True
            k = ti
            while k < len(path) and path[k] != "/":
                if _match_fragment_then(frag, gi + 1, path, k + 1, rest):
                    return True
                k += 1
            return False
        if c == "?":
            if ti >= len(path) or path[ti] == "/":
                return False
            gi += 1
            ti += 1
        elif c == "[":
            if ti >= len(path):
                return False
            cls = _match_char_class(frag, gi, path[ti])
            if cls is not None:
                matched, next_gi = cls
                if not matched:
                    return False
                gi = next_gi
                ti += 1
            else:
                if path[ti] != c:
                    return False
                gi += 1
                ti += 1
        else:
            if ti >= len(path) or path[ti] != c:
                return False
            gi += 1
            ti += 1
    return _match_rec(rest, 0, path, ti)


def _match_rec(pat, gi, path, ti):
    """explore.zig matchGlobRec."""
    while gi < len(pat):
        c = pat[gi]
        if c == "*":
            if gi + 1 < len(pat) and pat[gi + 1] == "*":
                slash_term = gi + 2 < len(pat) and pat[gi + 2] == "/"
                rest = gi + 2 + (1 if slash_term else 0)
                if _match_rec(pat, rest, path, ti):
                    return True
                for k in range(ti, len(path)):
                    if slash_term and not _seg_boundary(path, k + 1):
                        continue
                    if _match_rec(pat, rest, path, k + 1):
                        return True
                return False
            if _match_rec(pat, gi + 1, path, ti):
                return True
            k = ti
            while k < len(path) and path[k] != "/":
                if _match_rec(pat, gi + 1, path, k + 1):
                    return True
                k += 1
            return False
        if c == "?":
            if ti >= len(path) or path[ti] == "/":
                return False
            gi += 1
            ti += 1
        elif c == "[":
            if ti >= len(path):
                return False
            cls = _match_char_class(pat, gi, path[ti])
            if cls is not None:
                matched, next_gi = cls
                if not matched:
                    return False
                gi = next_gi
                ti += 1
            else:
                if path[ti] != c:
                    return False
                gi += 1
                ti += 1
        elif c == "{":
            close = _find_brace(pat, gi)
            if close is not None:
                alt_start = gi + 1
                i = alt_start
                while i <= close:
                    if i == close or pat[i] == ",":
                        if _match_fragment_then(
                            pat[alt_start:i], 0, path, ti, pat[close + 1 :]
                        ):
                            return True
                        alt_start = i + 1
                    i += 1
                return False
            if ti >= len(path) or path[ti] != c:
                return False
            gi += 1
            ti += 1
        else:
            if ti >= len(path) or path[ti] != c:
                return False
            gi += 1
            ti += 1
    return ti == len(path)


def ref_glob_match(pattern, path):
    """Documented codedb glob semantics incl. bare-pattern auto-promotion
    (mcp.zig normalizeGlobPattern: promote only when len+3 < 256)."""
    if "/" not in pattern and len(pattern) + 3 < 256:
        pattern = "**/" + pattern
    return _match_rec(pattern, 0, path, 0)


def ref_glob_set(pattern, indexed):
    return sorted(p for p in indexed if ref_glob_match(pattern, p))


# --- subprocess references ----------------------------------------------------


def _run(cmd, cwd=None, timeout=120):
    try:
        p = subprocess.run(
            cmd,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
        return (
            p.returncode,
            p.stdout.decode("utf-8", "replace"),
            p.stderr.decode("utf-8", "replace"),
        )
    except Exception as exc:  # noqa: BLE001 — recorded, never raised
        return -1, "", repr(exc)


def zsh_glob(root, patterns):
    """Filesystem glob via zsh 5.9 (native '**/', '[..]', braces; (N.) =
    nullglob + plain-files-only). Case-sensitive, skips dotfiles, ignores
    .gitignore — the classic-shell user expectation baseline."""
    script = "setopt nullglob; print -rl -- " + " ".join(
        "%s(N.)" % p for p in patterns
    )
    rc, out, err = _run([ZSH, "-fc", script], cwd=root)
    paths = sorted({l for l in out.splitlines() if l.strip()})
    return paths, rc, err.strip().splitlines()[0] if err.strip() else ""


def fd_glob_count(root, glob_pattern, extra=(), scope="."):
    """fd -g basename glob (NO --full-path: fd's full-path mode matches the
    ABSOLUTE path, so leading '**/<class>*' can false-match components of
    the root's own prefix, e.g. 'eval' for '[es]*' — verified)."""
    cmd = [FD, "-t", "f"] + list(extra) + ["-g", glob_pattern, scope]
    rc, out, err = _run(cmd, cwd=root)
    n = len([l for l in out.splitlines() if l.strip()])
    return n, rc, err.strip().splitlines()[0] if err.strip() else ""


def rg_files_glob(root, glob_pattern):
    rc, out, err = _run([RG, "--files", "-g", glob_pattern], cwd=root)
    n = len([l for l in out.splitlines() if l.strip()])
    return n, rc, err.strip().splitlines()[0] if err.strip() else ""


# --- codedb wrappers ----------------------------------------------------------


def codedb_glob_call(client, pattern, max_results=GLOB_CAP):
    res = client.call(
        "codedb_glob", {"pattern": pattern, "max_results": max_results}
    )
    text = res["text"]
    stripped = text.strip()
    if res["is_error"] or stripped.startswith("error"):
        return {"text": text, "is_error": True, "paths": None}
    if stripped == "no matches":
        return {"text": text, "is_error": False, "paths": []}
    paths = sorted({l.strip() for l in text.splitlines() if l.strip()})
    return {"text": text, "is_error": False, "paths": paths}


def glob_tool_description(client):
    """Quote codedb_glob's own description from tools/list."""
    try:
        resp = client._request("tools/list", {}, 30)
        for tool in resp.get("result", {}).get("tools", []):
            if tool.get("name") == "codedb_glob":
                return tool.get("description", "")
        return "(codedb_glob not present in tools/list)"
    except Exception as exc:  # noqa: BLE001
        return "(tools/list failed: %r)" % (exc,)


def compare_sets(cd_paths, ref_paths, cap=GLOB_CAP):
    """Cap-aware set diff: if codedb returned exactly `cap` paths, compare
    against the first `cap` of the lexicographically sorted reference
    (codedb sorts then truncates). Returns (missing, extra, cap_note)."""
    ref_sorted = sorted(ref_paths)
    cap_note = ""
    if len(cd_paths) == cap:
        ref_sorted = ref_sorted[:cap]
        cap_note = (
            "codedb returned exactly %d paths (= max_results cap, silent "
            "truncation possible); reference compared on its first %d "
            "sorted entries" % (cap, cap)
        )
    missing, extra = contract.diff_sets(set(cd_paths), set(ref_sorted))
    return missing, extra, cap_note


# --- per-root pattern configuration --------------------------------------------


def make_config(root):
    if os.path.isdir(os.path.join(root, "codex-rs")):
        return {
            "flavor": "codex",
            "main_pattern": "codex-rs/**/*.{rs,toml}",
            "main_fs_globs": ["codex-rs/**/*.rs", "codex-rs/**/*.toml"],
            "main_fd_basenames": ["*.rs", "*.toml"],
            "fd_scope": "codex-rs",
            "class_pattern": "codex-rs/[ac]*/**/*.rs",
            "class_fs_glob": "codex-rs/[ac]*/**/*.rs",
            "class_regex": re.compile(
                r"^codex-rs/[ac][^/]*/(?:[^/]*/)*[^/]*\.rs$"
            ),
            "promo_bare": "*.rs",
            "promo_full": "**/*.rs",
            "direct_nonempty": "codex-rs/*.toml",
            "direct_empty": "codex-rs/*.rs",
            "case_pattern": "**/*.RS",
            "fd_case_glob": "*.RS",
            "nested_pattern": "**/*.{r{s,on}}",
            "nested_basename": "*.{r{s,on}}",
            "nested_intended": "**/*.{rs,ron}",
        }
    return {
        "flavor": "synthetic",
        "main_pattern": "**/*.{c,py}",
        "main_fs_globs": ["**/*.c", "**/*.py"],
        "main_fd_basenames": ["*.c", "*.py"],
        "fd_scope": ".",
        "class_pattern": "[es]*/**/*.txt",
        "class_fs_glob": "[es]*/**/*.txt",
        "class_regex": re.compile(r"^[es][^/]*/(?:[^/]*/)*[^/]*\.txt$"),
        "promo_bare": "*.c",
        "promo_full": "**/*.c",
        "direct_nonempty": "encodings/*.txt",
        "direct_empty": "encodings/*.c",
        "case_pattern": "**/*.TXT",
        "fd_case_glob": "*.TXT",
        "nested_pattern": "**/*.{t{xt,oml}}",
        "nested_basename": "*.{t{xt,oml}}",
        "nested_intended": "**/*.{txt,toml}",
    }


# --- checks ---------------------------------------------------------------------


def _check_brace_parity(client, root, indexed, cfg, notes):
    pat = cfg["main_pattern"]
    res = codedb_glob_call(client, pat)
    divs = []
    detail = []
    if res["paths"] is None:
        divs.append(contract.divergence(
            "OTHER", "HIGH",
            "codedb_glob(%r) unexpectedly errored: %r" % (pat, res["text"][:200])))
        cd = []
    else:
        cd = res["paths"]
        ref = ref_glob_set(pat, indexed)
        missing, extra, cap_note = compare_sets(cd, ref)
        if cap_note:
            detail.append(cap_note)
            if len(ref) > GLOB_CAP:
                divs.append(contract.divergence(
                    "TRUNCATED_UNDISCLOSED", "MEDIUM",
                    "reference matcher finds %d paths but codedb returned the "
                    "5000 cap with no truncation marker" % len(ref)))
        if missing:
            divs.append(contract.divergence(
                "MISSING", "HIGH",
                "glob engine bug: %d paths match per the documented semantics "
                "(reference matcher over codedb_tree paths) but codedb_glob "
                "omits them" % len(missing), missing))
        if extra:
            divs.append(contract.divergence(
                "EXTRA", "HIGH",
                "glob engine bug: codedb_glob returned %d paths the documented "
                "semantics do not match" % len(extra), extra))
        detail.append("codedb=%d ref_matcher=%d" % (len(cd), len(ref)))
    fs_paths, fs_rc, fs_err = zsh_glob(root, cfg["main_fs_globs"])
    fd_total = 0
    for base in cfg["main_fd_basenames"]:
        n, _, _ = fd_glob_count(root, base, scope=cfg["fd_scope"])
        fd_total += n
    detail.append(
        "filesystem truth (INFO, visibility covered by probe 2a): "
        "zsh recursive glob=%d (rc=%d%s), fd default whole-tree "
        "basenames %r=%d"
        % (
            len(fs_paths),
            fs_rc,
            " err=" + fs_err if fs_err else "",
            cfg["main_fd_basenames"],
            fd_total,
        )
    )
    if res["paths"] is not None and len(fs_paths) != len(cd):
        notes.append(
            "7.1: codedb indexed-glob count %d vs zsh filesystem count %d "
            "— visibility delta (gitignore/dotfiles/policy), probe 2a scope"
            % (len(cd), len(fs_paths))
        )
    return contract.make_check(
        "7.1-brace-recursive-parity",
        "codedb_glob{pattern:%r,max_results:%d}" % (pat, GLOB_CAP),
        "in-module reference matcher (documented semantics) over "
        "codedb_tree paths; zsh -fc 'print -rl -- %s(N.)' for fs truth"
        % " ".join(cfg["main_fs_globs"]),
        divs,
        "; ".join(detail),
    )


def _check_char_class(client, root, indexed, cfg, notes):
    pat = cfg["class_pattern"]
    res = codedb_glob_call(client, pat)
    divs = []
    detail = []
    desc = glob_tool_description(client)
    expected_user = sorted(
        p for p in indexed if cfg["class_regex"].match(p)
    )
    fs_paths, fs_rc, fs_err = zsh_glob(root, [cfg["class_fs_glob"]])
    rg_n, rg_rc, rg_err = rg_files_glob(root, cfg["class_fs_glob"])
    detail.append(
        "class-aware expectation: %d indexed paths (regex over tree), "
        "zsh fs glob=%d (rc=%d%s), rg --files -g %r=%d (rc=%d%s)"
        % (
            len(expected_user),
            len(fs_paths),
            fs_rc,
            " err=" + fs_err if fs_err else "",
            cfg["class_fs_glob"],
            rg_n,
            rg_rc,
            " err=" + rg_err if rg_err else "",
        )
    )
    if res["paths"] is None:
        divs.append(contract.divergence(
            "ERROR_DISCLOSED", "INFO",
            "codedb_glob(%r) refused with an explicit error (good "
            "disclosure): %r" % (pat, res["text"][:200])))
        detail.append("codedb errored — disclosed, not silent")
    else:
        cd = res["paths"]
        ref = ref_glob_set(pat, indexed)
        missing, extra, cap_note = compare_sets(cd, ref)
        if cap_note:
            detail.append(cap_note)
        if missing or extra:
            divs.append(contract.divergence(
                "OTHER", "HIGH",
                "engine inconsistency: codedb disagrees with its own "
                "documented [...] character-class semantics (missing=%d extra=%d)"
                % (len(missing), len(extra)), (missing + extra)))
        detail.append(
            "codedb returned %d paths; character-class reference "
            "agrees on %d" % (len(cd), len(ref))
        )
        if sorted(cd) != expected_user and expected_user:
            divs.append(contract.divergence(
                "OTHER", "HIGH",
                "documented [...] class produced the wrong "
                "result: codedb returned %d paths for %r while every "
                "mainstream glob engine (zsh: %d files, rg: %d) matches the "
                "character class — %d indexed files a glob user would expect "
                "are silently absent; response is a plain %r with no error "
                "or warning. tools/list description: %r"
                % (len(cd), pat, len(fs_paths), rg_n, len(expected_user),
                   res["text"].strip()[:40], desc),
                expected_user[:10]))
        elif not expected_user:
            notes.append(
                "7.2: corpus has no paths matching the class pattern — "
                "expectation gap not demonstrable on this root"
            )
    return contract.make_check(
        "7.2-char-class-silent-literal",
        "codedb_glob{pattern:%r,max_results:%d}" % (pat, GLOB_CAP),
        "zsh -fc glob %r (class-aware), rg --files -g, class regex over "
        "indexed set" % cfg["class_fs_glob"],
        divs,
        "; ".join(detail),
    )


def _check_auto_promotion(client, root, indexed, cfg, notes):
    bare, full = cfg["promo_bare"], cfg["promo_full"]
    res_a = codedb_glob_call(client, bare)
    res_b = codedb_glob_call(client, full)
    divs = []
    detail = []
    if res_a["paths"] is None or res_b["paths"] is None:
        divs.append(contract.divergence(
            "OTHER", "HIGH", "codedb_glob errored: bare=%r full=%r"
            % (res_a["text"][:100], res_b["text"][:100])))
    else:
        a, b = res_a["paths"], res_b["paths"]
        if len(a) == GLOB_CAP or len(b) == GLOB_CAP:
            detail.append(
                "one side returned exactly %d (cap) — sets compared "
                "post-truncation (sorted, so still expected equal)"
                % GLOB_CAP
            )
        if set(a) != set(b):
            only_a = sorted(set(a) - set(b))
            only_b = sorted(set(b) - set(a))
            divs.append(contract.divergence(
                "OTHER", "HIGH",
                "documented auto-promotion broken: %r returned %d paths, %r "
                "returned %d (only-bare=%d only-full=%d)"
                % (bare, len(a), full, len(b), len(only_a), len(only_b)),
                (only_a + only_b)))
        else:
            detail.append(
                "confirmed: %r and %r return identical %d-path sets "
                "(documented bare-pattern promotion to '**/<p>')"
                % (bare, full, len(a))
            )
        ref = ref_glob_set(full, indexed)
        missing, extra, cap_note = compare_sets(b, ref)
        if cap_note:
            detail.append(cap_note)
        if missing or extra:
            divs.append(contract.divergence(
                "MISSING" if missing else "EXTRA", "HIGH",
                "%r disagrees with reference matcher over tree paths "
                "(missing=%d extra=%d)" % (full, len(missing), len(extra)),
                (missing + extra)))
        else:
            detail.append("reference matcher parity on %d paths" % len(ref))
    return contract.make_check(
        "7.3-bare-pattern-auto-promotion",
        "codedb_glob{pattern:%r} vs codedb_glob{pattern:%r} (both "
        "max_results:%d)" % (bare, full, GLOB_CAP),
        "set equality + in-module reference matcher over codedb_tree paths",
        divs,
        "; ".join(detail),
    )


def _check_single_star_no_recurse(client, root, indexed, cfg, notes):
    divs = []
    detail = []
    for pat, label in (
        (cfg["direct_nonempty"], "nonempty"),
        (cfg["direct_empty"], "empty"),
    ):
        res = codedb_glob_call(client, pat)
        if res["paths"] is None:
            divs.append(contract.divergence(
                "OTHER", "HIGH",
                "codedb_glob(%r) errored: %r" % (pat, res["text"][:150])))
            continue
        cd = res["paths"]
        ref = ref_glob_set(pat, indexed)
        missing, extra, _ = compare_sets(cd, ref)
        if missing or extra:
            divs.append(contract.divergence(
                "MISSING" if missing else "EXTRA", "HIGH",
                "%r: codedb vs reference matcher diff (missing=%d extra=%d)"
                % (pat, len(missing), len(extra)), (missing + extra)))
        prefix = pat.rsplit("/", 1)[0] + "/"
        deep = [p for p in cd if "/" in p[len(prefix):]]
        if deep:
            divs.append(contract.divergence(
                "OTHER", "HIGH",
                "single '*' crossed '/': %r returned nested paths" % pat,
                deep))
        fs_paths, fs_rc, _ = zsh_glob(root, [pat])
        detail.append(
            "%r (%s): codedb=%d ref=%d zsh_fs=%d (rc=%d)"
            % (pat, label, len(cd), len(ref), len(fs_paths), fs_rc)
        )
        if set(fs_paths) != set(cd):
            detail.append(
                "%r fs-vs-indexed delta (INFO, visibility — probe 2a): "
                "only_fs=%r only_codedb=%r"
                % (
                    pat,
                    sorted(set(fs_paths) - set(cd))[:5],
                    sorted(set(cd) - set(fs_paths))[:5],
                )
            )
    return contract.make_check(
        "7.4-single-star-direct-children-only",
        "codedb_glob{pattern:%r} / codedb_glob{pattern:%r}"
        % (cfg["direct_nonempty"], cfg["direct_empty"]),
        "reference matcher over tree paths + zsh non-recursive glob "
        "(direct children only)",
        divs,
        "; ".join(detail),
    )


def _check_case_sensitivity(client, root, indexed, cfg, notes):
    pat = cfg["case_pattern"]
    res = codedb_glob_call(client, pat)
    divs = []
    detail = []
    ref = ref_glob_set(pat, indexed)
    fs_paths, fs_rc, _ = zsh_glob(root, [pat])
    fd_default_n, fd_rc, fd_err = fd_glob_count(root, cfg["fd_case_glob"])
    fd_i_n, _, _ = fd_glob_count(root, cfg["fd_case_glob"], extra=("-i",))
    if res["paths"] is None:
        divs.append(contract.divergence(
            "OTHER", "HIGH",
            "codedb_glob(%r) errored: %r" % (pat, res["text"][:150])))
        cd = []
    else:
        cd = res["paths"]
        missing, extra, _ = compare_sets(cd, ref)
        if missing or extra:
            divs.append(contract.divergence(
                "MISSING" if missing else "EXTRA", "HIGH",
                "%r: codedb vs byte-case-sensitive reference matcher diff "
                "(missing=%d extra=%d)" % (pat, len(missing), len(extra)),
                (missing + extra)))
    detail.append(
        "codedb=%d ref_matcher=%d zsh_fs=%d (rc=%d, POSIX case-sensitive "
        "parity) fd_default=%d (rc=%d%s) fd_-i=%d"
        % (
            len(cd),
            len(ref),
            len(fs_paths),
            fs_rc,
            fd_default_n,
            fd_rc,
            " err=" + fd_err if fd_err else "",
            fd_i_n,
        )
    )
    if fd_i_n > 0 and not cd:
        divs.append(contract.divergence(
            "OTHER", "INFO",
            "ecosystem-expectation gap (documented design: byte-case-"
            "sensitive): codedb %r -> 'no matches' while case-insensitive "
            "tooling (fd -i, or fd's smart-case with a lowercase glob) finds "
            "%d files; zsh agrees with codedb (%d). Note: APFS is case-"
            "insensitive, so shell users CAN open files by wrong-case name "
            "yet glob 0 of them" % (pat, fd_i_n, len(fs_paths))))
    return contract.make_check(
        "7.5-byte-case-sensitivity",
        "codedb_glob{pattern:%r,max_results:%d}" % (pat, GLOB_CAP),
        "zsh -fc glob (case-sensitive baseline), fd -g %r default vs -i"
        % cfg["fd_case_glob"],
        divs,
        "; ".join(detail),
    )


def _check_nested_brace(client, root, indexed, cfg, notes):
    pat = cfg["nested_pattern"]
    intended = cfg["nested_intended"]
    res = codedb_glob_call(client, pat)
    divs = []
    detail = []
    ref = ref_glob_set(pat, indexed)
    intended_set = ref_glob_set(intended, indexed)
    fd_n, fd_rc, fd_err = fd_glob_count(root, cfg["nested_basename"])
    rg_n, rg_rc, rg_err = rg_files_glob(root, cfg["nested_basename"])
    detail.append(
        "intended single-level pattern %r matches %d indexed files; "
        "ecosystem on nested basename form %r: fd rc=%d n=%d%s | "
        "rg --files rc=%d n=%d%s"
        % (
            intended,
            len(intended_set),
            cfg["nested_basename"],
            fd_rc,
            fd_n,
            " err=" + fd_err if fd_err else "",
            rg_rc,
            rg_n,
            " err=" + rg_err if rg_err else "",
        )
    )
    if res["paths"] is None:
        divs.append(contract.divergence(
            "ERROR_DISCLOSED", "INFO",
            "codedb_glob(%r) refused with an explicit error (good "
            "disclosure): %r" % (pat, res["text"][:150])))
    else:
        cd = res["paths"]
        missing, extra, _ = compare_sets(cd, ref)
        if missing or extra:
            divs.append(contract.divergence(
                "OTHER", "HIGH",
                "engine inconsistency on nested brace: codedb vs documented "
                "literal-'{' reference (missing=%d extra=%d)"
                % (len(missing), len(extra)), (missing + extra)))
        detail.append(
            "codedb=%d ref_matcher(literal-'{')=%d" % (len(cd), len(ref))
        )
        if not cd and intended_set:
            divs.append(contract.divergence(
                "OTHER", "MEDIUM",
                "silent downgrade, no diagnostic: nested brace %r is treated "
                "as literal bytes and returns %r — the intended files (%d "
                "for %r) are silently absent and nothing tells the caller "
                "the pattern syntax was unsupported"
                % (pat, res["text"].strip()[:30], len(intended_set), intended),
                intended_set[:10]))
        elif not intended_set:
            notes.append(
                "7.6: no indexed files match the intended pattern %r — "
                "silent-downgrade impact not demonstrable on this root"
                % intended
            )
    return contract.make_check(
        "7.6-nested-brace-silent-downgrade",
        "codedb_glob{pattern:%r,max_results:%d}" % (pat, GLOB_CAP),
        "reference matcher (literal '{' per findBraceAlternatives), fd -g "
        "and rg --files -g on the nested pattern, intended set %r"
        % intended,
        divs,
        "; ".join(detail),
    )


# --- entry ----------------------------------------------------------------------


def run(client, root, info):
    notes = []
    try:
        cfg = make_config(root)
        notes.append("pattern flavor: %s" % cfg["flavor"])
        tree_text = client.call("codedb_tree")["text"]
        indexed = tree_paths(tree_text)
        notes.append("indexed files via codedb_tree: %d" % len(indexed))
        if not indexed:
            return contract.make_result(
                PROBE_ID, PROBE_NAME, root,
                [contract.make_check(
                    "7.0-tree-enumeration", "codedb_tree",
                    "non-empty indexed file list",
                    [contract.divergence(
                        "OTHER", "HIGH",
                        "codedb_tree yielded zero parseable file rows; glob "
                        "parity cannot be assessed")],
                    tree_text[:300])],
                notes)
        checks = [
            _check_brace_parity(client, root, indexed, cfg, notes),
            _check_char_class(client, root, indexed, cfg, notes),
            _check_auto_promotion(client, root, indexed, cfg, notes),
            _check_single_star_no_recurse(client, root, indexed, cfg, notes),
            _check_case_sensitivity(client, root, indexed, cfg, notes),
            _check_nested_brace(client, root, indexed, cfg, notes),
        ]
        return contract.make_result(PROBE_ID, PROBE_NAME, root, checks, notes)
    except Exception:  # noqa: BLE001 — contract: run() must never raise
        notes.append(traceback.format_exc())
        return contract.make_result(
            PROBE_ID, PROBE_NAME, root,
            [contract.make_check(
                "7.X-probe-exception", "probe body", "n/a",
                [contract.divergence(
                    "OTHER", "HIGH",
                    "probe raised an exception (see notes for traceback) — "
                    "results unusable")],
                "")],
            notes)


if __name__ == "__main__":
    from driver import CodedbClient

    if len(sys.argv) < 2:
        print("usage: probes_glob_codex.py <root>", file=sys.stderr)
        sys.exit(2)
    target_root = os.path.abspath(sys.argv[1])
    main_client = CodedbClient(target_root)
    try:
        main_client.wait_ready()
        run_info = {
            "synth_root": target_root,
            "codex_root": target_root,
            "codedb_sha": "",
            "codex_sha": "",
            "binary": main_client.binary,
        }
        outcome = run(main_client, target_root, run_info)
        print(json.dumps(outcome, indent=2, ensure_ascii=False))
    finally:
        main_client.close()
