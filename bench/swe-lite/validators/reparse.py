"""Re-parse validator outputs to extract JSON even when warnings precede/follow it."""
import json, os, re, sys

results_dir = "/Users/dev/codedb/bench/swe-lite/validators/results"

# For each .json file marked validator_crashed, try to extract embedded JSON from raw_output
fixed = 0
for fn in os.listdir(results_dir):
    if not fn.endswith('.json'): continue
    path = os.path.join(results_dir, fn)
    try:
        d = json.load(open(path))
    except Exception:
        continue
    if d.get('status') != 'validator_crashed':
        continue
    raw = d.get('raw_output', '')
    # Find first { that starts a balanced JSON object containing "checks"
    # Strategy: find all { and try parsing from each
    candidates = []
    for m in re.finditer(r'\{', raw):
        start = m.start()
        # Brace tracking
        depth = 0
        in_str = False
        esc = False
        for i in range(start, len(raw)):
            c = raw[i]
            if esc:
                esc = False
                continue
            if c == '\\':
                esc = True
                continue
            if c == '"' and not esc:
                in_str = not in_str
                continue
            if in_str:
                continue
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    candidate = raw[start:i+1]
                    try:
                        parsed = json.loads(candidate)
                        if isinstance(parsed, dict) and ('checks' in parsed or 'task' in parsed):
                            candidates.append((len(candidate), parsed))
                    except Exception:
                        pass
                    break
    if candidates:
        # Pick the largest valid JSON (most checks)
        candidates.sort(key=lambda x: -x[0])
        parsed = candidates[0][1]
        parsed['variant'] = d.get('variant', '')
        parsed['exit_code'] = d.get('exit_code', 0)
        parsed['status'] = 'validated'
        with open(path, 'w') as f:
            json.dump(parsed, f, indent=2)
        fixed += 1
        print(f"FIXED {fn}: {len(parsed.get('checks',{}))} checks recovered")

print(f"\nTotal: {fixed} files re-parsed")
