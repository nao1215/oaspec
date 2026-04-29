//// Test helpers for `oaspec/transport`. Each constructor returns a
//// `transport.Send` value that can be passed directly to a generated
//// client function, making it trivial to script fake responses in
//// unit tests without standing up a real HTTP runtime.

import oaspec/transport.{
  type Request, type Response, type Send, type TransportError, BytesBody,
  EmptyBody, Response, TextBody,
}

// Always respond with the given text body and status. Headers are empty.
pub fn text(status status: Int, body body: String) -> Send {
  fn(_req: Request) {
    Ok(Response(status: status, headers: [], body: TextBody(body)))
  }
}

// Always respond with the given binary body and status. Headers are empty.
pub fn bytes(status status: Int, body body: BitArray) -> Send {
  fn(_req: Request) {
    Ok(Response(status: status, headers: [], body: BytesBody(body)))
  }
}

// Always respond with the given status and an empty body.
pub fn empty(status status: Int) -> Send {
  fn(_req: Request) {
    Ok(Response(status: status, headers: [], body: EmptyBody))
  }
}

// Always fail with `transport.Timeout`.
pub fn timeout() -> Send {
  fn(_req: Request) { Error(transport.Timeout) }
}

// Always fail with the given `TransportError`.
pub fn fail(error error: TransportError) -> Send {
  fn(_req: Request) { Error(error) }
}

// Build a `Send` from an arbitrary handler — useful for asserting on
// the outbound request shape in tests.
pub fn from(
  handler handler: fn(Request) -> Result(Response, TransportError),
) -> Send {
  handler
}
