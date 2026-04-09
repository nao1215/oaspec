import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/types as type_gen
import oaspec/openapi/resolver
import oaspec/openapi/schema.{type SchemaRef, Inline, ObjectSchema, Reference}
import oaspec/openapi/spec
import oaspec/util/http
import oaspec/util/naming
import oaspec/util/string_extra as se

/// Expression that case-insensitively parses a string to Bool.
/// Accepts "true"/"True"/"TRUE" etc. as True, everything else as False.
/// This is compatible with Gleam's bool.to_string which produces "True"/"False".
const bool_parse_expr = "case string.lowercase(v) { \"true\" -> True _ -> False }"

/// Generate server stub files.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let handlers_content = generate_handlers(ctx)
  let router_content = generate_router(ctx)

  [
    GeneratedFile(
      path: "handlers.gleam",
      content: handlers_content,
      target: context.ServerTarget,
    ),
    GeneratedFile(
      path: "router.gleam",
      content: router_content,
      target: context.ServerTarget,
    ),
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

  // Generate callback handler stubs
  let sb =
    list.fold(operations, sb, fn(sb, op) {
      let #(op_id, operation, _path, _method) = op
      generate_callback_handlers(sb, op_id, operation)
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

/// Generate callback handler stubs for an operation's callbacks.
fn generate_callback_handlers(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation,
) -> se.StringBuilder {
  let callbacks = dict.to_list(operation.callbacks)
  list.fold(callbacks, sb, fn(sb, entry) {
    let #(callback_name, callback) = entry
    let callback_entries = dict.to_list(callback.entries)
    list.fold(callback_entries, sb, fn(sb, cb_entry) {
      let #(url_expression, _path_item) = cb_entry
      let fn_name =
        naming.operation_to_function_name(op_id)
        <> "_callback_"
        <> naming.to_snake_case(callback_name)
        <> "_"
        <> naming.to_snake_case(url_expression_to_suffix(url_expression))
      sb
      |> se.doc_comment(
        "Callback handler stub for " <> callback_name <> " on " <> op_id,
      )
      |> se.doc_comment("URL: " <> url_expression)
      |> se.line("pub fn " <> fn_name <> "() -> String {")
      |> se.indent(1, "// TODO: Implement callback " <> callback_name)
      |> se.indent(1, "todo")
      |> se.line("}")
      |> se.blank_line()
    })
  })
}

/// Extract a short suffix from a URL expression for function naming.
fn url_expression_to_suffix(url_expression: String) -> String {
  // Take the last path segment, stripping any template expressions
  let parts = string.split(url_expression, "/")
  case list.last(parts) {
    Ok(last) ->
      last
      |> string.replace("{", "")
      |> string.replace("}", "")
      |> string.replace("$", "")
      |> string.replace("#", "")
    Error(_) -> "handler"
  }
}

/// Generate a router module that dispatches requests.
fn generate_router(ctx: Context) -> String {
  let operations = type_gen.collect_operations(ctx)
  let has_deep_object =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(p) { is_deep_object_param(p, ctx) })
    })
  let has_form_urlencoded_body =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      operation_uses_form_urlencoded_body(operation)
    })
  let has_multipart_body =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      operation_uses_multipart_body(operation)
    })
  let has_nested_form_urlencoded_body =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(rb) -> form_urlencoded_body_has_nested_object(rb, ctx)
        None -> False
      }
    })

  // Determine which imports are needed based on operations
  let needs_dict =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      let has_query =
        list.any(operation.parameters, fn(p) { p.in_ == spec.InQuery })
      let has_header =
        list.any(operation.parameters, fn(p) { p.in_ == spec.InHeader })
      has_query || has_header
    })

  let needs_int =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(p) {
        query_schema_needs_int(p.schema) || deep_object_param_needs_int(p, ctx)
      })
      || case operation.request_body {
        Some(rb) -> form_urlencoded_body_needs_int(rb, ctx)
        None -> False
      }
      || case operation.request_body {
        Some(rb) -> multipart_body_needs_int(rb, ctx)
        None -> False
      }
    })

  let needs_float =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(p) {
        query_schema_needs_float(p.schema)
        || deep_object_param_needs_float(p, ctx)
      })
      || case operation.request_body {
        Some(rb) -> form_urlencoded_body_needs_float(rb, ctx)
        None -> False
      }
      || case operation.request_body {
        Some(rb) -> multipart_body_needs_float(rb, ctx)
        None -> False
      }
    })

  let needs_string =
    has_form_urlencoded_body
    || has_multipart_body
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(p) {
        case p.in_ {
          spec.InCookie -> True
          spec.InQuery | spec.InHeader ->
            query_schema_needs_string(p.schema)
            || deep_object_param_needs_string(p, ctx)
          spec.InPath -> query_schema_needs_string(p.schema)
        }
      })
      || case operation.request_body {
        Some(rb) -> form_urlencoded_body_needs_string(rb, ctx)
        None -> False
      }
    })

  let needs_cookie_lookup =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(p) { p.in_ == spec.InCookie })
    })

  let needs_list_import =
    needs_cookie_lookup
    || has_deep_object
    || has_form_urlencoded_body
    || has_multipart_body
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(p) {
        case p.in_, p.schema {
          spec.InQuery, Some(Inline(schema.ArraySchema(..))) -> True
          spec.InHeader, Some(Inline(schema.ArraySchema(..))) -> True
          _, _ -> False
        }
      })
    })
  let needs_uri_import = needs_cookie_lookup || has_form_urlencoded_body

  let needs_option =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      let has_optional_params =
        list.any(operation.parameters, fn(p) { !p.required })
      let has_optional_deep_object_fields =
        list.any(operation.parameters, fn(p) {
          deep_object_param_has_optional_fields(p, ctx)
        })
      let has_optional_form_urlencoded_fields = case operation.request_body {
        Some(rb) -> form_urlencoded_body_has_optional_fields(rb, ctx)
        None -> False
      }
      let has_optional_multipart_fields = case operation.request_body {
        Some(rb) -> multipart_body_has_optional_fields(rb, ctx)
        None -> False
      }
      let has_optional_body = case operation.request_body {
        Some(rb) -> !rb.required
        None -> False
      }
      has_optional_params
      || has_optional_deep_object_fields
      || has_optional_form_urlencoded_fields
      || has_optional_multipart_fields
      || has_optional_body
    })

  let needs_json =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      let responses = dict.to_list(operation.responses)
      list.any(responses, fn(entry) {
        let #(_, response) = entry
        let content_entries = dict.to_list(response.content)
        case content_entries {
          [#(media_type_name, media_type)] ->
            case media_type_name {
              "application/json" ->
                case media_type.schema {
                  Some(_) -> True
                  None -> False
                }
              _ -> False
            }
          _ -> False
        }
      })
    })

  let needs_decode =
    needs_json
    && list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      option.is_some(operation.request_body)
    })

  let needs_encode = needs_json

  let uses_query =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(p) { p.in_ == spec.InQuery })
    })

  let uses_headers =
    has_multipart_body
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(p) {
        p.in_ == spec.InHeader || p.in_ == spec.InCookie
      })
    })

  let uses_body =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      option.is_some(operation.request_body)
    })

  let has_params_ops =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      !list.is_empty(operation.parameters)
      || option.is_some(operation.request_body)
    })

  // Build imports list (Dict always needed for route signature)
  let _ = needs_dict
  let std_imports = ["gleam/dict.{type Dict}"]
  let std_imports = case needs_list_import {
    True -> list.append(std_imports, ["gleam/list"])
    False -> std_imports
  }
  let std_imports = case needs_uri_import {
    True -> list.append(std_imports, ["gleam/uri"])
    False -> std_imports
  }
  let std_imports = case needs_int {
    True -> list.append(std_imports, ["gleam/int"])
    False -> std_imports
  }
  let std_imports = case needs_float {
    True -> list.append(std_imports, ["gleam/float"])
    False -> std_imports
  }
  let std_imports = case needs_option {
    True -> list.append(std_imports, ["gleam/option.{None, Some}"])
    False -> std_imports
  }
  let std_imports = case needs_json {
    True -> list.append(std_imports, ["gleam/json"])
    False -> std_imports
  }
  let std_imports = case needs_string {
    True -> list.append(std_imports, ["gleam/string"])
    False -> std_imports
  }

  let pkg_imports = [ctx.config.package <> "/handlers"]
  let pkg_imports = case
    has_deep_object || has_form_urlencoded_body || has_multipart_body
  {
    True -> list.append(pkg_imports, [ctx.config.package <> "/types"])
    False -> pkg_imports
  }
  let pkg_imports = case needs_decode {
    True -> list.append(pkg_imports, [ctx.config.package <> "/decode"])
    False -> pkg_imports
  }
  let pkg_imports = case needs_encode {
    True -> list.append(pkg_imports, [ctx.config.package <> "/encode"])
    False -> pkg_imports
  }
  let pkg_imports = case has_params_ops {
    True ->
      list.append(pkg_imports, [
        ctx.config.package <> "/request_types",
        ctx.config.package <> "/response_types",
      ])
    False -> list.append(pkg_imports, [ctx.config.package <> "/response_types"])
  }

  let all_imports = list.append(std_imports, pkg_imports)

  let sb =
    se.file_header(context.version)
    |> se.imports(all_imports)

  // Generate ServerResponse type
  let sb =
    sb
    |> se.doc_comment("A server response with status code, body, and headers.")
    |> se.line("pub type ServerResponse {")
    |> se.indent(
      1,
      "ServerResponse(status: Int, body: String, headers: List(#(String, String)))",
    )
    |> se.line("}")
    |> se.blank_line()

  let sb = case has_deep_object {
    True ->
      sb
      |> se.line(
        "fn deep_object_present(query: Dict(String, List(String)), prefix: String, props: List(String)) -> Bool {",
      )
      |> se.indent(
        1,
        "list.any(props, fn(prop) { dict.has_key(query, prefix <> \"[\" <> prop <> \"]\") })",
      )
      |> se.line("}")
      |> se.blank_line()
    False -> sb
  }

  let sb = case has_form_urlencoded_body {
    True ->
      sb
      |> se.line("fn form_url_decode(value: String) -> String {")
      |> se.indent(1, "let value = string.replace(value, \"+\", \" \")")
      |> se.indent(
        1,
        "case uri.percent_decode(value) { Ok(decoded) -> decoded Error(_) -> value }",
      )
      |> se.line("}")
      |> se.blank_line()
      |> se.line(
        "fn parse_form_body(body: String) -> Dict(String, List(String)) {",
      )
      |> se.indent(
        1,
        "let parts = case body { \"\" -> [] _ -> string.split(body, \"&\") }",
      )
      |> se.indent(1, "list.fold(parts, dict.new(), fn(acc, part) {")
      |> se.indent(2, "case part {")
      |> se.indent(3, "\"\" -> acc")
      |> se.indent(3, "_ ->")
      |> se.indent(4, "case string.split_once(part, on: \"=\") {")
      |> se.indent(5, "Ok(#(raw_key, raw_value)) -> {")
      |> se.indent(6, "let key = form_url_decode(raw_key)")
      |> se.indent(6, "let value = form_url_decode(raw_value)")
      |> se.indent(6, "case dict.get(acc, key) {")
      |> se.indent(
        7,
        "Ok(existing) -> dict.insert(acc, key, list.append(existing, [value]))",
      )
      |> se.indent(7, "Error(_) -> dict.insert(acc, key, [value])")
      |> se.indent(6, "}")
      |> se.indent(5, "}")
      |> se.indent(5, "Error(_) -> {")
      |> se.indent(6, "let key = form_url_decode(part)")
      |> se.indent(6, "case dict.get(acc, key) {")
      |> se.indent(
        7,
        "Ok(existing) -> dict.insert(acc, key, list.append(existing, [\"\"]))",
      )
      |> se.indent(7, "Error(_) -> dict.insert(acc, key, [\"\"])")
      |> se.indent(6, "}")
      |> se.indent(5, "}")
      |> se.indent(4, "}")
      |> se.indent(2, "}")
      |> se.indent(1, "})")
      |> se.line("}")
      |> se.blank_line()
    False -> sb
  }

  let sb = case has_multipart_body {
    True ->
      sb
      |> se.line(
        "fn multipart_boundary(headers: Dict(String, String)) -> Result(String, Nil) {",
      )
      |> se.indent(1, "case dict.get(headers, \"content-type\") {")
      |> se.indent(2, "Ok(content_type) ->")
      |> se.indent(
        3,
        "list.find_map(string.split(content_type, \";\"), fn(part) {",
      )
      |> se.indent(4, "let trimmed = string.trim(part)")
      |> se.indent(4, "case string.starts_with(trimmed, \"boundary=\") {")
      |> se.indent(
        5,
        "True -> Ok(string.replace(trimmed, \"boundary=\", \"\"))",
      )
      |> se.indent(5, "False -> Error(Nil)")
      |> se.indent(4, "}")
      |> se.indent(3, "})")
      |> se.indent(2, "Error(_) -> Error(Nil)")
      |> se.indent(1, "}")
      |> se.line("}")
      |> se.blank_line()
      |> se.line(
        "fn multipart_name(raw_headers: String) -> Result(String, Nil) {",
      )
      |> se.indent(
        1,
        "list.find_map(string.split(raw_headers, \"\\r\\n\"), fn(line) {",
      )
      |> se.indent(2, "case string.contains(line, \"name=\") {")
      |> se.indent(3, "True ->")
      |> se.indent(4, "list.find_map(string.split(line, \";\"), fn(part) {")
      |> se.indent(5, "let trimmed = string.trim(part)")
      |> se.indent(5, "case string.starts_with(trimmed, \"name=\") {")
      |> se.indent(
        6,
        "True -> Ok(string.replace(string.replace(trimmed, \"name=\", \"\"), \"\\\"\", \"\"))",
      )
      |> se.indent(6, "False -> Error(Nil)")
      |> se.indent(5, "}")
      |> se.indent(4, "})")
      |> se.indent(3, "False -> Error(Nil)")
      |> se.indent(2, "}")
      |> se.indent(1, "})")
      |> se.line("}")
      |> se.blank_line()
      |> se.line(
        "fn parse_multipart_body(body: String, headers: Dict(String, String)) -> Dict(String, List(String)) {",
      )
      |> se.indent(1, "case multipart_boundary(headers) {")
      |> se.indent(2, "Ok(boundary) -> {")
      |> se.indent(3, "let delimiter = \"--\" <> boundary")
      |> se.indent(3, "let parts = string.split(body, delimiter)")
      |> se.indent(3, "list.fold(parts, dict.new(), fn(acc, part) {")
      |> se.indent(
        4,
        "let normalized_part = part |> string.remove_prefix(\"\\r\\n\") |> string.remove_suffix(\"\\r\\n\")",
      )
      |> se.indent(
        4,
        "case normalized_part == \"\" || normalized_part == \"--\" {",
      )
      |> se.indent(5, "True -> acc")
      |> se.indent(5, "False ->")
      |> se.indent(
        6,
        "case string.split_once(normalized_part, on: \"\\r\\n\\r\\n\") {",
      )
      |> se.indent(7, "Ok(#(raw_part_headers, raw_value)) ->")
      |> se.indent(8, "case multipart_name(raw_part_headers) {")
      |> se.indent(9, "Ok(name) -> {")
      |> se.indent(10, "let value = raw_value")
      |> se.indent(10, "case dict.get(acc, name) {")
      |> se.indent(
        11,
        "Ok(existing) -> dict.insert(acc, name, list.append(existing, [value]))",
      )
      |> se.indent(11, "Error(_) -> dict.insert(acc, name, [value])")
      |> se.indent(10, "}")
      |> se.indent(9, "}")
      |> se.indent(9, "Error(_) -> acc")
      |> se.indent(8, "}")
      |> se.indent(7, "Error(_) -> acc")
      |> se.indent(6, "}")
      |> se.indent(4, "}")
      |> se.indent(3, "})")
      |> se.indent(2, "}")
      |> se.indent(2, "Error(_) -> dict.new()")
      |> se.indent(1, "}")
      |> se.line("}")
      |> se.blank_line()
    False -> sb
  }

  let sb = case has_nested_form_urlencoded_body {
    True ->
      sb
      |> se.line(
        "fn form_object_present(form_body: Dict(String, List(String)), prefix: String, props: List(String)) -> Bool {",
      )
      |> se.indent(
        1,
        "list.any(props, fn(prop) { dict.has_key(form_body, prefix <> \"[\" <> prop <> \"]\") })",
      )
      |> se.line("}")
      |> se.blank_line()
    False -> sb
  }

  // Generate route function
  let sb =
    sb
    |> se.doc_comment("Route an incoming request to the appropriate handler.")
    |> se.line(
      "pub fn route(method: String, path: List(String), "
      <> route_arg_name("query", uses_query)
      <> ": Dict(String, List(String)), "
      <> route_arg_name("headers", uses_headers)
      <> ": Dict(String, String), "
      <> route_arg_name("body", uses_body)
      <> ": String) -> ServerResponse {",
    )
    |> se.indent(1, "case method, path {")

  let sb =
    list.fold(operations, sb, fn(sb, op) {
      let #(op_id, operation, path, method) = op
      let fn_name = naming.operation_to_function_name(op_id)
      let method_str = spec.method_to_string(method)
      let path_pattern = path_to_pattern(path)

      let has_params =
        !list.is_empty(operation.parameters)
        || option.is_some(operation.request_body)

      sb
      |> se.indent(2, "\"" <> method_str <> "\", " <> path_pattern <> " -> {")
      |> generate_route_body(op_id, fn_name, operation, path, has_params, ctx)
      |> se.indent(2, "}")
    })

  let sb =
    sb
    |> se.indent(
      2,
      "_, _ -> ServerResponse(status: 404, body: \"Not Found\", headers: [])",
    )
    |> se.indent(1, "}")
    |> se.line("}")
    |> se.blank_line()

  let sb = case needs_cookie_lookup {
    True -> generate_cookie_lookup(sb)
    False -> sb
  }

  se.to_string(sb)
}

