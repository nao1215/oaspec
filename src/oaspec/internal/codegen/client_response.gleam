import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/openapi/schema.{
  type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema, BooleanSchema, Inline,
  IntegerSchema, NumberSchema, ObjectSchema, OneOfSchema, Reference,
  StringSchema,
}
import oaspec/internal/openapi/spec.{type Resolved}
import oaspec/internal/util/content_type
import oaspec/internal/util/http
import oaspec/internal/util/naming
import oaspec/internal/util/string_extra as se

/// Issue #483: the `default` response branch must capture the actual
/// runtime status code so the decoded `XxxResponseDefault(...)`
/// variant can carry it through to the caller. For all non-default
/// branches the case pattern is the matched status int (or guard
/// expression for `2xx` ranges); the default branch binds `status`
/// instead of using `_` so the variant constructor can pass it on.
fn status_branch_pattern(status_code: http.HttpStatusCode) -> String {
  case status_code {
    http.DefaultStatus -> "status"
    _ -> http.status_code_to_int_pattern(status_code)
  }
}

/// Issue #483: prepend the runtime status binding to a variant
/// constructor's argument list when the status code is `default`. For
/// every other status the variant arity is unchanged.
fn prepend_default_status(
  arg: String,
  status_code: http.HttpStatusCode,
) -> String {
  case status_code {
    http.DefaultStatus ->
      case arg {
        "" -> "status"
        _ -> "status, " <> arg
      }
    _ -> arg
  }
}

/// Issue #387: assembled response-headers record. Tracks both the
/// pre-statements (let bindings or `use` chains that extract each
/// header field from `resp.headers`) and the final constructor
/// expression that references those bound names.
///
/// Required headers and parse-required typed headers (Int / Float /
/// Bool) emit `use ... <- result.try(...)` so a missing or
/// unparseable header short-circuits with
/// `Error(InvalidResponse(detail: ...))`. Optional headers emit a
/// plain `let`, defaulting to `None` when the lookup or parse fails.
pub type HeadersRecord {
  HeadersRecord(pre_statements: List(String), record_expr: String)
}

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
  headers: Option(HeadersRecord),
) -> se.StringBuilder {
  case content_type.from_string(media_type_name) {
    content_type.ApplicationOctetStream | content_type.Wildcard ->
      case media_type.schema {
        Some(_) ->
          body_branch(sb, status_code, variant_name, "bytes", headers, fn(sb) {
            se.indent(sb, 3, "use bytes <- result.try(bytes_body(resp.body))")
          })
        _ -> empty_body_branch(sb, status_code, variant_name, headers)
      }

    content_type.TextPlain | content_type.ApplicationXml | content_type.TextXml ->
      case media_type.schema {
        Some(_) ->
          body_branch(sb, status_code, variant_name, "text", headers, fn(sb) {
            se.indent(sb, 3, "use text <- result.try(text_body(resp.body))")
          })
        _ -> empty_body_branch(sb, status_code, variant_name, headers)
      }

    _ ->
      case media_type.schema {
        Some(schema_ref) -> {
          let decode_expr =
            get_response_decode_expr(schema_ref, op_id, status_code, ctx)
          let sb =
            sb
            |> se.indent(2, status_branch_pattern(status_code) <> " -> {")
            |> se.indent(3, "use text <- result.try(text_body(resp.body))")
            |> emit_pre_statements(headers)
          sb
          |> se.indent(3, "case " <> decode_expr <> " {")
          |> se.indent(
            4,
            "Ok(decoded) -> Ok("
              <> variant_name
              <> "("
              <> prepend_default_status(
              append_headers_arg("decoded", headers),
              status_code,
            )
              <> "))",
          )
          |> se.indent(
            4,
            "Error(_) -> Error(DecodeFailure(detail: \"Failed to decode response body\"))",
          )
          |> se.indent(3, "}")
          |> se.indent(2, "}")
        }
        _ -> empty_body_branch(sb, status_code, variant_name, headers)
      }
  }
}

/// Common branch shape for content branches that extract a body
/// value (`text` / `bytes`) directly into the variant constructor
/// without an intervening decoder. The `extract_body` callback emits
/// the `use <body> <- ...` line; the rest is reused across binary
/// and text/xml branches.
fn body_branch(
  sb: se.StringBuilder,
  status_code: http.HttpStatusCode,
  variant_name: String,
  body_arg: String,
  headers: Option(HeadersRecord),
  extract_body: fn(se.StringBuilder) -> se.StringBuilder,
) -> se.StringBuilder {
  sb
  |> se.indent(2, status_branch_pattern(status_code) <> " -> {")
  |> extract_body
  |> emit_pre_statements(headers)
  |> se.indent(
    3,
    "Ok("
      <> variant_name
      <> "("
      <> prepend_default_status(
      append_headers_arg(body_arg, headers),
      status_code,
    )
      <> "))",
  )
  |> se.indent(2, "}")
}

