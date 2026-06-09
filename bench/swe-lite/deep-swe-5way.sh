#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTANCES="$SCRIPT_DIR/deep_swe_7.json"
RESULTS_DIR="$SCRIPT_DIR/results-deepswe-5way"
TRACES_DIR="$RESULTS_DIR/traces"
WORK_DIR="/tmp/deep-swe-bench-5way"
CODEDB="/Users/dev/bin/codedb"
GRAPHIFY_PYTHON="/tmp/graphify-env/bin/python"
GRAPHIFY_CLI="/tmp/graphify-env/bin/graphify"
CODEGRAPH="codegraph"
LEANCTX="lean-ctx"
CLAUDE="claude"
MODEL="sonnet"
MAX_BUDGET="5.00"

mkdir -p "$RESULTS_DIR" "$TRACES_DIR" "$WORK_DIR"

W='\033[1;37m' G='\033[0;32m' R='\033[0;31m' C='\033[0;36m' Y='\033[0;33m' D='\033[0;90m' N='\033[0m'

printf "\n${W}══════════════════════════════════════════════════════════════${N}\n"
printf "${W}  DeepSWE 5-Way — codedb vs graphify vs codegraph vs lean-ctx vs baseline${N}\n"
printf "${W}══════════════════════════════════════════════════════════════${N}\n"
printf "${D}  Budget/run: \$%s | Model: Sonnet 4.6${N}\n" "$MAX_BUDGET"
printf "${D}  Date:       $(date '+%Y-%m-%d %H:%M')${N}\n"
printf "${D}  Traces:     %s${N}\n\n" "$TRACES_DIR"

INSTANCE_COUNT=$(python3 -c "import json; print(len(json.load(open('$INSTANCES'))))")
VARIANTS="codedb graphify codegraph leanctx baseline"

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

  printf "${W}━━━ [%d/%d] %s (%s) ━━━${N}\n" $((IDX + 1)) "$INSTANCE_COUNT" "$INSTANCE_ID" "$REPO"

  # Clone
  if [ -d "$REPO_DIR/.git" ]; then
    printf "  ${D}repo already cloned${N}\n"
  else
    printf "  ${C}cloning %s...${N}" "$REPO"
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone --quiet "https://github.com/$REPO.git" "$REPO_DIR" 2>/dev/null
    printf " ${G}done${N}\n"
  fi

  for VARIANT in $VARIANTS; do
    PATCH="$RESULTS_DIR/${INSTANCE_ID}_${VARIANT}.patch"
    LOG="$RESULTS_DIR/${INSTANCE_ID}_${VARIANT}.log"
    TRACE="$TRACES_DIR/${INSTANCE_ID}_${VARIANT}_trace.json"

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

    elif [ "$VARIANT" = "codegraph" ]; then
      printf "  ${C}indexing with codegraph...${N}"
      (cd "$REPO_DIR" && "$CODEGRAPH" index . 2>/dev/null) || true
      printf " ${G}done${N}\n"

      MCP_CONFIG="$WORK_DIR/mcp_codegraph_$IDX.json"
      python3 -c "
import json
config = {'mcpServers': {'codegraph': {'command': '$CODEGRAPH', 'args': ['serve', '--mcp', '--path', '$REPO_DIR']}}}
with open('$MCP_CONFIG', 'w') as f: json.dump(config, f)
"
      MCP_FLAG="--mcp-config $MCP_CONFIG"
      EXTRA_FLAGS='--disallowedTools "mcp__codedb__*"'
      TOOL_HINT="Use codegraph tools (codegraph_search, codegraph_context, codegraph_callers, codegraph_callees, codegraph_impact, codegraph_node, codegraph_explore) to understand the codebase."

    elif [ "$VARIANT" = "leanctx" ]; then
      printf "  ${C}setting up lean-ctx...${N}"
      (cd "$REPO_DIR" && "$LEANCTX" index build 2>/dev/null) || true
      printf " ${G}done${N}\n"

      MCP_CONFIG="$WORK_DIR/mcp_leanctx_$IDX.json"
      python3 -c "
import json
config = {'mcpServers': {'leanctx': {'command': '$LEANCTX', 'args': [], 'env': {'LEAN_CTX_PROJECT': '$REPO_DIR'}}}}
with open('$MCP_CONFIG', 'w') as f: json.dump(config, f)
"
      MCP_FLAG="--mcp-config $MCP_CONFIG"
      EXTRA_FLAGS='--disallowedTools "mcp__codedb__*"'
      TOOL_HINT="Use lean-ctx tools (ctx_read with modes like map/signatures/full, ctx_expand for search, ctx_refactor) to understand the codebase efficiently."

    else
      # baseline
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

    # Save trace JSON with full metadata
    python3 -c "
