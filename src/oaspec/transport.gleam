//// Pure, runtime-agnostic transport contract for generated OpenAPI clients.
////
//// Generated client code depends on this module instead of any concrete
//// HTTP runtime. Adapters (e.g. `oaspec/httpc`, `oaspec/fetch`) bridge
//// `Send` / `AsyncSend` to a real runtime; tests can plug in arbitrary
//// fake transport values via `oaspec/mock`.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// HTTP method enumeration.
//
// Defined locally to keep the root `oaspec` package free of a
// `gleam_http` dependency — adapters can convert to `gleam/http.Method`
// at the runtime boundary.
pub type Method {
  Get
  Post
  Put
  Delete
  Patch
  Head
  Options
  Trace
  Connect
}

pub type Body {
  EmptyBody
  TextBody(String)
  BytesBody(BitArray)
}

// Single OpenAPI security requirement, parameterised by scheme name plus
// the wire location encoded by the scheme. Scheme name is the OpenAPI
// `securitySchemes` key — credential lookups match on this.
pub type SecurityRequirement {
  ApiKeyHeader(scheme_name: String, header_name: String)
  ApiKeyQuery(scheme_name: String, query_name: String)
  ApiKeyCookie(scheme_name: String, cookie_name: String)
  HttpAuthorization(scheme_name: String, prefix: String)
}

// One satisfiable AND-bundle of security requirements. Operations carry
// a list of these to model OpenAPI OR-of-AND semantics: middleware
// applies the first alternative whose requirements are all satisfied
// by the supplied credentials.
pub type SecurityAlternative {
  SecurityAlternative(requirements: List(SecurityRequirement))
}

pub type Request {
  Request(
    method: Method,
    base_url: Option(String),
    path: String,
    query: List(#(String, String)),
    headers: List(#(String, String)),
    body: Body,
    security: List(SecurityAlternative),
  )
}

pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: Body)
}

pub type TransportError {
  ConnectionFailed(detail: String)
  Timeout
  InvalidBaseUrl(detail: String)
  TlsFailure(detail: String)
  Unsupported(detail: String)
}

pub type Send =
  fn(Request) -> Result(Response, TransportError)

pub type AsyncSend =
  fn(Request) -> Async(Result(Response, TransportError))

/// Cross-target async value used by generated async clients and adapters.
/// JavaScript adapters can back this with promises; other runtimes can bridge
/// from callbacks or scheduling primitives.
pub opaque type Async(value) {
  Async(register: fn(fn(value) -> Nil) -> Nil)
}

pub fn from_callback(
  register register: fn(fn(value) -> Nil) -> Nil,
) -> Async(value) {
  Async(register)
}

pub fn resolve(value value: a) -> Async(a) {
  Async(fn(done) { done(value) })
}

pub fn run(async async: Async(a), done done: fn(a) -> Nil) -> Nil {
  let Async(register) = async
  register(done)
}

pub fn map(async async: Async(a), with with_: fn(a) -> b) -> Async(b) {
  Async(fn(done) { run(async: async, done: fn(value) { done(with_(value)) }) })
}

pub fn await(async async: Async(a), next next: fn(a) -> Async(b)) -> Async(b) {
  Async(fn(done) {
    run(async: async, done: fn(value) { run(async: next(value), done: done) })
  })
}

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

// ---------------------------------------------------------------------------
// Credentials store
// ---------------------------------------------------------------------------

// Opaque credential bag for OpenAPI security schemes. Built up with
// `credentials() |> with_*(...) |> with_*(...)` and applied to a `Send`
// chain via `with_security`.
pub opaque type Credentials {
  Credentials(entries: List(CredentialEntry))
}

type CredentialEntry {
  CredApiKey(scheme_name: String, value: String)
  CredBearer(scheme_name: String, token: String)
  CredBasic(scheme_name: String, value: String)
  CredDigest(scheme_name: String, value: String)
}

pub fn credentials() -> Credentials {
  Credentials([])
}

pub fn with_api_key(
  creds creds: Credentials,
  scheme_name scheme_name: String,
  value value: String,
) -> Credentials {
  add_credential(creds, CredApiKey(scheme_name, value))
}

pub fn with_bearer_token(
  creds creds: Credentials,
  scheme_name scheme_name: String,
  token token: String,
) -> Credentials {
  add_credential(creds, CredBearer(scheme_name, token))
}

pub fn with_basic_auth(
  creds creds: Credentials,
  scheme_name scheme_name: String,
  value value: String,
) -> Credentials {
  add_credential(creds, CredBasic(scheme_name, value))
}

pub fn with_digest_auth(
  creds creds: Credentials,
  scheme_name scheme_name: String,
  value value: String,
) -> Credentials {
  add_credential(creds, CredDigest(scheme_name, value))
}

fn add_credential(creds: Credentials, entry: CredentialEntry) -> Credentials {
  let Credentials(entries) = creds
  Credentials(list.append(entries, [entry]))
}

// ---------------------------------------------------------------------------
// Send middleware
// ---------------------------------------------------------------------------

// Override the request's base URL. Always wins over any `base_url` set
// by the request builder, so callers can target staging / proxy hosts
// without regenerating clients. Works with both `transport.Send` and
// `transport.AsyncSend`.
pub fn with_base_url(
  send send: fn(Request) -> a,
  base_url base_url: String,
) -> fn(Request) -> a {
  fn(req: Request) { send(Request(..req, base_url: Some(base_url))) }
}

