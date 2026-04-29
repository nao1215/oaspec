/// Centralized schema dispatch logic.
/// This module is the single source of truth for mapping schemas to:
/// - Gleam type names
/// - To-string conversion expressions
/// - Decoder function names
/// - Encoder function names/expressions
///
/// Previously this logic was duplicated across types.gleam, decoders.gleam,
/// client.gleam, and guards.gleam (14+ functions with the same dispatch).
import gleam/option.{type Option, None, Some}
import oaspec/internal/openapi/resolver
import oaspec/internal/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  BooleanSchema, Inline, IntegerSchema, NumberSchema, ObjectSchema, OneOfSchema,
  Reference, StringSchema,
}
import oaspec/internal/openapi/spec.{type OpenApiSpec, type Resolved}
import oaspec/internal/util/naming

/// Map a schema object to its Gleam type string (without nullable wrapping).
pub fn schema_base_type(schema: SchemaObject) -> String {
  case schema {
    StringSchema(..) -> "String"
    IntegerSchema(..) -> "Int"
    NumberSchema(..) -> "Float"
    BooleanSchema(..) -> "Bool"
    ArraySchema(items:, ..) -> "List(" <> schema_ref_type(items) <> ")"
    ObjectSchema(..) -> "String"
    AllOfSchema(..) -> "String"
    OneOfSchema(..) -> "String"
    AnyOfSchema(..) -> "String"
  }
}

/// Map a schema object to its Gleam type string (with nullable wrapping).
pub fn schema_type(schema: SchemaObject) -> String {
  let base = schema_base_type(schema)
  case schema.is_nullable(schema) {
    True -> "Option(" <> base <> ")"
    False -> base
  }
}

/// Map a schema ref to a Gleam type string.
fn schema_ref_type(ref: SchemaRef) -> String {
  case ref {
    Inline(schema) -> schema_base_type(schema)
    Reference(name:, ..) -> naming.schema_to_type_name(name)
  }
}

/// Map a schema ref to a qualified Gleam type (with types. prefix for refs).
pub fn schema_ref_qualified_type(ref: SchemaRef) -> String {
  case ref {
    Inline(schema) -> schema_base_type(schema)
    Reference(name:, ..) -> "types." <> naming.schema_to_type_name(name)
  }
}

/// Map a primitive schema to its to_string expression.
/// Returns the expression that converts a value to String for URL encoding.
pub fn to_string_expr(schema: SchemaObject, value: String) -> String {
  case schema {
    IntegerSchema(..) -> "int.to_string(" <> value <> ")"
    NumberSchema(..) -> "float.to_string(" <> value <> ")"
    BooleanSchema(..) -> "bool.to_string(" <> value <> ")"
    StringSchema(..) -> value
    _ -> value
  }
}

/// Map a schema ref to a to_string expression, resolving refs if needed.
pub fn schema_ref_to_string_expr(
  ref: SchemaRef,
  value: String,
  spec: OpenApiSpec(Resolved),
) -> String {
  case ref {
    Inline(schema) -> to_string_expr(schema, value)
    Reference(name:, ..) -> {
      case resolver.resolve_schema_ref(ref, spec) {
        Ok(StringSchema(enum_values:, ..)) if enum_values != [] ->
          "encode.encode_"
          <> naming.to_snake_case(name)
          <> "_to_string("
          <> value
          <> ")"
        Ok(resolved) -> to_string_expr(resolved, value)
        // nolint: thrown_away_error -- unresolved refs fall back to the raw accessor; the resolver reports the ref error separately
        Error(_) -> value
      }
    }
  }
}

/// Map a schema ref to its decoder expression (for inline primitives)
/// or decoder function name (for references).
///
/// Inline complex schemas (object, allOf, oneOf, anyOf) are not
/// supported here — they must be defined under `components/schemas`
/// and referenced via `$ref`. The catch-all panics so unsupported
/// patterns fail fast instead of silently generating broken code
/// (#290).
pub fn decoder_expr(ref: SchemaRef) -> String {
  case ref {
    Inline(StringSchema(..)) -> "decode.string"
    Inline(IntegerSchema(..)) -> "decode.int"
    Inline(NumberSchema(..)) -> "decode.float"
    Inline(BooleanSchema(..)) -> "decode.bool"
    Reference(name:, ..) -> naming.to_snake_case(name) <> "_decoder()"
    Inline(schema) ->
      panic as {
        "oaspec: inline "
        <> schema_kind(schema)
        <> " schema is not supported in decoder_expr. "
        <> "Move the schema to components/schemas and use a $ref instead."
      }
  }
}

