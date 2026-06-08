#!/usr/bin/env python3
"""Mechanical replica of codedb's DOCUMENTED visibility policy.

Source of truth (codedb @ 803db6b):
  - skip_dirs:            src/watcher.zig:110-160 (matched case-insensitively
                          per directory name, shouldSkipDir watcher.zig:180-186)
  - skip_extensions:      src/watcher.zig:1187-1195 (case-insensitive suffix)
  - sensitive paths:      src/path_security.zig:25-83
  - path safety:          src/path_security.zig isPathSafe (no abs, no '..',
                          no NUL, no backslash)
  - size cap:             > 512*1024 bytes skipped (watcher.zig:516, 1224)
  - binary sniff:         NUL byte within first 512 bytes (watcher.zig:1231-1234)
  - .DS_Store suffix:     watcher.zig:1203
  - gitignore:            negation, nested, dir-only, **, anchored supported;
                          char classes / escapes NOT supported (we use git
                          itself as the gitignore oracle and flag the gap)

Used by probes to compute the EXPECTED-indexed file set so that divergences
split cleanly into "documented design choice" vs "silent bug".
"""
import os
import subprocess

SIZE_CAP = 512 * 1024
BINARY_SNIFF_WINDOW = 512

SKIP_DIRS = {
    ".git", ".claude", ".codedb", "node_modules", ".zig-cache", "zig-out",
    ".next", ".nuxt", ".svelte-kit", "dist", "build", ".build", ".output",
    "out", "__pycache__", ".venv", "venv", ".env", ".tox", ".mypy_cache",
    ".pytest_cache", ".ruff_cache", "target", ".gradle", ".idea", ".vs",
    "vendor", "pods", ".dart_tool", ".pub-cache", "coverage", ".nyc_output",
    ".turbo", ".parcel-cache", ".cache", ".tmp", ".temp", ".ds_store",
    "bundle", ".bundle", ".swc", ".terraform", ".terragrunt-cache",
    ".serverless", "elm-stuff", ".stack-work", ".cabal-sandbox", ".cargo",
    "bower_components",
}  # stored lowercase; compare with name.lower()

SKIP_EXTENSIONS = (
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".icns", ".webp",
    ".svg", ".ttf", ".otf", ".woff", ".woff2", ".eot", ".zip", ".tar",
    ".gz", ".bz2", ".xz", ".7z", ".rar", ".pdf", ".doc", ".docx",
    ".xls", ".xlsx", ".pptx", ".mp3", ".mp4", ".wav", ".avi", ".mov",
    ".flv", ".ogg", ".webm", ".exe", ".dll", ".so", ".dylib", ".o",
    ".a", ".lib", ".wasm", ".pyc", ".pyo", ".class", ".db", ".sqlite",
    ".sqlite3", ".lock", ".sum",
)

SENSITIVE_COMPONENTS = {".ssh", ".gnupg", ".aws"}

SENSITIVE_NAMES = {
    ".dev.vars", ".envrc", ".npmrc", ".pypirc", ".netrc", ".pgpass",
    ".htpasswd", "application.properties", "application.yml",
    "application.yaml", "credentials.json", "service-account.json",
    "secrets.json", "secrets.yaml", "secrets.yml", "id_rsa", "id_ed25519",
}

SENSITIVE_EXTENSIONS = (
    ".pem", ".key", ".p12", ".pfx", ".jks", ".crt", ".cer", ".der", ".crl",
)


def _is_env_name(component):
    # path_security.zig envName: ".env" prefix followed by nothing or . - _
    c = component.lower()
    if not c.startswith(".env"):
        return False
    return len(c) == 4 or c[4] in "._-"


def is_sensitive(relpath):
    parts = [p for p in relpath.split("/") if p]
    for comp in parts:
        if comp.lower() in SENSITIVE_COMPONENTS:
            return True
        if _is_env_name(comp):
            return True
    base = parts[-1] if parts else ""
    bl = base.lower()
    if bl.endswith(".env"):
        return True
    if bl in SENSITIVE_NAMES:
        return True
    if bl.endswith(SENSITIVE_EXTENSIONS):
        return True
    return False


