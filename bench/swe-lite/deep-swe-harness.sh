#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCES="$SCRIPT_DIR/deep_swe_2.json"
RESULTS_DIR="$SCRIPT_DIR/results-deepswe"
WORK_DIR="/tmp/deep-swe-bench"
CODEDB="/Users/dev/bin/codedb"
GRAPHIFY_PYTHON="/tmp/graphify-env/bin/python"
GRAPHIFY_CLI="/tmp/graphify-env/bin/graphify"
CLAUDE="claude"
MODEL="sonnet"
MAX_BUDGET="5.00"

mkdir -p "$RESULTS_DIR" "$WORK_DIR"

W='\033[1;37m' G='\033[0;32m' R='\033[0;31m' C='\033[0;36m' Y='\033[0;33m' D='\033[0;90m' N='\033[0m'

printf "\n${W}══════════════════════════════════════════════════════════════${N}\n"
printf "${W}  DeepSWE — codedb vs graphify vs baseline (Sonnet 4.6)${N}\n"
printf "${W}══════════════════════════════════════════════════════════════${N}\n"
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
with open('$WORK_DIR/instruction_$IDX.md', 'w') as pf:
    pf.write(inst['instruction'])
")"

  REPO_DIR="$WORK_DIR/repos/$INSTANCE_ID"
  INSTRUCTION=$(< "$WORK_DIR/instruction_$IDX.md")

  printf "${W}━━━ [%d/%d] %s ━━━${N}\n" $((IDX + 1)) "$INSTANCE_COUNT" "$INSTANCE_ID"

  # Clone
  if [ -d "$REPO_DIR/.git" ]; then
    printf "  ${D}repo already cloned${N}\n"
  else
    printf "  ${C}cloning %s...${N}" "$REPO"
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone --quiet "https://github.com/$REPO.git" "$REPO_DIR" 2>/dev/null
    printf " ${G}done${N}\n"
  fi

  for VARIANT in codedb graphify baseline; do
    PATCH="$RESULTS_DIR/${INSTANCE_ID}_${VARIANT}.patch"
    LOG="$RESULTS_DIR/${INSTANCE_ID}_${VARIANT}.log"

    if [ -s "$PATCH" ]; then
      printf "  ${D}%s already exists, skipping${N}\n" "$VARIANT"
      continue
    fi

    # Reset repo
    (cd "$REPO_DIR" && git checkout -f "$BASE_COMMIT" 2>/dev/null && git clean -fd 2>/dev/null) || true

    # Variant-specific setup
    EXTRA_FLAGS=""
    MCP_FLAG=""
    TOOL_HINT=""

    if [ "$VARIANT" = "codedb" ]; then
      printf "  ${C}indexing with codedb...${N}"
      "$CODEDB" "$REPO_DIR" index 2>/dev/null || true
      printf " ${G}done${N}\n"

      MCP_CONFIG="$WORK_DIR/mcp_codedb_$IDX.json"
      python3 -c "
import json
config = {'mcpServers': {'codedb': {'command': '$CODEDB', 'args': ['mcp', '$REPO_DIR']}}}
with open('$MCP_CONFIG', 'w') as f: json.dump(config, f)
"
      MCP_FLAG="--mcp-config $MCP_CONFIG"
      TOOL_HINT="Use codedb tools (codedb_search, codedb_symbol, codedb_outline, codedb_deps, codedb_callers, codedb_read) to understand the codebase."

    elif [ "$VARIANT" = "graphify" ]; then
      printf "  ${C}building graphify graph...${N}"
      (cd "$REPO_DIR" && "$GRAPHIFY_CLI" update . 2>/dev/null) || true
      GRAPH_JSON="$REPO_DIR/graphify-out/graph.json"
      if [ -f "$GRAPH_JSON" ]; then
        printf " ${G}done${N}\n"
      else
        printf " ${R}failed${N}\n"
      fi

      MCP_CONFIG="$WORK_DIR/mcp_graphify_$IDX.json"
      python3 -c "
