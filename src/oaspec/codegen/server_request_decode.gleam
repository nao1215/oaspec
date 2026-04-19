import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/codegen/context.{type Context}
import oaspec/codegen/ir_build
import oaspec/codegen/operation_ir
import oaspec/openapi/resolver
import oaspec/openapi/schema.{
  type AdditionalProperties, type SchemaRef, Forbidden, Inline, ObjectSchema,
  Reference, Untyped,
}
import oaspec/openapi/spec.{type Resolved, Value}
import oaspec/util/content_type
import oaspec/util/naming

/// Expression that case-insensitively parses a string to Bool.
/// Accepts "true"/"True"/"TRUE" etc. as True, everything else as False.
/// This is compatible with Gleam's bool.to_string which produces "True"/"False".
const bool_parse_expr = "case string.lowercase(v) { \"true\" -> True _ -> False }"

type DeepObjectProperty {
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
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
        Ok(schema_obj) -> body_field_kind_from_object(schema_obj, ctx)
        // nolint: thrown_away_error -- unresolved refs map to Unknown; the resolver reports the ref error separately
        Error(_) -> BodyFieldUnknown
      }
    _ -> BodyFieldUnknown
  }
}

fn body_field_kind_from_object(
  schema_obj: schema.SchemaObject,
  ctx: Context,
) -> BodyFieldKind {
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
/// Returns a safe expression that does not crash on invalid input.
/// For types that need parsing (int, float), returns the raw parse call
/// so the router can wrap it in a case expression for error handling.
pub fn param_parse_expr(
  var_name: String,
  param: spec.Parameter(Resolved),
) -> String {
  case spec.parameter_schema(param) {
    Some(Inline(schema.IntegerSchema(..))) -> {
      "int.parse(" <> var_name <> ")"
    }
    Some(Inline(schema.NumberSchema(..))) -> {
      "float.parse(" <> var_name <> ")"
    }
    Some(Inline(schema.BooleanSchema(..))) -> {
      "{ let v = " <> var_name <> " " <> bool_parse_expr <> " }"
    }
    _ -> var_name
  }
}

/// Return true when the parse expression returns a Result that the router
/// must unwrap (int/float parsing). Bool and string params are always safe.
pub fn param_needs_result_unwrap(param: spec.Parameter(Resolved)) -> Bool {
  case spec.parameter_schema(param) {
    Some(Inline(schema.IntegerSchema(..)))
    | Some(Inline(schema.NumberSchema(..))) -> True
    _ -> False
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
    Some(operation_ir.effective_explode(param)),
    param.style,
  )
}

fn query_required_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  explode: Option(Bool),
  style: Option(spec.ParameterStyle),
) -> String {
  let delim = operation_ir.delimiter_for_style(style)
  let base = "{ let assert Ok([v, ..]) = dict.get(query, \"" <> key <> "\") v }"
  case schema_ref {
    Some(Inline(schema.ArraySchema(items: Inline(schema.StringSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "{ let assert Ok([v, ..]) = dict.get(query, \""
          <> key
          <> "\") list.map(string.split(v, \""
          <> delim
          <> "\"), fn(item) { string.trim(item) }) }"
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
          <> "\") list.map(string.split(v, \""
          <> delim
          <> "\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n }) }"
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
          <> "\") list.map(string.split(v, \""
          <> delim
          <> "\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n }) }"
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
          <> "\") list.map(string.split(v, \""
          <> delim
          <> "\"), fn(item) { let v = string.trim(item) "
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
    Some(operation_ir.effective_explode(param)),
    param.style,
  )
}

fn query_optional_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  explode: Option(Bool),
  style: Option(spec.ParameterStyle),
) -> String {
  let delim = operation_ir.delimiter_for_style(style)
  case schema_ref {
    Some(Inline(schema.ArraySchema(items: Inline(schema.StringSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok([v, ..]) -> Some(list.map(string.split(v, \""
          <> delim
          <> "\"), fn(item) { string.trim(item) })) _ -> None }"
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
          <> "\") { Ok([v, ..]) -> Some(list.map(string.split(v, \""
          <> delim
          <> "\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n })) _ -> None }"
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
          <> "\") { Ok([v, ..]) -> Some(list.map(string.split(v, \""
          <> delim
          <> "\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n })) _ -> None }"
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
          <> "\") { Ok([v, ..]) -> Some(list.map(string.split(v, \""
          <> delim
          <> "\"), fn(item) { let v = string.trim(item) "
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
  operation_ir.is_deep_object_param(param, ctx)
}

fn deep_object_properties(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> List(DeepObjectProperty) {
  let details = case spec.parameter_schema(param) {
    Some(Reference(..) as schema_ref) ->
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
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
  ir_build.sorted_entries(properties)
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
  let has_untyped_ap = deep_object_has_untyped_additional_properties(param, ctx)
  let presence_check = case has_untyped_ap {
    True -> "deep_object_present_any(query, \"" <> key <> "\")"
    False ->
      "deep_object_present(query, \"" <> key <> "\", [" <> prop_names <> "])"
  }
  "case "
  <> presence_check
  <> " { True -> Some("
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
            None,
          )
        False ->
          query_optional_expr_with_schema(
            prop_key,
            Some(prop.schema_ref),
            Some(True),
            None,
          )
      }
      prop.field_name <> ": " <> value_expr
    })

  // Add additional_properties field if the schema has it
  let ap_kind = case spec.parameter_schema(param) {
    Some(schema_ref) -> schema_ref_additional_properties(schema_ref, ctx)
    None -> Forbidden
  }
  let fields = case ap_kind {
    Forbidden -> fields
    Untyped -> {
      let prop_names =
        deep_object_properties(param, ctx)
        |> list.map(fn(prop) { "\"" <> prop.name <> "\"" })
        |> string.join(", ")
      let expr =
        "coerce_dict(deep_object_additional_properties(query, \""
        <> key
        <> "\", ["
        <> prop_names
        <> "]))"
      list.append(fields, ["additional_properties: " <> expr])
    }
    _ -> {
      // Typed additional properties need type-specific conversion;
      // use empty dict as fallback until type-aware collection is implemented
      list.append(fields, ["additional_properties: dict.new()"])
    }
  }

  let fields_str = string.join(fields, ", ")
  deep_object_type_name(param, op_id) <> "(" <> fields_str <> ")"
}

pub fn deep_object_has_additional_properties(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  case spec.parameter_schema(param) {
    Some(Reference(..) as schema_ref) ->
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
        Ok(ObjectSchema(additional_properties: schema.Typed(_), ..)) -> True
        Ok(ObjectSchema(additional_properties: schema.Untyped, ..)) -> True
        _ -> False
      }
    Some(Inline(ObjectSchema(additional_properties: schema.Typed(_), ..))) ->
      True
    Some(Inline(ObjectSchema(additional_properties: schema.Untyped, ..))) ->
      True
    _ -> False
  }
}

pub fn deep_object_has_untyped_additional_properties(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  case spec.parameter_schema(param) {
    Some(schema_ref) ->
      case schema_ref_additional_properties(schema_ref, ctx) {
        Untyped -> True
        _ -> False
      }
    None -> False
  }
}

pub fn deep_object_param_has_optional_fields(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  use <- bool.guard(!is_deep_object_param(param, ctx), False)
  list.any(deep_object_properties(param, ctx), fn(prop) { !prop.required })
}

pub fn deep_object_param_needs_string(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  deep_object_param_needs(param, ctx, fn(prop) {
    query_schema_needs_string(Some(prop.schema_ref))
  })
}

pub fn deep_object_param_needs_int(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  deep_object_param_needs(param, ctx, fn(prop) {
    query_schema_needs_int(Some(prop.schema_ref))
  })
}

pub fn deep_object_param_needs_float(
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  deep_object_param_needs(param, ctx, fn(prop) {
    query_schema_needs_float(Some(prop.schema_ref))
  })
}

fn deep_object_param_needs(
  param: spec.Parameter(Resolved),
  ctx: Context,
  predicate: fn(DeepObjectProperty) -> Bool,
) -> Bool {
  use <- bool.guard(!is_deep_object_param(param, ctx), False)
  list.any(deep_object_properties(param, ctx), predicate)
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

fn object_properties_from_schema_ref(
  schema_ref: SchemaRef,
  ctx: Context,
) -> List(DeepObjectProperty) {
  let details = case schema_ref {
    Reference(..) as schema_ref ->
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
        Ok(ObjectSchema(properties:, required:, ..)) -> #(properties, required)
        _ -> #(dict.new(), [])
      }
    Inline(ObjectSchema(properties:, required:, ..)) -> #(properties, required)
    _ -> #(dict.new(), [])
  }
  let #(properties, required_fields) = details
  ir_build.sorted_entries(properties)
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
    // nolint: thrown_away_error -- absence of the content type means no properties to enumerate
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
    // nolint: thrown_away_error -- absence of the content type means no properties to enumerate
    Error(_) -> []
  }
}

fn schema_ref_resolves_to_object(schema_ref: SchemaRef, ctx: Context) -> Bool {
  case schema_ref {
    Inline(ObjectSchema(..)) -> True
    Reference(..) as schema_ref ->
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
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
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
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
    // nolint: thrown_away_error -- absence of the content type means no additionalProperties
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
    // nolint: thrown_away_error -- absence of the content type falls back to the raw body type
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
    // nolint: thrown_away_error -- absence of the content type falls back to the raw body type
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

fn form_urlencoded_body_constructor_expr(
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

fn multipart_body_constructor_expr(
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
  form_urlencoded_properties_need(props, ctx, allow_nested_objects, fn(prop) {
    query_schema_needs_string(Some(prop.schema_ref))
  })
}

fn form_urlencoded_properties_need_int(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
) -> Bool {
  form_urlencoded_properties_need(props, ctx, allow_nested_objects, fn(prop) {
    body_field_kind_needs_int(schema_ref_body_field_kind(
      Some(prop.schema_ref),
      ctx,
    ))
  })
}

fn form_urlencoded_properties_need_float(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
) -> Bool {
  form_urlencoded_properties_need(props, ctx, allow_nested_objects, fn(prop) {
    body_field_kind_needs_float(schema_ref_body_field_kind(
      Some(prop.schema_ref),
      ctx,
    ))
  })
}

fn form_urlencoded_properties_need(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
  predicate: fn(DeepObjectProperty) -> Bool,
) -> Bool {
  list.any(props, fn(prop) {
    predicate(prop)
    || case
      allow_nested_objects
      && schema_ref_resolves_to_object(prop.schema_ref, ctx)
    {
      True ->
        form_urlencoded_properties_need(
          object_properties_from_schema_ref(prop.schema_ref, ctx),
          ctx,
          False,
          predicate,
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
  body_required_expr(key, "form_body", True, schema_ref, ctx)
}

fn form_body_optional_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  body_optional_expr(key, "form_body", True, "_", schema_ref, ctx)
}

fn multipart_body_required_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  body_required_expr(key, "multipart_body", False, schema_ref, ctx)
}

fn multipart_body_optional_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  body_optional_expr(key, "multipart_body", False, "_", schema_ref, ctx)
}

/// Generate a required body field expression.
/// `source` is the dict name (e.g., "form_body", "multipart_body").
/// `trim_items` controls whether array items are trimmed (form_body) or used raw (multipart).
fn body_required_expr(
  key: String,
  source: String,
  trim_items: Bool,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  let lookup = "dict.get(" <> source <> ", \"" <> key <> "\")"
  let base = "{ let assert Ok([v, ..]) = " <> lookup <> " v }"
  case schema_ref_body_field_kind(schema_ref, ctx) {
    BodyFieldStringArray ->
      case trim_items {
        True ->
          "{ let assert Ok(vs) = "
          <> lookup
          <> " list.map(vs, fn(item) { string.trim(item) }) }"
        False -> "{ let assert Ok(vs) = " <> lookup <> " vs }"
      }
    BodyFieldIntArray ->
      "{ let assert Ok(vs) = "
      <> lookup
      <> " list.map(vs, fn(item) { "
      <> array_item_int_parse(trim_items)
      <> " }) }"
    BodyFieldFloatArray ->
      "{ let assert Ok(vs) = "
      <> lookup
      <> " list.map(vs, fn(item) { "
      <> array_item_float_parse(trim_items)
      <> " }) }"
    BodyFieldBoolArray ->
      "{ let assert Ok(vs) = "
      <> lookup
      <> " list.map(vs, fn(item) { "
      <> array_item_bool_parse(trim_items)
      <> " }) }"
    BodyFieldInt ->
      "{ let assert Ok([v, ..]) = "
      <> lookup
      <> " let assert Ok(n) = int.parse(v) n }"
    BodyFieldFloat ->
      "{ let assert Ok([v, ..]) = "
      <> lookup
      <> " let assert Ok(n) = float.parse(v) n }"
    BodyFieldBool ->
      "{ let assert Ok([v, ..]) = " <> lookup <> " " <> bool_parse_expr <> " }"
    _ -> base
  }
}

/// Generate an optional body field expression.
/// `source` is the dict name, `miss` is the miss pattern ("_" or "Error(_)").
fn body_optional_expr(
  key: String,
  source: String,
  trim_items: Bool,
  miss: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  let lookup = "dict.get(" <> source <> ", \"" <> key <> "\")"
  case schema_ref_body_field_kind(schema_ref, ctx) {
    BodyFieldStringArray ->
      case trim_items {
        True ->
          "case "
          <> lookup
          <> " { Ok(vs) -> Some(list.map(vs, fn(item) { string.trim(item) })) "
          <> miss
          <> " -> None }"
        False ->
          "case " <> lookup <> " { Ok(vs) -> Some(vs) " <> miss <> " -> None }"
      }
    BodyFieldIntArray ->
      "case "
      <> lookup
      <> " { Ok(vs) -> Some(list.map(vs, fn(item) { "
      <> array_item_int_parse(trim_items)
      <> " })) "
      <> miss
      <> " -> None }"
    BodyFieldFloatArray ->
      "case "
      <> lookup
      <> " { Ok(vs) -> Some(list.map(vs, fn(item) { "
      <> array_item_float_parse(trim_items)
      <> " })) "
      <> miss
      <> " -> None }"
    BodyFieldBoolArray ->
      "case "
      <> lookup
      <> " { Ok(vs) -> Some(list.map(vs, fn(item) { "
      <> array_item_bool_parse(trim_items)
      <> " })) "
      <> miss
      <> " -> None }"
    BodyFieldInt ->
      "case "
      <> lookup
      <> " { Ok([v, ..]) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } "
      <> miss
      <> " -> None }"
    BodyFieldFloat ->
      "case "
      <> lookup
      <> " { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } "
      <> miss
      <> " -> None }"
    BodyFieldBool ->
      "case "
      <> lookup
      <> " { Ok([v, ..]) -> Some("
      <> bool_parse_expr
      <> ") "
      <> miss
      <> " -> None }"
    _ ->
      "case " <> lookup <> " { Ok([v, ..]) -> Some(v) " <> miss <> " -> None }"
  }
}

/// Parse expression for array items: int, with optional trimming.
fn array_item_int_parse(trim: Bool) -> String {
  use <- bool.guard(!trim, "let assert Ok(n) = int.parse(item) n")
  "let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n"
}

/// Parse expression for array items: float, with optional trimming.
fn array_item_float_parse(trim: Bool) -> String {
  use <- bool.guard(!trim, "let assert Ok(n) = float.parse(item) n")
  "let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n"
}

/// Parse expression for array items: bool, with optional trimming.
fn array_item_bool_parse(trim: Bool) -> String {
  case trim {
    True -> "let v = string.trim(item) " <> bool_parse_expr
    False -> "let v = item " <> bool_parse_expr
  }
}

/// Generate expression for a required header parameter.
pub fn header_required_expr(
  key: String,
  param: spec.Parameter(Resolved),
) -> String {
  let lookup = "dict.get(headers, \"" <> key <> "\")"
  single_value_required_expr(lookup, "v", spec.parameter_schema(param))
}

/// Generate expression for an optional header parameter.
pub fn header_optional_expr(
  key: String,
  param: spec.Parameter(Resolved),
) -> String {
  let lookup = "dict.get(headers, \"" <> key <> "\")"
  single_value_optional_expr(lookup, "v", "_", spec.parameter_schema(param))
}

/// Generate expression for a required cookie parameter.
pub fn cookie_required_expr(
  key: String,
  param: spec.Parameter(Resolved),
) -> String {
  let lookup = "cookie_lookup(headers, \"" <> key <> "\")"
  single_value_required_expr(lookup, "v", spec.parameter_schema(param))
}

/// Generate expression for an optional cookie parameter.
pub fn cookie_optional_expr(
  key: String,
  param: spec.Parameter(Resolved),
) -> String {
  let lookup = "cookie_lookup(headers, \"" <> key <> "\")"
  single_value_optional_expr(
    lookup,
    "v",
    "Error(_)",
    spec.parameter_schema(param),
  )
}

/// Generate a required expression for a source that returns a single value.
/// Used for headers (dict.get returns single string) and cookies.
/// Header arrays are comma-separated in a single string value.
fn single_value_required_expr(
  lookup: String,
  var: String,
  schema_ref: Option(SchemaRef),
) -> String {
  let base = "{ let assert Ok(" <> var <> ") = " <> lookup <> " " <> var <> " }"
  case schema_ref {
    Some(Inline(schema.ArraySchema(items: Inline(schema.StringSchema(..)), ..))) ->
      "{ let assert Ok("
      <> var
      <> ") = "
      <> lookup
      <> " list.map(string.split("
      <> var
      <> ", \",\"), fn(item) { string.trim(item) }) }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.IntegerSchema(..)), ..))) ->
      "{ let assert Ok("
      <> var
      <> ") = "
      <> lookup
      <> " list.map(string.split("
      <> var
      <> ", \",\"), fn(item) { "
      <> array_item_int_parse(True)
      <> " }) }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.NumberSchema(..)), ..))) ->
      "{ let assert Ok("
      <> var
      <> ") = "
      <> lookup
      <> " list.map(string.split("
      <> var
      <> ", \",\"), fn(item) { "
      <> array_item_float_parse(True)
      <> " }) }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.BooleanSchema(..)), ..))) ->
      "{ let assert Ok("
      <> var
      <> ") = "
      <> lookup
      <> " list.map(string.split("
      <> var
      <> ", \",\"), fn(item) { "
      <> array_item_bool_parse(True)
      <> " }) }"
    Some(Inline(schema.IntegerSchema(..))) ->
      "{ let assert Ok("
      <> var
      <> ") = "
      <> lookup
      <> " let assert Ok(n) = int.parse("
      <> var
      <> ") n }"
    Some(Inline(schema.NumberSchema(..))) ->
      "{ let assert Ok("
      <> var
      <> ") = "
      <> lookup
      <> " let assert Ok(n) = float.parse("
      <> var
      <> ") n }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "{ let assert Ok("
      <> var
      <> ") = "
      <> lookup
      <> " "
      <> bool_parse_expr
      <> " }"
    _ -> base
  }
}

/// Generate an optional expression for a source that returns a single value.
fn single_value_optional_expr(
  lookup: String,
  var: String,
  miss: String,
  schema_ref: Option(SchemaRef),
) -> String {
  case schema_ref {
    Some(Inline(schema.ArraySchema(items: Inline(schema.StringSchema(..)), ..))) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> Some(list.map(string.split("
      <> var
      <> ", \",\"), fn(item) { string.trim(item) })) "
      <> miss
      <> " -> None }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.IntegerSchema(..)), ..))) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> Some(list.map(string.split("
      <> var
      <> ", \",\"), fn(item) { "
      <> array_item_int_parse(True)
      <> " })) "
      <> miss
      <> " -> None }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.NumberSchema(..)), ..))) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> Some(list.map(string.split("
      <> var
      <> ", \",\"), fn(item) { "
      <> array_item_float_parse(True)
      <> " })) "
      <> miss
      <> " -> None }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.BooleanSchema(..)), ..))) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> Some(list.map(string.split("
      <> var
      <> ", \",\"), fn(item) { "
      <> array_item_bool_parse(True)
      <> " })) "
      <> miss
      <> " -> None }"
    Some(Inline(schema.IntegerSchema(..))) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> { case int.parse("
      <> var
      <> ") { Ok(n) -> Some(n) _ -> None } } "
      <> miss
      <> " -> None }"
    Some(Inline(schema.NumberSchema(..))) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> { case float.parse("
      <> var
      <> ") { Ok(n) -> Some(n) _ -> None } } "
      <> miss
      <> " -> None }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> Some("
      <> bool_parse_expr
      <> ") "
      <> miss
      <> " -> None }"
    _ ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> Some("
      <> var
      <> ") "
      <> miss
      <> " -> None }"
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
    [#(ct_name, media_type)] ->
      case content_type.from_string(ct_name) {
        content_type.ApplicationJson -> {
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
        content_type.FormUrlEncoded -> {
          let body_expr = form_urlencoded_body_constructor_expr(rb, op_id, ctx)
          case rb.required {
            True -> body_expr
            False -> "case body { \"\" -> None _ -> Some(" <> body_expr <> ") }"
          }
        }
        content_type.MultipartFormData -> {
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
    _ -> {
      case rb.required {
        True -> "body"
        False -> "case body { \"\" -> None _ -> Some(body) }"
      }
    }
  }
}
