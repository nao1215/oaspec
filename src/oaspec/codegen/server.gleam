import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/types as type_gen
import oaspec/openapi/schema.{Inline, Reference}
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
        case p.schema {
          Some(Inline(schema.IntegerSchema(..))) -> True
          _ -> False
        }
      })
    })

  let needs_float =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(p) {
        case p.schema {
          Some(Inline(schema.NumberSchema(..))) -> True
          _ -> False
        }
      })
    })

  let needs_string =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(p) {
        case p.in_, p.schema {
          spec.InCookie, _ -> True
          _, Some(Inline(schema.BooleanSchema(..))) -> True
          _, _ -> False
        }
      })
    })

  let needs_cookie_lookup =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(p) { p.in_ == spec.InCookie })
    })

  let needs_list_import = needs_cookie_lookup
  let needs_uri_import = needs_cookie_lookup

  let needs_option =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      let has_optional_params =
        list.any(operation.parameters, fn(p) { !p.required })
      let has_optional_body = case operation.request_body {
        Some(rb) -> !rb.required
        None -> False
      }
      has_optional_params || has_optional_body
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
    list.any(operations, fn(op) {
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

  // Generate route function
  let sb =
    sb
    |> se.doc_comment("Route an incoming request to the appropriate handler.")
    |> se.line(
      "pub fn route(method: String, path: List(String), "
      <> route_arg_name("query", uses_query)
      <> ": Dict(String, String), "
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
  |> se.line("fn cookie_lookup(headers: Dict(String, String), key: String) -> Result(String, Nil) {")
  |> se.indent(1, "case dict.get(headers, \"cookie\") {")
  |> se.indent(2, "Ok(raw) ->")
  |> se.indent(3, "list.find_map(string.split(raw, \";\"), fn(part) {")
  |> se.indent(4, "let trimmed = string.trim(part)")
  |> se.indent(4, "case string.split_once(trimmed, on: \"=\") {")
  |> se.indent(5, "Ok(#(cookie_key, cookie_value)) ->")
  |> se.indent(6, "case string.trim(cookie_key) == key {")
  |> se.indent(
    7,
    "True -> uri.percent_decode(string.trim(cookie_value))",
  )
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
  path: String,
  _ctx: Context,
) -> se.StringBuilder {
  // Build path segment index map
  let path_segments =
    path
    |> string.split("/")
    |> list.filter(fn(s) { s != "" })

  let path_param_indices =
    list.index_map(path_segments, fn(seg, idx) { #(seg, idx) })
    |> list.filter(fn(entry) {
      let #(seg, _) = entry
      is_path_param(seg)
    })
    |> list.map(fn(entry) {
      let #(seg, idx) = entry
      let name = extract_param_name(seg)
      #(name, idx)
    })

  // Extract path parameters first
  let sb =
    list.fold(path_param_indices, sb, fn(sb, entry) {
      let #(name, _idx) = entry
      let var_name = naming.to_snake_case(name) <> "_param"
      // The path pattern already binds path params as variables
      // We just need to reference the bound variable from the pattern
      let _ = var_name
      sb
    })

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
          case param.required {
            True -> query_required_expr(key, param)
            False -> query_optional_expr(key, param)
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
      let body_expr = generate_body_decode_expr(rb, op_id)
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
  let base = "{ let assert Ok(v) = dict.get(query, \"" <> key <> "\") v }"
  case param.schema {
    Some(Inline(schema.IntegerSchema(..))) ->
      "{ let assert Ok(v) = dict.get(query, \""
      <> key
      <> "\") let assert Ok(n) = int.parse(v) n }"
    Some(Inline(schema.NumberSchema(..))) ->
      "{ let assert Ok(v) = dict.get(query, \""
      <> key
      <> "\") let assert Ok(n) = float.parse(v) n }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "{ let assert Ok(v) = dict.get(query, \""
      <> key
      <> "\") "
      <> bool_parse_expr
      <> " }"
    _ -> base
  }
}

/// Generate expression for an optional query parameter.
fn query_optional_expr(key: String, param: spec.Parameter) -> String {
  case param.schema {
    Some(Inline(schema.IntegerSchema(..))) ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok(v) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    Some(Inline(schema.NumberSchema(..))) ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok(v) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    Some(Inline(schema.BooleanSchema(..))) ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok(v) -> Some("
      <> bool_parse_expr
      <> ") _ -> None }"
    _ ->
      "case dict.get(query, \"" <> key <> "\") { Ok(v) -> Some(v) _ -> None }"
  }
}

/// Generate expression for a required header parameter.
fn header_required_expr(key: String, param: spec.Parameter) -> String {
  case param.schema {
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
fn generate_body_decode_expr(rb: spec.RequestBody, op_id: String) -> String {
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
            // Multiple content types: variant wraps String
            [_, _, ..] ->
              sb
              |> se.indent(
                4,
                "response_types."
                  <> variant_name
                  <> "(data) -> ServerResponse(status: "
                  <> status_int
                  <> ", body: data, headers: [])",
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
