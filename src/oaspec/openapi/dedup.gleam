import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AnyOfSchema, Forbidden, Inline,
  ObjectSchema, OneOfSchema, Reference, Typed, Untyped,
}
import oaspec/openapi/spec.{
  type OpenApiSpec, type Operation, type PathItem, Components, OpenApiSpec,
  PathItem, Ref, Value,
}
import oaspec/util/naming

/// Deduplicate names in the spec to avoid collisions in generated code.
/// This is a pre-processing pass that runs after hoisting and before validation.
/// It handles:
///   - Duplicate operationIds across operations
///   - Function/type name collisions after case conversion of operationIds
/// Property name and enum variant deduplication is done at codegen time via
/// dedup_property_names/1 and dedup_enum_variants/1 to preserve JSON wire names.
pub fn dedup(spec: OpenApiSpec(stage)) -> OpenApiSpec(stage) {
  let spec = dedup_operation_ids(spec)
  let spec = dedup_schemas(spec)
  spec
}

/// Deduplicate operationIds across all operations.
/// If two operations have the same operationId, the second gets "_2" appended, etc.
/// Also handles function/type name collisions after case conversion.
fn dedup_operation_ids(spec: OpenApiSpec(stage)) -> OpenApiSpec(stage) {
  // Collect all operation IDs with their paths
  let all_ops = collect_all_operations(spec)

  // First pass: deduplicate raw operationIds
  let raw_ids =
    list.map(all_ops, fn(op) {
      let #(_path, _method, operation) = op
      case operation.operation_id {
        Some(id) -> id
        None -> ""
      }
    })
  let deduped_ids = deduplicate_strings(raw_ids)

  // Second pass: deduplicate after snake_case conversion (function names)
  let fn_names = list.map(deduped_ids, naming.operation_to_function_name)
  let deduped_fn_names = deduplicate_strings(fn_names)

  // Build mapping: index -> final operationId
  // If function name was deduped, derive the operationId from the deduped function name
  let indexed_ops = list.index_map(all_ops, fn(op, idx) { #(idx, op) })
  let id_map =
    list.index_fold(indexed_ops, dict.new(), fn(acc, entry, _) {
      let #(idx, #(path, method, _op)) = entry
      let final_id = case
        list_at(deduped_ids, idx),
        list_at(deduped_fn_names, idx)
      {
        Some(raw_id), Some(fn_name) -> {
          // If function name differs from snake_case of raw_id, use the deduped fn name
          let expected_fn = naming.operation_to_function_name(raw_id)
          case expected_fn == fn_name {
            True -> raw_id
            False -> fn_name
          }
        }
        Some(raw_id), _ -> raw_id
        _, _ -> ""
      }
      dict.insert(acc, #(path, method), final_id)
    })

  // Apply the deduped IDs back to the spec
  let new_paths =
    dict.to_list(spec.paths)
    |> list.map(fn(entry) {
      let #(path, ref_or) = entry
      case ref_or {
        Value(path_item) -> {
          let new_item = dedup_path_item_ops(path_item, path, id_map)
          #(path, Value(new_item))
        }
        Ref(_) as r -> #(path, r)
      }
    })
    |> dict.from_list()

  OpenApiSpec(..spec, paths: new_paths)
}

fn dedup_path_item_ops(
  item: PathItem(stage),
  path: String,
  id_map: Dict(#(String, String), String),
) -> PathItem(stage) {
  PathItem(
    ..item,
    get: apply_deduped_id(item.get, path, "get", id_map),
    post: apply_deduped_id(item.post, path, "post", id_map),
    put: apply_deduped_id(item.put, path, "put", id_map),
    delete: apply_deduped_id(item.delete, path, "delete", id_map),
    patch: apply_deduped_id(item.patch, path, "patch", id_map),
    head: apply_deduped_id(item.head, path, "head", id_map),
    options: apply_deduped_id(item.options, path, "options", id_map),
    trace: apply_deduped_id(item.trace, path, "trace", id_map),
  )
}

fn apply_deduped_id(
  op: Option(Operation(stage)),
  path: String,
  method: String,
  id_map: Dict(#(String, String), String),
) -> Option(Operation(stage)) {
  case op {
    None -> None
    Some(operation) ->
      case dict.get(id_map, #(path, method)) {
        Ok(new_id) if new_id != "" ->
          Some(spec.Operation(..operation, operation_id: Some(new_id)))
        _ -> Some(operation)
      }
  }
}

/// Collect all operations as (path, method_str, operation) tuples.
fn collect_all_operations(
  spec: OpenApiSpec(stage),
) -> List(#(String, String, Operation(stage))) {
  let paths =
    list.sort(dict.to_list(spec.paths), fn(a, b) { string.compare(a.0, b.0) })
  list.flat_map(paths, fn(entry) {
    let #(path, ref_or) = entry
    case ref_or {
      Ref(_) -> []
      Value(item) -> {
        let ops = [
          #("get", item.get),
          #("post", item.post),
          #("put", item.put),
          #("delete", item.delete),
          #("patch", item.patch),
          #("head", item.head),
          #("options", item.options),
          #("trace", item.trace),
        ]
        list.filter_map(ops, fn(op) {
          case op {
            #(method, Some(operation)) -> Ok(#(path, method, operation))
            _ -> Error(Nil)
          }
        })
      }
    }
  })
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

/// Given a list of original enum values (JSON wire values), return a list
/// of deduped PascalCase Gleam variant suffixes. The returned list is
/// parallel to the input.
pub fn dedup_enum_variants(enum_values: List(String)) -> List(String) {
  let pascal_names = list.map(enum_values, naming.to_pascal_case)
  deduplicate_strings(pascal_names)
}

/// Deduplicate a list of strings by appending "_2", "_3", etc. for duplicates.
fn deduplicate_strings(names: List(String)) -> List(String) {
  let #(result_rev, _) =
    list.fold(names, #([], dict.new()), fn(acc, name) {
      let #(result, counts) = acc
      case dict.get(counts, name) {
        Error(_) -> {
          let counts = dict.insert(counts, name, 1)
          #([name, ..result], counts)
        }
        Ok(count) -> {
          let new_count = count + 1
          let unique_name = name <> "_" <> int.to_string(new_count)
          let counts = dict.insert(counts, name, new_count)
          #([unique_name, ..result], counts)
        }
      }
    })
  list.reverse(result_rev)
}

/// Get element at index from a list.
fn list_at(lst: List(a), idx: Int) -> Option(a) {
  case lst, idx {
    [], _ -> None
    [head, ..], 0 -> Some(head)
    [_, ..rest], n -> list_at(rest, n - 1)
  }
}
