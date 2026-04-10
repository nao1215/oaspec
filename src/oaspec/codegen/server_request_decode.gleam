import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/codegen/context.{type Context}
import oaspec/openapi/resolver
import oaspec/openapi/schema.{
  type AdditionalProperties, type SchemaRef, Forbidden, Inline, ObjectSchema,
  Reference,
}
import oaspec/openapi/spec.{type Resolved, Value}
import oaspec/util/naming

/// Expression that case-insensitively parses a string to Bool.
/// Accepts "true"/"True"/"TRUE" etc. as True, everything else as False.
/// This is compatible with Gleam's bool.to_string which produces "True"/"False".
pub const bool_parse_expr = "case string.lowercase(v) { \"true\" -> True _ -> False }"

pub type DeepObjectProperty {
  DeepObjectProperty(
    name: String,
    field_name: String,
    schema_ref: SchemaRef,
    required: Bool,
  )
}

pub type BodyFieldKind {
  BodyFieldUnknown
  BodyFieldString
  BodyFieldInt
  BodyFieldFloat
  BodyFieldBool
  BodyFieldStringArray
  BodyFieldIntArray
  BodyFieldFloatArray
  BodyFieldBoolArray
}

pub fn schema_ref_body_field_kind(
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> BodyFieldKind {
  case schema_ref {
    Some(schema_ref) -> body_field_kind(schema_ref, ctx)
    None -> BodyFieldUnknown
  }
}

pub fn body_field_kind(schema_ref: SchemaRef, ctx: Context) -> BodyFieldKind {
  case schema_ref {
    Inline(schema.StringSchema(..)) -> BodyFieldString
    Inline(schema.IntegerSchema(..)) -> BodyFieldInt
    Inline(schema.NumberSchema(..)) -> BodyFieldFloat
    Inline(schema.BooleanSchema(..)) -> BodyFieldBool
    Inline(schema.ArraySchema(items:, ..)) ->
      case body_field_kind(items, ctx) {
        BodyFieldString -> BodyFieldStringArray
        BodyFieldInt -> BodyFieldIntArray
        BodyFieldFloat -> BodyFieldFloatArray
        BodyFieldBool -> BodyFieldBoolArray
        _ -> BodyFieldUnknown
      }
    Reference(..) as schema_ref ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(schema_obj) -> body_field_kind_from_object(schema_obj, ctx)
        Error(_) -> BodyFieldUnknown
      }
    _ -> BodyFieldUnknown
  }
}

fn body_field_kind_from_object(schema_obj, ctx: Context) -> BodyFieldKind {
  case schema_obj {
    schema.StringSchema(..) -> BodyFieldString
    schema.IntegerSchema(..) -> BodyFieldInt
    schema.NumberSchema(..) -> BodyFieldFloat
    schema.BooleanSchema(..) -> BodyFieldBool
    schema.ArraySchema(items:, ..) ->
      case body_field_kind(items, ctx) {
        BodyFieldString -> BodyFieldStringArray
        BodyFieldInt -> BodyFieldIntArray
        BodyFieldFloat -> BodyFieldFloatArray
        BodyFieldBool -> BodyFieldBoolArray
        _ -> BodyFieldUnknown
      }
    _ -> BodyFieldUnknown
  }
}

pub fn body_field_kind_needs_int(kind: BodyFieldKind) -> Bool {
  case kind {
    BodyFieldInt | BodyFieldIntArray -> True
    _ -> False
  }
}

pub fn body_field_kind_needs_float(kind: BodyFieldKind) -> Bool {
  case kind {
    BodyFieldFloat | BodyFieldFloatArray -> True
    _ -> False
  }
}

/// Generate parse expression for a path parameter (already bound as String).
pub fn param_parse_expr(
  var_name: String,
  param: spec.Parameter(Resolved),
) -> String {
  case spec.parameter_schema(param) {
    Some(Inline(schema.IntegerSchema(..))) -> {
      // Parse string to int; use 0 as fallback
      "{ let assert Ok(v) = int.parse(" <> var_name <> ") v }"
    }
    Some(Inline(schema.NumberSchema(..))) -> {
      "{ let assert Ok(v) = float.parse(" <> var_name <> ") v }"
    }
    Some(Inline(schema.BooleanSchema(..))) -> {
      "{ let v = " <> var_name <> " " <> bool_parse_expr <> " }"
    }
    _ -> var_name
  }
}

/// Generate expression for a required query parameter.
pub fn query_required_expr(
  key: String,
  param: spec.Parameter(Resolved),
) -> String {
  query_required_expr_with_schema(
    key,
    spec.parameter_schema(param),
    param.explode,
  )
}

