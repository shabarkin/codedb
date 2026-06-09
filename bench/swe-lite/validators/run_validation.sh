#!/usr/bin/env bash
# Sandbox validation runner for big-repo patches.
set -uo pipefail

API_KEY="${SANDBOX_API_KEY:?set SANDBOX_API_KEY to your sandbox.trilok.ai API key}"
BASE=https://sandbox.trilok.ai
PATCH_DIR="/Users/dev/codedb/bench/swe-lite/results-deepswe-big/clean"
VAL_DIR="/Users/dev/codedb/bench/swe-lite/validators"
OUT_DIR="/Users/dev/codedb/bench/swe-lite/validators/results"
mkdir -p "$OUT_DIR"

# Function-based meta lookup (bash 3.x compatible)
task_meta() {
    case "$1" in
        langchain-request-coalescing) echo "langchain-ai/langchain 7cef35b langchain validate_langchain.py" ;;
        fastapi-implicit-head-options) echo "fastapi/fastapi 11614be9021aa4ac078d4d0693a8b5250a1010d8 fastapi validate_fastapi_head.py" ;;
        fastapi-deprecation-response-headers) echo "fastapi/fastapi 11614be9021aa4ac078d4d0693a8b5250a1010d8 fastapi validate_fastapi_deprec.py" ;;
        textual-richlog-follow-state) echo "Textualize/textual 0f0849fd37fbd0d4d6f81889476c22340129df67 textual validate_textual.py" ;;
        numba-stencil-boundary-modes) echo "numba/numba 5781334aa654972fdc749003e7c1e93e6d277110 numba validate_numba.py" ;;
    esac
}

ALL_TASKS="langchain-request-coalescing fastapi-implicit-head-options fastapi-deprecation-response-headers textual-richlog-follow-state numba-stencil-boundary-modes"
VARIANTS="codedb graphify codegraph leanctx baseline"

api_post() { curl -s -X POST "$BASE$1" -H "X-API-Key: $API_KEY" -H "Content-Type: ${3:-application/json}" -d "$2"; }
api_del()  { curl -s -X DELETE "$BASE$1" -H "X-API-Key: $API_KEY"; }

create_box() {
    local resp=$(api_post "/v1/boxes" '{"image":"python","cpu":2000,"memory":4096,"disk":12288,"ttl":3600,"tier":"process"}')
    echo "$resp" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null
}

run_in_box() {
    local box=$1 cmd=$2
    curl -s -X POST "$BASE/v1/boxes/$box/exec" -H "X-API-Key: $API_KEY" -H "Content-Type: text/plain" -d "$cmd" --max-time 600
}

upload_file() {
    local box=$1 path=$2 src=$3
    curl -s -X PUT "$BASE/v1/boxes/$box/files" -H "X-API-Key: $API_KEY" -H "X-File-Path: $path" --data-binary "@$src" > /dev/null
}

destroy_box() {
    api_del "/v1/boxes/$1" > /dev/null
}

