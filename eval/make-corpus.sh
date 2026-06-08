#!/bin/bash
# Generates eval/corpus-synthetic/ — edge-case trap corpus for codedb trust probes.
# Every trap file carries a unique NEEDLE_* token so probes can search for it exactly.
# Reproducible: deterministic content, no timestamps inside files.
set -euo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
CORPUS="$EVAL_DIR/corpus-synthetic"

rm -rf "$CORPUS"
mkdir -p "$CORPUS"
cd "$CORPUS"

git init -q .

# ---------------------------------------------------------------------------
# 0. Control file — sanity check that the corpus is indexed at all
# ---------------------------------------------------------------------------
cat > control.c <<'EOF'
/* control file */
int control_fn(void) { return 42; } // NEEDLE_CONTROL
EOF

# ---------------------------------------------------------------------------
# 1. Unicode filenames: NFC vs NFD (APFS normalization trap), CJK
#    NFC and NFD forms live in separate dirs — APFS treats them as the same
#    name within one dir.
# ---------------------------------------------------------------------------
mkdir -p unicode/nfc unicode/nfd
# NFC: café -> 0x63 0x61 0x66 0xC3 0xA9
NFC_NAME=$(printf 'caf\xc3\xa9.py')
# NFD: café -> 0x63 0x61 0x66 0x65 0xCC 0x81
NFD_NAME=$(printf 'cafe\xcc\x81.py')
printf 'def nfc_fn():\n    return "NEEDLE_NFC_CAFE"\n' > "unicode/nfc/$NFC_NAME"
printf 'def nfd_fn():\n    return "NEEDLE_NFD_CAFE"\n' > "unicode/nfd/$NFD_NAME"
printf 'export const jp = "NEEDLE_JAPANESE";\n' > "unicode/日本語.ts"

# ---------------------------------------------------------------------------
# 2. Encodings / line endings — tokens at exactly known line numbers
# ---------------------------------------------------------------------------
mkdir -p encodings

# UTF-8 BOM, LF endings. Token NEEDLE_BOM_L3 is on line 3.
{
  printf '\xef\xbb\xbf'
  printf 'bom line one\n'
  printf 'bom line two\n'
  printf 'bom NEEDLE_BOM_L3 here\n'
  printf 'bom line four\n'
} > encodings/bom.txt

# Pure CRLF. Token NEEDLE_CRLF_L5 is on line 5 of 10.
{
  for i in 1 2 3 4; do printf 'crlf line %d\r\n' "$i"; done
  printf 'crlf NEEDLE_CRLF_L5 here\r\n'
  for i in 6 7 8 9 10; do printf 'crlf line %d\r\n' "$i"; done
} > encodings/crlf.txt

# Mixed: lines 1-3 LF, lines 4-6 CRLF. Token NEEDLE_MIXED_L6 on line 6.
{
  printf 'mixed line 1\n'
  printf 'mixed line 2\n'
  printf 'mixed line 3\n'
  printf 'mixed line 4\r\n'
  printf 'mixed line 5\r\n'
  printf 'mixed NEEDLE_MIXED_L6 here\r\n'
} > encodings/mixed.txt

# No trailing newline. Token NEEDLE_NOEOL_L3 on line 3 (final, unterminated).
printf 'noeol line 1\nnoeol line 2\nnoeol NEEDLE_NOEOL_L3 end' > encodings/noeol.txt

# ---------------------------------------------------------------------------
# 3. Size / binary traps
# ---------------------------------------------------------------------------
mkdir -p sizes

# 511KB file (523,264 bytes < 524,288 cap). Tokens near start and end.
{
  printf 'NEEDLE_UNDER_CAP_START\n'
  # 523264 - 23 (start line) - 21 (end line) = 523220 filler bytes
  python3 -c "import sys; sys.stdout.write(('filler-under-cap-line\n' * (523220 // 22))[:523220])"
  printf 'NEEDLE_UNDER_CAP_END\n'
} > sizes/under-cap-511kb.txt

# 600KB file (614,400 bytes > 524,288 cap). Token near START so a partial
# read would still see it — isolates the file-level skip.
{
  printf 'NEEDLE_OVER_CAP_START\n'
  python3 -c "import sys; sys.stdout.write(('filler-over-cap-line!\n' * (614357 // 22))[:614357])"
  printf 'NEEDLE_OVER_CAP_END\n'
} > sizes/over-cap-600kb.txt

# First null byte at offset 600 — defeats a 512-byte binary sniff.
# Token before the null (offset < 600) and after it.
python3 - <<'PYEOF'
data = b''
line = b'pre-null padding line with NEEDLE_NULLAT600_EARLY token\n'
while len(data) + len(line) <= 600:
    data += line
