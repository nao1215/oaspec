import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/codegen/ir_build
import oaspec/internal/codegen/operation_ir
import oaspec/internal/codegen/schema_dispatch
import oaspec/internal/openapi/dedup
import oaspec/internal/openapi/resolver
import oaspec/internal/openapi/schema.{Inline, Reference}
import oaspec/internal/openapi/spec.{type Resolved, ParameterSchema, Value}
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
    schema_dispatch.resolve_param_type(
      spec.parameter_schema(param),
      context.spec(ctx),
    )
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
      let item_to_str = schema_dispatch.to_string_fn(items, context.spec(ctx))
      "string.join(list.map("
      <> param_name
      <> ", "
      <> item_to_str
      <> "), \",\")"
    }
    ParameterSchema(Inline(s)) -> schema_dispatch.to_string_expr(s, param_name)
    ParameterSchema(Reference(..) as schema_ref) -> {
      // Resolve the $ref to determine the actual schema type
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
        Ok(schema.ArraySchema(items:, ..)) -> {
          let item_to_str =
            schema_dispatch.to_string_fn(items, context.spec(ctx))
          "string.join(list.map("
          <> param_name
          <> ", "
          <> item_to_str
          <> "), \",\")"
        }
        _ ->
          schema_dispatch.schema_ref_to_string_expr(
            schema_ref,
            param_name,
            context.spec(ctx),
          )
      }
    }
    _ -> param_name
  }
}

/// Convert a required param to string for query building.
pub fn to_str_for_required(
  param: spec.Parameter(Resolved),
  param_name: String,
  ctx: Context,
) -> String {
  param_to_string_expr(param, param_name, ctx)
}

/// Convert an optional param value (bound to `v`) to string.
pub fn to_str_for_optional_value(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> String {
  case param.payload {
    ParameterSchema(Inline(schema.ArraySchema(items:, ..))) -> {
      let item_to_str = schema_dispatch.to_string_fn(items, context.spec(ctx))
      "string.join(list.map(v, " <> item_to_str <> "), \",\")"
    }
    ParameterSchema(Inline(s)) -> schema_dispatch.to_string_expr(s, "v")
    ParameterSchema(Reference(..) as schema_ref) -> {
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
        Ok(schema.ArraySchema(items:, ..)) -> {
          let item_to_str =
            schema_dispatch.to_string_fn(items, context.spec(ctx))
          "string.join(list.map(v, " <> item_to_str <> "), \",\")"
        }
        _ ->
          schema_dispatch.schema_ref_to_string_expr(
            schema_ref,
            "v",
            context.spec(ctx),
          )
      }
    }
    _ -> "v"
  }
}

/// Get the Gleam type for a request body parameter.
pub fn get_body_type(rb: spec.RequestBody(Resolved), op_id: String) -> String {
  let content_entries = ir_build.sorted_entries(rb.content)
  case content_entries {
    // Multiple content types: use pre-serialized String
    [_, _, ..] -> "String"
    [#(_, media_type)] ->
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
          case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
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
      let is_binary = multipart_field_is_binary(field_schema, ctx)
      // Convert value to string for multipart encoding
      let to_string_fn = case is_binary {
        True -> ""
        False -> multipart_field_to_string_fn(field_schema, ctx)
      }
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
          // Optional field: wrap in case body.<field> { Some(v) -> ... None -> parts }
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
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
        Ok(schema.StringSchema(format: Some("binary"), ..)) -> True
        _ -> False
      }
    _ -> False
  }
}

