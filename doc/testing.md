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

## Mutation testing

`gleam run -m metamon/mutation -- run` changes one operator, `!` or boolean literal in a module under `src/` at a time and runs `gleam test --target erlang` on each change; `gleam run -m metamon/mutation -- gate` then fails on a survivor that `doc/mutation/baseline.json` does not list, and `gleam run -m metamon/mutation -- baseline` records a full run as the baseline. `.github/workflows/mutation.yml` mutates the modules a pull request or push changes and runs the gate; the weekly run mutates every module in two parts. `just mutation` and `just mutation-record` run the same steps locally.

There is no baseline yet. It will be recorded from the first full run on CI, and until then the workflow runs without the gate.
