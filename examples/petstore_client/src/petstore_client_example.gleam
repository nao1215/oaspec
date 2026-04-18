//// Runnable example: using the oaspec-generated Petstore client.
////
//// This program builds a client configuration, calls `list_pets`, and
//// prints the result. The `send` function is stubbed to return a canned
//// HTTP response so the example runs without needing a live Petstore
//// instance. In production code you would replace it with a real HTTP
//// transport (e.g. `gleam_httpc`, `mist`, `wisp`).

import api/client
import api/response_types
import api/types
import gleam/http/request
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}

pub fn main() {
  // 1. Build a client config. The `send` function is where you plug in a
  //    real HTTP transport. Here we return a canned JSON response so the
  //    example stays self-contained.
  let config = client.new(client.default_base_url(), stub_send)

  // 2. Call the generated `list_pets` client function.
  //    Arguments match the OpenAPI parameters; option types are optional.
  case client.list_pets(config, Some(10), None) {
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
    client.ConnectionError(detail) -> "connection: " <> detail
    client.TimeoutError -> "timeout"
    client.DecodeError(detail) -> "decode: " <> detail
  }
}

/// Canned HTTP send function — pretends the server returned two pets
/// regardless of the path, method, or query string of the incoming request.
/// This keeps the example self-contained; a real client would dispatch on
/// `req.path`/`req.method` and issue a real HTTP call.
fn stub_send(
  req: request.Request(String),
) -> Result(client.ClientResponse, client.ClientError) {
  let _ = req
  let body =
    "[
      {\"id\": 1, \"name\": \"Fido\", \"status\": \"available\", \"tag\": \"dog\"},
      {\"id\": 2, \"name\": \"Whiskers\", \"status\": \"pending\"}
    ]"
  Ok(client.ClientResponse(status: 200, body: body))
}
