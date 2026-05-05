# oaspec

[![Hex package](https://img.shields.io/hexpm/v/oaspec)](https://hex.pm/packages/oaspec)
[![HexDocs](https://img.shields.io/badge/hexdocs-latest-blue)](https://hexdocs.pm/oaspec/)
[![License](https://img.shields.io/github/license/nao1215/oaspec)](https://github.com/nao1215/oaspec/blob/main/LICENSE)
[![CI](https://github.com/nao1215/oaspec/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/oaspec/actions)

Generate Gleam client and server modules from OpenAPI 3.x specs.

OpenAPI in → typed Gleam client and server out, with no per-operation glue
code to write or maintain. The generator owns request and response types,
encoders, decoders, validation guards, and the router; you wire credentials
and a transport adapter, then call typed operation functions:

```gleam
import api/client
import oaspec/httpc
import oaspec/transport

let send =
  httpc.send
  |> transport.with_base_url(client.default_base_url())

let assert Ok(pets) = client.list_pets(send, limit: Some(10), offset: None)
```

`oaspec` focuses on the parts of OpenAPI that affect generated code in real
projects: `$ref`, `allOf`, `oneOf`, `anyOf`, typed request and response
bodies, `deepObject` query parameters, form bodies, multipart bodies, and
security schemes. When a spec falls outside the supported subset, generation
stops with a diagnostic instead of emitting partial code.

- Generate client and server-side modules from a single spec
- Produce readable Gleam types, encoders, decoders, request types, and response
  types
- Keep unsupported spec shapes explicit and testable
- Backed by 366 unit tests, ShellSpec CLI tests, 40 integration compile tests,
  and 267 test fixtures (including 98 OSS-derived edge-case specs)

API reference: <https://hexdocs.pm/oaspec/>

## Install

`oaspec` ships in two flavors:

- Library API (the runtime contract for generated clients, plus the
  generator itself for in-process use) — install via `gleam add` from Hex.
- CLI (the `oaspec` binary that drives `init` / `generate` / `validate`
  on the command line) — install from a GitHub release or build from source.

Most users want both: `gleam add oaspec gleam_json` in the project that
consumes the generated code, and the CLI installed system-wide to run
`oaspec generate`.

### Library (Hex)

```sh
gleam add oaspec gleam_json
```

This pulls the published [hex.pm package](https://hex.pm/packages/oaspec)
and gives you the public modules under `oaspec/transport`, `oaspec/mock`,
`oaspec/config`, `oaspec/generate`, `oaspec/openapi/parser`, and
`oaspec/openapi/diagnostic`. See [Library API](#library-api) below for the
full module list.

`gleam_json` is added in the same step because the generated `decode.gleam`,
`encode.gleam`, `guards.gleam`, and `router.gleam` modules `import gleam/json`
directly. Without `gleam_json` listed as a direct dependency of the consumer
project, `gleam check` prints a "Transitive dependency imported" warning for
each generated file, and a future Gleam release will turn the warning into a
compile error. Adding it up front avoids both.

### CLI — GitHub release

Requires Erlang/OTP 27+. The release artifact is an Erlang escript, so the
same binary runs anywhere Erlang is available.

```sh
curl -fSL -o oaspec https://github.com/nao1215/oaspec/releases/latest/download/oaspec
chmod +x oaspec
sudo mv oaspec /usr/local/bin/
```

On Windows, download `oaspec` from the [latest release](https://github.com/nao1215/oaspec/releases/latest) and run it with `escript oaspec <command>`. Erlang/OTP 27+ must be on your `PATH`.

### CLI — build from source

Requires Gleam 1.15+, Erlang/OTP 27+, and `rebar3`.

```sh
git clone https://github.com/nao1215/oaspec.git
cd oaspec
gleam deps download
gleam run -m gleescript
```

On Linux and macOS, move the built `oaspec` binary into your `PATH` with
`sudo mv oaspec /usr/local/bin/`. On Windows, move `oaspec` to a directory on
your `PATH` and run it with `escript oaspec <command>`.

## Quickstart

If you already have an OpenAPI 3.x spec on disk, skip step 1 and point
`input:` at it. Otherwise, fetch a tiny sample to try the generator
end-to-end:

1. Fetch a sample spec (skip this step if you have your own).

```sh
curl -fSL -o openapi.yaml https://raw.githubusercontent.com/nao1215/oaspec/main/test/fixtures/petstore.yaml
```

2. Generate a starter `oaspec.yaml`.

```sh
oaspec init
```

`oaspec init` writes a fully-commented template — `package: api` is the
only uncommented field, with `input`, `mode`, `validate`, and `output:` all
present as commented examples. Open the file and at minimum uncomment
`input:` and point it at your spec (or set `input: openapi.yaml` if you
followed step 1).

3. Run the generator.

```sh
oaspec generate --config=oaspec.yaml
```

You can also run `gleam run -- generate --config=oaspec.yaml`.

Important: all path-valued config fields (`input`, `output.dir`,
`output.server`, `output.client`) are resolved relative to the current
working directory when `oaspec` runs, not relative to the config file
location. If `oaspec.yaml` lives in a subdirectory, either invoke
`oaspec` from that directory or write paths relative to the directory
you run the command from.

## Generated files

Given one OpenAPI spec, `oaspec` writes modules you can keep in your
repository:

```text
gen/my_api/
  types.gleam
  decode.gleam
  encode.gleam
  request_types.gleam
  response_types.gleam
  guards.gleam
  handlers.gleam
  handlers_generated.gleam
  router.gleam

gen/my_api_client/
  types.gleam
  decode.gleam
  encode.gleam
  request_types.gleam
  response_types.gleam
  guards.gleam
  client.gleam
```

## Supported input

`oaspec` handles the following OpenAPI shapes today:

- Schemas: `object`, primitives, arrays, enums, nullable, `allOf`,
  `oneOf`, `anyOf`, typed `additionalProperties`
- Local `$ref` (and relative-file external `$ref`) across schemas,
  parameters, request bodies, responses, and path items. External ref
  graphs must be acyclic — cycles such as `A.yaml → B.yaml → A.yaml`
  fail fast with a dedicated diagnostic that shows the visited chain.
- Parameters: path, query, header, cookie, plus array styles (`form`,
  `pipeDelimited`, `spaceDelimited`) and objects via `deepObject`
- Request bodies: `application/json`, `text/plain`,
  `application/octet-stream`, `application/x-www-form-urlencoded`,
  `multipart/form-data`
- Typed response variants, typed response headers, and `$ref` /
  `default` responses
- Security: `apiKey`, HTTP (bearer/basic/digest), OAuth2, OpenID Connect
  (bearer token attachment on the client; **parsed but not enforced** on
  the server — see [Server security model](#server-security-model))

Generation stops with a diagnostic for:

- JSON Schema 2020 keywords: `$defs`, `prefixItems`, `if/then/else`,
  `dependentSchemas`, `not`, `unevaluatedProperties` /
  `unevaluatedItems`, `contentEncoding` / `contentMediaType` /
  `contentSchema`
- XML request/response bodies with structural decoding, `xml`
  annotations, and `mutualTLS` security

Parsed but not yet turned into code: callbacks, webhooks, `externalDocs`,
tags, examples, links, and `encoding` metadata.

See [Current Boundaries](#current-boundaries) for the full list, including
server-mode restrictions and normalization rules. That section stays in sync
with the capability registry at
[`src/oaspec/internal/capability.gleam`](src/oaspec/internal/capability.gleam).

### Runnable examples

Working examples live under [`examples/`](./examples):

- [`examples/petstore_client`](./examples/petstore_client) — generated client / decoder roundtrip demo against a stub transport (no network). The example's README shows the one-liner swap to `oaspec_httpc` for real BEAM HTTP. Run it from the repo root with `just example-petstore`.
- [`examples/petstore_client_fetch`](./examples/petstore_client_fetch) — JavaScript-target client usage through the first-party fetch adapter. Run it from the repo root with `just example-petstore-fetch`.
- [`examples/server_adapter`](./examples/server_adapter) — wires the generated `router.route/6` to a framework-free adapter. Run it from the repo root with `just example-server-adapter`.

### Client transport

Generated clients depend on a tiny pure runtime (`oaspec/transport`)
instead of any specific HTTP library. Operations expose both synchronous
`transport.Send` entry points and asynchronous `transport.AsyncSend`
variants, so the same generated code runs against real HTTP, fakes,
or any future runtime:

```gleam
import api/client
import oaspec/httpc          // BEAM adapter (sibling package)
import oaspec/transport

let send =
  httpc.send
  |> transport.with_base_url(client.default_base_url())
  |> transport.with_security(
    transport.credentials()
    |> transport.with_bearer_token("BearerAuth", token),
  )

let result = client.list_pets(send, limit: Some(10), offset: None)
```

On the JavaScript target, use the async variant with the first-party
fetch adapter:

```gleam
import api/client
import oaspec/fetch
import oaspec/transport

let send =
  fetch.send
  |> transport.with_base_url(client.default_base_url())

client.list_pets_async(send, limit: Some(10), offset: None)
|> transport.run(fn(result) {
  let _ = result
  Nil
})
```

Each operation also exposes `build_<op>_request` and
`decode_<op>_response` helpers, plus request-object wrappers for both
sync and async call paths, so callers can drive the request and
response halves independently — useful for retry middleware, logging,
or testing decoding in isolation.

For tests, swap in `oaspec/mock`:

```gleam
import oaspec/mock

let send = mock.text(200, "[{\"id\": 1, \"name\": \"Fido\"}]")
let assert Ok(_) = client.list_pets(send, limit: None, offset: None)
```

The pure runtime supplies middleware for base URL override, default
headers, and OpenAPI security (`with_security` walks the request's
declared OR-of-AND alternatives and applies the first one whose
required schemes have credentials). The same `with_*` middleware works
for both `transport.Send` and `transport.AsyncSend`.

Adapters that bridge `transport.Send` / `transport.AsyncSend` to a real
runtime live as
sibling Gleam packages under [`adapters/`](./adapters), so the root
`oaspec` package never depends on `gleam_httpc` or any specific
HTTP runtime:

- `oaspec_httpc` (`adapters/httpc/`) — BEAM adapter backed by
  `gleam_httpc`.
- `oaspec_fetch` (`adapters/fetch/`) — JavaScript adapter backed by
  `gleam_fetch`, with helpers to bridge `transport.Async` and native
  JavaScript promises.

Both adapters are published to Hex from this repository on tag push:
`oaspec_httpc-v*` for the BEAM adapter and `oaspec_fetch-v*` for the
JavaScript adapter, separately from the main `oaspec` release tag
(`v*`). The publishing workflow swaps each adapter's parent dep
(`oaspec = { path = "../.." }` in-tree, for monorepo development)
to a Hex version constraint just before publishing, so consumers
install with the usual `gleam add` flow:

```sh
gleam add oaspec_httpc   # BEAM
gleam add oaspec_fetch   # JavaScript
```

If `gleam add oaspec_httpc` reports `package not found`, no adapter
release has been cut yet — depend on the adapter via a path
dependency to a local checkout of the oaspec repository until the
first tag push:

```toml
[dependencies]
oaspec = "..."
oaspec_fetch = { path = "../oaspec/adapters/fetch" }
```

A pure `git = "..."` dependency is not a workaround in that interim
state: each adapter lives in a subdirectory of the oaspec repo
(`adapters/httpc/`, `adapters/fetch/`), and Gleam's `gleam.toml`
parser does not support a `subpath` field on git dependencies as of
Gleam 1.16, so the build tool cannot locate the adapter's
`gleam.toml` inside the larger repository.

See [`examples/petstore_client_fetch/gleam.toml`](./examples/petstore_client_fetch/gleam.toml)
for the canonical path-dependency layout used in the bundled
examples.

### Server transport

Generated server code is the dual of the client side: the codegen
emits a single pure router function, and adapters bridge it to a real
HTTP framework. `api/router.route/6` takes the primitive pieces of a
request — `state`, `method`, `path`, `query`, `headers`, `body` — and
returns a `ServerResponse` whose `body` is a sum
(`TextBody(String)`, `BytesBody(BitArray)`, `EmptyBody`), so binary
endpoints carry real bytes through without a String round-trip.

A canonical [`mist`](https://hexdocs.pm/mist/) adapter looks like
this:

```gleam
import api/handlers
import api/router as oas_router
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mist

pub fn handle(
  req: Request(mist.Connection),
  state: handlers.State,
) -> Response(mist.ResponseData) {
  let method = req.method |> http.method_to_string |> string.uppercase
  let path =
    req.path
    |> string.split(on: "/")
    |> list.filter(fn(segment) { segment != "" })
  let query =
    req.query
    |> option.unwrap("")
    |> uri.parse_query
    |> result.unwrap([])
    |> list.fold(dict.new(), fn(acc, kv) {
      dict.upsert(acc, kv.0, fn(prev) {
        case prev {
          Some(values) -> list.append(values, [kv.1])
          None -> [kv.1]
        }
      })
    })
  let headers = req.headers |> dict.from_list
  let body =
    mist.read_body(req, 16_000_000)
    |> result.map(fn(read) { read.body })
    |> result.unwrap(<<>>)
    |> bit_array.to_string
    |> result.unwrap("")

  let resp = oas_router.route(state, method, path, query, headers, body)

  let mist_body = case resp.body {
    oas_router.TextBody(text) -> mist.Bytes(bytes_tree.from_string(text))
    oas_router.BytesBody(bytes) ->
      mist.Bytes(bytes_tree.from_bit_array(bytes))
    oas_router.EmptyBody -> mist.Bytes(bytes_tree.new())
  }
  resp.headers
  |> list.fold(response.new(resp.status), fn(r, header) {
    response.set_header(r, header.0, header.1)
  })
  |> response.set_body(mist_body)
}
```

The same shape works for [`wisp`](https://hexdocs.pm/wisp/): decompose
its request into the six primitives, call `oas_router.route(...)`,
render the returned `ServerResponse` back into the framework's
response type. Because the router is pure and synchronous, it is also
trivial to test in isolation without an HTTP server — see
[`examples/server_adapter`](./examples/server_adapter) for a
framework-free runnable example.

> **Note:** if any operation in your spec declares
> `application/octet-stream` on its request body, the generated
> router signature is `body: BitArray` (not `String`) so arbitrary
> binary payloads round-trip without going through
> `bit_array.to_string`. In that case drop the
> `|> bit_array.to_string |> result.unwrap("")` step from the
> snippet above and pass `mist.read_body(...).body` directly to
> `oas_router.route(...)`. The router internally converts to String
> for the non-binary arms. (#485)

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
| `include.tags` | no | `[]` | Operation tag allowlist (filter) |
| `include.paths` | no | `[]` | Operation path allowlist (filter, supports `/foo/**` glob) |
| `targets` | no | - | Array of per-target overrides (multi-target codegen) |

### Filtering operations with `include:`

To generate code for a subset of a large spec without modifying the
spec file, set `include.tags` and / or `include.paths`:

```yaml
input: github.yaml
package: github
mode: client
include:
  tags: [issues, repos]
  paths:
    - "/users/{username}"
    - "/repos/**"
```

Both lists are optional; omitting one means there is no constraint on
that axis, and omitting both leaves the filter inactive. An operation
is kept when its tag list intersects `include.tags` or its path matches
one of `include.paths`; the two lists are unioned rather than
intersected, so adding entries to either list widens the result.

Path patterns ending in `/**` match any path that extends the prefix
with a `/<rest>` segment, so `"/repos/**"` matches `/repos/foo` and
`/repos/foo/bar` but does not match the bare `/repos` — list `/repos`
explicitly when you also need it. Other patterns are compared by exact
equality.

### Splitting one spec into multiple packages with `targets:`

`targets:` is an array of per-target overrides. The same input spec is
generated once per entry, each with its own `package`, `output`, and
`include`. The top-level `input`, `mode`, and `validate` are shared
across every target.

```yaml
input: github.yaml
mode: client
targets:
  - package: dco_check/github/issues
    output: { dir: ./src }
    include:
      tags: [issues]
  - package: dco_check/github/repos
    output: { dir: ./src }
    include:
      paths: ["/repos/**"]
```

The example above produces two packages from one `oaspec generate` run,
at `./src/dco_check/github/issues/...` and
`./src/dco_check/github/repos/...`. Callers consume them as
`import dco_check/github/issues/client` and
`import dco_check/github/repos/client`.

Each target must declare its own `package`; there is no fallback default
for multi-target configs because two targets sharing the same default
would overwrite each other. The CLI rejects configs whose targets
resolve to overlapping output directories before writing any file. The
`--output` CLI flag is also rejected with multi-target configs because
each target already declares its own per-package output directory; use
per-target `output:` blocks instead.

### Configuration paths

All path-valued fields — `input`, `output.dir`, `output.server`,
`output.client` — are resolved relative to the current working
directory when oaspec runs, not the directory the config file lives in.

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
| `oaspec version` | Print the installed `oaspec` version (also available as `--version`) |

### CLI options for `init`

| Flag | Default | Description |
|------|---------|-------------|
| `--output=<path>` | `./oaspec.yaml` | Output path for the generated config file |

### CLI options for `generate`

| Flag | Default | Description |
|------|---------|-------------|
| `--config=<path>` | `./oaspec.yaml` | Path to config file |
| `--mode=<mode>` | `both` | `server`, `client`, or `both` (overrides config) |
| `--output=<path>` | - | Override output base directory |
| `--check` | `false` | Check that generated code matches existing files without writing |
| `--fail-on-warnings` | `false` | Treat warnings as errors |
| `--validate` | `false` | Force-enable guard validation in generated server/client code. One-way override — passing this flag turns validation on, but it cannot turn it off. To disable validation when the config sets `validate: true` (the default for `server` / `both` modes), edit `validate: false` in `oaspec.yaml`. |

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
- Request bodies: `application/json`, `text/plain`, `application/x-www-form-urlencoded`, and `multipart/form-data`
- Responses: typed status-code variants, `$ref` responses, `default` responses, typed response headers, and text or binary passthrough cases
- Security: `apiKey` (header, query, cookie), HTTP auth (bearer, basic, digest), OAuth2, and OpenID Connect. **Client-side**: the generated client attaches credentials per the `security:` declaration on each operation, walking OR-of-AND alternatives and applying the first satisfied one. For OAuth2 and OpenID Connect, the generated client attaches a bearer token to requests; token acquisition, refresh, and flow execution are outside the generated code. **Server-side**: the `security:` declaration on an operation is parsed but **not enforced** by the generated router — the handler is invoked regardless of whether the request carries the declared credentials. Handlers must check `Authorization` / `X-Api-Key` / cookie themselves and return their own 401. See [Server security model](#server-security-model) below.
- Generation safety: name collision handling, keyword escaping, validation guards, and capability errors with clear failure modes

### `format: byte` and `format: binary`

The OpenAPI `format` keyword on a `string` schema is passed through as
metadata only in the current release. Generated fields keep the Gleam
type `String`; the encoded contract (`format: byte` = base64 per OAS 3.0
§4.7.4 / OAS 3.1 alignment with JSON Schema, `format: binary` = raw
bytes) is not enforced or materialised by the generator.

Practical implications:

- `format: byte`: the field is decoded and emitted as the literal
  base64 character string. Callers that need the underlying bytes must
  base64-decode themselves (e.g. with `yabase/facade.decode_base64`).
  Invalid base64 input is not rejected at decode time.
- `format: binary`: the field is decoded and emitted as a plain
  `String`. For `multipart/form-data` request bodies, the higher-level
  body codepath (`client_request`) already handles binary bodies
  correctly via `BytesBody`; this caveat only applies when `binary`
  appears as a field-level format on a string schema outside that
  context.

A future release may auto-decode `format: byte` to `BitArray` or emit
a `format` docstring on the generated field; tracking issue
[#338](https://github.com/nao1215/oaspec/issues/338).

<!-- BEGIN GENERATED:BOUNDARIES -->
## Current Boundaries

This section stays in sync with `src/oaspec/internal/capability.gleam`.

- Detected and rejected keywords: `$defs`, `prefixItems`, `if/then/else`, `dependentSchemas`, `not`, `unevaluatedProperties`, `unevaluatedItems`, `contentEncoding`, `contentMediaType`, `contentSchema`, `mutualTLS`, `$id`, `const (non-string)`, `type: [T1, T2] with type-specific constraints`
- OpenAPI 3.1 `$id`-backed URL refs are still rejected during validation. Rewrite them to local `#/components/schemas/...` refs.
- `const` is only supported on string schemas. Non-string `const` values and multi-type schemas with type-specific constraints are rejected explicitly.
- Parsed but not used by codegen: callbacks, webhooks, externalDocs, tags, examples, links, encoding
- `xml` annotations are ignored by the parser
- Remaining server-mode request-shape boundaries: `server: complex path parameters`, `server: non-primitive query array items`, `server: non-primitive header array items`, `server: complex deepObject properties`, `server: mixed form-urlencoded request`, `server: complex form-urlencoded fields`, `server: mixed multipart request`, `server: complex multipart fields`, `server: unsupported request content type`
- Detailed server-mode decisions and fixture coverage live in [doc/server-mode-boundaries.md](./doc/server-mode-boundaries.md)
- Normalized to supported equivalents: `const` string values become single-value enums, `type: [T, null]` becomes nullable, and `type: [T1, T2]` becomes `oneOf`
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

`handlers.gleam` is user-owned. The generator writes panic stubs on the first
run and skips the file on every subsequent run, so your implementations survive
regeneration. `handlers_generated.gleam` is the sealed delegator the router
imports, and each operation forwards to `handlers.<op_name>(req)`.

### Feature restrictions by mode

| Feature | server | client | Notes |
|---------|--------|--------|-------|
| JSON request/response bodies | yes | yes | |
| Path / query / header / cookie parameters | yes | yes | |
| `style: deepObject` parameters | restricted | yes | Server: only primitive scalars and primitive arrays |
| Array query parameters | restricted | yes | Server: only inline primitive item schemas |
| `style: pipeDelimited` / `style: spaceDelimited` query arrays | yes | yes | Query array parameters only; primitive item types. Non-exploded joins with `\|` / `%20`, exploded degenerates to form-style `name=a&name=b`. |
| `application/x-www-form-urlencoded` | restricted | yes | Server: must be sole content type; only primitive fields and shallow nested objects |
| `multipart/form-data` | restricted | yes | Server: must be sole content type; only primitive scalar fields or arrays of primitive scalars |
| `text/plain` request body | yes | yes | Treated as a single `String` field on the request |
| `application/octet-stream` request body | yes | yes | Treated as raw `BitArray`/binary on the request |
| Security (apiKey, HTTP, OAuth2, OpenID Connect) | parsed (not enforced) | yes | Client attaches credentials via config; OAuth2/OpenID Connect: bearer token only. **Server-side**: see [Server security model](#server-security-model) — the spec's `security:` requirement is parsed but the generated router does not emit a 401 for missing/invalid credentials. Handlers must enforce auth themselves. (#484) |

### Server security model

Spec authors who declare `security:` on an operation expect "this
endpoint requires auth". The current oaspec server codegen
**does not enforce** that requirement: it parses the security
declaration during validation (so a typo in a scheme name or a
reference to an undefined `securityScheme` is still caught at
generation time) but emits no auth check in the generated router.
A request that omits the declared `Authorization` / `X-Api-Key` /
session cookie reaches the handler unchanged.

This is intentional in this release — picking a single auth
enforcement model would prescribe more policy than the rest of
the codegen does — but it is also a sharp edge worth calling out.
Until the generator gains a verifier hook, server users have two
options:

1. **Enforce in the handler.** The router already passes the full
   `headers` and (for cookie-based schemes) the path / query /
   body pieces it receives, so the handler can read
   `dict.get(headers, "authorization")` etc. and short-circuit
   with a 401 response variant before touching domain logic.
   Generated `XxxResponse` types include any explicit `"401":`
   variants, and after #483 the `default` response variant carries
   a runtime `Int` so a single `Default(401, ...)` arm can cover
   the catch-all 401 case for any operation.

2. **Enforce in an outer adapter layer.** Wrap the generated
   `router.route/6` in a thin auth-checking function that runs
   before dispatch — typically the same place where the framework
   adapter (`mist`, `wisp`, …) lives. This keeps the per-operation
   handlers focused on domain logic and centralises the auth
   policy in one place.

Tracking issue: [#484](https://github.com/nao1215/oaspec/issues/484).
Future work may add an opt-in verifier signature on the generated
`State` (e.g. `verify_security: fn(scheme, value) -> Result(...)`)
so the router can emit the 401 itself; that direction is not yet
committed to.

## Library API

`oaspec` can be used as a Gleam library, not just a CLI tool. The generation pipeline is pure (no IO) and split into composable steps.

### Public modules at a glance

| Module | Purpose |
|--------|---------|
| `oaspec/transport` | Runtime contract for generated clients (`Send` / `AsyncSend` types, `with_base_url`, `with_default_headers`, `with_security`) |
| `oaspec/mock` | In-memory transport adapter for tests — no network, no FFI |
| `oaspec/config` | Load config from YAML (`config.load/1` / `config.load_all/1`) or build a `Config` in code (`config.new/6`) |
| `oaspec/generate` | Pure generation pipeline (`generate.generate/2`, `generate.validate_only/2`) — no IO |
| `oaspec/openapi/parser` | Parse YAML/JSON spec text into an `OpenApiSpec(Unresolved)` |
| `oaspec/openapi/diagnostic` | Structured warnings and errors used throughout the pipeline |
| `oaspec/codegen/writer` | Write a `List(GeneratedFile)` to disk under `output.server` / `output.client` |

If you only consume generated clients, you only need `oaspec/transport` and
`oaspec/mock`. Tools that drive generation in-process (CI checks, custom
build steps, doctests) reach for `oaspec/openapi/parser` →
`oaspec/generate` → `oaspec/codegen/writer`.

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
    Nil
  }
  Error(generate.ValidationErrors(errors:)) -> {
    // errors: List(Diagnostic) — blocking validation errors
    Nil
  }
}
```

### Example: validate without generating

```gleam
case generate.validate_only(spec, cfg) {
  Ok(_summary) -> Nil
  // spec has errors; surface `errors` to the user
  Error(generate.ValidationErrors(errors: _errors)) -> Nil
}
```

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