fn route_arg_name(name: String, used: Bool) -> String {
  case used {
    True -> name
    False -> "_" <> name
  }
}

fn generate_cookie_lookup(sb: se.StringBuilder) -> se.StringBuilder {
  sb
  |> se.doc_comment("Extract a cookie value from the Cookie header.")
  |> se.line(
    "fn cookie_lookup(headers: Dict(String, String), key: String) -> Result(String, Nil) {",
  )
  |> se.indent(1, "case dict.get(headers, \"cookie\") {")
  |> se.indent(2, "Ok(raw) ->")
  |> se.indent(3, "list.find_map(string.split(raw, \";\"), fn(part) {")
  |> se.indent(4, "let trimmed = string.trim(part)")
  |> se.indent(4, "case string.split_once(trimmed, on: \"=\") {")
  |> se.indent(5, "Ok(#(cookie_key, cookie_value)) ->")
  |> se.indent(6, "case string.trim(cookie_key) == key {")
  |> se.indent(7, "True -> uri.percent_decode(string.trim(cookie_value))")
  |> se.indent(7, "False -> Error(Nil)")
  |> se.indent(6, "}")
  |> se.indent(5, "Error(_) -> Error(Nil)")
  |> se.indent(4, "}")
  |> se.indent(3, "})")
  |> se.indent(2, "Error(_) -> Error(Nil)")
  |> se.indent(1, "}")
  |> se.line("}")
  |> se.blank_line()
}

