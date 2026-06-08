#!/bin/bash
# Compass token-reduction benchmark: compass vs existing tools on a real repo.
# Usage: eval/compass-bench.sh [codex-root]
set -uo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
CDB="$EVAL_DIR/../zig-out/bin/codedb"
ROOT="${1:-$HOME/codex}"
OUT_DIR="$EVAL_DIR/results/compass-bench"
mkdir -p "$OUT_DIR"

run() { # run <label> <args...>
  local label="$1"; shift
  local f="$OUT_DIR/$label.txt"
  local t0 t1 ms
  t0=$(python3 -c 'import time; print(int(time.time()*1000))')
  (cd "$ROOT" && CODEDB_NO_CLI_PROXY=1 CODEDB_NO_CLI_DAEMON=1 "$CDB" . "$@") > "$f" 2>/dev/null
  t1=$(python3 -c 'import time; print(int(time.time()*1000))')
  ms=$((t1 - t0))
  local bytes
  bytes=$(wc -c < "$f" | tr -d ' ')
  echo "$label|$bytes|$ms"
}

echo "label|bytes|ms"

# --- Broad orientation: compass overview vs context (the direct ancestor) ---
run "b1-compass" compass "what does sandboxing look like here"
run "b1-context" context "what does sandboxing look like here"
run "b2-compass" compass "how does shell command approval work"
run "b2-context" context "how does shell command approval work"
run "b3-compass" compass "how does session rollout recording work"
run "b3-context" context "how does session rollout recording work"
run "b4-compass" compass "where are MCP tools defined and dispatched"
run "b4-context" context "where are MCP tools defined and dispatched"

# --- Narrow define: compass define vs symbol ---
run "d1-compass" compass --intent define SandboxPolicy
run "d1-symbol" symbol SandboxPolicy
run "d2-compass" compass --intent define TurnContext
run "d2-symbol" symbol TurnContext
run "d3-compass" compass --intent define RolloutRecorder
run "d3-symbol" symbol RolloutRecorder

# --- Narrow callers: compass callers vs callers ---
run "c1-compass" compass --intent callers process_exec_tool_call
run "c1-callers" callers process_exec_tool_call
run "c2-compass" compass --intent callers run_turn
run "c2-callers" callers run_turn
run "c3-compass" compass --intent callers Config
run "c3-callers" callers Config

# --- Ambiguity honesty ---
run "a1-compass" compass "auth"
run "a2-compass" compass "what calls auth"
run "a3-compass" compass "show render flow"
