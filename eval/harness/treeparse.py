#!/usr/bin/env python3
"""Parse codedb_tree output into a flat file list.

Format (renderTree, src/explore.zig:2897-2906): 2-space indent per depth,
directory rows end with '/', file rows are
    '<basename>  <lang>  <N>L  <M> sym'
codedb_tree has no result cap, so this is the authoritative way to
enumerate the full indexed file set (codedb_glob caps at 5000).
"""
import re

_FILE_ROW = re.compile(r"^(.*?)  (\S+)  (\d+)L  (\d+) sym")


def tree_files(text):
    """codedb_tree text -> sorted list of (relpath, lang, line_count, sym_count)."""
    stack = []  # dir names by depth
    out = []
    for row in text.splitlines():
        if not row.strip():
            continue
        indent = len(row) - len(row.lstrip(" "))
        if indent % 2:
            continue  # defensive: unexpected odd indent
        depth = indent // 2
        body = row.strip()
        if body.endswith("/") and "  " not in body:
            stack = stack[:depth]
            stack.append(body[:-1])
            continue
        m = _FILE_ROW.match(body)
        if not m:
            continue
        name, lang, lines, syms = m.groups()
        rel = "/".join(stack[:depth] + [name])
        out.append((rel, lang, int(lines), int(syms)))
    return sorted(out)


def tree_paths(text):
    """codedb_tree text -> sorted list of indexed relpaths."""
    return [t[0] for t in tree_files(text)]