/// Generate the body of a single route case branch.
fn generate_route_body(
  sb: se.StringBuilder,
  op_id: String,
  fn_name: String,
  operation: spec.Operation,
  path: String,
  has_params: Bool,
  ctx: Context,
) -> se.StringBuilder {
  let type_name = naming.schema_to_type_name(op_id)
  let response_type_name = type_name <> "Response"

  case has_params {
    False -> {
      // No parameters: call handler directly, convert response
      sb
      |> se.indent(3, "let response = handlers." <> fn_name <> "()")
      |> generate_response_conversion(response_type_name, operation, ctx)
    }
    True -> {
      // Has parameters: construct request, call handler, convert response
      let request_type_name = type_name <> "Request"
      let sb =
        generate_request_construction(
          sb,
          request_type_name,
          op_id,
          operation,
          path,
          ctx,
        )
      sb
      |> se.indent(3, "let response = handlers." <> fn_name <> "(request)")
      |> generate_response_conversion(response_type_name, operation, ctx)
    }
  }
}

/// Generate code to construct a typed request from raw inputs.
fn generate_request_construction(
  sb: se.StringBuilder,
  request_type_name: String,
  op_id: String,
  operation: spec.Operation,
  _path: String,
  ctx: Context,
) -> se.StringBuilder {
  let sb = case operation.request_body {
    Some(rb) ->
      case request_body_uses_form_urlencoded(rb) {
        True -> sb |> se.indent(3, "let form_body = parse_form_body(body)")
        False ->
          case request_body_uses_multipart(rb) {
            True ->
              sb
              |> se.indent(
                3,
                "let multipart_body = parse_multipart_body(body, headers)",
              )
            False -> sb
          }
      }
    _ -> sb
  }

  // Build request constructor
  let sb =
    sb
    |> se.indent(3, "let request = request_types." <> request_type_name <> "(")

  let sb =
    list.index_fold(operation.parameters, sb, fn(sb, param, _idx) {
      let field_name = naming.to_snake_case(param.name)
      let trailing = ","
      let value_expr = case param.in_ {
        spec.InPath -> {
          // Path param is already bound by the pattern match variable
          let var_name = naming.to_snake_case(param.name)
          param_parse_expr(var_name, param)
        }
        spec.InQuery -> {
          let key = param.name
          case is_deep_object_param(param, ctx), param.required {
            True, True -> deep_object_required_expr(key, param, op_id, ctx)
            True, False -> deep_object_optional_expr(key, param, op_id, ctx)
            False, True -> query_required_expr(key, param)
            False, False -> query_optional_expr(key, param)
          }
        }
        spec.InHeader -> {
          // HTTP headers are case-insensitive; client sends lowercase names.
          let key = string.lowercase(param.name)
          case param.required {
            True -> header_required_expr(key, param)
            False -> header_optional_expr(key, param)
          }
        }
        spec.InCookie -> {
          let key = param.name
          case param.required {
            True -> cookie_required_expr(key, param)
            False -> cookie_optional_expr(key, param)
          }
        }
      }
      sb |> se.indent(4, field_name <> ": " <> value_expr <> trailing)
    })

  // Add body field if present
  let sb = case operation.request_body {
    Some(rb) -> {
      let body_expr = generate_body_decode_expr(rb, op_id, ctx)
      sb |> se.indent(4, "body: " <> body_expr <> ",")
    }
    None -> sb
  }

  sb |> se.indent(3, ")")
}

/// Generate parse expression for a path parameter (already bound as String).
fn param_parse_expr(var_name: String, param: spec.Parameter) -> String {
  case param.schema {
    Some(Inline(schema.IntegerSchema(..))) -> {
      // Parse string to int; use 0 as fallback
      "{ let assert Ok(v) = int.parse(" <> var_name <> ") v }"
    }
    Some(Inline(schema.NumberSchema(..))) -> {
      "{ let assert Ok(v) = float.parse(" <> var_name <> ") v }"
    }
    Some(Inline(schema.BooleanSchema(..))) -> {
      "{ let v = " <> var_name <> " " <> bool_parse_expr <> " }"
    }
    _ -> var_name
  }
}

/// Generate expression for a required query parameter.
fn query_required_expr(key: String, param: spec.Parameter) -> String {
  query_required_expr_with_schema(key, param.schema, param.explode)
}

