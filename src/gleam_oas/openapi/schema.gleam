import gleam/dict.{type Dict}
import gleam/option.{type Option}

/// Represents a JSON Schema object within OpenAPI 3.x.
/// This is the core building block for all type generation.
pub type SchemaObject {
  StringSchema(
    description: Option(String),
    format: Option(String),
    enum_values: List(String),
    min_length: Option(Int),
    max_length: Option(Int),
    pattern: Option(String),
    nullable: Bool,
  )
  IntegerSchema(
    description: Option(String),
    format: Option(String),
    minimum: Option(Int),
    maximum: Option(Int),
    nullable: Bool,
  )
  NumberSchema(
    description: Option(String),
    format: Option(String),
    minimum: Option(Float),
    maximum: Option(Float),
    nullable: Bool,
  )
  BooleanSchema(description: Option(String), nullable: Bool)
  ArraySchema(
    description: Option(String),
    items: SchemaRef,
    min_items: Option(Int),
    max_items: Option(Int),
    nullable: Bool,
  )
  ObjectSchema(
    description: Option(String),
    properties: Dict(String, SchemaRef),
    required: List(String),
    additional_properties: Option(SchemaRef),
    additional_properties_untyped: Bool,
    nullable: Bool,
  )
  AllOfSchema(description: Option(String), schemas: List(SchemaRef))
  OneOfSchema(
    description: Option(String),
    schemas: List(SchemaRef),
    discriminator: Option(Discriminator),
  )
  AnyOfSchema(description: Option(String), schemas: List(SchemaRef))
}

/// A reference to a schema, either inline or via $ref.
pub type SchemaRef {
  Inline(SchemaObject)
  Reference(ref: String)
}

/// OpenAPI discriminator for oneOf/anyOf.
pub type Discriminator {
  Discriminator(property_name: String, mapping: Dict(String, String))
}

/// Get the description from any schema object.
pub fn get_description(schema: SchemaObject) -> Option(String) {
  case schema {
    StringSchema(description:, ..) -> description
    IntegerSchema(description:, ..) -> description
    NumberSchema(description:, ..) -> description
    BooleanSchema(description:, ..) -> description
    ArraySchema(description:, ..) -> description
    ObjectSchema(description:, ..) -> description
    AllOfSchema(description:, ..) -> description
    OneOfSchema(description:, ..) -> description
    AnyOfSchema(description:, ..) -> description
  }
}

/// Check if a schema is nullable.
pub fn is_nullable(schema: SchemaObject) -> Bool {
  case schema {
    StringSchema(nullable:, ..) -> nullable
    IntegerSchema(nullable:, ..) -> nullable
    NumberSchema(nullable:, ..) -> nullable
    BooleanSchema(nullable:, ..) -> nullable
    ArraySchema(nullable:, ..) -> nullable
    ObjectSchema(nullable:, ..) -> nullable
    AllOfSchema(..) -> False
    OneOfSchema(..) -> False
    AnyOfSchema(..) -> False
  }
}
