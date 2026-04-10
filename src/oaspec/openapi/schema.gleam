import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option}
import gleam/string
import oaspec/openapi/value.{type JsonValue}

/// Shared metadata for all schema types.
/// Extracted from variants to avoid duplication and ensure composition
/// schemas (allOf/oneOf/anyOf) don't lose these fields.
pub type SchemaMetadata {
  SchemaMetadata(
    description: Option(String),
    nullable: Bool,
    deprecated: Bool,
    title: Option(String),
    read_only: Bool,
    write_only: Bool,
    default: Option(JsonValue),
    example: Option(JsonValue),
    const_value: Option(JsonValue),
    raw_type: Option(List(String)),
    unsupported_keywords: List(String),
  )
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
  )
}

/// How additionalProperties is modeled in the AST.
pub type AdditionalProperties {
  /// additionalProperties: false (or absent with no schema)
  Forbidden
  /// additionalProperties: true (accept any JSON value)
  Untyped
  /// additionalProperties: { schema }
  Typed(SchemaRef)
}

/// Represents a JSON Schema object within OpenAPI 3.x.
/// This is the core building block for all type generation.
/// All variants carry shared `metadata` for description, nullable, deprecated.
pub type SchemaObject {
  StringSchema(
    metadata: SchemaMetadata,
    format: Option(String),
    enum_values: List(String),
    min_length: Option(Int),
    max_length: Option(Int),
    pattern: Option(String),
  )
  IntegerSchema(
    metadata: SchemaMetadata,
    format: Option(String),
    minimum: Option(Int),
    maximum: Option(Int),
    exclusive_minimum: Option(Int),
    exclusive_maximum: Option(Int),
    multiple_of: Option(Int),
  )
  NumberSchema(
    metadata: SchemaMetadata,
    format: Option(String),
    minimum: Option(Float),
    maximum: Option(Float),
    exclusive_minimum: Option(Float),
    exclusive_maximum: Option(Float),
    multiple_of: Option(Float),
  )
  BooleanSchema(metadata: SchemaMetadata)
  ArraySchema(
    metadata: SchemaMetadata,
    items: SchemaRef,
    min_items: Option(Int),
    max_items: Option(Int),
    unique_items: Bool,
  )
  ObjectSchema(
    metadata: SchemaMetadata,
    properties: Dict(String, SchemaRef),
    required: List(String),
    additional_properties: AdditionalProperties,
    min_properties: Option(Int),
    max_properties: Option(Int),
  )
  AllOfSchema(metadata: SchemaMetadata, schemas: List(SchemaRef))
  OneOfSchema(
    metadata: SchemaMetadata,
    schemas: List(SchemaRef),
    discriminator: Option(Discriminator),
  )
  AnyOfSchema(
    metadata: SchemaMetadata,
    schemas: List(SchemaRef),
    discriminator: Option(Discriminator),
  )
}

/// A reference to a schema, either inline or via $ref.
/// Reference carries both the full $ref string and the pre-extracted name
/// (last segment) to eliminate repeated string splitting in codegen.
pub type SchemaRef {
  Inline(SchemaObject)
  Reference(ref: String, name: String)
}

/// Create a Reference from a $ref string, auto-extracting the name.
pub fn make_reference(ref: String) -> SchemaRef {
  let name = ref_to_schema_name(ref)
  Reference(ref:, name:)
}

/// Extract the schema name from a $ref string (last path segment).
/// Example: "#/components/schemas/User" -> "User"
fn ref_to_schema_name(ref: String) -> String {
  case string.split(ref, "/") {
    [] -> "Unknown"
    segments -> {
      case list.last(segments) {
        Ok(name) -> name
        Error(_) -> "Unknown"
      }
    }
  }
}

/// OpenAPI discriminator for oneOf/anyOf.
pub type Discriminator {
  Discriminator(property_name: String, mapping: Dict(String, String))
}

/// Get the description from any schema object.
pub fn get_description(schema: SchemaObject) -> Option(String) {
  get_metadata(schema).description
}

/// Check if a schema is nullable.
pub fn is_nullable(schema: SchemaObject) -> Bool {
  get_metadata(schema).nullable
}

/// Check if a schema is deprecated.
pub fn is_deprecated(schema: SchemaObject) -> Bool {
  get_metadata(schema).deprecated
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
