import gleam/list
import gleam/option.{None, Some}
import gleam/string
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

fn echo_to_async_response() -> fn(Request) ->
  transport.Async(Result(Response, TransportError)) {
  fn(req: Request) {
    let base_url_header = case req.base_url {
      Some(url) -> [#("x-base-url", url)]
      None -> []
    }
    transport.resolve(
      Ok(Response(
        status: 200,
        headers: list.append(req.headers, base_url_header),
        body: TextBody(req.path),
      )),
    )
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

pub fn with_base_url_async_send_test() {
  let send =
    transport.with_base_url(echo_to_async_response(), "https://async.test")
  transport.run(send(empty_request()), fn(result) {
    let assert Ok(resp) = result
    resp.headers
    |> list.key_find("x-base-url")
    |> should.equal(Ok("https://async.test"))
  })
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

// Pin the documented "first occurrence wins" rule for duplicate names
// inside the supplied list. The reverse rule ("last wins") is more common
// in HTTP intuition, so the surprising-but-deterministic contract is
// exercised explicitly. (#547)
pub fn with_default_headers_first_occurrence_wins_for_duplicates_test() {
  let send =
    transport.with_default_headers(echo_to_response(), [
      #("X-Env", "staging"),
      #("X-Env", "prod"),
    ])
  let assert Ok(resp) = send(empty_request())
  resp.headers
  |> list.key_find("X-Env")
  |> should.equal(Ok("staging"))
}

pub fn with_default_headers_dedup_is_case_insensitive_test() {
  let send =
    transport.with_default_headers(echo_to_response(), [
      #("X-Env", "staging"),
      #("x-env", "prod"),
    ])
  let assert Ok(resp) = send(empty_request())
  resp.headers
  |> list.key_find("X-Env")
  |> should.equal(Ok("staging"))
  // The lower-case duplicate must not slip in under a different key.
  resp.headers
  |> list.key_find("x-env")
  |> should.equal(Error(Nil))
}

pub fn with_default_headers_first_wins_preserves_order_for_others_test() {
  // [#("X-A", "a"), #("X-B", "b"), #("X-A", "c")] — the second X-A is
  // dropped, but the X-B between them survives in input order.
  let send =
    transport.with_default_headers(echo_to_response(), [
      #("X-A", "a"),
      #("X-B", "b"),
      #("X-A", "c"),
    ])
  let assert Ok(resp) = send(empty_request())
  let kept =
    list.filter(resp.headers, fn(h) {
      let #(k, _) = h
      k == "X-A" || k == "X-B"
    })
  kept |> should.equal([#("X-A", "a"), #("X-B", "b")])
}

// Pin the wrapper-form composition rule: when two with_default_header
// wrappers target the same name, the OUTERMOST wrapper (the one most
// recently piped in) wins, because the request reaches it first. This
// is the inverse of the list-form rule above (#555).
pub fn with_default_header_outermost_wrapper_wins_for_same_name_test() {
  let send =
    echo_to_response()
    |> transport.with_default_header(name: "X-Trace", value: "v1")
    |> transport.with_default_header(name: "X-Trace", value: "v2")
  let assert Ok(resp) = send(empty_request())
  resp.headers
  |> list.key_find("X-Trace")
  |> should.equal(Ok("v2"))
}

pub fn with_default_header_outermost_wins_is_case_insensitive_test() {
  // Same composition rule, but the inner wrapper uses a lower-case
  // name. The outer wrapper still wins because the request reaches it
  // first; the inner wrapper sees the already-set header and skips.
  let send =
    echo_to_response()
    |> transport.with_default_header(name: "x-trace", value: "v1")
    |> transport.with_default_header(name: "X-Trace", value: "v2")
  let assert Ok(resp) = send(empty_request())
  resp.headers
  |> list.key_find("X-Trace")
  |> should.equal(Ok("v2"))
  // Lower-case duplicate must not slip in under a different key.
  resp.headers
  |> list.key_find("x-trace")
  |> should.equal(Error(Nil))
}

pub fn with_default_header_explicit_request_header_beats_all_wrappers_test() {
  // An explicit request header beats every wrapper layer regardless
  // of how many with_default_header calls are stacked above it.
  let send =
    echo_to_response()
    |> transport.with_default_header(name: "X-Trace", value: "wrapper-1")
    |> transport.with_default_header(name: "X-Trace", value: "wrapper-2")
  let req = Request(..empty_request(), headers: [#("X-Trace", "explicit")])
  let assert Ok(resp) = send(req)
  resp.headers
  |> list.key_find("X-Trace")
  |> should.equal(Ok("explicit"))
}

// Header value validation: CRLF / NUL injection (#546).

pub fn with_default_header_panics_on_cr_in_value_test() {
  let #(panicked, message) =
    capture_panic(fn() {
      let _ =
        transport.with_default_header(
          send: echo_to_response(),
          name: "X-Trace-Id",
          value: "abc\r\nX-Smuggled: yes",
        )
      Nil
    })
  should.be_true(panicked)
  should.be_true(string.contains(
    message,
    "oaspec.transport.with_default_header",
  ))
  should.be_true(string.contains(message, "CR"))
}

pub fn with_default_header_panics_on_lf_in_value_test() {
  let #(panicked, message) =
    capture_panic(fn() {
      let _ =
        transport.with_default_header(
          send: echo_to_response(),
          name: "X-Trace-Id",
          value: "abc\nX-Smuggled: yes",
        )
      Nil
    })
  should.be_true(panicked)
  should.be_true(string.contains(message, "LF"))
}

pub fn with_default_header_panics_on_nul_in_value_test() {
  let #(panicked, message) =
    capture_panic(fn() {
      let _ =
        transport.with_default_header(
          send: echo_to_response(),
          name: "X-Trace-Id",
          value: "abc\u{0000}def",
        )
      Nil
    })
  should.be_true(panicked)
  should.be_true(string.contains(message, "NUL"))
}

pub fn with_default_header_panics_on_cr_in_name_test() {
  let #(panicked, message) =
    capture_panic(fn() {
      let _ =
        transport.with_default_header(
          send: echo_to_response(),
          name: "X-Bad\r\nInjected",
          value: "ok",
        )
      Nil
    })
  should.be_true(panicked)
  should.be_true(string.contains(message, "header name"))
}

pub fn with_default_header_accepts_printable_ascii_test() {
  // Tab (\t) is allowed inside header values per RFC 9112 — only CR,
  // LF, and NUL are forbidden. All other printable ASCII passes.
  let send =
    transport.with_default_header(
      send: echo_to_response(),
      name: "X-Trace-Id",
      value: "abc-123 ~!@#$%^&*()_+\t",
    )
  let assert Ok(resp) = send(empty_request())
  resp.headers
  |> list.key_find("X-Trace-Id")
  |> should.equal(Ok("abc-123 ~!@#$%^&*()_+\t"))
}

pub fn with_default_headers_panics_on_invalid_value_test() {
  let #(panicked, message) =
    capture_panic(fn() {
      let _ =
        transport.with_default_headers(echo_to_response(), [
          #("X-OK", "fine"),
          #("X-Bad", "with\nnewline"),
        ])
      Nil
    })
  should.be_true(panicked)
  should.be_true(string.contains(
    message,
    "oaspec.transport.with_default_headers",
  ))
  should.be_true(string.contains(message, "X-Bad"))
  should.be_true(string.contains(message, "LF"))
}

@external(erlang, "oaspec_ffi", "capture_panic")
@external(javascript, "../oaspec_ffi.mjs", "capture_panic")
fn capture_panic(thunk: fn() -> Nil) -> #(Bool, String)

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
// async helpers
// ---------------------------------------------------------------------------

pub fn async_from_callback_and_map_test() {
  transport.from_callback(fn(done) { done(1) })
  |> transport.map(fn(value) { value + 1 })
  |> transport.run(fn(result) { result |> should.equal(2) })
}

pub fn async_await_test() {
  transport.resolve(1)
  |> transport.await(fn(value) { transport.resolve(value + 1) })
  |> transport.run(fn(result) { result |> should.equal(2) })
}

pub fn async_map_try_test() {
  transport.resolve(Ok(1))
  |> transport.map_try(fn(value) { Ok(value + 1) })
  |> transport.run(fn(result) { result |> should.equal(Ok(2)) })
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

pub fn mock_text_async_test() {
  let send = mock.text_async(200, "hello")
  transport.run(send(empty_request()), fn(result) {
    let assert Ok(resp) = result
    resp.status |> should.equal(200)
    resp.body |> should.equal(TextBody("hello"))
  })
}

pub fn mock_bytes_async_test() {
  let send = mock.bytes_async(201, <<1, 2, 3>>)
  transport.run(send(empty_request()), fn(result) {
    let assert Ok(resp) = result
    resp.status |> should.equal(201)
    resp.body |> should.equal(BytesBody(<<1, 2, 3>>))
  })
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

pub fn mock_empty_async_test() {
  let send = mock.empty_async(204)
  transport.run(send(empty_request()), fn(result) {
    let assert Ok(resp) = result
    resp.status |> should.equal(204)
    resp.body |> should.equal(EmptyBody)
  })
}

pub fn mock_timeout_test() {
  let send = mock.timeout()
  let assert Error(e) = send(empty_request())
  e |> should.equal(transport.Timeout)
}

pub fn mock_timeout_async_test() {
  let send = mock.timeout_async()
  transport.run(send(empty_request()), fn(result) {
    result |> should.equal(Error(transport.Timeout))
  })
}

pub fn mock_fail_test() {
  let send = mock.fail(transport.ConnectionFailed("boom"))
  let assert Error(e) = send(empty_request())
  e |> should.equal(transport.ConnectionFailed("boom"))
}

pub fn mock_fail_async_test() {
  let send = mock.fail_async(transport.ConnectionFailed("boom"))
  transport.run(send(empty_request()), fn(result) {
    result |> should.equal(Error(transport.ConnectionFailed("boom")))
  })
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

pub fn mock_from_async_inspects_request_test() {
  let send =
    mock.from_async(fn(req) {
      transport.resolve(
        Ok(Response(
          status: 200,
          headers: [#("x-method", method_to_string(req.method))],
          body: TextBody(req.path),
        )),
      )
    })
  transport.run(send(empty_request()), fn(result) {
    let assert Ok(resp) = result
    resp.body |> should.equal(TextBody("/pets"))
    resp.headers
    |> list.key_find("x-method")
    |> should.equal(Ok("GET"))
  })
}

pub fn async_try_await_short_circuits_error_test() {
  transport.resolve(Error("boom"))
  |> transport.try_await(fn(_value) { transport.resolve(Ok("should not run")) })
  |> transport.run(fn(result) { result |> should.equal(Error("boom")) })
}

// Issue #427: complementary halves of try_await / map_try.

pub fn async_try_await_chains_ok_test() {
  // Successful first stage flows into the second stage; both Ok values
  // are visible to the final continuation.
  transport.resolve(Ok(1))
  |> transport.try_await(fn(value) { transport.resolve(Ok(value + 1)) })
  |> transport.run(fn(result) { result |> should.equal(Ok(2)) })
}

pub fn async_map_try_short_circuits_error_test() {
  // Error skips the mapping function entirely.
  transport.resolve(Error("nope"))
  |> transport.map_try(fn(_value) { Ok(99) })
  |> transport.run(fn(result) { result |> should.equal(Error("nope")) })
}

// Issue #428: middleware composition has to keep working when wired
// against `AsyncSend`, not just sync `Send`. `with_base_url` is
// already covered above; mirror the rest.

pub fn with_default_header_async_send_test() {
  let send =
    transport.with_default_header(echo_to_async_response(), "x-trace", "abc")
  transport.run(send(empty_request()), fn(result) {
    let assert Ok(resp) = result
    resp.headers
    |> list.key_find("x-trace")
    |> should.equal(Ok("abc"))
  })
}

pub fn with_default_headers_async_send_test() {
  let send =
    transport.with_default_headers(echo_to_async_response(), [
      #("x-a", "1"),
      #("x-b", "2"),
    ])
  transport.run(send(empty_request()), fn(result) {
    let assert Ok(resp) = result
    resp.headers
    |> list.key_find("x-a")
    |> should.equal(Ok("1"))
    resp.headers
    |> list.key_find("x-b")
    |> should.equal(Ok("2"))
  })
}

pub fn with_security_async_send_test() {
  let creds =
    transport.credentials()
    |> transport.with_bearer_token("BearerAuth", "tok-async")
  let send = transport.with_security(echo_to_async_response(), creds)
  let req = with_security_alts([HttpAuthorization("BearerAuth", "Bearer")])
  transport.run(send(req), fn(result) {
    let assert Ok(resp) = result
    resp.headers
    |> list.key_find("authorization")
    |> should.equal(Ok("Bearer tok-async"))
  })
}
