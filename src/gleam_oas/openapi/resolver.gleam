import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam_oas/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  Inline, ObjectSchema, OneOfSchema, Reference,
}
import gleam_oas/openapi/spec.{type OpenApiSpec}

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
  |> list_last
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
    Reference(ref:) -> {
      case set.contains(seen, ref) {
        True -> Error(CircularRef(ref:))
        False -> {
          let new_seen = set.insert(seen, ref)
          case spec.components {
            Some(components) -> {
              let name = ref_to_name(ref)
              case dict.get(components.schemas, name) {
                Ok(Inline(schema)) -> Ok(schema)
                Ok(Reference(inner_ref)) ->
                  resolve_schema_ref_with_seen(
                    Reference(ref: inner_ref),
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
    ObjectSchema(
      description:,
      properties:,
      required:,
      additional_properties:,
      additional_properties_untyped:,
      nullable:,
    ) -> {
      let resolved_props =
        dict.map_values(properties, fn(_k, v) { resolve_one_ref(v, spec) })
      let resolved_ap = case additional_properties {
        Some(ap) -> Some(resolve_one_ref(ap, spec))
        None -> None
      }
      ObjectSchema(
        description:,
        properties: resolved_props,
        required:,
        additional_properties: resolved_ap,
        additional_properties_untyped:,
        nullable:,
      )
    }
    ArraySchema(description:, items:, min_items:, max_items:, nullable:) ->
      ArraySchema(
        description:,
        items: resolve_one_ref(items, spec),
        min_items:,
        max_items:,
        nullable:,
      )
    AllOfSchema(description:, schemas:) -> {
      let resolved = list_map_ref(schemas, spec)
      AllOfSchema(description:, schemas: resolved)
    }
    OneOfSchema(description:, schemas:, discriminator:) -> {
      let resolved = list_map_ref(schemas, spec)
      OneOfSchema(description:, schemas: resolved, discriminator:)
    }
    AnyOfSchema(description:, schemas:) -> {
      let resolved = list_map_ref(schemas, spec)
      AnyOfSchema(description:, schemas: resolved)
    }
    other -> other
  }
}

/// Try to resolve a single ref, keeping it as-is if resolution fails.
fn resolve_one_ref(schema_ref: SchemaRef, spec: OpenApiSpec) -> SchemaRef {
  case schema_ref {
    Reference(ref:) ->
      case resolve_schema_ref(schema_ref, spec) {
        Ok(schema) -> Inline(schema)
        Error(_) -> Reference(ref:)
      }
    inline -> inline
  }
}

/// Map a list of schema refs, resolving each.
fn list_map_ref(refs: List(SchemaRef), spec: OpenApiSpec) -> List(SchemaRef) {
  list.map(refs, fn(r) { resolve_one_ref(r, spec) })
}

/// Get the last element of a list.
fn list_last(items: List(String)) -> Result(String, Nil) {
  case items {
    [] -> Error(Nil)
    [last] -> Ok(last)
    [_, ..rest] -> list_last(rest)
  }
}