fn multipart_field_to_string_fn(
  field_schema: schema.SchemaRef,
  ctx: Context,
) -> String {
  let result = schema_dispatch.to_string_fn(field_schema, context.spec(ctx))
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
      schema_dispatch.schema_ref_to_string_expr(
        items,
        "item",
        context.spec(ctx),
      )
    _ -> "string.inspect(item)"
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
  let resolved = case field_schema {
    Inline(s) -> Ok(s)
    Reference(..) ->
      resolver.resolve_schema_ref(field_schema, context.spec(ctx))
  }
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
          case resolver.resolve_schema_ref(sr, context.spec(ctx)) {
            Ok(schema.ObjectSchema(..)) -> True
            _ -> False
          }
        _ -> False
      }
      case is_sub_object {
        True ->
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
        False -> {
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
  let resolved = case field_schema {
    Inline(s) -> Ok(s)
    Reference(..) ->
      resolver.resolve_schema_ref(field_schema, context.spec(ctx))
  }
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
            case resolver.resolve_schema_ref(sr, context.spec(ctx)) {
              Ok(schema.ObjectSchema(..)) -> True
              _ -> False
            }
          _ -> False
        }
        case is_obj {
          True ->
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
          False -> {
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

/// Generate application/x-www-form-urlencoded body encoding in the client function.
pub fn generate_form_urlencoded_body(
  sb: se.StringBuilder,
  rb: spec.RequestBody(Resolved),
  _op_id: String,
  ctx: Context,
) -> se.StringBuilder {
  let content_entries = ir_build.sorted_entries(rb.content)
  let #(properties, required_fields) = case content_entries {
    [#(_, media_type), ..] ->
      case media_type.schema {
        Some(Inline(schema.ObjectSchema(properties:, required:, ..))) -> #(
          ir_build.sorted_entries(properties),
          required,
        )
        Some(Reference(..) as schema_ref) ->
          case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
            Ok(schema.ObjectSchema(properties:, required:, ..)) -> {
              #(ir_build.sorted_entries(properties), required)
            }
            _ -> #([], [])
          }
        _ -> #([], [])
      }
    _ -> #([], [])
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
          case resolver.resolve_schema_ref(sr, context.spec(ctx)) {
            Ok(schema.ArraySchema(..)) -> True
            _ -> False
          }
        _ -> False
      }
      let is_object = case field_schema {
        Inline(schema.ObjectSchema(..)) -> True
        Reference(..) as sr ->
          case resolver.resolve_schema_ref(sr, context.spec(ctx)) {
            Ok(schema.ObjectSchema(..)) -> True
            _ -> False
          }
        _ -> False
      }
      case is_object {
        True ->
          // Nested objects: serialize as field[subkey]=value
          generate_form_nested_object(
            sb,
            field_name,
            gleam_field,
            field_schema,
            is_required,
            ctx,
          )
        False ->
          case is_array {
            True ->
              // Arrays: repeat the key for each element (tags=a&tags=b)
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
      case resolver.resolve_schema_ref(sr, context.spec(ctx)) {
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
      case resolver.resolve_schema_ref(sr, context.spec(ctx)) {
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
      case resolver.resolve_schema_ref(sr, context.spec(ctx)) {
        Ok(schema.ArraySchema(items:, ..)) ->
          array_item_to_string_fn(items, ctx)
        _ -> "fn(x) { x }"
      }
    _ -> "fn(x) { x }"
  }
  // Empty arrays produce no query entry, matching the existing exploded path.
  case param.required {
    True ->
      sb
      |> se.indent(1, "let query_parts = case " <> param_name <> " {")
      |> se.indent(2, "[] -> query_parts")
      |> se.indent(2, "items -> {")
      |> se.indent(
        3,
        "let joined = string.join(list.map(items, "
          <> item_to_str
          <> "), \""
          <> joiner
          <> "\")",
      )
      |> se.indent(
        3,
        "[\""
          <> param.name
          <> "=\" <> uri.percent_encode(joined), ..query_parts]",
      )
      |> se.indent(2, "}")
      |> se.indent(1, "}")
    False ->
      sb
      |> se.indent(1, "let query_parts = case " <> param_name <> " {")
      |> se.indent(2, "Some([]) -> query_parts")
      |> se.indent(2, "Some(items) -> {")
      |> se.indent(
        3,
        "let joined = string.join(list.map(items, "
          <> item_to_str
          <> "), \""
          <> joiner
          <> "\")",
      )
      |> se.indent(
        3,
        "[\""
          <> param.name
          <> "=\" <> uri.percent_encode(joined), ..query_parts]",
      )
      |> se.indent(2, "}")
      |> se.indent(2, "None -> query_parts")
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
  let item_to_str = case param.payload {
    ParameterSchema(Inline(schema.ArraySchema(items:, ..))) ->
      array_item_to_string_fn(items, ctx)
    ParameterSchema(Reference(..) as sr) ->
      case resolver.resolve_schema_ref(sr, context.spec(ctx)) {
        Ok(schema.ArraySchema(items:, ..)) ->
          array_item_to_string_fn(items, ctx)
        _ -> "fn(x) { x }"
      }
    _ -> "fn(x) { x }"
  }
  case param.required {
    True ->
      sb
      |> se.indent(
        1,
        "let query_parts = list.fold("
          <> param_name
          <> ", query_parts, fn(acc, item) {",
      )
      |> se.indent(
        2,
        "[\""
          <> param.name
          <> "=\" <> uri.percent_encode("
          <> item_to_str
          <> "(item)), ..acc]",
      )
      |> se.indent(1, "})")
    False ->
      sb
      |> se.indent(1, "let query_parts = case " <> param_name <> " {")
      |> se.indent(
        2,
        "Some(items) -> list.fold(items, query_parts, fn(acc, item) {",
      )
      |> se.indent(
        3,
        "[\""
          <> param.name
          <> "=\" <> uri.percent_encode("
          <> item_to_str
          <> "(item)), ..acc]",
      )
      |> se.indent(2, "})")
      |> se.indent(2, "None -> query_parts")
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

/// Generate deepObject-style query parameters: key[prop]=value for each property.
pub fn generate_deep_object_query_param(
  sb: se.StringBuilder,
  param: spec.Parameter(Resolved),
  param_name: String,
  ctx: Context,
) -> se.StringBuilder {
  let properties = case param.payload {
    ParameterSchema(Reference(..) as schema_ref) ->
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
        Ok(schema.ObjectSchema(properties:, required:, ..)) -> #(
          ir_build.sorted_entries(properties),
          required,
        )
        _ -> #([], [])
      }
    ParameterSchema(Inline(schema.ObjectSchema(properties:, required:, ..))) -> #(
      ir_build.sorted_entries(properties),
      required,
    )
    _ -> #([], [])
  }
  let #(props, required_fields) = properties
  case param.required {
    True ->
      list.fold(props, sb, fn(sb, entry) {
        let #(prop_name, prop_ref) = entry
        let field_name = naming.to_snake_case(prop_name)
        let accessor = param_name <> "." <> field_name
        let is_required = list.contains(required_fields, prop_name)
        let is_array = case prop_ref {
          Inline(schema.ArraySchema(..)) -> True
          _ -> False
        }
        case is_array, is_required {
          // Array leaf: iterate items to produce key[prop]=item for each
          True, True ->
            sb
            |> se.indent(
              1,
              "let query_parts = list.fold("
                <> accessor
                <> ", query_parts, fn(acc, item) {",
            )
            |> se.indent(
              2,
              "[\""
                <> param.name
                <> "["
                <> prop_name
                <> "]=\" <> uri.percent_encode("
                <> deep_object_array_item_to_string(prop_ref, ctx)
                <> "), ..acc]",
            )
            |> se.indent(1, "})")
          True, False ->
            sb
            |> se.indent(1, "let query_parts = case " <> accessor <> " {")
            |> se.indent(
              2,
              "Some(items) -> list.fold(items, query_parts, fn(acc, item) {",
            )
            |> se.indent(
              3,
              "[\""
                <> param.name
                <> "["
                <> prop_name
                <> "]=\" <> uri.percent_encode("
                <> deep_object_array_item_to_string(prop_ref, ctx)
                <> "), ..acc]",
            )
            |> se.indent(2, "})")
            |> se.indent(2, "None -> query_parts")
            |> se.indent(1, "}")
          // Scalar: single key[prop]=value
          False, True -> {
            let to_str = schema_ref_to_string_expr(prop_ref, accessor, ctx)
            sb
            |> se.indent(
              1,
              "let query_parts = [\""
                <> param.name
                <> "["
                <> prop_name
                <> "]=\" <> uri.percent_encode("
                <> to_str
                <> "), ..query_parts]",
            )
          }
          False, False -> {
            sb
            |> se.indent(1, "let query_parts = case " <> accessor <> " {")
            |> se.indent(
              2,
              "Some(v) -> [\""
                <> param.name
                <> "["
                <> prop_name
                <> "]=\" <> uri.percent_encode("
                <> schema_ref_to_string_expr(prop_ref, "v", ctx)
                <> "), ..query_parts]",
            )
            |> se.indent(2, "None -> query_parts")
            |> se.indent(1, "}")
          }
        }
      })
    False -> {
      let sb =
        sb |> se.indent(1, "let query_parts = case " <> param_name <> " {")
      let sb = sb |> se.indent(2, "Some(obj) -> {")
      let sb = sb |> se.indent(3, "let qp = query_parts")
      let sb =
        list.fold(props, sb, fn(sb, entry) {
          let #(prop_name, prop_ref) = entry
          let field_name = naming.to_snake_case(prop_name)
          let accessor = "obj." <> field_name
          let is_required = list.contains(required_fields, prop_name)
          let is_array = case prop_ref {
            Inline(schema.ArraySchema(..)) -> True
            _ -> False
          }
          case is_array, is_required {
            True, True ->
              sb
              |> se.indent(
                3,
                "let qp = list.fold(" <> accessor <> ", qp, fn(acc, item) {",
              )
              |> se.indent(
                4,
                "[\""
                  <> param.name
                  <> "["
                  <> prop_name
                  <> "]=\" <> uri.percent_encode("
                  <> deep_object_array_item_to_string(prop_ref, ctx)
                  <> "), ..acc]",
              )
              |> se.indent(3, "})")
            True, False ->
              sb
              |> se.indent(3, "let qp = case " <> accessor <> " {")
              |> se.indent(
                4,
                "Some(items) -> list.fold(items, qp, fn(acc, item) {",
              )
              |> se.indent(
                5,
                "[\""
                  <> param.name
                  <> "["
                  <> prop_name
                  <> "]=\" <> uri.percent_encode("
                  <> deep_object_array_item_to_string(prop_ref, ctx)
                  <> "), ..acc]",
              )
              |> se.indent(4, "})")
              |> se.indent(4, "None -> qp")
              |> se.indent(3, "}")
            False, True -> {
              let to_str = schema_ref_to_string_expr(prop_ref, accessor, ctx)
              sb
              |> se.indent(
                3,
                "let qp = [\""
                  <> param.name
                  <> "["
                  <> prop_name
                  <> "]=\" <> uri.percent_encode("
                  <> to_str
                  <> "), ..qp]",
              )
            }
            False, False ->
              sb
              |> se.indent(3, "let qp = case " <> accessor <> " {")
              |> se.indent(
                4,
                "Some(v) -> [\""
                  <> param.name
                  <> "["
                  <> prop_name
                  <> "]=\" <> uri.percent_encode("
                  <> schema_ref_to_string_expr(prop_ref, "v", ctx)
                  <> "), ..qp]",
              )
              |> se.indent(4, "None -> qp")
              |> se.indent(3, "}")
          }
        })
      let sb = sb |> se.indent(3, "qp")
      let sb = sb |> se.indent(2, "}")
      let sb = sb |> se.indent(2, "None -> query_parts")
      sb |> se.indent(1, "}")
    }
  }
}

/// Convert a SchemaRef to a string expression for a given accessor.
fn schema_ref_to_string_expr(
  schema_ref: schema.SchemaRef,
  accessor: String,
  ctx: Context,
) -> String {
  schema_dispatch.schema_ref_to_string_expr(
    schema_ref,
    accessor,
    context.spec(ctx),
  )
}

/// Return a function expression that converts an array item to String.
/// Used in generated code: `list.map(param, <fn>)`.
fn array_item_to_string_fn(items: schema.SchemaRef, ctx: Context) -> String {
  schema_dispatch.to_string_fn(items, context.spec(ctx))
}

/// Convert a deepObject array item to a string expression.
fn deep_object_array_item_to_string(
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
