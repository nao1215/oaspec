set shell := ["sh", "-cu"]

default:
  @just --list

deps:
  gleam deps download

format:
  gleam format src/ test/

format-check:
  gleam format --check src/ test/

typecheck:
  gleam check

build:
  gleam build --warnings-as-errors

test:
  gleam test

docs:
  gleam docs build

escript:
  gleam run -m gleescript

smoke-escript: escript
  bash scripts/smoke_escript.sh ./oaspec

shellspec:
  shellspec

integration:
  bash integration_test/run.sh

check: clean
  gleam format --check src/ test/
  gleam check
  gleam build --warnings-as-errors
  gleam test

ci: deps check

# Run all tests and checks (format, build, unit, shellspec, integration, escript)
all: clean deps
  gleam format --check src/ test/
  gleam check
  gleam build --warnings-as-errors
  gleam test
  shellspec
  bash integration_test/run.sh
  gleam run -m gleescript
  bash scripts/smoke_escript.sh ./oaspec
  @echo ""
  @echo "All checks passed."

sync-check:
  bash scripts/check_sync.sh

# Regenerate and run the petstore client example.
example-petstore:
  gleam run -- generate --config=examples/petstore_client/oaspec.yaml
  cd examples/petstore_client && gleam deps download && gleam build --warnings-as-errors && gleam run

# Regenerate golden test snapshot files
update-golden:
  bash scripts/update_golden.sh

clean:
  gleam clean
  rm -rf test_output test_output_client integration_test/src/api integration_test/build oaspec
