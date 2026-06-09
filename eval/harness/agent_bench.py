#!/usr/bin/env python3
"""Deterministic no-LLM benchmark for Phase 7 agent navigation.

The harness runs fixed ~/codex tasks against local zig-out/bin/codedb and
compares:
  - compass_summary: one compass call, summary mode, default 5 files
  - compass_minimal: one compass call, minimal mode, default 5 files
  - context: one codedb context call, where a task has extractable identifiers
  - manual_chain: a fixed multi-command codedb chain, where feasible

Command failures are recorded in the per-task JSON instead of aborting the run.
"""

import argparse
import datetime as _dt
import json
import os
import re
import subprocess
import sys
import time
from typing import Any


HERE = os.path.dirname(os.path.abspath(__file__))
EVAL_DIR = os.path.normpath(os.path.join(HERE, ".."))
REPO_ROOT = os.path.normpath(os.path.join(EVAL_DIR, ".."))
DEFAULT_BINARY = os.path.join(REPO_ROOT, "zig-out", "bin", "codedb")
DEFAULT_OUT = os.path.join(EVAL_DIR, "results", "compass-agent-bench.json")
DEFAULT_CODEX_ROOT = os.path.expanduser("~/codex")

PATH_RE = re.compile(
    r"(?<![A-Za-z0-9_./-])"
    r"((?:[A-Za-z0-9_.@%+-]+/)+[A-Za-z0-9_.@%+-]+)"
    r"(?::[0-9]+)?"
)
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


