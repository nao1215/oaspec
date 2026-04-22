#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/mise_bootstrap.sh
. "$SCRIPT_DIR/lib/mise_bootstrap.sh"

ARTIFACT_PATH="${1:-$PROJECT_ROOT/oaspec}"
ARTIFACT_DIR="$(cd "$(dirname "$ARTIFACT_PATH")" && pwd)"
ARTIFACT_PATH="$ARTIFACT_DIR/$(basename "$ARTIFACT_PATH")"
SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oaspec-escript-smoke.XXXXXX")"

info() { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

assert_output_contains() {
  local output="$1"
  local expected="$2"
  case "$output" in
    *"$expected"*) ;;
    *) fail "Expected output to include: $expected" ;;
  esac
}

assert_file() {
  local path="$1"
  [ -f "$path" ] || fail "Expected file to exist: $path"
}

cleanup() {
  clean_generated_outputs
  rm -rf "$SMOKE_DIR"
}

clean_generated_outputs() {
  rm -rf "$PROJECT_ROOT/test_output" "$PROJECT_ROOT/test_output_client"
}

trap cleanup EXIT

oaspec_require_tool escript
oaspec_require_tool gleam

[ -f "$ARTIFACT_PATH" ] || fail "Artifact not found: $ARTIFACT_PATH"

clean_generated_outputs

info "Smoke-testing packaged escript: init"
if ! INIT_OUTPUT="$(cd "$SMOKE_DIR" && "$ARTIFACT_PATH" init 2>&1)"; then
  printf "%s\n" "$INIT_OUTPUT" >&2
  fail "init smoke test failed"
fi
assert_output_contains "$INIT_OUTPUT" "Created ./oaspec.yaml"
assert_file "$SMOKE_DIR/oaspec.yaml"
grep -Fq "input: openapi.yaml" "$SMOKE_DIR/oaspec.yaml" || fail "Generated init config is missing input"
grep -Fq "package: api" "$SMOKE_DIR/oaspec.yaml" || fail "Generated init config is missing package"

info "Smoke-testing packaged escript: validate"
if ! VALIDATE_OUTPUT="$(cd "$PROJECT_ROOT" && "$ARTIFACT_PATH" validate --config=test/fixtures/oaspec.yaml 2>&1)"; then
  printf "%s\n" "$VALIDATE_OUTPUT" >&2
  fail "validate smoke test failed"
fi
assert_output_contains "$VALIDATE_OUTPUT" "Validation passed."
[ ! -e "$PROJECT_ROOT/test_output" ] || fail "validate should not create test_output"
[ ! -e "$PROJECT_ROOT/test_output_client" ] || fail "validate should not create test_output_client"

info "Smoke-testing packaged escript: generate"
clean_generated_outputs
if ! GENERATE_OUTPUT="$(cd "$PROJECT_ROOT" && "$ARTIFACT_PATH" generate --config=test/fixtures/oaspec.yaml 2>&1)"; then
  printf "%s\n" "$GENERATE_OUTPUT" >&2
  fail "generate smoke test failed"
fi
assert_output_contains "$GENERATE_OUTPUT" "Successfully generated "
assert_file "$PROJECT_ROOT/test_output/api/types.gleam"
assert_file "$PROJECT_ROOT/test_output/api/router.gleam"
assert_file "$PROJECT_ROOT/test_output_client/api/client.gleam"

info "Packaged escript smoke tests passed."