fn query_required_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  explode: Option(Bool),
) -> String {
  let base = "{ let assert Ok([v, ..]) = dict.get(query, \"" <> key <> "\") v }"
  case schema_ref {
    Some(Inline(schema.ArraySchema(items: Inline(schema.StringSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "{ let assert Ok([v, ..]) = dict.get(query, \""
          <> key
          <> "\") list.map(string.split(v, \",\"), fn(item) { string.trim(item) }) }"
        _ ->
          "{ let assert Ok(vs) = dict.get(query, \""
          <> key
          <> "\") list.map(vs, fn(item) { string.trim(item) }) }"
      }
    Some(Inline(schema.ArraySchema(items: Inline(schema.IntegerSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "{ let assert Ok([v, ..]) = dict.get(query, \""
          <> key
          <> "\") list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n }) }"
        _ ->
          "{ let assert Ok(vs) = dict.get(query, \""
          <> key
          <> "\") list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n }) }"
      }
    Some(Inline(schema.ArraySchema(items: Inline(schema.NumberSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "{ let assert Ok([v, ..]) = dict.get(query, \""
          <> key
          <> "\") list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n }) }"
        _ ->
          "{ let assert Ok(vs) = dict.get(query, \""
          <> key
          <> "\") list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n }) }"
      }
    Some(Inline(schema.ArraySchema(items: Inline(schema.BooleanSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "{ let assert Ok([v, ..]) = dict.get(query, \""
          <> key
          <> "\") list.map(string.split(v, \",\"), fn(item) { let v = string.trim(item) "
          <> bool_parse_expr
          <> " }) }"
        _ ->
          "{ let assert Ok(vs) = dict.get(query, \""
          <> key
          <> "\") list.map(vs, fn(item) { let v = string.trim(item) "
          <> bool_parse_expr
          <> " }) }"
      }
    Some(Inline(schema.IntegerSchema(..))) ->
      "{ let assert Ok([v, ..]) = dict.get(query, \""
      <> key
      <> "\") let assert Ok(n) = int.parse(v) n }"
    Some(Inline(schema.NumberSchema(..))) ->
      "{ let assert Ok([v, ..]) = dict.get(query, \""
      <> key
      <> "\") let assert Ok(n) = float.parse(v) n }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "{ let assert Ok([v, ..]) = dict.get(query, \""
      <> key
      <> "\") "
      <> bool_parse_expr
      <> " }"
    _ -> base
  }
}

/// Generate expression for an optional query parameter.
fn query_optional_expr(key: String, param: spec.Parameter) -> String {
  query_optional_expr_with_schema(key, param.schema, param.explode)
}

fn query_optional_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  explode: Option(Bool),
) -> String {
  case schema_ref {
    Some(Inline(schema.ArraySchema(items: Inline(schema.StringSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok([v, ..]) -> Some(list.map(string.split(v, \",\"), fn(item) { string.trim(item) })) _ -> None }"
        _ ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { string.trim(item) })) _ -> None }"
      }
    Some(Inline(schema.ArraySchema(items: Inline(schema.IntegerSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok([v, ..]) -> Some(list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n })) _ -> None }"
        _ ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n })) _ -> None }"
      }
    Some(Inline(schema.ArraySchema(items: Inline(schema.NumberSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok([v, ..]) -> Some(list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n })) _ -> None }"
        _ ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n })) _ -> None }"
      }
    Some(Inline(schema.ArraySchema(items: Inline(schema.BooleanSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok([v, ..]) -> Some(list.map(string.split(v, \",\"), fn(item) { let v = string.trim(item) "
          <> bool_parse_expr
          <> " })) _ -> None }"
        _ ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let v = string.trim(item) "
          <> bool_parse_expr
          <> " })) _ -> None }"
      }
    Some(Inline(schema.IntegerSchema(..))) ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok([v, ..]) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    Some(Inline(schema.NumberSchema(..))) ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok([v, ..]) -> Some("
      <> bool_parse_expr
      <> ") _ -> None }"
    _ ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok([v, ..]) -> Some(v) _ -> None }"
  }
}

type DeepObjectProperty {
  DeepObjectProperty(
    name: String,
    field_name: String,
    schema_ref: SchemaRef,
    required: Bool,
  )
}

type BodyFieldKind {
  BodyFieldUnknown
  BodyFieldString
  BodyFieldInt
  BodyFieldFloat
  BodyFieldBool
  BodyFieldStringArray
  BodyFieldIntArray
  BodyFieldFloatArray
  BodyFieldBoolArray
}

fn schema_ref_body_field_kind(
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> BodyFieldKind {
  case schema_ref {
    Some(schema_ref) -> body_field_kind(schema_ref, ctx)
    None -> BodyFieldUnknown
  }
}

fn body_field_kind(schema_ref: SchemaRef, ctx: Context) -> BodyFieldKind {
  case schema_ref {
    Inline(schema.StringSchema(..)) -> BodyFieldString
    Inline(schema.IntegerSchema(..)) -> BodyFieldInt
    Inline(schema.NumberSchema(..)) -> BodyFieldFloat
    Inline(schema.BooleanSchema(..)) -> BodyFieldBool
    Inline(schema.ArraySchema(items:, ..)) ->
      case body_field_kind(items, ctx) {
        BodyFieldString -> BodyFieldStringArray
        BodyFieldInt -> BodyFieldIntArray
        BodyFieldFloat -> BodyFieldFloatArray
        BodyFieldBool -> BodyFieldBoolArray
        _ -> BodyFieldUnknown
      }
    Reference(..) as schema_ref ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(schema_obj) -> body_field_kind_from_object(schema_obj, ctx)
        Error(_) -> BodyFieldUnknown
      }
    _ -> BodyFieldUnknown
  }
}

fn body_field_kind_from_object(schema_obj, ctx: Context) -> BodyFieldKind {
  case schema_obj {
    schema.StringSchema(..) -> BodyFieldString
    schema.IntegerSchema(..) -> BodyFieldInt
    schema.NumberSchema(..) -> BodyFieldFloat
    schema.BooleanSchema(..) -> BodyFieldBool
    schema.ArraySchema(items:, ..) ->
      case body_field_kind(items, ctx) {
        BodyFieldString -> BodyFieldStringArray
        BodyFieldInt -> BodyFieldIntArray
        BodyFieldFloat -> BodyFieldFloatArray
        BodyFieldBool -> BodyFieldBoolArray
        _ -> BodyFieldUnknown
      }
    _ -> BodyFieldUnknown
  }
}

fn body_field_kind_needs_int(kind: BodyFieldKind) -> Bool {
  case kind {
    BodyFieldInt | BodyFieldIntArray -> True
    _ -> False
  }
}

fn body_field_kind_needs_float(kind: BodyFieldKind) -> Bool {
  case kind {
    BodyFieldFloat | BodyFieldFloatArray -> True
    _ -> False
  }
}

fn is_deep_object_param(param: spec.Parameter, ctx: Context) -> Bool {
  case param.in_, param.style, param.schema {
    spec.InQuery, Some(spec.DeepObjectStyle), Some(Reference(..) as schema_ref) ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(ObjectSchema(..)) -> True
        _ -> False
      }
    spec.InQuery, Some(spec.DeepObjectStyle), Some(Inline(ObjectSchema(..))) ->
      True
    _, _, _ -> False
  }
}

fn deep_object_properties(
  param: spec.Parameter,
  ctx: Context,
) -> List(DeepObjectProperty) {
  let details = case param.schema {
    Some(Reference(..) as schema_ref) ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(ObjectSchema(properties:, required:, ..)) -> #(properties, required)
        _ -> #(dict.new(), [])
      }
    Some(Inline(ObjectSchema(properties:, required:, ..))) -> #(
      properties,
      required,
    )
    _ -> #(dict.new(), [])
  }
  let #(properties, required_fields) = details
  dict.to_list(properties)
  |> list.map(fn(entry) {
    let #(prop_name, prop_ref) = entry
    DeepObjectProperty(
      name: prop_name,
      field_name: naming.to_snake_case(prop_name),
      schema_ref: prop_ref,
      required: list.contains(required_fields, prop_name),
    )
  })
}

fn deep_object_type_name(param: spec.Parameter, op_id: String) -> String {
  case param.schema {
    Some(Reference(name:, ..)) -> "types." <> naming.schema_to_type_name(name)
    _ ->
      "types."
      <> naming.schema_to_type_name(op_id)
      <> "Param"
      <> naming.to_pascal_case(param.name)
  }
}

fn deep_object_required_expr(
  key: String,
  param: spec.Parameter,
  op_id: String,
  ctx: Context,
) -> String {
  deep_object_constructor_expr(key, param, op_id, ctx)
}

fn deep_object_optional_expr(
  key: String,
  param: spec.Parameter,
  op_id: String,
  ctx: Context,
) -> String {
  let props = deep_object_properties(param, ctx)
  let prop_names =
    props
    |> list.map(fn(prop) { "\"" <> prop.name <> "\"" })
    |> string.join(", ")
  "case deep_object_present(query, \""
  <> key
  <> "\", ["
  <> prop_names
  <> "]) { True -> Some("
  <> deep_object_constructor_expr(key, param, op_id, ctx)
  <> ") False -> None }"
}

fn deep_object_constructor_expr(
  key: String,
  param: spec.Parameter,
  op_id: String,
  ctx: Context,
) -> String {
  let fields =
    deep_object_properties(param, ctx)
    |> list.map(fn(prop) {
      let prop_key = key <> "[" <> prop.name <> "]"
      let value_expr = case prop.required {
        True ->
          query_required_expr_with_schema(
            prop_key,
            Some(prop.schema_ref),
            Some(True),
          )
        False ->
          query_optional_expr_with_schema(
            prop_key,
            Some(prop.schema_ref),
            Some(True),
          )
      }
      prop.field_name <> ": " <> value_expr
    })
    |> string.join(", ")
  deep_object_type_name(param, op_id) <> "(" <> fields <> ")"
}

fn deep_object_param_has_optional_fields(
  param: spec.Parameter,
  ctx: Context,
) -> Bool {
  case is_deep_object_param(param, ctx) {
    True ->
      list.any(deep_object_properties(param, ctx), fn(prop) { !prop.required })
    False -> False
  }
}

fn deep_object_param_needs_string(param: spec.Parameter, ctx: Context) -> Bool {
  case is_deep_object_param(param, ctx) {
    True ->
      list.any(deep_object_properties(param, ctx), fn(prop) {
        query_schema_needs_string(Some(prop.schema_ref))
      })
    False -> False
  }
}

fn deep_object_param_needs_int(param: spec.Parameter, ctx: Context) -> Bool {
  case is_deep_object_param(param, ctx) {
    True ->
      list.any(deep_object_properties(param, ctx), fn(prop) {
        query_schema_needs_int(Some(prop.schema_ref))
      })
    False -> False
  }
}

fn deep_object_param_needs_float(param: spec.Parameter, ctx: Context) -> Bool {
  case is_deep_object_param(param, ctx) {
    True ->
      list.any(deep_object_properties(param, ctx), fn(prop) {
        query_schema_needs_float(Some(prop.schema_ref))
      })
    False -> False
  }
}

fn request_body_uses_form_urlencoded(rb: spec.RequestBody) -> Bool {
  dict.has_key(rb.content, "application/x-www-form-urlencoded")
}

fn request_body_uses_multipart(rb: spec.RequestBody) -> Bool {
  dict.has_key(rb.content, "multipart/form-data")
}

fn operation_uses_form_urlencoded_body(operation: spec.Operation) -> Bool {
  case operation.request_body {
    Some(rb) -> request_body_uses_form_urlencoded(rb)
    None -> False
  }
}

fn operation_uses_multipart_body(operation: spec.Operation) -> Bool {
  case operation.request_body {
    Some(rb) -> request_body_uses_multipart(rb)
    None -> False
  }
}

fn object_properties_from_schema_ref(
  schema_ref: SchemaRef,
  ctx: Context,
) -> List(DeepObjectProperty) {
  let details = case schema_ref {
    Reference(..) as schema_ref ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(ObjectSchema(properties:, required:, ..)) -> #(properties, required)
        _ -> #(dict.new(), [])
      }
    Inline(ObjectSchema(properties:, required:, ..)) -> #(properties, required)
    _ -> #(dict.new(), [])
  }
  let #(properties, required_fields) = details
  dict.to_list(properties)
  |> list.map(fn(entry) {
    let #(prop_name, prop_ref) = entry
    DeepObjectProperty(
      name: prop_name,
      field_name: naming.to_snake_case(prop_name),
      schema_ref: prop_ref,
      required: list.contains(required_fields, prop_name),
    )
  })
}

fn form_urlencoded_body_properties(
  rb: spec.RequestBody,
  ctx: Context,
) -> List(DeepObjectProperty) {
  case dict.get(rb.content, "application/x-www-form-urlencoded") {
    Ok(media_type) -> {
      case media_type.schema {
        Some(schema_ref) -> object_properties_from_schema_ref(schema_ref, ctx)
        None -> []
      }
    }
    Error(_) -> []
  }
}

fn multipart_body_properties(
  rb: spec.RequestBody,
  ctx: Context,
) -> List(DeepObjectProperty) {
  case dict.get(rb.content, "multipart/form-data") {
    Ok(media_type) ->
      case media_type.schema {
        Some(schema_ref) -> object_properties_from_schema_ref(schema_ref, ctx)
        None -> []
      }
    Error(_) -> []
  }
}

fn schema_ref_resolves_to_object(schema_ref: SchemaRef, ctx: Context) -> Bool {
  case schema_ref {
    Inline(ObjectSchema(..)) -> True
    Reference(..) as schema_ref ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(ObjectSchema(..)) -> True
        _ -> False
      }
    _ -> False
  }
}

fn form_urlencoded_schema_ref_type_name(schema_ref: SchemaRef) -> String {
  case schema_ref {
    Reference(name:, ..) -> "types." <> naming.schema_to_type_name(name)
    _ -> "String"
  }
}

fn form_urlencoded_body_type_name(rb: spec.RequestBody, op_id: String) -> String {
  case dict.get(rb.content, "application/x-www-form-urlencoded") {
    Ok(media_type) ->
      case media_type.schema {
        Some(Reference(name:, ..)) ->
          "types." <> naming.schema_to_type_name(name)
        Some(Inline(ObjectSchema(..))) ->
          "types." <> naming.schema_to_type_name(op_id) <> "Request"
        _ -> "String"
      }
    Error(_) -> "String"
  }
}

fn multipart_body_type_name(rb: spec.RequestBody, op_id: String) -> String {
  case dict.get(rb.content, "multipart/form-data") {
    Ok(media_type) ->
      case media_type.schema {
        Some(Reference(name:, ..)) ->
          "types." <> naming.schema_to_type_name(name)
        Some(Inline(ObjectSchema(..))) ->
          "types." <> naming.schema_to_type_name(op_id) <> "Request"
        _ -> "String"
      }
    Error(_) -> "String"
  }
}

fn form_urlencoded_key(prefix: String, name: String) -> String {
  case prefix {
    "" -> name
    _ -> prefix <> "[" <> name <> "]"
  }
}

fn form_urlencoded_object_constructor_expr(
  type_name: String,
  prefix: String,
  properties: List(DeepObjectProperty),
  ctx: Context,
  nesting_depth: Int,
) -> String {
  let fields =
    properties
    |> list.map(fn(prop) {
      let key = form_urlencoded_key(prefix, prop.name)
      let value_expr = case
        nesting_depth < 5
        && schema_ref_resolves_to_object(prop.schema_ref, ctx),
        prop.required
      {
        True, True ->
          form_urlencoded_object_required_expr(
            key,
            prop.schema_ref,
            ctx,
            nesting_depth + 1,
          )
        True, False ->
          form_urlencoded_object_optional_expr(
            key,
            prop.schema_ref,
            ctx,
            nesting_depth + 1,
          )
        False, True ->
          form_body_required_expr_with_schema(key, Some(prop.schema_ref), ctx)
        False, False ->
          form_body_optional_expr_with_schema(key, Some(prop.schema_ref), ctx)
      }
      prop.field_name <> ": " <> value_expr
    })
    |> string.join(", ")
  type_name <> "(" <> fields <> ")"
}

fn form_urlencoded_object_required_expr(
  prefix: String,
  schema_ref: SchemaRef,
  ctx: Context,
  nesting_depth: Int,
) -> String {
  form_urlencoded_object_constructor_expr(
    form_urlencoded_schema_ref_type_name(schema_ref),
    prefix,
    object_properties_from_schema_ref(schema_ref, ctx),
    ctx,
    nesting_depth,
  )
}

fn form_urlencoded_object_optional_expr(
  prefix: String,
  schema_ref: SchemaRef,
  ctx: Context,
  nesting_depth: Int,
) -> String {
  let props = object_properties_from_schema_ref(schema_ref, ctx)
  let prop_names =
    props
    |> list.map(fn(prop) { "\"" <> prop.name <> "\"" })
    |> string.join(", ")
  "case form_object_present(form_body, \""
  <> prefix
  <> "\", ["
  <> prop_names
  <> "]) { True -> Some("
  <> form_urlencoded_object_constructor_expr(
    form_urlencoded_schema_ref_type_name(schema_ref),
    prefix,
    props,
    ctx,
    nesting_depth,
  )
  <> ") False -> None }"
}

fn form_urlencoded_body_constructor_expr(
  rb: spec.RequestBody,
  op_id: String,
  ctx: Context,
) -> String {
  form_urlencoded_object_constructor_expr(
    form_urlencoded_body_type_name(rb, op_id),
    "",
    form_urlencoded_body_properties(rb, ctx),
    ctx,
    0,
  )
}

fn form_urlencoded_body_has_optional_fields(
  rb: spec.RequestBody,
  ctx: Context,
) -> Bool {
  form_urlencoded_properties_have_optional_fields(
    form_urlencoded_body_properties(rb, ctx),
    ctx,
    True,
  )
}

fn form_urlencoded_body_needs_string(rb: spec.RequestBody, ctx: Context) -> Bool {
  form_urlencoded_properties_need_string(
    form_urlencoded_body_properties(rb, ctx),
    ctx,
    True,
  )
}

fn form_urlencoded_body_needs_int(rb: spec.RequestBody, ctx: Context) -> Bool {
  form_urlencoded_properties_need_int(
    form_urlencoded_body_properties(rb, ctx),
    ctx,
    True,
  )
}

fn form_urlencoded_body_needs_float(rb: spec.RequestBody, ctx: Context) -> Bool {
  form_urlencoded_properties_need_float(
    form_urlencoded_body_properties(rb, ctx),
    ctx,
    True,
  )
}

fn form_urlencoded_body_has_nested_object(
  rb: spec.RequestBody,
  ctx: Context,
) -> Bool {
  list.any(form_urlencoded_body_properties(rb, ctx), fn(prop) {
    schema_ref_resolves_to_object(prop.schema_ref, ctx)
  })
}

fn multipart_body_constructor_expr(
  rb: spec.RequestBody,
  op_id: String,
  ctx: Context,
) -> String {
  let fields =
    multipart_body_properties(rb, ctx)
    |> list.map(fn(prop) {
      let value_expr = case prop.required {
        True ->
          multipart_body_required_expr_with_schema(
            prop.name,
            Some(prop.schema_ref),
            ctx,
          )
        False ->
          multipart_body_optional_expr_with_schema(
            prop.name,
            Some(prop.schema_ref),
            ctx,
          )
      }
      prop.field_name <> ": " <> value_expr
    })
    |> string.join(", ")
  multipart_body_type_name(rb, op_id) <> "(" <> fields <> ")"
}

fn multipart_body_has_optional_fields(
  rb: spec.RequestBody,
  ctx: Context,
) -> Bool {
  list.any(multipart_body_properties(rb, ctx), fn(prop) { !prop.required })
}

fn multipart_body_needs_int(rb: spec.RequestBody, ctx: Context) -> Bool {
  list.any(multipart_body_properties(rb, ctx), fn(prop) {
    body_field_kind_needs_int(schema_ref_body_field_kind(
      Some(prop.schema_ref),
      ctx,
    ))
  })
}

fn multipart_body_needs_float(rb: spec.RequestBody, ctx: Context) -> Bool {
  list.any(multipart_body_properties(rb, ctx), fn(prop) {
    body_field_kind_needs_float(schema_ref_body_field_kind(
      Some(prop.schema_ref),
      ctx,
    ))
  })
}

fn form_urlencoded_properties_have_optional_fields(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
) -> Bool {
  list.any(props, fn(prop) {
    !prop.required
    || case
      allow_nested_objects
      && schema_ref_resolves_to_object(prop.schema_ref, ctx)
    {
      True ->
        form_urlencoded_properties_have_optional_fields(
          object_properties_from_schema_ref(prop.schema_ref, ctx),
          ctx,
          False,
        )
      False -> False
    }
  })
}

fn form_urlencoded_properties_need_string(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
) -> Bool {
  list.any(props, fn(prop) {
    query_schema_needs_string(Some(prop.schema_ref))
    || case
      allow_nested_objects
      && schema_ref_resolves_to_object(prop.schema_ref, ctx)
    {
      True ->
        form_urlencoded_properties_need_string(
          object_properties_from_schema_ref(prop.schema_ref, ctx),
          ctx,
          False,
        )
      False -> False
    }
  })
}

fn form_urlencoded_properties_need_int(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
) -> Bool {
  list.any(props, fn(prop) {
    body_field_kind_needs_int(schema_ref_body_field_kind(
      Some(prop.schema_ref),
      ctx,
    ))
    || case
      allow_nested_objects
      && schema_ref_resolves_to_object(prop.schema_ref, ctx)
    {
      True ->
        form_urlencoded_properties_need_int(
          object_properties_from_schema_ref(prop.schema_ref, ctx),
          ctx,
          False,
        )
      False -> False
    }
  })
}

fn form_urlencoded_properties_need_float(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
) -> Bool {
  list.any(props, fn(prop) {
    body_field_kind_needs_float(schema_ref_body_field_kind(
      Some(prop.schema_ref),
      ctx,
    ))
    || case
      allow_nested_objects
      && schema_ref_resolves_to_object(prop.schema_ref, ctx)
    {
      True ->
        form_urlencoded_properties_need_float(
          object_properties_from_schema_ref(prop.schema_ref, ctx),
          ctx,
          False,
        )
      False -> False
    }
  })
}

fn query_schema_needs_string(schema_ref: Option(SchemaRef)) -> Bool {
  case schema_ref {
    Some(Inline(schema.ArraySchema(..))) -> True
    Some(Inline(schema.BooleanSchema(..))) -> True
    _ -> False
  }
}

fn query_schema_needs_int(schema_ref: Option(SchemaRef)) -> Bool {
  case schema_ref {
    Some(Inline(schema.IntegerSchema(..))) -> True
    Some(Inline(schema.ArraySchema(items: Inline(schema.IntegerSchema(..)), ..))) ->
      True
    _ -> False
  }
}

fn query_schema_needs_float(schema_ref: Option(SchemaRef)) -> Bool {
  case schema_ref {
    Some(Inline(schema.NumberSchema(..))) -> True
    Some(Inline(schema.ArraySchema(items: Inline(schema.NumberSchema(..)), ..))) ->
      True
    _ -> False
  }
}

fn form_body_required_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  let base =
    "{ let assert Ok([v, ..]) = dict.get(form_body, \"" <> key <> "\") v }"
  case schema_ref_body_field_kind(schema_ref, ctx) {
    BodyFieldStringArray ->
      "{ let assert Ok(vs) = dict.get(form_body, \""
      <> key
      <> "\") list.map(vs, fn(item) { string.trim(item) }) }"
    BodyFieldIntArray ->
      "{ let assert Ok(vs) = dict.get(form_body, \""
      <> key
      <> "\") list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n }) }"
    BodyFieldFloatArray ->
      "{ let assert Ok(vs) = dict.get(form_body, \""
      <> key
      <> "\") list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n }) }"
    BodyFieldBoolArray ->
      "{ let assert Ok(vs) = dict.get(form_body, \""
      <> key
      <> "\") list.map(vs, fn(item) { let v = string.trim(item) "
      <> bool_parse_expr
      <> " }) }"
    BodyFieldInt ->
      "{ let assert Ok([v, ..]) = dict.get(form_body, \""
      <> key
      <> "\") let assert Ok(n) = int.parse(v) n }"
    BodyFieldFloat ->
      "{ let assert Ok([v, ..]) = dict.get(form_body, \""
      <> key
      <> "\") let assert Ok(n) = float.parse(v) n }"
    BodyFieldBool ->
      "{ let assert Ok([v, ..]) = dict.get(form_body, \""
      <> key
      <> "\") "
      <> bool_parse_expr
      <> " }"
    _ -> base
  }
}

fn form_body_optional_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  case schema_ref_body_field_kind(schema_ref, ctx) {
    BodyFieldStringArray ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { string.trim(item) })) _ -> None }"
    BodyFieldIntArray ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n })) _ -> None }"
    BodyFieldFloatArray ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n })) _ -> None }"
    BodyFieldBoolArray ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let v = string.trim(item) "
      <> bool_parse_expr
      <> " })) _ -> None }"
    BodyFieldInt ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    BodyFieldFloat ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    BodyFieldBool ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> Some("
      <> bool_parse_expr
      <> ") _ -> None }"
    _ ->
      "case dict.get(form_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> Some(v) _ -> None }"
  }
}

