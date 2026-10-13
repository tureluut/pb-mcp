#!/bin/bash
# ---------------------------------------------------------------------------
# build.sh - one-command build for pbmcp (PureBasic 6.x x64, Linux).
#
# Usage:  build.sh          lint + compile pbmcp
#         build.sh check    --check on the real tree (authoritative syntax
#                           check; the switch form is the Linux one:
#                           /SWITCH switches do not exist here)
#
# Mirrors build.cmd (Windows). The ONE deliberate behavioral difference:
# the Linux compile passes --thread - REQUIRED. The non-TS runtime
# heap-corrupts (SIGSEGV / free(): invalid size) when the docs-index
# preload thread runs LoadJSON concurrently with main-thread runtime use;
# measured live, see PORTING-LINUX.md Phase 2 execution record. The
# Windows build stays non-TS (proven green).
#
# Compiler discovery mirrors the server's own ConfigInit() Linux chain:
# PUREBASIC_HOME > ~/purebasic > /opt/purebasic > /usr/local/purebasic >
# pbcompiler on PATH. gcc must be on PATH for linking; if you hit
# "undefined reference to __wrap_memcpy" (PB 6.41 + modern binutils
# link-order bug) see the gcc wrapper note in INSTALL.md.
# ---------------------------------------------------------------------------
set -u
cd "$(dirname "$0")"

PBC=""
if [ -n "${PUREBASIC_HOME:-}" ] && [ -x "${PUREBASIC_HOME%/}/compilers/pbcompiler" ]; then
  PBC="${PUREBASIC_HOME%/}/compilers/pbcompiler"
fi
if [ -z "$PBC" ]; then
  for home in "$HOME/purebasic" /opt/purebasic /usr/local/purebasic; do
    if [ -x "$home/compilers/pbcompiler" ]; then
      PBC="$home/compilers/pbcompiler"
      break
    fi
  done
fi
if [ -z "$PBC" ] && command -v pbcompiler >/dev/null 2>&1; then
  PBC="$(command -v pbcompiler)"
fi
if [ -z "$PBC" ]; then
  echo "build.sh: pbcompiler not found - set PUREBASIC_HOME or install under ~/purebasic, /opt/purebasic or /usr/local/purebasic, or put pbcompiler on PATH"
  exit 1
fi

echo "build.sh: encoding lint - UTF-8 BOM required on all src/*.pb"
if ! bash tools/lint_encoding.sh; then
  echo "build.sh: lint FAILED - fix source encoding before compiling"
  exit 1
fi

SRC="$(pwd)/src/main.pb"
# PBMCP_OUT overrides the output path (make-dist.sh builds straight into
# dist/ so a running server cannot lock the target binary)
if [ -n "${PBMCP_OUT:-}" ]; then OUT="$PBMCP_OUT"; else OUT="$(pwd)/pbmcp"; fi

if [ "${1:-}" = "check" ]; then
  echo "build.sh: --check on \"$SRC\""
  exec "$PBC" --check --console "$SRC"
fi

echo "build.sh: compiling \"$SRC\" (--thread: required on Linux, see header)"
"$PBC" --thread --console "$SRC" --output "$OUT"
RC=$?
if [ $RC -ne 0 ] || [ ! -f "$OUT" ]; then
  echo "build.sh: compile FAILED"
  exit 1
fi
echo "build.sh: OK - \"$OUT\""
