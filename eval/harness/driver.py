#!/usr/bin/env python3
"""JSON-RPC/MCP stdio client for codedb trust probes.

Spawns `codedb <root> mcp` (CODEDB_MCP_LEAN=1), performs the MCP
initialize handshake, and gates every probe on codedb_status reporting
`scan: ready` plus a settle delay so index staleness never confounds
correctness results.
"""
import json
import os
import select
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BINARY = os.path.normpath(
    os.path.join(HERE, "..", "..", "zig-out", "bin", "codedb")
)


class CodedbError(RuntimeError):
    pass


class CodedbClient:
    """One codedb MCP server process bound to one project root."""

    def __init__(self, root, binary=None, lean=True):
        self.root = os.path.abspath(root)
        self.binary = binary or DEFAULT_BINARY
        env = dict(os.environ)
        if lean:
            env["CODEDB_MCP_LEAN"] = "1"
        self.proc = subprocess.Popen(
            [self.binary, self.root, "mcp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        self._next_id = 0
        self._initialize()

    # -- wire protocol (newline-delimited JSON-RPC) -------------------------

    def _send(self, msg):
        data = (json.dumps(msg) + "\n").encode("utf-8")
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def _recv(self, want_id, timeout):
        deadline = time.monotonic() + timeout
        buf = b""
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CodedbError(
                    "timeout waiting for response id=%s" % want_id
                )
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not ready:
                continue
            chunk = self.proc.stdout.read1(65536)
            if not chunk:
                raise CodedbError("codedb process closed stdout")
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                msg = json.loads(line.decode("utf-8"))
                if msg.get("id") == want_id:
                    return msg
                # ignore notifications / unrelated ids

    def _request(self, method, params, timeout):
        self._next_id += 1
        rid = self._next_id
        self._send(
            {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}
        )
        return self._recv(rid, timeout)

    def _initialize(self):
        resp = self._request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "codedb-probe", "version": "1.0"},
            },
            timeout=30,
        )
        if "result" not in resp:
            raise CodedbError("initialize failed: %r" % resp)
        self.server_version = resp["result"].get("serverInfo", {}).get(
            "version", "unknown"
        )
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    # -- public API ----------------------------------------------------------

    def call(self, tool, args=None, timeout=120):
        """Call an MCP tool; return the assistant-audience text."""
        resp = self._request(
            "tools/call",
            {"name": tool, "arguments": args or {}},
            timeout=timeout,
        )
        if "error" in resp:
            raise CodedbError("rpc error: %r" % resp["error"])
        result = resp["result"]
        texts = []
        for item in result.get("content", []):
            audience = item.get("annotations", {}).get("audience", [])
            if "assistant" in audience or not audience:
                texts.append(item.get("text", ""))
        return {
            "text": "\n".join(texts),
            "is_error": bool(result.get("isError")),
            "raw": result,
        }

    def status(self):
        return self.call("codedb_status")["text"]

    def wait_ready(self, timeout=600, settle=3.0):
        """Block until codedb_status reports `scan: ready`, then settle."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            text = self.status()
            if "scan: ready" in text:
                time.sleep(settle)
                return self.status()
            time.sleep(2.0)
        raise CodedbError("index never reached scan: ready in %ss" % timeout)

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


# -- response-text parsers (normalization layer) -----------------------------


def parse_search(text):
    """Parse codedb_search assistant text into [(path, line, content)].

    Format: header `N results for 'q':` then `  path:line: content` rows.
    """
    hits = []
    for row in text.splitlines():
        if not row.startswith("  "):
            continue
        body = row[2:]
        first_colon = _path_line_split(body)
        if first_colon is None:
            continue
        path, line_no, content = first_colon
        hits.append((path, line_no, content))
    return hits


def _path_line_split(body):
    """Split `path:line: content` — path may itself contain colons, so scan
    for the first `:<digits>:` boundary."""
    i = 0
    while True:
        i = body.find(":", i)
        if i == -1:
            return None
        j = i + 1
        while j < len(body) and body[j].isdigit():
            j += 1
        if j > i + 1 and j < len(body) and body[j] == ":":
            return body[:i], int(body[i + 1 : j]), body[j + 1 :].lstrip()
        if j > i + 1 and j == len(body):
            return body[:i], int(body[i + 1 : j]), ""
        i += 1


def parse_paths(text):
    """Parse plain path-per-line output (codedb_glob)."""
    if text.strip() == "no matches":  # codedb_glob empty-result sentinel
        return []
    out = []
    for row in text.splitlines():
        row = row.rstrip()
        if not row or row.startswith(("(", "#")):
            continue
        out.append(row.strip())
    return out


def search_total(text):
    """Extract the declared result count from the search header, if any."""
    head = text.splitlines()[0] if text.splitlines() else ""
    parts = head.split(" ", 1)
    if parts and parts[0].isdigit():
        return int(parts[0])
    return None


if __name__ == "__main__":
    # one-shot CLI: driver.py <root> <tool> [json-args]
    if len(sys.argv) < 3:
        print("usage: driver.py <root> <tool> [json-args]", file=sys.stderr)
        sys.exit(2)
    root_arg, tool_arg = sys.argv[1], sys.argv[2]
    tool_args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
    with CodedbClient(root_arg) as client:
        client.wait_ready()
        out = client.call(tool_arg, tool_args)
        print(out["text"])
