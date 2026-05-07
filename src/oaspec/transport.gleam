//// Pure, runtime-agnostic transport contract for generated OpenAPI clients.
////
//// Generated client code depends on this module instead of any concrete
//// HTTP runtime. Adapters (e.g. `oaspec/httpc`, `oaspec/fetch`) bridge
//// `Send` / `AsyncSend` to a real runtime; tests can plug in arbitrary
//// fake transport values via `oaspec/mock`.

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// HTTP method enumeration.
//
// Defined locally to keep the root `oaspec` package free of a
// `gleam_http` dependency — adapters can convert to `gleam/http.Method`
// at the runtime boundary.
//
// `Other(String)` carries verbs outside the RFC 9110 §9 method
// registry: WebDAV (`PROPFIND`, `PROPPATCH`, `MKCOL`, …), CalDAV /
// CardDAV (`REPORT`, `MKCALENDAR`), and vendor extensions (`PURGE`,
// `BAN`, `LINK`, `UNLINK`). Per RFC 9110 §9.1 method tokens are
// case-sensitive — construct via `method_from_string` rather than
// the bare `Other(...)` constructor when the source string may be
// in a non-canonical case; the constructor enforces the `tchar`
// charset (RFC 9110 §5.6.2) and routes well-known names to the
// dedicated variants.
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
  Other(String)
}

/// Construction error for `method_from_string`.
pub type MethodError {
  /// The supplied string is empty or contains a byte outside the
  /// `tchar` production from RFC 9110 §5.6.2 (control bytes,
  /// whitespace, separators like `(`, `)`, `<`, `>`, `@`, `,`, `;`,
  /// `:`, `\`, `"`, `/`, `[`, `]`, `?`, `=`, `{`, `}`).
  InvalidMethod(detail: String)
}

/// Convert a `Method` to its on-wire string. Well-known variants
/// produce their canonical RFC 9110 spelling (`Get` → `"GET"`);
/// `Other(s)` returns `s` verbatim — pre-normalise via
/// `method_from_string` if the source is in a non-canonical case.
pub fn method_to_wire(method: Method) -> String {
  case method {
    Get -> "GET"
    Post -> "POST"
    Put -> "PUT"
    Delete -> "DELETE"
    Patch -> "PATCH"
    Head -> "HEAD"
    Options -> "OPTIONS"
    Trace -> "TRACE"
    Connect -> "CONNECT"
    Other(s) -> s
  }
}

/// Smart constructor for `Method`. Routes case-insensitively to the
/// nine RFC 9110 §9 variants for known names; for everything else,
/// validates the input against the `tchar` charset (RFC 9110 §5.6.2)
/// and uppercases the result before wrapping in `Other` so the wire
/// representation is canonical.
///
/// Empty input or a byte outside `tchar` (control bytes, whitespace,
/// or separators like `(`, `)`, `,`, `;`, `:`, `/`, `[`, etc.) returns
/// `Error(InvalidMethod(detail))`.
pub fn method_from_string(s: String) -> Result(Method, MethodError) {
  case string.lowercase(s) {
    "get" -> Ok(Get)
    "post" -> Ok(Post)
    "put" -> Ok(Put)
    "delete" -> Ok(Delete)
    "patch" -> Ok(Patch)
    "head" -> Ok(Head)
    "options" -> Ok(Options)
    "trace" -> Ok(Trace)
    "connect" -> Ok(Connect)
    "" ->
      Error(InvalidMethod(detail: "method string is empty (RFC 9110 §5.6.2)"))
    _ ->
      case is_valid_token(s) {
        True -> Ok(Other(string.uppercase(s)))
        False ->
          Error(InvalidMethod(
            detail: "method `"
            <> s
            <> "` contains a byte outside the tchar charset (RFC 9110 §5.6.2)",
          ))
      }
  }
}

fn is_valid_token(s: String) -> Bool {
  string.to_utf_codepoints(s)
  |> list.all(is_tchar)
}

