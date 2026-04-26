//// Runnable example: wiring the oaspec-generated `router.route/5` into a
//// minimal adapter.
////
//// The generated router is HTTP-framework-agnostic: it takes the primitive
//// pieces of a request (method, path segments, query, headers, body) and
//// returns a `ServerResponse`. That shape is easy to bridge to any real
//// Gleam HTTP stack (`wisp`, `mist`, etc.) — the mapping is always the
//// same shape:
////
////   1. Turn the incoming HTTP request into method + path segments +
////      query dict + headers dict + body string.
////   2. Call `router.route(...)`.
////   3. Render the returned `ServerResponse` back into the framework's
////      response type.
////
//// This program does that with a *canned* request/response pair so the
//// example runs without starting a real HTTP server. Replace
//// `canned_request` with a real adapter in production.

import api/handlers
import api/router
import gleam/dict
import gleam/int
import gleam/io
import gleam/list

pub fn main() {
  // 1. Build the application state once. Real applications would put
  //    DB connection pools, configuration, loggers, etc. here.
  let state = handlers.State

  // 2. Build a canned request. In production this would come from
  //    `wisp.Request` / `mist.Request` / similar.
  let #(method, path, query, headers, body) = canned_request()

  // 3. Delegate routing + dispatch to the generated router. The state
  //    is threaded into every handler invocation.
  let response = router.route(state, method, path, query, headers, body)

  // 3. Render the response. A real adapter would turn `ServerResponse`
  //    into the framework's response value; here we just print it.
  print_response(response)
}

fn canned_request() -> #(
  String,
  List(String),
  dict.Dict(String, List(String)),
  dict.Dict(String, String),
  String,
) {
  #("GET", ["pets"], dict.new(), dict.new(), "")
}

fn print_response(response: router.ServerResponse) -> Nil {
  io.println("status: " <> int.to_string(response.status))
  let header_count = list.length(response.headers)
  io.println("headers: " <> int.to_string(header_count) <> " header(s)")
  io.println("body: " <> response.body)
}
