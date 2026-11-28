# Testing

`just check` runs format, type check, glinter and the unit tests; `just e2e`, `just integration` and `just bench` run the suites below that need the escript or generated projects. CI runs the unit tests on the Gleam floor (1.14.0, OTP 27) and on the latest Gleam 1.x (OTP 29).

## Examples and unit tests

`gleam test` runs the gleeunit suite under `test/`: the parser and validator (`oaspec_parse_core_test.gleam`, `oaspec_validate_test.gleam`), the code generators (`oaspec_codegen_test.gleam`, `oaspec_server_codegen_test.gleam`), and about a hundred documents taken from other OpenAPI tools' test suites (`oaspec_oss_fixture_test.gleam`, fixtures `test/fixtures/oss_*`).

## Generated properties

`test/naming_property_test.gleam` and `test/normalize_argv_property_test.gleam` use metamon for the naming helpers (idempotence, separators dropped, case of the first letter) and for the argument normalisation of the CLI. `.github/workflows/nightly-property.yml` runs the whole suite ten times a night with `METAMON_RUNS_MULTIPLIER=10`.

## Metamorphic relations

`test/document_metamorphic_test.gleam` takes every `test/fixtures/*.yaml` that oaspec generates code for from the string alone, rewrites it in ways that must not change the output, and checks that every generated file keeps its path and content:

- the document written as JSON. YAML goes through yay and JSON through OTP's `json` module, so this is also a differential test of the two front ends,
- the top-level keys in a random order (drawn by metamon),
- `x-` extension keys added to the root and to `info`.

The test fails if fewer than 50 fixtures qualify, so a broken filter cannot make it pass without checking anything.

## Golden files

`test/golden_test.gleam` compares the code generated for the documents in `golden/` (petstore, a document using most supported features, per-operation handlers) with the committed files byte for byte. `just update-golden` rewrites them after an intended change.

## End-to-end tests and output snapshots

The atago suites in `e2e/` run the escript: `init`, `generate`, `validate`, the `--check` mode and the help text, with exit codes, stderr and the generated file trees. Whole outputs are pinned in `e2e/snapshots/`.

## Real documents

`integration_test/run.sh` generates code for many fixtures into Gleam projects and builds and tests them. The `Full GitHub OpenAPI` and `Full Stripe OpenAPI` jobs of `ci-tests.yml` generate, format and build the client for GitHub's and Stripe's published documents (about 1000 operations each).

## Paired CI benchmarks

`bench/himorime.yaml` measures the escript; `.github/workflows/bench.yml` compares each pull request with its base in the same job. `bench/README.md` lists what is measured.

## Coverage

`just coverage` (`gleam build --target erlang`, then `gleam run -m metamon/mutation -- coverage`) runs the tests on the Erlang target with every module under `src/` measured and writes `build/coverage/lcov.info`; `.github/workflows/coverage.yml` reports it with octocov on pull requests and main. The local run on 2026-11-28 reached 87.3% of the lines.

## Mutation testing

`gleam run -m metamon/mutation -- run` changes one operator, `!` or boolean literal in a module under `src/` at a time and runs `gleam test --target erlang` on each change; `gleam run -m metamon/mutation -- gate` then fails on a survivor that `doc/mutation/baseline.json` does not list, and `gleam run -m metamon/mutation -- baseline` records a full run as the baseline. `.github/workflows/mutation.yml` mutates the modules a pull request or push changes and runs the gate; the weekly run mutates every module in two parts. `just mutation` and `just mutation-record` run the same steps locally.

The baseline comes from the first full run on CI (2026-11-27, run 46076687779). To record a new one, download the `mutation-results` artifact of a weekly run to `build/mutation/results.json` and run `just mutation-record`, which also rewrites the table below. `just mutation` runs every module locally; a loaded machine can time out tests that pass on CI, so record the baseline from a CI run.

