# petstore_client — runnable client example

A minimal Gleam project that uses an oaspec-generated client for the
Petstore OpenAPI spec at `test/fixtures/petstore.yaml`.

## What it shows

- Generating a client from an OpenAPI 3.x spec via `oaspec.yaml`.
- Importing the generated client and response types.
- Building a `transport.Send` value with `mock.from(...)` and a custom
  request handler (here a stub that returns a canned JSON body — swap
  in the [`oaspec_httpc`](../../adapters/httpc/) adapter for real
  BEAM-side traffic, or the [`oaspec_fetch`](../../adapters/fetch/)
  adapter for the JavaScript target).
- Handling the typed response variants that oaspec generates for each
  operation.

## Run it

From the repo root:

```sh
just example-petstore
```

Or manually:

```sh
# 1. Regenerate the client code (already committed — only needed if
#    the spec or oaspec itself changed).
gleam run -- generate --config=examples/petstore_client/oaspec.yaml

# 2. Run the example.
cd examples/petstore_client
gleam run
```

Expected output:

```text
Got 2 pet(s):
  - Fido (id=1)
  - Whiskers (id=2)
```

## File layout

```text
examples/petstore_client/
  gleam.toml                 — project manifest
  oaspec.yaml                — generator config (input: petstore.yaml)
  src/api/                   — generated client code (checked in)
  src/petstore_client_example.gleam  — the program you run
```

## Related examples

- [`examples/petstore_client_fetch`](../petstore_client_fetch/) — the same
  Petstore client flow on the JavaScript target using the first-party
  fetch adapter.
- [`examples/server_adapter`](../server_adapter/) — a framework-free runnable
  example that bridges the generated `router.route/5` to a canned
  request/response pair. Run it with `just example-server-adapter`.

A `security_client` example is still to come; see Issue #26.
