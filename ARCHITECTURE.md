# Architecture

This document describes the internal structure of `oaspec` and, in particular,
the boundary between code that is **pure Gleam** (target-agnostic) and code
that is **BEAM-only** (depends on Erlang FFI, escript bootstrap, or
BEAM-specific Gleam packages).

The boundary is documented because most of the value `oaspec` produces — spec
parsing, normalization, capability checking, and code generation — is pure
data transformation that does not, in principle, require the Erlang runtime.
Today the released artifact is an Erlang escript and the package is pinned to
`target = "erlang"` in `gleam.toml`, but understanding what is structurally
pure versus what is coupled to BEAM makes future work tractable: a
JavaScript-target build of the analysis core, alternative front-ends (editor
integrations, browser-based spec tooling), and the JavaScript fetch transport
adapter tracked in #347.

This document is **descriptive**, not prescriptive. It captures the current
state. It does not commit the project to any particular split.

## Two-layer model

```
+--------------------------------------------------+
| Shell (BEAM-only)                                |
|   src/oaspec.gleam                main / argv    |
|   src/oaspec/internal/cli.gleam   glint, IO      |
|   src/oaspec/config.gleam         simplifile     |
|   src/oaspec/openapi/parser.gleam yay + FFI      |
|   src/oaspec/codegen/writer.gleam simplifile     |
|   src/oaspec/internal/formatter.gleam subprocess |
|   src/oaspec/internal/progress.gleam clock FFI   |
|   src/oaspec_*ffi.erl, src/yaml_loc_ffi.erl      |
+-------------------|------------------------------+
                    | calls
                    v
+--------------------------------------------------+
| Core (pure Gleam — no FFI, no IO)                |
|   src/oaspec/generate.gleam       orchestrator   |
|   src/oaspec/transport.gleam      client runtime |
|   src/oaspec/mock.gleam           test helpers   |
|   src/oaspec/openapi/diagnostic.gleam            |
|   src/oaspec/internal/capability.gleam           |
|   src/oaspec/internal/codegen/**  IR + emit      |
|   src/oaspec/internal/openapi/**  AST + passes   |
|   src/oaspec/internal/util/**     helpers        |
+--------------------------------------------------+
```

The **shell** layer is responsible for everything that requires the world:
reading argv, loading files, running subprocesses, writing generated output,
detecting TTY, halting the process. The **core** layer takes already-loaded
data (Gleam values) and returns more Gleam values.

## Module classification

Every Gleam module in `src/` falls into one of three buckets.

### Pure (would compile on any Gleam target)

These modules have no `@external(erlang, ...)` declarations and no imports of
BEAM-only packages (`simplifile`, `glint`, `argv`, `yay`).

| Module | Role |
|--------|------|
| `oaspec/generate.gleam` | Top-level codegen orchestration |
| `oaspec/transport.gleam` | Client transport contract and middleware |
| `oaspec/mock.gleam` | In-memory `transport.Send` for tests |
| `oaspec/openapi/diagnostic.gleam` | Diagnostic value types |
| `oaspec/internal/capability.gleam` | Feature support registry |
| `oaspec/internal/codegen/**` | IR build, render, and emit (all 18 modules) |
| `oaspec/internal/util/**` | Naming, content-type, HTTP, string helpers |
| `oaspec/internal/openapi/capability_check.gleam` | Capability gating |
| `oaspec/internal/openapi/diagnostic_format.gleam` | Diagnostic rendering |
| `oaspec/internal/openapi/dedup.gleam` | Schema deduplication |
| `oaspec/internal/openapi/hoist.gleam` | Inline schema hoisting |
| `oaspec/internal/openapi/normalize.gleam` | Spec normalization |
| `oaspec/internal/openapi/operations.gleam` | Operation traversal |
| `oaspec/internal/openapi/provenance.gleam` | Provenance tracking |
| `oaspec/internal/openapi/resolver.gleam` | `$ref` resolution |
| `oaspec/internal/openapi/schema.gleam` | Schema AST |
| `oaspec/internal/openapi/spec.gleam` | OpenAPI document AST |

### BEAM-coupled (requires the Erlang target today)

These modules import a BEAM-only package, declare `@external(erlang, ...)`,
or transitively depend on a BEAM-only data type (e.g. yay nodes).

