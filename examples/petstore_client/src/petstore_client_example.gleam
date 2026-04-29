//// Runnable example: using the oaspec-generated Petstore client.
////
//// This program calls `list_pets` against a fake transport built with
//// `oaspec/mock`, then prints the result. Replace `mock.from(...)` with
//// a real transport adapter (e.g. `oaspec/httpc`) to talk to a live
//// Petstore.

import api/client
import api/response_types
import api/types
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import oaspec/mock
import oaspec/transport

pub fn main() {
  // The transport.Send value is the only thing client functions need.
  // Here we build a mock that returns a canned 200 response with two pets,
  // so the example runs without needing a live Petstore instance.
  let send = mock.from(stub_handler)

  case client.list_pets(send, Some(10), None) {
    Ok(response_types.ListPetsResponseOk(pets)) -> print_pets(pets)
    Ok(response_types.ListPetsResponseUnauthorized) ->
      io.println("server returned 401 Unauthorized")
    Error(err) -> io.println("client error: " <> describe(err))
  }
}

fn print_pets(pets: List(types.Pet)) -> Nil {
  io.println("Got " <> int.to_string(list.length(pets)) <> " pet(s):")
  list.each(pets, fn(pet) {
    io.println("  - " <> pet.name <> " (id=" <> int.to_string(pet.id) <> ")")
  })
}

fn describe(err: client.ClientError) -> String {
  case err {
    client.TransportError(error: e) -> "transport: " <> describe_transport(e)
    client.DecodeFailure(detail:) -> "decode: " <> detail
    client.InvalidResponse(detail:) -> "invalid response: " <> detail
    client.UnexpectedStatus(status:, headers: _, body: _) ->
      "unexpected status: " <> int.to_string(status)
  }
}

fn describe_transport(err: transport.TransportError) -> String {
  case err {
    transport.ConnectionFailed(detail:) -> "connection: " <> detail
    transport.Timeout -> "timeout"
    transport.InvalidBaseUrl(detail:) -> "invalid base url: " <> detail
    transport.TlsFailure(detail:) -> "tls: " <> detail
    transport.Unsupported(detail:) -> "unsupported: " <> detail
  }
}

/// Stub handler — pretends the server returned two pets regardless of
/// path/method/query. A real transport would dispatch on `req.method`,
/// `req.path`, etc., and issue an actual HTTP call.
fn stub_handler(
  req: transport.Request,
) -> Result(transport.Response, transport.TransportError) {
  let _ = req
  let body =
    "[
      {\"id\": 1, \"name\": \"Fido\", \"status\": \"available\", \"tag\": \"dog\"},
      {\"id\": 2, \"name\": \"Whiskers\", \"status\": \"pending\"}
    ]"
  Ok(transport.Response(
    status: 200,
    headers: [#("content-type", "application/json")],
    body: transport.TextBody(body),
  ))
}
