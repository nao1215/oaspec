import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oaspec/openapi/spec.{
  type HttpMethod, type OpenApiSpec, type Operation, type PathItem,
  type Resolved,
}

/// Collect all operations from the spec with their IDs, paths, and methods.
/// Handles path-level parameter inheritance, security inheritance, and
/// operationId generation from method + path when not specified.
///
/// Pure: depends only on the resolved spec, not on the codegen Context.
/// The Context now precomputes this list once at construction time and
/// every codegen pass reads it through `context.operations/1` instead of
/// re-running this traversal (issue #371).
pub fn collect_operations(
  resolved_spec: OpenApiSpec(Resolved),
) -> List(#(String, Operation(Resolved), String, HttpMethod)) {
  let paths =
    list.sort(dict.to_list(resolved_spec.paths), fn(a, b) {
      string.compare(a.0, b.0)
    })
  list.flat_map(paths, fn(entry) {
    let #(path, ref_or) = entry
    // All path-level refs are resolved by this point
    let path_item = spec.unwrap_ref(ref_or)
    path_item_operations(path_item)
    |> list.map(fn(op_entry) {
      let #(method, operation) = op_entry
      // Merge path-level parameters with operation parameters.
      // Operation params take precedence by (name, in) key per OpenAPI spec.
      let op_param_keys =
        list.map(operation.parameters, fn(ref_p) {
          let parameter = spec.unwrap_ref(ref_p)
          #(parameter.name, parameter.in_)
        })
      let inherited_params =
        list.filter(path_item.parameters, fn(ref_p) {
          let parameter = spec.unwrap_ref(ref_p)
          !list.contains(op_param_keys, #(parameter.name, parameter.in_))
        })
      let merged_params = list.append(inherited_params, operation.parameters)
      // Inherit top-level security if operation doesn't define its own.
      // operation.security = None → inherit, Some([]) → no security,
      // Some([...]) → use operation-level.
      let effective_security = case operation.security {
        Some(sec) -> sec
        None -> resolved_spec.security
      }
      // Inherit path-level servers when operation doesn't define its own.
      // OpenAPI precedence: operation.servers > path_item.servers > spec.servers
      let effective_servers = case operation.servers {
        [_, ..] -> operation.servers
        [] -> path_item.servers
      }
      let operation =
        spec.Operation(
          ..operation,
          parameters: merged_params,
          security: Some(effective_security),
          servers: effective_servers,
        )

      let op_id = case operation.operation_id {
        Some(id) -> id
        None ->
          spec.method_to_lower(method)
          <> "_"
          <> string.replace(path, "/", "_")
          |> string.replace("{", "")
          |> string.replace("}", "")
      }
      #(op_id, operation, path, method)
    })
  })
}

/// The operations a path item declares, each with its method, in the order
/// get, post, put, delete, patch, head, options, trace.
pub fn path_item_operations(
  item: PathItem(stage),
) -> List(#(HttpMethod, Operation(stage))) {
  [
    #(spec.Get, item.get),
    #(spec.Post, item.post),
    #(spec.Put, item.put),
    #(spec.Delete, item.delete),
    #(spec.Patch, item.patch),
    #(spec.Head, item.head),
    #(spec.Options, item.options),
    #(spec.Trace, item.trace),
  ]
  |> list.filter_map(fn(entry) {
    case entry.1 {
      Some(operation) -> Ok(#(entry.0, operation))
      None -> Error(Nil)
    }
  })
}
