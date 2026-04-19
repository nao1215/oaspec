import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/guards
import oaspec/codegen/import_analysis
import oaspec/codegen/server_request_decode as decode_helpers
import oaspec/config
import oaspec/openapi/operations
import oaspec/openapi/schema.{Inline, Reference}
import oaspec/openapi/spec.{type Resolved, Value}
import oaspec/util/content_type
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
      config.package(context.config(ctx)) <> "/request_types",
      config.package(context.config(ctx)) <> "/response_types",
    ])

  let sb =
    list.fold(operations, sb, fn(sb, op) {
      let #(op_id, operation, _path, _method) = op
      generate_handler(sb, op_id, operation, ctx)
    })

  // Callbacks are parsed and resolved but NOT emitted as handler stubs.
  // The previous stubs had the shape `fn(...) -> String` with no request
  // type, no response type, and no execution path — more misleading than
  // useful. Callback support is now documented as parsed-but-not-codegen
  // until a typed codegen story exists (see issue #117).
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
  // Whether any deep object param has additional_properties (Untyped or Typed)
  let has_deep_object_with_ap =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            decode_helpers.is_deep_object_param(p, ctx)
            && decode_helpers.deep_object_has_additional_properties(p, ctx)
          _ -> False
        }
      })
    })
  // Whether any optional deep object param does NOT use deep_object_present_any.
  // deep_object_present_any is only used for Untyped AP; all other optional
  // deep object params (no AP or Typed AP) use deep_object_present.
  let needs_deep_object_present =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            decode_helpers.is_deep_object_param(p, ctx)
            && !p.required
            && !decode_helpers.deep_object_has_untyped_additional_properties(
              p,
              ctx,
            )
          _ -> False
        }
      })
    })
  // Whether any deep object param has Untyped additional_properties (needs dynamic import)
  let has_deep_object_untyped_ap =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            decode_helpers.is_deep_object_param(p, ctx)
            && decode_helpers.deep_object_has_untyped_additional_properties(
              p,
              ctx,
            )
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

  // Determine which imports are needed based on operations.
  // Dict is always needed for the route signature, so we skip a conditional
  // check here.

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
    || has_deep_object_with_ap
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
                case content_type.is_json_compatible(media_type_name) {
                  True ->
                    case media_type.schema {
                      Some(_) -> True
                      None -> False
                    }
                  False -> False
                }
              _ -> False
            }
          }
          _ -> False
        }
      })
    })

  let needs_decode =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(Value(rb)) ->
          list.any(dict.to_list(rb.content), fn(entry) {
            let #(content_type, _) = entry
            content_type.is_json_compatible(content_type)
          })
        _ -> False
      }
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
  // json is also needed when guard validation is enabled (for 422 error responses)
  let needs_json_for_guards =
    config.validate(context.config(ctx))
    && list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      operation_needs_guard_validation(operation, ctx)
    })
  let std_imports = case needs_json || needs_json_for_guards {
    True -> list.append(std_imports, ["gleam/json"])
    False -> std_imports
  }
  let std_imports = case needs_string {
    True -> list.append(std_imports, ["gleam/string"])
    False -> std_imports
  }
  let std_imports = case has_deep_object_untyped_ap {
    True -> list.append(std_imports, ["gleam/dynamic"])
    False -> std_imports
  }

  let pkg_imports = [config.package(context.config(ctx)) <> "/handlers"]
  let pkg_imports = case
    has_deep_object || has_form_urlencoded_body || has_multipart_body
  {
    True ->
      list.append(pkg_imports, [config.package(context.config(ctx)) <> "/types"])
    False -> pkg_imports
  }
  let pkg_imports = case needs_decode {
    True ->
      list.append(pkg_imports, [
        config.package(context.config(ctx)) <> "/decode",
      ])
    False -> pkg_imports
  }
  let pkg_imports = case needs_encode {
    True ->
      list.append(pkg_imports, [
        config.package(context.config(ctx)) <> "/encode",
      ])
    False -> pkg_imports
  }
  let pkg_imports = case has_params_ops {
    True ->
      list.append(pkg_imports, [
        config.package(context.config(ctx)) <> "/request_types",
        config.package(context.config(ctx)) <> "/response_types",
      ])
    False ->
      list.append(pkg_imports, [
        config.package(context.config(ctx)) <> "/response_types",
      ])
  }
  // Import guards module when validation is enabled and any operation body has validators
  let needs_guards =
    config.validate(context.config(ctx))
    && list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      operation_needs_guard_validation(operation, ctx)
    })
  let pkg_imports = case needs_guards {
    True ->
      list.append(pkg_imports, [
        config.package(context.config(ctx)) <> "/guards",
      ])
    False -> pkg_imports
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

  // deep_object_present: only when optional deep object params without AP exist
  let sb = case needs_deep_object_present {
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

  // deep_object_present_any and deep_object_additional_properties:
  // only when deep object params with additional_properties exist
  let sb = case has_deep_object_with_ap {
    True ->
      sb
      |> se.line(
        "fn deep_object_present_any(query: Dict(String, List(String)), prefix: String) -> Bool {",
      )
      |> se.indent(1, "let prefix_bracket = prefix <> \"[\"")
      |> se.indent(
        1,
        "dict.fold(query, False, fn(found, k, _v) { found || string.starts_with(k, prefix_bracket) })",
      )
      |> se.line("}")
      |> se.blank_line()
      |> se.line(
        "fn deep_object_additional_properties(query: Dict(String, List(String)), prefix: String, known_props: List(String)) -> Dict(String, List(String)) {",
      )
      |> se.indent(1, "let prefix_bracket = prefix <> \"[\"")
      |> se.indent(1, "let prefix_len = string.length(prefix_bracket)")
      |> se.indent(1, "dict.fold(query, dict.new(), fn(acc, k, v) {")
      |> se.indent(
        2,
        "case string.starts_with(k, prefix_bracket) && string.ends_with(k, \"]\") {",
      )
      |> se.indent(3, "True -> {")
      |> se.indent(
        4,
        "let prop = string.slice(k, prefix_len, string.length(k) - prefix_len - 1)",
      )
      |> se.indent(
        4,
        "case list.contains(known_props, prop) { True -> acc False -> dict.insert(acc, prop, v) }",
      )
      |> se.indent(3, "}")
      |> se.indent(3, "False -> acc")
      |> se.indent(2, "}")
      |> se.indent(1, "})")
      |> se.line("}")
      |> se.blank_line()
    False -> sb
  }

  // coerce_dict: type-safe identity for converting Dict value types at compile time
  // Only needed when deepObject params with Untyped additional_properties exist
  let sb = case has_deep_object_untyped_ap {
    True ->
      sb
      |> se.line("@external(erlang, \"gleam_stdlib\", \"identity\")")
      |> se.line(
        "fn coerce_dict(value: Dict(String, List(String))) -> Dict(String, dynamic.Dynamic)",
      )
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
  use <- bool.guard(used, name)
  "_" <> name
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
      // Has parameters: validate inputs, construct request, call handler
      let request_type_name = type_name <> "Request"
      generate_safe_request_and_dispatch(
        sb,
        request_type_name,
        response_type_name,
        op_id,
        fn_name,
        operation,
        path,
        ctx,
      )
    }
  }
}

