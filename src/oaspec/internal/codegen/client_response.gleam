import gleam/option.{Some}
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/openapi/schema.{Inline, Reference}
import oaspec/internal/openapi/spec
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
) -> se.StringBuilder {
  case content_type.from_string(media_type_name) {
    content_type.ApplicationOctetStream ->
      case media_type.schema {
        Some(_) ->
          sb
          |> se.indent(2, http.status_code_to_int_pattern(status_code) <> " -> {")
          |> se.indent(3, "use bytes <- result.try(bytes_body(resp.body))")
          |> se.indent(3, "Ok(" <> variant_name <> "(bytes))")
          |> se.indent(2, "}")
        _ ->
          sb
          |> se.indent(
            2,
            http.status_code_to_int_pattern(status_code)
              <> " -> Ok("
              <> variant_name
              <> ")",
          )
      }

    content_type.TextPlain
    | content_type.ApplicationXml
    | content_type.TextXml ->
      case media_type.schema {
        Some(_) ->
          sb
          |> se.indent(2, http.status_code_to_int_pattern(status_code) <> " -> {")
          |> se.indent(3, "use text <- result.try(text_body(resp.body))")
          |> se.indent(3, "Ok(" <> variant_name <> "(text))")
          |> se.indent(2, "}")
        _ ->
          sb
          |> se.indent(
            2,
            http.status_code_to_int_pattern(status_code)
              <> " -> Ok("
              <> variant_name
              <> ")",
          )
      }

    _ ->
      case media_type.schema {
        Some(schema_ref) -> {
          let decode_expr =
            get_response_decode_expr(schema_ref, op_id, status_code, ctx)
          sb
          |> se.indent(2, http.status_code_to_int_pattern(status_code) <> " -> {")
          |> se.indent(3, "use text <- result.try(text_body(resp.body))")
          |> se.indent(3, "case " <> decode_expr <> " {")
          |> se.indent(4, "Ok(decoded) -> Ok(" <> variant_name <> "(decoded))")
          |> se.indent(
            4,
            "Error(_) -> Error(DecodeFailure(detail: \"Failed to decode response body\"))",
          )
          |> se.indent(3, "}")
          |> se.indent(2, "}")
        }
        _ ->
          sb
          |> se.indent(
            2,
            http.status_code_to_int_pattern(status_code)
              <> " -> Ok("
              <> variant_name
              <> ")",
          )
      }
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
) -> se.StringBuilder {
  sb
  |> se.indent(2, http.status_code_to_int_pattern(status_code) <> " -> {")
  |> se.indent(3, "use text <- result.try(text_body(resp.body))")
  |> se.indent(3, "Ok(" <> variant_name <> "(text))")
  |> se.indent(2, "}")
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
