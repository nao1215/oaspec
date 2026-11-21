//// Helpers over the `oaspec/openapi` schema types.

import gleam/list
import gleam/option
import gleam/result
import gleam/string
import oaspec/openapi.{
  type OriginKind, type SchemaMetadata, type SchemaObject, type SchemaRef,
  AllOfSchema, AnyOfSchema, ArraySchema, BooleanSchema, IntegerSchema,
  NumberSchema, ObjectSchema, OneOfSchema, Reference, SchemaMetadata,
  StringSchema, UserAuthored,
}

/// Create default metadata with no description, not nullable, not deprecated.
pub fn default_metadata() -> SchemaMetadata {
  SchemaMetadata(
    description: option.None,
    nullable: False,
    deprecated: False,
    title: option.None,
    read_only: False,
    write_only: False,
    default: option.None,
    example: option.None,
    const_value: option.None,
    raw_type: option.None,
    unsupported_keywords: [],
    internal: False,
    provenance: UserAuthored,
  )
}

/// Create a Reference from a $ref string, auto-extracting the name.
pub fn make_reference(ref: String) -> SchemaRef {
  let name = ref_to_schema_name(ref)
  Reference(ref:, name:)
}

/// Extract the schema name from a $ref string (last path segment).
/// Example: "#/components/schemas/User" -> "User"
fn ref_to_schema_name(ref: String) -> String {
  string.split(ref, "/")
  |> list.last
  |> result.unwrap(ref)
}

/// Check if a schema is nullable.
pub fn is_nullable(schema: SchemaObject) -> Bool {
  get_metadata(schema).nullable
}

/// Extract the shared metadata from any schema variant.
pub fn get_metadata(schema: SchemaObject) -> SchemaMetadata {
  case schema {
    StringSchema(metadata:, ..) -> metadata
    IntegerSchema(metadata:, ..) -> metadata
    NumberSchema(metadata:, ..) -> metadata
    BooleanSchema(metadata:) -> metadata
    ArraySchema(metadata:, ..) -> metadata
    ObjectSchema(metadata:, ..) -> metadata
    AllOfSchema(metadata:, ..) -> metadata
    OneOfSchema(metadata:, ..) -> metadata
    AnyOfSchema(metadata:, ..) -> metadata
  }
}

/// Mark a schema as internal (not part of the public generated API).
pub fn set_internal(schema: SchemaObject) -> SchemaObject {
  let meta = get_metadata(schema)
  let meta = SchemaMetadata(..meta, internal: True)
  set_metadata(schema, meta)
}

/// Stamp the origin of a hoisted schema onto its metadata so downstream
/// consumers (diagnostics, tooling) can distinguish user-authored schemas
/// from synthetic ones created during the hoist pass.
pub fn set_provenance(
  schema: SchemaObject,
  origin: OriginKind,
) -> SchemaObject {
  let meta = get_metadata(schema)
  let meta = SchemaMetadata(..meta, provenance: origin)
  set_metadata(schema, meta)
}

/// Read the provenance of a schema. Unhoisted schemas return `UserAuthored`.
pub fn get_provenance(schema: SchemaObject) -> OriginKind {
  get_metadata(schema).provenance
}

/// Replace the metadata on a schema object.
pub fn set_metadata(
  schema: SchemaObject,
  meta: SchemaMetadata,
) -> SchemaObject {
  case schema {
    StringSchema(format:, enum_values:, min_length:, max_length:, pattern:, ..) ->
      StringSchema(
        metadata: meta,
        format:,
        enum_values:,
        min_length:,
        max_length:,
        pattern:,
      )
    IntegerSchema(
      format:,
      minimum:,
      maximum:,
      exclusive_minimum:,
      exclusive_maximum:,
      multiple_of:,
      ..,
    ) ->
      IntegerSchema(
        metadata: meta,
        format:,
        minimum:,
        maximum:,
        exclusive_minimum:,
        exclusive_maximum:,
        multiple_of:,
      )
    NumberSchema(
      format:,
      minimum:,
      maximum:,
      exclusive_minimum:,
      exclusive_maximum:,
      multiple_of:,
      ..,
    ) ->
      NumberSchema(
        metadata: meta,
        format:,
        minimum:,
        maximum:,
        exclusive_minimum:,
        exclusive_maximum:,
        multiple_of:,
      )
    BooleanSchema(..) -> BooleanSchema(metadata: meta)
    ArraySchema(items:, min_items:, max_items:, unique_items:, ..) ->
      ArraySchema(metadata: meta, items:, min_items:, max_items:, unique_items:)
    ObjectSchema(
      properties:,
      required:,
      additional_properties:,
      min_properties:,
      max_properties:,
      ..,
    ) ->
      ObjectSchema(
        metadata: meta,
        properties:,
        required:,
        additional_properties:,
        min_properties:,
        max_properties:,
      )
    AllOfSchema(schemas:, ..) -> AllOfSchema(metadata: meta, schemas:)
    OneOfSchema(schemas:, discriminator:, ..) ->
      OneOfSchema(metadata: meta, schemas:, discriminator:)
    AnyOfSchema(schemas:, discriminator:, ..) ->
      AnyOfSchema(metadata: meta, schemas:, discriminator:)
  }
}
