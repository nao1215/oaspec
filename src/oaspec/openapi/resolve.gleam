import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import oaspec/openapi/parser.{type ParseError, InvalidValue}
import oaspec/openapi/spec.{
  type OpenApiSpec, AliasEntry, Components, ConcreteEntry,
}

/// Resolve all ComponentEntry aliases in the spec.
/// Call after parse and normalize, before capability_check and codegen.
pub fn resolve(spec: OpenApiSpec) -> Result(OpenApiSpec, ParseError) {
  case spec.components {
    None -> Ok(spec)
    Some(components) -> {
      use parameters <- result.try(resolve_component_dict(
        components.parameters,
        "components.parameters",
      ))
      use request_bodies <- result.try(resolve_component_dict(
        components.request_bodies,
        "components.requestBodies",
      ))
      use responses <- result.try(resolve_component_dict(
        components.responses,
        "components.responses",
      ))
      use security_schemes <- result.try(resolve_component_dict(
        components.security_schemes,
        "components.securitySchemes",
      ))
      use path_items <- result.try(resolve_component_dict(
        components.path_items,
        "components.pathItems",
      ))
      Ok(
        spec.OpenApiSpec(
          ..spec,
          components: Some(
            Components(
              ..components,
              parameters: parameters,
              request_bodies: request_bodies,
              responses: responses,
              security_schemes: security_schemes,
              path_items: path_items,
            ),
          ),
        ),
      )
    }
  }
}

/// Resolve all aliases in a component dict.
/// After resolution, all entries are ConcreteEntry.
fn resolve_component_dict(
  entries: Dict(String, spec.ComponentEntry(a)),
  context: String,
) -> Result(Dict(String, spec.ComponentEntry(a)), ParseError) {
  dict.to_list(entries)
  |> list.try_fold(entries, fn(acc, entry) {
    let #(name, value) = entry
    case value {
      ConcreteEntry(_) -> Ok(acc)
      AliasEntry(ref:) -> {
        use resolved <- result.try(resolve_alias(
          entries,
          ref,
          context <> "." <> name,
          set.new(),
        ))
        Ok(dict.insert(acc, name, ConcreteEntry(resolved)))
      }
    }
  })
}

/// Follow a $ref chain to find the concrete value.
fn resolve_alias(
  entries: Dict(String, spec.ComponentEntry(a)),
  ref: String,
  context: String,
  seen: set.Set(String),
) -> Result(a, ParseError) {
  case set.contains(seen, ref) {
    True ->
      Error(InvalidValue(
        path: context,
        detail: "Circular component alias detected: " <> ref,
      ))
    False -> {
      let new_seen = set.insert(seen, ref)
      let ref_name = extract_ref_name(ref)
      case dict.get(entries, ref_name) {
        Ok(ConcreteEntry(value)) -> Ok(value)
        Ok(AliasEntry(ref: next_ref)) ->
          resolve_alias(entries, next_ref, context, new_seen)
        Error(_) ->
          Error(InvalidValue(
            path: context,
            detail: "Unresolved component alias: "
              <> ref
              <> " — target '"
              <> ref_name
              <> "' not found.",
          ))
      }
    }
  }
}

/// Extract the last segment of a $ref path.
fn extract_ref_name(ref: String) -> String {
  ref
  |> string.split("/")
  |> list.last
  |> result.unwrap("unknown")
}
