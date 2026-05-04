# petstore_client — generated client / decoder roundtrip demo

A minimal Gleam project that uses an oaspec-generated client for the
Petstore OpenAPI spec at `test/fixtures/petstore.yaml`.

This example is intentionally framework-free: it does not hit a real
HTTP endpoint. The transport is a stub built with `oaspec/mock` that
returns a canned JSON body, so the example runs without a live server,
without network access, and without any HTTP adapter dependency. The
focus is the contract between oaspec-generated code and `oaspec/transport`
— request building, response decoding, and the typed response variants.

For a parallel example that calls a live JavaScript fetch endpoint, see
[`examples/petstore_client_fetch`](../petstore_client_fetch/). For a
BEAM example that issues real HTTP, see "Hooking up real HTTP" below
for the exact swap.

## What it shows

- Generating a client from an OpenAPI 3.x spec via `oaspec.yaml`.
- Importing the generated client and response types.
- Building a `transport.Send` value with `mock.from(...)` and a custom
  request handler — the stub is the only piece swapped out when moving
  to a real adapter.
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

## What the generator produces

A snippet from the checked-in [`src/api/client.gleam`](./src/api/client.gleam)
and [`src/api/response_types.gleam`](./src/api/response_types.gleam) — these
are emitted by `oaspec generate` from [`oaspec.yaml`](./oaspec.yaml):

```gleam
// src/api/client.gleam
pub fn list_pets(
  send send: transport.Send,
  limit limit: Option(Int),
  offset offset: Option(Int),
) -> Result(response_types.ListPetsResponse, ClientError)
```

```gleam
// src/api/response_types.gleam
pub type ListPetsResponse {
  ListPetsResponseOk(List(types.Pet))
  ListPetsResponseUnauthorized
}
```

The full generated tree (`types.gleam`, `decode.gleam`, `encode.gleam`,
`request_types.gleam`, `response_types.gleam`, `guards.gleam`,
`client.gleam`) lives under `src/api/`.

## File layout

```text
examples/petstore_client/
  gleam.toml                 — project manifest
  oaspec.yaml                — generator config (input: petstore.yaml)
  src/api/                   — generated client code (checked in)
  src/petstore_client_example.gleam  — the program you run
```

## Hooking up real HTTP

To run the same client against a live BEAM HTTP backend, swap the
stub for the `oaspec_httpc` adapter from
[`adapters/httpc/`](../../adapters/httpc/). The change is a one-liner
on the transport: everything else (the typed `list_pets/3` call, the
`response_types.ListPetsResponseOk(pets)` match, the
`ClientError` handling) stays the same.

```gleam
// before — stubbed, no network
import oaspec/mock
let send = mock.from(stub_handler)

// after — real BEAM HTTP via gleam_httpc
import oaspec/httpc
import oaspec/transport
let send =
  httpc.send
  |> transport.with_base_url("https://petstore3.swagger.io/api/v3")
```

`oaspec_httpc` is not yet on Hex; depend on it from a path or git
dependency in your project's `gleam.toml` (see the
[oaspec_fetch example layout](../petstore_client_fetch/gleam.toml) for
the canonical pattern).

A self-contained runnable real-HTTP sibling example
(`petstore_client_httpc`) can be added later once the `oaspec_httpc`
adapter ships on Hex; the swap above is small enough that it doesn't
need its own directory in the meantime.

## Related examples

- [`examples/petstore_client_fetch`](../petstore_client_fetch/) — the same
  Petstore client flow on the JavaScript target using the first-party
  fetch adapter.
- [`examples/server_adapter`](../server_adapter/) — a framework-free runnable
  example that bridges the generated `router.route/6` to a canned
  request/response pair. Run it with `just example-server-adapter`.

A `security_client` example is still to come; see Issue #26.
