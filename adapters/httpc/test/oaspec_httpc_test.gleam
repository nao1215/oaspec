import gleam/int
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import oaspec/httpc
import oaspec/transport

pub fn main() -> Nil {
  gleeunit.main()
}

@external(erlang, "oaspec_httpc_test_ffi", "silent_server")
fn silent_server() -> Int

@external(erlang, "oaspec_httpc_test_ffi", "closed_port")
fn closed_port() -> Int

fn get(port: Int) -> transport.Request {
  transport.Request(
    method: transport.Get,
    base_url: Some("http://127.0.0.1:" <> int.to_string(port)),
    path: "/",
    query: [],
    headers: [],
    body: transport.EmptyBody,
    security: [],
  )
}

pub fn with_timeout_returns_timeout_when_the_server_never_answers_test() {
  let send =
    httpc.config()
    |> httpc.with_timeout(200)
    |> httpc.build
  send(get(silent_server()))
  |> should.equal(Error(transport.Timeout))
}

pub fn refused_connection_is_connection_failed_test() {
  case httpc.send(get(closed_port())) {
    Error(transport.ConnectionFailed(_)) -> Nil
    other -> should.equal(other, Error(transport.ConnectionFailed("")))
  }
}
