import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import oaspec/mock
import oaspec/transport.{
  type Request, type Response, type TransportError, ApiKeyCookie, ApiKeyHeader,
  ApiKeyQuery, BytesBody, EmptyBody, Get, HttpAuthorization, Request, Response,
  SecurityAlternative, TextBody,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn empty_request() -> Request {
  Request(
    method: Get,
    base_url: None,
    path: "/pets",
    query: [],
    headers: [],
    body: EmptyBody,
    security: [],
  )
}

fn with_security_alts(reqs: List(transport.SecurityRequirement)) -> Request {
  Request(..empty_request(), security: [SecurityAlternative(reqs)])
}

// echo_to_response forwards relevant request attributes back as
// response so tests can assert on them.
fn echo_to_response() -> fn(Request) -> Result(Response, TransportError) {
  fn(req: Request) {
    let base_url_header = case req.base_url {
      Some(url) -> [#("x-base-url", url)]
      None -> []
    }
    Ok(Response(
      status: 200,
      headers: list.append(req.headers, base_url_header),
      body: TextBody(req.path),
    ))
  }
}

// echo_query_send encodes the request query as `k=v&k=v` in the body
// so query-mutation tests can assert on the wire shape.
fn echo_query_send() -> fn(Request) -> Result(Response, TransportError) {
  fn(req: Request) {
    let encoded =
      req.query
      |> list.map(fn(kv) {
        let #(k, v) = kv
        k <> "=" <> v
      })
      |> list_join("&")
    Ok(Response(status: 200, headers: req.headers, body: TextBody(encoded)))
  }
}

fn list_join(items: List(String), sep: String) -> String {
  case items {
    [] -> ""
    [first, ..rest] -> list.fold(rest, first, fn(acc, s) { acc <> sep <> s })
  }
}

fn method_to_string(method: transport.Method) -> String {
  case method {
    transport.Get -> "GET"
    transport.Post -> "POST"
    transport.Put -> "PUT"
    transport.Delete -> "DELETE"
    transport.Patch -> "PATCH"
    transport.Head -> "HEAD"
    transport.Options -> "OPTIONS"
    transport.Trace -> "TRACE"
    transport.Connect -> "CONNECT"
  }
}

// ---------------------------------------------------------------------------
// with_base_url
// ---------------------------------------------------------------------------

pub fn with_base_url_overrides_request_test() {
  let send =
    transport.with_base_url(echo_to_response(), "https://override.test")
  let req = Request(..empty_request(), base_url: Some("https://original.test"))
  let assert Ok(resp) = send(req)
  resp.headers
  |> list.key_find("x-base-url")
  |> should.equal(Ok("https://override.test"))
}

pub fn with_base_url_sets_when_missing_test() {
  let send = transport.with_base_url(echo_to_response(), "https://api.test")
  let assert Ok(resp) = send(empty_request())
  resp.headers
  |> list.key_find("x-base-url")
  |> should.equal(Ok("https://api.test"))
}

// ---------------------------------------------------------------------------
// with_default_header
// ---------------------------------------------------------------------------

pub fn with_default_header_injects_when_missing_test() {
  let send =
    transport.with_default_header(echo_to_response(), "x-trace-id", "abc-123")
  let assert Ok(resp) = send(empty_request())
  resp.headers
  |> list.key_find("x-trace-id")
  |> should.equal(Ok("abc-123"))
}

pub fn with_default_header_preserves_explicit_test() {
  let send =
    transport.with_default_header(echo_to_response(), "X-Trace-Id", "default")
  let req = Request(..empty_request(), headers: [#("x-trace-id", "explicit")])
  let assert Ok(resp) = send(req)
  resp.headers
  |> list.key_find("x-trace-id")
  |> should.equal(Ok("explicit"))
}

// ---------------------------------------------------------------------------
// with_default_headers
// ---------------------------------------------------------------------------

pub fn with_default_headers_preserves_order_test() {
  let send =
    transport.with_default_headers(echo_to_response(), [
      #("x-a", "1"),
      #("x-b", "2"),
      #("x-c", "3"),
    ])
  let assert Ok(resp) = send(empty_request())
  let names =
    list.filter(resp.headers, fn(h) {
      let #(k, _) = h
      k == "x-a" || k == "x-b" || k == "x-c"
    })
  names |> should.equal([#("x-a", "1"), #("x-b", "2"), #("x-c", "3")])
}

pub fn with_default_headers_skips_existing_test() {
  let send =
    transport.with_default_headers(echo_to_response(), [
      #("X-A", "default"),
      #("x-b", "default"),
    ])
  let req = Request(..empty_request(), headers: [#("x-a", "explicit")])
  let assert Ok(resp) = send(req)
  resp.headers
  |> list.key_find("x-a")
  |> should.equal(Ok("explicit"))
  resp.headers
  |> list.key_find("x-b")
  |> should.equal(Ok("default"))
}

// ---------------------------------------------------------------------------
// with_security: bearer
// ---------------------------------------------------------------------------

pub fn with_security_bearer_token_test() {
  let creds =
    transport.credentials()
    |> transport.with_bearer_token("BearerAuth", "tok-abc")
  let send = transport.with_security(echo_to_response(), creds)
  let req = with_security_alts([HttpAuthorization("BearerAuth", "Bearer")])
  let assert Ok(resp) = send(req)
  resp.headers
  |> list.key_find("authorization")
  |> should.equal(Ok("Bearer tok-abc"))
}

pub fn with_security_basic_auth_test() {
  let creds =
    transport.credentials()
    |> transport.with_basic_auth("BasicAuth", "dXNlcjpwYXNz")
  let send = transport.with_security(echo_to_response(), creds)
  let req = with_security_alts([HttpAuthorization("BasicAuth", "Basic")])
  let assert Ok(resp) = send(req)
  resp.headers
  |> list.key_find("authorization")
  |> should.equal(Ok("Basic dXNlcjpwYXNz"))
}

pub fn with_security_digest_auth_test() {
  let creds =
    transport.credentials()
    |> transport.with_digest_auth("DigestAuth", "digest-value")
  let send = transport.with_security(echo_to_response(), creds)
  let req = with_security_alts([HttpAuthorization("DigestAuth", "Digest")])
  let assert Ok(resp) = send(req)
  resp.headers
  |> list.key_find("authorization")
  |> should.equal(Ok("Digest digest-value"))
}

// ---------------------------------------------------------------------------
// with_security: api key locations
// ---------------------------------------------------------------------------

pub fn with_security_api_key_header_test() {
  let creds =
    transport.credentials()
    |> transport.with_api_key("ApiKeyAuth", "key-123")
  let send = transport.with_security(echo_to_response(), creds)
  let req = with_security_alts([ApiKeyHeader("ApiKeyAuth", "X-API-Key")])
  let assert Ok(resp) = send(req)
  resp.headers
  |> list.key_find("X-API-Key")
  |> should.equal(Ok("key-123"))
}

pub fn with_security_api_key_query_test() {
  let creds =
    transport.credentials()
    |> transport.with_api_key("ApiKeyAuth", "key-q")
  let send = transport.with_security(echo_query_send(), creds)
  let req =
    Request(
      ..with_security_alts([ApiKeyQuery("ApiKeyAuth", "api_key")]),
      query: [#("limit", "10")],
    )
  let assert Ok(resp) = send(req)
  resp.body
  |> should.equal(TextBody("limit=10&api_key=key-q"))
}

pub fn with_security_api_key_cookie_merges_test() {
  let creds =
    transport.credentials()
    |> transport.with_api_key("ApiKeyAuth", "k")
  let send = transport.with_security(echo_to_response(), creds)
  let req =
    Request(
      ..with_security_alts([ApiKeyCookie("ApiKeyAuth", "session")]),
      headers: [#("cookie", "tracking=abc")],
    )
  let assert Ok(resp) = send(req)
  resp.headers
  |> list.key_find("Cookie")
  |> should.equal(Ok("tracking=abc; session=k"))
}

// ---------------------------------------------------------------------------
// with_security: OR / AND semantics
// ---------------------------------------------------------------------------

pub fn with_security_or_picks_first_satisfiable_test() {
  // Only the second alternative (ApiKey) is satisfiable.
  let creds =
    transport.credentials()
    |> transport.with_api_key("ApiKeyAuth", "k")
  let send = transport.with_security(echo_to_response(), creds)
  let req =
    Request(..empty_request(), security: [
      SecurityAlternative([HttpAuthorization("BearerAuth", "Bearer")]),
      SecurityAlternative([ApiKeyHeader("ApiKeyAuth", "X-API-Key")]),
    ])
  let assert Ok(resp) = send(req)
  resp.headers
  |> list.key_find("authorization")
  |> should.equal(Error(Nil))
  resp.headers
  |> list.key_find("X-API-Key")
  |> should.equal(Ok("k"))
}

pub fn with_security_and_applies_all_test() {
  let creds =
    transport.credentials()
    |> transport.with_bearer_token("BearerAuth", "tok")
    |> transport.with_api_key("ApiKeyAuth", "k")
  let send = transport.with_security(echo_to_response(), creds)
  let req =
    Request(..empty_request(), security: [
      SecurityAlternative([
        HttpAuthorization("BearerAuth", "Bearer"),
        ApiKeyHeader("ApiKeyAuth", "X-API-Key"),
      ]),
    ])
  let assert Ok(resp) = send(req)
  resp.headers
  |> list.key_find("authorization")
  |> should.equal(Ok("Bearer tok"))
  resp.headers
  |> list.key_find("X-API-Key")
  |> should.equal(Ok("k"))
}

pub fn with_security_no_match_passes_through_test() {
  let creds = transport.credentials()
  let send = transport.with_security(echo_to_response(), creds)
  let req = with_security_alts([HttpAuthorization("BearerAuth", "Bearer")])
  let assert Ok(resp) = send(req)
  resp.headers
  |> list.key_find("authorization")
  |> should.equal(Error(Nil))
}

pub fn with_security_query_appends_to_existing_test() {
  let creds =
    transport.credentials()
    |> transport.with_api_key("ApiKeyAuth", "k1")
  let send = transport.with_security(echo_query_send(), creds)
  let req =
    Request(
      ..with_security_alts([ApiKeyQuery("ApiKeyAuth", "api_key")]),
      query: [#("a", "1"), #("b", "2")],
    )
  let assert Ok(resp) = send(req)
  resp.body
  |> should.equal(TextBody("a=1&b=2&api_key=k1"))
}

// ---------------------------------------------------------------------------
// mock module
// ---------------------------------------------------------------------------

pub fn mock_text_test() {
  let send = mock.text(200, "hello")
  let assert Ok(resp) = send(empty_request())
  resp.status |> should.equal(200)
  resp.body |> should.equal(TextBody("hello"))
}

pub fn mock_bytes_test() {
  let send = mock.bytes(201, <<1, 2, 3>>)
  let assert Ok(resp) = send(empty_request())
  resp.status |> should.equal(201)
  resp.body |> should.equal(BytesBody(<<1, 2, 3>>))
}

pub fn mock_empty_test() {
  let send = mock.empty(204)
  let assert Ok(resp) = send(empty_request())
  resp.status |> should.equal(204)
  resp.body |> should.equal(EmptyBody)
}

pub fn mock_timeout_test() {
  let send = mock.timeout()
  let assert Error(e) = send(empty_request())
  e |> should.equal(transport.Timeout)
}

pub fn mock_fail_test() {
  let send = mock.fail(transport.ConnectionFailed("boom"))
  let assert Error(e) = send(empty_request())
  e |> should.equal(transport.ConnectionFailed("boom"))
}

pub fn mock_from_inspects_request_test() {
  let send =
    mock.from(fn(req) {
      Ok(Response(
        status: 200,
        headers: [#("x-method", method_to_string(req.method))],
        body: TextBody(req.path),
      ))
    })
  let assert Ok(resp) = send(empty_request())
  resp.body |> should.equal(TextBody("/pets"))
  resp.headers
  |> list.key_find("x-method")
  |> should.equal(Ok("GET"))
}
