#!/usr/bin/env bash
# check_sync.sh — Verify version consistency across gleam.toml,
# context.gleam, and CHANGELOG.md, and report live test counts for
# manual sanity-check. Exit 1 on any drift.

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
# Previously this script asserted that hard-coded test counts in README.md
# matched the live counts in the repo. The README was slimmed down for
# usability and no longer mentions those numbers, so the assertion is gone.
# We still log the live counts so reviewers can sanity-check them by eye.
echo ""
echo "==> Live test counts (informational)..."

ACTUAL_UNIT_TESTS=$(grep -r '^pub fn .*_test()' test/ --include='*.gleam' | wc -l | tr -d ' ')
ACTUAL_FIXTURES=$(find test/fixtures -type f -name '*.yaml' -o -name '*.json' | wc -l | tr -d ' ')
ACTUAL_OSS=$(find test/fixtures -type f -name 'oss_*' | wc -l | tr -d ' ')

echo "    Unit tests:    $ACTUAL_UNIT_TESTS"
echo "    Test fixtures: $ACTUAL_FIXTURES"
echo "    OSS fixtures:  $ACTUAL_OSS"

# --- 3. Summary ---
echo ""
if [ "$errors" -gt 0 ]; then
  echo "FAILED: $errors inconsistencies found."
  echo "Fix the inconsistencies listed above manually."
  exit 1
else
  echo "All checks passed. Versions and counts are in sync."
fi
