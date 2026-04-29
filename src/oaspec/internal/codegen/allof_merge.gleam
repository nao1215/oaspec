import gleam/dict
import gleam/int
import gleam/list
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/openapi/resolver
import oaspec/internal/openapi/schema.{
  type AdditionalProperties, type SchemaRef, Forbidden, Inline, ObjectSchema,
  Reference, Typed, Unspecified, Untyped,
}

/// Result of merging allOf sub-schemas.
pub type MergedAllOf {
  MergedAllOf(
    properties: dict.Dict(String, SchemaRef),
    required: List(String),
    additional_properties: AdditionalProperties,
  )
}

/// Merge allOf sub-schemas: properties, required, and additionalProperties.
/// Non-object sub-schemas (primitives, arrays) are included as a synthetic
/// "value" property to preserve their constraints.
pub fn merge_allof_schemas(
  schemas: List(SchemaRef),
  ctx: Context,
) -> MergedAllOf {
  list.index_fold(
    schemas,
    MergedAllOf(
      properties: dict.new(),
      required: [],
      additional_properties: Unspecified,
    ),
    fn(acc, s_ref, idx) {
      let resolved = case s_ref {
        Inline(obj) -> Ok(obj)
        Reference(..) -> resolver.resolve_schema_ref(s_ref, context.spec(ctx))
      }
      case resolved {
        Ok(ObjectSchema(properties:, required:, additional_properties:, ..)) -> {
          let merged_ap = case
            additional_properties,
            acc.additional_properties
          {
            // Strongest declaration wins: Typed > Untyped > Forbidden >
            // Unspecified. Forbidden beats Unspecified because explicit
            // false is a real constraint while absent AP just means "no
            // surface in generated types"; merging the two should keep
            // the constraint.
            Typed(x), _ -> Typed(x)
            _, Typed(x) -> Typed(x)
            Untyped, _ -> Untyped
            _, Untyped -> Untyped
            Forbidden, _ -> Forbidden
            _, Forbidden -> Forbidden
            Unspecified, Unspecified -> Unspecified
          }
          MergedAllOf(
            properties: dict.merge(acc.properties, properties),
            required: list.append(acc.required, required),
            additional_properties: merged_ap,
          )
        }
        // Non-object sub-schemas: add as a synthetic "value" field
        Ok(schema_obj) -> {
          let field_name = case idx {
            0 -> "value"
            n -> "value_" <> int.to_string(n)
          }
          MergedAllOf(
            ..acc,
            properties: dict.insert(
              acc.properties,
              field_name,
              Inline(schema_obj),
            ),
            required: [field_name, ..acc.required],
          )
        }
        _ -> acc
      }
    },
  )
}
