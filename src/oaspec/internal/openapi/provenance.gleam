//// Summarise the provenance of component schemas after the hoist pass has
//// run. Distinguishing user-authored schemas from synthetic ones created
//// during hoisting lets tooling explain where each generated type came from.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import oaspec/internal/openapi/schema.{
  HoistedAdditionalProperties, HoistedAllOfPart, HoistedAnyOfVariant,
  HoistedArrayItem, HoistedOneOfVariant, HoistedParameter, HoistedProperty,
  HoistedRequestBody, HoistedResponse, Inline, UserAuthored,
}
import oaspec/internal/openapi/spec.{type OpenApiSpec}

/// Breakdown of component schemas by origin after hoisting.
pub type HoistedSummary {
  HoistedSummary(
    user_authored: List(String),
    hoisted_properties: List(#(String, String, String)),
    hoisted_array_items: List(#(String, String)),
    hoisted_oneof_variants: List(#(String, String, Int)),
    hoisted_anyof_variants: List(#(String, String, Int)),
    hoisted_allof_parts: List(#(String, String, Int)),
    hoisted_request_bodies: List(#(String, String)),
    hoisted_responses: List(#(String, String, String)),
    hoisted_parameters: List(#(String, String, String)),
    hoisted_additional_properties: List(#(String, String)),
  )
}

/// Total number of synthetic schemas that were created during hoisting.
pub fn total_hoisted(summary: HoistedSummary) -> Int {
  list.length(summary.hoisted_properties)
  + list.length(summary.hoisted_array_items)
  + list.length(summary.hoisted_oneof_variants)
  + list.length(summary.hoisted_anyof_variants)
  + list.length(summary.hoisted_allof_parts)
  + list.length(summary.hoisted_request_bodies)
  + list.length(summary.hoisted_responses)
  + list.length(summary.hoisted_parameters)
  + list.length(summary.hoisted_additional_properties)
}

/// Walk component schemas and group them by provenance. Reference-only
/// entries (rare after resolve) are ignored because they carry no
/// metadata of their own.
pub fn hoisted_schema_summary(spec: OpenApiSpec(stage)) -> HoistedSummary {
  let empty =
    HoistedSummary(
      user_authored: [],
      hoisted_properties: [],
      hoisted_array_items: [],
      hoisted_oneof_variants: [],
      hoisted_anyof_variants: [],
      hoisted_allof_parts: [],
      hoisted_request_bodies: [],
      hoisted_responses: [],
      hoisted_parameters: [],
      hoisted_additional_properties: [],
    )
  let schemas = case spec.components {
    Some(components) -> components.schemas
    None -> dict.new()
  }
  dict.to_list(schemas)
  |> list.fold(empty, fn(acc, entry) {
    let #(name, schema_ref) = entry
    case schema_ref {
      Inline(obj) ->
        case schema.get_provenance(obj) {
          UserAuthored ->
            HoistedSummary(..acc, user_authored: [name, ..acc.user_authored])
          HoistedProperty(parent:, property:) ->
            HoistedSummary(..acc, hoisted_properties: [
              #(name, parent, property),
              ..acc.hoisted_properties
            ])
          HoistedArrayItem(parent:) ->
            HoistedSummary(..acc, hoisted_array_items: [
              #(name, parent),
              ..acc.hoisted_array_items
            ])
          HoistedOneOfVariant(parent:, index:) ->
            HoistedSummary(..acc, hoisted_oneof_variants: [
              #(name, parent, index),
              ..acc.hoisted_oneof_variants
            ])
          HoistedAnyOfVariant(parent:, index:) ->
            HoistedSummary(..acc, hoisted_anyof_variants: [
              #(name, parent, index),
              ..acc.hoisted_anyof_variants
            ])
          HoistedAllOfPart(parent:, index:) ->
            HoistedSummary(..acc, hoisted_allof_parts: [
              #(name, parent, index),
              ..acc.hoisted_allof_parts
            ])
          HoistedRequestBody(operation_id:) ->
            HoistedSummary(..acc, hoisted_request_bodies: [
              #(name, operation_id),
              ..acc.hoisted_request_bodies
            ])
          HoistedResponse(operation_id:, status:) ->
            HoistedSummary(..acc, hoisted_responses: [
              #(name, operation_id, status),
              ..acc.hoisted_responses
            ])
          HoistedParameter(operation_id:, name: param_name) ->
            HoistedSummary(..acc, hoisted_parameters: [
              #(name, operation_id, param_name),
              ..acc.hoisted_parameters
            ])
          HoistedAdditionalProperties(parent:) ->
            HoistedSummary(..acc, hoisted_additional_properties: [
              #(name, parent),
              ..acc.hoisted_additional_properties
            ])
        }
      _ -> acc
    }
  })
}
