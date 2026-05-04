# oaspec_fetch

JavaScript fetch transport adapter for `oaspec` generated clients,
backed by `gleam_fetch`.

`oaspec_fetch` bridges the runtime-agnostic `oaspec/transport.AsyncSend`
contract that `oaspec generate --mode=client` emits to the browser
fetch API on the JavaScript target. The root `oaspec` package does not
depend on any specific HTTP library; the transport is composed at the
call site by plugging this adapter (or your own) into the generated
client.

For the BEAM target, see the sibling `oaspec_httpc` adapter.

## Install

```sh
gleam add oaspec_fetch
```

## Quick start

```gleam
import api/client
import oaspec/fetch
import oaspec/transport

pub fn main() {
  let send =
    fetch.send
    |> transport.with_base_url(client.default_base_url())

  client.list_pets_async(send, limit: Some(10), offset: None)
  |> transport.run(fn(result) {
    let _ = result
    Nil
  })
}
```

The async client variants suffixed `_async` return a `transport.Async`
value that resolves once the underlying fetch promise settles. The
adapter exposes helpers to bridge `transport.Async` to native
JavaScript promises when the host needs to await the result outside
Gleam.

## Tests in the consumer

For unit tests of code that calls a generated async client, prefer
`oaspec/mock` over a real network. The adapter's `AsyncSend` shape
matches `mock.AsyncSend`, so test code substitutes one for the other
without touching the call sites.

## License

MIT. See the LICENSE file at the root of the oaspec repository.