/// Map a schema ref to its JSON encoder expression.
pub fn json_encoder_expr(ref: SchemaRef, value: String) -> String {
  case ref {
    Inline(StringSchema(..)) -> "json.string(" <> value <> ")"
    Inline(IntegerSchema(..)) -> "json.int(" <> value <> ")"
    Inline(NumberSchema(..)) -> "json.float(" <> value <> ")"
    Inline(BooleanSchema(..)) -> "json.bool(" <> value <> ")"
    Reference(name:, ..) ->
      "encode_" <> naming.to_snake_case(name) <> "_json(" <> value <> ")"
    Inline(schema) ->
      panic as {
        "oaspec: inline "
        <> schema_kind(schema)
        <> " schema is not supported in json_encoder_expr. "
        <> "Move the schema to components/schemas and use a $ref instead."
      }
  }
}

/// Map a schema ref to its JSON encoder function reference (for higher-order use).
pub fn json_encoder_fn(ref: SchemaRef) -> String {
  case ref {
    Inline(StringSchema(..)) -> "json.string"
    Inline(IntegerSchema(..)) -> "json.int"
    Inline(NumberSchema(..)) -> "json.float"
    Inline(BooleanSchema(..)) -> "json.bool"
    Reference(name:, ..) -> "encode_" <> naming.to_snake_case(name) <> "_json"
    Inline(schema) ->
      panic as {
        "oaspec: inline "
        <> schema_kind(schema)
        <> " schema is not supported in json_encoder_fn. "
        <> "Move the schema to components/schemas and use a $ref instead."
      }
  }
}

/// Map a schema ref to its to_string function reference (for list.map etc).
pub fn to_string_fn(ref: SchemaRef, spec: OpenApiSpec(Resolved)) -> String {
  case ref {
    Inline(StringSchema(..)) -> "fn(x) { x }"
    Inline(IntegerSchema(..)) -> "int.to_string"
    Inline(NumberSchema(..)) -> "float.to_string"
    Inline(BooleanSchema(..)) -> "bool.to_string"
    Reference(name:, ..) -> {
      case resolver.resolve_schema_ref(ref, spec) {
        Ok(StringSchema(enum_values:, ..)) if enum_values != [] ->
          "encode.encode_" <> naming.to_snake_case(name) <> "_to_string"
        Ok(resolved) -> to_string_fn(Inline(resolved), spec)
        // nolint: thrown_away_error -- unresolved refs fall back to identity; the resolver reports the ref error separately
        Error(_) -> "fn(x) { x }"
      }
    }
    Inline(schema) ->
      panic as {
        "oaspec: inline "
        <> schema_kind(schema)
        <> " schema is not supported in to_string_fn. "
        <> "Move the schema to components/schemas and use a $ref instead."
      }
  }
}

/// Human-readable name for a schema variant (for error messages).
fn schema_kind(schema: SchemaObject) -> String {
  case schema {
    StringSchema(..) -> "string"
    IntegerSchema(..) -> "integer"
    NumberSchema(..) -> "number"
    BooleanSchema(..) -> "boolean"
    ArraySchema(..) -> "array"
    ObjectSchema(..) -> "object"
    AllOfSchema(..) -> "allOf"
    OneOfSchema(..) -> "oneOf"
    AnyOfSchema(..) -> "anyOf"
  }
}

/// Resolve a schema ref and return the base type (for parameter type resolution).
pub fn resolve_param_type(
  schema_ref: Option(SchemaRef),
  spec: OpenApiSpec(Resolved),
) -> String {
  case schema_ref {
    Some(Inline(schema)) -> schema_base_type(schema)
    Some(Reference(name:, ..) as ref) -> {
      case resolver.resolve_schema_ref(ref, spec) {
        Ok(ArraySchema(items:, ..)) -> "List(" <> schema_ref_type(items) <> ")"
        _ -> "types." <> naming.schema_to_type_name(name)
      }
    }
    None -> "String"
  }
}