pub fn query_required_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  explode: Option(Bool),
) -> String {
  let base = "{ let assert Ok([v, ..]) = dict.get(query, \"" <> key <> "\") v }"
  case schema_ref {
    Some(Inline(schema.ArraySchema(items: Inline(schema.StringSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "{ let assert Ok([v, ..]) = dict.get(query, \""
          <> key
          <> "\") list.map(string.split(v, \",\"), fn(item) { string.trim(item) }) }"
        _ ->
          "{ let assert Ok(vs) = dict.get(query, \""
          <> key
          <> "\") list.map(vs, fn(item) { string.trim(item) }) }"
      }
    Some(Inline(schema.ArraySchema(items: Inline(schema.IntegerSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "{ let assert Ok([v, ..]) = dict.get(query, \""
          <> key
          <> "\") list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n }) }"
        _ ->
          "{ let assert Ok(vs) = dict.get(query, \""
          <> key
          <> "\") list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n }) }"
      }
    Some(Inline(schema.ArraySchema(items: Inline(schema.NumberSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "{ let assert Ok([v, ..]) = dict.get(query, \""
          <> key
          <> "\") list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n }) }"
        _ ->
          "{ let assert Ok(vs) = dict.get(query, \""
          <> key
          <> "\") list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n }) }"
      }
    Some(Inline(schema.ArraySchema(items: Inline(schema.BooleanSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "{ let assert Ok([v, ..]) = dict.get(query, \""
          <> key
          <> "\") list.map(string.split(v, \",\"), fn(item) { let v = string.trim(item) "
          <> bool_parse_expr
          <> " }) }"
        _ ->
          "{ let assert Ok(vs) = dict.get(query, \""
          <> key
          <> "\") list.map(vs, fn(item) { let v = string.trim(item) "
          <> bool_parse_expr
          <> " }) }"
      }
    Some(Inline(schema.IntegerSchema(..))) ->
      "{ let assert Ok([v, ..]) = dict.get(query, \""
      <> key
      <> "\") let assert Ok(n) = int.parse(v) n }"
    Some(Inline(schema.NumberSchema(..))) ->
      "{ let assert Ok([v, ..]) = dict.get(query, \""
      <> key
      <> "\") let assert Ok(n) = float.parse(v) n }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "{ let assert Ok([v, ..]) = dict.get(query, \""
      <> key
      <> "\") "
      <> bool_parse_expr
      <> " }"
    _ -> base
  }
}

/// Generate expression for an optional query parameter.
pub fn query_optional_expr(
  key: String,
  param: spec.Parameter(Resolved),
) -> String {
  query_optional_expr_with_schema(
    key,
    spec.parameter_schema(param),
    param.explode,
  )
}

pub fn query_optional_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  explode: Option(Bool),
) -> String {
  case schema_ref {
    Some(Inline(schema.ArraySchema(items: Inline(schema.StringSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok([v, ..]) -> Some(list.map(string.split(v, \",\"), fn(item) { string.trim(item) })) _ -> None }"
        _ ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { string.trim(item) })) _ -> None }"
      }
    Some(Inline(schema.ArraySchema(items: Inline(schema.IntegerSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok([v, ..]) -> Some(list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n })) _ -> None }"
        _ ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n })) _ -> None }"
      }
    Some(Inline(schema.ArraySchema(items: Inline(schema.NumberSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok([v, ..]) -> Some(list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n })) _ -> None }"
        _ ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n })) _ -> None }"
      }
    Some(Inline(schema.ArraySchema(items: Inline(schema.BooleanSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok([v, ..]) -> Some(list.map(string.split(v, \",\"), fn(item) { let v = string.trim(item) "
          <> bool_parse_expr
          <> " })) _ -> None }"
        _ ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let v = string.trim(item) "
          <> bool_parse_expr
          <> " })) _ -> None }"
      }
    Some(Inline(schema.IntegerSchema(..))) ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok([v, ..]) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    Some(Inline(schema.NumberSchema(..))) ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok([v, ..]) -> Some("
      <> bool_parse_expr
      <> ") _ -> None }"
    _ ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok([v, ..]) -> Some(v) _ -> None }"
  }
}

pub fn is_deep_object_param(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  case param.in_, param.style, spec.parameter_schema(param) {
    spec.InQuery, Some(spec.DeepObjectStyle), Some(Reference(..) as schema_ref) ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(ObjectSchema(..)) -> True
        _ -> False
      }
    spec.InQuery, Some(spec.DeepObjectStyle), Some(Inline(ObjectSchema(..))) ->
      True
    _, _, _ -> False
  }
}

fn deep_object_properties(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> List(DeepObjectProperty) {
  let details = case spec.parameter_schema(param) {
    Some(Reference(..) as schema_ref) ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(ObjectSchema(properties:, required:, ..)) -> #(properties, required)
        _ -> #(dict.new(), [])
      }
    Some(Inline(ObjectSchema(properties:, required:, ..))) -> #(
      properties,
      required,
    )
    _ -> #(dict.new(), [])
  }
  let #(properties, required_fields) = details
  dict.to_list(properties)
  |> list.map(fn(entry) {
    let #(prop_name, prop_ref) = entry
    DeepObjectProperty(
      name: prop_name,
      field_name: naming.to_snake_case(prop_name),
      schema_ref: prop_ref,
      required: list.contains(required_fields, prop_name),
    )
  })
}

fn deep_object_type_name(
  param: spec.Parameter(Resolved),
  op_id: String,
) -> String {
  case spec.parameter_schema(param) {
    Some(Reference(name:, ..)) -> "types." <> naming.schema_to_type_name(name)
    _ ->
      "types."
      <> naming.schema_to_type_name(op_id)
      <> "Param"
      <> naming.to_pascal_case(param.name)
  }
}

pub fn deep_object_required_expr(
  key: String,
  param: spec.Parameter(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  deep_object_constructor_expr(key, param, op_id, ctx)
}

pub fn deep_object_optional_expr(
  key: String,
  param: spec.Parameter(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  let props = deep_object_properties(param, ctx)
  let prop_names =
    props
    |> list.map(fn(prop) { "\"" <> prop.name <> "\"" })
    |> string.join(", ")
  "case deep_object_present(query, \""
  <> key
  <> "\", ["
  <> prop_names
  <> "]) { True -> Some("
  <> deep_object_constructor_expr(key, param, op_id, ctx)
  <> ") False -> None }"
}

fn deep_object_constructor_expr(
  key: String,
  param: spec.Parameter(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  let fields =
    deep_object_properties(param, ctx)
    |> list.map(fn(prop) {
      let prop_key = key <> "[" <> prop.name <> "]"
      let value_expr = case prop.required {
        True ->
          query_required_expr_with_schema(
            prop_key,
            Some(prop.schema_ref),
            Some(True),
          )
        False ->
          query_optional_expr_with_schema(
            prop_key,
            Some(prop.schema_ref),
            Some(True),
          )
      }
      prop.field_name <> ": " <> value_expr
    })
    |> string.join(", ")
  deep_object_type_name(param, op_id) <> "(" <> fields <> ")"
}

pub fn deep_object_param_has_optional_fields(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  case is_deep_object_param(param, ctx) {
    True ->
      list.any(deep_object_properties(param, ctx), fn(prop) { !prop.required })
    False -> False
  }
}

pub fn deep_object_param_needs_string(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  case is_deep_object_param(param, ctx) {
    True ->
      list.any(deep_object_properties(param, ctx), fn(prop) {
        query_schema_needs_string(Some(prop.schema_ref))
      })
    False -> False
  }
}

pub fn deep_object_param_needs_int(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  case is_deep_object_param(param, ctx) {
    True ->
      list.any(deep_object_properties(param, ctx), fn(prop) {
        query_schema_needs_int(Some(prop.schema_ref))
      })
    False -> False
  }
}

pub fn deep_object_param_needs_float(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  case is_deep_object_param(param, ctx) {
    True ->
      list.any(deep_object_properties(param, ctx), fn(prop) {
        query_schema_needs_float(Some(prop.schema_ref))
      })
    False -> False
  }
}

pub fn request_body_uses_form_urlencoded(rb: spec.RequestBody(Resolved)) -> Bool {
  dict.has_key(rb.content, "application/x-www-form-urlencoded")
}

pub fn request_body_uses_multipart(rb: spec.RequestBody(Resolved)) -> Bool {
  dict.has_key(rb.content, "multipart/form-data")
}

pub fn operation_uses_form_urlencoded_body(
  operation: spec.Operation(Resolved),
) -> Bool {
  case operation.request_body {
    Some(Value(rb)) -> request_body_uses_form_urlencoded(rb)
    _ -> False
  }
}

pub fn operation_uses_multipart_body(
  operation: spec.Operation(Resolved),
) -> Bool {
  case operation.request_body {
    Some(Value(rb)) -> request_body_uses_multipart(rb)
    _ -> False
  }
}

pub fn object_properties_from_schema_ref(
  schema_ref: SchemaRef,
  ctx: Context,
) -> List(DeepObjectProperty) {
  let details = case schema_ref {
    Reference(..) as schema_ref ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(ObjectSchema(properties:, required:, ..)) -> #(properties, required)
        _ -> #(dict.new(), [])
      }
    Inline(ObjectSchema(properties:, required:, ..)) -> #(properties, required)
    _ -> #(dict.new(), [])
  }
  let #(properties, required_fields) = details
  dict.to_list(properties)
  |> list.map(fn(entry) {
    let #(prop_name, prop_ref) = entry
    DeepObjectProperty(
      name: prop_name,
      field_name: naming.to_snake_case(prop_name),
      schema_ref: prop_ref,
      required: list.contains(required_fields, prop_name),
    )
  })
}

fn form_urlencoded_body_properties(
  rb: spec.RequestBody(Resolved),
  ctx: Context,
) -> List(DeepObjectProperty) {
  case dict.get(rb.content, "application/x-www-form-urlencoded") {
    Ok(media_type) -> {
      case media_type.schema {
        Some(schema_ref) -> object_properties_from_schema_ref(schema_ref, ctx)
        None -> []
      }
    }
    Error(_) -> []
  }
}

fn multipart_body_properties(
  rb: spec.RequestBody(Resolved),
  ctx: Context,
) -> List(DeepObjectProperty) {
  case dict.get(rb.content, "multipart/form-data") {
    Ok(media_type) ->
      case media_type.schema {
        Some(schema_ref) -> object_properties_from_schema_ref(schema_ref, ctx)
        None -> []
      }
    Error(_) -> []
  }
}

fn schema_ref_resolves_to_object(schema_ref: SchemaRef, ctx: Context) -> Bool {
  case schema_ref {
    Inline(ObjectSchema(..)) -> True
    Reference(..) as schema_ref ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(ObjectSchema(..)) -> True
        _ -> False
      }
    _ -> False
  }
}

fn schema_ref_additional_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> AdditionalProperties {
  case schema_ref {
    Inline(ObjectSchema(additional_properties:, ..)) -> additional_properties
    Reference(..) as schema_ref ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(ObjectSchema(additional_properties:, ..)) -> additional_properties
        _ -> Forbidden
      }
    _ -> Forbidden
  }
}

fn body_additional_properties(
  rb: spec.RequestBody(Resolved),
  content_type: String,
  ctx: Context,
) -> AdditionalProperties {
  case dict.get(rb.content, content_type) {
    Ok(media_type) ->
      case media_type.schema {
        Some(schema_ref) -> schema_ref_additional_properties(schema_ref, ctx)
        None -> Forbidden
      }
    Error(_) -> Forbidden
  }
}

fn form_urlencoded_schema_ref_type_name(schema_ref: SchemaRef) -> String {
  case schema_ref {
    Reference(name:, ..) -> "types." <> naming.schema_to_type_name(name)
    _ -> "String"
  }
}

fn form_urlencoded_body_type_name(
  rb: spec.RequestBody(Resolved),
  op_id: String,
) -> String {
  case dict.get(rb.content, "application/x-www-form-urlencoded") {
    Ok(media_type) ->
      case media_type.schema {
        Some(Reference(name:, ..)) ->
          "types." <> naming.schema_to_type_name(name)
        Some(Inline(ObjectSchema(..))) ->
          "types." <> naming.schema_to_type_name(op_id) <> "Request"
        _ -> "String"
      }
    Error(_) -> "String"
  }
}

fn multipart_body_type_name(
  rb: spec.RequestBody(Resolved),
  op_id: String,
) -> String {
  case dict.get(rb.content, "multipart/form-data") {
    Ok(media_type) ->
      case media_type.schema {
        Some(Reference(name:, ..)) ->
          "types." <> naming.schema_to_type_name(name)
        Some(Inline(ObjectSchema(..))) ->
          "types." <> naming.schema_to_type_name(op_id) <> "Request"
        _ -> "String"
      }
    Error(_) -> "String"
  }
}

fn form_urlencoded_key(prefix: String, name: String) -> String {
  case prefix {
    "" -> name
    _ -> prefix <> "[" <> name <> "]"
  }
}

fn form_urlencoded_object_constructor_expr(
  type_name: String,
  prefix: String,
  properties: List(DeepObjectProperty),
  additional_properties: AdditionalProperties,
  ctx: Context,
  nesting_depth: Int,
) -> String {
  let fields =
    properties
    |> list.map(fn(prop) {
      let key = form_urlencoded_key(prefix, prop.name)
      let value_expr = case
        nesting_depth < 5 && schema_ref_resolves_to_object(prop.schema_ref, ctx),
        prop.required
      {
        True, True ->
          form_urlencoded_object_required_expr(
            key,
            prop.schema_ref,
            ctx,
            nesting_depth + 1,
          )
        True, False ->
          form_urlencoded_object_optional_expr(
            key,
            prop.schema_ref,
            ctx,
            nesting_depth + 1,
          )
        False, True ->
          form_body_required_expr_with_schema(key, Some(prop.schema_ref), ctx)
        False, False ->
          form_body_optional_expr_with_schema(key, Some(prop.schema_ref), ctx)
      }
      prop.field_name <> ": " <> value_expr
    })
    |> string.join(", ")
  let additional_props_suffix = case additional_properties {
    Forbidden -> ""
    _ -> ", additional_properties: dict.new()"
  }
  type_name <> "(" <> fields <> additional_props_suffix <> ")"
}

fn form_urlencoded_object_required_expr(
  prefix: String,
  schema_ref: SchemaRef,
  ctx: Context,
  nesting_depth: Int,
) -> String {
  form_urlencoded_object_constructor_expr(
    form_urlencoded_schema_ref_type_name(schema_ref),
    prefix,
    object_properties_from_schema_ref(schema_ref, ctx),
    schema_ref_additional_properties(schema_ref, ctx),
    ctx,
    nesting_depth,
  )
}

fn form_urlencoded_object_optional_expr(
  prefix: String,
  schema_ref: SchemaRef,
  ctx: Context,
  nesting_depth: Int,
) -> String {
  let props = object_properties_from_schema_ref(schema_ref, ctx)
  let prop_names =
    props
    |> list.map(fn(prop) { "\"" <> prop.name <> "\"" })
    |> string.join(", ")
  "case form_object_present(form_body, \""
  <> prefix
  <> "\", ["
  <> prop_names
  <> "]) { True -> Some("
  <> form_urlencoded_object_constructor_expr(
    form_urlencoded_schema_ref_type_name(schema_ref),
    prefix,
    props,
    schema_ref_additional_properties(schema_ref, ctx),
    ctx,
    nesting_depth,
  )
  <> ") False -> None }"
}

pub fn form_urlencoded_body_constructor_expr(
  rb: spec.RequestBody(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  form_urlencoded_object_constructor_expr(
    form_urlencoded_body_type_name(rb, op_id),
    "",
    form_urlencoded_body_properties(rb, ctx),
    body_additional_properties(rb, "application/x-www-form-urlencoded", ctx),
    ctx,
    0,
  )
}

pub fn form_urlencoded_body_has_optional_fields(
  rb: spec.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  form_urlencoded_properties_have_optional_fields(
    form_urlencoded_body_properties(rb, ctx),
    ctx,
    True,
  )
}

pub fn form_urlencoded_body_needs_string(
  rb: spec.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  form_urlencoded_properties_need_string(
    form_urlencoded_body_properties(rb, ctx),
    ctx,
    True,
  )
}

pub fn form_urlencoded_body_needs_int(
  rb: spec.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  form_urlencoded_properties_need_int(
    form_urlencoded_body_properties(rb, ctx),
    ctx,
    True,
  )
}

pub fn form_urlencoded_body_needs_float(
  rb: spec.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  form_urlencoded_properties_need_float(
    form_urlencoded_body_properties(rb, ctx),
    ctx,
    True,
  )
}

pub fn form_urlencoded_body_has_nested_object(
  rb: spec.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  list.any(form_urlencoded_body_properties(rb, ctx), fn(prop) {
    schema_ref_resolves_to_object(prop.schema_ref, ctx)
  })
}

pub fn multipart_body_constructor_expr(
  rb: spec.RequestBody(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  let fields =
    multipart_body_properties(rb, ctx)
    |> list.map(fn(prop) {
      let value_expr = case prop.required {
        True ->
          multipart_body_required_expr_with_schema(
            prop.name,
            Some(prop.schema_ref),
            ctx,
          )
        False ->
          multipart_body_optional_expr_with_schema(
            prop.name,
            Some(prop.schema_ref),
            ctx,
          )
      }
      prop.field_name <> ": " <> value_expr
    })
    |> string.join(", ")
  let additional_props_suffix = case
    body_additional_properties(rb, "multipart/form-data", ctx)
  {
    Forbidden -> ""
    _ -> ", additional_properties: dict.new()"
  }
  multipart_body_type_name(rb, op_id)
  <> "("
  <> fields
  <> additional_props_suffix
  <> ")"
}

pub fn multipart_body_has_optional_fields(
  rb: spec.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  list.any(multipart_body_properties(rb, ctx), fn(prop) { !prop.required })
}

pub fn multipart_body_needs_int(
  rb: spec.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  list.any(multipart_body_properties(rb, ctx), fn(prop) {
    body_field_kind_needs_int(schema_ref_body_field_kind(
      Some(prop.schema_ref),
      ctx,
    ))
  })
}

pub fn multipart_body_needs_float(
  rb: spec.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  list.any(multipart_body_properties(rb, ctx), fn(prop) {
    body_field_kind_needs_float(schema_ref_body_field_kind(
      Some(prop.schema_ref),
      ctx,
    ))
  })
}

fn form_urlencoded_properties_have_optional_fields(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
) -> Bool {
  list.any(props, fn(prop) {
    !prop.required
    || case
      allow_nested_objects
      && schema_ref_resolves_to_object(prop.schema_ref, ctx)
    {
      True ->
        form_urlencoded_properties_have_optional_fields(
          object_properties_from_schema_ref(prop.schema_ref, ctx),
          ctx,
          False,
        )
      False -> False
    }
  })
}

fn form_urlencoded_properties_need_string(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
) -> Bool {
  list.any(props, fn(prop) {
    query_schema_needs_string(Some(prop.schema_ref))
    || case
      allow_nested_objects
      && schema_ref_resolves_to_object(prop.schema_ref, ctx)
    {
      True ->
        form_urlencoded_properties_need_string(
          object_properties_from_schema_ref(prop.schema_ref, ctx),
          ctx,
          False,
        )
      False -> False
    }
  })
}

fn form_urlencoded_properties_need_int(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
) -> Bool {
  list.any(props, fn(prop) {
    body_field_kind_needs_int(schema_ref_body_field_kind(
      Some(prop.schema_ref),
      ctx,
    ))
    || case
      allow_nested_objects
      && schema_ref_resolves_to_object(prop.schema_ref, ctx)
    {
      True ->
        form_urlencoded_properties_need_int(
          object_properties_from_schema_ref(prop.schema_ref, ctx),
          ctx,
          False,
        )
      False -> False
    }
  })
}

fn form_urlencoded_properties_need_float(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
) -> Bool {
  list.any(props, fn(prop) {
    body_field_kind_needs_float(schema_ref_body_field_kind(
      Some(prop.schema_ref),
      ctx,
    ))
    || case
      allow_nested_objects
      && schema_ref_resolves_to_object(prop.schema_ref, ctx)
    {
      True ->
        form_urlencoded_properties_need_float(
          object_properties_from_schema_ref(prop.schema_ref, ctx),
          ctx,
          False,
        )
      False -> False
    }
  })
}

pub fn query_schema_needs_string(schema_ref: Option(SchemaRef)) -> Bool {
  case schema_ref {
    Some(Inline(schema.ArraySchema(..))) -> True
    Some(Inline(schema.BooleanSchema(..))) -> True
    _ -> False
  }
}

pub fn query_schema_needs_int(schema_ref: Option(SchemaRef)) -> Bool {
  case schema_ref {
    Some(Inline(schema.IntegerSchema(..))) -> True
    Some(Inline(schema.ArraySchema(items: Inline(schema.IntegerSchema(..)), ..))) ->
      True
    _ -> False
  }
}

pub fn query_schema_needs_float(schema_ref: Option(SchemaRef)) -> Bool {
  case schema_ref {
    Some(Inline(schema.NumberSchema(..))) -> True
    Some(Inline(schema.ArraySchema(items: Inline(schema.NumberSchema(..)), ..))) ->
      True
    _ -> False
  }
}

fn form_body_required_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  let base =
    "{ let assert Ok([v, ..]) = dict.get(form_body, \"" <> key <> "\") v }"
  case schema_ref_body_field_kind(schema_ref, ctx) {
    BodyFieldStringArray ->
      "{ let assert Ok(vs) = dict.get(form_body, \""
      <> key
      <> "\") list.map(vs, fn(item) { string.trim(item) }) }"
    BodyFieldIntArray ->
      "{ let assert Ok(vs) = dict.get(form_body, \""
      <> key
      <> "\") list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n }) }"
    BodyFieldFloatArray ->
      "{ let assert Ok(vs) = dict.get(form_body, \""
      <> key
      <> "\") list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n }) }"
    BodyFieldBoolArray ->
      "{ let assert Ok(vs) = dict.get(form_body, \""
      <> key
      <> "\") list.map(vs, fn(item) { let v = string.trim(item) "
      <> bool_parse_expr
      <> " }) }"
    BodyFieldInt ->
      "{ let assert Ok([v, ..]) = dict.get(form_body, \""
      <> key
      <> "\") let assert Ok(n) = int.parse(v) n }"
    BodyFieldFloat ->
      "{ let assert Ok([v, ..]) = dict.get(form_body, \""
      <> key
      <> "\") let assert Ok(n) = float.parse(v) n }"
    BodyFieldBool ->
      "{ let assert Ok([v, ..]) = dict.get(form_body, \""
      <> key
      <> "\") "
      <> bool_parse_expr
      <> " }"
    _ -> base
  }
}

fn form_body_optional_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  case schema_ref_body_field_kind(schema_ref, ctx) {
    BodyFieldStringArray ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { string.trim(item) })) _ -> None }"
    BodyFieldIntArray ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n })) _ -> None }"
    BodyFieldFloatArray ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n })) _ -> None }"
    BodyFieldBoolArray ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let v = string.trim(item) "
      <> bool_parse_expr
      <> " })) _ -> None }"
    BodyFieldInt ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    BodyFieldFloat ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    BodyFieldBool ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> Some("
      <> bool_parse_expr
      <> ") _ -> None }"
    _ ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> Some(v) _ -> None }"
  }
}

fn multipart_body_required_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  let base =
    "{ let assert Ok([v, ..]) = dict.get(multipart_body, \"" <> key <> "\") v }"
  case schema_ref_body_field_kind(schema_ref, ctx) {
    BodyFieldInt ->
      "{ let assert Ok([v, ..]) = dict.get(multipart_body, \""
      <> key
      <> "\") let assert Ok(n) = int.parse(v) n }"
    BodyFieldFloat ->
      "{ let assert Ok([v, ..]) = dict.get(multipart_body, \""
      <> key
      <> "\") let assert Ok(n) = float.parse(v) n }"
    BodyFieldBool ->
      "{ let assert Ok([v, ..]) = dict.get(multipart_body, \""
      <> key
      <> "\") "
      <> bool_parse_expr
      <> " }"
    BodyFieldStringArray ->
      "{ let assert Ok(vs) = dict.get(multipart_body, \"" <> key <> "\") vs }"
    BodyFieldIntArray ->
      "{ let assert Ok(vs) = dict.get(multipart_body, \""
      <> key
      <> "\") list.map(vs, fn(item) { let assert Ok(n) = int.parse(item) n }) }"
    BodyFieldFloatArray ->
      "{ let assert Ok(vs) = dict.get(multipart_body, \""
      <> key
      <> "\") list.map(vs, fn(item) { let assert Ok(n) = float.parse(item) n }) }"
    BodyFieldBoolArray ->
      "{ let assert Ok(vs) = dict.get(multipart_body, \""
      <> key
      <> "\") list.map(vs, fn(item) { let v = item "
      <> bool_parse_expr
      <> " }) }"
    _ -> base
  }
}

