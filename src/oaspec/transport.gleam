//// The runtime contract between generated OpenAPI clients and an HTTP
//// runtime.
////
//// Generated client code builds a `Request` and hands it to a `Send` (or an
//// `AsyncSend`) function. Adapters such as `oaspec_httpc` and `oaspec_fetch`
//// provide that function for a real runtime; in tests any function of the
//// same shape works:
////
//// ```gleam
//// let send = fn(_request) {
////   Ok(transport.Response(status: 200, headers: [], body: transport.TextBody("[]")))
//// }
//// ```
////
//// The `with_*` functions wrap a send function to add a base URL, default
//// headers or credentials. They work with both `Send` and `AsyncSend`.

import gleam/bool
import gleam/http.{type Method}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The body of a request or a response.
pub type Body {
  /// No body.
  EmptyBody
  /// A UTF-8 text body, such as JSON or form data.
  TextBody(String)
  /// A binary body.
  BytesBody(BitArray)
}

/// One credential an operation needs, as declared by an OpenAPI security
/// scheme. `scheme_name` is the key of the scheme under
/// `components.securitySchemes`, and `with_security` matches on it.
pub type SecurityRequirement {
  /// An API key sent in the named header.
  ApiKeyHeader(scheme_name: String, header_name: String)
  /// An API key sent in the named query parameter.
  ApiKeyQuery(scheme_name: String, query_name: String)
  /// An API key sent in the named cookie.
  ApiKeyCookie(scheme_name: String, cookie_name: String)
  /// An `Authorization` header with the given scheme prefix, such as
  /// `Bearer` or `Basic`.
  HttpAuthorization(scheme_name: String, prefix: String)
}

/// A set of security requirements that must all be met together.
///
/// A request lists the alternatives its operation accepts; meeting any one
/// of them is enough.
pub type SecurityAlternative {
  SecurityAlternative(requirements: List(SecurityRequirement))
}

/// A credential for one OpenAPI security scheme, passed to `with_security`.
pub type Credential {
  /// An API key, sent wherever the scheme says (header, query or cookie).
  ApiKey(scheme_name: String, value: String)
  /// A bearer token, sent as `Authorization: Bearer <token>`.
  BearerToken(scheme_name: String, token: String)
  /// Basic credentials, already Base64 encoded, sent as
  /// `Authorization: Basic <value>`.
  BasicAuth(scheme_name: String, value: String)
  /// Digest credentials, sent as `Authorization: Digest <value>`.
  DigestAuth(scheme_name: String, value: String)
}

/// A request built by a generated client.
pub type Request {
  Request(
    method: Method,
    /// The base URL from the spec's `servers`, if the client chose one.
    /// `with_base_url` replaces it.
    base_url: Option(String),
    /// The path with its parameters already filled in, such as `/pets/42`.
    path: String,
    query: List(#(String, String)),
    headers: List(#(String, String)),
    body: Body,
    /// The security alternatives the operation accepts. `with_security`
    /// reads this to decide which credentials to send.
    security: List(SecurityAlternative),
  )
}

/// A response returned by a send function.
pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: Body)
}

/// A failure to get any response from the server.
///
/// Error statuses such as 404 or 500 are responses, not transport errors.
pub type TransportError {
  /// The connection could not be made or was lost.
  ConnectionFailed(detail: String)
  /// The request did not finish in time.
  Timeout
  /// The base URL could not be parsed.
  InvalidBaseUrl(detail: String)
  /// The TLS handshake failed.
  TlsFailure(detail: String)
  /// The runtime cannot send this request, such as a body type it does
  /// not handle.
  Unsupported(detail: String)
}

/// A function that sends a request and waits for the response.
pub type Send =
  fn(Request) -> Result(Response, TransportError)

/// A function that sends a request and returns the response later.
pub type AsyncSend =
  fn(Request) -> Async(Result(Response, TransportError))

/// A value that will be ready later, used by generated async clients.
///
/// It runs on every target: JavaScript adapters back it with promises, and
/// other runtimes can bridge it from callbacks.
pub opaque type Async(value) {
  Async(register: fn(fn(value) -> Nil) -> Nil)
}

/// Creates an `Async` from a function that calls its argument once the
/// value is ready.
///
/// ## Examples
///
/// ```gleam
/// transport.from_callback(register: fn(done) { done(1) })
/// // -> an Async that yields 1
/// ```
///
pub fn from_callback(
  register register: fn(fn(value) -> Nil) -> Nil,
) -> Async(value) {
  Async(register)
}

/// Returns an `Async` that is already ready with the given value.
///
/// ## Examples
///
/// ```gleam
/// transport.resolve(value: Ok(response))
/// ```
///
pub fn resolve(value value: a) -> Async(a) {
  Async(fn(done) { done(value) })
}

/// Calls `done` with the value once it is ready.
///
pub fn run(async async: Async(a), done done: fn(a) -> Nil) -> Nil {
  let Async(register) = async
  register(done)
}

