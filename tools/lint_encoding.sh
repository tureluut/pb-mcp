#!/bin/bash
# lint_encoding.sh - enforce the project source-encoding rule (Linux port
# of lint_encoding.ps1 - KEEP THE TWO IN SYNC; same rule, same messages).
#
# The plan offered: ASCII-only OR UTF-8 with BOM. The user elected the
# BOM branch. Evidence (frozen): BOM-less UTF-8 sources are silently misread
# as CP-1252 by both PB 5.73 and 6.40 (mcp-pb-spike-640/out_goodcheck.txt).
# Rule: every src/*.pb must start with a UTF-8 BOM (EF BB BF). Harmless on
# Linux, mandatory on Windows: one source tree.
set -u
shopt -s nullglob
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
for f in "$ROOT"/src/*.pb; do
  b=$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')
  if [ "$b" = "efbbbf" ]; then
    echo "  OK   $(basename "$f")"
  else
    echo "  FAIL $(basename "$f") - missing UTF-8 BOM (BOM-less UTF-8 mojibakes on the PB compilers)"
    fail=1
  fi
done
exit $fail
