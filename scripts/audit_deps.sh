#!/usr/bin/env bash
# Dependency vulnerability scan, used identically by CI and locally.
#
# Why two passes: pip-audit looks packages up on PyPI, and the CPU-only builds
# (torch==X+cpu) only exist on download.pytorch.org, so pip-audit skips them.
# The +cpu wheels are built from the same source release as PyPI's torch==X, and
# advisories are keyed by release version, so pass 2 audits the lock with "+cpu" stripped.
set -euo pipefail

LOCK="${1:-requirements.txt}"
STRIPPED="$(mktemp)"
trap 'rm -f "$STRIPPED"' EXIT

# --no-deps --disable-pip: audit the exact hashed pins without installing anything
# (fast, and works on any OS even though the lock targets Linux).
echo "== pass 1: full lock =="
pip-audit -r "$LOCK" --no-deps --disable-pip --progress-spinner off

echo "== pass 2: CPU torch builds mapped to their PyPI release =="
sed 's/+cpu//' "$LOCK" > "$STRIPPED"
pip-audit -r "$STRIPPED" --no-deps --disable-pip --progress-spinner off
