//// JavaScript fetch adapter for oaspec generated clients.
////
//// `oaspec/fetch` bridges the pure `oaspec/transport.AsyncSend` contract to
//// the JavaScript `fetch` API via `gleam_fetch`.

import gleam/bit_array
import gleam/fetch
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/javascript/promise
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import oaspec/transport

/// Convert a JavaScript promise into oaspec's cross-target async wrapper.
pub fn from_promise(promise promise_: promise.Promise(a)) -> transport.Async(a) {
  transport.from_callback(fn(done) {
    let _ = promise.tap(promise_, done)
    Nil
  })
}

/// Convert oaspec's async wrapper into a JavaScript promise.
pub fn to_promise(async async_: transport.Async(a)) -> promise.Promise(a) {
  promise.new(fn(done) { transport.run(async_, done) })
}

/// Convenience: same signature as `transport.AsyncSend`.
pub fn send(
  req: transport.Request,
) -> transport.Async(Result(transport.Response, transport.TransportError)) {
  do_send(req)
}

fn do_send(
  req: transport.Request,
) -> transport.Async(Result(transport.Response, transport.TransportError)) {
  case build_http_request(req) {
    Ok(http_req) ->
      fetch.send_bits(http_req)
      |> from_promise
      |> transport.try_await(read_fetch_response)
      |> transport.map(fn(result) {
        result |> result.map_error(fetch_error_to_transport_error)
      })
    Error(error) -> transport.resolve(Error(error))
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
    transport.Other(s) -> http.Other(s)
  }
}

fn read_fetch_response(
  resp: response.Response(fetch.FetchBody),
) -> transport.Async(Result(transport.Response, fetch.FetchError)) {
  case should_read_as_text(resp) {
    True ->
      fetch.read_text_body(resp)
      |> from_promise
      |> transport.map(fn(result) {
        result |> result.map(text_response_to_transport)
      })
    False ->
      fetch.read_bytes_body(resp)
      |> from_promise
      |> transport.map(fn(result) {
        result |> result.map(bytes_response_to_transport)
      })
  }
}

fn should_read_as_text(resp: response.Response(fetch.FetchBody)) -> Bool {
  case response.get_header(resp, "content-type") {
    Ok(ct) -> is_text_content_type(ct)
    Error(_) -> True
  }
}

fn text_response_to_transport(
  resp: response.Response(String),
) -> transport.Response {
  transport.Response(
    status: resp.status,
    headers: resp.headers,
    body: transport.TextBody(resp.body),
  )
}

fn bytes_response_to_transport(
  resp: response.Response(BitArray),
) -> transport.Response {
  transport.Response(
    status: resp.status,
    headers: resp.headers,
    body: transport.BytesBody(resp.body),
  )
}

fn fetch_error_to_transport_error(
  error: fetch.FetchError,
) -> transport.TransportError {
  case error {
    fetch.NetworkError(detail) -> transport.ConnectionFailed(detail: detail)
    fetch.UnableToReadBody ->
      transport.Unsupported(detail: "fetch response body could not be read")
    fetch.InvalidJsonBody ->
      transport.Unsupported(detail: "fetch response body was not valid JSON")
  }
}

fn is_text_content_type(ct: String) -> Bool {
  let lowered = string.lowercase(ct)
  string.contains(lowered, "json")
  || string.contains(lowered, "xml")
  || string.starts_with(lowered, "text/")
  || string.contains(lowered, "x-www-form-urlencoded")
}