fn multipart_body_required_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  let base =
    "{ let assert Ok([v, ..]) = dict.get(multipart_body, \"" <> key <> "\") v }"
  case schema_ref_body_field_kind(schema_ref, ctx) {
    BodyFieldInt ->
      "{ let assert Ok([v, ..]) = dict.get(multipart_body, \""
      <> key
      <> "\") let assert Ok(n) = int.parse(v) n }"
    BodyFieldFloat ->
      "{ let assert Ok([v, ..]) = dict.get(multipart_body, \""
      <> key
      <> "\") let assert Ok(n) = float.parse(v) n }"
    BodyFieldBool ->
      "{ let assert Ok([v, ..]) = dict.get(multipart_body, \""
      <> key
      <> "\") "
      <> bool_parse_expr
      <> " }"
    BodyFieldStringArray ->
      "{ let assert Ok(vs) = dict.get(multipart_body, \"" <> key <> "\") vs }"
    BodyFieldIntArray ->
      "{ let assert Ok(vs) = dict.get(multipart_body, \""
      <> key
      <> "\") list.map(vs, fn(item) { let assert Ok(n) = int.parse(item) n }) }"
    BodyFieldFloatArray ->
      "{ let assert Ok(vs) = dict.get(multipart_body, \""
      <> key
      <> "\") list.map(vs, fn(item) { let assert Ok(n) = float.parse(item) n }) }"
    BodyFieldBoolArray ->
      "{ let assert Ok(vs) = dict.get(multipart_body, \""
      <> key
      <> "\") list.map(vs, fn(item) { let v = item "
      <> bool_parse_expr
      <> " }) }"
    _ -> base
  }
}

