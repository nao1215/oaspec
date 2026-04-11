#!/bin/bash
# Regenerate golden test snapshot files.
# Run via: just update-golden
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "Updating golden files..."

# Petstore
rm -rf golden/petstore/api
gleam run -- generate --config=golden/petstore.oaspec.yaml

# Complex supported
rm -rf golden/complex_supported/api
gleam run -- generate --config=golden/complex_supported.oaspec.yaml

echo "Done. Golden files updated."
echo "Review changes with: git diff golden/"
