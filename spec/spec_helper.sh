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

# Helper: run oas-gleam generate command
generate() {
  cd "$PROJECT_ROOT" && gleam run -- generate "$@" 2>&1
}

# Helper: clean test output
clean_test_output() {
  rm -rf "$TEST_OUTPUT_DIR"
}

# Helper: generate petstore once (idempotent)
generate_petstore_once() {
  if [ ! -f "$TEST_OUTPUT_DIR/server/types.gleam" ]; then
    cd "$PROJECT_ROOT" && gleam run -- generate --config=test/fixtures/oas-gleam.yaml 2>/dev/null
  fi
}

# Helper: generate complex supported spec once (idempotent)
generate_complex_supported_once() {
  if [ ! -f "$TEST_OUTPUT_DIR/complex_server/types.gleam" ]; then
    cd "$PROJECT_ROOT" && gleam run -- generate --config=test/fixtures/complex-supported-oas-gleam.yaml 2>/dev/null
  fi
}