data += b'x' * (600 - len(data))   # pad to exactly 600
data += b'\x00'
data += b'\npost-null text with NEEDLE_NULLAT600_LATE token\n'
open('sizes/null-at-600.txt', 'wb').write(data)
PYEOF

# Real PNG bytes renamed .txt (nulls in first 16 bytes) with an ASCII token
# embedded mid-stream.
python3 - <<'PYEOF'
png = bytes.fromhex('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489')
png += b'NEEDLE_PNG_AS_TXT'
png += bytes.fromhex('0000000049454e44ae426082')
open('sizes/image-renamed.txt', 'wb').write(png)
PYEOF

# ---------------------------------------------------------------------------
# 4. Gitignore battery
#    Root ignores: *.log, build/ (dir-only), outdir/ (dir-only, NOT in any
#    hardcoded skip list — discriminates gitignore handling from skip_dirs),
#    **/generated
#    Nested logs/.gitignore re-includes important.log via negation.
# ---------------------------------------------------------------------------
mkdir -p gitignore-battery
cd gitignore-battery

cat > .gitignore <<'EOF'
*.log
build/
outdir/
**/generated
EOF

mkdir -p logs
cat > logs/.gitignore <<'EOF'
!important.log
EOF
printf 'TOKEN_DEBUG_LOG should be ignored (*.log)\n'        > logs/debug.log
printf 'TOKEN_IMPORTANT_LOG re-included by negation\n'      > logs/important.log

mkdir -p build
printf 'int build_fn(void); /* TOKEN_BUILD_DIRONLY ignored via build/ */\n' > build/keep.c
# A FILE named 'build' — dir-only pattern build/ must NOT ignore it.
printf 'TOKEN_BUILD_FILE not a dir, must stay visible\n' > subdir-holder.txt
mkdir -p filetrap
printf 'TOKEN_BUILD_PLAINFILE dir-only pattern must not match files\n' > filetrap/build

mkdir -p outdir
printf 'TOKEN_OUTDIR ignored via outdir/ (not in skip_dirs)\n' > outdir/artifact.c

mkdir -p deep/nested/generated
printf 'TOKEN_GENERATED ignored via **/generated\n' > deep/nested/generated/gen.c

printf 'TOKEN_GITIGNORE_VISIBLE plain visible file\n' > visible.c
cd "$CORPUS"

# ---------------------------------------------------------------------------
# 4b. Regex trap file — lines crafted so that "unsupported construct treated
#     as literal" produces a DIFFERENT match set than the Python `re` oracle.
#     One probe target per line; line numbers are load-bearing.
# ---------------------------------------------------------------------------
mkdir -p regex
cat > regex/traps.txt <<'EOF'
aa backref-target
a1 backref-literal-trap
fooZ endanchor-literal-trap
foo
pL unicode-prop-literal-trap
phello unicode-prop-p-trap
foobar lookahead-target
foobaz lookahead-decoy
catfood class-target-cat
batfood class-target-bat
ratfood class-decoy-rat
word boundary target word.
swordfish noboundary
aaa quantifier-triple
aaaa quantifier-quad
3.14 dotted-number
3X14 undotted-number
FOO case-upper
foo case-lower
EOF

# ---------------------------------------------------------------------------
# 5. Symlinks: broken, loop, escape-root
# ---------------------------------------------------------------------------
mkdir -p symlinks
ln -sf /nonexistent/target symlinks/broken-link
ln -sf b symlinks/a
ln -sf a symlinks/b
OUTSIDE="/tmp/codedb-eval-outside.txt"
printf 'NEEDLE_OUTSIDE_ROOT lives outside the corpus root\n' > "$OUTSIDE"
ln -sf "$OUTSIDE" symlinks/escape-link

# ---------------------------------------------------------------------------
# 6. Name traps: source dir named Build/ (capital — case-insensitive prune
#    trap), Cargo.lock with a searchable token
# ---------------------------------------------------------------------------
mkdir -p Build
cat > Build/real_code.c <<'EOF'
/* Real source code living in a dir named Build/ */
int build_dir_source(void) { return 1; } /* NEEDLE_BUILD_DIR_SOURCE */
EOF

cat > Cargo.lock <<'EOF'
# This file is automatically @generated by Cargo.
[[package]]
name = "needle-package"
version = "1.2.3"
checksum = "NEEDLE_CARGO_LOCK"
EOF

echo "corpus-synthetic generated at: $CORPUS"
find . -not -path './.git/*' -not -name .git | sort | wc -l | xargs echo "entries (excl .git):"
