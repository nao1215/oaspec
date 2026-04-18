# server_adapter — minimal HTTP adapter for the generated router

A Gleam project that shows how to bridge the oaspec-generated
`router.route/5` function to any real HTTP stack (wisp, mist, …).

## What it shows

- Generating a server from an OpenAPI 3.x spec via `oaspec.yaml`.
- Hand-writing `handlers.gleam` — the generated file ships with `panic`
  stubs; real applications replace these with domain logic.
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

## Run it

From the repo root:

```sh
just example-server-adapter
```

Or manually:

```sh
# 1. Regenerate the server code (already committed; only needed if the
#    spec or oaspec itself changed). Note that `handlers.gleam` is
#    *hand-written* in this example — running the generator will
#    overwrite it, so keep a backup if you edit it locally.
gleam run -- generate --config=examples/server_adapter/oaspec.yaml

# 2. Run the example.
cd examples/server_adapter
gleam run
```

Expected output:

```text
status: 200
headers: 1 header(s)
body: [{"id":1,"name":"Fido","status":"available","tag":"dog"},{"id":2,"name":"Whiskers","status":"pending","tag":null}]
```

## File layout

```text
examples/server_adapter/
  gleam.toml                 — project manifest
  oaspec.yaml                — generator config (server mode)
  src/api/                   — generated server code (checked in)
  src/api/handlers.gleam     — *hand-written* handlers (NOT regenerated)
  src/server_adapter_example.gleam  — the program you run
```

`handlers.gleam` is also produced by the generator with `panic` stubs.
The example commits the hand-written version; running the generator
again will overwrite it. When integrating into a real project, keep
handler implementations in a separate module (or a separate file
excluded from `generate`) and delegate from the generated
`handlers.gleam` to that module.
