#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCES="$SCRIPT_DIR/instances.json"
RESULTS_DIR="$SCRIPT_DIR/results"
WORK_DIR="/tmp/swe-lite-bench"
CODEDB="/Users/dev/bin/codedb"
GRAPHIFY_PYTHON="/tmp/graphify-env/bin/python"
GRAPHIFY_CLI="/tmp/graphify-env/bin/graphify"
CLAUDE="claude"
MODEL="sonnet"
MAX_BUDGET="3.00"

mkdir -p "$RESULTS_DIR" "$WORK_DIR"

W='\033[1;37m' G='\033[0;32m' R='\033[0;31m' C='\033[0;36m' Y='\033[0;33m' D='\033[0;90m' N='\033[0m'

printf "\n${W}═══════════════════════════════════════════════════════${N}\n"
printf "${W}  SWE-bench Lite — codedb vs baseline (Sonnet 4.6)${N}\n"
printf "${W}═══════════════════════════════════════════════════════${N}\n"
printf "${D}  Model:      %s${N}\n" "$MODEL"
printf "${D}  Instances:  $(python3 -c "import json; print(len(json.load(open('$INSTANCES'))))")${N}\n"
printf "${D}  Budget/run: \$%s${N}\n" "$MAX_BUDGET"
printf "${D}  Date:       $(date '+%Y-%m-%d %H:%M')${N}\n\n"

INSTANCE_COUNT=$(python3 -c "import json; print(len(json.load(open('$INSTANCES'))))")

for IDX in $(seq 0 $((INSTANCE_COUNT - 1))); do
  eval "$(python3 -c "
import json, shlex
with open('$INSTANCES') as f:
    inst = json.load(f)[$IDX]
print(f'INSTANCE_ID={shlex.quote(inst[\"instance_id\"])}')
print(f'REPO={shlex.quote(inst[\"repo\"])}')
print(f'BASE_COMMIT={shlex.quote(inst[\"base_commit\"])}')
with open('$WORK_DIR/problem_$IDX.txt', 'w') as pf:
    pf.write(inst['problem_statement'])
with open('$WORK_DIR/test_patch_$IDX.patch', 'w') as tp:
    tp.write(inst['test_patch'])
with open('$WORK_DIR/gold_patch_$IDX.patch', 'w') as gp:
    gp.write(inst['patch'])
with open('$WORK_DIR/fail_tests_$IDX.txt', 'w') as ft:
    ft.write(inst['FAIL_TO_PASS'])
")"

  REPO_DIR="$WORK_DIR/repos/$INSTANCE_ID"
  PROBLEM_FILE="$WORK_DIR/problem_$IDX.txt"

  printf "${W}━━━ [%d/%d] %s ━━━${N}\n" $((IDX + 1)) "$INSTANCE_COUNT" "$INSTANCE_ID"

  # ── Step 1: Clone repo at base commit ──
  if [ -d "$REPO_DIR/.git" ]; then
    printf "  ${D}repo already cloned${N}\n"
    (cd "$REPO_DIR" && git checkout -f "$BASE_COMMIT" 2>/dev/null && git clean -fd 2>/dev/null) || true
  else
    printf "  ${C}cloning %s @ %s...${N}" "$REPO" "${BASE_COMMIT:0:8}"
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone --quiet "https://github.com/$REPO.git" "$REPO_DIR" 2>/dev/null
    (cd "$REPO_DIR" && git checkout -f "$BASE_COMMIT" 2>/dev/null) || true
    printf " ${G}done${N}\n"
  fi

  # ── Step 2: Index with codedb ──
  printf "  ${C}indexing with codedb...${N}"
  CODEDB_START=$(python3 -c 'import time; print(time.time())')
  "$CODEDB" "$REPO_DIR" index 2>/dev/null || true
  CODEDB_END=$(python3 -c 'import time; print(time.time())')
  CODEDB_INDEX_MS=$(python3 -c "print(f'{($CODEDB_END - $CODEDB_START) * 1000:.0f}')")
  FILE_COUNT=$("$CODEDB" "$REPO_DIR" status 2>/dev/null | grep -oE '[0-9]+ files' | head -1 || echo "? files")
  printf " ${G}done${N} (${CODEDB_INDEX_MS}ms, ${FILE_COUNT})\n"

  PROBLEM=$(< "$PROBLEM_FILE")

  # Build MCP config for codedb pointing at this repo
  MCP_CONFIG_FILE="$WORK_DIR/mcp_config_$IDX.json"
  python3 -c "