fn multipart_body_optional_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  case schema_ref_body_field_kind(schema_ref, ctx) {
    BodyFieldInt ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    BodyFieldFloat ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    BodyFieldBool ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> Some("
      <> bool_parse_expr
      <> ") _ -> None }"
    BodyFieldStringArray ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(vs) _ -> None }"
    BodyFieldIntArray ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let assert Ok(n) = int.parse(item) n })) _ -> None }"
    BodyFieldFloatArray ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let assert Ok(n) = float.parse(item) n })) _ -> None }"
    BodyFieldBoolArray ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let v = item "
      <> bool_parse_expr
      <> " })) _ -> None }"
    _ ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> Some(v) _ -> None }"
  }
}

/// Generate expression for a required header parameter.
pub fn header_required_expr(
  key: String,
  param: spec.Parameter(Resolved),
) -> String {
  case spec.parameter_schema(param) {
    Some(Inline(schema.ArraySchema(items: Inline(schema.StringSchema(..)), ..))) ->
      "{ let assert Ok(v) = dict.get(headers, \""
      <> key
      <> "\") list.map(string.split(v, \",\"), fn(item) { string.trim(item) }) }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.IntegerSchema(..)), ..))) ->
      "{ let assert Ok(v) = dict.get(headers, \""
      <> key
      <> "\") list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n }) }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.NumberSchema(..)), ..))) ->
      "{ let assert Ok(v) = dict.get(headers, \""
      <> key
      <> "\") list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n }) }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.BooleanSchema(..)), ..))) ->
      "{ let assert Ok(v) = dict.get(headers, \""
      <> key
      <> "\") list.map(string.split(v, \",\"), fn(item) { let v = string.trim(item) "
      <> bool_parse_expr
      <> " }) }"
    Some(Inline(schema.IntegerSchema(..))) ->
      "{ let assert Ok(v) = dict.get(headers, \""
      <> key
      <> "\") let assert Ok(n) = int.parse(v) n }"
    Some(Inline(schema.NumberSchema(..))) ->
      "{ let assert Ok(v) = dict.get(headers, \""
      <> key
      <> "\") let assert Ok(n) = float.parse(v) n }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "{ let assert Ok(v) = dict.get(headers, \""
      <> key
      <> "\") "
      <> bool_parse_expr
      <> " }"
    _ -> "{ let assert Ok(v) = dict.get(headers, \"" <> key <> "\") v }"
  }
}

/// Generate expression for an optional header parameter.
pub fn header_optional_expr(
  key: String,
  param: spec.Parameter(Resolved),
) -> String {
  case spec.parameter_schema(param) {
    Some(Inline(schema.ArraySchema(items: Inline(schema.StringSchema(..)), ..))) ->
      "case dict.get(headers, \""
      <> key
      <> "\") { Ok(v) -> Some(list.map(string.split(v, \",\"), fn(item) { string.trim(item) })) _ -> None }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.IntegerSchema(..)), ..))) ->
      "case dict.get(headers, \""
      <> key
      <> "\") { Ok(v) -> Some(list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n })) _ -> None }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.NumberSchema(..)), ..))) ->
      "case dict.get(headers, \""
      <> key
      <> "\") { Ok(v) -> Some(list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n })) _ -> None }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.BooleanSchema(..)), ..))) ->
      "case dict.get(headers, \""
      <> key
      <> "\") { Ok(v) -> Some(list.map(string.split(v, \",\"), fn(item) { let v = string.trim(item) "
      <> bool_parse_expr
      <> " })) _ -> None }"
    Some(Inline(schema.IntegerSchema(..))) ->
      "case dict.get(headers, \""
      <> key
      <> "\") { Ok(v) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    Some(Inline(schema.NumberSchema(..))) ->
      "case dict.get(headers, \""
      <> key
      <> "\") { Ok(v) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "case dict.get(headers, \""
      <> key
      <> "\") { Ok(v) -> Some("
      <> bool_parse_expr
      <> ") _ -> None }"
    _ ->
      "case dict.get(headers, \"" <> key <> "\") { Ok(v) -> Some(v) _ -> None }"
  }
}

/// Generate expression for a required cookie parameter.
pub fn cookie_required_expr(
  key: String,
  param: spec.Parameter(Resolved),
) -> String {
  case spec.parameter_schema(param) {
    Some(Inline(schema.IntegerSchema(..))) ->
      "{ let assert Ok(v) = cookie_lookup(headers, \""
      <> key
      <> "\") let assert Ok(n) = int.parse(v) n }"
    Some(Inline(schema.NumberSchema(..))) ->
      "{ let assert Ok(v) = cookie_lookup(headers, \""
      <> key
      <> "\") let assert Ok(n) = float.parse(v) n }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "{ let assert Ok(v) = cookie_lookup(headers, \""
      <> key
      <> "\") "
      <> bool_parse_expr
      <> " }"
    _ -> "{ let assert Ok(v) = cookie_lookup(headers, \"" <> key <> "\") v }"
  }
}

/// Generate expression for an optional cookie parameter.
pub fn cookie_optional_expr(
  key: String,
  param: spec.Parameter(Resolved),
) -> String {
  case spec.parameter_schema(param) {
    Some(Inline(schema.IntegerSchema(..))) ->
      "case cookie_lookup(headers, \""
      <> key
      <> "\") { Ok(v) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } Error(_) -> None }"
    Some(Inline(schema.NumberSchema(..))) ->
      "case cookie_lookup(headers, \""
      <> key
      <> "\") { Ok(v) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } Error(_) -> None }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "case cookie_lookup(headers, \""
      <> key
      <> "\") { Ok(v) -> Some("
      <> bool_parse_expr
      <> ") Error(_) -> None }"
    _ ->
      "case cookie_lookup(headers, \""
      <> key
      <> "\") { Ok(v) -> Some(v) Error(_) -> None }"
  }
}

/// Generate the body decode expression for a request body.
pub fn generate_body_decode_expr(
  rb: spec.RequestBody(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  let content_entries = dict.to_list(rb.content)
  case content_entries {
    [#("application/json", media_type)] -> {
      let decode_fn = case media_type.schema {
        Some(Reference(name:, ..)) ->
          "decode.decode_" <> naming.to_snake_case(name) <> "(body)"
        _ ->
          "decode.decode_"
          <> naming.to_snake_case(op_id)
          <> "_request_body(body)"
      }
      case rb.required {
        True -> "{ let assert Ok(decoded) = " <> decode_fn <> " decoded }"
        False ->
          "case body { \"\" -> None _ -> { case "
          <> decode_fn
          <> " { Ok(decoded) -> Some(decoded) _ -> None } } }"
      }
    }
    [#("application/x-www-form-urlencoded", _media_type)] -> {
      let body_expr = form_urlencoded_body_constructor_expr(rb, op_id, ctx)
      case rb.required {
        True -> body_expr
        False -> "case body { \"\" -> None _ -> Some(" <> body_expr <> ") }"
      }
    }
    [#("multipart/form-data", _media_type)] -> {
      let body_expr = multipart_body_constructor_expr(rb, op_id, ctx)
      case rb.required {
        True -> body_expr
        False -> "case body { \"\" -> None _ -> Some(" <> body_expr <> ") }"
      }
    }
    _ -> {
      case rb.required {
        True -> "body"
        False -> "case body { \"\" -> None _ -> Some(body) }"
      }
    }
  }
}