import json, os
try:
    log = json.load(open('$LOG'))
except:
    log = {}
trace = {
    'instance_id': '$INSTANCE_ID',
    'variant': '$VARIANT',
    'repo': '$REPO',
    'base_commit': '$BASE_COMMIT',
    'model': '$MODEL',
    'max_budget': float('$MAX_BUDGET'),
    'cost_usd': log.get('total_cost_usd', 0),
    'num_turns': log.get('num_turns', 0),
    'duration_ms': log.get('duration_ms', 0),
    'duration_api_ms': log.get('duration_api_ms', 0),
    'ttft_ms': log.get('ttft_ms', 0),
    'wall_seconds': float('$RUN_SEC'),
    'patch_lines': int('$PATCH_LINES'),
    'stop_reason': log.get('stop_reason', ''),
    'terminal_reason': log.get('terminal_reason', ''),
    'session_id': log.get('session_id', ''),
    'usage': log.get('usage', {}),
    'model_usage': log.get('modelUsage', {}),
    'permission_denials': log.get('permission_denials', []),
}
with open('$TRACE', 'w') as f:
    json.dump(trace, f, indent=2)
" 2>/dev/null || true

    if [ "$PATCH_LINES" -gt 0 ]; then
      printf " ${G}done${N} (${RUN_SEC}s, \$${COST}, ${TOKENS}tk, ${TURNS}t, ${PATCH_LINES}L)\n"
    else
      printf " ${R}no patch${N} (${RUN_SEC}s, \$${COST})\n"
    fi
  done

  printf "\n"
done

# Summary table
printf "\n${W}══════════════════════════════════════════════════════════════${N}\n"
printf "${W}  Results Summary${N}\n"
printf "${W}══════════════════════════════════════════════════════════════${N}\n\n"

RESULTS_DIR_ESC="$RESULTS_DIR" python3 << 'PYEOF'
import json, os, glob

results_dir = os.environ["RESULTS_DIR_ESC"]

variants = ["codedb", "graphify", "codegraph", "leanctx", "baseline"]
data = {}

for f in sorted(glob.glob(os.path.join(results_dir, "*.log"))):
    name = os.path.basename(f).replace(".log", "")
    if name == "run":
        continue
    parts = name.rsplit("_", 1)
    if len(parts) != 2:
        continue
    instance, variant = parts
    try:
        log = json.load(open(f))
    except:
        continue
    patch_f = f.replace(".log", ".patch")
    patch_lines = sum(1 for _ in open(patch_f)) if os.path.exists(patch_f) and os.path.getsize(patch_f) > 0 else 0
    if instance not in data:
        data[instance] = {}
    data[instance][variant] = {
        "cost": log.get("total_cost_usd", 0),
        "turns": log.get("num_turns", 0),
        "lines": patch_lines,
        "wall_s": log.get("duration_ms", 0) / 1000,
    }

header = f"{'Instance':<42}"
for v in variants:
    header += f" {v:>14}"
print(header)
print("-" * (42 + 15 * len(variants)))

totals = {v: {"cost": 0, "turns": 0, "lines": 0} for v in variants}
for inst in sorted(data.keys()):
    row = f"{inst:<42}"
    costs = {}
    for v in variants:
        d = data[inst].get(v)
        if d:
            row += f" ${d['cost']:.2f} {d['turns']}T"
            totals[v]["cost"] += d["cost"]
            totals[v]["turns"] += d["turns"]
            totals[v]["lines"] += d["lines"]
            costs[v] = d["cost"]
        else:
            row += f" {'—':>14}"
    if costs:
        cheapest = min(costs, key=costs.get)
        row += f"  <- {cheapest}"
    print(row)

print("-" * (42 + 15 * len(variants)))
row = f"{'TOTAL':<42}"
for v in variants:
    t = totals[v]
    row += f" ${t['cost']:.2f} {t['turns']}T"
print(row)
print()
PYEOF

printf "\n${D}Traces saved to: %s${N}\n" "$TRACES_DIR"
printf "${D}Full logs in: %s${N}\n\n" "$RESULTS_DIR"