/// Issue #387: shared empty-body branch for status entries that have
/// no schema (e.g. 204 No Content) but may still carry a typed
/// headers record. Emits a single-line `<status> -> Ok(...)` when the
/// headers record has no pre-statements, or a multi-line block when
/// any required header forces a `use` chain.
fn empty_body_branch(
  sb: se.StringBuilder,
  status_code: http.HttpStatusCode,
  variant_name: String,
  headers: Option(HeadersRecord),
) -> se.StringBuilder {
  case headers {
    Some(HeadersRecord(pre_statements: [_, ..], record_expr: expr)) ->
      sb
      |> se.indent(2, status_branch_pattern(status_code) <> " -> {")
      |> emit_pre_statements(headers)
      |> se.indent(
        3,
        "Ok("
          <> variant_name
          <> "("
          <> prepend_default_status(expr, status_code)
          <> "))",
      )
      |> se.indent(2, "}")
    Some(HeadersRecord(record_expr: expr, ..)) ->
      sb
      |> se.indent(
        2,
        status_branch_pattern(status_code)
          <> " -> Ok("
          <> variant_name
          <> "("
          <> prepend_default_status(expr, status_code)
          <> "))",
      )
    None ->
      sb
      |> se.indent(
        2,
        status_branch_pattern(status_code)
          <> " -> Ok("
          <> variant_name
          <> case status_code {
          http.DefaultStatus -> "(status)"
          _ -> ""
        }
          <> ")",
      )
  }
}

/// Emit each header pre-statement at the appropriate indentation
/// level (3, inside the per-status block). No-op when the response
/// declares no headers.
fn emit_pre_statements(
  sb: se.StringBuilder,
  headers: Option(HeadersRecord),
) -> se.StringBuilder {
  case headers {
    Some(HeadersRecord(pre_statements: stmts, ..)) ->
      list.fold(stmts, sb, fn(acc, line) { se.indent(acc, 3, line) })
    None -> sb
  }
}

/// Issue #387: when a response declares headers, the variant
/// constructor takes the body value followed by the typed headers
/// record. This helper appends the headers expression to a body
/// argument so callers do not need to know whether headers exist.
fn append_headers_arg(
  body_arg: String,
  headers: Option(HeadersRecord),
) -> String {
  case headers {
    Some(HeadersRecord(record_expr: expr, ..)) -> body_arg <> ", " <> expr
    None -> body_arg
  }
}

/// Generate the per-status branch for responses that declare no
/// `content` entries (e.g. 204 No Content, or anywhere the spec uses
/// just `description:` and optional `headers:`). When typed headers
/// are present this still emits the headers extraction; otherwise
/// it collapses to a single `<status> -> Ok(<Variant>)` line.
pub fn generate_empty_content_response(
  sb: se.StringBuilder,
  status_code: http.HttpStatusCode,
  variant_name: String,
  headers: Option(HeadersRecord),
) -> se.StringBuilder {
  empty_body_branch(sb, status_code, variant_name, headers)
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
  headers: Option(HeadersRecord),
) -> se.StringBuilder {
  body_branch(sb, status_code, variant_name, "text", headers, fn(sb) {
    se.indent(sb, 3, "use text <- result.try(text_body(resp.body))")
  })
}

/// Issue #387: build the typed-headers record for a response, or
/// `None` if the response declares no headers. Returns a
/// `HeadersRecord` carrying both the per-field extraction
/// pre-statements and the final constructor expression that
/// references the bound names.
///
/// Header type plumbing (no longer scoped down to "String only"):
///   - Optional + String → `let <fn> = list.key_find(...) |> result.map(Some) |> result.unwrap(None)`
///   - Required + String → `use <fn> <- result.try(list.key_find(...) |> result.map_error(...))`
///   - Optional + Int / Float → same as String, plus `result.try(int.parse)` / `result.try(float.parse)`
///   - Required + Int / Float → use chain that errors on missing OR unparseable values
///   - Optional + Bool   → case match for "true" / "false" (anything else → None)
///   - Required + Bool   → case match wrapped in `use ... <- result.try(...)`
///
/// `$ref`-typed response headers (`schema: $ref: ...`) and complex
/// inline shapes (Object / Array / allOf / oneOf / anyOf) are
/// rejected at generation time with a clear `panic` so the user
/// sees the gap explicitly rather than getting a cryptic compile
/// error in the generated module.
pub fn build_headers_record(
  op_id: String,
  status_code: http.HttpStatusCode,
  response: spec.Response(Resolved),
) -> Option(HeadersRecord) {
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
          let pre_statement =
            header_field_extraction(field_name, header_name, header)
          #(field_name, pre_statement)
        })
      let pre_statements = list.map(fields, fn(p) { p.1 })
      let assignments = list.map(fields, fn(p) { p.0 <> ": " <> p.0 })
      Some(HeadersRecord(
        pre_statements: pre_statements,
        record_expr: record_name <> "(" <> string.join(assignments, ", ") <> ")",
      ))
    }
  }
}

/// Classification of a response header's schema, restricted to
/// shapes the client extractor can produce code for. Anything
/// outside this set falls back to a codegen-time panic via
/// `header_field_extraction`.
type HeaderFieldType {
  StringHeader
  IntHeader
  FloatHeader
  BoolHeader
}

