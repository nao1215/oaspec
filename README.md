# oaspec

[![Hex package](https://img.shields.io/hexpm/v/oaspec)](https://hex.pm/packages/oaspec)
[![HexDocs](https://img.shields.io/badge/hexdocs-latest-blue)](https://hexdocs.pm/oaspec/)
[![License](https://img.shields.io/github/license/nao1215/oaspec)](https://github.com/nao1215/oaspec/blob/main/LICENSE)
[![Quick](https://github.com/nao1215/oaspec/actions/workflows/ci-quick.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/ci-quick.yml)
[![Tests](https://github.com/nao1215/oaspec/actions/workflows/ci-tests.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/ci-tests.yml)
[![Examples](https://github.com/nao1215/oaspec/actions/workflows/ci-examples.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/ci-examples.yml)
[![Adapters](https://github.com/nao1215/oaspec/actions/workflows/ci-adapters.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/ci-adapters.yml)

Generate Gleam client and server modules from OpenAPI 3.x specs.

OpenAPI in → typed Gleam client and server out, with no per-operation glue
code to write or maintain. The generator owns request and response types,
encoders, decoders, validation guards, and the router; you wire credentials
and a transport adapter, then call typed operation functions.

```gleam
import api/client
import oaspec/httpc
import oaspec/transport

let send =
  httpc.send
  |> transport.with_base_url(client.default_base_url())

let assert Ok(pets) = client.list_pets(send, limit: Some(10), offset: None)
```

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

```sh
gleam add oaspec gleam_json
```

`gleam_json` is added in the same step because the generated `decode.gleam`,
`encode.gleam`, `guards.gleam`, and `router.gleam` modules `import gleam/json`
directly. Without it as a direct dependency, `gleam check` warns on every
generated file.

### CLI (GitHub release)

Requires Erlang/OTP 27+. The release artifact is an Erlang escript, so the
same binary runs anywhere Erlang is available.

```sh
curl -fSL -o oaspec https://github.com/nao1215/oaspec/releases/latest/download/oaspec
chmod +x oaspec
sudo mv oaspec /usr/local/bin/
```

On Windows, download `oaspec` from the [latest release](https://github.com/nao1215/oaspec/releases/latest) and run it with `escript oaspec <command>`. Erlang/OTP 27+ must be on your `PATH`.

### CLI (build from source)

Requires Gleam 1.15+, Erlang/OTP 27+, and `rebar3`.

```sh
git clone https://github.com/nao1215/oaspec.git
cd oaspec
gleam deps download
gleam run -m gleescript
sudo mv oaspec /usr/local/bin/   # or anywhere on PATH
```

## Quickstart

```sh
# 1. (Skip if you have your own.) Fetch a sample spec.
curl -fSL -o openapi.yaml https://raw.githubusercontent.com/nao1215/oaspec/main/test/fixtures/petstore.yaml

# 2. Create oaspec.yaml — uncomment `input:` and point it at your spec.
oaspec init

# 3. Generate.
oaspec generate --config=oaspec.yaml
```

`oaspec init` writes a fully-commented template; `package: api` is the
only uncommented field. All path-valued config fields (`input`,
`output.dir`, `output.server`, `output.client`) are resolved relative to
the current working directory when `oaspec` runs, not the config file
location. See [doc/configuration.md](./doc/configuration.md) for the
full set of fields, CLI flags, multi-target codegen, and validate mode.

## Generated files

Given one OpenAPI spec, `oaspec` writes modules you can keep in your
repository:

```text
gen/my_api/                  # server (mode: server | both)
  types.gleam
  decode.gleam
  encode.gleam
  request_types.gleam
  response_types.gleam
  guards.gleam
  handlers.gleam             # user-owned, written once, never overwritten
  handlers_generated.gleam
  router.gleam

gen/my_api_client/           # client (mode: client | both)
  types.gleam
  decode.gleam
  encode.gleam
  request_types.gleam
  response_types.gleam
  guards.gleam
  client.gleam
```

`handlers.gleam` is the one user-owned file — the generator writes panic
stubs on the first run and skips it afterwards, so your implementations
survive regeneration. Everything else is regenerated as the spec changes.

## Using the generated client

Generated clients depend on a tiny pure runtime (`oaspec/transport`)
instead of any specific HTTP library. Operations expose both synchronous
`transport.Send` entry points and asynchronous `transport.AsyncSend`
variants, so the same generated code runs against real HTTP, fakes, or
any future runtime.

Adapters that bridge `transport.Send` / `transport.AsyncSend` to a real
runtime live as sibling Gleam packages under [`adapters/`](./adapters),
so the root `oaspec` package never depends on `gleam_httpc` or any
specific HTTP runtime.

### BEAM (`oaspec_httpc`)

```sh
gleam add oaspec_httpc
```

```gleam
import api/client
import oaspec/httpc
import oaspec/transport

let send =
  httpc.send
  |> transport.with_base_url(client.default_base_url())

let result = client.list_pets(send, limit: Some(10), offset: None)
```

Runnable example: [`examples/petstore_client`](./examples/petstore_client).
Run it with `just example-petstore`.

### JavaScript (`oaspec_fetch`)

```sh
gleam add oaspec_fetch
```

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

Runnable example:
[`examples/petstore_client_fetch`](./examples/petstore_client_fetch).
Run it with `just example-petstore-fetch`.

### Tests (`oaspec/mock`)

```gleam
import oaspec/mock

let send = mock.text(200, "[{\"id\": 1, \"name\": \"Fido\"}]")
let assert Ok(_) = client.list_pets(send, limit: None, offset: None)
```

`oaspec/mock` is a pure in-memory transport — no network, no FFI — so
generated clients can be exercised in `gleam test` without any HTTP
adapter. The petstore example above is built on it.

### Authenticated requests

`oaspec/transport` ships middleware for base URL override, default
headers, and OpenAPI security. `with_security` walks the request's
declared OR-of-AND alternatives and applies the first one whose required
schemes have credentials. The same `with_*` middleware works for both
`transport.Send` and `transport.AsyncSend`.

```gleam
let send =
  httpc.send
  |> transport.with_base_url(client.default_base_url())
  |> transport.with_security(
    transport.credentials()
    |> transport.with_bearer_token("BearerAuth", token),
  )
```

Each operation also exposes `build_<op>_request` and
`decode_<op>_response` helpers, plus request-object wrappers for both
sync and async call paths, so callers can drive the request and response
halves independently — useful for retry middleware, logging, or testing
decoding in isolation.

### Adapter availability

Both adapters are published to Hex from this repository on tag push:
`oaspec_httpc-v*` for the BEAM adapter, `oaspec_fetch-v*` for the
JavaScript one. If `gleam add oaspec_httpc` reports `package not found`,
no adapter release has been cut yet — depend on the adapter via a path
dependency to a local checkout of `oaspec` until the first tag push.
Pure `git = "..."` dependencies do not work in that interim state because
each adapter lives in a subdirectory of the repo and Gleam's `gleam.toml`
parser does not support a `subpath` field on git dependencies as of
Gleam 1.16. See
[`examples/petstore_client_fetch/gleam.toml`](./examples/petstore_client_fetch/gleam.toml)
for the canonical path-dependency layout.

## Using the generated server

The codegen emits a single pure router function, and adapters bridge it
to a real HTTP framework. `api/router.route/6` takes the primitive pieces
of a request — `state`, `method`, `path`, `query`, `headers`, `body` —
and returns a `ServerResponse` whose `body` is a sum
(`TextBody(String)`, `BytesBody(BitArray)`, `EmptyBody`), so binary
endpoints carry real bytes through without a String round-trip:

```gleam
import api/handlers
import api/router

let state = handlers.State
let response = router.route(state, "GET", ["pets"], dict.new(), dict.new(), "")

case response.body {
  router.TextBody(text) -> ...
  router.BytesBody(bytes) -> ...
  router.EmptyBody -> ...
}
```

Because the router is pure and synchronous, it is also trivial to test
in isolation without an HTTP server. Runnable framework-free example:
[`examples/server_adapter`](./examples/server_adapter). Run it with
`just example-server-adapter`.

For `mist` and `wisp` recipes that decompose the framework's request
into the six primitives and render the `ServerResponse` back, see
[doc/server-adapters.md](./doc/server-adapters.md).

The generated router parses but does not enforce `security:` declarations
on operations — handlers must check `Authorization` / `X-Api-Key` /
cookies themselves and return their own 401. See
[doc/server-security.md](./doc/server-security.md) for the rationale and
two enforcement patterns.

## Best for

- Generating typed Gleam clients from an OpenAPI contract
- Keeping request and response types in sync with an external API spec
- Bootstrapping server-side types, handlers, and router support from the
  same source spec
- Catching unsupported spec features early in CI instead of after code
  generation

## Documentation

- [doc/openapi-support.md](./doc/openapi-support.md) — what `oaspec`
  supports, what it rejects, and mode-specific feature restrictions
- [doc/configuration.md](./doc/configuration.md) — `oaspec.yaml` fields,
  CLI flags, multi-target codegen, and the `validate` mode
- [doc/server-adapters.md](./doc/server-adapters.md) — `mist` / `wisp`
  adapter recipes for the generated router
- [doc/server-security.md](./doc/server-security.md) — server-side auth
  enforcement model and patterns
- [doc/library-api.md](./doc/library-api.md) — using `oaspec` as a Gleam
  library (parse → generate pipeline)
- [examples/](./examples) — runnable examples covered by CI

## Development

This project uses [mise](https://mise.jdx.dev/) for tool versions and
[just](https://just.systems/) as a task runner.

```sh
mise install
just check
just shellspec
just integration
```

| Command | Tool | What it tests |
|---------|------|---------------|
| `just test` | gleeunit | Parser, validator, naming, config, collision detection |
| `just shellspec` | ShellSpec | CLI behaviour, file generation, content, unsupported feature detection |
| `just integration` | gleeunit | Generated code compiles and the generated modules work together |

## License

[MIT](LICENSE)