| Module | Reason |
|--------|--------|
| `oaspec.gleam` | escript entry point: `argv`, `glint`, `erlang:halt/1` |
| `oaspec/config.gleam` | Reads spec file via `simplifile`; uses `yay` for YAML |
| `oaspec/codegen/writer.gleam` | Writes generated files via `simplifile` |
| `oaspec/openapi/parser.gleam` | Loads files (`simplifile`), parses YAML (`yay`), JSON FFI (`oaspec_json_ffi`) |
| `oaspec/internal/cli.gleam` | `glint` CLI framework, file IO, FFI for TTY/color |
| `oaspec/internal/formatter.gleam` | Spawns `gleam format` subprocess via FFI |
| `oaspec/internal/progress.gleam` | Monotonic clock via FFI for elapsed-time reporting |
| `oaspec/internal/openapi/external_loader.gleam` | Loads remote `$ref` files via `simplifile` |
| `oaspec/internal/openapi/location_index.gleam` | Walks yamerl AST via `yaml_loc_ffi` |
| `oaspec/internal/openapi/parser_error.gleam` | Carries `yay` node positions |
| `oaspec/internal/openapi/parser_schema.gleam` | Operates on `yay` nodes |
| `oaspec/internal/openapi/value.gleam` | Wraps `yay` value types |
| `oaspec/internal/openapi/resolve.gleam` | Uses `@external(erlang, "gleam_stdlib", "identity")` (could be lifted) |

The four `.erl` files in `src/` (`oaspec_ffi.erl`, `oaspec_json_ffi.erl`,
`yaml_loc_ffi.erl`) are unconditionally Erlang-only.

### Adapters (out of tree)

Transport adapters live as sibling Gleam packages under `adapters/`:

- `adapters/httpc/` — BEAM HTTP adapter wrapping `gleam_httpc`. Imports
  Erlang's `httpc`, BEAM-only.
- A JavaScript `fetch` adapter is tracked in #347.

Adapters depend on `oaspec/transport.gleam` (pure) but the runtime they
bridge to is target-specific. The root `oaspec` package never depends on a
specific HTTP runtime, which is what makes per-target adapters viable.

## Minimum pure surface

The following modules form the largest contiguous pure subgraph of the
codebase. They could, in principle, be compiled with `target = "javascript"`
once the BEAM-coupled inputs they currently consume (parsed `yay` nodes) are
replaced by a target-agnostic equivalent:

- `oaspec/transport.gleam`, `oaspec/mock.gleam`
- `oaspec/openapi/diagnostic.gleam`
- All of `oaspec/internal/codegen/**`
- All of `oaspec/internal/util/**`
- `oaspec/internal/capability.gleam`
- The pure subset of `oaspec/internal/openapi/**` (see table above)
- `oaspec/generate.gleam`, once given an already-loaded spec value

The blocker is that today's spec input arrives as `yay` nodes from
`oaspec/openapi/parser.gleam`, and `yay` is BEAM-only. Decoupling the
analysis core from `yay` (e.g. by introducing a target-neutral spec value
type at the `parser.gleam` boundary) is the largest single piece of work
required before any of the above could actually be cross-compiled.

## BEAM shell coupling points

The shell layer is BEAM-only for concrete, identifiable reasons:

| Coupling | Where | Why BEAM-only |
|----------|-------|---------------|
| Argument loading | `argv` in `oaspec.gleam` | `argv` reads `init:get_plain_arguments/0` (BEAM) |
| CLI framework | `glint` in `cli.gleam`, `oaspec.gleam` | `glint` targets Erlang only |
| File IO | `simplifile` in 4 modules | `simplifile` uses Erlang `file` module |
| YAML parsing | `yay` (transitively `yamerl`) | `yamerl` is an Erlang library |
| Subprocess | `oaspec_ffi:run_executable` | Wraps `erlang:open_port/2` |
| Monotonic clock | `oaspec_ffi:monotonic_ms` | Wraps `erlang:monotonic_time/1` |
| TTY detection | `oaspec_ffi:is_stdout_tty` | Reads BEAM `io_protocol` |
| Process halt | `erlang:halt/1` | Direct BEAM builtin |
| Generated client runtime (`oaspec_httpc`) | `gleam_httpc` | Wraps Erlang's `httpc` |

None of these are accidental: each one solves a problem a CLI tool
genuinely has on the target machine. Lifting them would mean substituting a
JS-side equivalent (Node `fs`, browser `fetch`, `process.argv`, `Date.now`),
not deleting them.

## Future direction

This document only captures today's boundaries. The follow-up work is
tracked under #344 and #347 and is, briefly:

- Replace the `yay`-typed boundary inside the analysis core with a
  target-neutral spec value type, so the pure subgraph above is genuinely
  cross-target. (Largest piece of #344.)
- Add a CI job that compiles the pure core with `target = "javascript"` to
  catch regressions. (Last bullet of #344.)
- Build out a JavaScript transport adapter and the async transport contract
  it requires. (#347.)

Pull requests touching the modules listed under "Pure" in this document
should aim to keep them pure: avoid adding `simplifile`, `yay`, `glint`,
`argv`, or `@external(erlang, ...)` imports there. If new IO is required, it
generally belongs in the shell layer, with the result passed into the core
as a value.
