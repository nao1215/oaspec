import gleam/list
import gleam/option.{Some}
import gleam_oas/codegen/context.{
  type Context, type GeneratedFile, GeneratedFile,
}
import gleam_oas/codegen/types as type_gen
import gleam_oas/openapi/spec
import gleam_oas/util/naming
import gleam_oas/util/string_extra as se

/// Generate server stub files.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let handlers_content = generate_handlers(ctx)
  let router_content = generate_router(ctx)

  [
    GeneratedFile(path: "handlers.gleam", content: handlers_content),
    GeneratedFile(path: "router.gleam", content: router_content),
  ]
}

/// Generate handler stubs for all operations.
fn generate_handlers(ctx: Context) -> String {
  let sb =
    se.file_header(context.version)
    |> se.imports([
      ctx.config.package <> "/request_types",
      ctx.config.package <> "/response_types",
    ])

  let operations = type_gen.collect_operations(ctx)

  let sb =
    list.fold(operations, sb, fn(sb, op) {
      let #(op_id, operation, _path, _method) = op
      generate_handler(sb, op_id, operation, ctx)
    })

  se.to_string(sb)
}

/// Generate a single handler stub.
fn generate_handler(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation,
  _ctx: Context,
) -> se.StringBuilder {
  let fn_name = naming.operation_to_function_name(op_id)
  let request_type = naming.schema_to_type_name(op_id) <> "Request"
  let response_type = naming.schema_to_type_name(op_id) <> "Response"

  let sb = case operation.summary {
    Some(summary) -> sb |> se.doc_comment(summary)
    _ -> sb
  }
  let sb = case operation.description {
    Some(desc) -> sb |> se.doc_comment(desc)
    _ -> sb
  }

  let has_params =
    !list.is_empty(operation.parameters)
    || option.is_some(operation.request_body)

  let sb = case has_params {
    True ->
      sb
      |> se.line(
        "pub fn "
        <> fn_name
        <> "(req: request_types."
        <> request_type
        <> ") -> response_types."
        <> response_type
        <> " {",
      )
    False ->
      sb
      |> se.line(
        "pub fn " <> fn_name <> "() -> response_types." <> response_type <> " {",
      )
  }

  let sb = case has_params {
    True -> sb |> se.indent(1, "let _ = req")
    False -> sb
  }

  sb
  |> se.indent(1, "// TODO: Implement " <> fn_name)
  |> se.indent(1, "todo")
  |> se.line("}")
  |> se.blank_line()
}

/// Generate a router module that dispatches requests.
fn generate_router(ctx: Context) -> String {
  let sb =
    se.file_header(context.version)
    |> se.imports([
      ctx.config.package <> "/handlers",
    ])

  let sb =
    sb
    |> se.doc_comment("Route an incoming request to the appropriate handler.")
    |> se.line("pub fn route(method: String, path: List(String)) -> String {")
    |> se.indent(1, "case method, path {")

  let operations = type_gen.collect_operations(ctx)

  let sb =
    list.fold(operations, sb, fn(sb, op) {
      let #(op_id, _operation, path, method) = op
      let fn_name = naming.operation_to_function_name(op_id)
      let method_str = spec.method_to_string(method)
      let path_pattern = path_to_pattern(path)

      sb
      |> se.indent(2, "\"" <> method_str <> "\", " <> path_pattern <> " -> {")
      |> se.indent(3, "let _ = handlers." <> fn_name)
      |> se.indent(3, "\"OK\"")
      |> se.indent(2, "}")
    })

  let sb =
    sb
    |> se.indent(2, "_, _ -> \"Not Found\"")
    |> se.indent(1, "}")
    |> se.line("}")
    |> se.blank_line()

  se.to_string(sb)
}

/// Convert an OpenAPI path to a Gleam pattern match expression.
fn path_to_pattern(path: String) -> String {
  let segments =
    path
    |> string_split("/")
    |> list.filter(fn(s) { s != "" })

  let patterns =
    list.map(segments, fn(seg) {
      case is_path_param(seg) {
        True -> {
          let param_name = extract_param_name(seg)
          naming.to_snake_case(param_name)
        }
        False -> "\"" <> seg <> "\""
      }
    })

  "[" <> se.join_with(patterns, ", ") <> "]"
}

/// Check if a path segment is a parameter.
fn is_path_param(segment: String) -> Bool {
  case segment {
    "{" <> _ -> True
    _ -> False
  }
}

/// Extract parameter name from {name}.
fn extract_param_name(segment: String) -> String {
  segment
  |> string_replace("{", "")
  |> string_replace("}", "")
}

/// Simple string split (avoiding import issues).
fn string_split(input: String, delimiter: String) -> List(String) {
  do_string_split(input, delimiter)
}

@external(erlang, "string", "split")
fn do_string_split(input: String, delimiter: String) -> List(String) {
  // Fallback - won't be called on erlang target
  let _ = delimiter
  [input]
}

/// Simple string replace.
fn string_replace(input: String, pattern: String, replacement: String) -> String {
  do_string_replace(input, pattern, replacement)
}

@external(erlang, "gleam_stdlib", "string_replace")
fn do_string_replace(
  input: String,
  pattern: String,
  replacement: String,
) -> String {
  let _ = pattern
  let _ = replacement
  input
}
