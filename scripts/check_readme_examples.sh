#!/usr/bin/env bash
# check_readme_examples.sh — Type-check the library example in README.md
# ("### Using oaspec as a library") against the current public API.
# The block is a complete module, so it is copied verbatim into a
# temporary test module and checked with `gleam check`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/mise_bootstrap.sh
. "$SCRIPT_DIR/lib/mise_bootstrap.sh"
oaspec_require_tool gleam

cd "$(git rev-parse --show-toplevel)"

DOC_FILE="README.md"
HEADING="### Using oaspec as a library"
SMOKE_FILE="test/readme_smoke_test_.gleam"

cleanup() {
  rm -f "$SMOKE_FILE"
}
trap cleanup EXIT

awk -v heading="$HEADING" '
  BEGIN { in_section = 0; in_block = 0 }
  /^#+ / { in_section = ($0 == heading); next }
  in_section && /^```gleam$/ { in_block = 1; next }
  in_section && in_block && /^```$/ { exit }
  in_block { print }
' "$DOC_FILE" > "$SMOKE_FILE"

if [ ! -s "$SMOKE_FILE" ]; then
  echo "FAILED: could not extract the gleam block under '$HEADING' in $DOC_FILE" >&2
  exit 1
fi

echo "==> Type-checking the README library example..."

if gleam check; then
  echo "==> README library example compiles."
else
  echo "FAILED: the README library example does not compile against the public API." >&2
  exit 1
fi
