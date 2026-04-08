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
  @echo ""
  @echo "All checks passed."

clean:
  gleam clean
  rm -rf test_output test_output_client integration_test/src/api integration_test/build oaspec
