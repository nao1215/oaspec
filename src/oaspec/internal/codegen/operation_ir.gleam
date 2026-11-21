import gleam/option.{type Option, None, Some}
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/openapi/spec
import oaspec/openapi

/// Compute the effective explode value for a parameter.
/// OpenAPI 3.x default: true for form/deepObject style, false otherwise.
/// When style is None (on a query parameter), the default is form → true.
pub fn effective_explode(param: openapi.Parameter(openapi.Resolved)) -> Bool {
  case param.explode {
    Some(v) -> v
    None ->
      case param.style {
        Some(openapi.FormStyle) | Some(openapi.DeepObjectStyle) | None -> True
        _ -> False
      }
  }
}

/// Return the delimiter character for a parameter style.
/// pipeDelimited → "|", spaceDelimited → " ", all others → ","
pub fn delimiter_for_style(style: Option(openapi.ParameterStyle)) -> String {
  case style {
    Some(openapi.PipeDelimitedStyle) -> "|"
    Some(openapi.SpaceDelimitedStyle) -> " "
    _ -> ","
  }
}

/// Check if a parameter uses deepObject serialization.
/// True when: in=query, style=deepObject, and schema is an ObjectSchema.
pub fn is_deep_object_param(
  param: openapi.Parameter(openapi.Resolved),
  ctx: Context,
) -> Bool {
  case param.in_, param.style, spec.parameter_schema(param) {
    openapi.InQuery,
      Some(openapi.DeepObjectStyle),
      Some(openapi.Reference(..) as schema_ref)
    ->
      case context.resolve_schema_ref(schema_ref, ctx) {
        Ok(openapi.ObjectSchema(..)) -> True
        _ -> False
      }
    openapi.InQuery,
      Some(openapi.DeepObjectStyle),
      Some(openapi.Inline(openapi.ObjectSchema(..)))
    -> True
    _, _, _ -> False
  }
}
