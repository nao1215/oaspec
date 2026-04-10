import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oaspec/codegen/context.{type Context}
import oaspec/openapi/spec

/// Collect all operations from the spec with their IDs, paths, and methods.
pub fn collect_operations(
  ctx: Context,
) -> List(#(String, spec.Operation, String, spec.HttpMethod)) {
  let paths =
    list.sort(dict.to_list(ctx.spec.paths), fn(a, b) {
      string.compare(a.0, b.0)
    })
  list.flat_map(paths, fn(entry) {
    let #(path, path_item) = entry
    let ops = [
      #(path_item.get, spec.Get),
      #(path_item.post, spec.Post),
      #(path_item.put, spec.Put),
      #(path_item.delete, spec.Delete),
      #(path_item.patch, spec.Patch),
      #(path_item.head, spec.Head),
      #(path_item.options, spec.Options),
      #(path_item.trace, spec.Trace),
    ]
    list.filter_map(ops, fn(op_entry) {
      let #(maybe_op, method) = op_entry
      case maybe_op {
        Some(operation) -> {
          // Merge path-level parameters with operation parameters.
          // Operation params take precedence by (name, in) key per OpenAPI spec.
          let op_param_keys =
            list.map(operation.parameters, fn(p) { #(p.name, p.in_) })
          let inherited_params =
            list.filter(path_item.parameters, fn(p) {
              !list.contains(op_param_keys, #(p.name, p.in_))
            })
          let merged_params =
            list.append(inherited_params, operation.parameters)
          // Inherit top-level security if operation doesn't define its own.
          // operation.security = None → inherit, Some([]) → no security,
          // Some([...]) → use operation-level.
          let effective_security = case operation.security {
            Some(sec) -> sec
            None -> ctx.spec.security
          }
          let operation =
            spec.Operation(
              ..operation,
              parameters: merged_params,
              security: Some(effective_security),
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
          Ok(#(op_id, operation, path, method))
        }
        None -> Error(Nil)
      }
    })
  })
}
