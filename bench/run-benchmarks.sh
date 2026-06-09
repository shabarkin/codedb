#!/usr/bin/env bash
set -euo pipefail

CODEDB="./zig-out/bin/codedb"
REPOS=(
  "/Users/dev/codedb|codedb|20 files, 12.6k lines"
  "/Users/dev/merjs|merjs|100 files, 17.3k lines"
  "/Users/dev/turboAPI|turboAPI|160 files, 41.2k lines"
)

W='\033[1;37m' G='\033[0;32m' C='\033[0;36m' D='\033[0;90m' Y='\033[0;33m' N='\033[0m'

# Send a JSON-RPC request to an MCP server via its stdin/stdout
# Usage: mcp_call <pid> <in_pipe> <out_pipe> <method> <params_json>
MCP_ID=1
mcp_request() {
  local in_pipe="$1" out_pipe="$2" method="$3" params="$4"
  MCP_ID=$((MCP_ID + 1))
  local body="{\"jsonrpc\":\"2.0\",\"id\":$MCP_ID,\"method\":\"$method\",\"params\":$params}"
  local len=${#body}
  printf "Content-Length: %d\r\n\r\n%s" "$len" "$body" > "$in_pipe"
  # Read response — Content-Length header then body
  local resp_hdr resp_len resp_body
  read -r resp_hdr < "$out_pipe"
  read -r _ < "$out_pipe"  # empty line
  resp_len=$(echo "$resp_hdr" | tr -dc '0-9')
  resp_body=$(dd bs=1 count="$resp_len" < "$out_pipe" 2>/dev/null)
  echo "$resp_body"
}

# Time N iterations of an MCP tool call, return avg ms
time_mcp() {
  local in_pipe="$1" out_pipe="$2" tool="$3" args="$4" iters="${5:-10}"
  local start end
  start=$(python3 -c 'import time; print(time.time())')
  for ((i=0; i<iters; i++)); do
    mcp_request "$in_pipe" "$out_pipe" "tools/call" "{\"name\":\"$tool\",\"arguments\":$args}" >/dev/null
  done
  end=$(python3 -c 'import time; print(time.time())')
  python3 -c "print(f'{($end - $start) / $iters * 1000:.2f}')"
}

time_cmd() {
  local start end
  start=$(python3 -c 'import time; print(time.time())')
  "$@" >/dev/null 2>&1 || true
  end=$(python3 -c 'import time; print(time.time())')
  python3 -c "print(f'{($end - $start) * 1000:.1f}')"
}

printf "\n${W}═══════════════════════════════════════════════════════════════${N}\n"
printf "${W}  codedb (MCP) vs ast-grep vs ripgrep — benchmark suite${N}\n"
printf "${W}═══════════════════════════════════════════════════════════════${N}\n"
printf "${D}  Machine: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)${N}\n"
printf "${D}  RAM:     $(( $(sysctl -n hw.memsize) / 1073741824 ))GB${N}\n"
printf "${D}  Date:    $(date '+%Y-%m-%d %H:%M')${N}\n"
printf "${D}  Mode:    MCP server (pre-indexed, warm queries, 10 iterations avg)${N}\n\n"

for entry in "${REPOS[@]}"; do
  IFS='|' read -r repo name desc <<< "$entry"

  printf "${W}━━━ $name ($desc) ━━━${N}\n\n"

  # Start MCP server
  IN_PIPE="/tmp/codedb_bench_in.$$"
  OUT_PIPE="/tmp/codedb_bench_out.$$"
  mkfifo "$IN_PIPE" "$OUT_PIPE"

  "$CODEDB" mcp "$repo" < "$IN_PIPE" > "$OUT_PIPE" 2>/dev/null &
  MCP_PID=$!
  exec 3>"$IN_PIPE"
  exec 4<"$OUT_PIPE"

  # Wait for server to be ready — send initialize
  sleep 0.3
  INIT_BODY='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bench","version":"1.0"}}}'
  INIT_LEN=${#INIT_BODY}
  printf "Content-Length: %d\r\n\r\n%s" "$INIT_LEN" "$INIT_BODY" >&3

  # Read init response
  read -r _ <&4; read -r _ <&4
  RESP_HDR=""
  read -r RESP_HDR <&4
  RESP_LEN=$(echo "$RESP_HDR" | tr -dc '0-9')
  dd bs=1 count="$RESP_LEN" <&4 2>/dev/null >/dev/null

  # Send initialized notification
  NOTIF='{"jsonrpc":"2.0","method":"notifications/initialized"}'
  NOTIF_LEN=${#NOTIF}
  printf "Content-Length: %d\r\n\r\n%s" "$NOTIF_LEN" "$NOTIF" >&3
  sleep 0.5

  FIRST_FILE=$(zigrep -F "*.zig" "$repo/src" 2>/dev/null | head -1)
  REL_FILE="${FIRST_FILE#$repo/}"

  # ── 1. Tree ──
  printf "${C}  1. File Tree${N}\n"
  MS=$(time_mcp /proc/self/fd/3 /proc/self/fd/4 "codedb_tree" '{}')
  printf "     ${G}codedb${N}    ${W}%s ms${N}  (MCP, pre-indexed)\n" "$MS"
  AST_MS=$(time_cmd ast-grep scan --rule '{ id: bench, language: zig, rule: { kind: source_file } }' "$repo/src")
  printf "     ${Y}ast-grep${N}  ${W}%s ms${N}  (cold, re-parses every call)\n" "$AST_MS"
  echo ""

  # ── 2. Symbol Search ──
  printf "${C}  2. Symbol Search (find 'init')${N}\n"
  MS=$(time_mcp /proc/self/fd/3 /proc/self/fd/4 "codedb_symbol" '{"name":"init"}')
  printf "     ${G}codedb${N}    ${W}%s ms${N}  (MCP, hash lookup)\n" "$MS"
  AST_MS=$(time_cmd ast-grep scan --pattern 'fn init($$$)' "$repo/src")
  printf "     ${Y}ast-grep${N}  ${W}%s ms${N}  (tree-sitter parse + match)\n" "$AST_MS"
  RG_MS=$(time_cmd rg -n 'fn init' "$repo/src")
  printf "     ${D}ripgrep${N}   ${W}%s ms${N}  (regex)\n" "$RG_MS"
  echo ""

  # ── 3. Full-Text Search ──
  printf "${C}  3. Full-Text Search ('allocator')${N}\n"
  MS=$(time_mcp /proc/self/fd/3 /proc/self/fd/4 "codedb_search" '{"query":"allocator"}')
  printf "     ${G}codedb${N}    ${W}%s ms${N}  (MCP, trigram index)\n" "$MS"
  RG_MS=$(time_cmd rg -c 'allocator' "$repo/src")
  printf "     ${D}ripgrep${N}   ${W}%s ms${N}  (brute force)\n" "$RG_MS"
  AST_MS=$(time_cmd ast-grep scan --pattern 'allocator' "$repo/src")
  printf "     ${Y}ast-grep${N}  ${W}%s ms${N}  (tree-sitter parse + match)\n" "$AST_MS"
  echo ""

  # ── 4. Word Index ──
  printf "${C}  4. Word Index Lookup ('self')${N}\n"
  MS=$(time_mcp /proc/self/fd/3 /proc/self/fd/4 "codedb_word" '{"word":"self"}')
  printf "     ${G}codedb${N}    ${W}%s ms${N}  (MCP, O(1) inverted index)\n" "$MS"
  RG_MS=$(time_cmd rg -wc 'self' "$repo/src")
  printf "     ${D}ripgrep${N}   ${W}%s ms${N}  (regex word boundary)\n" "$RG_MS"
  printf "     ${Y}ast-grep${N}  ${D}n/a (no word index)${N}\n"
  echo ""

  # ── 5. Outline ──
  printf "${C}  5. Structural Outline${N}\n"
  if [ -n "$FIRST_FILE" ]; then
    MS=$(time_mcp /proc/self/fd/3 /proc/self/fd/4 "codedb_outline" "{\"path\":\"$REL_FILE\"}")
    printf "     ${G}codedb${N}    ${W}%s ms${N}  (MCP, cached parse)\n" "$MS"
    AST_MS=$(time_cmd ast-grep scan --rule "{ id: bench, language: zig, rule: { kind: function_declaration } }" "$FIRST_FILE")
    printf "     ${Y}ast-grep${N}  ${W}%s ms${N}  (tree-sitter cold parse)\n" "$AST_MS"
    CTAGS_MS=$(time_cmd ctags -f /dev/null --languages=all "$FIRST_FILE")
    printf "     ${D}ctags${N}     ${W}%s ms${N}  (regex)\n" "$CTAGS_MS"
  fi
  echo ""

  # ── 6. Deps ──
  printf "${C}  6. Dependency Graph${N}\n"
  if [ -n "$FIRST_FILE" ]; then
    MS=$(time_mcp /proc/self/fd/3 /proc/self/fd/4 "codedb_deps" "{\"path\":\"$REL_FILE\"}")
    printf "     ${G}codedb${N}    ${W}%s ms${N}  (MCP, pre-computed reverse graph)\n" "$MS"
    printf "     ${Y}ast-grep${N}  ${D}n/a (no dependency tracking)${N}\n"
    printf "     ${D}ripgrep${N}   ${D}n/a (no dependency tracking)${N}\n"
  fi
  echo ""

  # ── 7. Status ──
  printf "${C}  7. Status (file count + seq)${N}\n"
  MS=$(time_mcp /proc/self/fd/3 /proc/self/fd/4 "codedb_status" '{}')
  printf "     ${G}codedb${N}    ${W}%s ms${N}  (MCP)\n" "$MS"
  printf "     ${Y}ast-grep${N}  ${D}n/a${N}\n"
  echo ""

  # Cleanup MCP server
  exec 3>&-
  exec 4<&-
  kill $MCP_PID 2>/dev/null || true
  wait $MCP_PID 2>/dev/null || true
  rm -f "$IN_PIPE" "$OUT_PIPE"
done

printf "${W}═══════════════════════════════════════════════════════════════${N}\n"
printf "${W}  Feature Matrix${N}\n"
printf "${W}═══════════════════════════════════════════════════════════════${N}\n"
printf "\n"
printf "  %-28s  ${G}codedb${N}  ${Y}ast-grep${N}  ${D}ripgrep${N}  ${D}ctags${N}\n" ""
printf "  %-28s  ──────  ────────  ───────  ─────\n" ""
printf "  %-28s  ${G}  ✓   ${N}  ${Y}  ✓   ${N}  ${D}  ✗   ${N}  ${D}  ✓ ${N}\n" "Structural parsing"
printf "  %-28s  ${G}  ✓   ${N}  ${Y}  ✗   ${N}  ${D}  ✗   ${N}  ${D}  ✗ ${N}\n" "Trigram search index"
printf "  %-28s  ${G}  ✓   ${N}  ${Y}  ✗   ${N}  ${D}  ✗   ${N}  ${D}  ✗ ${N}\n" "Inverted word index"
printf "  %-28s  ${G}  ✓   ${N}  ${Y}  ✗   ${N}  ${D}  ✗   ${N}  ${D}  ✗ ${N}\n" "Dependency graph"
printf "  %-28s  ${G}  ✓   ${N}  ${Y}  ✗   ${N}  ${D}  ✗   ${N}  ${D}  ✗ ${N}\n" "Version tracking"
printf "  %-28s  ${G}  ✓   ${N}  ${Y}  ✗   ${N}  ${D}  ✗   ${N}  ${D}  ✗ ${N}\n" "Multi-agent file locking"
printf "  %-28s  ${G}  ✓   ${N}  ${Y}  ✗   ${N}  ${D}  ✗   ${N}  ${D}  ✗ ${N}\n" "MCP server (AI agents)"
printf "  %-28s  ${G}  ✓   ${N}  ${Y}  ✗   ${N}  ${D}  ✗   ${N}  ${D}  ✗ ${N}\n" "HTTP API + SSE events"
printf "  %-28s  ${G}  ✓   ${N}  ${Y}  ✗   ${N}  ${D}  ✗   ${N}  ${D}  ✗ ${N}\n" "File watcher"
printf "  %-28s  ${G}  ✓   ${N}  ${Y}  ✗   ${N}  ${D}  ✗   ${N}  ${D}  ✗ ${N}\n" "Portable snapshot"
printf "  %-28s  ${G}  ✓   ${N}  ${Y}  ✓   ${N}  ${D}  ✓   ${N}  ${D}  ✗ ${N}\n" "Full-text search"
printf "  %-28s  ${G}  ✓   ${N}  ${Y}  ✓   ${N}  ${D}  ✗   ${N}  ${D}  ✗ ${N}\n" "Atomic file edits"
printf "  %-28s  ${G} Zig  ${N}  ${Y}Rust  ${N}  ${D} Rust ${N}  ${D}  C  ${N}\n" "Implementation"
printf "  %-28s  ${G}  0   ${N}  ${Y} tree ${N}  ${D}  0   ${N}  ${D}  0  ${N}\n" "External deps"
printf "     ${D}                        -sitter${N}\n"
printf "\n"
