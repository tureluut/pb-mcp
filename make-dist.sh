#!/bin/bash
# ---------------------------------------------------------------------------
# make-dist.sh - build pbmcp and assemble the self-contained dist/
# (Linux port of make-dist.cmd; the layout differs only in the binary name).
#
# Usage:  make-dist.sh
#
# Output layout:
#   dist/pbmcp
#   dist/index-*.json        newest repo-root index-*.json copied verbatim -
#                            a working docs-index drop-in (the loader's glob is
#                            index-*.json; plain index.json is ignored). When
#                            none exists the binary's embedded placeholder covers.
#   dist/README.md
#   dist/INSTALL.md
#   dist/skills/purebasic/        complete skill (SKILL.md + references/)
#
# Compiles straight into dist/ (via PBMCP_OUT) so a server running from the
# repo-root binary does not lock the build target. dist/ is gitignored;
# regenerate after every release-worthy change.
# ---------------------------------------------------------------------------
set -u
cd "$(dirname "$0")"

fail() { echo "make-dist: assembly FAILED"; exit 1; }

echo "make-dist: creating dist layout"
rm -rf dist
mkdir -p dist/skills/purebasic || fail

echo "make-dist: building pbmcp"
export PBMCP_OUT="$(pwd)/dist/pbmcp"
if ! bash build.sh; then
  echo "make-dist: build FAILED - if dist/pbmcp is locked, close the MCP client using it and re-run"
  exit 1
fi

echo "make-dist: copying docs + skill"
cp README.md dist/ || fail
cp INSTALL.md dist/ || fail
idx=$(ls -t index-*.json 2>/dev/null | head -n 1)
if [ -n "$idx" ]; then
  echo "make-dist: docs index drop-in - $idx"
  cp "$idx" dist/ || fail
else
  echo "make-dist: no index-*.json at repo root - binary falls back to the embedded placeholder"
fi
echo "make-dist: copying complete skill tree (SKILL.md + references/)"
cp -R skills/purebasic/. dist/skills/purebasic/ || fail

# smoke: the artifact must launch (also warms it past first-run security
# scanning - a never-executed fresh binary can fail to start in time under
# the suite's timing-sensitive tests)
echo "make-dist: smoke - dist/pbmcp version"
"$(pwd)/dist/pbmcp" version >/dev/null 2>&1 || fail

echo "make-dist: OK"
ls dist dist/skills/purebasic
