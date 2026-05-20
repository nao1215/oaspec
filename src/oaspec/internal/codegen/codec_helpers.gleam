//// Helpers shared between `encoders.gleam` and `decoders.gleam`.
////
//// Issue #402: prior to extraction these four helpers were duplicated
//// in both modules, with the doc comment on `encoders.gleam` flagging
//// the duplication as a follow-up to #212. The bodies were
//// byte-identical (modulo function names for the bare-Option pair), so
//// keeping them in lock-step manually was a maintenance trap. This
//// module owns the canonical implementations now.

import gleam/string
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/codegen/schema_dispatch
import oaspec/openapi/schema.{
  type SchemaRef, ArraySchema, BooleanSchema, Inline, IntegerSchema,
  NumberSchema, StringSchema,
}

/// Escape a spec-derived string so it can be safely interpolated
/// inside a generated Gleam string literal (e.g. `json.string("...")`).
/// Constant property values from issue #309 land here — practical
/// values are simple identifiers (`text`, `media`, …) but a spec
/// could in principle declare an enum value containing `"` or `\`.
pub fn escape_for_string_literal(value: String) -> String {
  value
  |> string.replace(each: "\\", with: "\\\\")
  |> string.replace(each: "\"", with: "\\\"")
}

/// Get element at index from a list, or return a default.
pub fn list_at_or(lst: List(String), idx: Int, default: String) -> String {
  case lst, idx {
    [], _ -> default
    [head, ..], 0 -> head
    [_, ..rest], n -> list_at_or(rest, n - 1, default)
  }
}

/// Convert a SchemaRef to a qualified Gleam type string (with `types.`
/// prefix for component refs). `_ctx` is currently unused but kept on
/// the signature so future ref-resolving variants don't change the
/// caller surface.
pub fn qualified_schema_ref_type(ref: SchemaRef, _ctx: Context) -> String {
  case ref {
    Inline(schema) -> schema_dispatch.schema_type(schema)
    _ -> schema_dispatch.schema_ref_qualified_type(ref)
  }
}

/// Issue #387: True when the top-level codec for this schema would
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
