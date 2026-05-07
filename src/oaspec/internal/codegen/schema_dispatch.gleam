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
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  BooleanSchema, Inline, IntegerSchema, NumberSchema, ObjectSchema, OneOfSchema,
  Reference, StringSchema,
}
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

/// Like `schema_type`, but recurses into composites so any
/// `Reference(_)` items / sub-schemas come back qualified with the
/// `types.` prefix. Use this from any module that imports `types` as
/// a separate qualifier (`guards.gleam`, `decoders.gleam`); plain
/// `schema_type` flattens references bare and only works inside
/// `types.gleam` itself.
pub fn schema_type_qualified(schema: SchemaObject) -> String {
  let base = case schema {
    ArraySchema(items:, ..) ->
      "List(" <> schema_ref_qualified_type_recursive(items) <> ")"
    _ -> schema_base_type(schema)
  }
  case schema.is_nullable(schema) {
    True -> "Option(" <> base <> ")"
    False -> base
  }
}

fn schema_ref_qualified_type_recursive(ref: SchemaRef) -> String {
  case ref {
    Inline(s) -> schema_type_qualified(s)
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
  ctx: Context,
) -> String {
  case ref {
    Inline(schema) -> to_string_expr(schema, value)
    Reference(name:, ..) -> {
      case context.resolve_schema_ref(ref, ctx) {
        Ok(StringSchema(enum_values:, ..)) if enum_values != [] ->
          "encode.encode_"
          <> naming.to_snake_case(name)
          <> "_to_string("
          <> value
          <> ")"
        // Composite `$ref`s cannot fall through to `to_string_expr`'s
        // catch-all — the value is typed as the per-schema record /
        // union, not String. The generated encoder's String form
        // serialises through `json.to_string()`, which is the
        // form-style fallback the validator already warns about.
        Ok(ObjectSchema(..))
        | Ok(OneOfSchema(..))
        | Ok(AnyOfSchema(..))
        | Ok(AllOfSchema(..)) ->
          "encode.encode_" <> naming.to_snake_case(name) <> "(" <> value <> ")"
        Ok(resolved) -> {
          // A `$ref` to a `nullable: true` primitive renders its type
          // as `Option(<T>)`, but the to_string callsite (query-param
          // tuples, path-segment substitution) needs a `String`.
          // `option.unwrap(<value>, "")` collapses `None` (and
          // `Some(None)`) to the empty string, which most OpenAPI
          // servers treat the same as the param being absent.
          let inner = to_string_expr(resolved, value)
          case schema.is_nullable(resolved) {
            True -> "option.unwrap(" <> inner <> ", \"\")"
            False -> inner
          }
        }
        // nolint: thrown_away_error -- unresolved refs fall back to the raw accessor; the resolver reports the ref error separately
        Error(_) -> value
      }
    }
  }
}

/// Map a schema ref to its decoder expression (for inline primitives)
/// or decoder function name (for references).
///
/// Inline composite schemas (object, allOf, oneOf, anyOf) normally
/// pass through the hoist pass (oaspec/internal/openapi/hoist) and
/// arrive here as a `$ref`. If hoist misses a shape — or a new spec
/// shape lands that hoist does not yet recognise — this dispatch
/// previously panicked. As of PR #543 it falls back to a permissive
/// `dyn_decode.dynamic` decoder so the generator finishes and the
/// failure surfaces at runtime (with the field path) instead of
/// crashing the build. The hoist contract is still enforced by the
/// validate pass and the unit tests.
pub fn decoder_expr(ref: SchemaRef) -> String {
  case ref {
    Inline(StringSchema(..)) -> "decode.string"
    Inline(IntegerSchema(..)) -> "decode.int"
    Inline(NumberSchema(..)) -> "decode.float"
    Inline(BooleanSchema(..)) -> "decode.bool"
    Reference(name:, ..) -> naming.to_snake_case(name) <> "_decoder()"
    Inline(_) -> "dyn_decode.dynamic"
  }
}

/// Map a schema ref to its JSON encoder expression. Inline composites
/// fall back to `json.null()` (see `decoder_expr` for the panic-removal
/// rationale).
pub fn json_encoder_expr(ref: SchemaRef, value: String) -> String {
  case ref {
    Inline(StringSchema(..)) -> "json.string(" <> value <> ")"
    Inline(IntegerSchema(..)) -> "json.int(" <> value <> ")"
    Inline(NumberSchema(..)) -> "json.float(" <> value <> ")"
    Inline(BooleanSchema(..)) -> "json.bool(" <> value <> ")"
    Reference(name:, ..) ->
      "encode_" <> naming.to_snake_case(name) <> "_json(" <> value <> ")"
    Inline(_) -> "json.null()"
  }
}

/// Map a schema ref to its JSON encoder function reference (for
/// higher-order use). Inline composites fall back to a `fn(_) {
/// json.null() }` lambda — the codegen still emits valid Gleam, and
/// hoist gaps surface as null payloads at runtime instead of build-
/// time panics.
pub fn json_encoder_fn(ref: SchemaRef) -> String {
  case ref {
    Inline(StringSchema(..)) -> "json.string"
    Inline(IntegerSchema(..)) -> "json.int"
    Inline(NumberSchema(..)) -> "json.float"
    Inline(BooleanSchema(..)) -> "json.bool"
    Reference(name:, ..) -> "encode_" <> naming.to_snake_case(name) <> "_json"
    Inline(_) -> "fn(_) { json.null() }"
  }
}

/// Map a schema ref to its to_string function reference (for list.map etc).
/// Inline composites fall back to a `fn(_) { \"\" }` lambda — empty
/// string is the same value other unparseable param branches use.
pub fn to_string_fn(ref: SchemaRef, ctx: Context) -> String {
  case ref {
    Inline(StringSchema(..)) -> "fn(x) { x }"
    Inline(IntegerSchema(..)) -> "int.to_string"
    Inline(NumberSchema(..)) -> "float.to_string"
    Inline(BooleanSchema(..)) -> "bool.to_string"
    Reference(name:, ..) -> {
      case context.resolve_schema_ref(ref, ctx) {
        Ok(StringSchema(enum_values:, ..)) if enum_values != [] ->
          "encode.encode_" <> naming.to_snake_case(name) <> "_to_string"
        Ok(resolved) -> to_string_fn(Inline(resolved), ctx)
        // nolint: thrown_away_error -- unresolved refs fall back to identity; the resolver reports the ref error separately
        Error(_) -> "fn(x) { x }"
      }
    }
    Inline(_) -> "fn(_) { \"\" }"
  }
}

/// Resolve a schema ref and return the base type (for parameter type resolution).
pub fn resolve_param_type(schema_ref: Option(SchemaRef), ctx: Context) -> String {
  case schema_ref {
    Some(Inline(ArraySchema(items:, ..))) ->
      "List(" <> schema_ref_qualified_type_recursive(items) <> ")"
    Some(Inline(schema)) -> schema_base_type(schema)
    Some(Reference(name:, ..) as ref) -> {
      case context.resolve_schema_ref(ref, ctx) {
        Ok(ArraySchema(items:, ..)) ->
          "List(" <> schema_ref_qualified_type_recursive(items) <> ")"
        _ -> "types." <> naming.schema_to_type_name(name)
      }
    }
    None -> "String"
  }
}
