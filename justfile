set shell := ["sh", "-cu"]

# Make the mise-managed toolchain (erlang / gleam / rebar) visible to
# every recipe even when the invoking shell has not run `mise
# activate`. The bootstrap helper is the same one that standalone
# bash scripts source, so `just <recipe>` and `bash scripts/<name>.sh`
# behave identically in a fresh shell.
export PATH := shell('. scripts/lib/mise_bootstrap.sh; printf %s "$PATH"')

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

lint:
  gleam run -m glinter -- --stats

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

e2e: escript
  OASPEC_BIN="$PWD/oaspec" atago run --ci --parallel 1 ./e2e

integration:
  bash integration_test/run.sh

check: clean
  gleam format --check src/ test/
  gleam check
  gleam run -m glinter -- --stats
  gleam build --warnings-as-errors
  gleam test

ci: deps check

# Run all tests and checks (format, lint, build, unit, e2e, integration, escript)
all: clean deps
  gleam format --check src/ test/
  gleam check
  gleam run -m glinter -- --stats
  gleam build --warnings-as-errors
  gleam test
  gleam run -m gleescript
  OASPEC_BIN="$PWD/oaspec" atago run --ci --parallel 1 ./e2e
  bash integration_test/run.sh
  bash scripts/smoke_escript.sh ./oaspec
  @echo ""
  @echo "All checks passed."

sync-check:
  bash scripts/check_sync.sh

# Build and test the BEAM transport adapter (sibling package).
adapter-httpc:
  cd adapters/httpc && gleam build --warnings-as-errors

# Build and test the JavaScript fetch adapter (sibling package).
adapter-fetch:
  cd adapters/fetch && gleam deps download && gleam build --warnings-as-errors

# Regenerate and run the petstore client example.
example-petstore:
  gleam run -- generate --config=examples/petstore_client/oaspec.yaml
  cd examples/petstore_client && gleam deps download && gleam build --warnings-as-errors && gleam run

# Regenerate and run the petstore client example on the JavaScript target.
example-petstore-fetch:
  gleam run -- generate --config=examples/petstore_client_fetch/oaspec.yaml
  cd examples/petstore_client_fetch && gleam deps download && gleam build --warnings-as-errors && gleam run

# Run the server_adapter example. `handlers.gleam` is hand-written and
# committed, so we do NOT regenerate here (generation would overwrite it).
example-server-adapter:
  cd examples/server_adapter && gleam deps download && gleam build --warnings-as-errors && gleam run

# Regenerate golden test snapshot files
update-golden:
  bash scripts/update_golden.sh

clean:
  gleam clean
  rm -rf test_output test_output_client integration_test/src/api integration_test/build oaspec
