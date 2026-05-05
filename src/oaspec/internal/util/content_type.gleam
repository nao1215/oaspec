import gleam/list
import gleam/string
import oaspec/internal/capability

/// Supported content types for code generation.
///
/// `Wildcard` represents the OpenAPI `*/*` media-type catch-all
/// (Issue #504). Specs like Kubernetes' OpenAPI v3 use it for
/// proxy-style endpoints and resource mutation handlers that accept or
/// emit arbitrary bytes. oaspec treats `*/*` as `application/octet-stream`
/// for codegen purposes — request body is `BitArray`, response body is
/// `BitArray` — which matches the "any bytes" semantics without
/// committing the SDK to a specific parser.
pub type ContentType {
  ApplicationJson
  TextPlain
  MultipartFormData
  FormUrlEncoded
  ApplicationOctetStream
  ApplicationXml
  TextXml
  Wildcard
  UnsupportedContentType(String)
}

/// Parse a content type string into a ContentType.
/// Recognizes structured syntax suffixes: types ending with `+json` are
/// treated as JSON-compatible, and types ending with `+xml` as XML-compatible.
///
/// Unrecognized media types fall back to a passthrough alias so real-world
/// specs like the GitHub REST API don't trip the "unsupported content
/// type" diagnostic just because they declare vendor-prefixed responses
/// (issue #352). The fallback table:
///
///   - `text/*` (e.g. `text/html`, `text/x-markdown`) aliases to
///     `TextPlain` so the body passes through as a `String`.
///   - `application/*` not already in the recognized list (e.g.
///     `application/vnd.github.diff`, `application/octocat-stream`)
///     aliases to `ApplicationOctetStream` so the body passes through
///     as raw bytes.
///   - Anything else (`image/*`, `audio/*`, `video/*`, …) stays as
///     `UnsupportedContentType` and continues to fail validation —
///     the generator has no sensible default for binary media that
///     isn't already covered by `application/octet-stream`.
///
/// The original media-type string is still embedded verbatim into the
/// generated server's `Content-Type` response header (codegen pulls
/// the name from the spec, not from `to_string`), so the wire-level
/// content type is preserved even though the in-memory typing falls
/// back. This mirrors the existing `application/x-ndjson` aliasing.
pub fn from_string(content_type: String) -> ContentType {
  case content_type {
    "application/json" -> ApplicationJson
    "text/plain" -> TextPlain
    // application/x-ndjson (newline-delimited JSON) is widely deployed for
    // streaming JSON Lines responses (Elasticsearch bulk, Loki, OpenAI
    // streaming, log shippers). For codegen purposes the body is a `String`
    // and no per-line decoding happens at the SDK layer, so it aliases to
    // TextPlain. The original "application/x-ndjson" string is still embedded
    // verbatim into the generated server's `Content-Type` response header
    // because the codegen pulls the media-type name from the spec, not from
    // `to_string`.
    "application/x-ndjson" -> TextPlain
    "multipart/form-data" -> MultipartFormData
    "application/x-www-form-urlencoded" -> FormUrlEncoded
    "application/octet-stream" -> ApplicationOctetStream
    "application/xml" -> ApplicationXml
    "text/xml" -> TextXml
    // OpenAPI `*/*` catch-all (Issue #504). Treated as a synonym for
    // application/octet-stream by the codegen so the generated code
    // moves bytes through unchanged.
    "*/*" -> Wildcard
    other ->
      case string.ends_with(other, "+json") {
        True -> ApplicationJson
        False ->
          case string.ends_with(other, "+xml") {
            True -> ApplicationXml
            False ->
              case string.starts_with(other, "text/") {
                True -> TextPlain
                False ->
                  case string.starts_with(other, "application/") {
                    True -> ApplicationOctetStream
                    False -> UnsupportedContentType(other)
                  }
              }
          }
      }
  }
}

/// Check if a content type string is JSON-compatible.
/// Matches "application/json" and any type with a "+json" suffix.
pub fn is_json_compatible(s: String) -> Bool {
  s == "application/json" || string.ends_with(s, "+json")
}

/// Check if a content type string is XML-compatible.
/// Matches "application/xml", "text/xml", and any type with a "+xml" suffix.
pub fn is_xml_compatible(s: String) -> Bool {
  s == "application/xml" || s == "text/xml" || string.ends_with(s, "+xml")
}

/// Convert a ContentType back to its string representation.
pub fn to_string(content_type: ContentType) -> String {
  case content_type {
    ApplicationJson -> "application/json"
    TextPlain -> "text/plain"
    MultipartFormData -> "multipart/form-data"
    FormUrlEncoded -> "application/x-www-form-urlencoded"
    ApplicationOctetStream -> "application/octet-stream"
    ApplicationXml -> "application/xml"
    TextXml -> "text/xml"
    Wildcard -> "*/*"
    UnsupportedContentType(s) -> s
  }
}

/// Check if a content type is supported anywhere in code generation.
pub fn is_supported(content_type: ContentType) -> Bool {
  case content_type {
    ApplicationJson -> True
    TextPlain -> True
    MultipartFormData -> True
    FormUrlEncoded -> True
    ApplicationOctetStream -> True
    ApplicationXml -> True
    TextXml -> True
    Wildcard -> True
    _ -> False
  }
}

/// Check if a content type is supported for request bodies.
/// Driven by the capability registry: looks up the MIME string under
/// category `"request"` at level Supported. UnsupportedContentType
/// never matches the registry and always returns False.
pub fn is_supported_request(content_type: ContentType) -> Bool {
  case content_type {
    UnsupportedContentType(_) -> False
    ct -> registry_has_supported(to_string(ct), "request")
  }
}

/// Check if a content type is supported for responses. Same mechanism
/// as `is_supported_request`, just targeting the `"response"` category.
pub fn is_supported_response(content_type: ContentType) -> Bool {
  case content_type {
    UnsupportedContentType(_) -> False
    ct -> registry_has_supported(to_string(ct), "response")
  }
}

fn registry_has_supported(name: String, category: String) -> Bool {
  capability.registry()
  |> list.any(fn(c) {
    c.name == name && c.category == category && c.level == capability.Supported
  })
}
