import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/import_analysis
import oaspec/codegen/ir_build
import oaspec/codegen/server_request_decode as decode_helpers
import oaspec/openapi/operations
import oaspec/openapi/schema.{Inline, Reference}
import oaspec/openapi/spec.{type Resolved, Value}
import oaspec/util/http
import oaspec/util/naming
import oaspec/util/string_extra as se

/// Generate server stub files.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let operations = operations.collect_operations(ctx)
  let handlers_content = generate_handlers(ctx, operations)
  let router_content = generate_router(ctx, operations)

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
fn generate_handlers(
  ctx: Context,
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> String {
  let sb =
    se.file_header(context.version)
    |> se.imports([
      ctx.config.package <> "/request_types",
      ctx.config.package <> "/response_types",
    ])

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
  operation: spec.Operation(Resolved),
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
  |> se.indent(1, "panic as \"unimplemented: " <> fn_name <> "\"")
  |> se.line("}")
  |> se.blank_line()
}

/// Generate callback handler stubs for an operation's callbacks.
fn generate_callback_handlers(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation(Resolved),
) -> se.StringBuilder {
  let callbacks = ir_build.sorted_entries(operation.callbacks)
  list.fold(callbacks, sb, fn(sb, entry) {
    let #(callback_name, callback) = entry
    let callback_entries = ir_build.sorted_entries(callback.entries)
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
      |> se.indent(1, "panic as \"unimplemented: " <> fn_name <> "\"")
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
fn generate_router(
  ctx: Context,
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> String {
  let has_deep_object =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) -> decode_helpers.is_deep_object_param(p, ctx)
          _ -> False
        }
      })
    })
  let has_form_urlencoded_body =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      decode_helpers.operation_uses_form_urlencoded_body(operation)
    })
  let has_multipart_body =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      decode_helpers.operation_uses_multipart_body(operation)
    })
  let has_nested_form_urlencoded_body =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(Value(rb)) ->
          decode_helpers.form_urlencoded_body_has_nested_object(rb, ctx)
        _ -> False
      }
    })

  // Determine which imports are needed based on operations
  let needs_dict =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      let has_query =
        list.any(operation.parameters, fn(ref_p) {
          case ref_p {
            Value(p) -> p.in_ == spec.InQuery
            _ -> False
          }
        })
      let has_header =
        list.any(operation.parameters, fn(ref_p) {
          case ref_p {
            Value(p) -> p.in_ == spec.InHeader
            _ -> False
          }
        })
      has_query || has_header
    })

  let needs_int =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            decode_helpers.query_schema_needs_int(spec.parameter_schema(p))
            || decode_helpers.deep_object_param_needs_int(p, ctx)
          _ -> False
        }
      })
      || case operation.request_body {
        Some(Value(rb)) ->
          decode_helpers.form_urlencoded_body_needs_int(rb, ctx)
        _ -> False
      }
      || case operation.request_body {
        Some(Value(rb)) -> decode_helpers.multipart_body_needs_int(rb, ctx)
        _ -> False
      }
    })

  let needs_float =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            decode_helpers.query_schema_needs_float(spec.parameter_schema(p))
            || decode_helpers.deep_object_param_needs_float(p, ctx)
          _ -> False
        }
      })
      || case operation.request_body {
        Some(Value(rb)) ->
          decode_helpers.form_urlencoded_body_needs_float(rb, ctx)
        _ -> False
      }
      || case operation.request_body {
        Some(Value(rb)) -> decode_helpers.multipart_body_needs_float(rb, ctx)
        _ -> False
      }
    })

  let needs_string =
    has_form_urlencoded_body
    || has_multipart_body
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            case p.in_ {
              spec.InCookie -> True
              spec.InQuery | spec.InHeader ->
                decode_helpers.query_schema_needs_string(spec.parameter_schema(
                  p,
                ))
                || decode_helpers.deep_object_param_needs_string(p, ctx)
              spec.InPath ->
                decode_helpers.query_schema_needs_string(spec.parameter_schema(
                  p,
                ))
            }
          _ -> False
        }
      })
      || case operation.request_body {
        Some(Value(rb)) ->
          decode_helpers.form_urlencoded_body_needs_string(rb, ctx)
        _ -> False
      }
    })

  let needs_cookie_lookup =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) -> p.in_ == spec.InCookie
          _ -> False
        }
      })
    })

  let needs_list_import =
    needs_cookie_lookup
    || has_deep_object
    || has_form_urlencoded_body
    || has_multipart_body
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            case p.in_, spec.parameter_schema(p) {
              spec.InQuery, Some(Inline(schema.ArraySchema(..))) -> True
              spec.InHeader, Some(Inline(schema.ArraySchema(..))) -> True
              _, _ -> False
            }
          _ -> False
        }
      })
    })
  let needs_uri_import = needs_cookie_lookup || has_form_urlencoded_body

  let needs_option =
    import_analysis.operations_have_optional_params(operations)
    || import_analysis.operations_have_optional_body(operations)
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      let has_optional_deep_object_fields =
        list.any(operation.parameters, fn(ref_p) {
          case ref_p {
            Value(p) ->
              decode_helpers.deep_object_param_has_optional_fields(p, ctx)
            _ -> False
          }
        })
      let has_optional_form_urlencoded_fields = case operation.request_body {
        Some(Value(rb)) ->
          decode_helpers.form_urlencoded_body_has_optional_fields(rb, ctx)
        _ -> False
      }
      let has_optional_multipart_fields = case operation.request_body {
        Some(Value(rb)) ->
          decode_helpers.multipart_body_has_optional_fields(rb, ctx)
        _ -> False
      }
      has_optional_deep_object_fields
      || has_optional_form_urlencoded_fields
      || has_optional_multipart_fields
    })

  let needs_json =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      let responses = dict.to_list(operation.responses)
      list.any(responses, fn(entry) {
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) -> {
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
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) -> p.in_ == spec.InQuery
          _ -> False
        }
      })
    })

  let uses_headers =
    has_multipart_body
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) -> p.in_ == spec.InHeader || p.in_ == spec.InCookie
          _ -> False
        }
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
  operation: spec.Operation(Resolved),
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
  operation: spec.Operation(Resolved),
  _path: String,
  ctx: Context,
) -> se.StringBuilder {
  let sb = case operation.request_body {
    Some(Value(rb)) ->
      case decode_helpers.request_body_uses_form_urlencoded(rb) {
        True -> sb |> se.indent(3, "let form_body = parse_form_body(body)")
        False ->
          case decode_helpers.request_body_uses_multipart(rb) {
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
    list.index_fold(
      list.filter_map(operation.parameters, fn(r) {
        case r {
          Value(p) -> Ok(p)
          _ -> Error(Nil)
        }
      }),
      sb,
      fn(sb, param, _idx) {
        let field_name = naming.to_snake_case(param.name)
        let trailing = ","
        let value_expr = case param.in_ {
          spec.InPath -> {
            // Path param is already bound by the pattern match variable
            let var_name = naming.to_snake_case(param.name)
            decode_helpers.param_parse_expr(var_name, param)
          }
          spec.InQuery -> {
            let key = param.name
            case
              decode_helpers.is_deep_object_param(param, ctx),
              param.required
            {
              True, True ->
                decode_helpers.deep_object_required_expr(key, param, op_id, ctx)
              True, False ->
                decode_helpers.deep_object_optional_expr(key, param, op_id, ctx)
              False, True -> decode_helpers.query_required_expr(key, param)
              False, False -> decode_helpers.query_optional_expr(key, param)
            }
          }
          spec.InHeader -> {
            // HTTP headers are case-insensitive; client sends lowercase names.
            let key = string.lowercase(param.name)
            case param.required {
              True -> decode_helpers.header_required_expr(key, param)
              False -> decode_helpers.header_optional_expr(key, param)
            }
          }
          spec.InCookie -> {
            let key = param.name
            case param.required {
              True -> decode_helpers.cookie_required_expr(key, param)
              False -> decode_helpers.cookie_optional_expr(key, param)
            }
          }
        }
        sb |> se.indent(4, field_name <> ": " <> value_expr <> trailing)
      },
    )

  // Add body field if present
  let sb = case operation.request_body {
    Some(Value(rb)) -> {
      let body_expr = decode_helpers.generate_body_decode_expr(rb, op_id, ctx)
      sb |> se.indent(4, "body: " <> body_expr <> ",")
    }
    _ -> sb
  }

  sb |> se.indent(3, ")")
}

// Parameter parsing, body decoding, and request construction helpers
// have been extracted to server_request_decode.gleam

/// Generate code to convert a handler response to ServerResponse.
fn generate_response_conversion(
  sb: se.StringBuilder,
  response_type_name: String,
  operation: spec.Operation(Resolved),
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
          let #(status_code, ref_or) = entry
          case ref_or {
            Value(response) -> {
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
            }
            _ -> sb
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