// RFC 9110 §5.6.2: tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*"
// / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA.
// Every other byte (control chars, whitespace, separators) is
// forbidden inside a method token.
fn is_tchar(cp: UtfCodepoint) -> Bool {
  let codepoint = string.utf_codepoint_to_int(cp)
  case codepoint {
    0x21 -> True
    // !
    0x23 -> True
    // #
    0x24 -> True
    // $
    0x25 -> True
    // %
    0x26 -> True
    // &
    0x27 -> True
    // '
    0x2A -> True
    // *
    0x2B -> True
    // +
    0x2D -> True
    // -
    0x2E -> True
    // .
    0x5E -> True
    // ^
    0x5F -> True
    // _
    0x60 -> True
    // `
    0x7C -> True
    // |
    0x7E -> True
    // ~
    _ ->
      // 0..9 / A..Z / a..z
      { codepoint >= 0x30 && codepoint <= 0x39 }
      || { codepoint >= 0x41 && codepoint <= 0x5A }
      || { codepoint >= 0x61 && codepoint <= 0x7A }
  }
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

// Header-middleware composition rules at a glance:
//
// - `with_default_header` (single name/value, wrapper form) — each call
//   wraps the previous send. When two wrappers target the same name
//   (case-insensitive), the **outermost** wrapper (the one most recently
//   piped in) wins, because the request reaches it first and inserts
//   before the inner check runs.
// - `with_default_headers` (list form) — when the supplied list contains
//   the same name twice, the **first occurrence** is kept and the rest
//   are silently dropped.
//
// The two rules are each correct in isolation but inverse to each other.
// Pick one shape per code path to avoid surprises. In both forms,
// headers already on the inbound request always win — middleware never
// clobbers explicit caller intent.

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
/// **Validation.** Both `name` and `value` are checked at construction
/// time for the absence of CR (`\r`), LF (`\n`), and NUL (`\u{0000}`)
/// bytes. Those bytes enable HTTP response-splitting / header
/// injection if they reach the wire — see RFC 9112 §2.2. A value that
/// contains any of them panics with a structured message naming the
/// offending byte and the recommendation: pre-encode binary values
/// via Base64 or RFC 8187 before passing them in. The check fires at
/// the outer call (i.e. when the wrapper is built), so a static
/// misconfiguration surfaces immediately at startup rather than
/// per-request.
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
  validate_header_name(
    api_name: "oaspec.transport.with_default_header",
    name: name,
  )
  validate_header_value(
    api_name: "oaspec.transport.with_default_header",
    name: name,
    value: value,
  )
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
/// **Validation.** Every `name` and every `value` in `headers` is
/// checked at construction time for the absence of CR, LF, and NUL
/// bytes (see `with_default_header` for the rationale). The first
/// invalid entry panics with a structured message naming the
/// offending byte; the check fires at the outer call, so a static
/// misconfiguration surfaces immediately rather than per-request.
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
  list.each(headers, fn(kv) {
    let #(name, value) = kv
    validate_header_name(
      api_name: "oaspec.transport.with_default_headers",
      name: name,
    )
    validate_header_value(
      api_name: "oaspec.transport.with_default_headers",
      name: name,
      value: value,
    )
  })
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

// Reject header names that contain CR / LF / NUL bytes. The name
// itself is rarely user-derived (most callers pass a string literal),
// but defending the same surface as `validate_header_value` keeps the
// API symmetrical and shuts the door on a future call site that flips
// from literal-name to runtime-name without thinking through the
// injection surface.
fn validate_header_name(api_name api_name: String, name name: String) -> Nil {
  case forbidden_byte(name) {
    None -> Nil
    Some(byte_label) ->
      panic as {
        api_name
        <> ": header name contains forbidden control byte "
        <> byte_label
        <> " — header names must not include CR, LF, or NUL"
      }
  }
}

// Reject header values that contain CR / LF / NUL bytes — those are
// the bytes that enable HTTP response-splitting / header injection if
// they reach the wire (RFC 9112 §2.2). Pre-encode binary values via
// Base64 or RFC 8187 before passing them in.
fn validate_header_value(
  api_name api_name: String,
  name name: String,
  value value: String,
) -> Nil {
  case forbidden_byte(value) {
    None -> Nil
    Some(byte_label) ->
      panic as {
        api_name
        <> ": header value for `"
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
