# oaspec

[![CI](https://github.com/nao1215/oaspec/actions/workflows/ci-tests.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/ci-tests.yml)
[![Quick](https://github.com/nao1215/oaspec/actions/workflows/ci-quick.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/ci-quick.yml)
[![Adapters](https://github.com/nao1215/oaspec/actions/workflows/ci-adapters.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/ci-adapters.yml)
[![Gitleaks](https://github.com/nao1215/oaspec/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/gitleaks.yml)
[![Trivy](https://github.com/nao1215/oaspec/actions/workflows/trivy.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/trivy.yml)
[![OSV-Scanner](https://github.com/nao1215/oaspec/actions/workflows/osv-scan.yml/badge.svg)](https://github.com/nao1215/oaspec/actions/workflows/osv-scan.yml)
[![tested with atago](https://img.shields.io/badge/tested%20with-atago-7c3aed?logo=data:image/svg%2Bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI%2BPHBhdGggZmlsbD0iI2ZmZiIgZD0iTTMuNiA0LjIgMTEuOSAxMmwtOC4zIDcuOC0xLjktMi4yTDcuOSAxMiAxLjcgNi40eiIvPjxyZWN0IGZpbGw9IiNmZmYiIHg9IjEyLjYiIHk9IjE3LjIiIHdpZHRoPSI5LjciIGhlaWdodD0iMi44IiByeD0iMS40Ii8%2BPC9zdmc%2B&logoColor=white)](https://github.com/nao1215/atago)
[![measured with himorime](https://img.shields.io/badge/measured%20with-himorime-d9480f?logo=data:image/svg%2Bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI%2BPHBhdGggZmlsbD0ibm9uZSIgc3Ryb2tlPSIjZmZmIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBkPSJNNC4yIDE4LjVBOSA5IDAgMSAxIDE5LjggMTguNSIvPjxwYXRoIGZpbGw9Im5vbmUiIHN0cm9rZT0iI2ZmZiIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgZD0iTTEyIDE0LjUgMTYuNSA5Ii8%2BPGNpcmNsZSBmaWxsPSIjZmZmIiBjeD0iMTIiIGN5PSIxNC41IiByPSIyLjIiLz48L3N2Zz4=&logoColor=white)](https://github.com/nao1215/himorime)
[![Hex](https://img.shields.io/hexpm/v/oaspec)](https://hex.pm/packages/oaspec)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/oaspec/)
[![Hex Downloads](https://img.shields.io/hexpm/dt/oaspec)](https://hex.pm/packages/oaspec)
[![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/nao1215/oaspec/total)](https://github.com/nao1215/oaspec/releases)
[![License](https://img.shields.io/github/license/nao1215/oaspec)](https://github.com/nao1215/oaspec/blob/main/LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/nao1215/oaspec/badge)](https://scorecard.dev/viewer/?uri=github.com/nao1215/oaspec)

Generate Gleam client and server modules from OpenAPI 3.x specs. The generator writes the request and response types, encoders, decoders, validation guards and the router. You supply credentials and a transport adapter, then call typed operation functions.

```gleam
import api_client/client
import oaspec/httpc
import oaspec/transport

let send =
  httpc.send
  |> transport.with_base_url(client.default_base_url())

let assert Ok(pets) = client.list_pets(send, limit: Some(10), offset: None)
```

API reference: <https://hexdocs.pm/oaspec/>

## Install

Most projects need both parts: the library from Hex in the project that uses the generated code, and the `oaspec` CLI (`init`, `generate`, `validate`) to run the generator.

```sh
gleam add oaspec gleam_json gleam_http
```

Generated modules import `gleam/json`, and generated clients import `gleam/http` for request methods, so both need to be direct dependencies or `gleam check` warns on every generated file.

### CLI (GitHub release)

The release artifact is an Erlang escript and needs Erlang/OTP 27+.

```sh
curl -fSL -o oaspec https://github.com/nao1215/oaspec/releases/latest/download/oaspec
chmod +x oaspec
sudo mv oaspec /usr/local/bin/
```

On Windows, download `oaspec` from the [latest release](https://github.com/nao1215/oaspec/releases/latest) and run it with `escript oaspec <command>`. Erlang/OTP 27+ must be on your `PATH`.

### CLI (build from source)

Requires Gleam 1.14+, Erlang/OTP 27+, and `rebar3`.

```sh
git clone https://github.com/nao1215/oaspec.git
cd oaspec
sh scripts/build_escript.sh oaspec
sudo mv oaspec /usr/local/bin/   # or anywhere on PATH
```

### Verifying release integrity

From v0.71.0, each release carries `SHA256SUMS` (the escript, its CycloneDX SBOM `oaspec.cdx.json` and the bundled third-party licenses), a cosign keyless signature of it, and SLSA provenance. With the release files in the current directory:

```sh
sha256sum -c SHA256SUMS
cosign verify-blob --bundle SHA256SUMS.sigstore.json \
  --certificate-identity-regexp '^https://github.com/nao1215/oaspec/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS
gh attestation verify oaspec --repo nao1215/oaspec
slsa-verifier verify-artifact --provenance-path multiple.intoto.jsonl \
  --source-uri github.com/nao1215/oaspec --source-tag <tag> oaspec
```

## Quickstart

```sh
# 1. (Skip if you have your own.) Fetch a sample spec.
curl -fSL -o openapi.yaml https://raw.githubusercontent.com/nao1215/oaspec/main/test/fixtures/petstore.yaml

# 2. Create oaspec.yaml (it reads openapi.yaml by default).
oaspec init

# 3. Generate.
oaspec generate --config=oaspec.yaml
```

`oaspec init` writes a commented template in which only `input: openapi.yaml` and `package: api` are set. Path fields (`input`, `output.dir`, `output.server`, `output.client`) are resolved against the working directory, not the config file's location. [doc/configuration.md](https://github.com/nao1215/oaspec/blob/main/doc/configuration.md) lists every field and CLI flag, multi-target codegen and validate mode.

### Using oaspec as a library

The `oaspec` module has the steps the CLI runs: `parse_file` or `parse_string`, `generate`, then `write`. `generate` does no IO, so a build step or a test can look at the files before they are written. `write` does not format the files; run `gleam format` afterwards, as the CLI does.

```gleam
import gleam/io
import gleam/list
import oaspec
import oaspec/config
import oaspec/openapi

pub fn main() {
  let assert Ok(cfg) = config.load("oaspec.yaml")
  case oaspec.parse_file(cfg.input) {
    Error(diagnostic) -> io.println(openapi.diagnostic_to_string(diagnostic))
    Ok(spec) ->
      case oaspec.generate(spec, cfg) {
        Ok(generated) -> {
          let assert Ok(paths) = oaspec.write(generated)
          list.each(paths, io.println)
        }
        Error(oaspec.InvalidSpec(errors)) ->
          list.each(errors, fn(e) { io.println(openapi.diagnostic_to_string(e)) })
        Error(oaspec.InvalidConfig(error)) ->
          io.println(config.error_to_string(error))
      }
  }
}
```

## Generated files

For one spec, `oaspec` writes:

```text
src/my_api/                  # server (mode: server | both)
  types.gleam
  decode.gleam
  encode.gleam
  request_types.gleam
  response_types.gleam
  guards.gleam
  handlers.gleam             # user-owned, written once, never overwritten
  handlers_generated.gleam
  router.gleam

src/my_api_client/           # client (mode: client | both)
  types.gleam
  decode.gleam
  encode.gleam
  request_types.gleam
  response_types.gleam
  guards.gleam
  client.gleam
```

The base directory is `./src`, so `gleam build` picks the modules up. `output.dir`, or `output.server` and `output.client`, change it.

`handlers.gleam` is yours: the generator writes panic stubs on the first run and never touches it again. Everything else is regenerated. With `handlers: per_operation`, each operation gets its own `handlers/<operation>.gleam`, so an operation added to the spec gets a stub on the next run; see [Configuration](https://github.com/nao1215/oaspec/blob/main/doc/configuration.md#one-handler-file-per-operation).

## Using the generated client

Generated clients depend on the small pure runtime `oaspec/transport`, not on an HTTP library. Each operation has a synchronous `transport.Send` entry point and an asynchronous `transport.AsyncSend` variant. The adapters that connect them to a real HTTP runtime are separate packages under [`adapters/`](https://github.com/nao1215/oaspec/tree/main/adapters), so `oaspec` itself does not depend on `gleam_httpc`. They are published to Hex on `oaspec_httpc-v*` and `oaspec_fetch-v*` tags.

### BEAM (`oaspec_httpc`)

```sh
gleam add oaspec_httpc
```

```gleam
import api_client/client
import oaspec/httpc
import oaspec/transport

let send =
  httpc.send
  |> transport.with_base_url(client.default_base_url())

let result = client.list_pets(send, limit: Some(10), offset: None)
```

Runnable example: [`examples/petstore_client`](https://github.com/nao1215/oaspec/tree/main/examples/petstore_client).
Run it with `just example-petstore`.

### JavaScript (`oaspec_fetch`)

```sh
gleam add oaspec_fetch
```

```gleam
import api_client/client
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
[`examples/petstore_client_fetch`](https://github.com/nao1215/oaspec/tree/main/examples/petstore_client_fetch).
Run it with `just example-petstore-fetch`.

### Tests

A `Send` is a function from `transport.Request` to a result, so a test can pass one that returns a fixed response, with no network:

```gleam
let send = fn(_request) {
  Ok(transport.Response(
    status: 200,
    headers: [],
    body: transport.TextBody("[{\"id\": 1, \"name\": \"Fido\"}]"),
  ))
}
let assert Ok(_) = client.list_pets(send, limit: None, offset: None)
```

### Authenticated requests

`oaspec/transport` has middleware for the base URL, default headers and OpenAPI security, for both `Send` and `AsyncSend`. `with_security` applies the first of the request's OR-of-AND security alternatives whose schemes all have credentials.

```gleam
let send =
  httpc.send
  |> transport.with_base_url(client.default_base_url())
  |> transport.with_security([transport.BearerToken("BearerAuth", token)])
```

Each operation also has `build_<op>_request` and `decode_<op>_response` helpers and request-object wrappers for both call paths, so retry middleware, logging or a decoding test can handle the request and the response separately.

## Using the generated server

The generator writes one pure router function. `api/router.route/6` takes `state`, `method`, `path`, `query`, `headers` and `body`, and returns a `ServerResponse` whose `body` is `TextBody(String)`, `BytesBody(BitArray)` or `EmptyBody`, so binary endpoints keep their bytes:

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

The router can be tested without an HTTP server. Runnable framework-free example: [`examples/server_adapter`](https://github.com/nao1215/oaspec/tree/main/examples/server_adapter), run with `just example-server-adapter`. [doc/server-adapters.md](https://github.com/nao1215/oaspec/blob/main/doc/server-adapters.md) has `mist` and `wisp` recipes.

The router reads `security:` declarations but does not enforce them; [doc/server-security.md](https://github.com/nao1215/oaspec/blob/main/doc/server-security.md) shows where to check credentials.

## Documentation

- [doc/openapi-support.md](https://github.com/nao1215/oaspec/blob/main/doc/openapi-support.md): what `oaspec` supports and rejects, and restrictions per mode
- [doc/configuration.md](https://github.com/nao1215/oaspec/blob/main/doc/configuration.md): `oaspec.yaml` fields, CLI flags, multi-target codegen, `validate` mode
- [doc/server-adapters.md](https://github.com/nao1215/oaspec/blob/main/doc/server-adapters.md): `mist` and `wisp` recipes for the generated router
- [doc/server-security.md](https://github.com/nao1215/oaspec/blob/main/doc/server-security.md): enforcing auth on the server
- [examples/](https://github.com/nao1215/oaspec/tree/main/examples): runnable examples covered by CI

## Development

This project uses [mise](https://mise.jdx.dev/) for tool versions and
[just](https://just.systems/) as a task runner.

```sh
mise install
go install github.com/nao1215/atago@latest
go install github.com/nao1215/himorime@latest
just check
just e2e
just integration
just bench
```

| Command | Tool | What it tests |
|---------|------|---------------|
| `just test` | gleeunit | Parser, validator, naming, config, collision detection |
| `just e2e` | atago | CLI behaviour, generated file trees, content snapshots, unsupported feature detection |
| `just integration` | gleeunit | Generated code compiles and the generated modules work together |
| `just bench` | himorime | Start-up, validate and generate on documents of 10 and 500 operations; pull requests are compared with their base ([bench/README.md](https://github.com/nao1215/oaspec/blob/main/bench/README.md)) |

## Testing

| Technique | Bug class caught here |
|---|---|
| Examples and unit tests | [Wrong parsing, validation and code generation per stage, on documents from other OpenAPI tools](https://github.com/nao1215/oaspec/blob/main/doc/testing.md#examples-and-unit-tests) |
| Generated properties | [Naming and argument helpers that break on unusual input](https://github.com/nao1215/oaspec/blob/main/doc/testing.md#generated-properties) |
| Metamorphic relations | [Generated code that depends on YAML vs JSON, key order or extension keys](https://github.com/nao1215/oaspec/blob/main/doc/testing.md#metamorphic-relations) |
| Golden files | [Unreviewed changes to the generated code](https://github.com/nao1215/oaspec/blob/main/doc/testing.md#golden-files) |
| End-to-end tests and output snapshots | [Wrong exit codes, messages and file trees of the shipped escript](https://github.com/nao1215/oaspec/blob/main/doc/testing.md#end-to-end-tests-and-output-snapshots) |
| Real documents | [Generated code that does not compile for large published documents](https://github.com/nao1215/oaspec/blob/main/doc/testing.md#real-documents) |
| Paired CI benchmarks | [Slower start-up, validate and generate](https://github.com/nao1215/oaspec/blob/main/doc/testing.md#paired-ci-benchmarks) |
| Mutation testing | [Branches of the generator that no test pins down](https://github.com/nao1215/oaspec/blob/main/doc/testing.md#mutation-testing) |

## License

[MIT](https://github.com/nao1215/oaspec/blob/main/LICENSE)
