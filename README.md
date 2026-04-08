# oaspec

[![CI](https://github.com/nao1215/oaspec/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/ci.yml)
[![Integration Tests](https://github.com/nao1215/oaspec/actions/workflows/integration.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/integration.yml)

> [!IMPORTANT]
> oaspec does not cover the full OpenAPI 3.x specification. Support is expanded incrementally.

Generate Gleam code from OpenAPI 3.x specifications.

- Custom types for component schemas
- JSON decoders and encoders (allOf, oneOf/anyOf with discriminator)
- Server handler stubs
- Client SDK with parameter serialization and response decoding
- Middleware (logging, retry)
- Security scheme support (`apiKey` header/query/cookie, HTTP bearer/basic/digest)
- OpenAPI descriptions as doc comments

## Install

### From GitHub Release

Download the `oaspec` escript binary from the [Releases](https://github.com/nao1215/oaspec/releases) page. Requires Erlang/OTP 27+.

```sh
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

Generated code is placed at `<dir>/<package>` (server) and `<dir>_client/<package>` (client). Both directory basenames must match `package` so that Gleam imports resolve correctly. Copy or symlink the output into `src/` to use it.

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `input` | yes | - | Path to OpenAPI 3.x spec (YAML or JSON) |
| `package` | no | `api` | Gleam module namespace prefix |
| `mode` | no | `both` | `server`, `client`, or `both` |
| `output.dir` | no | `./gen` | Base output directory |
| `output.server` | no | `<dir>/<package>` | Server code output path |
| `output.client` | no | `<dir>_client/<package>` | Client code output path |

The directory basename must match `package` so that `import my_api/types` resolves. The CLI `--output` flag works the same as `output.dir`. A mismatch is an early error.

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

You can also run via `gleam run -- generate --config=oaspec.yaml`.

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
  types.gleam
  decode.gleam
  encode.gleam
  middleware.gleam
  client.gleam              # HTTP client functions
  request_types.gleam
  response_types.gleam
```

## Generated code examples

Given a Petstore OpenAPI spec:

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

pub type PetStatus {
  PetStatusAvailable
  PetStatusPending
  PetStatusSold
}
```

### Server handlers

```gleam
pub fn list_pets(req: request_types.ListPetsRequest) -> response_types.ListPetsResponse {
  let _ = req
  // TODO: Implement list_pets
  todo
}
```

### Client

```gleam
pub fn create_pet(config: ClientConfig, body: types.CreatePetRequest)
  -> Result(response_types.CreatePetResponse, ClientError) {
  // ...
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

- OpenAPI 3.x (YAML and JSON)
- Paths and operations (GET, POST, PUT, DELETE, PATCH)
- Path, query, header, cookie parameters (path-level merged by `(name, in)`)
- Parameter serialization for Bool, Float, Int, String, `$ref` enum types
- Percent-encoding for path/query/cookie parameter values via `uri.percent_encode`
- Cookie parameters combined into single header
- `application/json` request bodies with `$ref` resolution (typed, auto-encoded)
- allOf in request body (property merging from `$ref` + inline objects)
- Responses with status codes, `$ref` responses from `components.responses`
- `$ref` resolution for parameters, requestBodies, responses, schemas
- Component schemas: types, decoders, encoders
- Primitive component schemas (string, integer, number, boolean): type alias, decoder, encoder
- String enums with unknown-value rejection
- Inline enums in properties (auto-named)
- Inline objects in top-level response/requestBody (anonymous types generated)
- oneOf/anyOf with `$ref` variants: sum types, decoders, encoders
- oneOf discriminator-based decoding
- anyOf try-each decoding
- allOf property merging with decoders/encoders
- Nullable fields, arrays (including `$ref` items)
- Encode/decode roundtrip: `decode(encode(value)) == Ok(value)`
- Circular `$ref` detection
- Fail-fast parser for missing required fields, invalid parameter locations, malformed content
- Client typed body (auto-encoded) and typed response (auto-decoded)
- `default` response handling in client
- Top-level security inheritance (operation-level overrides, `security: []` opts out)
- Security schemes: `apiKey` in header/query/cookie, HTTP bearer/basic/digest (first OR alternative applied; AND within one alternative supported)
- `text/plain` response content type: body returned as `String` directly
- Typed `additionalProperties`: `Dict(String, T)` with dict decoder/encoder (known keys excluded)
- Untyped `additionalProperties: true`: `Dict(String, Dynamic)` (decode-only, known keys excluded)
- `multipart/form-data` request bodies with boundary-based encoding for string/integer/number/boolean/binary/string-enum fields (optional fields handled)
- Validation constraint guards (minLength, maxLength, minimum, maximum, minItems, maxItems)
- Duplicate operationId detection
- Function/type name collision detection after case conversion
- Property name collision detection after snake_case conversion
- Enum variant collision detection after PascalCase conversion
- Config validation: output directory basename must match package name
- Gleam keyword escaping in generated field names

### Unsupported (exits with error)

These are detected before code generation. The generator prints an error and exits non-zero.

- `style: deepObject` query parameters
- Inline oneOf/anyOf schemas (variants must be `$ref`)
- Nested inline object/allOf in properties (use `$ref`)
- Array parameters (query/header/cookie with `type: array`)
- Complex schema parameters (object/allOf/oneOf/anyOf in path/query/header/cookie)
- Inline complex array items (object/allOf/oneOf/anyOf; use `$ref`)
- Duplicate operationId
- Function/type name collisions after case conversion
- Property name collisions after snake_case conversion
- Enum variant collisions after PascalCase conversion
- Non-JSON/non-multipart request body content types (only `application/json` and `multipart/form-data`)
- Non-JSON response content types (only `application/json` and `text/plain`)
- Path parameters with `required: false`

### Not yet supported

- Validation constraints enforcement at runtime (guards are generated but not auto-called)
- Callbacks: ignored by the generator
- OAuth2: rejected at validation time
- OpenID Connect: rejected at parse time
- Unsupported HTTP security schemes (e.g. hoba, negotiate): rejected at validation time
- `allOf` merge only supports object sub-schemas (non-object entries are ignored)
- `additionalProperties` with inline complex schemas is not handled explicitly; use primitives or `$ref`

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
| `oneOf`/`anyOf` (`$ref` variants) | Sum type |

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
| `just test` | gleeunit | Parser, validator, naming, config, collision detection |
| `just shellspec` | ShellSpec | CLI behaviour, file generation, content, unsupported feature detection |
| `just integration` | gleeunit | Generated code compiles, types/decoders/encoders/handlers/middleware work |

## License

[MIT](LICENSE)
