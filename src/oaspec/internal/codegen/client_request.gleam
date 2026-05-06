import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/codegen/ir_build
import oaspec/internal/codegen/operation_ir
import oaspec/internal/codegen/schema_dispatch
import oaspec/internal/openapi/dedup
import oaspec/internal/openapi/schema.{Inline, Reference}
import oaspec/internal/openapi/spec.{type Resolved, ParameterSchema, Value}
import oaspec/internal/util/content_type
import oaspec/internal/util/naming
import oaspec/internal/util/string_extra as se

/// Map from a parameter's `(wire name, location)` pair to its deduped Gleam
/// field name within an operation. Used to keep type emission, server
/// dispatch, and client builders in sync when two parameters in different
/// locations would otherwise collide on the same snake_case field.
pub type ParamFieldNames =
  Dict(#(String, spec.ParameterIn), String)

/// Build a `(name, in)` → deduped-field-name map for a single operation.
/// The dedup order matches the spec's parameter order, so all codegen
/// callers that use this map agree on the final field names.
pub fn build_param_field_names(
  operation: spec.Operation(Resolved),
) -> ParamFieldNames {
  let resolved =
    list.filter_map(operation.parameters, fn(r) {
      case r {
        Value(p) -> Ok(p)
        _ -> Error(Nil)
      }
    })
  let deduped = dedup.dedup_param_field_names(resolved)
  list.zip(resolved, deduped)
  |> list.fold(dict.new(), fn(acc, pair) {
    let #(param, name) = pair
    dict.insert(acc, #(param.name, param.in_), name)
  })
}

/// Look up the deduped field name for a parameter. The map is built from
/// the same operation the caller iterates, so the lookup always hits —
/// the fallback is just a safety net that keeps the output valid Gleam
/// if a caller ever passes a mismatched map.
pub fn field_name_for(
  map: ParamFieldNames,
  param: spec.Parameter(Resolved),
) -> String {
  case dict.get(map, #(param.name, param.in_)) {
    Ok(name) -> name
    // nolint: thrown_away_error -- dict.get's Error just means the map did not carry this parameter; fall back to raw snake_case so codegen still produces a valid (if un-deduped) identifier
    Error(_) -> naming.to_snake_case(param.name)
  }
}

/// Build the call-site argument list for the `_with_request` wrapper that
/// unpacks a `request_types.*Request` record into the flat client function
/// it delegates to. Returns `None` if the operation uses a multi-content
/// body (where the flat API also takes a `content_type` argument that the
/// request type does not carry).
pub fn build_request_object_call_args(
  path_params: List(spec.Parameter(Resolved)),
  query_params: List(spec.Parameter(Resolved)),
  header_params: List(spec.Parameter(Resolved)),
  cookie_params: List(spec.Parameter(Resolved)),
  operation: spec.Operation(Resolved),
) -> Option(String) {
  let all_params =
    list.append(path_params, query_params)
    |> list.append(header_params)
    |> list.append(cookie_params)
  let has_body = case operation.request_body {
    Some(_) -> True
    None -> False
  }
  // Operations with no parameters and no body produce no `<Op>Request` type,
  // so there is nothing for the wrapper to accept. Skip the wrapper.
  case list.is_empty(all_params), has_body {
    True, False -> None
    _, _ -> {
      let field_names = build_param_field_names(operation)
      let param_refs =
        list.map(all_params, fn(p) { "req." <> field_name_for(field_names, p) })
      case operation.request_body {
        Some(Value(rb)) -> {
          let content_entries = ir_build.sorted_entries(rb.content)
          case content_entries {
            [_, _, ..] -> None
            _ -> Some(string.join(list.append(param_refs, ["req.body"]), ", "))
          }
        }
        _ -> Some(string.join(param_refs, ", "))
      }
    }
  }
}

/// Build parameter list for function signature.
pub fn build_param_list(
  path_params: List(spec.Parameter(Resolved)),
  query_params: List(spec.Parameter(Resolved)),
  header_params: List(spec.Parameter(Resolved)),
  cookie_params: List(spec.Parameter(Resolved)),
  operation: spec.Operation(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  let all_params =
    list.append(path_params, query_params)
    |> list.append(header_params)
    |> list.append(cookie_params)
  let field_names = build_param_field_names(operation)

  let param_strs =
    list.map(all_params, fn(p) {
      let param_name = field_name_for(field_names, p)
      let param_type = param_to_type(p, ctx)
      ", " <> param_name <> " " <> param_name <> ": " <> param_type
    })

  let body_param = case operation.request_body {
    Some(Value(rb)) -> {
      let body_type = get_body_type(rb, op_id)
      let wrapped_type = case rb.required {
        True -> body_type
        False -> "Option(" <> body_type <> ")"
      }
      let content_entries = ir_build.sorted_entries(rb.content)
      case content_entries {
        // Multi-content: add content_type param before body
        [_, _, ..] -> [
          ", content_type content_type: String",
          ", body body: " <> wrapped_type,
        ]
        _ -> [", body body: " <> wrapped_type]
      }
    }
    _ -> []
  }

  string.join(list.append(param_strs, body_param), "")
}

/// Convert a parameter to its Gleam type string.
fn param_to_type(param: spec.Parameter(Resolved), ctx: Context) -> String {
  let base =
    schema_dispatch.resolve_param_type(spec.parameter_schema(param), ctx)
  case param.required {
    True -> base
    False -> "Option(" <> base <> ")"
  }
}

/// Convert a parameter value to its String representation for URL/header use.
pub fn param_to_string_expr(
  param: spec.Parameter(Resolved),
  param_name: String,
  ctx: Context,
) -> String {
  case param.payload {
    ParameterSchema(Inline(schema.ArraySchema(items:, ..))) -> {
      let item_to_str = schema_dispatch.to_string_fn(items, ctx)
      "string.join(list.map("
      <> param_name
      <> ", "
      <> item_to_str
      <> "), \",\")"
    }
    ParameterSchema(Inline(s)) -> schema_dispatch.to_string_expr(s, param_name)
    ParameterSchema(Reference(..) as schema_ref) -> {
      // Resolve the $ref to determine the actual schema type
      case context.resolve_schema_ref(schema_ref, ctx) {
        Ok(schema.ArraySchema(items:, ..)) -> {
          let item_to_str = schema_dispatch.to_string_fn(items, ctx)
          "string.join(list.map("
          <> param_name
          <> ", "
          <> item_to_str
          <> "), \",\")"
        }
        _ ->
          schema_dispatch.schema_ref_to_string_expr(schema_ref, param_name, ctx)
      }
    }
    _ -> param_name
  }
}

/// Convert an optional param value (bound to `v`) to string.
pub fn to_str_for_optional_value(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> String {
  case param.payload {
    ParameterSchema(Inline(schema.ArraySchema(items:, ..))) -> {
      let item_to_str = schema_dispatch.to_string_fn(items, ctx)
      "string.join(list.map(v, " <> item_to_str <> "), \",\")"
    }
    ParameterSchema(Inline(s)) -> schema_dispatch.to_string_expr(s, "v")
    ParameterSchema(Reference(..) as schema_ref) -> {
      case context.resolve_schema_ref(schema_ref, ctx) {
        Ok(schema.ArraySchema(items:, ..)) -> {
          let item_to_str = schema_dispatch.to_string_fn(items, ctx)
          "string.join(list.map(v, " <> item_to_str <> "), \",\")"
        }
        _ -> schema_dispatch.schema_ref_to_string_expr(schema_ref, "v", ctx)
      }
    }
    _ -> "v"
  }
}

/// Get the Gleam type for a request body parameter.
///
/// Issue #485: an `application/octet-stream` request body is raw
/// bytes — the README's mode-specific table promises `BitArray`,
/// the client wraps it in `transport.BytesBody` (which expects
/// `BitArray`), and forcing it through `String` means arbitrary
/// binary payloads cannot round-trip. The `String` fallback for
/// every other content type stays unchanged.
pub fn get_body_type(rb: spec.RequestBody(Resolved), op_id: String) -> String {
  let content_entries = ir_build.sorted_entries(rb.content)
  case content_entries {
    // Multiple content types: use pre-serialized String
    [_, _, ..] -> "String"
    [#(media_type_name, media_type)] ->
      case content_type.from_string(media_type_name) {
        content_type.ApplicationOctetStream | content_type.Wildcard ->
          "BitArray"
        _ ->
          case media_type.schema {
            Some(Reference(name:, ..)) ->
              "types." <> naming.schema_to_type_name(name)
            Some(Inline(schema.StringSchema(..))) -> "String"
            Some(Inline(schema.IntegerSchema(..))) -> "Int"
            Some(Inline(schema.NumberSchema(..))) -> "Float"
            Some(Inline(schema.BooleanSchema(..))) -> "Bool"
            Some(Inline(_)) ->
              "types." <> naming.schema_to_type_name(op_id) <> "RequestBody"
            _ -> "String"
          }
      }
    [] -> "String"
  }
}

/// Get the encode expression for a request body.
pub fn get_body_encode_expr(
  rb: spec.RequestBody(Resolved),
  op_id: String,
  _ctx: Context,
) -> String {
  let content_entries = ir_build.sorted_entries(rb.content)
  case content_entries {
    [#(_, media_type), ..] ->
      case media_type.schema {
        Some(Reference(name:, ..)) -> {
          "encode.encode_" <> naming.to_snake_case(name) <> "(body)"
        }
        Some(Inline(schema.StringSchema(..))) ->
          "json.to_string(json.string(body))"
        Some(Inline(schema.IntegerSchema(..))) ->
          "json.to_string(json.int(body))"
        Some(Inline(schema.NumberSchema(..))) ->
          "json.to_string(json.float(body))"
        Some(Inline(schema.BooleanSchema(..))) ->
          "json.to_string(json.bool(body))"
        Some(Inline(_)) -> {
          let fn_name =
            "encode_" <> naming.to_snake_case(op_id) <> "_request_body"
          "encode." <> fn_name <> "(body)"
        }
        _ -> "body"
      }
    [] -> "body"
  }
}

/// Generate multipart/form-data body encoding in the client function.
pub fn generate_multipart_body(
  sb: se.StringBuilder,
  rb: spec.RequestBody(Resolved),
  _op_id: String,
  ctx: Context,
) -> se.StringBuilder {
  let boundary = "----oaspec-boundary"
  let content_entries = ir_build.sorted_entries(rb.content)
  let #(properties, required_fields) = case content_entries {
    [#(_, media_type), ..] ->
      case media_type.schema {
        Some(Inline(schema.ObjectSchema(properties:, required:, ..))) -> #(
          ir_build.sorted_entries(properties),
          required,
        )
        Some(Reference(..) as schema_ref) ->
          case context.resolve_schema_ref(schema_ref, ctx) {
            Ok(schema.ObjectSchema(properties:, required:, ..)) -> {
              #(ir_build.sorted_entries(properties), required)
            }
            _ -> #([], [])
          }
        _ -> #([], [])
      }
    _ -> #([], [])
  }

  let sb =
    sb
    |> se.indent(1, "let boundary = \"" <> boundary <> "\"")
    |> se.indent(1, "let parts = []")

  let sb =
    list.fold(properties, sb, fn(sb, prop) {
      let #(field_name, field_schema) = prop
      let gleam_field = naming.to_snake_case(field_name)
      let is_required = list.contains(required_fields, field_name)
      case multipart_field_kind(field_schema, ctx) {
        MultipartArrayKind(items) ->
          emit_multipart_array_field(
            sb,
            field_name,
            gleam_field,
            items,
            is_required,
            ctx,
          )
        MultipartObjectKind ->
          emit_multipart_object_field(
            sb,
            field_name,
            gleam_field,
            field_schema,
            is_required,
            ctx,
          )
        MultipartBinaryKind ->
          emit_multipart_simple_field(
            sb,
            field_name,
            gleam_field,
            "",
            True,
            is_required,
          )
        MultipartScalarKind ->
          emit_multipart_simple_field(
            sb,
            field_name,
            gleam_field,
            multipart_field_to_string_fn(field_schema, ctx),
            False,
            is_required,
          )
      }
    })

  sb
  |> se.indent(
    1,
    "let body_str = string.join(parts, \"\") <> \"--\" <> boundary <> \"--\\r\\n\"",
  )
  |> se.indent(
    1,
    "let body_content_type = \"multipart/form-data; boundary=\" <> boundary",
  )
}

pub fn multipart_field_is_binary(
  field_schema: schema.SchemaRef,
  ctx: Context,
) -> Bool {
  case field_schema {
    Inline(schema.StringSchema(format: Some("binary"), ..)) -> True
    Reference(..) as schema_ref ->
      case context.resolve_schema_ref(schema_ref, ctx) {
        Ok(schema.StringSchema(format: Some("binary"), ..)) -> True
        _ -> False
      }
    _ -> False
  }
}

/// Issue #503: dispatch each multipart field by its high-level shape so
/// the generator can emit per-element parts for arrays and a single
/// JSON-encoded part for objects, while keeping the existing scalar /
/// binary paths unchanged.
type MultipartFieldKind {
  MultipartScalarKind
  MultipartBinaryKind
  MultipartArrayKind(items: schema.SchemaRef)
  MultipartObjectKind
}

fn multipart_field_kind(
  field_schema: schema.SchemaRef,
  ctx: Context,
) -> MultipartFieldKind {
  use <- bool.guard(
    multipart_field_is_binary(field_schema, ctx),
    MultipartBinaryKind,
  )
  case field_schema {
    Inline(schema.ArraySchema(items:, ..)) -> MultipartArrayKind(items)
    Inline(schema.ObjectSchema(..)) -> MultipartObjectKind
    Reference(..) as schema_ref ->
      case context.resolve_schema_ref(schema_ref, ctx) {
        Ok(schema.ArraySchema(items:, ..)) -> MultipartArrayKind(items)
        Ok(schema.ObjectSchema(..)) -> MultipartObjectKind
        _ -> MultipartScalarKind
      }
    _ -> MultipartScalarKind
  }
}

/// Emit a single multipart part for a scalar or binary field. The
/// scalar path stringifies the value (or uses it directly when the
/// schema is already `String`); the binary path emits the
/// `Content-Type: application/octet-stream` header and passes the
/// value through unchanged.
fn emit_multipart_simple_field(
  sb: se.StringBuilder,
  field_name: String,
  gleam_field: String,
  to_string_fn: String,
  is_binary: Bool,
  is_required: Bool,
) -> se.StringBuilder {
  let part_header_binary =
    "\"--\" <> boundary <> \"\\r\\nContent-Disposition: form-data; name=\\\""
    <> field_name
    <> "\\\"; filename=\\\""
    <> field_name
    <> "\\\"\\r\\nContent-Type: application/octet-stream\\r\\n\\r\\n\""
  let part_header_text =
    "\"--\" <> boundary <> \"\\r\\nContent-Disposition: form-data; name=\\\""
    <> field_name
    <> "\\\"\\r\\n\\r\\n\""
  let part_header = case is_binary {
    True -> part_header_binary
    False -> part_header_text
  }
  case is_required {
    True -> {
      let value_expr = case to_string_fn {
        "" -> "body." <> gleam_field
        fn_name -> fn_name <> "(body." <> gleam_field <> ")"
      }
      sb
      |> se.indent(
        1,
        "let parts = ["
          <> part_header
          <> " <> "
          <> value_expr
          <> " <> \"\\r\\n\", ..parts]",
      )
    }
    False -> {
      let value_expr = case to_string_fn {
        "" -> "v"
        fn_name -> fn_name <> "(v)"
      }
      sb
      |> se.indent(1, "let parts = case body." <> gleam_field <> " {")
      |> se.indent(
        2,
        "Some(v) -> ["
          <> part_header
          <> " <> "
          <> value_expr
          <> " <> \"\\r\\n\", ..parts]",
      )
      |> se.indent(2, "None -> parts")
      |> se.indent(1, "}")
    }
  }
}

/// Issue #503: emit one multipart part per element of an array field,
/// folding the input list into the running `parts` accumulator. Each
/// element shares the field name (`name="expand"` repeated) so the
/// receiver assembles the array from the repeated parts. Optional
/// arrays guard the fold behind a `Some(v) -> ... None -> parts` arm.
fn emit_multipart_array_field(
  sb: se.StringBuilder,
  field_name: String,
  gleam_field: String,
  items: schema.SchemaRef,
  is_required: Bool,
  ctx: Context,
) -> se.StringBuilder {
  let part_header =
    "\"--\" <> boundary <> \"\\r\\nContent-Disposition: form-data; name=\\\""
    <> field_name
    <> "\\\"\\r\\n\\r\\n\""
  let item_to_string =
    schema_dispatch.schema_ref_to_string_expr(items, "item", ctx)
  let fold_expr = fn(list_expr: String) -> String {
    "list.fold("
    <> list_expr
    <> ", parts, fn(acc, item) { ["
    <> part_header
    <> " <> "
    <> item_to_string
    <> " <> \"\\r\\n\", ..acc] })"
  }
  case is_required {
    True ->
      sb
      |> se.indent(1, "let parts = " <> fold_expr("body." <> gleam_field))
    False ->
      sb
      |> se.indent(1, "let parts = case body." <> gleam_field <> " {")
      |> se.indent(2, "Some(v) -> " <> fold_expr("v"))
      |> se.indent(2, "None -> parts")
      |> se.indent(1, "}")
  }
}

/// Issue #503: emit a multipart part for an object field. Per OAS 3
/// the default serialization is a single part with
/// `Content-Type: application/json` carrying the JSON-encoded value.
/// The encoder name is derived from the post-hoist schema reference;
/// inline objects survive only when they would not otherwise be
/// hoisted (rare in real specs), in which case we fall back to the
/// op-id-derived synthetic name produced by `ir_build`.
fn emit_multipart_object_field(
  sb: se.StringBuilder,
  field_name: String,
  gleam_field: String,
  field_schema: schema.SchemaRef,
  is_required: Bool,
  ctx: Context,
) -> se.StringBuilder {
  let part_header =
    "\"--\" <> boundary <> \"\\r\\nContent-Disposition: form-data; name=\\\""
    <> field_name
    <> "\\\"\\r\\nContent-Type: application/json\\r\\n\\r\\n\""
  let encoded_value = fn(input_expr: String) -> String {
    multipart_object_encode_expr(field_schema, input_expr, ctx)
  }
  case is_required {
    True ->
      sb
      |> se.indent(
        1,
        "let parts = ["
          <> part_header
          <> " <> "
          <> encoded_value("body." <> gleam_field)
          <> " <> \"\\r\\n\", ..parts]",
      )
    False ->
      sb
      |> se.indent(1, "let parts = case body." <> gleam_field <> " {")
      |> se.indent(
        2,
        "Some(v) -> ["
          <> part_header
          <> " <> "
          <> encoded_value("v")
          <> " <> \"\\r\\n\", ..parts]",
      )
      |> se.indent(2, "None -> parts")
      |> se.indent(1, "}")
  }
}

fn multipart_object_encode_expr(
  field_schema: schema.SchemaRef,
  input_expr: String,
  _ctx: Context,
) -> String {
  case field_schema {
    Reference(name:, ..) ->
      // The encoder module exports `encode_<snake>_json/1` for every
      // hoisted component schema; call it through the `encode` import
      // alias so the generated client compiles unchanged regardless of
      // whether `encode.gleam` lives in the same package.
      "json.to_string(encode.encode_"
      <> naming.to_snake_case(name)
      <> "_json("
      <> input_expr
      <> "))"
    _ ->
      // Inline object schemas survive only when hoist intentionally
      // left them inline; fall back to a `string.inspect` so the
      // generated code at least compiles. Real specs (Stripe) put
      // these objects under named components, which take the
      // Reference branch above.
      "string.inspect(" <> input_expr <> ")"
  }
}

fn multipart_field_to_string_fn(
  field_schema: schema.SchemaRef,
  ctx: Context,
) -> String {
  let result = schema_dispatch.to_string_fn(field_schema, ctx)
  // Return "" for identity functions since callers use "" to mean "no conversion"
  case result {
    "fn(x) { x }" -> ""
    _ -> result
  }
}

/// Convert an array field's items to a string expression for form-urlencoded encoding.
/// Returns an expression that converts `item` to a String.
fn form_array_item_to_string(
  field_schema: schema.SchemaRef,
  ctx: Context,
) -> String {
  case field_schema {
    Inline(schema.ArraySchema(items:, ..)) ->
      schema_dispatch.schema_ref_to_string_expr(items, "item", ctx)
    _ -> "item"
  }
}

/// True when `schema_ref` resolves to an `ObjectSchema` post-`$ref`
/// resolution. Used to dispatch nested-form encoding into the
/// recursive bracket-key path.
fn schema_resolves_to_object(schema_ref: schema.SchemaRef, ctx: Context) -> Bool {
  case schema_ref {
    Inline(schema.ObjectSchema(..)) -> True
    Reference(..) ->
      case context.resolve_schema_ref(schema_ref, ctx) {
        Ok(schema.ObjectSchema(..)) -> True
        _ -> False
      }
    _ -> False
  }
}

/// True when `schema_ref` resolves to an `ArraySchema`.
fn schema_resolves_to_array(schema_ref: schema.SchemaRef, ctx: Context) -> Bool {
  case schema_ref {
    Inline(schema.ArraySchema(..)) -> True
    Reference(..) ->
      case context.resolve_schema_ref(schema_ref, ctx) {
        Ok(schema.ArraySchema(..)) -> True
        _ -> False
      }
    _ -> False
  }
}

/// Resolve `schema_ref` to its ArraySchema items (post-`$ref`).
/// Caller is expected to have already gated on `schema_resolves_to_array`.
fn array_items_of(
  schema_ref: schema.SchemaRef,
  ctx: Context,
) -> Option(schema.SchemaRef) {
  case schema_ref {
    Inline(schema.ArraySchema(items:, ..)) -> Some(items)
    Reference(..) ->
      case context.resolve_schema_ref(schema_ref, ctx) {
        Ok(schema.ArraySchema(items:, ..)) -> Some(items)
        _ -> None
      }
    _ -> None
  }
}

/// Emit serialisation for an array sub-field whose runtime type is
/// `List(<inner>)`. The wire format depends on what `<inner>` is:
///
///   - **primitive items**: OAS `form` style with `explode: true`,
///     i.e. the same key is repeated per element
///     (`<prefix>=v1&<prefix>=v2`). This is what the OAS spec defines
///     as the default and what oaspec's existing server decoder
///     already parses, so generated clients and servers round-trip
///     cleanly.
///   - **object items**: numerical bracket index per element
///     (`<prefix>[0][<prop>]=v`). OAS leaves this case undefined; we
///     pick the form Stripe / qs (`indices` mode) / jQuery / Rails
///     all decode interoperably — the only encoding agreed on across
///     mainstream form-body parsers.
///   - **nested array items**: bracket-index recursion
///     (`<prefix>[0][0]=v`).
fn generate_form_indexed_array(
  sb: se.StringBuilder,
  key_prefix_quoted: String,
  accessor: String,
  items_schema: schema.SchemaRef,
  is_required: Bool,
  indent_base: Int,
  parts_var: String,
  ctx: Context,
) -> se.StringBuilder {
  case is_required {
    True ->
      emit_array_fold(
        sb,
        key_prefix_quoted,
        accessor,
        items_schema,
        indent_base,
        parts_var,
        ctx,
      )
    False ->
      sb
      |> se.indent(
        indent_base,
        "let " <> parts_var <> " = case " <> accessor <> " {",
      )
      |> se.indent(indent_base + 1, "Some(items) -> {")
      |> emit_array_fold(
        key_prefix_quoted,
        "items",
        items_schema,
        indent_base + 2,
        parts_var,
        ctx,
      )
      |> se.indent(indent_base + 1, "}")
      |> se.indent(indent_base + 1, "None -> " <> parts_var)
      |> se.indent(indent_base, "}")
  }
}

fn emit_array_fold(
  sb: se.StringBuilder,
  key_prefix_quoted: String,
  list_expr: String,
  items_schema: schema.SchemaRef,
  indent_base: Int,
  parts_var: String,
  ctx: Context,
) -> se.StringBuilder {
  case
    schema_resolves_to_object(items_schema, ctx),
    schema_resolves_to_array(items_schema, ctx)
  {
    True, _ -> {
      // Object items: indexed bracket — `<prefix>[<i>][<prop>]=<v>`.
      let element_key_expr =
        key_prefix_quoted <> " <> \"[\" <> int.to_string(idx) <> \"]\""
      sb
      |> se.indent(
        indent_base,
        "let "
          <> parts_var
          <> " = list.index_fold("
          <> list_expr
          <> ", "
          <> parts_var
          <> ", fn(acc, item, idx) {",
      )
      |> emit_form_object_recurse(
        element_key_expr,
        "item",
        items_schema,
        True,
        indent_base + 1,
        "acc",
        ctx,
      )
      |> se.indent(indent_base + 1, "acc")
      |> se.indent(indent_base, "})")
    }
    _, True -> {
      // Nested array items (rare, but representable):
      // `<prefix>[<i>][<j>]=v`.
      let element_key_expr =
        key_prefix_quoted <> " <> \"[\" <> int.to_string(idx) <> \"]\""
      case array_items_of(items_schema, ctx) {
        Some(inner_items) ->
          sb
          |> se.indent(
            indent_base,
            "let "
              <> parts_var
              <> " = list.index_fold("
              <> list_expr
              <> ", "
              <> parts_var
              <> ", fn(acc, item, idx) {",
          )
          |> emit_array_fold(
            element_key_expr,
            "item",
            inner_items,
            indent_base + 1,
            "acc",
            ctx,
          )
          |> se.indent(indent_base + 1, "acc")
          |> se.indent(indent_base, "})")
        None -> sb
      }
    }
    False, False -> {
      // Primitive items: OAS form/explode default — repeat the same
      // key per element. Round-trips cleanly with the existing
      // generated server decoder.
      let item_value_expr = case
        schema_dispatch.to_string_fn(items_schema, ctx)
      {
        "fn(x) { x }" -> "item"
        fn_name -> fn_name <> "(item)"
      }
      sb
      |> se.indent(
        indent_base,
        "let "
          <> parts_var
          <> " = list.fold("
          <> list_expr
          <> ", "
          <> parts_var
          <> ", fn(acc, item) {",
      )
      |> se.indent(
        indent_base + 1,
        "["
          <> key_prefix_quoted
          <> " <> \"=\" <> uri.percent_encode("
          <> item_value_expr
          <> "), ..acc]",
      )
      |> se.indent(indent_base, "})")
    }
  }
}

/// Recurse into the properties of an object whose runtime accessor is
/// `accessor`. Each sub-property is emitted with key
/// `<key_prefix>[<sub>]=...`. Used both for top-level object fields
/// and for object items inside arrays. Mutates `acc` (or whatever the
/// caller's `parts_var` is) — the caller is responsible for emitting
/// the final `acc` line if needed.
fn emit_form_object_recurse(
  sb: se.StringBuilder,
  key_prefix_quoted: String,
  accessor: String,
  schema_ref: schema.SchemaRef,
  _is_required: Bool,
  indent_base: Int,
  parts_var: String,
  ctx: Context,
) -> se.StringBuilder {
  let resolved = context.resolve_schema_ref(schema_ref, ctx)
  case resolved {
    Ok(schema.ObjectSchema(properties:, required:, ..)) -> {
      let props = ir_build.sorted_entries(properties)
      list.fold(props, sb, fn(sb, entry) {
        let #(prop_name, prop_ref) = entry
        let prop_field = naming.to_snake_case(prop_name)
        let prop_accessor = accessor <> "." <> prop_field
        let prop_required = list.contains(required, prop_name)
        let sub_key_quoted =
          key_prefix_quoted <> " <> \"[" <> prop_name <> "]\""
        emit_form_field(
          sb,
          sub_key_quoted,
          prop_accessor,
          prop_ref,
          prop_required,
          indent_base,
          parts_var,
          ctx,
        )
      })
    }
    _ -> sb
  }
}

/// Single dispatch point for "emit one field whose runtime accessor
/// is `accessor` under a key built from `key_prefix_quoted`". Routes
/// objects through `emit_form_object_recurse`, arrays through
/// `generate_form_indexed_array`, and primitive scalars to a direct
/// emit. Used inside `emit_form_object_recurse` so deeply nested
/// shapes terminate cleanly at primitives.
fn emit_form_field(
  sb: se.StringBuilder,
  key_prefix_quoted: String,
  accessor: String,
  schema_ref: schema.SchemaRef,
  is_required: Bool,
  indent_base: Int,
  parts_var: String,
  ctx: Context,
) -> se.StringBuilder {
  case
    schema_resolves_to_object(schema_ref, ctx),
    schema_resolves_to_array(schema_ref, ctx)
  {
    True, _ -> {
      case is_required {
        True ->
          emit_form_object_recurse(
            sb,
            key_prefix_quoted,
            accessor,
            schema_ref,
            True,
            indent_base,
            parts_var,
            ctx,
          )
        False -> {
          sb
          |> se.indent(
            indent_base,
            "let " <> parts_var <> " = case " <> accessor <> " {",
          )
          |> se.indent(indent_base + 1, "Some(obj) -> {")
          |> se.indent(indent_base + 2, "let acc2 = " <> parts_var)
          |> emit_form_object_recurse(
            key_prefix_quoted,
            "obj",
            schema_ref,
            True,
            indent_base + 2,
            "acc2",
            ctx,
          )
          |> se.indent(indent_base + 2, "acc2")
          |> se.indent(indent_base + 1, "}")
          |> se.indent(indent_base + 1, "None -> " <> parts_var)
          |> se.indent(indent_base, "}")
        }
      }
    }
    _, True -> {
      case array_items_of(schema_ref, ctx) {
        Some(items) ->
          generate_form_indexed_array(
            sb,
            key_prefix_quoted,
            accessor,
            items,
            is_required,
            indent_base,
            parts_var,
            ctx,
          )
        None -> sb
      }
    }
    False, False -> {
      let to_str = multipart_field_to_string_fn(schema_ref, ctx)
      case is_required {
        True -> {
          let value_expr = case to_str {
            "" -> accessor
            fn_name -> fn_name <> "(" <> accessor <> ")"
          }
          sb
          |> se.indent(
            indent_base,
            "let "
              <> parts_var
              <> " = ["
              <> key_prefix_quoted
              <> " <> \"=\" <> uri.percent_encode("
              <> value_expr
              <> "), .."
              <> parts_var
              <> "]",
          )
        }
        False -> {
          let some_value_expr = case to_str {
            "" -> "v"
            fn_name -> fn_name <> "(v)"
          }
          sb
          |> se.indent(
            indent_base,
            "let " <> parts_var <> " = case " <> accessor <> " {",
          )
          |> se.indent(
            indent_base + 1,
            "Some(v) -> ["
              <> key_prefix_quoted
              <> " <> \"=\" <> uri.percent_encode("
              <> some_value_expr
              <> "), .."
              <> parts_var
              <> "]",
          )
          |> se.indent(indent_base + 1, "None -> " <> parts_var)
          |> se.indent(indent_base, "}")
        }
      }
    }
  }
}

/// Generate form encoding for a nested object property.
/// Serializes as field[subkey]=value for each sub-property.
fn generate_form_nested_object(
  sb: se.StringBuilder,
  field_name: String,
  gleam_field: String,
  field_schema: schema.SchemaRef,
  is_required: Bool,
  ctx: Context,
) -> se.StringBuilder {
  let resolved = context.resolve_schema_ref(field_schema, ctx)
  let sub_props = case resolved {
    Ok(schema.ObjectSchema(properties:, required:, ..)) -> #(
      ir_build.sorted_entries(properties),
      required,
    )
    _ -> #([], [])
  }
  let #(props, required_fields) = sub_props
  let accessor_prefix = case is_required {
    True -> "body." <> gleam_field
    False -> "obj"
  }
  let sb = case is_required {
    True -> sb
    False ->
      sb
      |> se.indent(1, "let form_parts = case body." <> gleam_field <> " {")
      |> se.indent(2, "Some(obj) -> {")
      |> se.indent(3, "let fp = form_parts")
  }
  let indent_base = case is_required {
    True -> 1
    False -> 3
  }
  let parts_var = case is_required {
    True -> "form_parts"
    False -> "fp"
  }
  let sb =
    list.fold(props, sb, fn(sb, entry) {
      let #(sub_name, sub_ref) = entry
      let sub_field = naming.to_snake_case(sub_name)
      let sub_accessor = accessor_prefix <> "." <> sub_field
      let sub_required = list.contains(required_fields, sub_name)
      // Check if sub-property is an object — need recursive bracket encoding
      let is_sub_object = case sub_ref {
        Inline(schema.ObjectSchema(..)) -> True
        Reference(..) as sr ->
          case context.resolve_schema_ref(sr, ctx) {
            Ok(schema.ObjectSchema(..)) -> True
            _ -> False
          }
        _ -> False
      }
      let is_sub_array = case sub_ref {
        Inline(schema.ArraySchema(..)) -> True
        Reference(..) as sr ->
          case context.resolve_schema_ref(sr, ctx) {
            Ok(schema.ArraySchema(..)) -> True
            _ -> False
          }
        _ -> False
      }
      case is_sub_object, is_sub_array {
        True, _ ->
          // Recurse: generate meta[author][name]=value encoding
          generate_form_bracket_fields(
            sb,
            field_name <> "[" <> sub_name <> "]",
            sub_accessor,
            sub_ref,
            sub_required,
            indent_base,
            parts_var,
            ctx,
          )
        _, True -> {
          // Object property whose value is an array — emit indexed
          // bracket form (`<parent>[<sub>][<i>]=<v>` for primitive
          // items, `<parent>[<sub>][<i>][<prop>]=<v>` for object
          // items).
          case array_items_of(sub_ref, ctx) {
            Some(items_schema) ->
              generate_form_indexed_array(
                sb,
                "\"" <> field_name <> "[" <> sub_name <> "]\"",
                sub_accessor,
                items_schema,
                sub_required,
                indent_base,
                parts_var,
                ctx,
              )
            None -> sb
          }
        }
        False, False -> {
          let to_str = multipart_field_to_string_fn(sub_ref, ctx)
          case sub_required {
            True -> {
              let value_expr = case to_str {
                "" -> sub_accessor
                fn_name -> fn_name <> "(" <> sub_accessor <> ")"
              }
              sb
              |> se.indent(
                indent_base,
                "let "
                  <> parts_var
                  <> " = [\""
                  <> field_name
                  <> "["
                  <> sub_name
                  <> "]=\" <> uri.percent_encode("
                  <> value_expr
                  <> "), .."
                  <> parts_var
                  <> "]",
              )
            }
            False -> {
              sb
              |> se.indent(
                indent_base,
                "let " <> parts_var <> " = case " <> sub_accessor <> " {",
              )
              |> se.indent(
                indent_base + 1,
                "Some(v) -> [\""
                  <> field_name
                  <> "["
                  <> sub_name
                  <> "]=\" <> uri.percent_encode("
                  <> {
                  case to_str {
                    "" -> "v"
                    fn_name -> fn_name <> "(v)"
                  }
                }
                  <> "), .."
                  <> parts_var
                  <> "]",
              )
              |> se.indent(indent_base + 1, "None -> " <> parts_var)
              |> se.indent(indent_base, "}")
            }
          }
        }
      }
    })
  case is_required {
    True -> sb
    False ->
      sb
      |> se.indent(3, "fp")
      |> se.indent(2, "}")
      |> se.indent(2, "None -> form_parts")
      |> se.indent(1, "}")
  }
}

/// Recursively generate bracket-encoded form fields for nested objects.
/// Produces key[sub]=value for leaf fields and recurses for object children.
fn generate_form_bracket_fields(
  sb: se.StringBuilder,
  key_prefix: String,
  accessor_prefix: String,
  field_schema: schema.SchemaRef,
  _is_required: Bool,
  indent_base: Int,
  parts_var: String,
  ctx: Context,
) -> se.StringBuilder {
  let resolved = context.resolve_schema_ref(field_schema, ctx)
  case resolved {
    Ok(schema.ObjectSchema(properties:, required:, ..)) -> {
      let props = ir_build.sorted_entries(properties)
      list.fold(props, sb, fn(sb, entry) {
        let #(prop_name, prop_ref) = entry
        let prop_field = naming.to_snake_case(prop_name)
        let prop_accessor = accessor_prefix <> "." <> prop_field
        let prop_required = list.contains(required, prop_name)
        let is_obj = case prop_ref {
          Inline(schema.ObjectSchema(..)) -> True
          Reference(..) as sr ->
            case context.resolve_schema_ref(sr, ctx) {
              Ok(schema.ObjectSchema(..)) -> True
              _ -> False
            }
          _ -> False
        }
        let is_arr = case prop_ref {
          Inline(schema.ArraySchema(..)) -> True
          Reference(..) as sr ->
            case context.resolve_schema_ref(sr, ctx) {
              Ok(schema.ArraySchema(..)) -> True
              _ -> False
            }
          _ -> False
        }
        case is_obj, is_arr {
          True, _ ->
            generate_form_bracket_fields(
              sb,
              key_prefix <> "[" <> prop_name <> "]",
              prop_accessor,
              prop_ref,
              prop_required,
              indent_base,
              parts_var,
              ctx,
            )
          _, True ->
            case array_items_of(prop_ref, ctx) {
              Some(items_schema) ->
                generate_form_indexed_array(
                  sb,
                  "\"" <> key_prefix <> "[" <> prop_name <> "]\"",
                  prop_accessor,
                  items_schema,
                  prop_required,
                  indent_base,
                  parts_var,
                  ctx,
                )
              None -> sb
            }
          False, False -> {
            let to_str = multipart_field_to_string_fn(prop_ref, ctx)
            case prop_required {
              True -> {
                let value_expr = case to_str {
                  "" -> prop_accessor
                  fn_name -> fn_name <> "(" <> prop_accessor <> ")"
                }
                sb
                |> se.indent(
                  indent_base,
                  "let "
                    <> parts_var
                    <> " = [\""
                    <> key_prefix
                    <> "["
                    <> prop_name
                    <> "]=\" <> uri.percent_encode("
                    <> value_expr
                    <> "), .."
                    <> parts_var
                    <> "]",
                )
              }
              False ->
                sb
                |> se.indent(
                  indent_base,
                  "let " <> parts_var <> " = case " <> prop_accessor <> " {",
                )
                |> se.indent(
                  indent_base + 1,
                  "Some(v) -> [\""
                    <> key_prefix
                    <> "["
                    <> prop_name
                    <> "]=\" <> uri.percent_encode("
                    <> {
                    case to_str {
                      "" -> "v"
                      fn_name -> fn_name <> "(v)"
                    }
                  }
                    <> "), .."
                    <> parts_var
                    <> "]",
                )
                |> se.indent(indent_base + 1, "None -> " <> parts_var)
                |> se.indent(indent_base, "}")
            }
          }
        }
      })
    }
    _ -> sb
  }
}

/// JSON encoder expression for an `encoding.<field>.contentType:
/// application/json` escape hatch. Falls back to per-property recursion
/// for inline arrays so a `tags: [string]` field can be lifted to a
/// single `json.array(...)` call without round-tripping through the
/// hoist contract.
fn form_field_json_encoder_expr(
  ref: schema.SchemaRef,
  value: String,
  _ctx: Context,
) -> String {
  case ref {
    Inline(schema.StringSchema(..)) -> "json.string(" <> value <> ")"
    Inline(schema.IntegerSchema(..)) -> "json.int(" <> value <> ")"
    Inline(schema.NumberSchema(..)) -> "json.float(" <> value <> ")"
    Inline(schema.BooleanSchema(..)) -> "json.bool(" <> value <> ")"
    Inline(schema.ArraySchema(items:, ..)) ->
      "json.array(" <> value <> ", " <> form_field_json_encoder_fn(items) <> ")"
    _ -> schema_dispatch.json_encoder_expr(ref, value)
  }
}

fn form_field_json_encoder_fn(ref: schema.SchemaRef) -> String {
  case ref {
    Inline(schema.StringSchema(..)) -> "json.string"
    Inline(schema.IntegerSchema(..)) -> "json.int"
    Inline(schema.NumberSchema(..)) -> "json.float"
    Inline(schema.BooleanSchema(..)) -> "json.bool"
    Inline(schema.ArraySchema(items:, ..)) ->
      "fn(xs) { json.array(xs, " <> form_field_json_encoder_fn(items) <> ") }"
    _ -> schema_dispatch.json_encoder_fn(ref)
  }
}

/// Returns true when a form field's schema either is — or transitively
/// contains — a composite (`oneOf` / `anyOf` / `allOf`). There is no
/// agreed-upon bracket-or-repeat wire format for composite shapes (a
/// 2025 Stripe spec hits this on `metadata`, `address`, `documents`,
/// `tags`, etc.), so the codegen lifts the entire field to the JSON
/// escape hatch — the same shape an explicit
/// `encoding.<field>.contentType: application/json` annotation
/// would request — and serialises the whole value as one
/// percent-encoded JSON string.
///
/// "Transitively" means descending into object properties and array
/// items: if any leaf schema in the field's tree is composite, the
/// whole field switches to the JSON path. Without this, fields like
/// Stripe's `documents` (object → properties → array → items → `anyOf`)
/// would slip back into the bracket-index emitter and panic in
/// `to_string_fn` after hoist.
fn field_resolves_to_composite(ref: schema.SchemaRef, ctx: Context) -> Bool {
  case resolve_schema_object(Some(ref), ctx) {
    Some(schema.OneOfSchema(..))
    | Some(schema.AnyOfSchema(..))
    | Some(schema.AllOfSchema(..)) -> True
    Some(schema.ArraySchema(items:, ..)) ->
      field_resolves_to_composite(items, ctx)
    Some(schema.ObjectSchema(properties:, ..)) ->
      dict.to_list(properties)
      |> list.any(fn(entry) {
        let #(_, child_schema) = entry
        field_resolves_to_composite(child_schema, ctx)
      })
    _ -> False
  }
}

fn resolve_schema_object(
  schema_ref: Option(schema.SchemaRef),
  ctx: Context,
) -> Option(schema.SchemaObject) {
  case schema_ref {
    Some(Inline(s)) -> Some(s)
    Some(Reference(..) as ref) ->
      case context.resolve_schema_ref(ref, ctx) {
        Ok(s) -> Some(s)
        // nolint: thrown_away_error -- unresolved refs cannot be classified; treat as non-composite and let downstream codegen fail loudly if it actually emits
        Error(_) -> None
      }
    None -> None
  }
}

/// Returns true when `encoding[<field>].contentType` resolves to
/// `application/json` (or `application/json` with parameters such as
/// `application/json; charset=utf-8`). Per OAS 3.x this triggers the
/// per-property JSON serialisation escape hatch.
fn form_encoding_is_json(
  encoding: Dict(String, spec.Encoding),
  field_name: String,
) -> Bool {
  case dict.get(encoding, field_name) {
    Ok(spec.Encoding(content_type: Some(ct), ..)) ->
      case content_type.from_string(ct) {
        content_type.ApplicationJson -> True
        _ -> False
      }
    _ -> False
  }
}

/// Generate application/x-www-form-urlencoded body encoding in the client function.
pub fn generate_form_urlencoded_body(
  sb: se.StringBuilder,
  rb: spec.RequestBody(Resolved),
  _op_id: String,
  ctx: Context,
) -> se.StringBuilder {
  let content_entries = ir_build.sorted_entries(rb.content)
  let #(properties, required_fields, encoding) = case content_entries {
    [#(_, media_type), ..] ->
      case media_type.schema {
        Some(Inline(schema.ObjectSchema(properties:, required:, ..))) -> #(
          ir_build.sorted_entries(properties),
          required,
          media_type.encoding,
        )
        Some(Reference(..) as schema_ref) ->
          case context.resolve_schema_ref(schema_ref, ctx) {
            Ok(schema.ObjectSchema(properties:, required:, ..)) -> {
              #(
                ir_build.sorted_entries(properties),
                required,
                media_type.encoding,
              )
            }
            _ -> #([], [], dict.new())
          }
        _ -> #([], [], dict.new())
      }
    _ -> #([], [], dict.new())
  }

  let sb = sb |> se.indent(1, "let form_parts = []")
  let sb =
    list.fold(properties, sb, fn(sb, prop) {
      let #(field_name, field_schema) = prop
      let gleam_field = naming.to_snake_case(field_name)
      let is_required = list.contains(required_fields, field_name)
      let is_array = case field_schema {
        Inline(schema.ArraySchema(..)) -> True
        Reference(..) as sr ->
          case context.resolve_schema_ref(sr, ctx) {
            Ok(schema.ArraySchema(..)) -> True
            _ -> False
          }
        _ -> False
      }
      let is_object = case field_schema {
        Inline(schema.ObjectSchema(..)) -> True
        Reference(..) as sr ->
          case context.resolve_schema_ref(sr, ctx) {
            Ok(schema.ObjectSchema(..)) -> True
            _ -> False
          }
        _ -> False
      }
      // Top-level array of objects (Stripe `marketing_features` shape)
      // — wire format is `<field>[<i>][<prop>]=<v>`. Distinct from
      // top-level array of primitives below, which keeps the OAS
      // `form,explode` repeat shape (`<field>=<v>&<field>=<v>`) for
      // backwards compatibility.
      let array_items = case is_array {
        True -> array_items_of(field_schema, ctx)
        False -> None
      }
      let is_array_of_object = case array_items {
        Some(items) -> schema_resolves_to_object(items, ctx)
        None -> False
      }
      let is_composite = field_resolves_to_composite(field_schema, ctx)
      // The JSON escape hatch fires for both an explicit
      // `encoding.<field>.contentType: application/json` annotation
      // and for composite (`oneOf` / `anyOf` / `allOf`) fields —
      // there is no single bracket-or-repeat wire format that round-
      // trips for those, so we serialise the whole value as one JSON
      // string and percent-encode it.
      let json_escape_hatch =
        form_encoding_is_json(encoding, field_name) || is_composite
      use <- bool.lazy_guard(json_escape_hatch, fn() {
        let value_expr = "body." <> gleam_field
        case is_required {
          True -> {
            let inner =
              form_field_json_encoder_expr(field_schema, value_expr, ctx)
            sb
            |> se.indent(
              1,
              "let form_parts = [\""
                <> field_name
                <> "=\" <> uri.percent_encode(json.to_string("
                <> inner
                <> ")), ..form_parts]",
            )
          }
          False -> {
            let inner = form_field_json_encoder_expr(field_schema, "v", ctx)
            sb
            |> se.indent(
              1,
              "let form_parts = case body." <> gleam_field <> " {",
            )
            |> se.indent(
              2,
              "Some(v) -> [\""
                <> field_name
                <> "=\" <> uri.percent_encode(json.to_string("
                <> inner
                <> ")), ..form_parts]",
            )
            |> se.indent(2, "None -> form_parts")
            |> se.indent(1, "}")
          }
        }
      })
      case is_object, is_array_of_object {
        True, _ ->
          // Nested objects: serialize as field[subkey]=value
          generate_form_nested_object(
            sb,
            field_name,
            gleam_field,
            field_schema,
            is_required,
            ctx,
          )
        _, True ->
          case array_items {
            Some(items_schema) ->
              generate_form_indexed_array(
                sb,
                "\"" <> field_name <> "\"",
                "body." <> gleam_field,
                items_schema,
                is_required,
                1,
                "form_parts",
                ctx,
              )
            None -> sb
          }
        False, False ->
          case is_array {
            True ->
              // Arrays of primitives: repeat the key for each element (tags=a&tags=b).
              // This is the OAS form,explode default and stays
              // unchanged for backwards compatibility — only nested
              // arrays adopt the indexed-bracket form.
              case is_required {
                True ->
                  sb
                  |> se.indent(
                    1,
                    "let form_parts = list.fold(body."
                      <> gleam_field
                      <> ", form_parts, fn(acc, item) {",
                  )
                  |> se.indent(
                    2,
                    "[\""
                      <> field_name
                      <> "=\" <> uri.percent_encode("
                      <> form_array_item_to_string(field_schema, ctx)
                      <> "), ..acc]",
                  )
                  |> se.indent(1, "})")
                False ->
                  sb
                  |> se.indent(
                    1,
                    "let form_parts = case body." <> gleam_field <> " {",
                  )
                  |> se.indent(
                    2,
                    "Some(items) -> list.fold(items, form_parts, fn(acc, item) {",
                  )
                  |> se.indent(
                    3,
                    "[\""
                      <> field_name
                      <> "=\" <> uri.percent_encode("
                      <> form_array_item_to_string(field_schema, ctx)
                      <> "), ..acc]",
                  )
                  |> se.indent(2, "})")
                  |> se.indent(2, "None -> form_parts")
                  |> se.indent(1, "}")
              }
            False -> {
              let to_str = multipart_field_to_string_fn(field_schema, ctx)
              case is_required {
                True -> {
                  let value_expr = case to_str {
                    "" -> "body." <> gleam_field
                    fn_name -> fn_name <> "(body." <> gleam_field <> ")"
                  }
                  sb
                  |> se.indent(
                    1,
                    "let form_parts = [\""
                      <> field_name
                      <> "=\" <> uri.percent_encode("
                      <> value_expr
                      <> "), ..form_parts]",
                  )
                }
                False ->
                  sb
                  |> se.indent(
                    1,
                    "let form_parts = case body." <> gleam_field <> " {",
                  )
                  |> se.indent(
                    2,
                    "Some(v) -> [\""
                      <> field_name
                      <> "=\" <> uri.percent_encode("
                      <> {
                      case to_str {
                        "" -> "v"
                        fn_name -> fn_name <> "(v)"
                      }
                    }
                      <> "), ..form_parts]",
                  )
                  |> se.indent(2, "None -> form_parts")
                  |> se.indent(1, "}")
              }
            }
          }
      }
    })

  sb
  |> se.indent(1, "let body_str = string.join(form_parts, \"&\")")
  |> se.indent(
    1,
    "let body_content_type = \"application/x-www-form-urlencoded\"",
  )
}

/// Check if a parameter is an array with explode behavior.
/// OpenAPI default: style: form has explode: true by default.
pub fn is_exploded_array_param(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  let is_array = case param.payload {
    ParameterSchema(Inline(schema.ArraySchema(..))) -> True
    ParameterSchema(Reference(..) as sr) ->
      case context.resolve_schema_ref(sr, ctx) {
        Ok(schema.ArraySchema(..)) -> True
        _ -> False
      }
    _ -> False
  }
  case is_array {
    False -> False
    True -> operation_ir.effective_explode(param)
  }
}

/// Returns Some(joiner) if the parameter is a non-exploded delimited array
/// (pipeDelimited or spaceDelimited). Returns None for everything else
/// including form arrays — we keep that on the existing path.
pub fn is_delimited_array_param(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> option.Option(String) {
  let is_array = case param.payload {
    ParameterSchema(Inline(schema.ArraySchema(..))) -> True
    ParameterSchema(Reference(..) as sr) ->
      case context.resolve_schema_ref(sr, ctx) {
        Ok(schema.ArraySchema(..)) -> True
        _ -> False
      }
    _ -> False
  }
  // Use spec-default explode rules (false for pipe/space) so that omitting
  // `explode` yields the delimited path, matching OpenAPI semantics.
  let is_non_exploded = !operation_ir.effective_explode(param)
  case is_array, is_non_exploded, param.style {
    True, True, option.Some(spec.PipeDelimitedStyle)
    | True, True, option.Some(spec.SpaceDelimitedStyle)
    -> option.Some(operation_ir.delimiter_for_style(param.style))
    _, _, _ -> option.None
  }
}

/// Generate non-exploded delimited array query parameter:
/// tags=a|b|c (pipeDelimited) or tags=a%20b%20c (spaceDelimited).
pub fn generate_delimited_array_query_param(
  sb: se.StringBuilder,
  param: spec.Parameter(Resolved),
  param_name: String,
  joiner: String,
  ctx: Context,
) -> se.StringBuilder {
  let item_to_str = case param.payload {
    ParameterSchema(Inline(schema.ArraySchema(items:, ..))) ->
      array_item_to_string_fn(items, ctx)
    ParameterSchema(Reference(..) as sr) ->
      case context.resolve_schema_ref(sr, ctx) {
        Ok(schema.ArraySchema(items:, ..)) ->
          array_item_to_string_fn(items, ctx)
        _ -> "fn(x) { x }"
      }
    _ -> "fn(x) { x }"
  }
  // Empty arrays produce no query entry, matching the exploded path.
  case param.required {
    True ->
      sb
      |> se.indent(1, "let query = case " <> param_name <> " {")
      |> se.indent(2, "[] -> query")
      |> se.indent(2, "items -> {")
      |> se.indent(
        3,
        "let joined = string.join(list.map(items, "
          <> item_to_str
          <> "), \""
          <> joiner
          <> "\")",
      )
      |> se.indent(3, "[#(\"" <> param.name <> "\", joined), ..query]")
      |> se.indent(2, "}")
      |> se.indent(1, "}")
    False ->
      sb
      |> se.indent(1, "let query = case " <> param_name <> " {")
      |> se.indent(2, "Some([]) -> query")
      |> se.indent(2, "Some(items) -> {")
      |> se.indent(
        3,
        "let joined = string.join(list.map(items, "
          <> item_to_str
          <> "), \""
          <> joiner
          <> "\")",
      )
      |> se.indent(3, "[#(\"" <> param.name <> "\", joined), ..query]")
      |> se.indent(2, "}")
      |> se.indent(2, "None -> query")
      |> se.indent(1, "}")
  }
}

/// Generate exploded array query parameter: tags=a&tags=b
pub fn generate_exploded_array_query_param(
  sb: se.StringBuilder,
  param: spec.Parameter(Resolved),
  param_name: String,
  ctx: Context,
) -> se.StringBuilder {
  let items_ref = array_items_ref(param, ctx)
  let json_escape = case items_ref {
    Some(items) -> !items_resolve_primitive(items, ctx)
    None -> False
  }
  use <- bool.lazy_guard(json_escape, fn() {
    case items_ref {
      Some(items) -> emit_json_array_query_param(sb, param, param_name, items)
      None -> sb
    }
  })

  let item_to_str = case items_ref {
    Some(items) -> array_item_to_string_fn(items, ctx)
    None -> "fn(x) { x }"
  }
  case param.required {
    True ->
      sb
      |> se.indent(
        1,
        "let query = list.fold(" <> param_name <> ", query, fn(acc, item) {",
      )
      |> se.indent(
        2,
        "[#(\"" <> param.name <> "\", " <> item_to_str <> "(item)), ..acc]",
      )
      |> se.indent(1, "})")
    False ->
      sb
      |> se.indent(1, "let query = case " <> param_name <> " {")
      |> se.indent(2, "Some(items) -> list.fold(items, query, fn(acc, item) {")
      |> se.indent(
        3,
        "[#(\"" <> param.name <> "\", " <> item_to_str <> "(item)), ..acc]",
      )
      |> se.indent(2, "})")
      |> se.indent(2, "None -> query")
      |> se.indent(1, "}")
  }
}

fn array_items_ref(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> Option(schema.SchemaRef) {
  case param.payload {
    ParameterSchema(Inline(schema.ArraySchema(items:, ..))) -> Some(items)
    ParameterSchema(Reference(..) as sr) ->
      case context.resolve_schema_ref(sr, ctx) {
        Ok(schema.ArraySchema(items:, ..)) -> Some(items)
        _ -> None
      }
    _ -> None
  }
}

fn items_resolve_primitive(items: schema.SchemaRef, ctx: Context) -> Bool {
  case items {
    Inline(schema.StringSchema(..))
    | Inline(schema.IntegerSchema(..))
    | Inline(schema.NumberSchema(..))
    | Inline(schema.BooleanSchema(..)) -> True
    Reference(..) ->
      case context.resolve_schema_ref(items, ctx) {
        Ok(schema.StringSchema(..))
        | Ok(schema.IntegerSchema(..))
        | Ok(schema.NumberSchema(..))
        | Ok(schema.BooleanSchema(..)) -> True
        _ -> False
      }
    _ -> False
  }
}

/// Emit an array query parameter whose items resolve to a non-
/// primitive (object / array / composite) shape via the JSON escape
/// hatch — the entire list is JSON-encoded into a single value
/// (`<param>=<JSON array string>`). This matches the form-urlencoded
/// composite path (PR #542) and keeps the generator from panicking
/// in `to_string_fn` on non-primitive items.
fn emit_json_array_query_param(
  sb: se.StringBuilder,
  param: spec.Parameter(Resolved),
  param_name: String,
  items: schema.SchemaRef,
) -> se.StringBuilder {
  let item_encoder = schema_dispatch.json_encoder_fn(items)
  case param.required {
    True ->
      sb
      |> se.indent(
        1,
        "let query = [#(\""
          <> param.name
          <> "\", json.to_string(json.array("
          <> param_name
          <> ", "
          <> item_encoder
          <> "))), ..query]",
      )
    False ->
      sb
      |> se.indent(1, "let query = case " <> param_name <> " {")
      |> se.indent(
        2,
        "Some(items) -> [#(\""
          <> param.name
          <> "\", json.to_string(json.array(items, "
          <> item_encoder
          <> "))), ..query]",
      )
      |> se.indent(2, "None -> query")
      |> se.indent(1, "}")
  }
}

/// Check if a parameter uses deepObject style with an object schema.
pub fn is_deep_object_param(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  operation_ir.is_deep_object_param(param, ctx)
}

/// Return a function expression that converts an array item to String.
/// Used in generated code: `list.map(param, <fn>)`.
fn array_item_to_string_fn(items: schema.SchemaRef, ctx: Context) -> String {
  schema_dispatch.to_string_fn(items, ctx)
}