<!-- mutation:start -->
| Module | Killed | Lived | Timed out | Score |
|---|---:|---:|---:|---:|
| `oaspec/config` | 3 | 1 | 0 | 75.0% |
| `oaspec/internal/cli` | 21 | 14 | 0 | 60.0% |
| `oaspec/internal/codegen/client` | 12 | 2 | 0 | 85.7% |
| `oaspec/internal/codegen/client_ir` | 67 | 91 | 0 | 42.4% |
| `oaspec/internal/codegen/client_request` | 37 | 26 | 0 | 58.7% |
| `oaspec/internal/codegen/codec_helpers` | 2 | 2 | 0 | 50.0% |
| `oaspec/internal/codegen/context` | 2 | 2 | 0 | 50.0% |
| `oaspec/internal/codegen/decoders` | 9 | 2 | 0 | 81.8% |
| `oaspec/internal/codegen/encoders` | 28 | 9 | 0 | 75.7% |
| `oaspec/internal/codegen/guards` | 29 | 36 | 0 | 44.6% |
| `oaspec/internal/codegen/import_analysis` | 12 | 1 | 0 | 92.3% |
| `oaspec/internal/codegen/ir_build` | 10 | 14 | 0 | 41.7% |
| `oaspec/internal/codegen/operation_ir` | 5 | 1 | 0 | 83.3% |
| `oaspec/internal/codegen/router_ir` | 62 | 35 | 0 | 63.9% |
| `oaspec/internal/codegen/schema_dispatch` | 1 | 1 | 0 | 50.0% |
| `oaspec/internal/codegen/schema_utils` | 19 | 15 | 0 | 55.9% |
| `oaspec/internal/codegen/server` | 32 | 6 | 0 | 84.2% |
| `oaspec/internal/codegen/server_request_decode` | 53 | 44 | 0 | 54.6% |
| `oaspec/internal/codegen/validate` | 33 | 9 | 0 | 78.6% |
| `oaspec/internal/codegen/writer` | 5 | 0 | 0 | 100.0% |
| `oaspec/internal/config_check` | 9 | 3 | 0 | 75.0% |
| `oaspec/internal/generate` | 1 | 0 | 0 | 100.0% |
| `oaspec/internal/openapi/capability_check` | 0 | 3 | 0 | 0.0% |
| `oaspec/internal/openapi/dedup` | 3 | 3 | 0 | 50.0% |
| `oaspec/internal/openapi/diagnostic` | 3 | 1 | 0 | 75.0% |
| `oaspec/internal/openapi/diagnostic_format` | 1 | 0 | 0 | 100.0% |
| `oaspec/internal/openapi/external_loader` | 1 | 0 | 0 | 100.0% |
| `oaspec/internal/openapi/external_loader_planner` | 8 | 0 | 0 | 100.0% |
| `oaspec/internal/openapi/filter` | 7 | 3 | 0 | 70.0% |
| `oaspec/internal/openapi/hoist` | 6 | 2 | 0 | 75.0% |
| `oaspec/internal/openapi/normalize` | 2 | 15 | 0 | 11.8% |
| `oaspec/internal/openapi/operations` | 1 | 0 | 0 | 100.0% |
| `oaspec/internal/openapi/parser` | 56 | 21 | 2 | 73.4% |
| `oaspec/internal/openapi/parser_schema` | 21 | 7 | 0 | 75.0% |
| `oaspec/internal/openapi/schema` | 3 | 3 | 0 | 50.0% |
| `oaspec/internal/progress` | 9 | 4 | 0 | 69.2% |
| `oaspec/internal/util/content_type` | 9 | 0 | 0 | 100.0% |
| `oaspec/internal/util/http` | 7 | 6 | 0 | 53.8% |
| `oaspec/internal/util/naming` | 6 | 1 | 0 | 85.7% |
| `oaspec/transport` | 16 | 0 | 0 | 100.0% |
| all | 611 | 383 | 2 | 61.5% |
<!-- mutation:end -->
