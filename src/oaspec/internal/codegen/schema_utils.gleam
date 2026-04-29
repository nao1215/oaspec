/// Shared schema analysis utilities used by types.gleam and ir_build.gleam.
/// Extracted to break the import-cycle that previously forced ir_build.gleam
/// to mirror these helpers from types.gleam.
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/openapi/resolver
import oaspec/internal/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, Forbidden, Inline,
  ObjectSchema, Reference, StringSchema, Typed, Untyped,
}

/// Check if a schema has typed or untyped additionalProperties that would need Dict.
pub fn schema_has_additional_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  case schema_ref {
    Inline(ObjectSchema(additional_properties: Typed(_), ..)) -> True
    Inline(ObjectSchema(additional_properties: Untyped, ..)) -> True
    Inline(AllOfSchema(schemas:, ..)) ->
      list.any(schemas, fn(s) { schema_has_additional_properties(s, ctx) })
    Reference(..) ->
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
        Ok(schema_obj) ->
          schema_has_additional_properties(Inline(schema_obj), ctx)
        // nolint: thrown_away_error -- unresolved refs are treated as not having additionalProperties; the resolver reports the ref error separately
        Error(_) -> False
      }
    _ -> False
  }
}

/// Check if a schema has `additionalProperties: false` (needs Dict for the
/// closed-schema unknown-key check at decode time). Recurses through allOf
/// children and resolves `$ref` so nested closed schemas are surfaced too.
pub fn schema_has_forbidden_additional_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  case schema_ref {
    Inline(ObjectSchema(additional_properties: Forbidden, ..)) -> True
    Inline(AllOfSchema(schemas:, ..)) ->
      list.any(schemas, fn(s) {
        schema_has_forbidden_additional_properties(s, ctx)
      })
    Reference(..) ->
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
        Ok(schema_obj) ->
          schema_has_forbidden_additional_properties(Inline(schema_obj), ctx)
        // nolint: thrown_away_error -- unresolved refs are treated as not having forbidden additionalProperties; the resolver reports the ref error separately
        Error(_) -> False
      }
    _ -> False
  }
}

/// Check if a schema has untyped additionalProperties (needs Dynamic import).
pub fn schema_has_untyped_additional_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  case schema_ref {
    Inline(ObjectSchema(additional_properties: Untyped, ..)) -> True
    Inline(AllOfSchema(schemas:, ..)) ->
      list.any(schemas, fn(s) {
        schema_has_untyped_additional_properties(s, ctx)
      })
    Reference(..) ->
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
        Ok(schema_obj) ->
          schema_has_untyped_additional_properties(Inline(schema_obj), ctx)
        // nolint: thrown_away_error -- unresolved refs are treated as not having untyped additionalProperties; the resolver reports the ref error separately
        Error(_) -> False
      }
    _ -> False
  }
}

/// Check if a schema has any optional or nullable fields that would need Option.
pub fn schema_has_optional_fields(schema_ref: SchemaRef, ctx: Context) -> Bool {
  case schema_ref {
    Inline(ObjectSchema(properties:, required:, ..)) -> {
      dict.to_list(properties)
      |> list.any(fn(entry) {
        let #(prop_name, prop_ref) = entry
        !list.contains(required, prop_name)
        || schema_ref_is_nullable(prop_ref, ctx)
      })
    }
    Inline(AllOfSchema(schemas:, ..)) ->
      list.any(schemas, fn(s) { schema_has_optional_fields(s, ctx) })
    Reference(..) ->
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
        Ok(schema_obj) -> schema_has_optional_fields(Inline(schema_obj), ctx)
        // nolint: thrown_away_error -- unresolved refs are treated as not having optional fields; the resolver reports the ref error separately
        Error(_) -> False
      }
    _ -> False
  }
}

/// Issue #309: detect a property that is fully determined by the
/// schema — an inline string-enum with exactly one allowed value that
/// the parent schema lists as required. Such a property is a constant
/// marker on the wire (e.g. a `kind: type: string, enum: [text]`
/// discriminator on a oneOf variant): the only legal value is known
/// at codegen time, so the generated record drops the field, the
/// encoder emits the constant, and the decoder validates it.
///
/// Returns `Some(value)` for an elidable constant property; `None`
/// otherwise (including `$ref`s, multi-value enums, optional
/// properties, and non-string schemas — those keep their current
/// record-field shape).
pub fn constant_property_value(
  prop_ref: SchemaRef,
  prop_name: String,
  required: List(String),
) -> Option(String) {
  case list.contains(required, prop_name), prop_ref {
    True, Inline(StringSchema(enum_values: [single_value], ..)) ->
      Some(single_value)
    _, _ -> None
  }
}

