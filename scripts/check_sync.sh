#!/usr/bin/env bash
# check_sync.sh — Verify version and test count consistency
# across gleam.toml, context.gleam, README.md, and CHANGELOG.md.
# Exit 1 on any drift.

set -euo pipefail

errors=0
warn() { echo "DRIFT: $1"; errors=$((errors + 1)); }

# --- 1. Version consistency ---
TOML_VERSION=$(grep '^version' gleam.toml | sed 's/.*"\(.*\)"/\1/')
CONTEXT_VERSION=$(grep 'pub const version' src/oaspec/internal/codegen/context.gleam | sed 's/.*"\(.*\)"/\1/')
CHANGELOG_VERSION=$(grep -m1 '^## \[' CHANGELOG.md | sed 's/.*\[\(.*\)\].*/\1/')

echo "==> Checking version consistency..."
echo "    gleam.toml:   $TOML_VERSION"
echo "    context.gleam: $CONTEXT_VERSION"
echo "    CHANGELOG.md:  $CHANGELOG_VERSION"

if [ "$TOML_VERSION" != "$CONTEXT_VERSION" ]; then
  warn "gleam.toml version ($TOML_VERSION) != context.gleam version ($CONTEXT_VERSION)"
fi
if [ "$CHANGELOG_VERSION" != "Unreleased" ] && [ "$TOML_VERSION" != "$CHANGELOG_VERSION" ]; then
  warn "gleam.toml version ($TOML_VERSION) != CHANGELOG.md latest entry ($CHANGELOG_VERSION)"
fi

# --- 2. Test counts ---
echo ""
echo "==> Checking test counts in README..."

# Count actual unit tests (pub fn *_test functions across all test files)
ACTUAL_UNIT_TESTS=$(grep -r '^pub fn .*_test()' test/ --include='*.gleam' | wc -l | tr -d ' ')

# Count test fixtures
ACTUAL_FIXTURES=$(find test/fixtures -type f -name '*.yaml' -o -name '*.json' | wc -l | tr -d ' ')

# Count OSS-derived fixtures
ACTUAL_OSS=$(find test/fixtures -type f -name 'oss_*' | wc -l | tr -d ' ')

# Extract README claims
README_UNIT=$(grep -o '[0-9]* unit tests' README.md | grep -o '[0-9]*')
README_FIXTURES=$(grep -o '[0-9]* test fixtures' README.md | grep -o '[0-9]*')
README_OSS=$(grep -o '[0-9]* OSS-derived' README.md | grep -o '[0-9]*')

echo "    Unit tests:    actual=$ACTUAL_UNIT_TESTS, README=$README_UNIT"
echo "    Test fixtures: actual=$ACTUAL_FIXTURES, README=$README_FIXTURES"
echo "    OSS fixtures:  actual=$ACTUAL_OSS, README=$README_OSS"

if [ "$ACTUAL_UNIT_TESTS" != "$README_UNIT" ]; then
  warn "Unit test count: actual $ACTUAL_UNIT_TESTS != README $README_UNIT"
fi
if [ "$ACTUAL_FIXTURES" != "$README_FIXTURES" ]; then
  warn "Test fixture count: actual $ACTUAL_FIXTURES != README $README_FIXTURES"
fi
if [ "$ACTUAL_OSS" != "$README_OSS" ]; then
  warn "OSS fixture count: actual $ACTUAL_OSS != README $README_OSS"
fi

# --- 3. Summary ---
echo ""
if [ "$errors" -gt 0 ]; then
  echo "FAILED: $errors inconsistencies found."
  echo "Fix the inconsistencies listed above manually."
  exit 1
else
  echo "All checks passed. Versions and counts are in sync."
fi
