import gleam/option.{Some}
import oaspec/codegen/context.{type Context}
import oaspec/codegen/schema_dispatch
import oaspec/openapi/schema.{Inline, Reference}
import oaspec/openapi/spec
import oaspec/util/content_type
import oaspec/util/http
import oaspec/util/naming
import oaspec/util/string_extra as se

/// Generate response handling for a single content type.
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
    content_type.TextPlain
    | content_type.ApplicationXml
    | content_type.TextXml
    | content_type.ApplicationOctetStream ->
      case media_type.schema {
        Some(_) ->
          sb
          |> se.indent(
            4,
            http.status_code_to_int_pattern(status_code)
              <> " -> Ok("
              <> variant_name
              <> "(resp.body))",
          )
        _ ->
          sb
          |> se.indent(
            4,
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
          |> se.indent(
            4,
            http.status_code_to_int_pattern(status_code) <> " -> {",
          )
          |> se.indent(5, "case " <> decode_expr <> " {")
          |> se.indent(6, "Ok(decoded) -> Ok(" <> variant_name <> "(decoded))")
          |> se.indent(
            6,
            "Error(_) -> Error(DecodeError(detail: \"Failed to decode response body\"))",
          )
          |> se.indent(5, "}")
          |> se.indent(4, "}")
        }
        _ ->
          sb
          |> se.indent(
            4,
            http.status_code_to_int_pattern(status_code)
              <> " -> Ok("
              <> variant_name
              <> ")",
          )
      }
  }
}

/// Generate response handling for multiple content types.
/// Since the response variant uses String for multi-content (to stay type-safe),
/// all branches return resp.body directly.
pub fn generate_multi_content_response(
  sb: se.StringBuilder,
  status_code: http.HttpStatusCode,
  variant_name: String,
  _content_entries: List(#(String, spec.MediaType)),
  _op_id: String,
  _ctx: Context,
) -> se.StringBuilder {
  // Multi-content response type is always String, so just return resp.body
  sb
  |> se.indent(
    4,
    http.status_code_to_int_pattern(status_code)
      <> " -> Ok("
      <> variant_name
      <> "(resp.body))",
  )
}

/// Get the decode expression for a response body.
pub fn get_response_decode_expr(
  schema_ref: schema.SchemaRef,
  op_id: String,
  status_code: http.HttpStatusCode,
  _ctx: Context,
) -> String {
  case schema_ref {
    Reference(name:, ..) -> {
      "decode.decode_" <> naming.to_snake_case(name) <> "(resp.body)"
    }
    Inline(schema.ArraySchema(items:, ..)) ->
      case items {
        Reference(name:, ..) -> {
          "decode.decode_" <> naming.to_snake_case(name) <> "_list(resp.body)"
        }
        Inline(inner) -> {
          let inner_decoder = inline_schema_to_decoder(inner)
          "json.parse(resp.body, decode.list(" <> inner_decoder <> "))"
        }
      }
    Inline(schema.StringSchema(..)) ->
      "json.parse(resp.body, dyn_decode.string)"
    Inline(schema.IntegerSchema(..)) -> "json.parse(resp.body, dyn_decode.int)"
    Inline(schema.NumberSchema(..)) -> "json.parse(resp.body, dyn_decode.float)"
    Inline(schema.BooleanSchema(..)) -> "json.parse(resp.body, dyn_decode.bool)"
    Inline(_) -> {
      let fn_name =
        "decode_"
        <> naming.to_snake_case(op_id)
        <> "_response_"
        <> naming.to_snake_case(http.status_code_suffix(status_code))
      "decode." <> fn_name <> "(resp.body)"
    }
  }
}

/// Convert an inline schema to a decoder expression for use in generated client.
/// Uses dyn_decode (gleam/dynamic/decode) to avoid collision with the generated
/// decode module.
pub fn inline_schema_to_decoder(s: schema.SchemaObject) -> String {
  case s {
    schema.StringSchema(..) -> "dyn_decode.string"
    schema.IntegerSchema(..) -> "dyn_decode.int"
    schema.NumberSchema(..) -> "dyn_decode.float"
    schema.BooleanSchema(..) -> "dyn_decode.bool"
    _ -> "dyn_decode.string"
  }
}

/// Return a function expression that converts an array item to String.
/// Used in generated code: `list.map(param, <fn>)`.
pub fn array_item_to_string_fn(items: schema.SchemaRef, ctx: Context) -> String {
  schema_dispatch.to_string_fn(items, context.spec(ctx))
}

/// Convert a deepObject array item to a string expression.
pub fn deep_object_array_item_to_string(
  prop_ref: schema.SchemaRef,
  ctx: Context,
) -> String {
  case prop_ref {
    Inline(schema.ArraySchema(items:, ..)) ->
      schema_dispatch.schema_ref_to_string_expr(
        items,
        "item",
        context.spec(ctx),
      )
    _ -> "item"
  }
}
