# gleam-oas

[![CI](https://github.com/nao1215/gleam-oas/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/gleam-oas/actions/workflows/ci.yml)
[![Integration Tests](https://github.com/nao1215/gleam-oas/actions/workflows/integration.yml/badge.svg)](https://github.com/nao1215/gleam-oas/actions/workflows/integration.yml)

![gleam_oas_logo](https://raw.githubusercontent.com/nao1215/gleam-oas/main/doc/img/gleam-oas-small-logo.png)

> [!IMPORTANT]
> Not fully supporting the entire OpenAPI 3.x specification, gleam-oas can only perform limited code generation at this stage. Support will be expanded incrementally.

Generate strongly typed Gleam code from OpenAPI 3.x specifications.

- Custom types for every component schema (no generic maps)
- JSON decoders and encoders
- Server handler stubs with TODO placeholders
- Client SDK with query parameter serialization
- Composable middleware system (logging, retry)
- OpenAPI descriptions propagated as doc comments

## Install

### From GitHub Release (recommended)

Download the `gleam_oas` escript binary from the [Releases](https://github.com/nao1215/gleam-oas/releases) page. Requires Erlang/OTP 27+ runtime.

```sh
# Download (replace URL with the latest release)
curl -fSL -o gleam_oas https://github.com/nao1215/gleam-oas/releases/download/v0.1.0/gleam_oas
chmod +x gleam_oas
sudo mv gleam_oas /usr/local/bin/
```

### From source

Requires Gleam 1.15+, Erlang/OTP 27+, and rebar3.

```sh
git clone https://github.com/nao1215/gleam-oas.git
cd gleam-oas
gleam deps download
gleam run -m gleescript    # produces ./gleam_oas escript binary
sudo mv gleam_oas /usr/local/bin/
```

## Usage

### 1. Create a config file

```sh
gleam_oas init
```

This creates `gleam-oas.yaml` with a commented template. Edit it for your project:

```yaml
input: openapi.yaml
package: my_api
output:
  dir: ./gen          # base directory (default: ./gen)
```

Generated code is placed at `<dir>/<package>` and `<dir>/<package>_client`. To use the generated code in your Gleam project, copy or symlink the output into `src/`.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `input` | yes | - | Path to OpenAPI 3.x spec (YAML or JSON) |
| `package` | no | `api` | Gleam module namespace prefix |
| `mode` | no | `both` | Generation mode: `server`, `client`, or `both` |
| `output.dir` | no | `./gen` | Base output directory |
| `output.server` | no | `<dir>/<package>` | Server code output (overrides dir-based default) |
| `output.client` | no | `<dir>/<package>_client` | Client code output (overrides dir-based default) |

The directory basename must match `package` so that Gleam imports (`import my_api/types`) resolve correctly. The CLI `--output` flag works the same as `output.dir` in the config file.

### 2. Run the generator

```sh
gleam_oas generate --config=gleam-oas.yaml
```

Options:

```
--config=<path>   Path to config file (default: ./gleam-oas.yaml)
--mode=<mode>     server, client, or both (default: both)
--output=<path>   Override output base directory
```

When developing gleam-oas itself, you can also run via `gleam run -- generate --config=gleam-oas.yaml`.

### 3. Generated output

```
gen/my_api/                 # server (package = "my_api")
  types.gleam               # Domain model types
  request_types.gleam       # Request parameter types
  response_types.gleam      # Response types (tagged unions by status code)
  decode.gleam              # JSON decoders
  encode.gleam              # JSON encoders
  middleware.gleam           # Middleware types and utilities
  handlers.gleam            # Handler stubs (TODO placeholders)
  router.gleam              # Route dispatcher skeleton

gen/my_api_client/          # client
  types.gleam               # Same domain types
  decode.gleam              # Same decoders
  encode.gleam              # Same encoders
  middleware.gleam           # Same middleware (with retry)
  client.gleam              # HTTP client functions
  request_types.gleam
  response_types.gleam
```

## Generated code examples

Given a Petstore OpenAPI spec, gleam-oas generates:

### Types

```gleam
/// A pet in the store
pub type Pet {
  Pet(
    id: Int,
    name: String,
    status: PetStatus,
    tag: Option(String)
  )
}

/// The status of a pet in the store
pub type PetStatus {
  PetStatusAvailable
  PetStatusPending
  PetStatusSold
}
```

### Server handlers

```gleam
/// List all pets
pub fn list_pets(req: request_types.ListPetsRequest) -> response_types.ListPetsResponse {
  let _ = req
  // TODO: Implement list_pets
  todo
}
```

### Client SDK

```gleam
pub fn get_pet(config: ClientConfig, pet_id: Int) -> Result(ClientResponse, ClientError) {
  let path = "/pets/{petId}"
  let path = string.replace(path, "{petId}", int.to_string(pet_id))
  let assert Ok(req) = request.to(config.base_url <> path)
  let req = request.set_method(req, http.Get)
  config.send(req)
}
```

### Middleware

```gleam
pub type Handler(req, res) =
  fn(req) -> Result(res, MiddlewareError)

pub type Middleware(req, res) =
  fn(Handler(req, res)) -> Handler(req, res)

pub fn compose(first: Middleware(req, res), second: Middleware(req, res)) -> Middleware(req, res)
pub fn apply(middlewares: List(Middleware(req, res)), handler: Handler(req, res)) -> Handler(req, res)
pub fn retry(max_retries: Int) -> Middleware(req, res)
```

## OpenAPI support

### Supported

- OpenAPI 3.x (YAML and JSON input)
- Paths and operations (GET, POST, PUT, DELETE, PATCH)
- Path, query, header, and cookie parameters (path-level merged into operations, serialized in client)
- Request bodies with `$ref` schema resolution (typed, not raw String)
- Inline allOf in request body (property merging from `$ref` + inline objects)
- Responses with status codes, including `$ref` responses from `components.responses`
- `$ref` parameters, requestBodies, and responses resolved from `components`
- Component schemas with `$ref` resolution (types, decoders, encoders)
- String enums with unknown-value rejection (decode returns Error, not silent fallback)
- Inline enums in properties (auto-named types generated)
- Inline objects in response/requestBody (anonymous types auto-generated)
- oneOf/anyOf with `$ref` variants (sum types generated)
- Nullable fields, arrays (including array of `$ref`)
- allOf (property merging from inline and `$ref` schemas, including required fields)
- Encode/decode roundtrip safety: `decode(encode(value)) == Ok(value)`
- Circular `$ref` detection (returns error instead of infinite recursion)
- Fail-fast parser: missing required fields and unknown parameter locations return Error

### Explicitly unsupported (generator exits with error)

These patterns are detected before code generation. The generator prints a clear error message and exits non-zero instead of generating broken code.

- **`style: deepObject`** query parameters
- **`multipart/form-data`** request bodies
- **`additionalProperties: true`** (untyped map)
- **Inline oneOf/anyOf with primitive types** (`String | Int | Bool`)

### Not yet supported

- **Client response decoding**: Client returns raw `ClientResponse`, not typed response variants
- **Client request body encoding**: Client accepts `body: String`, not typed body parameter
- **oneOf / anyOf decoders/encoders**: Types generated for `$ref` variants, but no decoder/encoder
- **Discriminator in decoders**: Parsed but not used in generated decoder logic
- **Validation constraints** (minLength, maxLength, pattern, minimum, maximum): Parsed but not enforced
- **Callbacks**: Parsed but ignored
- **Security schemes**: Parsed but not applied to generated client

### Schema-to-type mapping

| OpenAPI type | Gleam type |
|-------------|-----------|
| `string` | `String` |
| `integer` | `Int` |
| `number` | `Float` |
| `boolean` | `Bool` |
| `array` | `List(T)` |
| `object` | Custom type |
| `enum` | Custom type with variants |
| nullable | `Option(T)` |

## Development

This project uses [mise](https://mise.jdx.dev/) for tool versions and [just](https://just.systems/) as a task runner.

```sh
mise install          # install Gleam, Erlang, rebar3
just check            # format check, typecheck, build, unit tests
just shellspec        # CLI integration tests (ShellSpec)
just integration      # generated code compile + roundtrip tests
```

### Test structure

| Command | Tool | What it tests |
|---------|------|---------------|
| `just test` | gleeunit | Unit tests (parser, naming, config) |
| `just shellspec` | ShellSpec | CLI behaviour, file generation, content verification |
| `just integration` | gleeunit | Generated code compiles, types/decoders/encoders/handlers/middleware work |

## License

[MIT](LICENSE)