import json
config = {
    'mcpServers': {
        'codedb': {
            'command': '$CODEDB',
            'args': ['mcp', '$REPO_DIR']
        }
    }
}
with open('$MCP_CONFIG_FILE', 'w') as f:
    json.dump(config, f)
"

  # ── Run A: codedb-assisted ──
  CODEDB_PATCH="$RESULTS_DIR/${INSTANCE_ID}_codedb.patch"
  CODEDB_LOG="$RESULTS_DIR/${INSTANCE_ID}_codedb.log"

  if [ -s "$CODEDB_PATCH" ]; then
    printf "  ${D}codedb run already exists, skipping${N}\n"
  else
    printf "  ${C}running Sonnet + codedb...${N}"

    (cd "$REPO_DIR" && git checkout -f "$BASE_COMMIT" 2>/dev/null && git clean -fd 2>/dev/null) || true

    AGENT_PROMPT="You are solving a GitHub issue in a Python repository.

REPOSITORY: $REPO (checked out at commit ${BASE_COMMIT:0:12})
WORKING DIRECTORY: $REPO_DIR

ISSUE:
$PROBLEM

INSTRUCTIONS:
1. Use the codedb tools (codedb_search, codedb_symbol, codedb_outline, codedb_deps, codedb_callers, codedb_read, codedb_tree) to understand the codebase structure and find relevant code.
2. Find the relevant code that needs to be changed to fix this issue.
3. Make the minimal fix to resolve the issue. Edit only what is necessary.
4. Do NOT run tests. Do NOT create new test files.
5. Do NOT commit your changes. Just edit the files directly.
6. When done, say DONE and briefly explain what you changed and why."

    RUN_START=$(python3 -c 'import time; print(time.time())')
    $CLAUDE -p "$AGENT_PROMPT" \
      --model "$MODEL" \
      --mcp-config "$MCP_CONFIG_FILE" \
      --max-budget-usd "$MAX_BUDGET" \
      --dangerously-skip-permissions \
      --output-format json \
      > "$CODEDB_LOG" 2>&1 || true
    RUN_END=$(python3 -c 'import time; print(time.time())')
    CODEDB_RUN_SEC=$(python3 -c "print(f'{$RUN_END - $RUN_START:.1f}')")

    # Extract token usage from JSON output
    CODEDB_COST=$(python3 -c "import json; d=json.load(open('$CODEDB_LOG')); print(f'{d.get(\"total_cost_usd\",0):.4f}')" 2>/dev/null || echo "?")
    CODEDB_TOKENS=$(python3 -c "
import json
d=json.load(open('$CODEDB_LOG'))
u=d.get('usage',{})
inp=u.get('input_tokens',0)+u.get('cache_read_input_tokens',0)+u.get('cache_creation_input_tokens',0)
out=u.get('output_tokens',0)
print(f'{inp}in/{out}out')
" 2>/dev/null || echo "?")
    CODEDB_TURNS=$(python3 -c "import json; d=json.load(open('$CODEDB_LOG')); print(d.get('num_turns',0))" 2>/dev/null || echo "?")

    (cd "$REPO_DIR" && git diff) > "$CODEDB_PATCH" 2>/dev/null || true
    CODEDB_PATCH_LINES=$(wc -l < "$CODEDB_PATCH" | tr -d ' ')

    if [ "$CODEDB_PATCH_LINES" -gt 0 ]; then
      printf " ${G}done${N} (${CODEDB_RUN_SEC}s, \$${CODEDB_COST}, ${CODEDB_TOKENS}, ${CODEDB_TURNS} turns, ${CODEDB_PATCH_LINES}L)\n"
    else
      printf " ${R}no patch${N} (${CODEDB_RUN_SEC}s, \$${CODEDB_COST}, ${CODEDB_TOKENS})\n"
    fi
  fi

  # ── Run B: graphify-assisted ──
  GRAPHIFY_PATCH="$RESULTS_DIR/${INSTANCE_ID}_graphify.patch"
  GRAPHIFY_LOG="$RESULTS_DIR/${INSTANCE_ID}_graphify.log"

  if [ -s "$GRAPHIFY_PATCH" ]; then
    printf "  ${D}graphify run already exists, skipping${N}\n"
  else
    printf "  ${C}building graphify graph...${N}"
    (cd "$REPO_DIR" && git checkout -f "$BASE_COMMIT" 2>/dev/null && git clean -fd 2>/dev/null) || true
    GRAPHIFY_BUILD_START=$(python3 -c 'import time; print(time.time())')
    (cd "$REPO_DIR" && "$GRAPHIFY_CLI" update . 2>/dev/null) || true
    GRAPHIFY_BUILD_END=$(python3 -c 'import time; print(time.time())')
    GRAPHIFY_BUILD_MS=$(python3 -c "print(f'{($GRAPHIFY_BUILD_END - $GRAPHIFY_BUILD_START) * 1000:.0f}')")
    GRAPH_JSON="$REPO_DIR/graphify-out/graph.json"
    if [ -f "$GRAPH_JSON" ]; then
      printf " ${G}done${N} (${GRAPHIFY_BUILD_MS}ms)\n"
    else
      printf " ${R}failed${N}\n"
    fi

    printf "  ${C}running Sonnet + graphify...${N}"

    GRAPHIFY_MCP_CONFIG="$WORK_DIR/mcp_graphify_$IDX.json"
    python3 -c "
import json
config = {
    'mcpServers': {
        'graphify': {
            'command': '$GRAPHIFY_PYTHON',
            'args': ['-m', 'graphify.serve', '$GRAPH_JSON']
        }
    }
}
with open('$GRAPHIFY_MCP_CONFIG', 'w') as f:
    json.dump(config, f)
"

    GRAPHIFY_PROMPT="You are solving a GitHub issue in a Python repository.

REPOSITORY: $REPO (checked out at commit ${BASE_COMMIT:0:12})
WORKING DIRECTORY: $REPO_DIR

ISSUE:
$PROBLEM

INSTRUCTIONS:
1. Use the graphify tools (query_graph, get_node, get_neighbors, shortest_path, get_community) to understand the codebase architecture and find relevant code.
2. Find the relevant code that needs to be changed to fix this issue.
3. Make the minimal fix to resolve the issue. Edit only what is necessary.
4. Do NOT run tests. Do NOT create new test files.
5. Do NOT commit your changes. Just edit the files directly.
6. When done, say DONE and briefly explain what you changed and why."

    RUN_START=$(python3 -c 'import time; print(time.time())')
    $CLAUDE -p "$GRAPHIFY_PROMPT" \
      --model "$MODEL" \
      --mcp-config "$GRAPHIFY_MCP_CONFIG" \
      --max-budget-usd "$MAX_BUDGET" \
      --dangerously-skip-permissions \
      --disallowedTools "mcp__codedb__*" \
      --output-format json \
      > "$GRAPHIFY_LOG" 2>&1 || true
    RUN_END=$(python3 -c 'import time; print(time.time())')
    GRAPHIFY_RUN_SEC=$(python3 -c "print(f'{$RUN_END - $RUN_START:.1f}')")

    GRAPHIFY_COST=$(python3 -c "import json; d=json.load(open('$GRAPHIFY_LOG')); print(f'{d.get(\"total_cost_usd\",0):.4f}')" 2>/dev/null || echo "?")
    GRAPHIFY_TOKENS=$(python3 -c "
import json
d=json.load(open('$GRAPHIFY_LOG'))
u=d.get('usage',{})
inp=u.get('input_tokens',0)+u.get('cache_read_input_tokens',0)+u.get('cache_creation_input_tokens',0)
out=u.get('output_tokens',0)
print(f'{inp}in/{out}out')
" 2>/dev/null || echo "?")
    GRAPHIFY_TURNS=$(python3 -c "import json; d=json.load(open('$GRAPHIFY_LOG')); print(d.get('num_turns',0))" 2>/dev/null || echo "?")

    (cd "$REPO_DIR" && git diff) > "$GRAPHIFY_PATCH" 2>/dev/null || true
    GRAPHIFY_PATCH_LINES=$(wc -l < "$GRAPHIFY_PATCH" | tr -d ' ')

    if [ "$GRAPHIFY_PATCH_LINES" -gt 0 ]; then
      printf " ${G}done${N} (${GRAPHIFY_RUN_SEC}s, \$${GRAPHIFY_COST}, ${GRAPHIFY_TOKENS}, ${GRAPHIFY_TURNS} turns, ${GRAPHIFY_PATCH_LINES}L)\n"
    else
      printf " ${R}no patch${N} (${GRAPHIFY_RUN_SEC}s, \$${GRAPHIFY_COST}, ${GRAPHIFY_TOKENS})\n"
    fi
  fi
  # ── Run B: baseline (no code intelligence) ──
  BASELINE_PATCH="$RESULTS_DIR/${INSTANCE_ID}_baseline.patch"
  BASELINE_LOG="$RESULTS_DIR/${INSTANCE_ID}_baseline.log"

  if [ -s "$BASELINE_PATCH" ]; then
    printf "  ${D}baseline run already exists, skipping${N}\n"
  else
    printf "  ${C}running Sonnet baseline...${N}"

    (cd "$REPO_DIR" && git checkout -f "$BASE_COMMIT" 2>/dev/null && git clean -fd 2>/dev/null) || true

    BASELINE_PROMPT="You are solving a GitHub issue in a Python repository.

REPOSITORY: $REPO (checked out at commit ${BASE_COMMIT:0:12})
WORKING DIRECTORY: $REPO_DIR

ISSUE:
$PROBLEM

INSTRUCTIONS:
1. Use Bash with grep, find, head, tail, etc. to explore the codebase and find relevant code.
2. Find the relevant code that needs to be changed to fix this issue.
3. Make the minimal fix to resolve the issue. Edit only what is necessary.
4. Do NOT run tests. Do NOT create new test files.
5. Do NOT commit your changes. Just edit the files directly.
6. When done, say DONE and briefly explain what you changed and why."

    RUN_START=$(python3 -c 'import time; print(time.time())')
    $CLAUDE -p "$BASELINE_PROMPT" \
      --model "$MODEL" \
      --max-budget-usd "$MAX_BUDGET" \
      --dangerously-skip-permissions \
      --disallowedTools "mcp__codedb__*" \
      --output-format json \
      > "$BASELINE_LOG" 2>&1 || true
    RUN_END=$(python3 -c 'import time; print(time.time())')
    BASELINE_RUN_SEC=$(python3 -c "print(f'{$RUN_END - $RUN_START:.1f}')")

    BASELINE_COST=$(python3 -c "import json; d=json.load(open('$BASELINE_LOG')); print(f'{d.get(\"total_cost_usd\",0):.4f}')" 2>/dev/null || echo "?")
    BASELINE_TOKENS=$(python3 -c "
import json
d=json.load(open('$BASELINE_LOG'))
u=d.get('usage',{})
inp=u.get('input_tokens',0)+u.get('cache_read_input_tokens',0)+u.get('cache_creation_input_tokens',0)
out=u.get('output_tokens',0)
print(f'{inp}in/{out}out')
" 2>/dev/null || echo "?")
    BASELINE_TURNS=$(python3 -c "import json; d=json.load(open('$BASELINE_LOG')); print(d.get('num_turns',0))" 2>/dev/null || echo "?")

    (cd "$REPO_DIR" && git diff) > "$BASELINE_PATCH" 2>/dev/null || true
    BASELINE_PATCH_LINES=$(wc -l < "$BASELINE_PATCH" | tr -d ' ')

    if [ "$BASELINE_PATCH_LINES" -gt 0 ]; then
      printf " ${G}done${N} (${BASELINE_RUN_SEC}s, \$${BASELINE_COST}, ${BASELINE_TOKENS}, ${BASELINE_TURNS} turns, ${BASELINE_PATCH_LINES}L)\n"
    else
      printf " ${R}no patch${N} (${BASELINE_RUN_SEC}s, \$${BASELINE_COST}, ${BASELINE_TOKENS})\n"
    fi
  fi

  printf "\n"
done

# ── Summary ──
printf "\n${W}═══════════════════════════════════════════════════════════════════════════${N}\n"
printf "${W}  Results Summary${N}\n"
printf "${W}═══════════════════════════════════════════════════════════════════════════${N}\n\n"

printf "  %-35s  %-20s  %-20s\n" "Instance" "codedb" "baseline"
printf "  %-35s  %-20s  %-20s\n" "" "cost/tokens/patch" "cost/tokens/patch"
printf "  %-35s  ────────────────────  ────────────────────\n" ""

CODEDB_PRODUCED=0
BASELINE_PRODUCED=0
CODEDB_TOTAL_COST=0
BASELINE_TOTAL_COST=0

for IDX in $(seq 0 $((INSTANCE_COUNT - 1))); do
  INSTANCE_ID=$(python3 -c "import json; print(json.load(open('$INSTANCES'))[$IDX]['instance_id'])")

  CODEDB_LINES=$(wc -l < "$RESULTS_DIR/${INSTANCE_ID}_codedb.patch" 2>/dev/null | tr -d ' ' || echo 0)
  BASELINE_LINES=$(wc -l < "$RESULTS_DIR/${INSTANCE_ID}_baseline.patch" 2>/dev/null | tr -d ' ' || echo 0)

  CODEDB_INFO=$(python3 -c "
import json
try:
    d=json.load(open('$RESULTS_DIR/${INSTANCE_ID}_codedb.log'))
    cost=d.get('total_cost_usd',0)
    u=d.get('usage',{})
    inp=u.get('input_tokens',0)+u.get('cache_read_input_tokens',0)+u.get('cache_creation_input_tokens',0)
    out=u.get('output_tokens',0)
    turns=d.get('num_turns',0)
    print(f'\${cost:.3f} {inp+out}tk {turns}t')
except: print('n/a')
" 2>/dev/null)

  BASELINE_INFO=$(python3 -c "
import json
try:
    d=json.load(open('$RESULTS_DIR/${INSTANCE_ID}_baseline.log'))
    cost=d.get('total_cost_usd',0)
    u=d.get('usage',{})
    inp=u.get('input_tokens',0)+u.get('cache_read_input_tokens',0)+u.get('cache_creation_input_tokens',0)
    out=u.get('output_tokens',0)
    turns=d.get('num_turns',0)
    print(f'\${cost:.3f} {inp+out}tk {turns}t')
except: print('n/a')
" 2>/dev/null)

  if [ "$CODEDB_LINES" -gt 0 ]; then CODEDB_PRODUCED=$((CODEDB_PRODUCED + 1)); fi
  if [ "$BASELINE_LINES" -gt 0 ]; then BASELINE_PRODUCED=$((BASELINE_PRODUCED + 1)); fi

  printf "  %-35s  %-20s  %-20s\n" "$INSTANCE_ID" "${CODEDB_INFO} ${CODEDB_LINES}L" "${BASELINE_INFO} ${BASELINE_LINES}L"
done

# Totals
CODEDB_TOTAL=$(python3 -c "
import json, glob
total=0
for f in glob.glob('$RESULTS_DIR/*_codedb.log'):
    try: total+=json.load(open(f)).get('total_cost_usd',0)
    except: pass
print(f'\${total:.2f}')
" 2>/dev/null)

BASELINE_TOTAL=$(python3 -c "
import json, glob
total=0
for f in glob.glob('$RESULTS_DIR/*_baseline.log'):
    try: total+=json.load(open(f)).get('total_cost_usd',0)
    except: pass
print(f'\${total:.2f}')
" 2>/dev/null)

printf "\n  Patches: codedb %d/%d  baseline %d/%d\n" \
  "$CODEDB_PRODUCED" "$INSTANCE_COUNT" "$BASELINE_PRODUCED" "$INSTANCE_COUNT"
printf "  Total cost: codedb %s  baseline %s\n\n" "$CODEDB_TOTAL" "$BASELINE_TOTAL"

printf "${Y}  Next: run evaluate.sh to check which patches pass the test suites${N}\n\n"
