# server_adapter — minimal HTTP adapter for the generated router

A Gleam project that shows how to bridge the oaspec-generated
`router.route/5` function to any real HTTP stack (wisp, mist, …).

## What it shows

- Generating a server from an OpenAPI 3.x spec via `oaspec.yaml`.
- A **regeneration-safe handler layout**: domain logic lives in
  `src/example_handlers.gleam`, which the generator never touches.
  `src/api/handlers.gleam` is a thin delegator owned by the generator.
- Calling the generated router with primitive request pieces
  (`method`, `path`, `query`, `headers`, `body`) and inspecting the
  returned `ServerResponse`.

The shape of the router is deliberately framework-free. Any wisp / mist
adapter is the same three-step pattern:

1. Decompose the framework's request into the five primitives.
2. `let response = router.route(method, path, query, headers, body)`.
3. Render `response.status` / `response.body` / `response.headers` back
   into the framework's response type.

This program runs that adapter against a canned request instead of
spinning up an HTTP server, so the example has no framework dependency.

## Recommended handler layout

The generator owns every file under `src/api/`. Putting domain logic
directly into `src/api/handlers.gleam` means regeneration clobbers it.
The pattern this example demonstrates — and that we recommend for
production projects — is:

```text
src/
  api/
    handlers.gleam         ← generated, regen-safe thin delegator
    …other generated files
  example_handlers.gleam   ← you own this; domain logic lives here
```

`src/api/handlers.gleam` is a two-line-per-function delegator:

```gleam
import api/request_types
import api/response_types
import example_handlers

pub fn list_pets(
  req: request_types.ListPetsRequest,
) -> response_types.ListPetsResponse {
  example_handlers.list_pets(req)
}
```

When you regenerate the server, `handlers.gleam` is rewritten with
fresh `panic` stubs. Restoring it is mechanical: for each function,
replace the stub body with `example_handlers.<fn>(req)`. Because your
actual domain logic never lived in `handlers.gleam`, nothing of value
is lost in the overwrite.

## Run it

From the repo root:

```sh
just example-server-adapter
```

Or manually:

```sh
cd examples/server_adapter
gleam run
```

Expected output:

```text
status: 200
headers: 1 header(s)
body: [{"id":1,"name":"Fido","status":"available","tag":"dog"},{"id":2,"name":"Whiskers","status":"pending","tag":null}]
```

## Regenerating the server code

The generated server files under `src/api/` are committed, so the
example runs out of the box. Regenerate only when the spec or oaspec
itself changes:

```sh
gleam run -- generate --config=examples/server_adapter/oaspec.yaml
```

After regeneration, re-apply the thin delegator pattern to
`src/api/handlers.gleam` (see above). `src/example_handlers.gleam` is
untouched by the generator, so the domain logic carries over as-is.

## File layout

```text
examples/server_adapter/
  gleam.toml                 — project manifest
  oaspec.yaml                — generator config (server mode)
  src/api/                   — generated server code (checked in)
  src/api/handlers.gleam     — thin delegator (hand-edited, 1 line per op)
  src/example_handlers.gleam — your domain logic (generator never touches)
  src/server_adapter_example.gleam  — the program you run
```