fn multipart_body_optional_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  case schema_ref_body_field_kind(schema_ref, ctx) {
    BodyFieldInt ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    BodyFieldFloat ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    BodyFieldBool ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> Some("
      <> bool_parse_expr
      <> ") _ -> None }"
    BodyFieldStringArray ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(vs) _ -> None }"
    BodyFieldIntArray ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let assert Ok(n) = int.parse(item) n })) _ -> None }"
    BodyFieldFloatArray ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let assert Ok(n) = float.parse(item) n })) _ -> None }"
    BodyFieldBoolArray ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let v = item "
      <> bool_parse_expr
      <> " })) _ -> None }"
    _ ->
      "case dict.get(multipart_body, \""
      <> key
      <> "\") { Ok([v, ..]) -> Some(v) _ -> None }"
  }
}

/// Generate expression for a required header parameter.
fn header_required_expr(key: String, param: spec.Parameter) -> String {
  case param.schema {
    Some(Inline(schema.ArraySchema(items: Inline(schema.StringSchema(..)), ..))) ->
      "{ let assert Ok(v) = dict.get(headers, \""
      <> key
      <> "\") list.map(string.split(v, \",\"), fn(item) { string.trim(item) }) }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.IntegerSchema(..)), ..))) ->
      "{ let assert Ok(v) = dict.get(headers, \""
      <> key
      <> "\") list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n }) }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.NumberSchema(..)), ..))) ->
      "{ let assert Ok(v) = dict.get(headers, \""
      <> key
      <> "\") list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n }) }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.BooleanSchema(..)), ..))) ->
      "{ let assert Ok(v) = dict.get(headers, \""
      <> key
      <> "\") list.map(string.split(v, \",\"), fn(item) { let v = string.trim(item) "
      <> bool_parse_expr
      <> " }) }"
    Some(Inline(schema.IntegerSchema(..))) ->
      "{ let assert Ok(v) = dict.get(headers, \""
      <> key
      <> "\") let assert Ok(n) = int.parse(v) n }"
    Some(Inline(schema.NumberSchema(..))) ->
      "{ let assert Ok(v) = dict.get(headers, \""
      <> key
      <> "\") let assert Ok(n) = float.parse(v) n }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "{ let assert Ok(v) = dict.get(headers, \""
      <> key
      <> "\") "
      <> bool_parse_expr
      <> " }"
    _ -> "{ let assert Ok(v) = dict.get(headers, \"" <> key <> "\") v }"
  }
}

/// Generate expression for an optional header parameter.
fn header_optional_expr(key: String, param: spec.Parameter) -> String {
  case param.schema {
    Some(Inline(schema.ArraySchema(items: Inline(schema.StringSchema(..)), ..))) ->
      "case dict.get(headers, \""
      <> key
      <> "\") { Ok(v) -> Some(list.map(string.split(v, \",\"), fn(item) { string.trim(item) })) _ -> None }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.IntegerSchema(..)), ..))) ->
      "case dict.get(headers, \""
      <> key
      <> "\") { Ok(v) -> Some(list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n })) _ -> None }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.NumberSchema(..)), ..))) ->
      "case dict.get(headers, \""
      <> key
      <> "\") { Ok(v) -> Some(list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = float.parse(trimmed) n })) _ -> None }"
    Some(Inline(schema.ArraySchema(items: Inline(schema.BooleanSchema(..)), ..))) ->
      "case dict.get(headers, \""
      <> key
      <> "\") { Ok(v) -> Some(list.map(string.split(v, \",\"), fn(item) { let v = string.trim(item) "
      <> bool_parse_expr
      <> " })) _ -> None }"
    Some(Inline(schema.IntegerSchema(..))) ->
      "case dict.get(headers, \""
      <> key
      <> "\") { Ok(v) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    Some(Inline(schema.NumberSchema(..))) ->
      "case dict.get(headers, \""
      <> key
      <> "\") { Ok(v) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "case dict.get(headers, \""
      <> key
      <> "\") { Ok(v) -> Some("
      <> bool_parse_expr
      <> ") _ -> None }"
    _ ->
      "case dict.get(headers, \"" <> key <> "\") { Ok(v) -> Some(v) _ -> None }"
  }
}

/// Generate expression for a required cookie parameter.
fn cookie_required_expr(key: String, param: spec.Parameter) -> String {
  case param.schema {
    Some(Inline(schema.IntegerSchema(..))) ->
      "{ let assert Ok(v) = cookie_lookup(headers, \""
      <> key
      <> "\") let assert Ok(n) = int.parse(v) n }"
    Some(Inline(schema.NumberSchema(..))) ->
      "{ let assert Ok(v) = cookie_lookup(headers, \""
      <> key
      <> "\") let assert Ok(n) = float.parse(v) n }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "{ let assert Ok(v) = cookie_lookup(headers, \""
      <> key
      <> "\") "
      <> bool_parse_expr
      <> " }"
    _ -> "{ let assert Ok(v) = cookie_lookup(headers, \"" <> key <> "\") v }"
  }
}

/// Generate expression for an optional cookie parameter.
fn cookie_optional_expr(key: String, param: spec.Parameter) -> String {
  case param.schema {
    Some(Inline(schema.IntegerSchema(..))) ->
      "case cookie_lookup(headers, \""
      <> key
      <> "\") { Ok(v) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } Error(_) -> None }"
    Some(Inline(schema.NumberSchema(..))) ->
      "case cookie_lookup(headers, \""
      <> key
      <> "\") { Ok(v) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } Error(_) -> None }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "case cookie_lookup(headers, \""
      <> key
      <> "\") { Ok(v) -> Some("
      <> bool_parse_expr
      <> ") Error(_) -> None }"
    _ ->
      "case cookie_lookup(headers, \""
      <> key
      <> "\") { Ok(v) -> Some(v) Error(_) -> None }"
  }
}

/// Generate the body decode expression for a request body.
fn generate_body_decode_expr(
  rb: spec.RequestBody,
  op_id: String,
  ctx: Context,
) -> String {
  let content_entries = dict.to_list(rb.content)
  case content_entries {
    [#("application/json", media_type)] -> {
      let decode_fn = case media_type.schema {
        Some(Reference(name:, ..)) ->
          "decode.decode_" <> naming.to_snake_case(name) <> "(body)"
        _ ->
          "decode.decode_"
          <> naming.to_snake_case(op_id)
          <> "_request_body(body)"
      }
      case rb.required {
        True -> "{ let assert Ok(decoded) = " <> decode_fn <> " decoded }"
        False ->
          "case body { \"\" -> None _ -> { case "
          <> decode_fn
          <> " { Ok(decoded) -> Some(decoded) _ -> None } } }"
      }
    }
    [#("application/x-www-form-urlencoded", _media_type)] -> {
      let body_expr = form_urlencoded_body_constructor_expr(rb, op_id, ctx)
      case rb.required {
        True -> body_expr
        False -> "case body { \"\" -> None _ -> Some(" <> body_expr <> ") }"
      }
    }
    [#("multipart/form-data", _media_type)] -> {
      let body_expr = multipart_body_constructor_expr(rb, op_id, ctx)
      case rb.required {
        True -> body_expr
        False -> "case body { \"\" -> None _ -> Some(" <> body_expr <> ") }"
      }
    }
    _ -> {
      case rb.required {
        True -> "body"
        False -> "case body { \"\" -> None _ -> Some(body) }"
      }
    }
  }
}

/// Generate code to convert a handler response to ServerResponse.
fn generate_response_conversion(
  sb: se.StringBuilder,
  response_type_name: String,
  operation: spec.Operation,
  ctx: Context,
) -> se.StringBuilder {
  let responses = http.sort_response_entries(dict.to_list(operation.responses))

  case list.is_empty(responses) {
    True ->
      sb
      |> se.indent(3, "ServerResponse(status: 200, body: \"\", headers: [])")
    False -> {
      let sb = sb |> se.indent(3, "case response {")

      let sb =
        list.fold(responses, sb, fn(sb, entry) {
          let #(status_code, response) = entry
          let variant_name =
            response_type_name <> http.status_code_suffix(status_code)
          let status_int = http.status_code_to_int(status_code)
          let content_entries = dict.to_list(response.content)

          case content_entries {
            [] ->
              // No content body variant
              sb
              |> se.indent(
                4,
                "response_types."
                  <> variant_name
                  <> " -> ServerResponse(status: "
                  <> status_int
                  <> ", body: \"\", headers: [])",
              )
            [#(media_type_name, media_type)] ->
              case media_type_name {
                "application/json" ->
                  case media_type.schema {
                    Some(_) -> {
                      let encode_fn =
                        get_encode_function(media_type.schema, ctx)
                      sb
                      |> se.indent(
                        4,
                        "response_types."
                          <> variant_name
                          <> "(data) -> ServerResponse(status: "
                          <> status_int
                          <> ", body: json.to_string("
                          <> encode_fn
                          <> "(data)), headers: [#(\"content-type\", \"application/json\")])",
                      )
                    }
                    None ->
                      sb
                      |> se.indent(
                        4,
                        "response_types."
                          <> variant_name
                          <> " -> ServerResponse(status: "
                          <> status_int
                          <> ", body: \"\", headers: [])",
                      )
                  }
                "text/plain"
                | "application/xml"
                | "text/xml"
                | "application/octet-stream" ->
                  case media_type.schema {
                    Some(_) ->
                      sb
                      |> se.indent(
                        4,
                        "response_types."
                          <> variant_name
                          <> "(data) -> ServerResponse(status: "
                          <> status_int
                          <> ", body: data, headers: [#(\"content-type\", \""
                          <> media_type_name
                          <> "\")])",
                      )
                    None ->
                      sb
                      |> se.indent(
                        4,
                        "response_types."
                          <> variant_name
                          <> " -> ServerResponse(status: "
                          <> status_int
                          <> ", body: \"\", headers: [])",
                      )
                  }
                _ ->
                  case media_type.schema {
                    Some(_) -> {
                      let encode_fn =
                        get_encode_function(media_type.schema, ctx)
                      sb
                      |> se.indent(
                        4,
                        "response_types."
                          <> variant_name
                          <> "(data) -> ServerResponse(status: "
                          <> status_int
                          <> ", body: json.to_string("
                          <> encode_fn
                          <> "(data)), headers: [#(\"content-type\", \""
                          <> media_type_name
                          <> "\")])",
                      )
                    }
                    None ->
                      sb
                      |> se.indent(
                        4,
                        "response_types."
                          <> variant_name
                          <> " -> ServerResponse(status: "
                          <> status_int
                          <> ", body: \"\", headers: [])",
                      )
                  }
              }
            // Multiple content types: variant wraps String.
            // Use the first content type as default content-type header.
            [#(first_media_type, _), _, ..] ->
              sb
              |> se.indent(
                4,
                "response_types."
                  <> variant_name
                  <> "(data) -> ServerResponse(status: "
                  <> status_int
                  <> ", body: data, headers: [#(\"content-type\", \""
                  <> first_media_type
                  <> "\")])",
              )
          }
        })

      sb |> se.indent(3, "}")
    }
  }
}

/// Get the encode function name for a schema reference.
fn get_encode_function(
  schema_ref: option.Option(schema.SchemaRef),
  _ctx: Context,
) -> String {
  case schema_ref {
    Some(Reference(name:, ..)) -> {
      "encode.encode_" <> naming.to_snake_case(name) <> "_json"
    }
    Some(Inline(schema.ArraySchema(items:, ..))) -> {
      case items {
        Reference(name:, ..) ->
          "fn(items) { json.array(items, encode.encode_"
          <> naming.to_snake_case(name)
          <> "_json) }"
        _ -> "json.string"
      }
    }
    Some(Inline(schema.StringSchema(..))) -> "json.string"
    Some(Inline(schema.IntegerSchema(..))) -> "json.int"
    Some(Inline(schema.NumberSchema(..))) -> "json.float"
    Some(Inline(schema.BooleanSchema(..))) -> "json.bool"
    _ -> "json.string"
  }
}

/// Convert an OpenAPI path to a Gleam pattern match expression.
fn path_to_pattern(path: String) -> String {
  let segments =
    path
    |> string.split("/")
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
  |> string.replace("{", "")
  |> string.replace("}", "")
}
