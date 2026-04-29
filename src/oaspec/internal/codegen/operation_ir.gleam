import gleam/option.{type Option, None, Some}
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/openapi/resolver
import oaspec/internal/openapi/schema
import oaspec/internal/openapi/spec

/// Compute the effective explode value for a parameter.
/// OpenAPI 3.x default: true for form/deepObject style, false otherwise.
/// When style is None (on a query parameter), the default is form → true.
pub fn effective_explode(param: spec.Parameter(spec.Resolved)) -> Bool {
  case param.explode {
    Some(v) -> v
    None ->
      case param.style {
        Some(spec.FormStyle) | Some(spec.DeepObjectStyle) | None -> True
        _ -> False
      }
  }
}

/// Return the delimiter character for a parameter style.
/// pipeDelimited → "|", spaceDelimited → " ", all others → ","
pub fn delimiter_for_style(style: Option(spec.ParameterStyle)) -> String {
  case style {
    Some(spec.PipeDelimitedStyle) -> "|"
    Some(spec.SpaceDelimitedStyle) -> " "
    _ -> ","
  }
}

/// Check if a parameter uses deepObject serialization.
/// True when: in=query, style=deepObject, and schema is an ObjectSchema.
pub fn is_deep_object_param(
  param: spec.Parameter(spec.Resolved),
  ctx: Context,
) -> Bool {
  case param.in_, param.style, spec.parameter_schema(param) {
    spec.InQuery,
      Some(spec.DeepObjectStyle),
      Some(schema.Reference(..) as schema_ref)
    ->
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
        Ok(schema.ObjectSchema(..)) -> True
        _ -> False
      }
    spec.InQuery,
      Some(spec.DeepObjectStyle),
      Some(schema.Inline(schema.ObjectSchema(..)))
    -> True
    _, _, _ -> False
  }
}
