# oaspec

[![CI](https://github.com/nao1215/oaspec/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/ci.yml)
[![Integration Tests](https://github.com/nao1215/oaspec/actions/workflows/integration.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/integration.yml)

Generate Gleam code from OpenAPI 3.x specifications with strict codegen for a large practical subset.

- Custom types for component schemas
- JSON decoders and encoders (allOf, oneOf/anyOf with discriminator)
- Server handler stubs with callback support
- Client SDK with parameter serialization and response decoding
- Middleware (logging, retry, validation)
- Security scheme support (`apiKey`, HTTP all schemes, OAuth2, OpenID Connect)
- Parameter support (deepObject, array, complex schema parameters)
- Content type support (JSON, form-urlencoded, multipart, XML, octet-stream, text/plain)
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

- OpenAPI 3.0.x and 3.1 (YAML and JSON; 3.1 `type` arrays and `null` supported, other 3.1-only features are best-effort)
- Paths and operations (GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, TRACE)
- Path, query, header, cookie parameters (path-level merged by `(name, in)`)
- Parameter serialization for Bool, Float, Int, String, `$ref` enum types
- `style: deepObject` query parameters with `key[prop]=value` serialization
- Array parameters in query/header/cookie with explode-aware serialization (`explode: true` → repeated `key=a&key=b`; `explode: false` → comma-separated `key=a,b`)
- Complex schema parameters (object/allOf/oneOf/anyOf) via automatic hoisting
- Percent-encoding for path/query/cookie parameter values via `uri.percent_encode`
- Cookie parameters combined into single header
- `application/json` request bodies with `$ref` resolution (typed, auto-encoded)
- `application/x-www-form-urlencoded` request bodies with recursive bracket encoding for nested objects (`field[sub][key]=value`)
- `multipart/form-data` request bodies with boundary-based encoding for string/integer/number/boolean/binary/string-enum fields (optional fields handled)
- allOf in request body (property merging from `$ref` + inline objects)
- Responses with status codes, `$ref` responses from `components.responses`
- `$ref` resolution for parameters, requestBodies, responses, schemas
- Component schemas: types, decoders, encoders
- Primitive component schemas (string, integer, number, boolean): type alias, decoder, encoder
- String enums with unknown-value rejection
- Inline enums in properties (auto-named)
- Inline objects in top-level response/requestBody (anonymous types generated)
- Inline oneOf/anyOf schemas: automatically hoisted to `components.schemas` with generated names
- Nested inline object/allOf in properties: automatically hoisted
- Inline complex array items: automatically hoisted
- oneOf/anyOf with `$ref` variants: sum types, decoders, encoders
- oneOf discriminator-based decoding
- anyOf try-each decoding
- allOf property merging with decoders/encoders (non-object sub-schemas included as synthetic fields)
- Nullable fields, arrays (including `$ref` items)
- Encode/decode roundtrip: `decode(encode(value)) == Ok(value)`
- Circular `$ref` detection
- Fail-fast parser for missing required fields, invalid parameter locations, malformed content
- Client typed body (auto-encoded) and typed response (auto-decoded) for single content-type operations; multi-content-type operations use `String` body with explicit `content_type` parameter
- `default` response handling in client
- Top-level security inheritance (operation-level overrides, `security: []` opts out, OR alternatives all applied)
- Security schemes: `apiKey` in header/query/cookie, HTTP all schemes (bearer/basic/digest/hoba/negotiate/mutual/etc.), OAuth2, OpenID Connect
- `text/plain` response content type: body returned as `String` directly
- `application/xml`, `text/xml` response content types: body returned as `String`
- `application/octet-stream` response content type: body returned as `String`
- Typed `additionalProperties`: `Dict(String, T)` with dict decoder/encoder (known keys excluded)
- Untyped `additionalProperties: true`: `Dict(String, Dynamic)` (decode-only, known keys excluded)
- `additionalProperties` with inline complex schemas (hoisted automatically)
- Validation constraint guards (minLength, maxLength, minimum, maximum, minItems, maxItems)
- Composite `validate_<type>` functions that auto-call all field validators
- Callbacks: parsed and callback handler stubs generated
- Duplicate operationId detection
- Function/type name collision detection after case conversion
- Property name collision detection after snake_case conversion
- Enum variant collision detection after PascalCase conversion
- Auto-deduplication of duplicate operationIds (appends `_2`, `_3`, etc.)
- Auto-deduplication of property name collisions after snake_case conversion
- Auto-deduplication of enum variant collisions after PascalCase conversion
- Auto-deduplication of function/type name collisions after case conversion
- Config validation: output directory basename must match package name
- Gleam keyword escaping in generated field names
- Optional request body (`requestBody.required: false`) generates `Option(T)` body parameter
- Array alias component schemas (e.g. `type: array, items: ...`) generate decoder/encoder

### Not yet supported

The following OpenAPI 3.x features are not yet implemented. Specs using these features will either produce a parse error or have the feature silently ignored:

- `PathItem.$ref` (path-level `$ref`)
- `Parameter.content` (media-type-based parameter encoding)
- `Parameter.allowReserved`
- `MediaType.encoding` (per-property encoding for multipart/form-data)
- `Response.headers` and `Response.links`
- OAuth2 `flows` / `scopes` detail (schemes are recognized but flow details are not preserved)
- Webhooks (`webhooks` top-level field)
- `components.pathItems`
- OpenAPI 3.1 / JSON Schema 2020-12 advanced features (`$defs`, `prefixItems`, `if/then/else`, `dependentSchemas`, `$dynamicRef`, `contentMediaType`)
- OpenAPI 3.1 multi-type unions (`type: [string, integer]`) — use `oneOf` instead
- Server variable generation (server stubs are scaffolds only)
- `xml` annotations
- `externalDocs`

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