/// Generate safe request construction wrapped in error handling.
/// Path parameter parsing, required query/header/cookie params, and body
/// decoding are all validated before calling the handler. Parse failures
/// return ServerResponse(status: 400) instead of crashing.
fn generate_safe_request_and_dispatch(
  sb: se.StringBuilder,
  request_type_name: String,
  response_type_name: String,
  op_id: String,
  fn_name: String,
  operation: spec.Operation(Resolved),
  _path: String,
  ctx: Context,
) -> se.StringBuilder {
  let params =
    list.filter_map(operation.parameters, fn(r) {
      case r {
        Value(p) -> Ok(p)
        _ -> Error(Nil)
      }
    })

  // Collect path params that need Result-based parsing (int, float)
  let path_params_needing_parse =
    list.filter(params, fn(p) {
      p.in_ == spec.InPath && decode_helpers.param_needs_result_unwrap(p)
    })

  // Check if the request body needs safe decoding (required JSON body)
  let needs_body_guard = case operation.request_body {
    Some(Value(rb)) ->
      rb.required
      && list.any(dict.to_list(rb.content), fn(entry) {
        content_type.is_json_compatible(entry.0)
      })
    _ -> False
  }

  // Open nested case expressions for each param that needs parsing
  let sb =
    list.fold(path_params_needing_parse, sb, fn(sb, p) {
      let var_name = naming.to_snake_case(p.name)
      let parse_expr = decode_helpers.param_parse_expr(var_name, p)
      sb
      |> se.indent(3, "case " <> parse_expr <> " {")
      |> se.indent(4, "Ok(" <> var_name <> "_parsed) -> {")
    })

  // Determine the body schema reference name (used for decode and guard validation)
  let body_schema_ref_name = case operation.request_body {
    Some(Value(rb)) -> {
      let content_entries = dict.to_list(rb.content)
      case content_entries {
        [#(_ct_name, media_type)] ->
          case media_type.schema {
            Some(schema.Reference(name:, ..)) -> Some(name)
            _ -> None
          }
        _ -> None
      }
    }
    _ -> None
  }

  // Check if guard validation should be emitted for this body
  let needs_guard_validation =
    config.validate(context.config(ctx))
    && needs_body_guard
    && {
      case body_schema_ref_name {
        Some(name) -> guards.schema_has_validator(name, ctx)
        None -> False
      }
    }

  // Open body decode guard if needed
  let sb = case needs_body_guard, operation.request_body {
    True, Some(Value(rb)) -> {
      let content_entries = dict.to_list(rb.content)
      case content_entries {
        [#(_ct_name, media_type)] ->
          case media_type.schema {
            Some(schema.Reference(name:, ..)) -> {
              let decode_fn =
                "decode.decode_" <> naming.to_snake_case(name) <> "(body)"
              sb
              |> se.indent(3, "case " <> decode_fn <> " {")
              |> se.indent(4, "Ok(decoded_body) -> {")
            }
            _ -> {
              let decode_fn =
                "decode.decode_"
                <> naming.to_snake_case(op_id)
                <> "_request_body(body)"
              sb
              |> se.indent(3, "case " <> decode_fn <> " {")
              |> se.indent(4, "Ok(decoded_body) -> {")
            }
          }
        _ -> sb
      }
    }
    _, _ -> sb
  }

  // Open guard validation if needed (after body decode succeeds)
  let sb = case needs_guard_validation, body_schema_ref_name {
    True, Some(name) -> {
      let validate_fn =
        "guards.validate_" <> naming.to_snake_case(name) <> "(decoded_body)"
      sb
      |> se.indent(3, "case " <> validate_fn <> " {")
      |> se.indent(4, "Ok(decoded_body) -> {")
    }
    _, _ -> sb
  }

  // Prepare form/multipart body if needed
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
    list.fold(params, sb, fn(sb, param) {
      let field_name = naming.to_snake_case(param.name)
      let trailing = ","
      let value_expr = case param.in_ {
        spec.InPath -> {
          // Use the parsed variable if it needed Result unwrapping
          case decode_helpers.param_needs_result_unwrap(param) {
            True -> naming.to_snake_case(param.name) <> "_parsed"
            False -> {
              let var_name = naming.to_snake_case(param.name)
              decode_helpers.param_parse_expr(var_name, param)
            }
          }
        }
        spec.InQuery -> {
          let key = param.name
          case decode_helpers.is_deep_object_param(param, ctx), param.required {
            True, True ->
              decode_helpers.deep_object_required_expr(key, param, op_id, ctx)
            True, False ->
              decode_helpers.deep_object_optional_expr(key, param, op_id, ctx)
            False, True -> decode_helpers.query_required_expr(key, param)
            False, False -> decode_helpers.query_optional_expr(key, param)
          }
        }
        spec.InHeader -> {
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
    })

  // Add body field
  let sb = case needs_body_guard {
    True -> sb |> se.indent(4, "body: decoded_body,")
    False ->
      case operation.request_body {
        Some(Value(rb)) -> {
          let body_expr =
            decode_helpers.generate_body_decode_expr(rb, op_id, ctx)
          sb |> se.indent(4, "body: " <> body_expr <> ",")
        }
        _ -> sb
      }
  }

  let sb = sb |> se.indent(3, ")")

  // Call handler and convert response
  let sb =
    sb
    |> se.indent(3, "let response = handlers." <> fn_name <> "(request)")
    |> generate_response_conversion(response_type_name, operation, ctx)

  // Close guard validation (returns 422 with error details)
  let sb = case needs_guard_validation {
    True ->
      sb
      |> se.indent(4, "}")
      |> se.indent(
        4,
        "Error(errors) -> ServerResponse(status: 422, body: json.to_string(json.array(errors, json.string)), headers: [#(\"content-type\", \"application/json\")])",
      )
      |> se.indent(3, "}")
    False -> sb
  }

  // Close body decode guard
  let sb = case needs_body_guard {
    True ->
      sb
      |> se.indent(4, "}")
      |> se.indent(
        4,
        "Error(_) -> ServerResponse(status: 400, body: \"Bad Request\", headers: [])",
      )
      |> se.indent(3, "}")
    False -> sb
  }

  // Close path param case expressions (in reverse order)
  list.fold(path_params_needing_parse, sb, fn(sb, _p) {
    sb
    |> se.indent(4, "}")
    |> se.indent(
      4,
      "Error(_) -> ServerResponse(status: 400, body: \"Bad Request\", headers: [])",
    )
    |> se.indent(3, "}")
  })
}

/// Check if an operation's request body needs guard validation.
/// True when the body is required, JSON-compatible, references a named schema,
/// and that schema has constraint-based validators.
fn operation_needs_guard_validation(
  operation: spec.Operation(Resolved),
  ctx: Context,
) -> Bool {
  case operation.request_body {
    Some(Value(rb)) ->
      rb.required
      && {
        let content_entries = dict.to_list(rb.content)
        list.any(content_entries, fn(entry) {
          content_type.is_json_compatible(entry.0)
        })
        && case content_entries {
          [#(_, mt)] ->
            case mt.schema {
              Some(schema.Reference(name:, ..)) ->
                guards.schema_has_validator(name, ctx)
              _ -> False
            }
          _ -> False
        }
      }
    _ -> False
  }
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
                  case content_type.from_string(media_type_name) {
                    content_type.ApplicationJson ->
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
                    content_type.TextPlain
                    | content_type.ApplicationXml
                    | content_type.TextXml
                    | content_type.ApplicationOctetStream ->
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
