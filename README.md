# oaspec

[![CI](https://github.com/nao1215/oaspec/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/ci.yml)
[![Integration Tests](https://github.com/nao1215/oaspec/actions/workflows/integration.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/integration.yml)

> [!IMPORTANT]
> Not fully supporting the entire OpenAPI 3.x specification, oaspec can only perform limited code generation at this stage. Support will be expanded incrementally.

Generate strongly typed Gleam code from OpenAPI 3.x specifications.

- Custom types for every component schema (no generic maps)
- JSON decoders and encoders (including allOf, oneOf/anyOf with discriminator)
- Server handler stubs with TODO placeholders
- Typed client SDK with parameter serialization and response decoding
- Composable middleware system (logging, retry)
- Security scheme support (apiKey, Bearer token)
- OpenAPI descriptions propagated as doc comments

## Install

### From GitHub Release (recommended)

Download the `oaspec` escript binary from the [Releases](https://github.com/nao1215/oaspec/releases) page. Requires Erlang/OTP 27+ runtime.

```sh
# Download (replace URL with the latest release)
curl -fSL -o oaspec https://github.com/nao1215/oaspec/releases/latest/download/oaspec
chmod +x oaspec
sudo mv oaspec /usr/local/bin/
```

### From source

Requires Gleam 1.15+, Erlang/OTP 27+, and rebar3.

```sh
git clone https://github.com/nao1215/oaspec.git
cd oaspec
gleam deps download
gleam run -m gleescript    # produces ./oaspec escript binary
sudo mv oaspec /usr/local/bin/
```

## Usage

### 1. Create a config file

```sh
oaspec init
```

This creates `oaspec.yaml` with a commented template. Edit it for your project:

```yaml
input: openapi.yaml
package: my_api
output:
  dir: ./gen          # base directory (default: ./gen)
```

Generated code is placed at `<dir>/<package>` (server) and `<dir>_client/<package>` (client). Both directory basenames must match `package` so that Gleam imports resolve correctly. To use the generated code in your Gleam project, copy or symlink the output into `src/`.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `input` | yes | - | Path to OpenAPI 3.x spec (YAML or JSON) |
| `package` | no | `api` | Gleam module namespace prefix |
| `mode` | no | `both` | Generation mode: `server`, `client`, or `both` |
| `output.dir` | no | `./gen` | Base output directory |
| `output.server` | no | `<dir>/<package>` | Server code output (overrides dir-based default) |
| `output.client` | no | `<dir>_client/<package>` | Client code output (overrides dir-based default) |

The directory basename **must** match `package` so that Gleam imports (`import my_api/types`) resolve correctly. The CLI `--output` flag works the same as `output.dir` in the config file. A basename mismatch is an early error.

### 2. Run the generator

```sh
oaspec generate --config=oaspec.yaml
```

Options:

```
--config=<path>   Path to config file (default: ./oaspec.yaml)
--mode=<mode>     server, client, or both (default: both)
--output=<path>   Override output base directory
```

When developing oaspec itself, you can also run via `gleam run -- generate --config=oaspec.yaml`.

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

gen_client/my_api/          # client
  types.gleam               # Same domain types
  decode.gleam              # Same decoders
  encode.gleam              # Same encoders
  middleware.gleam           # Same middleware (with retry)
  client.gleam              # Typed HTTP client functions
  request_types.gleam
  response_types.gleam
```

## Generated code examples

Given a Petstore OpenAPI spec, oaspec generates:

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
pub fn create_pet(config: ClientConfig, body: types.CreatePetRequest)
  -> Result(response_types.CreatePetResponse, ClientError) {
  // ... typed body encoding, typed response decoding
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
- Path, query, header, and cookie parameters (path-level merged by `(name, in)` key)
- Parameter serialization: `Bool`, `Float`, `Int`, `String`, `$ref` enum types
- Cookie parameters combined into single header (`"a=1; b=2"`)
- Request bodies with `$ref` schema resolution (typed, auto-encoded)
- Inline allOf in request body (property merging from `$ref` + inline objects)
- Responses with status codes, including `$ref` responses from `components.responses`
- `$ref` parameters, requestBodies, and responses resolved from `components`
- Component schemas with `$ref` resolution (types, decoders, encoders)
- String enums with unknown-value rejection (decode returns Error, not silent fallback)
- Inline enums in properties (auto-named types generated)
- Inline objects in top-level response/requestBody (anonymous types auto-generated; nested inline objects in properties are unsupported)
- oneOf/anyOf with `$ref` variants (sum types, decoders, encoders generated)
- oneOf discriminator-based decoding (dispatches by discriminator field value)
- anyOf try-each decoding (tries each variant decoder in order)
- allOf (property merging, decoders, encoders)
- Nullable fields, arrays (including array of `$ref`)
- Encode/decode roundtrip safety: `decode(encode(value)) == Ok(value)`
- Circular `$ref` detection (returns error instead of infinite recursion)
- Fail-fast parser: missing required fields (`responses`, `items` for arrays, `openapi`, `info`), unknown parameter locations (`in: body`), and malformed content all return Error immediately
- Client typed body: accepts typed body parameters, auto-encodes via generated encoders
- Client typed response: returns typed response variants, auto-decodes via generated decoders
- Security schemes: `apiKey` in `header` or `query`, HTTP `bearer` token — applied to generated client functions (other `apiKey.in` values rejected at parse time)
- Duplicate operationId detection (validation error)
- Function name collision detection after snake_case conversion
- Type name collision detection after PascalCase conversion
- Config validation: output directory basename must match package name

### Explicitly unsupported (generator exits with error)

These patterns are detected before code generation. The generator prints a clear error message and exits non-zero instead of generating broken code.

- **`style: deepObject`** query parameters
- **`multipart/form-data`** request bodies (only `application/json` supported)
- **`additionalProperties: true`** (untyped map — Gleam has no untyped map type)
- **Typed `additionalProperties`** (e.g., `additionalProperties: { type: string }`)
- **Inline oneOf/anyOf schemas** (all variants must be `$ref` to named schemas)
- **Nested inline object/allOf in properties** (extract to `components.schemas` and use `$ref`)
- **Duplicate operationId** across paths
- **Function/type name collisions** after case conversion

### Not yet supported

- **Validation constraints** (minLength, maxLength, pattern, minimum, maximum): Parsed but not enforced
- **Callbacks**: Ignored by the generator (no AST representation)
- **OAuth2 / OpenID Connect security schemes**: Rejected at parse time
- **`apiKey` in `cookie`**: Rejected at parse time
- **HTTP Basic / Digest authentication**: Only `bearer` is supported for `type: http`; others rejected at parse time
- **allOf with non-object sub-schemas**: Only object sub-schemas are merged

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
| `allOf` | Merged custom type |
| `oneOf`/`anyOf` (`$ref` variants) | Sum type with variant constructors |

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
| `just test` | gleeunit | Unit tests (parser fail-fast, validator recursion, naming, config validation, collision detection) |
| `just shellspec` | ShellSpec | CLI behaviour, file generation, content verification, unsupported feature detection |
| `just integration` | gleeunit | Generated code compiles, types/decoders/encoders/handlers/middleware work |

## License

[MIT](LICENSE)
