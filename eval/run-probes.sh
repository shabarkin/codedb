#!/bin/bash
# Entry point: codedb trust-probe run.
#   eval/run-probes.sh [codex-root]
# Regenerates the synthetic corpus, then runs all probes against it and the
# codex corpus, writing eval/results/probe-results.json (records corpus
# paths, codex SHA, codedb SHA, per-probe pass/fail).
set -euo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_ROOT="${1:-${CODEDB_CODEX_ROOT:-$HOME/codex}}"

"$EVAL_DIR/make-corpus.sh"

# Nuke any persisted index for the synthetic corpus root: probes_meta_codex's
# staleness check intentionally exercises (and can poison) the persisted
# index, and stale data dirs survive corpus regeneration.
SYNTH_ROOT="$EVAL_DIR/corpus-synthetic"
for d in "$HOME"/.codedb/projects/*/; do
  [ -f "$d/project.txt" ] || continue
  if [ "$(cat "$d/project.txt")" = "$SYNTH_ROOT" ]; then
    rm -rf "$d"
    echo "cleared persisted index: $d"
  fi
done

exec python3 "$EVAL_DIR/harness/run_probes.py" \
  --synth "$EVAL_DIR/corpus-synthetic" \
  --codex "$CODEX_ROOT" \
  --out "$EVAL_DIR/results/probe-results.json"
