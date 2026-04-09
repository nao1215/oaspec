import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  Inline, ObjectSchema, OneOfSchema, Reference,
}
import oaspec/openapi/spec.{type OpenApiSpec}

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
  spec: OpenApiSpec,
) -> Result(SchemaObject, ResolveError) {
  resolve_schema_ref_with_seen(schema_ref, spec, set.new())
}

/// Internal resolver that tracks visited refs for cycle detection.
fn resolve_schema_ref_with_seen(
  schema_ref: SchemaRef,
  spec: OpenApiSpec,
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

/// Resolve all $ref in a schema object's nested schemas (one level).
pub fn resolve_schema_refs_in_schema(
  schema: SchemaObject,
  spec: OpenApiSpec,
) -> SchemaObject {
  case schema {
    ObjectSchema(properties:, additional_properties:, ..) as obj -> {
      let resolved_props =
        dict.map_values(properties, fn(_k, v) { resolve_one_ref(v, spec) })
      let resolved_ap = case additional_properties {
        Some(ap) -> Some(resolve_one_ref(ap, spec))
        None -> None
      }
      ObjectSchema(
        ..obj,
        properties: resolved_props,
        additional_properties: resolved_ap,
      )
    }
    ArraySchema(items:, ..) as arr ->
      ArraySchema(..arr, items: resolve_one_ref(items, spec))
    AllOfSchema(metadata:, schemas:) -> {
      let resolved = list_map_ref(schemas, spec)
      AllOfSchema(metadata:, schemas: resolved)
    }
    OneOfSchema(metadata:, schemas:, discriminator:) -> {
      let resolved = list_map_ref(schemas, spec)
      OneOfSchema(metadata:, schemas: resolved, discriminator:)
    }
    AnyOfSchema(metadata:, schemas:, discriminator:) -> {
      let resolved = list_map_ref(schemas, spec)
      AnyOfSchema(metadata:, schemas: resolved, discriminator:)
    }
    other -> other
  }
}

/// Try to resolve a single ref, keeping it as-is if resolution fails.
fn resolve_one_ref(schema_ref: SchemaRef, spec: OpenApiSpec) -> SchemaRef {
  case schema_ref {
    Reference(..) ->
      case resolve_schema_ref(schema_ref, spec) {
        Ok(schema) -> Inline(schema)
        Error(_) -> schema_ref
      }
    inline -> inline
  }
}

/// Map a list of schema refs, resolving each.
fn list_map_ref(refs: List(SchemaRef), spec: OpenApiSpec) -> List(SchemaRef) {
  list.map(refs, fn(r) { resolve_one_ref(r, spec) })
}
