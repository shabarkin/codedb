#!/usr/bin/env python3
"""Judge a single agent answer against the task's ground truth.

Usage:
    python3 judge.py <task_id> <backend_id> <rep>
    python3 judge.py --all      # score every answer that doesn't have a score yet

Reads:
    tasks.json
    answers/<task>/<backend>-rep<N>.json
Produces:
    scores/scores.json  (appended, idempotent by (task,backend,rep) key)
"""
import argparse, json, os, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

def load_tasks():
    return {t["id"]: t for t in json.loads((HERE / "tasks.json").read_text())}

def load_scores():
    p = HERE / "scores" / "scores.json"
    if not p.exists(): return []
    return json.loads(p.read_text())

def save_scores(scores):
    (HERE / "scores" / "scores.json").write_text(json.dumps(scores, indent=2))

def find_answer_files():
    """Yield (task, backend, rep, path) for every answers/*/*.json file."""
    for tdir in sorted((HERE / "answers").iterdir()):
        if not tdir.is_dir(): continue
        for f in sorted(tdir.glob("*-rep*.json")):
            # filename: <backend>-rep<N>.json
            stem = f.stem
            backend, _, repstr = stem.rpartition("-rep")
            try: rep = int(repstr)
            except: continue
            yield tdir.name, backend, rep, f

def build_judge_prompt(task, answer):
    """Build a single prompt asking Claude Sonnet to score one answer."""
    prompt = f"""You are scoring one agent answer from a code-search benchmark.

# Task
{task["title"]}: {task["prompt"]}

# Ground truth
```json
{json.dumps(task["ground_truth"], indent=2)}
```

# Agent's submitted answer
```json
{json.dumps(answer, indent=2)}
```

# Rubric (out of 5)
+1 file_correct          (file path resolves to the right file)
+1 function_correct      (function/symbol name matches)
+1 snippet_faithful      (quoted code/snippet matches source — not hand-waved/paraphrased)
+1 explanation_accurate  (description/trace is what the code actually does, no hallucinations)
+1 completeness          (addresses ALL parts of the asked-for answer shape)

You may use `Read` or `grep` against /Users/dev/codedb-bench/react to verify references — but bound your verification effort. Don't burn 10 tool calls on one answer.

# Output
End your response with EXACTLY this JSON on the last line, nothing after:
{{"file": <0 or 1>, "function": <0 or 1>, "snippet": <0 or 1>, "explanation": <0 or 1>, "completeness": <0 or 1>, "total": <sum>, "notes": "<one short sentence on what cost or earned points>"}}
"""
    return prompt

def score_via_claude(prompt, model="sonnet"):
    """Call `claude --print` non-interactively with the judge prompt."""
    r = subprocess.run(
        ["claude", "--print", "--model", model, prompt],
        capture_output=True, text=True, timeout=300,
    )
    if r.returncode != 0:
        print(f"claude --print failed (exit {r.returncode})", file=sys.stderr)
        print(r.stderr[:500], file=sys.stderr)
        return None
    # Find the last {...} JSON in the response
    text = r.stdout.strip()
    last_open = text.rfind("{")
    if last_open < 0: return None
    try:
        return json.loads(text[last_open:])
    except json.JSONDecodeError:
        # Try one earlier opener
        return None

def score_one(task_id, backend, rep, model="sonnet"):
    tasks = load_tasks()
    task = tasks.get(task_id)
    if not task:
        print(f"unknown task {task_id}", file=sys.stderr); return None
    ans_file = HERE / "answers" / task_id / f"{backend}-rep{rep}.json"
    if not ans_file.exists():
        print(f"answer file missing: {ans_file}", file=sys.stderr); return None
    answer = json.loads(ans_file.read_text())
    prompt = build_judge_prompt(task, answer)
    scored = score_via_claude(prompt, model=model)
    if scored is None: return None
    scored.update({"task": task_id, "backend": backend, "rep": rep})
    return scored

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("task", nargs="?")
    ap.add_argument("backend", nargs="?")
    ap.add_argument("rep", nargs="?", type=int)
    ap.add_argument("--all", action="store_true", help="score every answer that doesn't have a score yet")
    ap.add_argument("--force", action="store_true", help="re-score even if a score exists")
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--print-prompt-only", action="store_true",
                    help="don't call claude; print the judge prompt for manual scoring")
    args = ap.parse_args()

    scores = load_scores()
    have = {(s["task"], s["backend"], s["rep"]) for s in scores}

    if args.all:
        to_score = [(t, b, r, f) for t, b, r, f in find_answer_files()
                    if args.force or (t, b, r) not in have]
    elif args.task:
        if not args.backend or args.rep is None:
            print("must pass task + backend + rep, or --all", file=sys.stderr); sys.exit(2)
        if (args.task, args.backend, args.rep) in have and not args.force and not args.print_prompt_only:
            print(f"already scored: {args.task}/{args.backend}-rep{args.rep} (use --force)", file=sys.stderr); sys.exit(0)
        to_score = [(args.task, args.backend, args.rep, None)]
    else:
        ap.print_help(); sys.exit(2)

    for task_id, backend, rep, _ in to_score:
        if args.print_prompt_only:
            task = load_tasks()[task_id]
            answer = json.loads((HERE / "answers" / task_id / f"{backend}-rep{rep}.json").read_text())
            print(f"# === prompt for {task_id} / {backend} / rep{rep} ===")
            print(build_judge_prompt(task, answer))
            print()
            continue
        print(f"scoring {task_id} / {backend} / rep{rep}...", flush=True)
        s = score_one(task_id, backend, rep, model=args.model)
        if s is None:
            print(f"  failed; skipping")
            continue
        # remove any old score for this cell and append
        scores = [x for x in scores if (x["task"], x["backend"], x["rep"]) != (task_id, backend, rep)]
        scores.append(s)
        save_scores(scores)
        print(f"  total={s.get('total')} — {s.get('notes', '')[:80]}")

if __name__ == "__main__":
    main()