fn classify_header_schema(
  schema_opt: Option(SchemaRef),
  header_name: String,
) -> HeaderFieldType {
  case schema_opt {
    None -> StringHeader
    Some(Inline(StringSchema(..))) -> StringHeader
    Some(Inline(IntegerSchema(..))) -> IntHeader
    Some(Inline(NumberSchema(..))) -> FloatHeader
    Some(Inline(BooleanSchema(..))) -> BoolHeader
    Some(Reference(name:, ..)) ->
      panic as response_header_unsupported(
          header_name,
          "$ref to component schema '" <> name <> "'",
        )
    Some(Inline(ObjectSchema(..))) ->
      panic as response_header_unsupported(header_name, "inline object schema")
    Some(Inline(ArraySchema(..))) ->
      panic as response_header_unsupported(header_name, "inline array schema")
    Some(Inline(AllOfSchema(..))) ->
      panic as response_header_unsupported(header_name, "allOf composition")
    Some(Inline(OneOfSchema(..))) ->
      panic as response_header_unsupported(header_name, "oneOf composition")
    Some(Inline(AnyOfSchema(..))) ->
      panic as response_header_unsupported(header_name, "anyOf composition")
  }
}

fn response_header_unsupported(header_name: String, kind: String) -> String {
  "Cannot generate client extractor for response header '"
  <> header_name
  <> "' (unsupported schema: "
  <> kind
  <> "). Supported shapes today are inline String / Int / Float / Bool. "
  <> "File a follow-up to oaspec issue #387 if you need typed extraction "
  <> "for this header."
}

fn header_field_extraction(
  field_name: String,
  header_name: String,
  header: spec.Header,
) -> String {
  let lookup = header_lookup_expr(header_name)
  let kind = classify_header_schema(header.schema, header_name)
  case header.required, kind {
    False, StringHeader ->
      "let "
      <> field_name
      <> " = "
      <> lookup
      <> " |> result.map(Some) |> result.unwrap(None)"
    True, StringHeader ->
      "use "
      <> field_name
      <> " <- result.try("
      <> lookup
      <> " |> result.map_error(fn(_) { "
      <> missing_required_error(header_name, "string")
      <> " }))"
    False, IntHeader ->
      "let "
      <> field_name
      <> " = "
      <> lookup
      <> " |> result.try(int.parse) |> result.map(Some) |> result.unwrap(None)"
    True, IntHeader ->
      "use "
      <> field_name
      <> " <- result.try("
      <> lookup
      <> " |> result.try(int.parse) |> result.map_error(fn(_) { "
      <> missing_required_error(header_name, "integer")
      <> " }))"
    False, FloatHeader ->
      "let "
      <> field_name
      <> " = "
      <> lookup
      <> " |> result.try(float.parse) |> result.map(Some) |> result.unwrap(None)"
    True, FloatHeader ->
      "use "
      <> field_name
      <> " <- result.try("
      <> lookup
      <> " |> result.try(float.parse) |> result.map_error(fn(_) { "
      <> missing_required_error(header_name, "number")
      <> " }))"
    False, BoolHeader ->
      "let "
      <> field_name
      <> " = case "
      <> lookup
      <> " { Ok(\"true\") -> Some(True) Ok(\"false\") -> Some(False) _ -> None }"
    True, BoolHeader ->
      "use "
      <> field_name
      <> " <- result.try(case "
      <> lookup
      <> " { Ok(\"true\") -> Ok(True) Ok(\"false\") -> Ok(False) _ -> Error("
      <> missing_required_error_inner(header_name, "boolean")
      <> ") })"
  }
}

fn missing_required_error(header_name: String, kind: String) -> String {
  "InvalidResponse(detail: \"missing or invalid required "
  <> kind
  <> " header: "
  <> header_name
  <> "\")"
}

fn missing_required_error_inner(header_name: String, kind: String) -> String {
  // Same payload as `missing_required_error/2` but built without the
  // outer `fn(_) { ... }` wrapper, used inside an inline
  // `case ... { ... -> Error(...) }` branch.
  "InvalidResponse(detail: \"missing or invalid required "
  <> kind
  <> " header: "
  <> header_name
  <> "\")"
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
          // Issue #493 / CodeRabbit follow-up: parse with
          // `decode.list(<schema>_decoder())` directly instead of
          // calling the synthetic `decode_<schema>_list` wrapper.
          // The wrapper is only emitted for object schemas, so an
          // array of `$ref` to an enum / primitive / oneOf / anyOf
          // would otherwise reference a non-existent function.
          // Going through the per-schema decoder works for every
          // schema kind and also dodges the `XxxList` rename pass.
          "json.parse(text, dyn_decode.list(decode."
          <> naming.to_snake_case(name)
          <> "_decoder()))"
        }
        Inline(inner) -> {
          // `decode` here is the generated per-spec decode module; it
          // has no `list` combinator. The list combinator lives on
          // `gleam/dynamic/decode` — imported as `dyn_decode` — so we
          // route through that.
          let inner_decoder = inline_schema_to_decoder(inner)
          "json.parse(text, dyn_decode.list(" <> inner_decoder <> "))"
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
