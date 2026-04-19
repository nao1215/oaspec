import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, Inline, Reference,
}
import oaspec/openapi/spec.{type OpenApiSpec, type Resolved}

/// Errors during reference resolution.
pub type ResolveError {
  UnresolvedRef(ref: String)
  CircularRef(ref: String)
}

/// Resolve a $ref string to its schema name.
/// Example: "#/components/schemas/User" -> "User"
pub fn ref_to_name(ref: String) -> String {
  ref
  |> string.split("/")
  |> list.last
  |> result.unwrap("Unknown")
}

/// Resolve a SchemaRef to a SchemaObject, looking up $ref in components.
/// Tracks seen refs to detect circular references.
pub fn resolve_schema_ref(
  schema_ref: SchemaRef,
  spec: OpenApiSpec(Resolved),
) -> Result(SchemaObject, ResolveError) {
  resolve_schema_ref_with_seen(schema_ref, spec, set.new())
}

/// Internal resolver that tracks visited refs for cycle detection.
fn resolve_schema_ref_with_seen(
  schema_ref: SchemaRef,
  spec: OpenApiSpec(Resolved),
  seen: Set(String),
) -> Result(SchemaObject, ResolveError) {
  case schema_ref {
    Inline(schema) -> Ok(schema)
    Reference(ref:, name:) -> {
      case set.contains(seen, ref) {
        True -> Error(CircularRef(ref:))
        False -> {
          let new_seen = set.insert(seen, ref)
          case spec.components {
            Some(components) -> {
              case dict.get(components.schemas, name) {
                Ok(Inline(schema)) -> Ok(schema)
                Ok(Reference(ref: inner_ref, name: inner_name)) ->
                  resolve_schema_ref_with_seen(
                    Reference(ref: inner_ref, name: inner_name),
                    spec,
                    new_seen,
                  )
                Error(_) -> Error(UnresolvedRef(ref:))
              }
            }
            None -> Error(UnresolvedRef(ref:))
          }
        }
      }
    }
  }
}