/// Transforms the value once it is ready.
///
/// ## Examples
///
/// ```gleam
/// transport.resolve(value: 1)
/// |> transport.map(with: fn(x) { x + 1 })
/// // -> an Async that yields 2
/// ```
///
pub fn map(async async: Async(a), with with_: fn(a) -> b) -> Async(b) {
  Async(fn(done) { run(async: async, done: fn(value) { done(with_(value)) }) })
}

/// Waits for the value and then for the `Async` that `next` returns from
/// it.
///
pub fn await(async async: Async(a), next next: fn(a) -> Async(b)) -> Async(b) {
  Async(fn(done) {
    run(async: async, done: fn(value) { run(async: next(value), done: done) })
  })
}

/// Transforms an `Ok` value once it is ready. An `Error` is passed through
/// and `with` is not called.
///
/// ## Examples
///
/// ```gleam
/// transport.resolve(value: Ok(1))
/// |> transport.map_try(with: fn(x) { Ok(x + 1) })
/// // -> an Async that yields Ok(2)
/// ```
///
/// ```gleam
/// transport.resolve(value: Error(transport.Timeout))
/// |> transport.map_try(with: fn(x) { Ok(x + 1) })
/// // -> an Async that yields Error(transport.Timeout)
/// ```
///
pub fn map_try(
  async async: Async(Result(a, error)),
  with with_: fn(a) -> Result(b, error),
) -> Async(Result(b, error)) {
  async
  |> map(fn(result) {
    case result {
      Ok(value) -> with_(value)
      Error(error) -> Error(error)
    }
  })
}

/// Waits for an `Ok` value and then for the `Async` that `next` returns
/// from it. An `Error` is passed through and `next` is not called.
///
pub fn try_await(
  async async: Async(Result(a, error)),
  next next: fn(a) -> Async(Result(b, error)),
) -> Async(Result(b, error)) {
  async
  |> await(fn(result) {
    case result {
      Ok(value) -> next(value)
      Error(error) -> resolve(value: Error(error))
    }
  })
}

/// Wraps a send function so every request goes to `base_url`, replacing
/// the base URL the client chose from the spec.
///
/// ## Examples
///
/// ```gleam
/// let send = httpc.send |> transport.with_base_url("https://staging.example.com")
/// ```
///
pub fn with_base_url(
  send send: fn(Request) -> a,
  base_url base_url: String,
) -> fn(Request) -> a {
  fn(req: Request) { send(Request(..req, base_url: Some(base_url))) }
}