/// Inject a single default header when the request does not already
/// declare it. Header-name comparison is case-insensitive (per RFC 7230),
/// so a request that already carries `x-trace-id` blocks a default
/// `X-Trace-Id`. Explicit request headers always win — middleware never
/// clobbers them — and the helper works with both sync and async send
/// functions.
///
/// **Composition order.** Each call wraps the previous send. When two
/// `with_default_header` wrappers target the same name (case-insensitive),
/// the **outermost** wrapper (the one most recently piped in) wins,
/// because the request reaches it first and inserts before the inner
/// check runs. This is the *opposite* of the list form below — see
/// `with_default_headers` for the in-list rule. Reach for the
/// `with_default_headers([...])` shape if you want a single source of
/// truth for the dedup ordering.
pub fn with_default_header(
  send send: fn(Request) -> a,
  name name: String,
  value value: String,
) -> fn(Request) -> a {
  fn(req: Request) {
    case has_header(req.headers, name) {
      True -> send(req)
      False ->
        send(
          Request(..req, headers: list.append(req.headers, [#(name, value)])),
        )
    }
  }
}

/// Inject a list of default headers when the request does not already
/// declare them. Iteration order is preserved so callers get
/// deterministic ordering on the wire, and the helper works with both
/// sync and async send functions.
///
/// **Duplicate names within `headers`.** Header-name comparison is
/// case-insensitive (per RFC 7230). When the supplied list contains the
/// same name twice (e.g. `[#("X-Env", "staging"), #("X-Env", "prod")]`),
/// the **first occurrence is kept** and subsequent entries with the
/// same name are silently dropped. Headers already present on the
/// inbound request always win over every entry in `headers` regardless
/// of position.
///
/// This is the *opposite* of the wrapper form's composition rule (see
/// `with_default_header`, where the outermost wrapper wins). The two
/// rules are each correct in isolation: the list form picks the first
/// caller-supplied entry; the wrapper form picks the most recently
/// piped wrapper. Pick one shape per code path and stick to it to
/// avoid surprises.
pub fn with_default_headers(
  send send: fn(Request) -> a,
  headers headers: List(#(String, String)),
) -> fn(Request) -> a {
  fn(req: Request) {
    // Build with prepend + final reverse so the fold is O(N) over the
    // header list instead of the O(N²) shape we get from
    // `list.append(acc, [...])`. has_header is order-independent
    // (a name lookup), so checking against the reversed accumulator
    // preserves the original "first-occurrence wins" behavior.
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

// Apply OpenAPI security requirements. Walks `req.security` in order,
// finds the first alternative all of whose requirements have matching
// credentials in `creds`, and stamps those credentials onto the
// outbound request (header / query / cookie as required by the
// scheme). If no alternative is satisfiable, the request is forwarded
// unchanged — server-side rejection then surfaces as
// `UnexpectedStatus`. Works with both sync and async send functions.
pub fn with_security(
  send send: fn(Request) -> a,
  credentials creds: Credentials,
) -> fn(Request) -> a {
  fn(req: Request) {
    let prepared = case pick_alternative(req.security, creds) {
      Some(alt) -> apply_alternative(req: req, alt: alt, creds: creds)
      None -> req
    }
    send(prepared)
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn has_header(headers: List(#(String, String)), name: String) -> Bool {
  let lowered = string.lowercase(name)
  list.any(headers, fn(h) {
    let #(k, _) = h
    string.lowercase(k) == lowered
  })
}

fn pick_alternative(
  alts: List(SecurityAlternative),
  creds: Credentials,
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

fn satisfiable(alt: SecurityAlternative, creds: Credentials) -> Bool {
  list.all(alt.requirements, fn(req) { find_credential(creds, req) != None })
}

fn find_credential(
  creds: Credentials,
  req: SecurityRequirement,
) -> Option(CredentialEntry) {
  let Credentials(entries) = creds
  list.find(entries, fn(c) { credential_matches(c, req) })
  |> option.from_result
}

fn credential_matches(cred: CredentialEntry, req: SecurityRequirement) -> Bool {
  case cred, req {
    CredApiKey(s, _), ApiKeyHeader(t, _) if s == t -> True
    CredApiKey(s, _), ApiKeyQuery(t, _) if s == t -> True
    CredApiKey(s, _), ApiKeyCookie(t, _) if s == t -> True
    CredBearer(s, _), HttpAuthorization(t, prefix) if s == t ->
      string.lowercase(prefix) == "bearer"
    CredBasic(s, _), HttpAuthorization(t, prefix) if s == t ->
      string.lowercase(prefix) == "basic"
    CredDigest(s, _), HttpAuthorization(t, prefix) if s == t ->
      string.lowercase(prefix) == "digest"
    _, _ -> False
  }
}

fn apply_alternative(
  req req: Request,
  alt alt: SecurityAlternative,
  creds creds: Credentials,
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
  cred cred: CredentialEntry,
) -> Request {
  case requirement, cred {
    ApiKeyHeader(_, header_name), CredApiKey(_, value) ->
      Request(..req, headers: list.append(req.headers, [#(header_name, value)]))

    ApiKeyQuery(_, query_name), CredApiKey(_, value) ->
      Request(..req, query: list.append(req.query, [#(query_name, value)]))

    ApiKeyCookie(_, cookie_name), CredApiKey(_, value) ->
      merge_cookie(req: req, cookie_name: cookie_name, value: value)

    HttpAuthorization(_, prefix), CredBearer(_, token) ->
      set_authorization(req: req, prefix: prefix, value: token)

    HttpAuthorization(_, prefix), CredBasic(_, value) ->
      set_authorization(req: req, prefix: prefix, value: value)

    HttpAuthorization(_, prefix), CredDigest(_, value) ->
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
