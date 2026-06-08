#!/usr/bin/env python3
"""Probe orchestrator: runs all probe modules against the synthetic corpus
and /Users/shabarkin/codex, sequentially (never two servers on one root),
and writes a single JSON results file recording corpus paths, corpus SHA,
codedb SHA, and per-probe verdicts.

Usage: run_probes.py [--synth ROOT] [--codex ROOT] [--out FILE] [--only IDS]
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from driver import CodedbClient  # noqa: E402

SYNTH_DEFAULT = os.path.normpath(os.path.join(HERE, "..", "corpus-synthetic"))
CODEX_DEFAULT = "/Users/shabarkin/codex"
OUT_DEFAULT = os.path.normpath(
    os.path.join(HERE, "..", "results", "probe-results.json")
)

MODULE_NAMES = [
    "probes_regex",
    "probes_lines",
    "probes_visibility_synth",
    "probes_visibility_codex",
    "probes_search_codex",
    "probes_glob_codex",
    "probes_meta_codex",
]


def git_sha(root):
    try:
        return subprocess.run(
            ["git", "-C", root, "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
    except OSError:
        return "unknown"


def error_result(mod_name, exc_text):
    return {
        "probe": mod_name,
        "name": mod_name,
        "corpus": "n/a",
        "checks": [],
        "verdict": "ERROR",
        "notes": ["orchestrator caught exception", exc_text],
    }


def run_module(mod, root, info, make_client):
    if getattr(mod, "SELF_MANAGED", False):
        return mod.run(make_client, root, info)
    client = make_client(root)
    try:
        return mod.run(client, root, info)
    finally:
        client.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--synth", default=SYNTH_DEFAULT)
    ap.add_argument("--codex", default=CODEX_DEFAULT)
    ap.add_argument("--out", default=OUT_DEFAULT)
    ap.add_argument("--only", default="", help="comma-sep module names")
    args = ap.parse_args()

    synth = os.path.abspath(args.synth)
    codex = os.path.abspath(args.codex)

    info = {
        "synth_root": synth,
        "codex_root": codex,
        "codedb_sha": git_sha(os.path.join(HERE, "..", "..")),
        "codex_sha": git_sha(codex),
        "binary": os.path.normpath(
            os.path.join(HERE, "..", "..", "zig-out", "bin", "codedb")
        ),
    }

    def make_client(root):
        client = CodedbClient(root)
        client.wait_ready(timeout=900, settle=3.0)
        return client

    only = {m.strip() for m in args.only.split(",") if m.strip()}
    modules = []
    for name in MODULE_NAMES:
        if only and name not in only:
            continue
        try:
            modules.append(__import__(name))
        except Exception:
            modules.append(name)  # marker: import failed

    # group: synth-rooted first, then codex-rooted, SELF_MANAGED last
    def order_key(mod):
        if isinstance(mod, str):
            return (3, mod)
        if getattr(mod, "SELF_MANAGED", False):
            return (2, mod.__name__)
        return (0 if mod.ROOT == "synth" else 1, mod.__name__)

    results = []
    for mod in sorted(modules, key=order_key):
        if isinstance(mod, str):
            results.append(error_result(mod, "import failed"))
            print("[ERROR] import failed: %s" % mod, file=sys.stderr)
            continue
        root = synth if mod.ROOT == "synth" else codex
        label = "%s (probe %s, root=%s)" % (
            mod.__name__, getattr(mod, "PROBE_ID", "?"), mod.ROOT
        )
        print("=== running %s" % label, file=sys.stderr)
        try:
            res = run_module(mod, root, info, make_client)
        except Exception:
            res = error_result(mod.__name__, traceback.format_exc())
        results.append(res)
        print("    verdict: %s" % res.get("verdict"), file=sys.stderr)

    payload = {
        "meta": {
            "generated_utc": datetime.datetime.utcnow().isoformat() + "Z",
            "synth_root": synth,
            "codex_root": codex,
            "codex_sha": info["codex_sha"],
            "codedb_sha": info["codedb_sha"],
            "binary": info["binary"],
            "platform": sys.platform,
        },
        "results": results,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)

    print("\n=== verdict summary ===")
    for r in results:
        n_div = sum(len(c["divergences"]) for c in r.get("checks", []))
        print("%-28s %-10s checks=%d divergences=%d" % (
            str(r.get("probe")), r.get("verdict"),
            len(r.get("checks", [])), n_div,
        ))
    print("results written to %s" % args.out)


if __name__ == "__main__":
    main()
