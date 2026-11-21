import gleam/dict
import gleam/int
import gleam/list
import gleam/set
import oaspec/internal/codegen/context.{type Context}
import oaspec/openapi.{
  type AdditionalProperties, type SchemaRef, AllOfSchema, Forbidden, Inline,
  ObjectSchema, Reference, Typed, Unspecified, Untyped,
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
///
/// A member that is a `$ref` to another allOf schema is merged member by
/// member, since `allOf` of an `allOf` is the conjunction of all of
/// them. Each `$ref` is merged at most once: a schema whose allOf lists
/// itself (`RecursiveObject: allOf: [$ref: RecursiveObject, ...]`, an
/// oapi-codegen fixture) adds nothing by referencing itself, and
/// treating it as a synthetic field nested the schema in itself without
/// end, so `generate` never finished.
pub fn merge_allof_schemas(
  schemas: List(SchemaRef),
  ctx: Context,
) -> MergedAllOf {
  merge_members(
    schemas,
    ctx,
    set.new(),
    MergedAllOf(
      properties: dict.new(),
      required: [],
      additional_properties: Unspecified,
    ),
  )
}

fn merge_members(
  schemas: List(SchemaRef),
  ctx: Context,
  visited: set.Set(String),
  initial: MergedAllOf,
) -> MergedAllOf {
  list.index_fold(schemas, initial, fn(acc, s_ref, idx) {
    case s_ref {
      Reference(ref:, ..) ->
        case set.contains(visited, ref) {
          True -> acc
          False ->
            case context.resolve_schema_ref(s_ref, ctx) {
              Ok(AllOfSchema(schemas: members, ..)) ->
                merge_members(members, ctx, set.insert(visited, ref), acc)
              resolved -> merge_one(acc, resolved, idx)
            }
        }
      _ -> merge_one(acc, context.resolve_schema_ref(s_ref, ctx), idx)
    }
  })
}

fn merge_one(
  acc: MergedAllOf,
  resolved: Result(openapi.SchemaObject, e),
  idx: Int,
) -> MergedAllOf {
  case resolved {
    Ok(ObjectSchema(properties:, required:, additional_properties:, ..)) -> {
      let merged_ap = case additional_properties, acc.additional_properties {
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
        properties: dict.insert(acc.properties, field_name, Inline(schema_obj)),
        required: [field_name, ..acc.required],
      )
    }
    _ -> acc
  }
}