def skip_reason(root, relpath):
    """Why codedb's documented policy would exclude relpath (or None).

    Checks dir pruning, extension, sensitivity, size, and binary sniff.
    Does NOT apply gitignore — combine with git_ignored() for that.
    """
    parts = relpath.split("/")
    for d in parts[:-1]:
        if d.lower() in SKIP_DIRS:
            return "skip_dir:%s" % d
        if d.lower() in SENSITIVE_COMPONENTS or _is_env_name(d):
            return "sensitive_dir:%s" % d
    base = parts[-1]
    if "\\" in relpath or "\x00" in relpath:
        return "unsafe_path"
    bl = base.lower()
    if bl.endswith(SKIP_EXTENSIONS):
        return "skip_extension"
    if bl.endswith(".ds_store"):
        return "ds_store"
    if is_sensitive(relpath):
        return "sensitive_file"
    full = os.path.join(root, relpath)
    try:
        st = os.lstat(full)
    except OSError:
        return "unstattable"
    if os.path.islink(full):
        # in-root file symlinks indexed; out-of-root/broken dropped
        try:
            real = os.path.realpath(full)
            real_root = os.path.realpath(root)
            if not os.path.exists(real):
                return "broken_symlink"
            if not (real == real_root or real.startswith(real_root + "/")):
                return "symlink_outside_root"
            st = os.stat(full)
        except OSError:
            return "broken_symlink"
    if st.st_size > SIZE_CAP:
        return "over_512kb"
    try:
        with open(full, "rb") as fh:
            head = fh.read(BINARY_SNIFF_WINDOW)
        if b"\x00" in head:
            return "binary_null_sniff"
    except OSError:
        return "unreadable"
    return None


def git_ignored(root, relpaths, no_index=False):
    """Subset of relpaths matching gitignore rules.

    no_index=False: git's EFFECTIVE semantics (tracked files never ignored).
    no_index=True:  pure pattern matching — what codedb's engine (and rg)
                    implement, with no index awareness.
    """
    if not relpaths:
        return set()
    cmd = ["git", "-C", root, "check-ignore"]
    if no_index:
        cmd.append("--no-index")
    cmd += ["--stdin", "-z"]
    proc = subprocess.run(
        cmd,
        input="\0".join(relpaths).encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    out = proc.stdout.decode("utf-8", "surrogateescape")
    return {p for p in out.split("\0") if p}


def walk_files(root):
    """All regular files under root (relative paths, '/'-separated), pruning
    nothing — the raw filesystem inventory. Does not follow dir symlinks."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            rel_dir = ""
        for name in filenames:
            rel = os.path.join(rel_dir, name) if rel_dir else name
            found.append(rel.replace(os.sep, "/"))
    return sorted(found)


def expected_indexed(root):
    """The file set codedb's DOCUMENTED policy should index, plus a map of
    excluded path -> reason.

    Gitignore is applied PATTERN-ONLY (check-ignore --no-index): codedb's
    engine — like ripgrep's — has no index awareness, so tracked files whose
    paths match an ignore pattern are excluded. Those get the distinct
    reason 'gitignored_but_tracked' so probes can surface the divergence
    from git's effective semantics (git never ignores tracked files).
    """
    inventory = walk_files(root)
    inventory = [p for p in inventory if not p.startswith(".git/")]
    ignored_patterns = git_ignored(root, inventory, no_index=True)
    ignored_effective = git_ignored(root, inventory, no_index=False)
    expected, excluded = [], {}
    for rel in inventory:
        if rel == "codedb.snapshot":
            # codedb writes this into probed roots after a cold scan;
            # not part of the corpus — tracked separately by probes
            excluded[rel] = "codedb_artifact"
            continue
        if rel in ignored_patterns:
            if rel in ignored_effective:
                excluded[rel] = "gitignored"
            else:
                excluded[rel] = "gitignored_but_tracked"
            continue
        reason = skip_reason(root, rel)
        if reason:
            excluded[rel] = reason
        else:
            expected.append(rel)
    return expected, excluded
