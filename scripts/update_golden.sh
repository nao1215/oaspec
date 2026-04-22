#!/bin/bash
# Regenerate golden test snapshot files.
# Run via: just update-golden
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/mise_bootstrap.sh
. "$SCRIPT_DIR/lib/mise_bootstrap.sh"
oaspec_require_tool gleam

cd "$(git rev-parse --show-toplevel)"

echo "Updating golden files..."

# Petstore
rm -rf golden/petstore/api
gleam run -- generate --config=golden/petstore.oaspec.yaml

# Complex supported
rm -rf golden/complex_supported/api
gleam run -- generate --config=golden/complex_supported.oaspec.yaml

# Verify formatting compliance
echo "Verifying format compliance..."
gleam format --check golden/petstore/api/ golden/complex_supported/api/

echo "Done. Golden files updated."
echo "Review changes with: git diff golden/"