TASKS: list[dict[str, Any]] = [
    {
        "id": "define_turn_context",
        "label": "Define TurnContext",
        "task": "definition of TurnContext",
        "intent": "define",
        "gold_files": ["codex-rs/core/src/session/turn_context.rs"],
        "gold_symbols": ["TurnContext"],
        "manual_chain": [
            ["symbol", "TurnContext"],
            [
                "read",
                "codex-rs/core/src/session/turn_context.rs",
                "-L",
                "55-130",
                "--compact",
            ],
        ],
    },
    {
        "id": "define_rollout_recorder",
        "label": "Define RolloutRecorder",
        "task": "definition of RolloutRecorder",
        "intent": "define",
        "gold_files": ["codex-rs/rollout/src/recorder.rs"],
        "gold_symbols": ["RolloutRecorder"],
        "manual_chain": [
            ["symbol", "RolloutRecorder"],
            [
                "read",
                "codex-rs/rollout/src/recorder.rs",
                "-L",
                "75-230",
                "--compact",
            ],
        ],
    },
    {
        "id": "callers_process_exec_tool_call",
        "label": "Callers of process_exec_tool_call",
        "task": "what calls process_exec_tool_call",
        "intent": "callers",
        "gold_files": [
            "codex-rs/core/src/exec.rs",
            "codex-rs/core/tests/suite/exec.rs",
            "codex-rs/core/tests/suite/windows_sandbox.rs",
            "codex-rs/linux-sandbox/tests/suite/landlock.rs",
        ],
        "gold_symbols": ["process_exec_tool_call"],
        "manual_chain": [
            ["symbol", "process_exec_tool_call"],
            ["callers", "process_exec_tool_call"],
        ],
    },
    {
        "id": "overview_shell_exec_approval",
        "label": "Shell command approval flow",
        "task": "trace ShellCommandToolCallParams ExecCommandApproval shell approval flow",
        "intent": "overview",
        "gold_files": [
            "codex-rs/protocol/src/models.rs",
            "codex-rs/core/src/tools/handlers/shell.rs",
            "codex-rs/core/src/tools/handlers/shell/shell_command.rs",
            "codex-rs/core/src/exec_policy.rs",
            "codex-rs/tui/src/chatwidget/protocol_requests.rs",
        ],
        "gold_symbols": ["ShellCommandToolCallParams", "ExecCommandApproval"],
        "manual_chain": [
            ["symbol", "ShellCommandToolCallParams"],
            ["search", "--paths-only", "--max-results", "10", "ExecCommandApproval"],
            ["search", "--paths-only", "--max-results", "10", "ShellCommandToolCallParams"],
            [
                "read",
                "codex-rs/core/src/tools/handlers/shell/shell_command.rs",
                "-L",
                "144-202",
                "--compact",
            ],
        ],
    },
    {
        "id": "overview_mcp_tool_call",
        "label": "MCP tool call flow",
        "task": "trace handle_mcp_tool_call tools/call approval flow",
        "intent": "overview",
        "gold_files": [
            "codex-rs/core/src/mcp_tool_call.rs",
            "codex-rs/core/src/tools/handlers/mcp.rs",
            "codex-rs/app-server-protocol/src/protocol/thread_history.rs",
            "codex-rs/core/src/session/mcp.rs",
        ],
        "gold_symbols": ["handle_mcp_tool_call", "McpToolCall"],
        "manual_chain": [
            ["symbol", "handle_mcp_tool_call"],
            ["callers", "handle_mcp_tool_call"],
            ["search", "--paths-only", "--max-results", "10", "McpToolCall"],
        ],
    },
    {
        "id": "define_config",
        "label": "Define Config",
        "task": "definition of Config",
        "intent": "define",
        "gold_files": ["codex-rs/core/src/config/mod.rs"],
        "gold_symbols": ["Config"],
        "manual_chain": [["symbol", "Config"]],
    },
    {
        "id": "define_config_builder",
        "label": "Define ConfigBuilder",
        "task": "definition of ConfigBuilder",
        "intent": "define",
        "gold_files": ["codex-rs/core/src/config/mod.rs"],
        "gold_symbols": ["ConfigBuilder"],
        "manual_chain": [["symbol", "ConfigBuilder"]],
    },
    {
        "id": "define_codex",
        "label": "Define Codex session type",
        "task": "definition of Codex",
        "intent": "define",
        "gold_files": ["codex-rs/core/src/session/mod.rs"],
        "gold_symbols": ["Codex"],
        "manual_chain": [["symbol", "Codex"]],
    },
    {
        "id": "callers_codex_submit",
        "label": "Callers of Codex submit",
        "task": "what calls submit",
        "intent": "callers",
        "gold_files": [
            "codex-rs/core/src/session/mod.rs",
            "codex-rs/core/src/codex_thread.rs",
        ],
        "gold_symbols": ["submit"],
        "manual_chain": [["callers", "submit"]],
    },
    {
        "id": "define_sandbox_policy",
        "label": "Define SandboxPolicy",
        "task": "definition of SandboxPolicy",
        "intent": "define",
        "gold_files": ["codex-rs/protocol/src/protocol.rs"],
        "gold_symbols": ["SandboxPolicy"],
        "manual_chain": [["symbol", "SandboxPolicy"]],
    },
    {
        "id": "define_exec_params",
        "label": "Define ExecParams",
        "task": "definition of ExecParams",
        "intent": "define",
        "gold_files": ["codex-rs/core/src/exec.rs"],
        "gold_symbols": ["ExecParams"],
        "manual_chain": [["symbol", "ExecParams"]],
    },
    {
        "id": "overview_exec_policy",
        "label": "Exec policy manager flow",
        "task": "how does ExecPolicyManager ExecApprovalRequest work",
        "intent": "overview",
        "gold_files": [
            "codex-rs/core/src/exec_policy.rs",
            "codex-rs/protocol/src/approvals.rs",
        ],
        "gold_symbols": ["ExecPolicyManager", "ExecApprovalRequest"],
        "manual_chain": [
            ["symbol", "ExecPolicyManager"],
            ["symbol", "ExecApprovalRequest"],
            ["search", "--paths-only", "--max-results", "10", "ExecPolicyManager"],
        ],
    },
    {
        "id": "overview_approval_overlay",
        "label": "TUI approval overlay",
        "task": "how does ApprovalOverlay handle_key_event approval UI work",
        "intent": "overview",
        "gold_files": [
            "codex-rs/tui/src/bottom_pane/approval_overlay.rs",
            "codex-rs/tui/src/approval_events.rs",
        ],
        "gold_symbols": ["ApprovalOverlay", "handle_key_event"],
        "manual_chain": [
            ["symbol", "ApprovalOverlay"],
            ["search", "--paths-only", "--max-results", "10", "handle_key_event"],
        ],
    },
    {
        "id": "overview_chat_composer",
        "label": "Chat composer key handling",
        "task": "trace ChatComposer handle_key_event file popup skill popup",
        "intent": "overview",
        "gold_files": ["codex-rs/tui/src/bottom_pane/chat_composer.rs"],
        "gold_symbols": ["handle_key_event", "handle_key_event_with_file_popup"],
        "manual_chain": [
            ["search", "--paths-only", "--max-results", "10", "handle_key_event_with_file_popup"],
            ["search", "--paths-only", "--max-results", "10", "handle_key_event_with_skill_popup"],
        ],
    },
    {
        "id": "define_app_event",
        "label": "Define AppEvent",
        "task": "definition of AppEvent",
        "intent": "define",
        "gold_files": ["codex-rs/tui/src/app_event.rs"],
        "gold_symbols": ["AppEvent"],
        "manual_chain": [["symbol", "AppEvent"]],
    },
    {
        "id": "define_view_image_handler",
        "label": "Define ViewImageHandler",
        "task": "definition of ViewImageHandler",
        "intent": "define",
        "gold_files": ["codex-rs/core/src/tools/handlers/view_image.rs"],
        "gold_symbols": ["ViewImageHandler"],
        "manual_chain": [["symbol", "ViewImageHandler"]],
    },
    {
        "id": "overview_unified_exec",
        "label": "Unified exec command handling",
        "task": "trace ExecCommandHandler ExecCommandArgs unified exec command flow",
        "intent": "overview",
        "gold_files": [
            "codex-rs/core/src/tools/handlers/unified_exec.rs",
            "codex-rs/core/src/tools/handlers/unified_exec/exec_command.rs",
            "codex-rs/core/src/unified_exec/mod.rs",
        ],
        "gold_symbols": ["ExecCommandHandler", "ExecCommandArgs"],
        "manual_chain": [
            ["symbol", "ExecCommandHandler"],
            ["symbol", "ExecCommandArgs"],
        ],
    },
    {
        "id": "overview_permissions",
        "label": "Filesystem sandbox permissions",
        "task": "how does FileSystemSandboxPolicy ReadDenyMatcher workspace_write work",
        "intent": "overview",
        "gold_files": ["codex-rs/protocol/src/permissions.rs"],
        "gold_symbols": ["FileSystemSandboxPolicy", "ReadDenyMatcher"],
        "manual_chain": [
            ["symbol", "FileSystemSandboxPolicy"],
            ["symbol", "ReadDenyMatcher"],
        ],
    },
    {
        "id": "overview_mcp_protocol",
        "label": "MCP protocol models",
        "task": "how do Tool ResourceTemplate CallToolResult MCP protocol types work",
        "intent": "overview",
        "gold_files": ["codex-rs/protocol/src/mcp.rs"],
        "gold_symbols": ["Tool", "ResourceTemplate", "CallToolResult"],
        "manual_chain": [
            ["symbol", "Tool"],
            ["symbol", "ResourceTemplate"],
            ["symbol", "CallToolResult"],
        ],
    },
    {
        "id": "blast_config",
        "label": "Blast radius of config module",
        "task": "blast radius of codex-rs/core/src/config/mod.rs",
        "intent": "blast_radius",
        "gold_files": ["codex-rs/core/src/config/mod.rs"],
        "gold_symbols": ["Config"],
        "manual_chain": [
            ["deps", "codex-rs/core/src/config/mod.rs", "--transitive", "--max-depth", "2"],
        ],
    },
]


