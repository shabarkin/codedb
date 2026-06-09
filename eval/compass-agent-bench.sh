#!/bin/bash
# Deterministic no-LLM agent-navigation benchmark for code_compass.
# Usage: eval/compass-agent-bench.sh [codex-root] [out-json]
set -uo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$HOME/codex}"
OUT="${2:-$EVAL_DIR/results/compass-agent-bench.json}"
CDB="${CODEDB_BINARY:-$EVAL_DIR/../zig-out/bin/codedb}"

mkdir -p "$(dirname "$OUT")"

exec python3 "$EVAL_DIR/harness/agent_bench.py" \
  --binary "$CDB" \
  --root "$ROOT" \
  --out "$OUT"
