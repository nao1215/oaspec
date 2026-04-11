# oaspec

[![Hex](https://img.shields.io/hexpm/v/oaspec)](https://hex.pm/packages/oaspec)
[![CI](https://github.com/nao1215/oaspec/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/ci.yml)

Generate usable Gleam code from OpenAPI 3.x specifications.

`oaspec` is aimed at practical, typed code generation rather than a feature checklist. It handles the OpenAPI cases that tend to break real projects, such as `$ref` resolution, `allOf`, `oneOf` and `anyOf`, `deepObject` query parameters, form bodies, multipart bodies, and multiple security schemes, while failing fast when a spec goes outside the supported subset.

- Generate client and server-side modules from a single spec
- Produce readable Gleam types, encoders, decoders, request types, and response types
- Handle real-world OpenAPI patterns: unions, nullable fields, `additionalProperties`, form bodies, multipart, and security
- Backed by 470 unit tests, ShellSpec CLI tests, 40 integration compile tests, and 178 test fixtures (including 94 OSS-derived edge-case specs)

## Why oaspec

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
  middleware.gleam
  guards.gleam          (only if schemas have validation constraints)
  handlers.gleam
  router.gleam

gen_client/my_api/
  types.gleam
  decode.gleam
  encode.gleam
  request_types.gleam
  response_types.gleam
  middleware.gleam
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

## Quickstart

### Install from GitHub release

Requires Erlang/OTP 27+.

```sh
curl -fSL -o oaspec https://github.com/nao1215/oaspec/releases/latest/download/oaspec
chmod +x oaspec
sudo mv oaspec /usr/local/bin/
```

### Build from source

Requires Gleam 1.15+, Erlang/OTP 27+, and `rebar3`.

```sh
git clone https://github.com/nao1215/oaspec.git
cd oaspec
gleam deps download
gleam run -m gleescript
sudo mv oaspec /usr/local/bin/
```

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

## Configuration

Generated server code is written to `<dir>/<package>`. Generated client code is written to `<dir>_client/<package>`. The basename of each output directory must match `package` so imports such as `import my_api/types` resolve correctly.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `input` | yes | - | Path to an OpenAPI 3.x spec in YAML or JSON |
| `package` | no | `api` | Gleam module namespace prefix |
| `mode` | no | `both` | `server`, `client`, or `both` |
| `output.dir` | no | `./gen` | Base output directory |
| `output.server` | no | `<dir>/<package>` | Server output path |
| `output.client` | no | `<dir>_client/<package>` | Client output path |

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

`oaspec` supports OpenAPI 3.0.x and a practical subset of OpenAPI 3.1 in YAML or JSON.

Coverage is strongest in these areas:

- Schemas: component schemas, primitive aliases, enums, nullable fields, arrays, objects, `allOf`, `oneOf`, `anyOf`, and typed `additionalProperties`
- References: local `$ref` resolution for schemas, parameters, request bodies, responses, and path items, including circular-reference detection
- Parameters: path, query, header, and cookie parameters, including array serialization and `style: deepObject`
- Request bodies: `application/json`, `application/x-www-form-urlencoded`, and `multipart/form-data`
- Responses: typed status-code variants, `$ref` responses, `default` responses, and text or binary passthrough cases
- Security: `apiKey`, HTTP auth schemes, OAuth2, and OpenID Connect
- Generation safety: name collision handling, keyword escaping, validation guards, and capability errors with clear failure modes

<!-- BEGIN GENERATED:BOUNDARIES -->
## Current Boundaries

These boundaries are generated from the capability registry in `src/oaspec/capability.gleam`.

These are the most important limitations today:

- The following keywords are detected and rejected: `$defs`, `prefixItems`, `if/then/else`, `dependentSchemas`, `not`, `unevaluatedProperties`, `unevaluatedItems`, `contentEncoding`, `contentMediaType`, `contentSchema`, `mutualTLS`
- `xml` annotations are not handled by the parser
- Some fields are parsed and preserved but not yet used by codegen: webhooks, externalDocs, tags, examples, links, operation servers, path servers, response headers, encoding
- The following are normalized to supported equivalents:
- `const`: String const normalized to single-value enum
- `type: [T, null]`: Normalized to nullable
- `type: [T1, T2]`: Normalized to oneOf
<!-- END GENERATED:BOUNDARIES -->

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
