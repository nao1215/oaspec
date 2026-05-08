# Library API

`oaspec` can be used as a Gleam library, not just a CLI tool. The
generation pipeline is pure (no IO) and split into composable steps.

## Public modules at a glance

| Module | Purpose |
|--------|---------|
| `oaspec/transport` | Runtime contract for generated clients (`Send` / `AsyncSend` types, `with_base_url`, `with_default_headers`, `with_security`) |
| `oaspec/mock` | In-memory transport adapter for tests — no network, no FFI |
| `oaspec/config` | Load config from YAML (`config.load/1` / `config.load_all/1`) or build a `Config` in code (`config.new/6`) |
| `oaspec/generate` | Pure generation pipeline (`generate.generate/2`, `generate.validate_only/2`) — no IO |
| `oaspec/openapi/parser` | Parse YAML/JSON spec text into an `OpenApiSpec(Unresolved)` |
| `oaspec/openapi/diagnostic` | Structured warnings and errors used throughout the pipeline |
| `oaspec/codegen/writer` | Write a `List(GeneratedFile)` to disk under `output.server` / `output.client` |

If you only consume generated clients, you only need `oaspec/transport`
and `oaspec/mock`. Tools that drive generation in-process (CI checks,
custom build steps, doctests) reach for `oaspec/openapi/parser` →
`oaspec/generate` → `oaspec/codegen/writer`.

## Pipeline overview

```text
parse → normalize → resolve → capability check → hoist → dedup → validate → codegen
```

The `oaspec/generate` module wraps this pipeline into two entry points:

- `generate.generate(spec, config)` — run the full pipeline and return generated files
- `generate.validate_only(spec, config)` — run validation without code generation

## Example: generate files from a parsed spec

```gleam
import oaspec/config
import oaspec/generate
import oaspec/openapi/parser

let assert Ok(spec) = parser.parse_file("openapi.yaml")
let cfg = config.new(
  input: "openapi.yaml",
  output_server: "./src/my_api",
  output_client: "./src/my_api_client",
  package: "my_api",
  mode: config.Both,
  validate: False,
)

case generate.generate(spec, cfg) {
  Ok(summary) -> {
    // summary.files: List(GeneratedFile) — path and content for each file
    // summary.warnings: List(Diagnostic) — non-blocking warnings
    // summary.spec_title: String
    Nil
  }
  Error(generate.ValidationErrors(errors:)) -> {
    // errors: List(Diagnostic) — blocking validation errors
    Nil
  }
}
```

## Example: validate without generating

```gleam
case generate.validate_only(spec, cfg) {
  Ok(_summary) -> Nil
  // spec has errors; surface `errors` to the user
  Error(generate.ValidationErrors(errors: _errors)) -> Nil
}
```