validate_task() {
    local task=$1
    local meta=$(task_meta "$task")
    if [ -z "$meta" ]; then echo "Unknown task: $task"; return; fi
    set -- $meta
    local repo=$1 base_commit=$2 pip_pkg=$3 validator=$4
    
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  TASK: $task"
    echo "  REPO: $repo @ ${base_commit:0:8}"
    echo "════════════════════════════════════════════════════════"
    
    for variant in $VARIANTS; do
        local patch="$PATCH_DIR/${task}_${variant}.patch"
        local out_file="$OUT_DIR/${task}_${variant}.json"
        
        if [ ! -s "$patch" ]; then
            echo "[$variant] SKIP (no patch / empty)"
            echo "{\"task\":\"$task\",\"variant\":\"$variant\",\"status\":\"no_patch\"}" > "$out_file"
            continue
        fi
        
        if [ -f "$out_file" ]; then
            echo "[$variant] already validated, skipping"
            continue
        fi
        
        echo "[$variant] creating sandbox..."
        local box=$(create_box)
        if [ -z "$box" ]; then
            echo "[$variant] FAILED to create box"
            continue
        fi
        echo "[$variant] box: $box"
        
        run_in_box "$box" "mkdir -p /workspace" > /dev/null
        upload_file "$box" "/workspace/patch.diff" "$patch"
        upload_file "$box" "/workspace/validator.py" "$VAL_DIR/$validator"
        
        local setup_cmd="set -e
cd /workspace
git clone --quiet https://github.com/$repo.git repo 2>&1 | tail -5
cd repo
git checkout -q $base_commit 2>&1 | tail -3
git apply /workspace/patch.diff 2>&1 | head -20 || (echo 'PATCH_APPLY_FAILED'; exit 1)
echo 'PATCH_APPLIED_OK'"
        
        echo "[$variant] cloning + applying patch..."
        local setup_resp=$(run_in_box "$box" "$setup_cmd")
        local setup_out=$(echo "$setup_resp" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('output',''))" 2>/dev/null)
        
        if ! echo "$setup_out" | grep -q "PATCH_APPLIED_OK"; then
            echo "[$variant] PATCH FAILED TO APPLY"
            python3 -c "
import json
print(json.dumps({'task':'$task','variant':'$variant','status':'patch_failed','output':'''$setup_out'''[:500]}, indent=2))
" > "$out_file"
            destroy_box "$box"
            continue
        fi
        echo "[$variant] patch applied OK"
        
        local install_cmd=""
        case "$task" in
            langchain-request-coalescing)
                install_cmd="cd /workspace/repo/libs/core && pip install -q --break-system-packages -e . 2>&1 | tail -5"
                ;;
            fastapi-implicit-head-options|fastapi-deprecation-response-headers)
                install_cmd="cd /workspace/repo && pip install -q --break-system-packages -e . httpx 2>&1 | tail -5"
                ;;
            textual-richlog-follow-state)
                install_cmd="cd /workspace/repo && pip install -q --break-system-packages -e . 2>&1 | tail -5"
                ;;
            numba-stencil-boundary-modes)
                install_cmd="pip install -q --break-system-packages numpy 'llvmlite==0.46.0' 2>&1 | tail -3 && cd /workspace/repo && pip install -q --break-system-packages -e . 2>&1 | tail -5"
                ;;
        esac
        
        echo "[$variant] installing..."
        run_in_box "$box" "$install_cmd" > /dev/null
        
        echo "[$variant] running validator..."
        local val_resp=$(run_in_box "$box" "cd /workspace && python3 validator.py")
        
        # Save full response (we'll parse later)
        echo "$val_resp" > "$out_file.raw"
        
        python3 << PYEOF > "$out_file"
import json, sys
try:
    raw = open('$out_file.raw').read()
    d = json.loads(raw)
    out = d.get('output', '')
    exit_code = d.get('exit_code', -1)
    try:
        parsed = json.loads(out)
        parsed['variant'] = '$variant'
        parsed['exit_code'] = exit_code
        parsed['status'] = 'validated'
        print(json.dumps(parsed, indent=2))
    except Exception:
        print(json.dumps({
            'task': '$task',
            'variant': '$variant',
            'status': 'validator_crashed',
            'exit_code': exit_code,
            'raw_output': out[:2000],
        }, indent=2))
except Exception as e:
    print(json.dumps({'task':'$task','variant':'$variant','status':'parse_error','err':str(e)}, indent=2))
PYEOF
        
        rm -f "$out_file.raw"
        echo "[$variant] result saved"
        destroy_box "$box"
    done
}

if [ $# -gt 0 ]; then
    for task in "$@"; do
        validate_task "$task"
    done
else
    for task in $ALL_TASKS; do
        validate_task "$task"
    done
fi

echo ""
echo "Validation complete. Results in: $OUT_DIR"
