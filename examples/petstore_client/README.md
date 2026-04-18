# petstore_client — runnable client example

A minimal Gleam project that uses an oaspec-generated client for the
Petstore OpenAPI spec at `test/fixtures/petstore.yaml`.

## What it shows

- Generating a client from an OpenAPI 3.x spec via `oaspec.yaml`.
- Importing the generated client and response types.
- Building a `ClientConfig` with a custom `send` function (here a stub
  that returns a canned JSON body — swap in `gleam_httpc`, `mist`, or
  `wisp` for real traffic).
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

More examples (`server_adapter`, `security_client`) will follow in
subsequent PRs per Issue #26.
