# Server adapters

Generated server code is the dual of the client side: the codegen emits a
single pure router function, and adapters bridge it to a real HTTP
framework. `api/router.route/6` takes the primitive pieces of a
request — `state`, `method`, `path`, `query`, `headers`, `body` — and
returns a `ServerResponse` whose `body` is a sum
(`TextBody(String)`, `BytesBody(BitArray)`, `EmptyBody`), so binary
endpoints carry real bytes through without a `String` round-trip.

The same shape works for any Gleam HTTP stack: decompose the framework's
request into the six primitives, call `router.route(...)`, render the
returned `ServerResponse` back into the framework's response type. The
router is pure and synchronous, so it is also trivial to test in isolation
without an HTTP server — see [`examples/server_adapter`](../examples/server_adapter/)
for a framework-free runnable example.

## `mist`

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

## `wisp`

The same shape applies: decompose `wisp.Request`, call
`oas_router.route(...)`, render the `ServerResponse` back into a
`wisp.Response`. Use `wisp.read_body_to_bitstring(...)` for the body and
`wisp.json_response(...)` / `wisp.bytes_tree(...)` for the response.

## Binary request bodies

If any operation in your spec declares `application/octet-stream` on its
request body, the generated router signature is `body: BitArray` (not
`String`) so arbitrary binary payloads round-trip without going through
`bit_array.to_string`. In that case drop the
`|> bit_array.to_string |> result.unwrap("")` step from the snippet above
and pass `mist.read_body(...).body` directly to `oas_router.route(...)`.
The router internally converts to `String` for the non-binary arms.
([#485](https://github.com/nao1215/oaspec/issues/485))
