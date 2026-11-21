//// Helpers shared between `encoders.gleam` and `decoders.gleam`.

import gleam/string

import gleam/list
import oaspec/internal/codegen/allof_merge
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/codegen/ir_build
import oaspec/internal/codegen/schema_dispatch
import oaspec/openapi/schema.{
  type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema, BooleanSchema, Inline,
  IntegerSchema, NumberSchema, ObjectSchema, OneOfSchema, StringSchema,
}

/// Escape a spec-derived string so it can be safely interpolated
/// inside a generated Gleam string literal (e.g. `json.string("...")`).
/// Constant property values land here — practical
/// values are simple identifiers (`text`, `media`, …) but a spec
/// could in principle declare an enum value containing `"` or `\`.
pub fn escape_for_string_literal(value: String) -> String {
  value
  |> string.replace(each: "\\", with: "\\\\")
  |> string.replace(each: "\"", with: "\\\"")
}

/// Convert a SchemaRef to a qualified Gleam type string (with `types.`
/// prefix for component refs).
pub fn qualified_schema_ref_type(ref: SchemaRef) -> String {
  case ref {
    Inline(schema) -> schema_dispatch.schema_type(schema)
    _ -> schema_dispatch.schema_ref_qualified_type(ref)
  }
}

/// True when the top-level codec for this schema would
/// emit a bare `Option(...)` wrapper at the surface (decoder declares
/// `decode.Decoder(Option(...))`, encoder takes a bare `Option(...)`
/// parameter). Only primitive / array component schemas with
/// `nullable: true` reach this shape; object / allOf / oneOf / anyOf /
/// enum schemas wrap optionality through `decode.optional` /
/// `json.nullable` inside their bodies and never declare `Option(...)`
/// as the outer type.
pub fn schema_ref_has_bare_option_type(ref: SchemaRef) -> Bool {
  case ref {
    Inline(StringSchema(metadata:, enum_values: [], ..)) -> metadata.nullable
    Inline(IntegerSchema(metadata:, ..)) -> metadata.nullable
    Inline(NumberSchema(metadata:, ..)) -> metadata.nullable
    Inline(BooleanSchema(metadata:)) -> metadata.nullable
    Inline(ArraySchema(metadata:, ..)) -> metadata.nullable
    _ -> False
  }
}

/// True when one of the component schemas is generated as a type in
/// `types.gleam` (an object, a composite or a string enum), so the codec
/// module has to import it.
pub fn needs_types(schemas: List(#(String, SchemaRef))) -> Bool {
  list.any(schemas, fn(entry) {
    case entry.1 {
      Inline(ObjectSchema(..))
      | Inline(AllOfSchema(..))
      | Inline(OneOfSchema(..))
      | Inline(AnyOfSchema(..)) -> True
      Inline(StringSchema(enum_values:, ..)) -> enum_values != []
      _ -> False
    }
  })
}

/// The sorted properties and the required names of an inline object or
/// allOf schema; empty for every other schema.
pub fn object_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> #(List(#(String, SchemaRef)), List(String)) {
  case schema_ref {
    Inline(ObjectSchema(properties:, required:, ..)) -> #(
      ir_build.sorted_entries(properties),
      required,
    )
    Inline(AllOfSchema(schemas:, ..)) -> {
      let merged = allof_merge.merge_allof_schemas(schemas, ctx)
      #(ir_build.sorted_entries(merged.properties), merged.required)
    }
    _ -> #([], [])
  }
}
