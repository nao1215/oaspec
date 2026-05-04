# oaspec_httpc

BEAM HTTP transport adapter for `oaspec` generated clients, backed by
`gleam_httpc`.

`oaspec_httpc` bridges the runtime-agnostic `oaspec/transport.Send`
contract that `oaspec generate --mode=client` emits to a real HTTP
implementation on the BEAM. The root `oaspec` package does not depend
on any specific HTTP library; the transport is composed at the call
site by plugging this adapter (or your own) into the generated client.

For the JavaScript target, see the sibling `oaspec_fetch` adapter.

## Install

```sh
gleam add oaspec_httpc
```

## Quick start

```gleam
import api/client
import oaspec/httpc
import oaspec/transport

pub fn main() {
  let send =
    httpc.send
    |> transport.with_base_url(client.default_base_url())

  let assert Ok(pets) = client.list_pets(send, limit: Some(10), offset: None)
}
```

The bare `httpc.send` is the simplest path. For per-request
configuration such as timeouts, build a `Send` value with `config()`
and the `with_*` helpers, then call `build()`:

```gleam
import oaspec/httpc

let send =
  httpc.config()
  |> httpc.with_timeout(5_000)
  |> httpc.build
```

## Tests in the consumer

For unit tests of code that calls a generated client, prefer
`oaspec/mock` over a real network. The adapter's `Send` shape matches
`mock.Send`, so test code substitutes one for the other without
touching the call sites:

```gleam
import oaspec/mock

let send = mock.text(200, "[{\"id\": 1, \"name\": \"Fido\"}]")
let assert Ok(_) = client.list_pets(send, limit: None, offset: None)
```

## License

MIT. See the LICENSE file at the root of the oaspec repository.
