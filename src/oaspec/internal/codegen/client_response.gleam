import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/openapi/schema.{Inline, Reference}
import oaspec/internal/openapi/spec.{type Resolved}
import oaspec/internal/util/content_type
import oaspec/internal/util/http
import oaspec/internal/util/naming
import oaspec/internal/util/string_extra as se

/// Generate response handling for a single content type. Emits a branch
/// of the `case resp.status { ... }` ladder inside a generated
/// `decode_<op>_response` function.
///
/// Body extraction is performed before decoding: text-shaped responses
/// extract via `text_body(resp.body)` and binary responses via
/// `bytes_body(resp.body)`. Both helpers return `ClientError` values so
/// the caller can short-circuit with `use`.
pub fn generate_single_content_response(
  sb: se.StringBuilder,
  status_code: http.HttpStatusCode,
  variant_name: String,
  media_type_name: String,
  media_type: spec.MediaType,
  op_id: String,
  ctx: Context,
  headers_record_expr: Option(String),
) -> se.StringBuilder {
  case content_type.from_string(media_type_name) {
    content_type.ApplicationOctetStream ->
      case media_type.schema {
        Some(_) ->
          sb
          |> se.indent(
            2,
            http.status_code_to_int_pattern(status_code) <> " -> {",
          )
          |> se.indent(3, "use bytes <- result.try(bytes_body(resp.body))")
          |> se.indent(
            3,
            "Ok("
              <> variant_name
              <> "("
              <> append_headers_arg("bytes", headers_record_expr)
              <> "))",
          )
          |> se.indent(2, "}")
        _ ->
          empty_body_branch(sb, status_code, variant_name, headers_record_expr)
      }

    content_type.TextPlain | content_type.ApplicationXml | content_type.TextXml ->
      case media_type.schema {
        Some(_) ->
          sb
          |> se.indent(
            2,
            http.status_code_to_int_pattern(status_code) <> " -> {",
          )
          |> se.indent(3, "use text <- result.try(text_body(resp.body))")
          |> se.indent(
            3,
            "Ok("
              <> variant_name
              <> "("
              <> append_headers_arg("text", headers_record_expr)
              <> "))",
          )
          |> se.indent(2, "}")
        _ ->
          empty_body_branch(sb, status_code, variant_name, headers_record_expr)
      }

    _ ->
      case media_type.schema {
        Some(schema_ref) -> {
          let decode_expr =
            get_response_decode_expr(schema_ref, op_id, status_code, ctx)
          sb
          |> se.indent(
            2,
            http.status_code_to_int_pattern(status_code) <> " -> {",
          )
          |> se.indent(3, "use text <- result.try(text_body(resp.body))")
          |> se.indent(3, "case " <> decode_expr <> " {")
          |> se.indent(
            4,
            "Ok(decoded) -> Ok("
              <> variant_name
              <> "("
              <> append_headers_arg("decoded", headers_record_expr)
              <> "))",
          )
          |> se.indent(
            4,
            "Error(_) -> Error(DecodeFailure(detail: \"Failed to decode response body\"))",
          )
          |> se.indent(3, "}")
          |> se.indent(2, "}")
        }
        _ ->
          empty_body_branch(sb, status_code, variant_name, headers_record_expr)
      }
  }
}

/// Issue #387: shared empty-body branch for status entries that have
/// no schema (e.g. 204 No Content) but may still carry a typed
/// headers record.
fn empty_body_branch(
  sb: se.StringBuilder,
  status_code: http.HttpStatusCode,
  variant_name: String,
  headers_record_expr: Option(String),
) -> se.StringBuilder {
  let ok_call = case headers_record_expr {
    Some(expr) -> " -> Ok(" <> variant_name <> "(" <> expr <> "))"
    None -> " -> Ok(" <> variant_name <> ")"
  }
  sb
  |> se.indent(2, http.status_code_to_int_pattern(status_code) <> ok_call)
}

/// Issue #387: when a response declares headers, the variant
/// constructor takes the body value followed by the typed headers
/// record. This helper appends the headers expression to a body
/// argument so callers do not need to know whether headers exist.
fn append_headers_arg(body_arg: String, headers: Option(String)) -> String {
  case headers {
    Some(expr) -> body_arg <> ", " <> expr
    None -> body_arg
  }
}

