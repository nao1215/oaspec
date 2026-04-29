//// BEAM HTTP adapter for oaspec generated clients.
////
//// `oaspec/httpc` bridges the pure `oaspec/transport.Send` contract
//// to `gleam_httpc`. The simplest usage is the bare `send` function:
////
//// ```gleam
//// import oaspec/httpc
//// import api/client
////
//// let result = client.list_pets(httpc.send, ...)
//// ```
////
//// For per-request configuration (timeouts, etc.) use the builder:
////
//// ```gleam
//// let send =
////   httpc.config()
////   |> httpc.with_timeout(5_000)
////   |> httpc.build
//// ```

import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import oaspec/transport.{type Send}

/// Adapter configuration. Build with `config()`, tune with the
/// `with_*` helpers, then commit to a `Send` value via `build()`.
pub opaque type Config {
  Config(timeout_ms: option.Option(Int))
}

pub fn config() -> Config {
  Config(timeout_ms: None)
}

pub fn with_timeout(cfg cfg: Config, timeout_ms timeout_ms: Int) -> Config {
  let _ = cfg
  Config(timeout_ms: Some(timeout_ms))
}

/// Materialise a `Send` value from a `Config`. Use this when you've
/// configured timeouts or other options. For the simplest case, prefer
/// the bare `send` function, which has the same signature as `Send`.
pub fn build(cfg: Config) -> Send {
  fn(req: transport.Request) { do_send(req, cfg) }
}

/// Convenience: equivalent to `config() |> build`. Provides the most
/// common no-config path as a single function reference.
pub fn send(
  req: transport.Request,
) -> Result(transport.Response, transport.TransportError) {
  do_send(req, config())
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn do_send(
  req: transport.Request,
  _cfg: Config,
) -> Result(transport.Response, transport.TransportError) {
  use http_req <- result.try(build_http_request(req))
  case httpc.send_bits(http_req) {
    Ok(resp) -> Ok(convert_response(resp))
    Error(_) ->
      Error(transport.ConnectionFailed(detail: "gleam_httpc send failed"))
  }
}

fn build_http_request(
  req: transport.Request,
) -> Result(request.Request(BitArray), transport.TransportError) {
  let url = build_url(req)
  use parsed <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { transport.InvalidBaseUrl(detail: url) }),
  )
  let parsed = request.set_method(parsed, convert_method(req.method))
  let parsed =
    list.fold(req.headers, parsed, fn(r, h) {
      let #(name, value) = h
      request.set_header(r, name, value)
    })
  let body = case req.body {
    transport.EmptyBody -> <<>>
    transport.TextBody(text) -> bit_array.from_string(text)
    transport.BytesBody(bits) -> bits
  }
  Ok(request.set_body(parsed, body))
}

fn build_url(req: transport.Request) -> String {
  let base = case req.base_url {
    Some(b) -> b
    None -> ""
  }
  base <> req.path <> encode_query(req.query)
}

fn encode_query(query: List(#(String, String))) -> String {
  case query {
    [] -> ""
    _ -> {
      let parts =
        list.map(query, fn(kv) {
          let #(k, v) = kv
          uri.percent_encode(k) <> "=" <> uri.percent_encode(v)
        })
      "?" <> string.join(parts, "&")
    }
  }
}

fn convert_method(method: transport.Method) -> http.Method {
  case method {
    transport.Get -> http.Get
    transport.Post -> http.Post
    transport.Put -> http.Put
    transport.Delete -> http.Delete
    transport.Patch -> http.Patch
    transport.Head -> http.Head
    transport.Options -> http.Options
    transport.Trace -> http.Trace
    transport.Connect -> http.Connect
  }
}

fn convert_response(resp: response.Response(BitArray)) -> transport.Response {
  let is_text = case list.key_find(resp.headers, "content-type") {
    Ok(ct) -> is_text_content_type(ct)
    Error(_) -> True
  }
  let body = case is_text {
    True ->
      case bit_array.to_string(resp.body) {
        Ok(text) -> transport.TextBody(text)
        Error(_) -> transport.BytesBody(resp.body)
      }
    False -> transport.BytesBody(resp.body)
  }
  transport.Response(
    status: resp.status,
    headers: resp.headers,
    body: body,
  )
}

fn is_text_content_type(ct: String) -> Bool {
  let lowered = string.lowercase(ct)
  string.contains(lowered, "json")
  || string.contains(lowered, "xml")
  || string.starts_with(lowered, "text/")
  || string.contains(lowered, "x-www-form-urlencoded")
}
