/// Shared schema analysis utilities used by types.gleam, ir_build.gleam
/// and the other codegen modules.
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import oaspec/internal/codegen/context.{type Context}
import oaspec/openapi.{
  type SchemaObject, type SchemaRef, AllOfSchema, ArraySchema, BooleanSchema,
  Forbidden, Inline, IntegerSchema, NumberSchema, ObjectSchema, OneOfSchema,
  Reference, StringSchema, Typed, Untyped,
}

/// Whether `leaf` holds for the schema or for a schema it is built from:
/// the `children` of an inline schema (allOf members, and for some
/// checks oneOf members) and the target of a `$ref`. Each `$ref` is
/// followed at most once, so a schema whose allOf includes itself
/// (`RecursiveObject: allOf: [$ref: RecursiveObject, ...]`) terminates;
/// following it again could only find what the first visit found.
fn reaches(
  schema_ref: SchemaRef,
  ctx: Context,
  visited: set.Set(String),
  leaf: fn(SchemaObject) -> Bool,
  children: fn(SchemaObject) -> List(SchemaRef),
) -> Bool {
  case schema_ref {
    Inline(schema_obj) ->
      leaf(schema_obj)
      || list.any(children(schema_obj), fn(child) {
        reaches(child, ctx, visited, leaf, children)
      })
    Reference(ref:, ..) ->
      case set.contains(visited, ref) {
        True -> False
        False ->
          case context.resolve_schema_ref(schema_ref, ctx) {
            Ok(schema_obj) ->
              reaches(
                Inline(schema_obj),
                ctx,
                set.insert(visited, ref),
                leaf,
                children,
              )
            // nolint: thrown_away_error -- an unresolved ref contributes nothing here; the resolver reports the ref error separately
            Error(_) -> False
          }
      }
  }
}

fn allof_members(schema_obj: SchemaObject) -> List(SchemaRef) {
  case schema_obj {
    AllOfSchema(schemas:, ..) -> schemas
    _ -> []
  }
}

/// Check if a schema has typed or untyped additionalProperties that would need Dict.
pub fn schema_has_additional_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  reaches(
    schema_ref,
    ctx,
    set.new(),
    fn(schema_obj) {
      case schema_obj {
        ObjectSchema(additional_properties: Typed(_), ..) -> True
        ObjectSchema(additional_properties: Untyped, ..) -> True
        _ -> False
      }
    },
    allof_members,
  )
}

/// Check if a schema has `additionalProperties: false` (needs Dict for the
/// closed-schema unknown-key check at decode time). Recurses through allOf
/// children and resolves `$ref` so nested closed schemas are surfaced too.
pub fn schema_has_forbidden_additional_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  reaches(
    schema_ref,
    ctx,
    set.new(),
    fn(schema_obj) {
      case schema_obj {
        ObjectSchema(additional_properties: Forbidden, ..) -> True
        _ -> False
      }
    },
    allof_members,
  )
}

/// Check if a schema is — or transitively contains — a `oneOf` with at least
/// one $ref variant and no discriminator. The strict-oneOf decoder body
/// generated for that shape uses `list.filter_map` and `result.map`, so the
/// generator must add `gleam/list` and `gleam/result` to the imports of
/// `decode.gleam` when this returns True.
pub fn schema_has_non_discriminator_oneof(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  reaches(
    schema_ref,
    ctx,
    set.new(),
    fn(schema_obj) {
      case schema_obj {
        OneOfSchema(schemas:, discriminator: option.None, ..) ->
          list.any(schemas, fn(s) {
            case s {
              Reference(..) -> True
              _ -> False
            }
          })
        _ -> False
      }
    },
    fn(schema_obj) {
      case schema_obj {
        // A oneOf without a discriminator is decided by its own variants.
        OneOfSchema(discriminator: option.None, ..) -> []
        OneOfSchema(schemas:, ..) -> schemas
        AllOfSchema(schemas:, ..) -> schemas
        _ -> []
      }
    },
  )
}

/// Check if a schema has untyped additionalProperties (needs Dynamic import).
pub fn schema_has_untyped_additional_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  reaches(
    schema_ref,
    ctx,
    set.new(),
    fn(schema_obj) {
      case schema_obj {
        ObjectSchema(additional_properties: Untyped, ..) -> True
        _ -> False
      }
    },
    allof_members,
  )
}

/// Check if a schema has any optional or nullable fields that would need Option.
pub fn schema_has_optional_fields(schema_ref: SchemaRef, ctx: Context) -> Bool {
  reaches(
    schema_ref,
    ctx,
    set.new(),
    fn(schema_obj) {
      case schema_obj {
        ObjectSchema(properties:, required:, ..) ->
          dict.to_list(properties)
          |> list.any(fn(entry) {
            let #(prop_name, prop_ref) = entry
            !list.contains(required, prop_name)
            || schema_ref_is_nullable(prop_ref, ctx)
          })
        _ -> False
      }
    },
    allof_members,
  )
}

/// Detect a property that is fully determined by the
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
    // A `nullable: true` enum admits two wire values (the single
    // declared variant AND `null`), so it is not a true constant.
    // Treating it as one would elide the field from the record but
    // leave the encoder reading `value.<field>` from a type that no
    // longer carries it.
    True, Inline(StringSchema(metadata:, enum_values: [single_value], ..)) ->
      case metadata.nullable {
        True -> None
        False -> Some(single_value)
      }
    _, _ -> None
  }
}

/// Check if a SchemaRef is nullable, resolving $ref if needed.
pub fn schema_ref_is_nullable(ref: SchemaRef, ctx: Context) -> Bool {
  case context.schema_metadata(ref, ctx) {
    Some(metadata) -> metadata.nullable
    None -> False
  }
}

/// Check if a SchemaRef has readOnly metadata, resolving $ref if needed.
pub fn schema_ref_is_read_only(ref: SchemaRef, ctx: Context) -> Bool {
  case context.schema_metadata(ref, ctx) {
    Some(metadata) -> metadata.read_only
    None -> False
  }
}

/// Check if a SchemaRef has writeOnly metadata, resolving $ref if needed.
pub fn schema_ref_is_write_only(ref: SchemaRef, ctx: Context) -> Bool {
  case context.schema_metadata(ref, ctx) {
    Some(metadata) -> metadata.write_only
    None -> False
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

/// True when `schema_ref` is, or is a `$ref` to, a string, integer, number
/// or boolean schema.
pub fn resolves_to_primitive(schema_ref: SchemaRef, ctx: Context) -> Bool {
  case context.resolve_schema_ref(schema_ref, ctx) {
    Ok(StringSchema(..))
    | Ok(IntegerSchema(..))
    | Ok(NumberSchema(..))
    | Ok(BooleanSchema(..)) -> True
    _ -> False
  }
}

/// The items schema when `schema_ref` is, or is a `$ref` to, an array.
pub fn array_items(schema_ref: SchemaRef, ctx: Context) -> Option(SchemaRef) {
  case context.resolve_schema_ref(schema_ref, ctx) {
    Ok(ArraySchema(items:, ..)) -> Some(items)
    _ -> None
  }
}