/// Check if a SchemaRef is nullable, resolving $ref if needed.
pub fn schema_ref_is_nullable(ref: SchemaRef, ctx: Context) -> Bool {
  case ref {
    Inline(inline_schema) -> schema.is_nullable(inline_schema)
    Reference(..) ->
      case resolver.resolve_schema_ref(ref, context.spec(ctx)) {
        Ok(resolved) -> schema.is_nullable(resolved)
        // nolint: thrown_away_error -- unresolved refs are treated as non-nullable; the resolver reports the ref error separately
        Error(_) -> False
      }
  }
}

/// Check if a SchemaRef has readOnly metadata, resolving $ref if needed.
pub fn schema_ref_is_read_only(ref: SchemaRef, ctx: Context) -> Bool {
  case ref {
    Inline(inline_schema) -> schema.get_metadata(inline_schema).read_only
    Reference(..) ->
      case resolver.resolve_schema_ref(ref, context.spec(ctx)) {
        Ok(resolved) -> schema.get_metadata(resolved).read_only
        // nolint: thrown_away_error -- unresolved refs are treated as not read-only; the resolver reports the ref error separately
        Error(_) -> False
      }
  }
}

/// Check if a SchemaRef has writeOnly metadata, resolving $ref if needed.
pub fn schema_ref_is_write_only(ref: SchemaRef, ctx: Context) -> Bool {
  case ref {
    Inline(inline_schema) -> schema.get_metadata(inline_schema).write_only
    Reference(..) ->
      case resolver.resolve_schema_ref(ref, context.spec(ctx)) {
        Ok(resolved) -> schema.get_metadata(resolved).write_only
        // nolint: thrown_away_error -- unresolved refs are treated as not write-only; the resolver reports the ref error separately
        Error(_) -> False
      }
  }
}

/// Filter readOnly properties from an ObjectSchema for request body context.
/// Returns a new schema with readOnly properties removed.
pub fn filter_read_only_properties(
  schema_obj: SchemaObject,
  ctx: Context,
) -> SchemaObject {
  case schema_obj {
    ObjectSchema(
      metadata:,
      properties:,
      required:,
      additional_properties:,
      min_properties:,
      max_properties:,
    ) -> {
      let filtered_props =
        dict.filter(properties, fn(_name, prop_ref) {
          !schema_ref_is_read_only(prop_ref, ctx)
        })
      let filtered_required =
        list.filter(required, fn(name) {
          case dict.get(filtered_props, name) {
            Ok(_) -> True
            // nolint: thrown_away_error -- dict miss means the required field was filtered out; no error value to preserve
            Error(_) -> False
          }
        })
      ObjectSchema(
        metadata:,
        properties: filtered_props,
        required: filtered_required,
        additional_properties:,
        min_properties:,
        max_properties:,
      )
    }
    _ -> schema_obj
  }
}

/// Filter writeOnly properties from an ObjectSchema for response body context.
/// Returns a new schema with writeOnly properties removed.
pub fn filter_write_only_properties(
  schema_obj: SchemaObject,
  ctx: Context,
) -> SchemaObject {
  case schema_obj {
    ObjectSchema(
      metadata:,
      properties:,
      required:,
      additional_properties:,
      min_properties:,
      max_properties:,
    ) -> {
      let filtered_props =
        dict.filter(properties, fn(_name, prop_ref) {
          !schema_ref_is_write_only(prop_ref, ctx)
        })
      let filtered_required =
        list.filter(required, fn(name) {
          case dict.get(filtered_props, name) {
            Ok(_) -> True
            // nolint: thrown_away_error -- dict miss means the required field was filtered out; no error value to preserve
            Error(_) -> False
          }
        })
      ObjectSchema(
        metadata:,
        properties: filtered_props,
        required: filtered_required,
        additional_properties:,
        min_properties:,
        max_properties:,
      )
    }
    _ -> schema_obj
  }
}
