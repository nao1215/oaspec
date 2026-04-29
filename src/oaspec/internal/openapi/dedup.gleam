import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import oaspec/internal/openapi/schema.{
  type SchemaObject, type SchemaRef, AnyOfSchema, Forbidden, Inline,
  ObjectSchema, OneOfSchema, Reference, Typed, Unspecified, Untyped,
}
import oaspec/internal/openapi/spec.{type OpenApiSpec, Components, OpenApiSpec}
import oaspec/internal/util/naming

/// Deduplicate names within schemas to avoid collisions in generated code.
/// This is a pre-processing pass that runs after hoisting and before validation.
///
/// Scope is intentionally limited: operationId / function-name uniqueness is
/// enforced by `oaspec/internal/codegen/validate.gleam` with a hard error, not by a
/// silent rename, because renaming mutates the generated public API surface
/// without telling the user (see issue #237). Property name and enum variant
/// deduplication is done at codegen time via dedup_property_names/1 and
/// dedup_enum_variants/1 to preserve JSON wire names.
pub fn dedup(spec: OpenApiSpec(stage)) -> OpenApiSpec(stage) {
  spec
  |> dedup_schemas
}

/// Recurse into nested schemas within components (e.g. oneOf children).
fn dedup_schemas(spec: OpenApiSpec(stage)) -> OpenApiSpec(stage) {
  case spec.components {
    None -> spec
    Some(components) -> {
      let new_schemas =
        dict.to_list(components.schemas)
        |> list.map(fn(entry) {
          let #(name, schema_ref) = entry
          #(name, dedup_schema_ref(schema_ref))
        })
        |> dict.from_list()
      OpenApiSpec(
        ..spec,
        components: Some(Components(..components, schemas: new_schemas)),
      )
    }
  }
}

fn dedup_schema_ref(schema_ref: SchemaRef) -> SchemaRef {
  case schema_ref {
    Reference(..) -> schema_ref
    Inline(schema_obj) -> Inline(dedup_schema_object(schema_obj))
  }
}

fn dedup_schema_object(schema_obj: SchemaObject) -> SchemaObject {
  case schema_obj {
    ObjectSchema(properties:, additional_properties:, ..) as obj -> {
      // Only recurse into child schemas — do NOT rename property keys.
      let new_props =
        dict.to_list(properties)
        |> list.map(fn(entry) {
          let #(name, prop_ref) = entry
          #(name, dedup_schema_ref(prop_ref))
        })
        |> dict.from_list()

      ObjectSchema(
        ..obj,
        properties: new_props,
        additional_properties: case additional_properties {
          Typed(ap) -> Typed(dedup_schema_ref(ap))
          Forbidden -> Forbidden
          Untyped -> Untyped
          Unspecified -> Unspecified
        },
      )
    }

    // Do NOT rename enum values — they are JSON wire values.
    // Gleam variant deduplication is handled at codegen time via
    // dedup_enum_variants/1.
    OneOfSchema(metadata:, schemas:, discriminator:) ->
      OneOfSchema(
        metadata:,
        schemas: list.map(schemas, dedup_schema_ref),
        discriminator:,
      )

    AnyOfSchema(metadata:, schemas:, discriminator:) ->
      AnyOfSchema(
        metadata:,
        schemas: list.map(schemas, dedup_schema_ref),
        discriminator:,
      )

    _ -> schema_obj
  }
}

/// Given a list of original property names (JSON wire names), return a list
/// of deduped snake_case Gleam field names. The returned list is parallel
/// to the input: result[i] is the Gleam name for input[i].
pub fn dedup_property_names(prop_names: List(String)) -> List(String) {
  let snake_names = list.map(prop_names, naming.to_snake_case)
  deduplicate_strings(snake_names)
}

/// Given the parameters of a single operation, return a parallel list of
/// deduped snake_case Gleam field names. Parameters whose wire names map to
/// the same snake_case field (e.g. `id` in path AND `id` in query) get the
/// same `_2`/`_3` suffix treatment used for property names. The reserved
/// label `body` is taken first so a parameter literally named `body` is
/// renamed instead of clashing with the request type's body field.
///
/// The function is order-sensitive: the first occurrence keeps its base
/// snake_case form, later occurrences get the suffix. Pass the parameters
/// in the same order the spec lists them so type emission, server dispatch,
/// and client builder agree on the final field name.
pub fn dedup_param_field_names(
  params: List(spec.Parameter(stage)),
) -> List(String) {
  let snake_names = list.map(params, fn(p) { naming.to_snake_case(p.name) })
  let with_body_reserved = ["body", ..snake_names]
  case deduplicate_strings(with_body_reserved) {
    [_body, ..rest] -> rest
    _ -> []
  }
}

/// Given a list of original enum values (JSON wire values), return a list
/// of deduped PascalCase Gleam variant suffixes. The returned list is
/// parallel to the input.
pub fn dedup_enum_variants(enum_values: List(String)) -> List(String) {
  let pascal_names = list.map(enum_values, naming.to_pascal_case)
  deduplicate_strings(pascal_names)
}

/// Deduplicate a list of strings by appending "_2", "_3", etc. for duplicates.
/// The chosen suffix skips any name that already appears elsewhere in the
/// input (so a later literal `foo_2` keeps its label and an earlier
/// duplicate `foo` advances to `foo_3`) and any suffix this call has
/// already handed out, so the output has no collisions in either
/// direction.
fn deduplicate_strings(names: List(String)) -> List(String) {
  let input_names =
    list.fold(names, dict.new(), fn(acc, name) { dict.insert(acc, name, True) })
  let #(result_rev, _) =
    list.fold(names, #([], dict.new()), fn(acc, name) {
      let #(result, claimed) = acc
      case dict.has_key(claimed, name) {
        False -> #([name, ..result], dict.insert(claimed, name, True))
        True -> {
          let unique_name = next_unique_name(name, input_names, claimed, 2)
          #([unique_name, ..result], dict.insert(claimed, unique_name, True))
        }
      }
    })
  list.reverse(result_rev)
}

/// Pick the first `base_<n>` suffix that collides neither with another
/// literal input name nor with a name this call has already minted.
fn next_unique_name(
  base: String,
  input_names: Dict(String, Bool),
  claimed: Dict(String, Bool),
  suffix: Int,
) -> String {
  let candidate = base <> "_" <> int.to_string(suffix)
  case
    dict.has_key(input_names, candidate) || dict.has_key(claimed, candidate)
  {
    True -> next_unique_name(base, input_names, claimed, suffix + 1)
    False -> candidate
  }
}
