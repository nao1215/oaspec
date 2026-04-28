# oaspec

[![Hex](https://img.shields.io/hexpm/v/oaspec)](https://hex.pm/packages/oaspec)
[![Hex Downloads](https://img.shields.io/hexpm/dt/oaspec)](https://hex.pm/packages/oaspec)
[![CI](https://github.com/nao1215/oaspec/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/ci.yml)

Generate usable Gleam code from OpenAPI 3.x specifications.

`oaspec` is aimed at practical, typed code generation rather than a feature checklist. It handles the OpenAPI cases that tend to break real projects, such as `$ref` resolution, `allOf`, `oneOf` and `anyOf`, `deepObject` query parameters, form bodies, multipart bodies, and multiple security schemes, while failing fast when a spec goes outside the supported subset.

- Generate client and server-side modules from a single spec
- Produce readable Gleam types, encoders, decoders, request types, and response types
- Handle real-world OpenAPI patterns: unions, nullable fields, `additionalProperties`, form bodies, multipart, and security
- Backed by 763 unit tests, ShellSpec CLI tests, 40 integration compile tests, and 235 test fixtures (including 94 OSS-derived edge-case specs)

## Why oaspec?

**oaspec is the OpenAPI code generator built for Gleam.** Generated code
is regular Gleam: no templates, no runtime magic, type-safe end to end.

|                                                           | `oaspec` | Generic multi-language generators (e.g. openapi-generator) | Single-language generators for other targets (e.g. oapi-codegen for Go) |
|-----------------------------------------------------------|:--------:|:----------------------------------------------------------:|:----------------------------------------------------------------------:|
| First-class Gleam output                                  |    Yes   |                             No                             |                                   No                                   |
| Idiomatic types, decoders, encoders, and request/response records |    Yes   |                 Templated, not always idiomatic            |                           Language-specific                           |
| Refuses to emit broken code on unsupported spec patterns  |    Yes   |                          Sometimes                         |                                Partial                                 |

- Built for Gleam: the generated code is shaped like normal Gleam modules, not generic templates awkwardly translated from another ecosystem.
- Focused on practical OpenAPI: coverage is strongest around the features teams actually ship with, not just toy Petstore specs.
- Strict by default: unsupported features are reported explicitly instead of being silently dropped into broken output.

## What you get

Given one OpenAPI spec, `oaspec` generates modules you can keep in your repository:

```text
gen/my_api/
  types.gleam
  decode.gleam
  encode.gleam
  request_types.gleam
  response_types.gleam
  guards.gleam          (only if schemas have validation constraints)
  handlers.gleam        (user-owned: written once with panic stubs, skipped on regeneration)
  handlers_generated.gleam (sealed delegator; router imports this)
  router.gleam

gen_client/my_api/
  types.gleam
  decode.gleam
  encode.gleam
  request_types.gleam
  response_types.gleam
  guards.gleam          (only if schemas have validation constraints)
  client.gleam
```

Example generated code:

```gleam
/// A pet in the store
pub type Pet {
  Pet(
    id: Int,
    name: String,
    status: PetStatus,
    tag: Option(String),
  )
}

pub type PetStatus {
  PetStatusAvailable
  PetStatusPending
  PetStatusSold
}

pub fn create_pet(config: ClientConfig, body: types.CreatePetRequest)
  -> Result(response_types.CreatePetResponse, ClientError) {
  // ...
}

pub fn list_pets(req: request_types.ListPetsRequest)
  -> response_types.ListPetsResponse {
  let _ = req
  panic as "unimplemented: list_pets"
}
```

## Is oaspec right for your spec?

A one-minute check before you paste in your OpenAPI document — if your
spec stays inside the green list below, `oaspec` will generate code; if
it relies on anything in the red list, generation stops with a clear
diagnostic instead of producing broken output.

**Generates code for:**

- Schemas: `object`, primitives, arrays, enums, nullable, `allOf`,
  `oneOf`, `anyOf`, typed `additionalProperties`
- Local `$ref` (and relative-file external `$ref`) across schemas,
  parameters, request bodies, responses, and path items. External ref
  graphs must be acyclic — cycles such as `A.yaml → B.yaml → A.yaml`
  fail fast with a dedicated diagnostic that shows the visited chain.
- Parameters: path, query, header, cookie, plus array styles (`form`,
  `pipeDelimited`, `spaceDelimited`) and objects via `deepObject`
- Request bodies: `application/json`,
  `application/x-www-form-urlencoded`, `multipart/form-data`
- Typed response variants, typed response headers, and `$ref` /
  `default` responses
- Security: `apiKey`, HTTP (bearer/basic/digest), OAuth2, OpenID Connect
  (bearer token attachment)

**Stops with a diagnostic for:**

- JSON Schema 2020 keywords: `$defs`, `prefixItems`, `if/then/else`,
  `dependentSchemas`, `not`, `unevaluatedProperties` /
  `unevaluatedItems`, `contentEncoding` / `contentMediaType` /
  `contentSchema`
- XML request/response bodies with structural decoding, `xml`
  annotations, and `mutualTLS` security

**Parsed but not yet turned into code:** callbacks, webhooks,
`externalDocs`, tags, examples, links, `encoding` metadata.

See [Current Boundaries](#current-boundaries) for the full list,
including server-mode restrictions and normalization rules. The
boundaries are kept in sync with the capability registry at
[`src/oaspec/capability.gleam`](src/oaspec/capability.gleam) by a
drift-detection test.

## Quickstart

### Install from GitHub release (Linux / macOS)

Requires Erlang/OTP 27+. The release binary is an Erlang escript that runs on any platform with Erlang installed.

```sh
curl -fSL -o oaspec https://github.com/nao1215/oaspec/releases/latest/download/oaspec
chmod +x oaspec
sudo mv oaspec /usr/local/bin/
```

> On Windows, download `oaspec` from the [latest release](https://github.com/nao1215/oaspec/releases/latest) and run it with `escript oaspec <command>`. Erlang/OTP 27+ must be on your `PATH`.

### Build from source (all platforms)

Requires Gleam 1.15+, Erlang/OTP 27+, and `rebar3`. Works on Linux, macOS, and Windows.

```sh
git clone https://github.com/nao1215/oaspec.git
cd oaspec
gleam deps download
gleam run -m gleescript
```

On Linux/macOS, move the binary into your PATH:

```sh
sudo mv oaspec /usr/local/bin/
```

On Windows, move `oaspec` to a directory on your `PATH` and run it with `escript oaspec <command>`.

### Generate code

1. Create a config file.

```sh
oaspec init
```

2. Edit `oaspec.yaml`.

```yaml
input: openapi.yaml
package: my_api
output:
  dir: ./gen
```

3. Run the generator.

```sh
oaspec generate --config=oaspec.yaml
```

You can also run `gleam run -- generate --config=oaspec.yaml`.

### Runnable examples

Working examples live under [`examples/`](./examples):

- [`examples/petstore_client`](./examples/petstore_client) — minimal client usage against a canned HTTP transport. Run it from the repo root with `just example-petstore`.
- [`examples/server_adapter`](./examples/server_adapter) — wires the generated `router.route/5` to a framework-free adapter. Run it from the repo root with `just example-server-adapter`.

## Configuration

Generated server code is written to `<dir>/<package>` and generated client code is written to `<dir>/<package>_client`. Both default paths land inside the same `<dir>`, so a single `gleam build` rooted at `<dir>` (e.g. when `<dir>` is the project's `src/`) picks up both. The basename of each output directory must match the package name so imports such as `import my_api/types` (server) and `import my_api_client/types` (client) resolve correctly. To split server and client into separate Gleam projects, set `output.server` and/or `output.client` explicitly.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `input` | yes | - | Path to an OpenAPI 3.x spec in YAML or JSON |
| `package` | no | `api` | Gleam module namespace prefix |
| `mode` | no | `both` | `server`, `client`, or `both` |
| `validate` | no | mode-dependent (`true` for `server` / `both`, `false` for `client`) | Enable guard validation in generated server/client code |
| `output.dir` | no | `./gen` | Base output directory |
| `output.server` | no | `<dir>/<package>` | Server output path |
| `output.client` | no | `<dir>/<package>_client` | Client output path |

### Configuration paths

All path-valued fields — `input`, `output.dir`, `output.server`,
`output.client` — are resolved **relative to the current working
directory** when oaspec runs, not the directory the config file lives
in.

A config at the repo root that refers to a sibling spec works with no
prefix:

```text
myproject/
├── oaspec.yaml   # input: openapi.yaml
└── openapi.yaml
```

```sh
cd myproject
oaspec generate --config=oaspec.yaml   # resolves ./openapi.yaml
```

If the config lives in a subdirectory, its `input` must be reachable
from where the command is run, so either use a path relative to that
CWD or keep invoking oaspec from the config's own directory:

```text
myproject/
├── api/
│   ├── oaspec.yaml    # input: openapi.yaml
│   └── openapi.yaml
└── (other code)
```

```sh
cd myproject/api
oaspec generate --config=oaspec.yaml   # resolves ./openapi.yaml

# or, from the repo root:
oaspec generate --config=api/oaspec.yaml   # needs input: api/openapi.yaml
```

Output directories (`output.dir`, `output.server`, `output.client`)
are created automatically if they do not exist; existing files in the
target directories are overwritten by the newly generated code.

If the input spec or the config file itself cannot be opened, oaspec
exits with a `Config file not found` / `parse_file` diagnostic that
includes the path it attempted to read.

### CLI commands

| Command | Description |
|---------|-------------|
| `oaspec generate` | Generate Gleam code from an OpenAPI specification |
| `oaspec validate` | Validate an OpenAPI specification without generating code |
| `oaspec init` | Create a default `oaspec.yaml` config file |

### CLI options for `generate`

| Flag | Default | Description |
|------|---------|-------------|
| `--config=<path>` | `./oaspec.yaml` | Path to config file |
| `--mode=<mode>` | `both` | `server`, `client`, or `both` (overrides config) |
| `--output=<path>` | - | Override output base directory |
| `--check` | `false` | Check that generated code matches existing files without writing |
| `--fail-on-warnings` | `false` | Treat warnings as errors |
| `--validate` | `false` | Enable guard validation in generated server/client code |

### CLI options for `validate`

| Flag | Default | Description |
|------|---------|-------------|
| `--config=<path>` | `./oaspec.yaml` | Path to config file |
| `--mode=<mode>` | `both` | `server`, `client`, or `both` (overrides config) |

### Validate

Check a spec for unsupported patterns without generating code:

```sh
oaspec validate --config=oaspec.yaml
```

### Guard validation

By default, generated code does not validate request bodies at runtime. Enable `validate` in the config file or pass `--validate` to `generate` to add schema-constraint checks:

```yaml
validate: true
```

```sh
oaspec generate --config=oaspec.yaml --validate
```

When enabled, generated routers validate request bodies against schema constraints and return 422 on failure. Generated clients validate request bodies before sending.

The 422 response body is a JSON array of `ValidationFailure` objects with the violating field, the JSON Schema keyword that failed, and a human-readable message:

```json
[
  {"field": "name", "code": "minLength", "message": "must be at least 1 character"},
  {"field": "age", "code": "maximum", "message": "must be at most 150"}
]
```

Generated clients surface the same failures via `ClientError.ValidationError(errors: List(guards.ValidationFailure))`.

### CI integration

Use `--check` and `--fail-on-warnings` to verify generated code stays in sync:

```sh
# Fail if generated code would differ from what's committed
oaspec generate --config=oaspec.yaml --check --fail-on-warnings
```

## Best For

- Generating typed Gleam clients from an OpenAPI contract
- Keeping request and response types in sync with an external API spec
- Bootstrapping server-side types, handlers, and router support from the same source spec
- Catching unsupported spec features early in CI instead of after code generation

## OpenAPI Support

`oaspec` supports OpenAPI 3.0.x and a practical subset of OpenAPI 3.1.x in YAML or JSON. For compatibility, the parser also accepts the two-segment forms `3.0` / `3.1`, including YAML numeric values such as `openapi: 3.0` that arrive as the float `3.0`. Any other `openapi` value — for example `2.0`, `4.0.0`, a bare `3`, or a malformed `3.0.foo` — is rejected with an `invalid_value` diagnostic so unsupported versions fail fast instead of producing plausible-looking but meaningless output.

### operationId uniqueness

Every operation must carry a unique `operationId`. oaspec validates this as a hard error with the offending `METHOD /path` sites listed, because silently renaming the second occurrence (as some generators do) would mutate the generated function/type names without telling the user. The check also catches IDs that only differ in casing — `listItems` and `list_items` both collapse to the same generated `list_items` function, so the spec is rejected.

Coverage is strongest in these areas:

- Schemas: component schemas, primitive aliases, enums, nullable fields, arrays, objects, `allOf`, `oneOf`, `anyOf`, and typed `additionalProperties`
- References: local `$ref` resolution for schemas, parameters, request bodies, responses, and path items, including circular-reference detection
- Parameters: path, query, header, and cookie parameters, including array serialization (`style: form`, `style: pipeDelimited`, `style: spaceDelimited`) and objects via `style: deepObject`
- Request bodies: `application/json`, `application/x-www-form-urlencoded`, and `multipart/form-data`
- Responses: typed status-code variants, `$ref` responses, `default` responses, typed response headers, and text or binary passthrough cases
- Security: `apiKey` (header, query, cookie), HTTP auth (bearer, basic, digest), OAuth2, and OpenID Connect. For OAuth2 and OpenID Connect, the generated client attaches a bearer token to requests; token acquisition, refresh, and flow execution are outside the generated code.
- Generation safety: name collision handling, keyword escaping, validation guards, and capability errors with clear failure modes

<!-- BEGIN GENERATED:BOUNDARIES -->
## Current Boundaries

These boundaries are generated from the capability registry in `src/oaspec/capability.gleam`.

These are the most important limitations today:

- The following keywords are detected and rejected: `$defs`, `prefixItems`, `if/then/else`, `dependentSchemas`, `not`, `unevaluatedProperties`, `unevaluatedItems`, `contentEncoding`, `contentMediaType`, `contentSchema`, `mutualTLS`, `$id`, `const (non-string)`, `type: [T1, T2] with type-specific constraints`
- OpenAPI 3.1 `$id`-backed URL refs (e.g. `$ref: https://example.com/Box` paired with `$id: https://example.com/Box` inside `components.schemas`) are an explicit boundary: the parser accepts them, but validation rejects them with a dedicated URL-ref diagnostic. Rewrite to local `#/components/schemas/...` refs.
- `const` is only supported on string schemas (lowered to a single-value enum). Non-string `const` (bool, int, number, object, array, null) and multi-type schemas that carry type-specific constraints (`pattern`, `minLength`, `minimum`, etc.) are rejected explicitly during `generate` / `validate` so semantic loss never slips into generated code.
- `xml` annotations are not handled by the parser
- Some fields are parsed and preserved but not yet used by codegen: callbacks, webhooks, externalDocs, tags, examples, links, encoding
- Operation-level and path-level server overrides are supported in generated clients (precedence: operation > path > top-level)
- Server-mode code generation rejects the following spec configurations (supported in client mode): `server: complex path parameters`, `server: non-primitive query array items`, `server: non-primitive header array items`, `server: complex deepObject properties`, `server: mixed form-urlencoded request`, `server: complex form-urlencoded fields`, `server: mixed multipart request`, `server: complex multipart fields`, `server: unsupported request content type`
- The following are normalized to supported equivalents:
- `const`: String const normalized to single-value enum
- `type: [T, null]`: Normalized to nullable
- `type: [T1, T2]`: Normalized to oneOf
<!-- END GENERATED:BOUNDARIES -->

## Mode-Specific Support

`oaspec` generates different files depending on the `--mode` flag. Some features have mode-specific restrictions enforced at validation time.

### Generated files

| File | server | client |
|------|--------|--------|
| `types.gleam` | yes | yes |
| `decode.gleam` | yes | yes |
| `encode.gleam` | yes | yes |
| `request_types.gleam` | yes | yes |
| `response_types.gleam` | yes | yes |
| `guards.gleam` | yes | yes |
| `handlers.gleam` | yes (once) | - |
| `handlers_generated.gleam` | yes | - |
| `router.gleam` | yes | - |
| `client.gleam` | - | yes |

`handlers.gleam` is **user-owned**: the generator writes panic stubs on the first run and skips the file on every subsequent run, so your implementations survive regeneration. `handlers_generated.gleam` is the sealed delegator the router imports — each operation forwards to `handlers.<op_name>(req)`, so router/handler wiring stays in sync with the spec without ever touching your code.

### Feature restrictions by mode

| Feature | server | client | Notes |
|---------|--------|--------|-------|
| JSON request/response bodies | yes | yes | |
| Path / query / header / cookie parameters | yes | yes | |
| `style: deepObject` parameters | restricted | yes | Server: only primitive scalars and primitive arrays |
| Array query parameters | restricted | yes | Server: only inline primitive item schemas |
| `style: pipeDelimited` / `style: spaceDelimited` query arrays | yes | yes | Query array parameters only; primitive item types. Non-exploded joins with `\|` / `%20`, exploded degenerates to form-style `name=a&name=b`. |
| `application/x-www-form-urlencoded` | restricted | yes | Server: must be sole content type; only primitive fields and shallow nested objects |
| `multipart/form-data` | restricted | yes | Server: must be sole content type; only primitive scalar fields |
| Security (apiKey, HTTP, OAuth2, OpenID Connect) | yes | yes | Client attaches credentials via config; OAuth2/OpenID Connect: bearer token only |

## Library API

`oaspec` can be used as a Gleam library, not just a CLI tool. The generation pipeline is pure (no IO) and split into composable steps.

### Pipeline overview

```text
parse → normalize → resolve → capability check → hoist → dedup → validate → codegen
```

The `oaspec/generate` module wraps this pipeline into two entry points:

- `generate.generate(spec, config)` — run the full pipeline and return generated files
- `generate.validate_only(spec, config)` — run validation without code generation

### Example: generate files from a parsed spec

```gleam
import oaspec/config
import oaspec/generate
import oaspec/openapi/parser

let assert Ok(spec) = parser.parse_file("openapi.yaml")
let cfg = config.new(
  input: "openapi.yaml",
  output_server: "./gen/my_api",
  output_client: "./gen/my_api_client",
  package: "my_api",
  mode: config.Both,
  validate: False,
)

case generate.generate(spec, cfg) {
  Ok(summary) -> {
    // summary.files: List(GeneratedFile) — path and content for each file
    // summary.warnings: List(Diagnostic) — non-blocking warnings
    // summary.spec_title: String
  }
  Error(generate.ValidationErrors(errors:)) -> {
    // errors: List(Diagnostic) — blocking validation errors
  }
}
```

### Example: validate without generating

```gleam
case generate.validate_only(spec, cfg) {
  Ok(summary) -> // spec is valid; summary.warnings may be non-empty
  Error(generate.ValidationErrors(errors:)) -> // spec has errors
}
```

### Key modules

| Module | Purpose |
|--------|---------|
| `oaspec/openapi/parser` | Parse YAML/JSON spec into `OpenApiSpec(Unresolved)` |
| `oaspec/config` | Load config from YAML or construct programmatically |
| `oaspec/generate` | Pure generation pipeline (parse → codegen) |
| `oaspec/codegen/writer` | Write generated files to disk |
| `oaspec/openapi/diagnostic` | Structured warnings and errors |

## Development

This project uses [mise](https://mise.jdx.dev/) for tool versions and [just](https://just.systems/) as a task runner.

```sh
mise install
just check
just shellspec
just integration
```

Test structure:

| Command | Tool | What it tests |
|---------|------|---------------|
| `just test` | gleeunit | Parser, validator, naming, config, collision detection |
| `just shellspec` | ShellSpec | CLI behaviour, file generation, content, unsupported feature detection |
| `just integration` | gleeunit | Generated code compiles and the generated modules work together |

## License

[MIT](LICENSE)