/// Generate response handling for multiple content types. Multi-content
/// response variants carry the raw text body, so the branch just
/// extracts text and constructs the variant.
pub fn generate_multi_content_response(
  sb: se.StringBuilder,
  status_code: http.HttpStatusCode,
  variant_name: String,
  _content_entries: List(#(String, spec.MediaType)),
  _op_id: String,
  _ctx: Context,
  headers_record_expr: Option(String),
) -> se.StringBuilder {
  sb
  |> se.indent(2, http.status_code_to_int_pattern(status_code) <> " -> {")
  |> se.indent(3, "use text <- result.try(text_body(resp.body))")
  |> se.indent(
    3,
    "Ok("
      <> variant_name
      <> "("
      <> append_headers_arg("text", headers_record_expr)
      <> "))",
  )
  |> se.indent(2, "}")
}

/// Issue #387: build the typed-headers-record constructor expression
/// for a response, or `None` if the response declares no headers.
///
/// The emitted expression references `resp.headers` (a
/// `List(#(String, String))` from `oaspec/transport`) and constructs
/// the `<Op>Response<Status>Headers` record using whatever fields
/// the spec declares. HTTP header names are looked up case-
/// insensitively by lowercasing the spec-declared name; that matches
/// what `gleam/list.key_find` is given to compare against.
///
/// Field-type handling (current scope):
///   - optional headers (`required: false` or omitted) →
///     `list.key_find(...) |> result.map(Some) |> result.unwrap(None)`,
///     producing `Option(String)`.
///   - required headers (`required: true`) →
///     `result.unwrap(list.key_find(...), "")`, producing `String`
///     with an empty-string fallback when the upstream server omits
///     the header. The server is in violation of its own contract in
///     that case; treating it as "" is safer than panicking inside a
///     generated client.
///
/// Typed headers beyond String (Int / Float / Bool / `$ref` schemas)
/// would require parsers or component decoders here. Real specs
/// rarely declare typed response headers, so the minimal fix lets
/// the typical case (String / Option(String)) compile and reach the
/// caller; broader typing is left to a follow-up.
pub fn build_headers_record_expr(
  op_id: String,
  status_code: http.HttpStatusCode,
  response: spec.Response(Resolved),
) -> Option(String) {
  let headers =
    response.headers
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  case headers {
    [] -> None
    _ -> {
      let record_name =
        "response_types."
        <> naming.schema_to_type_name(op_id)
        <> "Response"
        <> http.status_code_suffix(status_code)
        <> "Headers"
      let fields =
        list.map(headers, fn(entry) {
          let #(header_name, header) = entry
          let field_name = naming.to_snake_case(header_name)
          let lookup = header_lookup_expr(header_name)
          // `header.required` is the OAS-required flag; `False` (the
          // OAS default) maps to `Option(_)` in the generated record.
          let value_expr = case header.required {
            False -> lookup <> " |> result.map(Some) |> result.unwrap(None)"
            True -> "result.unwrap(" <> lookup <> ", \"\")"
          }
          field_name <> ": " <> value_expr
        })
      Some(record_name <> "(" <> string.join(fields, ", ") <> ")")
    }
  }
}

fn header_lookup_expr(header_name: String) -> String {
  // HTTP headers are case-insensitive on the wire; normalise to
  // lowercase so the lookup works regardless of how the upstream
  // server cased the name.
  "list.key_find(resp.headers, \"" <> string.lowercase(header_name) <> "\")"
}

/// Decoder expression for a response body. The emitted expression
/// references `text` (which the caller's surrounding `use` brings into
/// scope from `text_body(resp.body)`).
pub fn get_response_decode_expr(
  schema_ref: schema.SchemaRef,
  op_id: String,
  status_code: http.HttpStatusCode,
  _ctx: Context,
) -> String {
  case schema_ref {
    Reference(name:, ..) -> {
      "decode.decode_" <> naming.to_snake_case(name) <> "(text)"
    }
    Inline(schema.ArraySchema(items:, ..)) ->
      case items {
        Reference(name:, ..) -> {
          "decode.decode_" <> naming.to_snake_case(name) <> "_list(text)"
        }
        Inline(inner) -> {
          let inner_decoder = inline_schema_to_decoder(inner)
          "json.parse(text, decode.list(" <> inner_decoder <> "))"
        }
      }
    Inline(schema.StringSchema(..)) -> "json.parse(text, dyn_decode.string)"
    Inline(schema.IntegerSchema(..)) -> "json.parse(text, dyn_decode.int)"
    Inline(schema.NumberSchema(..)) -> "json.parse(text, dyn_decode.float)"
    Inline(schema.BooleanSchema(..)) -> "json.parse(text, dyn_decode.bool)"
    Inline(_) -> {
      let fn_name =
        "decode_"
        <> naming.to_snake_case(op_id)
        <> "_response_"
        <> naming.to_snake_case(http.status_code_suffix(status_code))
      "decode." <> fn_name <> "(text)"
    }
  }
}

/// Convert an inline schema to a decoder expression for use in generated
/// client code (uses `dyn_decode` to avoid colliding with the `decode`
/// module that holds the spec-derived decoders).
pub fn inline_schema_to_decoder(s: schema.SchemaObject) -> String {
  case s {
    schema.StringSchema(..) -> "dyn_decode.string"
    schema.IntegerSchema(..) -> "dyn_decode.int"
    schema.NumberSchema(..) -> "dyn_decode.float"
    schema.BooleanSchema(..) -> "dyn_decode.bool"
    _ -> "dyn_decode.string"
  }
}