/// Wraps a send function so each request gets the given headers when it
/// does not already have them.
///
/// Header names are compared case-insensitively. A header already on the
/// request is kept, and when `headers` names the same header twice the
/// first entry is used.
///
/// ## Examples
///
/// ```gleam
/// let send =
///   httpc.send
///   |> transport.with_default_headers([#("user-agent", "my-app/1.0")])
/// ```
///
/// ## Panics
///
/// Panics when a header name or value contains CR, LF or NUL, since those
/// bytes allow header injection. The check runs when the wrapper is built,
/// not on each request.
///
pub fn with_default_headers(
  send send: fn(Request) -> a,
  headers headers: List(#(String, String)),
) -> fn(Request) -> a {
  list.each(headers, fn(kv) {
    let #(name, value) = kv
    validate_header_name(name: name)
    validate_header_value(name: name, value: value)
  })
  fn(req: Request) {
    // Build with prepend + final reverse so the fold is O(N) over the
    // header list. has_header is a name lookup, so checking against the
    // reversed accumulator keeps the first-occurrence rule.
    let merged_rev =
      list.fold(headers, list.reverse(req.headers), fn(acc_rev, kv) {
        let #(name, value) = kv
        case has_header(acc_rev, name) {
          True -> acc_rev
          False -> [#(name, value), ..acc_rev]
        }
      })
    send(Request(..req, headers: list.reverse(merged_rev)))
  }
}

/// Wraps a send function so each request carries the credentials its
/// operation asks for.
///
/// The first security alternative of the request whose requirements all
/// have a matching credential (by `scheme_name` and kind) is applied: API
/// keys go to the declared header, query parameter or cookie, and the
/// other credentials go to the `Authorization` header. When no alternative
/// can be met the request is sent unchanged, and the server's rejection
/// comes back as a normal response.
///
/// ## Examples
///
/// ```gleam
/// let send =
///   httpc.send
///   |> transport.with_security([transport.BearerToken("bearerAuth", token)])
/// ```
///
pub fn with_security(
  send send: fn(Request) -> a,
  credentials credentials: List(Credential),
) -> fn(Request) -> a {
  fn(req: Request) {
    let prepared = case pick_alternative(req.security, credentials) {
      Some(alt) -> apply_alternative(req: req, alt: alt, creds: credentials)
      None -> req
    }
    send(prepared)
  }
}

fn has_header(headers: List(#(String, String)), name: String) -> Bool {
  let lowered = string.lowercase(name)
  list.any(headers, fn(h) {
    let #(k, _) = h
    string.lowercase(k) == lowered
  })
}

fn validate_header_name(name name: String) -> Nil {
  case forbidden_byte(name) {
    None -> Nil
    Some(byte_label) ->
      panic as {
        "oaspec.transport.with_default_headers: header name contains forbidden control byte "
        <> byte_label
        <> " — header names must not include CR, LF, or NUL"
      }
  }
}

// CR / LF / NUL in a header value enable response splitting and header
// injection once they reach the wire (RFC 9112 §2.2).
fn validate_header_value(name name: String, value value: String) -> Nil {
  case forbidden_byte(value) {
    None -> Nil
    Some(byte_label) ->
      panic as {
        "oaspec.transport.with_default_headers: header value for `"
        <> name
        <> "` contains forbidden control byte "
        <> byte_label
        <> " (CR/LF/NUL enable header injection per RFC 9112 §2.2);"
        <> " pre-encode binary values via Base64 or RFC 8187"
      }
  }
}

fn forbidden_byte(s: String) -> Option(String) {
  use <- bool.guard(string.contains(s, "\r"), Some("CR (\\r)"))
  use <- bool.guard(string.contains(s, "\n"), Some("LF (\\n)"))
  use <- bool.guard(string.contains(s, "\u{0000}"), Some("NUL (\\u{0000})"))
  None
}

fn pick_alternative(
  alts: List(SecurityAlternative),
  creds: List(Credential),
) -> Option(SecurityAlternative) {
  case alts {
    [] -> None
    [alt, ..rest] ->
      case satisfiable(alt, creds) {
        True -> Some(alt)
        False -> pick_alternative(rest, creds)
      }
  }
}

fn satisfiable(alt: SecurityAlternative, creds: List(Credential)) -> Bool {
  list.all(alt.requirements, fn(req) { find_credential(creds, req) != None })
}

fn find_credential(
  creds: List(Credential),
  req: SecurityRequirement,
) -> Option(Credential) {
  list.find(creds, fn(c) { credential_matches(c, req) })
  |> option.from_result
}

fn credential_matches(cred: Credential, req: SecurityRequirement) -> Bool {
  case cred, req {
    ApiKey(s, _), ApiKeyHeader(t, _) if s == t -> True
    ApiKey(s, _), ApiKeyQuery(t, _) if s == t -> True
    ApiKey(s, _), ApiKeyCookie(t, _) if s == t -> True
    BearerToken(s, _), HttpAuthorization(t, prefix) if s == t ->
      string.lowercase(prefix) == "bearer"
    BasicAuth(s, _), HttpAuthorization(t, prefix) if s == t ->
      string.lowercase(prefix) == "basic"
    DigestAuth(s, _), HttpAuthorization(t, prefix) if s == t ->
      string.lowercase(prefix) == "digest"
    _, _ -> False
  }
}

fn apply_alternative(
  req req: Request,
  alt alt: SecurityAlternative,
  creds creds: List(Credential),
) -> Request {
  list.fold(alt.requirements, req, fn(acc, requirement) {
    case find_credential(creds, requirement) {
      Some(cred) -> apply_one(req: acc, requirement: requirement, cred: cred)
      None -> acc
    }
  })
}

fn apply_one(
  req req: Request,
  requirement requirement: SecurityRequirement,
  cred cred: Credential,
) -> Request {
  case requirement, cred {
    ApiKeyHeader(_, header_name), ApiKey(_, value) ->
      Request(..req, headers: list.append(req.headers, [#(header_name, value)]))

    ApiKeyQuery(_, query_name), ApiKey(_, value) ->
      Request(..req, query: list.append(req.query, [#(query_name, value)]))

    ApiKeyCookie(_, cookie_name), ApiKey(_, value) ->
      merge_cookie(req: req, cookie_name: cookie_name, value: value)

    HttpAuthorization(_, prefix), BearerToken(_, token) ->
      set_authorization(req: req, prefix: prefix, value: token)

    HttpAuthorization(_, prefix), BasicAuth(_, value) ->
      set_authorization(req: req, prefix: prefix, value: value)

    HttpAuthorization(_, prefix), DigestAuth(_, value) ->
      set_authorization(req: req, prefix: prefix, value: value)

    _, _ -> req
  }
}

fn set_authorization(
  req req: Request,
  prefix prefix: String,
  value value: String,
) -> Request {
  let header_value = prefix <> " " <> value
  Request(
    ..req,
    headers: list.append(req.headers, [#("authorization", header_value)]),
  )
}

fn merge_cookie(
  req req: Request,
  cookie_name cookie_name: String,
  value value: String,
) -> Request {
  let pair = cookie_name <> "=" <> value
  let lowered = "cookie"
  let #(existing, others) =
    list.partition(req.headers, fn(h) {
      let #(k, _) = h
      string.lowercase(k) == lowered
    })
  let merged_value = case existing {
    [] -> pair
    [_, ..] ->
      list.map(existing, fn(h) {
        let #(_, v) = h
        v
      })
      |> list.append([pair])
      |> string.join("; ")
  }
  Request(..req, headers: list.append(others, [#("Cookie", merged_value)]))
}
