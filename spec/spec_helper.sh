#!/bin/sh
# shellcheck shell=sh

# Shared setup for ShellSpec integration tests.

set -eu

export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

# Project root directory
PROJECT_ROOT="$(cd "$(dirname "$SHELLSPEC_SPECDIR")" && pwd)"
export PROJECT_ROOT

# Temporary output directory for test artifacts
TEST_OUTPUT_DIR="${PROJECT_ROOT}/test_output"
export TEST_OUTPUT_DIR

# Client output directory (separate from server)
TEST_OUTPUT_DIR_CLIENT="${PROJECT_ROOT}/test_output_client"
export TEST_OUTPUT_DIR_CLIENT

# Helper: run oaspec generate command
generate() {
  cd "$PROJECT_ROOT" && gleam run -- generate "$@" 2>&1
}

# Helper: clean test output
clean_test_output() {
  rm -rf "$TEST_OUTPUT_DIR" "$TEST_OUTPUT_DIR_CLIENT"
}

# Helper: generate petstore once (idempotent)
generate_petstore_once() {
  if [ ! -f "$TEST_OUTPUT_DIR/api/types.gleam" ]; then
    cd "$PROJECT_ROOT" && gleam run -- generate --config=test/fixtures/oaspec.yaml 2>/dev/null
  fi
}

# Helper: generate complex supported spec once (idempotent)
# Note: uses same output dir as petstore (both package=api), so clean first
generate_complex_supported_once() {
  clean_test_output
  cd "$PROJECT_ROOT" && gleam run -- generate --config=test/fixtures/complex-supported-oaspec.yaml 2>/dev/null
}