import json
config = {'mcpServers': {'graphify': {'command': '$GRAPHIFY_PYTHON', 'args': ['-m', 'graphify.serve', '$GRAPH_JSON']}}}
with open('$MCP_CONFIG', 'w') as f: json.dump(config, f)
"
      MCP_FLAG="--mcp-config $MCP_CONFIG"
      EXTRA_FLAGS='--disallowedTools "mcp__codedb__*"'
      TOOL_HINT="Use graphify tools (query_graph, get_node, get_neighbors, shortest_path) to understand the codebase architecture."

    else
      EXTRA_FLAGS='--disallowedTools "mcp__codedb__*"'
      TOOL_HINT="Use Bash with grep, find, etc. to explore the codebase."
    fi

    PROMPT="You are implementing a feature in a codebase.

REPOSITORY: $REPO (checked out at commit ${BASE_COMMIT:0:12})
WORKING DIRECTORY: $REPO_DIR

TASK:
$INSTRUCTION

INSTRUCTIONS:
1. $TOOL_HINT
2. Understand the existing codebase patterns before writing code.
3. Implement the feature described above. Follow existing code style.
4. Do NOT run tests. Do NOT commit your changes. Just edit the files directly.
5. When done, say DONE and briefly explain what you implemented."

    printf "  ${C}running Sonnet + %s...${N}" "$VARIANT"

    RUN_START=$(python3 -c 'import time; print(time.time())')
    eval $CLAUDE -p '"$PROMPT"' \
      --model "$MODEL" \
      $MCP_FLAG \
      --max-budget-usd "$MAX_BUDGET" \
      --dangerously-skip-permissions \
      $EXTRA_FLAGS \
      --output-format json \
      > "$LOG" 2>&1 || true
    RUN_END=$(python3 -c 'import time; print(time.time())')
    RUN_SEC=$(python3 -c "print(f'{$RUN_END - $RUN_START:.1f}')")

    COST=$(python3 -c "import json; d=json.load(open('$LOG')); print(f'{d.get(\"total_cost_usd\",0):.3f}')" 2>/dev/null || echo "?")
    TURNS=$(python3 -c "import json; d=json.load(open('$LOG')); print(d.get('num_turns',0))" 2>/dev/null || echo "?")
    TOKENS=$(python3 -c "
import json; d=json.load(open('$LOG')); u=d.get('usage',{})
t=u.get('input_tokens',0)+u.get('cache_read_input_tokens',0)+u.get('cache_creation_input_tokens',0)+u.get('output_tokens',0)
print(f'{t:,}')
" 2>/dev/null || echo "?")

    (cd "$REPO_DIR" && git diff) > "$PATCH" 2>/dev/null || true
    PATCH_LINES=$(wc -l < "$PATCH" | tr -d ' ')

    if [ "$PATCH_LINES" -gt 0 ]; then
      printf " ${G}done${N} (${RUN_SEC}s, \$${COST}, ${TOKENS}tk, ${TURNS}t, ${PATCH_LINES}L)\n"
    else
      printf " ${R}no patch${N} (${RUN_SEC}s, \$${COST})\n"
    fi
  done

  printf "\n"
done

# Summary
printf "\n${W}══════════════════════════════════════════════════════════════${N}\n"
printf "${W}  Results${N}\n"
printf "${W}══════════════════════════════════════════════════════════════${N}\n\n"

for IDX in $(seq 0 $((INSTANCE_COUNT - 1))); do
  INSTANCE_ID=$(python3 -c "import json; print(json.load(open('$INSTANCES'))[$IDX]['instance_id'])")
  printf "  ${W}%s${N}\n" "$INSTANCE_ID"
  for VARIANT in codedb graphify baseline; do
    LOG="$RESULTS_DIR/${INSTANCE_ID}_${VARIANT}.log"
    PATCH="$RESULTS_DIR/${INSTANCE_ID}_${VARIANT}.patch"
    INFO=$(python3 -c "
import json, os
try:
    d=json.load(open('$LOG'))
    cost=d.get('total_cost_usd',0)
    u=d.get('usage',{})
    t=u.get('input_tokens',0)+u.get('cache_read_input_tokens',0)+u.get('cache_creation_input_tokens',0)+u.get('output_tokens',0)
    turns=d.get('num_turns',0)
    pl=sum(1 for _ in open('$PATCH')) if os.path.getsize('$PATCH') > 0 else 0
    print(f'\${cost:.3f}  {t:>8,}tk  {turns:>2}t  {pl:>4}L')
except: print('n/a')
" 2>/dev/null)
    printf "    %-10s %s\n" "$VARIANT" "$INFO"
  done
done
printf "\n"