def git_sha(root: str) -> str:
    try:
        proc = subprocess.run(
            ["git", "-C", root, "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except Exception:
        return "unknown"
    return proc.stdout.strip() if proc.returncode == 0 else "unknown"


def short_text(value: str, limit: int = 500) -> str:
    if len(value) <= limit:
        return value
    return value[:limit] + "...[truncated]"


def command_env() -> dict[str, str]:
    env = dict(os.environ)
    env["CODEDB_NO_CLI_PROXY"] = "1"
    env["CODEDB_NO_CLI_DAEMON"] = "1"
    return env


def run_codedb(
    binary: str, root: str, args: list[str], timeout: float
) -> dict[str, Any]:
    argv = [binary, root] + args
    started = time.perf_counter()
    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=command_env(),
        )
        latency_ms = int(round((time.perf_counter() - started) * 1000))
        error = None if proc.returncode == 0 else "exit %d" % proc.returncode
        return {
            "argv": argv,
            "exit_code": proc.returncode,
            "latency_ms": latency_ms,
            "stdout_bytes": len(proc.stdout.encode("utf-8")),
            "stderr_bytes": len(proc.stderr.encode("utf-8")),
            "stdout": proc.stdout,
            "stderr_excerpt": short_text(proc.stderr.strip()),
            "error": error,
        }
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", "replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", "replace")
        latency_ms = int(round((time.perf_counter() - started) * 1000))
        return {
            "argv": argv,
            "exit_code": None,
            "latency_ms": latency_ms,
            "stdout_bytes": len(stdout.encode("utf-8")),
            "stderr_bytes": len(stderr.encode("utf-8")),
            "stdout": stdout,
            "stderr_excerpt": short_text(stderr.strip()),
            "error": "timeout after %.1fs" % timeout,
        }
    except OSError as exc:
        latency_ms = int(round((time.perf_counter() - started) * 1000))
        return {
            "argv": argv,
            "exit_code": None,
            "latency_ms": latency_ms,
            "stdout_bytes": 0,
            "stderr_bytes": 0,
            "stdout": "",
            "stderr_excerpt": "",
            "error": "%s: %s" % (exc.__class__.__name__, exc),
        }


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def extract_paths(text: str) -> list[str]:
    seen: set[str] = set()
    paths: list[str] = []
    for match in PATH_RE.finditer(strip_ansi(text)):
        path = match.group(1).strip("`.,);]}")
        if "://" in path:
            continue
        if path.startswith(("/", "../")):
            continue
        if "/" not in path:
            continue
        if path not in seen:
            seen.add(path)
            paths.append(path)
    return paths


def symbol_present(text: str, symbol: str) -> bool:
    pattern = r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(symbol)
    return re.search(pattern, text) is not None


def has_more_marker(text: str) -> bool:
    if "## MORE reqid=" in text:
        return True
    return re.search(r'"more"\s*:\s*"[0-9a-f]{16}"', text) is not None


def evaluate_strategy(
    task: dict[str, Any], commands: list[dict[str, Any]], single_call: bool
) -> dict[str, Any]:
    stdout = "\n".join(command["stdout"] for command in commands)
    clean_stdout = strip_ansi(stdout)
    top_paths = extract_paths(clean_stdout)
    top5 = top_paths[:5]

    gold_files = task["gold_files"]
    gold_symbols = task["gold_symbols"]
    files_at_5 = [path for path in gold_files if path in top5]
    files_anywhere = [path for path in gold_files if path in clean_stdout]
    symbols_anywhere = [
        symbol for symbol in gold_symbols if symbol_present(clean_stdout, symbol)
    ]
    command_errors = [
        {
            "argv": command["argv"],
            "error": command["error"],
            "exit_code": command["exit_code"],
            "stderr_excerpt": command["stderr_excerpt"],
        }
        for command in commands
        if command["error"]
    ]
    recall_at_5 = (
        round(len(files_at_5) / len(gold_files), 4) if gold_files else 1.0
    )
    zero_follow_up = (
        single_call
        and not command_errors
        and len(files_anywhere) == len(gold_files)
        and len(symbols_anywhere) == len(gold_symbols)
        and not has_more_marker(clean_stdout)
    )

    return {
        "bytes": sum(command["stdout_bytes"] for command in commands),
        "latency_ms": sum(command["latency_ms"] for command in commands),
        "recall@5": recall_at_5,
        "zero_follow_up": zero_follow_up,
        "command_count": len(commands),
        "top_paths": top5,
        "gold_file_hits_at_5": files_at_5,
        "gold_file_hits_anywhere": files_anywhere,
        "gold_symbol_hits_anywhere": symbols_anywhere,
        "command_errors": command_errors,
        "commands": [
            {
                "argv": command["argv"],
                "exit_code": command["exit_code"],
                "latency_ms": command["latency_ms"],
                "stdout_bytes": command["stdout_bytes"],
                "stderr_bytes": command["stderr_bytes"],
                "stderr_excerpt": command["stderr_excerpt"],
                "error": command["error"],
            }
            for command in commands
        ],
    }


def strategy_commands(task: dict[str, Any]) -> dict[str, tuple[list[list[str]], bool]]:
    intent = task.get("intent")
    compass_prefix = ["compass", "--mode", "summary"]
    if intent:
        compass_prefix += ["--intent", intent]
    compass_minimal_prefix = ["compass", "--mode", "minimal"]
    if intent:
        compass_minimal_prefix += ["--intent", intent]
    return {
        "compass_summary": (
            compass_prefix + ["--max-files", "5", task["task"]],
            True,
        ),
        "compass_minimal": (
            compass_minimal_prefix + ["--max-files", "5", task["task"]],
            True,
        ),
        "context": (["context", task.get("context_task", task["task"])], True),
        "manual_chain": (task.get("manual_chain", []), False),
    }


def run_task(
    task: dict[str, Any], binary: str, root: str, timeout: float
) -> dict[str, Any]:
    strategies: dict[str, Any] = {}
    for strategy, (spec, single_call) in strategy_commands(task).items():
        if not spec:
            strategies[strategy] = {
                "bytes": 0,
                "latency_ms": 0,
                "recall@5": 0.0,
                "zero_follow_up": False,
                "command_count": 0,
                "top_paths": [],
                "gold_file_hits_at_5": [],
                "gold_file_hits_anywhere": [],
                "gold_symbol_hits_anywhere": [],
                "command_errors": [{"error": "strategy not feasible for task"}],
                "commands": [],
            }
            continue
        command_specs = [spec] if single_call else spec
        runs = [run_codedb(binary, root, args, timeout) for args in command_specs]
        strategies[strategy] = evaluate_strategy(task, runs, single_call)

    return {
        "id": task["id"],
        "label": task["label"],
        "task": task["task"],
        "intent": task.get("intent"),
        "gold": {
            "files": task["gold_files"],
            "symbols": task["gold_symbols"],
            "files_exist": {
                path: os.path.exists(os.path.join(root, path))
                for path in task["gold_files"]
            },
        },
        "strategies": strategies,
    }


def summarize(tasks: list[dict[str, Any]]) -> dict[str, Any]:
    by_strategy: dict[str, dict[str, Any]] = {}
    for task in tasks:
        for name, result in task["strategies"].items():
            row = by_strategy.setdefault(
                name,
                {
                    "tasks": 0,
                    "total_bytes": 0,
                    "total_latency_ms": 0,
                    "total_recall@5": 0.0,
                    "zero_follow_up": 0,
                    "command_errors": 0,
                },
            )
            row["tasks"] += 1
            row["total_bytes"] += result["bytes"]
            row["total_latency_ms"] += result["latency_ms"]
            row["total_recall@5"] += result["recall@5"]
            row["zero_follow_up"] += 1 if result["zero_follow_up"] else 0
            row["command_errors"] += len(result["command_errors"])

    for row in by_strategy.values():
        tasks_n = max(1, row["tasks"])
        row["avg_bytes"] = round(row["total_bytes"] / tasks_n, 1)
        row["avg_latency_ms"] = round(row["total_latency_ms"] / tasks_n, 1)
        row["avg_recall@5"] = round(row["total_recall@5"] / tasks_n, 4)
        row["zero_follow_up_rate"] = round(row["zero_follow_up"] / tasks_n, 4)
    return by_strategy


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=DEFAULT_BINARY)
    parser.add_argument("--root", default=DEFAULT_CODEX_ROOT)
    parser.add_argument("--out", default=DEFAULT_OUT)
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument(
        "--only",
        default="",
        help="comma-separated task ids to run; default runs all tasks",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    binary = os.path.abspath(args.binary)
    root = os.path.abspath(os.path.expanduser(args.root))
    only = {item.strip() for item in args.only.split(",") if item.strip()}
    tasks = [task for task in TASKS if not only or task["id"] in only]

    results = [run_task(task, binary, root, args.timeout) for task in tasks]
    payload = {
        "meta": {
            "generated_utc": _dt.datetime.utcnow().replace(microsecond=0).isoformat()
            + "Z",
            "harness": "phase7-agent-navigation",
            "root": root,
            "binary": binary,
            "binary_exists": os.path.exists(binary),
            "codedb_sha": git_sha(REPO_ROOT),
            "codex_sha": git_sha(root),
            "notes": [
                "No LLM calls; task/gold definitions are fixed in eval/harness/agent_bench.py.",
                "compass_minimal uses --mode minimal with the same max-files budget as summary.",
                "recall@5 is gold-file recall against the first five unique paths surfaced by a strategy.",
                "zero_follow_up is true only for successful single-command strategies that surface all gold files and symbols without a more handle.",
            ],
        },
        "summary": summarize(results),
        "tasks": results,
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    print("results written to %s" % args.out)
    for name, row in payload["summary"].items():
        print(
            "%-16s avg_bytes=%7.1f avg_ms=%7.1f avg_recall@5=%.4f zero_follow_up=%d/%d errors=%d"
            % (
                name,
                row["avg_bytes"],
                row["avg_latency_ms"],
                row["avg_recall@5"],
                row["zero_follow_up"],
                row["tasks"],
                row["command_errors"],
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
