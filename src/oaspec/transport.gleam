//// Pure, runtime-agnostic transport contract for generated OpenAPI clients.
////
//// Generated client code depends on this module instead of any concrete
//// HTTP runtime. Adapters (e.g. `oaspec/httpc`, `oaspec/fetch`) bridge
//// `Send` to a real runtime; tests can plug in arbitrary fake `Send`
//// values via `oaspec/mock`.

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
// without regenerating clients.
pub fn with_base_url(send send: Send, base_url base_url: String) -> Send {
  fn(req: Request) { send(Request(..req, base_url: Some(base_url))) }
}

// Inject a single header when the request does not already declare it.
// Explicit request headers win — middleware never clobbers them.
pub fn with_default_header(
  send send: Send,
  name name: String,
  value value: String,
) -> Send {
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

// Inject a list of default headers. Iteration order is preserved so
// callers get deterministic ordering on the wire.
pub fn with_default_headers(
  send send: Send,
  headers headers: List(#(String, String)),
) -> Send {
  fn(req: Request) {
    let merged =
      list.fold(headers, req.headers, fn(acc, kv) {
        let #(name, value) = kv
        case has_header(acc, name) {
          True -> acc
          False -> list.append(acc, [#(name, value)])
        }
      })
    send(Request(..req, headers: merged))
  }
}

// Apply OpenAPI security requirements. Walks `req.security` in order,
// finds the first alternative all of whose requirements have matching
// credentials in `creds`, and stamps those credentials onto the
// outbound request (header / query / cookie as required by the
// scheme). If no alternative is satisfiable, the request is forwarded
// unchanged — server-side rejection then surfaces as
// `UnexpectedStatus`.
pub fn with_security(send send: Send, credentials creds: Credentials) -> Send {
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
