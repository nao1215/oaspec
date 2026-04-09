import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/schema_dispatch
import oaspec/codegen/types as type_gen
import oaspec/openapi/resolver
import oaspec/openapi/schema.{Inline, Reference}
import oaspec/openapi/spec
import oaspec/util/http
import oaspec/util/naming
import oaspec/util/string_extra as se

/// Generate client SDK files.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let client_content = generate_client(ctx)

  [
    GeneratedFile(
      path: "client.gleam",
      content: client_content,
      target: context.ClientTarget,
    ),
  ]
}

/// Generate the client module with functions for each operation.
fn generate_client(ctx: Context) -> String {
  let operations = type_gen.collect_operations(ctx)

  // Determine which imports are needed based on parameter types
  let all_params =
    list.flat_map(operations, fn(op) {
      let #(_, operation, _, _) = op
      operation.parameters
    })
  let needs_bool =
    list.any(all_params, fn(p) {
      case p.schema {
        Some(Inline(schema.BooleanSchema(..))) -> True
        _ -> False
      }
    })
  let needs_float =
    list.any(all_params, fn(p) {
      case p.schema {
        Some(Inline(schema.NumberSchema(..))) -> True
        _ -> False
      }
    })
  let has_multi_content_response =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, response) = entry
        list.length(dict.to_list(response.content)) > 1
      })
    })

  // Check if any operation has a form-urlencoded request body
  let has_form_urlencoded =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(rb) ->
          list.any(dict.to_list(rb.content), fn(ce) {
            let #(key, _) = ce
            key == "application/x-www-form-urlencoded"
          })
        _ -> False
      }
    })

  let needs_list =
    has_form_urlencoded
    || has_multi_content_response
    || list.any(all_params, fn(p) {
      case p.schema {
        Some(Inline(schema.ArraySchema(..))) -> True
        Some(Reference(..) as sr) ->
          case resolver.resolve_schema_ref(sr, ctx.spec) {
            Ok(schema.ArraySchema(..)) -> True
            _ -> False
          }
        _ -> False
      }
    })

  // dyn_decode + json needed for inline primitive response decoding
  let needs_dyn_decode =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, response) = entry
        list.any(dict.to_list(response.content), fn(ce) {
          let #(media_type_name, mt) = ce
          // text/plain responses don't need dyn_decode (body returned directly)
          case media_type_name {
            "text/plain" -> False
            _ ->
              case mt.schema {
                Some(Inline(schema.ArraySchema(items: Inline(_), ..))) -> True
                Some(Inline(schema.StringSchema(..))) -> True
                Some(Inline(schema.IntegerSchema(..))) -> True
                Some(Inline(schema.NumberSchema(..))) -> True
                Some(Inline(schema.BooleanSchema(..))) -> True
                _ -> False
              }
          }
        })
      })
    })

  // json needed for inline primitive body encoding (without dyn_decode)
  let needs_json =
    needs_dyn_decode
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(rb) ->
          list.any(dict.to_list(rb.content), fn(ce) {
            let #(_, mt) = ce
            case mt.schema {
              Some(Inline(schema.StringSchema(..))) -> True
              Some(Inline(schema.IntegerSchema(..))) -> True
              Some(Inline(schema.NumberSchema(..))) -> True
              Some(Inline(schema.BooleanSchema(..))) -> True
              _ -> False
            }
          })
        _ -> False
      }
    })

  // string module needed for path/query/cookie parameter handling,
  // security query apiKey, multipart/form-data body building,
  // form-urlencoded body building, and multi-content-type response dispatch
  let needs_string =
    has_multi_content_response
    || has_form_urlencoded
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      !list.is_empty(operation.parameters)
    })
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(rb) ->
          list.any(dict.to_list(rb.content), fn(ce) {
            let #(key, _) = ce
            key == "multipart/form-data"
          })
        _ -> False
      }
    })
    || {
      let security_schemes = case ctx.spec.components {
        Some(c) -> dict.to_list(c.security_schemes)
        _ -> []
      }
      list.any(security_schemes, fn(entry) {
        case entry {
          #(_, spec.ApiKeyScheme(in_: spec.SchemeInQuery, ..)) -> True
          _ -> False
        }
      })
    }

  // Check which modules are actually needed
  let needs_typed_schemas =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      // Need types/encode when $ref body or $ref params exist
      let has_ref_body = case operation.request_body {
        Some(rb) ->
          list.any(dict.to_list(rb.content), fn(ce) {
            let #(_, mt) = ce
            case mt.schema {
              Some(Reference(..)) -> True
              Some(Inline(schema.ObjectSchema(..))) -> True
              Some(Inline(schema.AllOfSchema(..))) -> True
              _ -> False
            }
          })
        _ -> False
      }
      let has_ref_params =
        list.any(operation.parameters, fn(p) {
          case p.schema {
            Some(Reference(..)) -> True
            _ -> False
          }
        })
      has_ref_body || has_ref_params
    })

  let needs_option =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(p) { !p.required })
    })
    || {
      let security_schemes = case ctx.spec.components {
        Some(c) -> dict.to_list(c.security_schemes)
        _ -> []
      }
      !list.is_empty(security_schemes)
    }

  let base_imports = [
    "gleam/http/request",
    "gleam/http",
    "gleam/int",
    ctx.config.package <> "/decode",
    ctx.config.package <> "/response_types",
  ]
  let base_imports = case needs_option {
    True -> ["gleam/option.{type Option, None, Some}", ..base_imports]
    False -> base_imports
  }
  let base_imports = case needs_typed_schemas {
    True ->
      list.append(
        [ctx.config.package <> "/types", ctx.config.package <> "/encode"],
        base_imports,
      )
    False -> base_imports
  }
  let base_imports = case needs_string {
    True -> ["gleam/string", ..base_imports]
    False -> base_imports
  }
  let imports = case needs_dyn_decode {
    True -> ["gleam/dynamic/decode as dyn_decode", ..base_imports]
    False -> base_imports
  }
  let imports = case needs_json {
    True -> ["gleam/json", ..imports]
    False -> imports
  }
  let imports = case needs_bool {
    True -> ["gleam/bool", ..imports]
    False -> imports
  }
  let imports = case needs_float {
    True -> ["gleam/float", ..imports]
    False -> imports
  }
  let imports = case needs_list {
    True -> ["gleam/list", ..imports]
    False -> imports
  }

  // uri module needed for percent-encoding parameter values and form-urlencoded bodies
  let needs_uri =
    has_form_urlencoded
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      !list.is_empty(operation.parameters)
    })
  let imports = case needs_uri {
    True -> ["gleam/uri", ..imports]
    False -> imports
  }

  // result module needed for cookie-based apiKey security (reading existing cookie header)
  let has_cookie_api_key = case ctx.spec.components {
    Some(c) ->
      list.any(dict.to_list(c.security_schemes), fn(entry) {
        case entry {
          #(_, spec.ApiKeyScheme(in_: spec.SchemeInCookie, ..)) -> True
          _ -> False
        }
      })
    _ -> False
  }
  let imports = case has_cookie_api_key {
    True -> {
      // Need gleam/list for list.key_find and gleam/result for result.unwrap
      let imports = case needs_list {
        True -> imports
        False -> ["gleam/list", ..imports]
      }
      ["gleam/result", ..imports]
    }
    False -> imports
  }

  let sb =
    se.file_header(context.version)
    |> se.imports(imports)

  // Collect security schemes
  let security_schemes = case ctx.spec.components {
    Some(components) -> dict.to_list(components.security_schemes)
    _ -> []
  }

  // Client configuration type
  let sb =
    sb
    |> se.doc_comment("HTTP client configuration.")
    |> se.line("pub type ClientConfig {")
    |> se.indent(1, "ClientConfig(")
    |> se.indent(2, "base_url: String,")
    |> se.indent(
      2,
      "send: fn(request.Request(String)) -> Result(ClientResponse, ClientError),",
    )

  // Add security credential fields
  let sb =
    list.fold(security_schemes, sb, fn(sb, entry) {
      let #(scheme_name, _scheme) = entry
      let field_name = naming.to_snake_case(scheme_name)
      sb |> se.indent(2, field_name <> ": Option(String),")
    })

  let sb =
    sb
    |> se.indent(1, ")")
    |> se.line("}")
    |> se.blank_line()

  // HTTP response type
  let sb =
    sb
    |> se.doc_comment("Raw HTTP response from the server.")
    |> se.line("pub type ClientResponse {")
    |> se.indent(1, "ClientResponse(")
    |> se.indent(2, "status: Int,")
    |> se.indent(2, "body: String,")
    |> se.indent(1, ")")
    |> se.line("}")
    |> se.blank_line()

  // Error type
  let sb =
    sb
    |> se.doc_comment("HTTP client errors.")
    |> se.line("pub type ClientError {")
    |> se.indent(1, "ConnectionError(detail: String)")
    |> se.indent(1, "TimeoutError")
    |> se.indent(1, "DecodeError(detail: String)")
    |> se.line("}")
    |> se.blank_line()

  // Create default client
  let sb =
    sb
    |> se.doc_comment("Create a new client configuration.")
    |> se.line("pub fn new(")
    |> se.indent(1, "base_url: String,")
    |> se.indent(
      1,
      "send: fn(request.Request(String)) -> Result(ClientResponse, ClientError),",
    )
    |> se.line(") -> ClientConfig {")
    |> se.indent(1, "ClientConfig(base_url:, send:,")

  // Initialize security fields to None
  let sb =
    list.fold(security_schemes, sb, fn(sb, entry) {
      let #(scheme_name, _scheme) = entry
      let field_name = naming.to_snake_case(scheme_name)
      sb |> se.indent(2, field_name <> ": None,")
    })

  let sb =
    sb
    |> se.indent(1, ")")
    |> se.line("}")
    |> se.blank_line()

  // Generate default_base_url function from server template variables
  let sb = generate_default_base_url(sb, ctx)

  // Generate operation functions
  let sb =
    list.fold(operations, sb, fn(sb, op) {
      let #(op_id, operation, path, method) = op
      generate_client_function(sb, op_id, operation, path, method, ctx)
    })

  se.to_string(sb)
}

/// Substitute server variable placeholders in a URL template with their default values.
fn substitute_server_variables(
  url: String,
  variables: List(#(String, spec.ServerVariable)),
) -> String {
  list.fold(variables, url, fn(acc, entry) {
    let #(name, variable) = entry
    string.replace(acc, "{" <> name <> "}", variable.default)
  })
}

/// Generate the default_base_url function from the first server's template and variables.
fn generate_default_base_url(
  sb: se.StringBuilder,
  ctx: Context,
) -> se.StringBuilder {
  case ctx.spec.servers {
    [first_server, ..] -> {
      let variables = dict.to_list(first_server.variables)
      let resolved_url =
        substitute_server_variables(first_server.url, variables)
      let defaults_doc = case variables {
        [] -> ""
        _ ->
          "Defaults: "
          <> string.join(
            list.map(variables, fn(entry) {
              let #(name, variable) = entry
              name <> " = \"" <> variable.default <> "\""
            }),
            ", ",
          )
      }
      let sb = case defaults_doc {
        "" ->
          sb
          |> se.doc_comment(
            "Build the base URL from server template variables.",
          )
        doc ->
          sb
          |> se.doc_comment(
            "Build the base URL from server template variables.",
          )
          |> se.doc_comment(doc)
      }
      sb
      |> se.line("pub fn default_base_url() -> String {")
      |> se.indent(1, "\"" <> resolved_url <> "\"")
      |> se.line("}")
      |> se.blank_line()
    }
    [] -> {
      sb
      |> se.doc_comment("Build the base URL from server template variables.")
      |> se.line("pub fn default_base_url() -> String {")
      |> se.indent(1, "\"\"")
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Generate a client function for a single operation.
fn generate_client_function(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation,
  path: String,
  method: spec.HttpMethod,
  ctx: Context,
) -> se.StringBuilder {
  let fn_name = naming.operation_to_function_name(op_id)

  let sb = case operation.summary {
    Some(summary) -> sb |> se.doc_comment(summary)
    _ -> sb
  }
  let sb = case operation.description {
    Some(desc) -> sb |> se.doc_comment(desc)
    _ -> sb
  }
  // Add doc comment listing supported content types for multi-content request bodies
  let sb = case operation.request_body {
    Some(rb) -> {
      let content_entries = dict.to_list(rb.content)
      case content_entries {
        [_, _, ..] -> {
          let ct_names =
            list.map(content_entries, fn(e) { e.0 })
            |> string.join(", ")
          sb
          |> se.doc_comment("Supported content types: " <> ct_names)
        }
        _ -> sb
      }
    }
    _ -> sb
  }

  let path_params =
    list.filter(operation.parameters, fn(p) {
      case p.in_ {
        spec.InPath -> True
        _ -> False
      }
    })

  let query_params =
    list.filter(operation.parameters, fn(p) {
      case p.in_ {
        spec.InQuery -> True
        _ -> False
      }
    })

  let header_params =
    list.filter(operation.parameters, fn(p) {
      case p.in_ {
        spec.InHeader -> True
        _ -> False
      }
    })

  let cookie_params =
    list.filter(operation.parameters, fn(p) {
      case p.in_ {
        spec.InCookie -> True
        _ -> False
      }
    })

  // Function signature
  let response_type = naming.schema_to_type_name(op_id) <> "Response"
  let params =
    build_param_list(
      path_params,
      query_params,
      header_params,
      cookie_params,
      operation,
      op_id,
      ctx,
    )
  let sb =
    sb
    |> se.line(
      "pub fn "
      <> fn_name
      <> "(config: ClientConfig"
      <> params
      <> ") -> Result(response_types."
      <> response_type
      <> ", ClientError) {",
    )

  // Build URL with path params
  let sb = sb |> se.indent(1, "let path = \"" <> path <> "\"")
  let sb =
    list.fold(path_params, sb, fn(sb, p) {
      let param_name = naming.to_snake_case(p.name)
      let to_string_expr = param_to_string_expr(p, param_name, ctx)
      sb
      |> se.indent(
        1,
        "let path = string.replace(path, \"{"
          <> p.name
          <> "}\", uri.percent_encode("
          <> to_string_expr
          <> "))",
      )
    })

  // Build query string from query params
  let sb = case list.is_empty(query_params) {
    True -> sb
    False -> {
      let sb = sb |> se.indent(1, "let query_parts = []")
      let sb =
        list.fold(query_params, sb, fn(sb, p) {
          let param_name = naming.to_snake_case(p.name)
          // Check for deepObject style with object schema
          case p.style, is_deep_object_param(p, ctx) {
            Some(spec.DeepObjectStyle), True ->
              generate_deep_object_query_param(sb, p, param_name, ctx)
            _, _ ->
              case is_exploded_array_param(p, ctx) {
                True ->
                  generate_exploded_array_query_param(sb, p, param_name, ctx)
                False ->
                  case p.required {
                    True -> {
                      let to_str = to_str_for_required(p, param_name, ctx)
                      let encoded = maybe_percent_encode(to_str, p)
                      sb
                      |> se.indent(
                        1,
                        "let query_parts = [\""
                          <> p.name
                          <> "=\" <> "
                          <> encoded
                          <> ", ..query_parts]",
                      )
                    }
                    False -> {
                      let to_str = to_str_for_optional_value(p, ctx)
                      let encoded = maybe_percent_encode(to_str, p)
                      sb
                      |> se.indent(
                        1,
                        "let query_parts = case " <> param_name <> " {",
                      )
                      |> se.indent(
                        2,
                        "Some(v) -> [\""
                          <> p.name
                          <> "=\" <> "
                          <> encoded
                          <> ", ..query_parts]",
                      )
                      |> se.indent(2, "None -> query_parts")
                      |> se.indent(1, "}")
                    }
                  }
              }
          }
        })
      let sb =
        sb
        |> se.indent(1, "let query_string = string.join(query_parts, \"&\")")
        |> se.indent(1, "let path = case query_string {")
        |> se.indent(2, "\"\" -> path")
        |> se.indent(2, "_ -> path <> \"?\" <> query_string")
        |> se.indent(1, "}")
      sb
    }
  }

  // Build the request
  let http_method = case method {
    spec.Get -> "http.Get"
    spec.Post -> "http.Post"
    spec.Put -> "http.Put"
    spec.Delete -> "http.Delete"
    spec.Patch -> "http.Patch"
    spec.Head -> "http.Head"
    spec.Options -> "http.Options"
    spec.Trace -> "http.Trace"
  }

  let sb =
    sb
    |> se.indent(1, "let assert Ok(req) = request.to(config.base_url <> path)")
    |> se.indent(1, "let req = request.set_method(req, " <> http_method <> ")")

  // Only set content-type for requests with body
  let sb = case operation.request_body {
    Some(rb) -> {
      // For optional request bodies, unwrap the Option first
      let sb = case rb.required {
        True -> sb
        False ->
          sb
          |> se.indent(1, "let req = case body {")
          |> se.indent(2, "Some(body) -> {")
      }
      let indent_offset = case rb.required {
        True -> 0
        False -> 2
      }
      let _ = indent_offset
      let content_entries = dict.to_list(rb.content)
      let sb = case content_entries {
        // Multiple content types: accept pre-serialized String body
        // with a content_type parameter
        [_, _, ..] ->
          sb
          |> se.indent(
            1,
            "let req = request.set_header(req, \"content-type\", content_type)",
          )
          |> se.indent(1, "let req = request.set_body(req, body)")
        // Single content type
        [#(content_type_key, _)] ->
          case content_type_key {
            "multipart/form-data" -> generate_multipart_body(sb, rb, op_id, ctx)
            "application/x-www-form-urlencoded" ->
              generate_form_urlencoded_body(sb, rb, op_id, ctx)
            _ -> {
              let body_encode_expr = get_body_encode_expr(rb, op_id, ctx)
              sb
              |> se.indent(
                1,
                "let req = request.set_header(req, \"content-type\", \""
                  <> content_type_key
                  <> "\")",
              )
              |> se.indent(
                1,
                "let req = request.set_body(req, " <> body_encode_expr <> ")",
              )
            }
          }
        [] -> sb
      }
      // Close optional body case
      case rb.required {
        True -> sb
        False ->
          sb
          |> se.indent(2, "req")
          |> se.indent(1, "}")
          |> se.indent(2, "None -> req")
          |> se.indent(1, "}")
      }
    }
    _ -> sb
  }

  // Set header parameters
  let sb =
    list.fold(header_params, sb, fn(sb, p) {
      let param_name = naming.to_snake_case(p.name)
      let header_name = string.lowercase(p.name)
      case p.required {
        True -> {
          let to_str = param_to_string_expr(p, param_name, ctx)
          sb
          |> se.indent(
            1,
            "let req = request.set_header(req, \""
              <> header_name
              <> "\", "
              <> to_str
              <> ")",
          )
        }
        False -> {
          let to_str = to_str_for_optional_value(p, ctx)
          sb
          |> se.indent(1, "let req = case " <> param_name <> " {")
          |> se.indent(
            2,
            "Some(v) -> request.set_header(req, \""
              <> header_name
              <> "\", "
              <> to_str
              <> ")",
          )
          |> se.indent(2, "None -> req")
          |> se.indent(1, "}")
        }
      }
    })

  // Set cookie parameters: combine all into a single "cookie" header
  let sb = case list.is_empty(cookie_params) {
    True -> sb
    False -> {
      let sb = sb |> se.indent(1, "let cookie_parts = []")
      let sb =
        list.fold(cookie_params, sb, fn(sb, p) {
          let param_name = naming.to_snake_case(p.name)
          case p.required {
            True -> {
              let to_str = param_to_string_expr(p, param_name, ctx)
              sb
              |> se.indent(
                1,
                "let cookie_parts = [\""
                  <> p.name
                  <> "=\" <> uri.percent_encode("
                  <> to_str
                  <> "), ..cookie_parts]",
              )
            }
            False -> {
              let to_str = to_str_for_optional_value(p, ctx)
              sb
              |> se.indent(1, "let cookie_parts = case " <> param_name <> " {")
              |> se.indent(
                2,
                "Some(v) -> [\""
                  <> p.name
                  <> "=\" <> uri.percent_encode("
                  <> to_str
                  <> "), ..cookie_parts]",
              )
              |> se.indent(2, "None -> cookie_parts")
              |> se.indent(1, "}")
            }
          }
        })
      sb
      |> se.indent(1, "let req = case cookie_parts {")
      |> se.indent(2, "[] -> req")
      |> se.indent(
        2,
        "_ -> request.set_header(req, \"cookie\", string.join(cookie_parts, \"; \"))",
      )
      |> se.indent(1, "}")
    }
  }

  // Apply security schemes with proper OR semantics.
  // OpenAPI security is OR of alternatives; each alternative is AND of
  // schemes. The generated code tries each alternative in order and
  // applies only the first one whose credentials are all present.
  let effective_security = case operation.security {
    Some(sec) -> sec
    None -> ctx.spec.security
  }
  let sb = case effective_security {
    [] -> sb
    alternatives -> {
      // Emit scope comments for each security alternative
      let sb =
        list.fold(alternatives, sb, fn(sb, alt) {
          let all_scopes = list.flat_map(alt.schemes, fn(s) { s.scopes })
          case all_scopes {
            [] -> sb
            scopes ->
              sb
              |> se.indent(
                1,
                "// Required scopes: " <> string.join(scopes, ", "),
              )
          }
        })
      generate_security_or_chain(sb, ctx, alternatives, 1)
    }
  }

  // Send request and decode response into typed variant
  let sb =
    sb
    |> se.indent(1, "case config.send(req) {")
    |> se.indent(2, "Error(e) -> Error(e)")
    |> se.indent(2, "Ok(resp) -> {")

  let responses = http.sort_response_entries(dict.to_list(operation.responses))
  let sb =
    sb
    |> se.indent(3, "case resp.status {")

  let sb =
    list.fold(responses, sb, fn(sb, entry) {
      let #(status_code, response) = entry
      let variant_name =
        "response_types."
        <> naming.schema_to_type_name(op_id)
        <> "Response"
        <> http.status_code_suffix(status_code)
      let content_entries = dict.to_list(response.content)
      case content_entries {
        [] ->
          sb
          |> se.indent(
            4,
            http.status_code_to_int_pattern(status_code)
              <> " -> Ok("
              <> variant_name
              <> ")",
          )
        [#(single_ct, single_mt)] ->
          generate_single_content_response(
            sb,
            status_code,
            variant_name,
            single_ct,
            single_mt,
            op_id,
            ctx,
          )
        multiple ->
          generate_multi_content_response(
            sb,
            status_code,
            variant_name,
            multiple,
            op_id,
            ctx,
          )
      }
    })

  // Only add a fallback _ branch if no "default" response exists
  let has_default =
    list.any(responses, fn(entry) {
      let #(code, _) = entry
      code == "default"
    })
  let sb = case has_default {
    True -> sb
    False ->
      sb
      |> se.indent(
        4,
        "_ -> Error(DecodeError(detail: \"Unexpected status: \" <> int.to_string(resp.status)))",
      )
  }
  let sb =
    sb
    |> se.indent(3, "}")
    |> se.indent(2, "}")
    |> se.indent(1, "}")

  sb
  |> se.line("}")
  |> se.blank_line()
}

/// Generate response handling for a single content type.
fn generate_single_content_response(
  sb: se.StringBuilder,
  status_code: String,
  variant_name: String,
  media_type_name: String,
  media_type: spec.MediaType,
  op_id: String,
  ctx: Context,
) -> se.StringBuilder {
  case media_type_name {
    "text/plain" | "application/xml" | "text/xml" | "application/octet-stream" ->
      case media_type.schema {
        Some(_) ->
          sb
          |> se.indent(
            4,
            http.status_code_to_int_pattern(status_code)
              <> " -> Ok("
              <> variant_name
              <> "(resp.body))",
          )
        _ ->
          sb
          |> se.indent(
            4,
            http.status_code_to_int_pattern(status_code)
              <> " -> Ok("
              <> variant_name
              <> ")",
          )
      }
    _ ->
      case media_type.schema {
        Some(schema_ref) -> {
          let decode_expr =
            get_response_decode_expr(schema_ref, op_id, status_code, ctx)
          sb
          |> se.indent(
            4,
            http.status_code_to_int_pattern(status_code) <> " -> {",
          )
          |> se.indent(5, "case " <> decode_expr <> " {")
          |> se.indent(6, "Ok(decoded) -> Ok(" <> variant_name <> "(decoded))")
          |> se.indent(
            6,
            "Error(_) -> Error(DecodeError(detail: \"Failed to decode response body\"))",
          )
          |> se.indent(5, "}")
          |> se.indent(4, "}")
        }
        _ ->
          sb
          |> se.indent(
            4,
            http.status_code_to_int_pattern(status_code)
              <> " -> Ok("
              <> variant_name
              <> ")",
          )
      }
  }
}

/// Generate response handling for multiple content types.
/// Since the response variant uses String for multi-content (to stay type-safe),
/// all branches return resp.body directly.
fn generate_multi_content_response(
  sb: se.StringBuilder,
  status_code: String,
  variant_name: String,
  _content_entries: List(#(String, spec.MediaType)),
  _op_id: String,
  _ctx: Context,
) -> se.StringBuilder {
  // Multi-content response type is always String, so just return resp.body
  sb
  |> se.indent(
    4,
    http.status_code_to_int_pattern(status_code)
      <> " -> Ok("
      <> variant_name
      <> "(resp.body))",
  )
}

/// Build parameter list for function signature.
fn build_param_list(
  path_params: List(spec.Parameter),
  query_params: List(spec.Parameter),
  header_params: List(spec.Parameter),
  cookie_params: List(spec.Parameter),
  operation: spec.Operation,
  op_id: String,
  ctx: Context,
) -> String {
  let all_params =
    list.append(path_params, query_params)
    |> list.append(header_params)
    |> list.append(cookie_params)

  let param_strs =
    list.map(all_params, fn(p) {
      let param_name = naming.to_snake_case(p.name)
      let param_type = param_to_type(p, ctx)
      ", " <> param_name <> ": " <> param_type
    })

  let _ = ctx
  let body_param = case operation.request_body {
    Some(rb) -> {
      let body_type = get_body_type(rb, op_id)
      let wrapped_type = case rb.required {
        True -> body_type
        False -> "Option(" <> body_type <> ")"
      }
      let content_entries = dict.to_list(rb.content)
      case content_entries {
        // Multi-content: add content_type param before body
        [_, _, ..] -> [", content_type: String", ", body: " <> wrapped_type]
        _ -> [", body: " <> wrapped_type]
      }
    }
    _ -> []
  }

  string.join(list.append(param_strs, body_param), "")
}

/// Convert a parameter to its Gleam type string.
fn param_to_type(param: spec.Parameter, ctx: Context) -> String {
  let base = schema_dispatch.resolve_param_type(param.schema, ctx.spec)
  case param.required {
    True -> base
    False -> "Option(" <> base <> ")"
  }
}

/// Convert a parameter value to its String representation for URL/header use.
fn param_to_string_expr(
  param: spec.Parameter,
  param_name: String,
  ctx: Context,
) -> String {
  case param.schema {
    Some(Inline(schema.ArraySchema(items:, ..))) -> {
      let item_to_str = schema_dispatch.to_string_fn(items, ctx.spec)
      "string.join(list.map("
      <> param_name
      <> ", "
      <> item_to_str
      <> "), \",\")"
    }
    Some(Inline(s)) -> schema_dispatch.to_string_expr(s, param_name)
    Some(Reference(..) as schema_ref) -> {
      // Resolve the $ref to determine the actual schema type
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(schema.ArraySchema(items:, ..)) -> {
          let item_to_str = schema_dispatch.to_string_fn(items, ctx.spec)
          "string.join(list.map("
          <> param_name
          <> ", "
          <> item_to_str
          <> "), \",\")"
        }
        _ ->
          schema_dispatch.schema_ref_to_string_expr(
            schema_ref,
            param_name,
            ctx.spec,
          )
      }
    }
    _ -> param_name
  }
}

/// Convert a required param to string for query building.
fn to_str_for_required(
  param: spec.Parameter,
  param_name: String,
  ctx: Context,
) -> String {
  param_to_string_expr(param, param_name, ctx)
}

/// Convert an optional param value (bound to `v`) to string.
fn to_str_for_optional_value(param: spec.Parameter, ctx: Context) -> String {
  case param.schema {
    Some(Inline(schema.ArraySchema(items:, ..))) -> {
      let item_to_str = schema_dispatch.to_string_fn(items, ctx.spec)
      "string.join(list.map(v, " <> item_to_str <> "), \",\")"
    }
    Some(Inline(s)) -> schema_dispatch.to_string_expr(s, "v")
    Some(Reference(..) as schema_ref) -> {
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(schema.ArraySchema(items:, ..)) -> {
          let item_to_str = schema_dispatch.to_string_fn(items, ctx.spec)
          "string.join(list.map(v, " <> item_to_str <> "), \",\")"
        }
        _ ->
          schema_dispatch.schema_ref_to_string_expr(schema_ref, "v", ctx.spec)
      }
    }
    _ -> "v"
  }
}

/// Get the Gleam type for a request body parameter.
fn get_body_type(rb: spec.RequestBody, op_id: String) -> String {
  let content_entries = dict.to_list(rb.content)
  case content_entries {
    // Multiple content types: use pre-serialized String
    [_, _, ..] -> "String"
    [#(_, media_type)] ->
      case media_type.schema {
        Some(Reference(name:, ..)) ->
          "types." <> naming.schema_to_type_name(name)
        Some(Inline(schema.StringSchema(..))) -> "String"
        Some(Inline(schema.IntegerSchema(..))) -> "Int"
        Some(Inline(schema.NumberSchema(..))) -> "Float"
        Some(Inline(schema.BooleanSchema(..))) -> "Bool"
        Some(Inline(_)) ->
          "types." <> naming.schema_to_type_name(op_id) <> "RequestBody"
        _ -> "String"
      }
    [] -> "String"
  }
}

/// Get the encode expression for a request body.
fn get_body_encode_expr(
  rb: spec.RequestBody,
  op_id: String,
  _ctx: Context,
) -> String {
  let content_entries = dict.to_list(rb.content)
  case content_entries {
    [#(_, media_type), ..] ->
      case media_type.schema {
        Some(Reference(name:, ..)) -> {
          "encode.encode_" <> naming.to_snake_case(name) <> "(body)"
        }
        Some(Inline(schema.StringSchema(..))) ->
          "json.to_string(json.string(body))"
        Some(Inline(schema.IntegerSchema(..))) ->
          "json.to_string(json.int(body))"
        Some(Inline(schema.NumberSchema(..))) ->
          "json.to_string(json.float(body))"
        Some(Inline(schema.BooleanSchema(..))) ->
          "json.to_string(json.bool(body))"
        Some(Inline(_)) -> {
          let fn_name =
            "encode_" <> naming.to_snake_case(op_id) <> "_request_body"
          "encode." <> fn_name <> "(body)"
        }
        _ -> "body"
      }
    [] -> "body"
  }
}

/// Generate multipart/form-data body encoding in the client function.
fn generate_multipart_body(
  sb: se.StringBuilder,
  rb: spec.RequestBody,
  _op_id: String,
  ctx: Context,
) -> se.StringBuilder {
  let boundary = "----oaspec-boundary"
  let content_entries = dict.to_list(rb.content)
  let #(properties, required_fields) = case content_entries {
    [#(_, media_type), ..] ->
      case media_type.schema {
        Some(Inline(schema.ObjectSchema(properties:, required:, ..))) -> #(
          dict.to_list(properties),
          required,
        )
        Some(Reference(..) as schema_ref) ->
          case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
            Ok(schema.ObjectSchema(properties:, required:, ..)) -> {
              #(dict.to_list(properties), required)
            }
            _ -> #([], [])
          }
        _ -> #([], [])
      }
    _ -> #([], [])
  }

  let sb =
    sb
    |> se.indent(1, "let boundary = \"" <> boundary <> "\"")
    |> se.indent(1, "let parts = []")

  let sb =
    list.fold(properties, sb, fn(sb, prop) {
      let #(field_name, field_schema) = prop
      let gleam_field = naming.to_snake_case(field_name)
      let is_required = list.contains(required_fields, field_name)
      let is_binary = multipart_field_is_binary(field_schema, ctx)
      // Convert value to string for multipart encoding
      let to_string_fn = case is_binary {
        True -> ""
        False -> multipart_field_to_string_fn(field_schema, ctx)
      }
      let part_header_binary =
        "\"--\" <> boundary <> \"\\r\\nContent-Disposition: form-data; name=\\\""
        <> field_name
        <> "\\\"; filename=\\\""
        <> field_name
        <> "\\\"\\r\\nContent-Type: application/octet-stream\\r\\n\\r\\n\""
      let part_header_text =
        "\"--\" <> boundary <> \"\\r\\nContent-Disposition: form-data; name=\\\""
        <> field_name
        <> "\\\"\\r\\n\\r\\n\""
      let part_header = case is_binary {
        True -> part_header_binary
        False -> part_header_text
      }
      case is_required {
        True -> {
          let value_expr = case to_string_fn {
            "" -> "body." <> gleam_field
            fn_name -> fn_name <> "(body." <> gleam_field <> ")"
          }
          sb
          |> se.indent(
            1,
            "let parts = ["
              <> part_header
              <> " <> "
              <> value_expr
              <> " <> \"\\r\\n\", ..parts]",
          )
        }
        False -> {
          // Optional field: wrap in case body.<field> { Some(v) -> ... None -> parts }
          let value_expr = case to_string_fn {
            "" -> "v"
            fn_name -> fn_name <> "(v)"
          }
          sb
          |> se.indent(1, "let parts = case body." <> gleam_field <> " {")
          |> se.indent(
            2,
            "Some(v) -> ["
              <> part_header
              <> " <> "
              <> value_expr
              <> " <> \"\\r\\n\", ..parts]",
          )
          |> se.indent(2, "None -> parts")
          |> se.indent(1, "}")
        }
      }
    })

  sb
  |> se.indent(
    1,
    "let body_str = string.join(parts, \"\") <> \"--\" <> boundary <> \"--\\r\\n\"",
  )
  |> se.indent(
    1,
    "let req = request.set_header(req, \"content-type\", \"multipart/form-data; boundary=\" <> boundary)",
  )
  |> se.indent(1, "let req = request.set_body(req, body_str)")
}

fn multipart_field_is_binary(
  field_schema: schema.SchemaRef,
  ctx: Context,
) -> Bool {
  case field_schema {
    Inline(schema.StringSchema(format: Some("binary"), ..)) -> True
    Reference(..) as schema_ref ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(schema.StringSchema(format: Some("binary"), ..)) -> True
        _ -> False
      }
    _ -> False
  }
}

fn multipart_field_to_string_fn(
  field_schema: schema.SchemaRef,
  ctx: Context,
) -> String {
  let result = schema_dispatch.to_string_fn(field_schema, ctx.spec)
  // Return "" for identity functions since callers use "" to mean "no conversion"
  case result {
    "fn(x) { x }" -> ""
    _ -> result
  }
}

/// Convert an array field's items to a string expression for form-urlencoded encoding.
/// Returns an expression that converts `item` to a String.
fn form_array_item_to_string(
  field_schema: schema.SchemaRef,
  ctx: Context,
) -> String {
  case field_schema {
    Inline(schema.ArraySchema(items:, ..)) ->
      schema_dispatch.schema_ref_to_string_expr(items, "item", ctx.spec)
    _ -> "string.inspect(item)"
  }
}

/// Generate form encoding for a nested object property.
/// Serializes as field[subkey]=value for each sub-property.
fn generate_form_nested_object(
  sb: se.StringBuilder,
  field_name: String,
  gleam_field: String,
  field_schema: schema.SchemaRef,
  is_required: Bool,
  ctx: Context,
) -> se.StringBuilder {
  let resolved = case field_schema {
    Inline(s) -> Ok(s)
    Reference(..) -> resolver.resolve_schema_ref(field_schema, ctx.spec)
  }
  let sub_props = case resolved {
    Ok(schema.ObjectSchema(properties:, required:, ..)) -> #(
      dict.to_list(properties),
      required,
    )
    _ -> #([], [])
  }
  let #(props, required_fields) = sub_props
  let accessor_prefix = case is_required {
    True -> "body." <> gleam_field
    False -> "obj"
  }
  let sb = case is_required {
    True -> sb
    False ->
      sb
      |> se.indent(1, "let form_parts = case body." <> gleam_field <> " {")
      |> se.indent(2, "Some(obj) -> {")
      |> se.indent(3, "let fp = form_parts")
  }
  let indent_base = case is_required {
    True -> 1
    False -> 3
  }
  let parts_var = case is_required {
    True -> "form_parts"
    False -> "fp"
  }
  let sb =
    list.fold(props, sb, fn(sb, entry) {
      let #(sub_name, sub_ref) = entry
      let sub_field = naming.to_snake_case(sub_name)
      let sub_accessor = accessor_prefix <> "." <> sub_field
      let sub_required = list.contains(required_fields, sub_name)
      // Check if sub-property is an object — need recursive bracket encoding
      let is_sub_object = case sub_ref {
        Inline(schema.ObjectSchema(..)) -> True
        Reference(..) as sr ->
          case resolver.resolve_schema_ref(sr, ctx.spec) {
            Ok(schema.ObjectSchema(..)) -> True
            _ -> False
          }
        _ -> False
      }
      case is_sub_object {
        True ->
          // Recurse: generate meta[author][name]=value encoding
          generate_form_bracket_fields(
            sb,
            field_name <> "[" <> sub_name <> "]",
            sub_accessor,
            sub_ref,
            sub_required,
            indent_base,
            parts_var,
            ctx,
          )
        False -> {
          let to_str = multipart_field_to_string_fn(sub_ref, ctx)
          case sub_required {
            True -> {
              let value_expr = case to_str {
                "" -> sub_accessor
                fn_name -> fn_name <> "(" <> sub_accessor <> ")"
              }
              sb
              |> se.indent(
                indent_base,
                "let "
                  <> parts_var
                  <> " = [\""
                  <> field_name
                  <> "["
                  <> sub_name
                  <> "]=\" <> uri.percent_encode("
                  <> value_expr
                  <> "), .."
                  <> parts_var
                  <> "]",
              )
            }
            False -> {
              sb
              |> se.indent(
                indent_base,
                "let " <> parts_var <> " = case " <> sub_accessor <> " {",
              )
              |> se.indent(
                indent_base + 1,
                "Some(v) -> [\""
                  <> field_name
                  <> "["
                  <> sub_name
                  <> "]=\" <> uri.percent_encode("
                  <> {
                  case to_str {
                    "" -> "v"
                    fn_name -> fn_name <> "(v)"
                  }
                }
                  <> "), .."
                  <> parts_var
                  <> "]",
              )
              |> se.indent(indent_base + 1, "None -> " <> parts_var)
              |> se.indent(indent_base, "}")
            }
          }
        }
      }
    })
  case is_required {
    True -> sb
    False ->
      sb
      |> se.indent(3, "fp")
      |> se.indent(2, "}")
      |> se.indent(2, "None -> form_parts")
      |> se.indent(1, "}")
  }
}

/// Recursively generate bracket-encoded form fields for nested objects.
/// Produces key[sub]=value for leaf fields and recurses for object children.
fn generate_form_bracket_fields(
  sb: se.StringBuilder,
  key_prefix: String,
  accessor_prefix: String,
  field_schema: schema.SchemaRef,
  _is_required: Bool,
  indent_base: Int,
  parts_var: String,
  ctx: Context,
) -> se.StringBuilder {
  let resolved = case field_schema {
    Inline(s) -> Ok(s)
    Reference(..) -> resolver.resolve_schema_ref(field_schema, ctx.spec)
  }
  case resolved {
    Ok(schema.ObjectSchema(properties:, required:, ..)) -> {
      let props = dict.to_list(properties)
      list.fold(props, sb, fn(sb, entry) {
        let #(prop_name, prop_ref) = entry
        let prop_field = naming.to_snake_case(prop_name)
        let prop_accessor = accessor_prefix <> "." <> prop_field
        let prop_required = list.contains(required, prop_name)
        let is_obj = case prop_ref {
          Inline(schema.ObjectSchema(..)) -> True
          Reference(..) as sr ->
            case resolver.resolve_schema_ref(sr, ctx.spec) {
              Ok(schema.ObjectSchema(..)) -> True
              _ -> False
            }
          _ -> False
        }
        case is_obj {
          True ->
            generate_form_bracket_fields(
              sb,
              key_prefix <> "[" <> prop_name <> "]",
              prop_accessor,
              prop_ref,
              prop_required,
              indent_base,
              parts_var,
              ctx,
            )
          False -> {
            let to_str = multipart_field_to_string_fn(prop_ref, ctx)
            case prop_required {
              True -> {
                let value_expr = case to_str {
                  "" -> prop_accessor
                  fn_name -> fn_name <> "(" <> prop_accessor <> ")"
                }
                sb
                |> se.indent(
                  indent_base,
                  "let "
                    <> parts_var
                    <> " = [\""
                    <> key_prefix
                    <> "["
                    <> prop_name
                    <> "]=\" <> uri.percent_encode("
                    <> value_expr
                    <> "), .."
                    <> parts_var
                    <> "]",
                )
              }
              False ->
                sb
                |> se.indent(
                  indent_base,
                  "let " <> parts_var <> " = case " <> prop_accessor <> " {",
                )
                |> se.indent(
                  indent_base + 1,
                  "Some(v) -> [\""
                    <> key_prefix
                    <> "["
                    <> prop_name
                    <> "]=\" <> uri.percent_encode("
                    <> {
                    case to_str {
                      "" -> "v"
                      fn_name -> fn_name <> "(v)"
                    }
                  }
                    <> "), .."
                    <> parts_var
                    <> "]",
                )
                |> se.indent(indent_base + 1, "None -> " <> parts_var)
                |> se.indent(indent_base, "}")
            }
          }
        }
      })
    }
    _ -> sb
  }
}

/// Generate application/x-www-form-urlencoded body encoding in the client function.
fn generate_form_urlencoded_body(
  sb: se.StringBuilder,
  rb: spec.RequestBody,
  _op_id: String,
  ctx: Context,
) -> se.StringBuilder {
  let content_entries = dict.to_list(rb.content)
  let #(properties, required_fields) = case content_entries {
    [#(_, media_type), ..] ->
      case media_type.schema {
        Some(Inline(schema.ObjectSchema(properties:, required:, ..))) -> #(
          dict.to_list(properties),
          required,
        )
        Some(Reference(..) as schema_ref) ->
          case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
            Ok(schema.ObjectSchema(properties:, required:, ..)) -> {
              #(dict.to_list(properties), required)
            }
            _ -> #([], [])
          }
        _ -> #([], [])
      }
    _ -> #([], [])
  }

  let sb = sb |> se.indent(1, "let form_parts = []")
  let sb =
    list.fold(properties, sb, fn(sb, prop) {
      let #(field_name, field_schema) = prop
      let gleam_field = naming.to_snake_case(field_name)
      let is_required = list.contains(required_fields, field_name)
      let is_array = case field_schema {
        Inline(schema.ArraySchema(..)) -> True
        Reference(..) as sr ->
          case resolver.resolve_schema_ref(sr, ctx.spec) {
            Ok(schema.ArraySchema(..)) -> True
            _ -> False
          }
        _ -> False
      }
      let is_object = case field_schema {
        Inline(schema.ObjectSchema(..)) -> True
        Reference(..) as sr ->
          case resolver.resolve_schema_ref(sr, ctx.spec) {
            Ok(schema.ObjectSchema(..)) -> True
            _ -> False
          }
        _ -> False
      }
      case is_object {
        True ->
          // Nested objects: serialize as field[subkey]=value
          generate_form_nested_object(
            sb,
            field_name,
            gleam_field,
            field_schema,
            is_required,
            ctx,
          )
        False ->
          case is_array {
            True ->
              // Arrays: repeat the key for each element (tags=a&tags=b)
              case is_required {
                True ->
                  sb
                  |> se.indent(
                    1,
                    "let form_parts = list.fold(body."
                      <> gleam_field
                      <> ", form_parts, fn(acc, item) {",
                  )
                  |> se.indent(
                    2,
                    "[\""
                      <> field_name
                      <> "=\" <> uri.percent_encode("
                      <> form_array_item_to_string(field_schema, ctx)
                      <> "), ..acc]",
                  )
                  |> se.indent(1, "})")
                False ->
                  sb
                  |> se.indent(
                    1,
                    "let form_parts = case body." <> gleam_field <> " {",
                  )
                  |> se.indent(
                    2,
                    "Some(items) -> list.fold(items, form_parts, fn(acc, item) {",
                  )
                  |> se.indent(
                    3,
                    "[\""
                      <> field_name
                      <> "=\" <> uri.percent_encode("
                      <> form_array_item_to_string(field_schema, ctx)
                      <> "), ..acc]",
                  )
                  |> se.indent(2, "})")
                  |> se.indent(2, "None -> form_parts")
                  |> se.indent(1, "}")
              }
            False -> {
              let to_str = multipart_field_to_string_fn(field_schema, ctx)
              case is_required {
                True -> {
                  let value_expr = case to_str {
                    "" -> "body." <> gleam_field
                    fn_name -> fn_name <> "(body." <> gleam_field <> ")"
                  }
                  sb
                  |> se.indent(
                    1,
                    "let form_parts = [\""
                      <> field_name
                      <> "=\" <> uri.percent_encode("
                      <> value_expr
                      <> "), ..form_parts]",
                  )
                }
                False ->
                  sb
                  |> se.indent(
                    1,
                    "let form_parts = case body." <> gleam_field <> " {",
                  )
                  |> se.indent(
                    2,
                    "Some(v) -> [\""
                      <> field_name
                      <> "=\" <> uri.percent_encode("
                      <> {
                      case to_str {
                        "" -> "v"
                        fn_name -> fn_name <> "(v)"
                      }
                    }
                      <> "), ..form_parts]",
                  )
                  |> se.indent(2, "None -> form_parts")
                  |> se.indent(1, "}")
              }
            }
          }
      }
    })

  sb
  |> se.indent(1, "let body_str = string.join(form_parts, \"&\")")
  |> se.indent(
    1,
    "let req = request.set_header(req, \"content-type\", \"application/x-www-form-urlencoded\")",
  )
  |> se.indent(1, "let req = request.set_body(req, body_str)")
}

/// Get the decode expression for a response body.
fn get_response_decode_expr(
  schema_ref: schema.SchemaRef,
  op_id: String,
  status_code: String,
  _ctx: Context,
) -> String {
  case schema_ref {
    Reference(name:, ..) -> {
      "decode.decode_" <> naming.to_snake_case(name) <> "(resp.body)"
    }
    Inline(schema.ArraySchema(items:, ..)) ->
      case items {
        Reference(name:, ..) -> {
          "decode.decode_" <> naming.to_snake_case(name) <> "_list(resp.body)"
        }
        Inline(inner) -> {
          let inner_decoder = inline_schema_to_decoder(inner)
          "json.parse(resp.body, decode.list(" <> inner_decoder <> "))"
        }
      }
    Inline(schema.StringSchema(..)) ->
      "json.parse(resp.body, dyn_decode.string)"
    Inline(schema.IntegerSchema(..)) -> "json.parse(resp.body, dyn_decode.int)"
    Inline(schema.NumberSchema(..)) -> "json.parse(resp.body, dyn_decode.float)"
    Inline(schema.BooleanSchema(..)) -> "json.parse(resp.body, dyn_decode.bool)"
    Inline(_) -> {
      let fn_name =
        "decode_"
        <> naming.to_snake_case(op_id)
        <> "_response_"
        <> naming.to_snake_case(http.status_code_suffix(status_code))
      "decode." <> fn_name <> "(resp.body)"
    }
  }
}

/// Convert an inline schema to a decoder expression for use in generated client.
/// Uses dyn_decode (gleam/dynamic/decode) to avoid collision with the generated
/// decode module.
fn inline_schema_to_decoder(s: schema.SchemaObject) -> String {
  case s {
    schema.StringSchema(..) -> "dyn_decode.string"
    schema.IntegerSchema(..) -> "dyn_decode.int"
    schema.NumberSchema(..) -> "dyn_decode.float"
    schema.BooleanSchema(..) -> "dyn_decode.bool"
    _ -> "dyn_decode.string"
  }
}

/// Return a function expression that converts an array item to String.
/// Used in generated code: `list.map(param, <fn>)`.
fn array_item_to_string_fn(items: schema.SchemaRef, ctx: Context) -> String {
  schema_dispatch.to_string_fn(items, ctx.spec)
}

/// Convert a deepObject array item to a string expression.
fn deep_object_array_item_to_string(
  prop_ref: schema.SchemaRef,
  ctx: Context,
) -> String {
  case prop_ref {
    Inline(schema.ArraySchema(items:, ..)) ->
      schema_dispatch.schema_ref_to_string_expr(items, "item", ctx.spec)
    _ -> "item"
  }
}

/// Check if a parameter is an array with explode behavior.
/// OpenAPI default: style: form has explode: true by default.
fn is_exploded_array_param(param: spec.Parameter, ctx: Context) -> Bool {
  let is_array = case param.schema {
    Some(Inline(schema.ArraySchema(..))) -> True
    Some(Reference(..) as sr) ->
      case resolver.resolve_schema_ref(sr, ctx.spec) {
        Ok(schema.ArraySchema(..)) -> True
        _ -> False
      }
    _ -> False
  }
  case is_array {
    False -> False
    True -> {
      // explode defaults to true for style: form (which is the default for query params)
      let effective_explode = case param.explode {
        option.Some(v) -> v
        option.None ->
          case param.style {
            option.Some(spec.FormStyle) | option.None -> True
            _ -> False
          }
      }
      effective_explode
    }
  }
}

/// Generate exploded array query parameter: tags=a&tags=b
fn generate_exploded_array_query_param(
  sb: se.StringBuilder,
  param: spec.Parameter,
  param_name: String,
  ctx: Context,
) -> se.StringBuilder {
  let item_to_str = case param.schema {
    Some(Inline(schema.ArraySchema(items:, ..))) ->
      array_item_to_string_fn(items, ctx)
    Some(Reference(..) as sr) ->
      case resolver.resolve_schema_ref(sr, ctx.spec) {
        Ok(schema.ArraySchema(items:, ..)) ->
          array_item_to_string_fn(items, ctx)
        _ -> "fn(x) { x }"
      }
    _ -> "fn(x) { x }"
  }
  case param.required {
    True ->
      sb
      |> se.indent(
        1,
        "let query_parts = list.fold("
          <> param_name
          <> ", query_parts, fn(acc, item) {",
      )
      |> se.indent(
        2,
        "[\""
          <> param.name
          <> "=\" <> uri.percent_encode("
          <> item_to_str
          <> "(item)), ..acc]",
      )
      |> se.indent(1, "})")
    False ->
      sb
      |> se.indent(1, "let query_parts = case " <> param_name <> " {")
      |> se.indent(
        2,
        "Some(items) -> list.fold(items, query_parts, fn(acc, item) {",
      )
      |> se.indent(
        3,
        "[\""
          <> param.name
          <> "=\" <> uri.percent_encode("
          <> item_to_str
          <> "(item)), ..acc]",
      )
      |> se.indent(2, "})")
      |> se.indent(2, "None -> query_parts")
      |> se.indent(1, "}")
  }
}

/// Check if a parameter uses deepObject style with an object schema.
fn is_deep_object_param(param: spec.Parameter, ctx: Context) -> Bool {
  case param.schema {
    Some(Reference(..) as schema_ref) ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(schema.ObjectSchema(..)) -> True
        _ -> False
      }
    Some(Inline(schema.ObjectSchema(..))) -> True
    _ -> False
  }
}

/// Generate deepObject-style query parameters: key[prop]=value for each property.
fn generate_deep_object_query_param(
  sb: se.StringBuilder,
  param: spec.Parameter,
  param_name: String,
  ctx: Context,
) -> se.StringBuilder {
  let properties = case param.schema {
    Some(Reference(..) as schema_ref) ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(schema.ObjectSchema(properties:, required:, ..)) -> #(
          dict.to_list(properties),
          required,
        )
        _ -> #([], [])
      }
    Some(Inline(schema.ObjectSchema(properties:, required:, ..))) -> #(
      dict.to_list(properties),
      required,
    )
    _ -> #([], [])
  }
  let #(props, required_fields) = properties
  case param.required {
    True ->
      list.fold(props, sb, fn(sb, entry) {
        let #(prop_name, prop_ref) = entry
        let field_name = naming.to_snake_case(prop_name)
        let accessor = param_name <> "." <> field_name
        let is_required = list.contains(required_fields, prop_name)
        let is_array = case prop_ref {
          Inline(schema.ArraySchema(..)) -> True
          _ -> False
        }
        case is_array, is_required {
          // Array leaf: iterate items to produce key[prop]=item for each
          True, True ->
            sb
            |> se.indent(
              1,
              "let query_parts = list.fold("
                <> accessor
                <> ", query_parts, fn(acc, item) {",
            )
            |> se.indent(
              2,
              "[\""
                <> param.name
                <> "["
                <> prop_name
                <> "]=\" <> uri.percent_encode("
                <> deep_object_array_item_to_string(prop_ref, ctx)
                <> "), ..acc]",
            )
            |> se.indent(1, "})")
          True, False ->
            sb
            |> se.indent(1, "let query_parts = case " <> accessor <> " {")
            |> se.indent(
              2,
              "Some(items) -> list.fold(items, query_parts, fn(acc, item) {",
            )
            |> se.indent(
              3,
              "[\""
                <> param.name
                <> "["
                <> prop_name
                <> "]=\" <> uri.percent_encode("
                <> deep_object_array_item_to_string(prop_ref, ctx)
                <> "), ..acc]",
            )
            |> se.indent(2, "})")
            |> se.indent(2, "None -> query_parts")
            |> se.indent(1, "}")
          // Scalar: single key[prop]=value
          False, True -> {
            let to_str = schema_ref_to_string_expr(prop_ref, accessor, ctx)
            sb
            |> se.indent(
              1,
              "let query_parts = [\""
                <> param.name
                <> "["
                <> prop_name
                <> "]=\" <> uri.percent_encode("
                <> to_str
                <> "), ..query_parts]",
            )
          }
          False, False -> {
            sb
            |> se.indent(1, "let query_parts = case " <> accessor <> " {")
            |> se.indent(
              2,
              "Some(v) -> [\""
                <> param.name
                <> "["
                <> prop_name
                <> "]=\" <> uri.percent_encode("
                <> schema_ref_to_string_expr(prop_ref, "v", ctx)
                <> "), ..query_parts]",
            )
            |> se.indent(2, "None -> query_parts")
            |> se.indent(1, "}")
          }
        }
      })
    False -> {
      let sb =
        sb |> se.indent(1, "let query_parts = case " <> param_name <> " {")
      let sb = sb |> se.indent(2, "Some(obj) -> {")
      let sb = sb |> se.indent(3, "let qp = query_parts")
      let sb =
        list.fold(props, sb, fn(sb, entry) {
          let #(prop_name, prop_ref) = entry
          let field_name = naming.to_snake_case(prop_name)
          let accessor = "obj." <> field_name
          let is_required = list.contains(required_fields, prop_name)
          let is_array = case prop_ref {
            Inline(schema.ArraySchema(..)) -> True
            _ -> False
          }
          case is_array, is_required {
            True, True ->
              sb
              |> se.indent(
                3,
                "let qp = list.fold(" <> accessor <> ", qp, fn(acc, item) {",
              )
              |> se.indent(
                4,
                "[\""
                  <> param.name
                  <> "["
                  <> prop_name
                  <> "]=\" <> uri.percent_encode("
                  <> deep_object_array_item_to_string(prop_ref, ctx)
                  <> "), ..acc]",
              )
              |> se.indent(3, "})")
            True, False ->
              sb
              |> se.indent(3, "let qp = case " <> accessor <> " {")
              |> se.indent(
                4,
                "Some(items) -> list.fold(items, qp, fn(acc, item) {",
              )
              |> se.indent(
                5,
                "[\""
                  <> param.name
                  <> "["
                  <> prop_name
                  <> "]=\" <> uri.percent_encode("
                  <> deep_object_array_item_to_string(prop_ref, ctx)
                  <> "), ..acc]",
              )
              |> se.indent(4, "})")
              |> se.indent(4, "None -> qp")
              |> se.indent(3, "}")
            False, True -> {
              let to_str = schema_ref_to_string_expr(prop_ref, accessor, ctx)
              sb
              |> se.indent(
                3,
                "let qp = [\""
                  <> param.name
                  <> "["
                  <> prop_name
                  <> "]=\" <> uri.percent_encode("
                  <> to_str
                  <> "), ..qp]",
              )
            }
            False, False ->
              sb
              |> se.indent(3, "let qp = case " <> accessor <> " {")
              |> se.indent(
                4,
                "Some(v) -> [\""
                  <> param.name
                  <> "["
                  <> prop_name
                  <> "]=\" <> uri.percent_encode("
                  <> schema_ref_to_string_expr(prop_ref, "v", ctx)
                  <> "), ..qp]",
              )
              |> se.indent(4, "None -> qp")
              |> se.indent(3, "}")
          }
        })
      let sb = sb |> se.indent(3, "qp")
      let sb = sb |> se.indent(2, "}")
      let sb = sb |> se.indent(2, "None -> query_parts")
      sb |> se.indent(1, "}")
    }
  }
}

/// Convert a SchemaRef to a string expression for a given accessor.
fn schema_ref_to_string_expr(
  schema_ref: schema.SchemaRef,
  accessor: String,
  ctx: Context,
) -> String {
  schema_dispatch.schema_ref_to_string_expr(schema_ref, accessor, ctx.spec)
}

/// Capitalize the first letter of a string (for HTTP scheme prefix).
fn capitalize_first(s: String) -> String {
  case string.pop_grapheme(s) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    Error(_) -> s
  }
}

/// Generate a chain of OR alternatives for security requirements.
/// Each alternative is tried in order; the first one with all credentials
/// present is applied. If none match, req is returned unchanged.
fn generate_security_or_chain(
  sb: se.StringBuilder,
  ctx: Context,
  alternatives: List(spec.SecurityRequirement),
  base_indent: Int,
) -> se.StringBuilder {
  case alternatives {
    [] -> sb
    [alt] ->
      // Last (or only) alternative: None branch falls through to req
      generate_security_alternative(sb, ctx, alt.schemes, base_indent, "req")
    [alt, ..rest] -> {
      // For this alternative, the None/fallback branch tries the next alternative
      // We generate a nested structure where the fallback is the next alternative
      case alt.schemes {
        [] -> generate_security_or_chain(sb, ctx, rest, base_indent)
        [single_scheme] -> {
          let field_name = naming.to_snake_case(single_scheme.scheme_name)
          let sb =
            sb
            |> se.indent(
              base_indent,
              "let req = case config." <> field_name <> " {",
            )
          let sb =
            generate_scheme_some_branch(sb, ctx, single_scheme, base_indent + 1)
          let sb =
            sb
            |> se.indent(base_indent + 1, "None -> {")
          let sb = generate_security_or_chain(sb, ctx, rest, base_indent + 2)
          sb
          |> se.indent(base_indent + 2, "req")
          |> se.indent(base_indent + 1, "}")
          |> se.indent(base_indent, "}")
        }
        schemes -> {
          // AND alternative with multiple schemes: tuple match
          let fields =
            list.map(schemes, fn(s) {
              "config." <> naming.to_snake_case(s.scheme_name)
            })
          let sb =
            sb
            |> se.indent(
              base_indent,
              "let req = case " <> string.join(fields, ", ") <> " {",
            )
          // Some, Some, ... branch — apply all schemes
          let some_patterns =
            list.map(schemes, fn(s) {
              "Some(" <> naming.to_snake_case(s.scheme_name) <> "_val)"
            })
          let sb =
            sb
            |> se.indent(
              base_indent + 1,
              string.join(some_patterns, ", ") <> " -> {",
            )
          let sb =
            list.fold(schemes, sb, fn(sb, scheme_ref) {
              generate_scheme_apply(
                sb,
                ctx,
                scheme_ref,
                naming.to_snake_case(scheme_ref.scheme_name) <> "_val",
                base_indent + 2,
              )
            })
          let sb =
            sb
            |> se.indent(base_indent + 2, "req")
            |> se.indent(base_indent + 1, "}")
          // Wildcard branch — try next alternative
          let wildcard =
            list.map(schemes, fn(_) { "_" })
            |> string.join(", ")
          let sb =
            sb
            |> se.indent(base_indent + 1, wildcard <> " -> {")
          let sb = generate_security_or_chain(sb, ctx, rest, base_indent + 2)
          sb
          |> se.indent(base_indent + 2, "req")
          |> se.indent(base_indent + 1, "}")
          |> se.indent(base_indent, "}")
        }
      }
    }
  }
}

/// Generate a single security alternative (last in chain, None -> req).
fn generate_security_alternative(
  sb: se.StringBuilder,
  ctx: Context,
  schemes: List(spec.SecuritySchemeRef),
  base_indent: Int,
  fallback: String,
) -> se.StringBuilder {
  case schemes {
    [] -> sb
    [single_scheme] -> {
      let field_name = naming.to_snake_case(single_scheme.scheme_name)
      let sb =
        sb
        |> se.indent(
          base_indent,
          "let req = case config." <> field_name <> " {",
        )
      let sb =
        generate_scheme_some_branch(sb, ctx, single_scheme, base_indent + 1)
      sb
      |> se.indent(base_indent + 1, "None -> " <> fallback)
      |> se.indent(base_indent, "}")
    }
    schemes -> {
      // AND: tuple match
      let fields =
        list.map(schemes, fn(s) {
          "config." <> naming.to_snake_case(s.scheme_name)
        })
      let sb =
        sb
        |> se.indent(
          base_indent,
          "let req = case " <> string.join(fields, ", ") <> " {",
        )
      let some_patterns =
        list.map(schemes, fn(s) {
          "Some(" <> naming.to_snake_case(s.scheme_name) <> "_val)"
        })
      let sb =
        sb
        |> se.indent(
          base_indent + 1,
          string.join(some_patterns, ", ") <> " -> {",
        )
      let sb =
        list.fold(schemes, sb, fn(sb, scheme_ref) {
          generate_scheme_apply(
            sb,
            ctx,
            scheme_ref,
            naming.to_snake_case(scheme_ref.scheme_name) <> "_val",
            base_indent + 2,
          )
        })
      let sb =
        sb
        |> se.indent(base_indent + 2, "req")
        |> se.indent(base_indent + 1, "}")
      // Wildcard
      let wildcard =
        list.map(schemes, fn(_) { "_" })
        |> string.join(", ")
      sb
      |> se.indent(base_indent + 1, wildcard <> " -> " <> fallback)
      |> se.indent(base_indent, "}")
    }
  }
}

/// Generate the Some branch for a single scheme (the apply-credential line).
fn generate_scheme_some_branch(
  sb: se.StringBuilder,
  ctx: Context,
  scheme_ref: spec.SecuritySchemeRef,
  indent: Int,
) -> se.StringBuilder {
  case ctx.spec.components {
    Some(components) ->
      case dict.get(components.security_schemes, scheme_ref.scheme_name) {
        Ok(spec.ApiKeyScheme(name: header_name, in_: spec.SchemeInHeader)) ->
          sb
          |> se.indent(
            indent,
            "Some(key) -> request.set_header(req, \""
              <> string.lowercase(header_name)
              <> "\", key)",
          )
        Ok(spec.ApiKeyScheme(name: query_name, in_: spec.SchemeInQuery)) ->
          sb
          |> se.indent(indent, "Some(key) -> {")
          |> se.indent(
            indent + 1,
            "let sep = case string.contains(req.path, \"?\") {",
          )
          |> se.indent(indent + 2, "True -> \"&\"")
          |> se.indent(indent + 2, "False -> \"?\"")
          |> se.indent(indent + 1, "}")
          |> se.indent(
            indent + 1,
            "request.Request(..req, path: req.path <> sep <> \""
              <> query_name
              <> "=\" <> key)",
          )
          |> se.indent(indent, "}")
        Ok(spec.ApiKeyScheme(name: cookie_name, in_: spec.SchemeInCookie)) ->
          sb
          |> se.indent(indent, "Some(value) -> {")
          |> se.indent(
            indent + 1,
            "let existing = list.key_find(req.headers, \"cookie\") |> result.unwrap(\"\")",
          )
          |> se.indent(
            indent + 1,
            "let cookie_val = \"" <> cookie_name <> "=\" <> value",
          )
          |> se.indent(indent + 1, "let new_cookie = case existing {")
          |> se.indent(indent + 2, "\"\" -> cookie_val")
          |> se.indent(indent + 2, "_ -> existing <> \"; \" <> cookie_val")
          |> se.indent(indent + 1, "}")
          |> se.indent(
            indent + 1,
            "request.set_header(req, \"cookie\", new_cookie)",
          )
          |> se.indent(indent, "}")
        Ok(spec.HttpScheme(scheme: "basic", ..)) ->
          sb
          |> se.indent(
            indent,
            "Some(token) -> request.set_header(req, \"authorization\", \"Basic \" <> token)",
          )
        Ok(spec.HttpScheme(scheme: "digest", ..)) ->
          sb
          |> se.indent(
            indent,
            "Some(token) -> request.set_header(req, \"authorization\", \"Digest \" <> token)",
          )
        Ok(spec.HttpScheme(scheme: "bearer", ..))
        | Ok(spec.OAuth2Scheme(..))
        | Ok(spec.OpenIdConnectScheme(..)) ->
          sb
          |> se.indent(
            indent,
            "Some(token) -> request.set_header(req, \"authorization\", \"Bearer \" <> token)",
          )
        Ok(spec.HttpScheme(scheme: scheme_name, ..)) ->
          sb
          |> se.indent(
            indent,
            "Some(token) -> request.set_header(req, \"authorization\", \""
              <> capitalize_first(scheme_name)
              <> " \" <> token)",
          )
        _ -> sb
      }
    _ -> sb
  }
}

/// Generate scheme application using a known value variable (for AND tuple matches).
fn generate_scheme_apply(
  sb: se.StringBuilder,
  ctx: Context,
  scheme_ref: spec.SecuritySchemeRef,
  val_var: String,
  indent: Int,
) -> se.StringBuilder {
  case ctx.spec.components {
    Some(components) ->
      case dict.get(components.security_schemes, scheme_ref.scheme_name) {
        Ok(spec.ApiKeyScheme(name: header_name, in_: spec.SchemeInHeader)) ->
          sb
          |> se.indent(
            indent,
            "let req = request.set_header(req, \""
              <> string.lowercase(header_name)
              <> "\", "
              <> val_var
              <> ")",
          )
        Ok(spec.ApiKeyScheme(name: query_name, in_: spec.SchemeInQuery)) ->
          sb
          |> se.indent(
            indent,
            "let sep = case string.contains(req.path, \"?\") {",
          )
          |> se.indent(indent + 1, "True -> \"&\"")
          |> se.indent(indent + 1, "False -> \"?\"")
          |> se.indent(indent, "}")
          |> se.indent(
            indent,
            "let req = request.Request(..req, path: req.path <> sep <> \""
              <> query_name
              <> "=\" <> "
              <> val_var
              <> ")",
          )
        Ok(spec.ApiKeyScheme(name: cookie_name, in_: spec.SchemeInCookie)) ->
          sb
          |> se.indent(
            indent,
            "let existing = list.key_find(req.headers, \"cookie\") |> result.unwrap(\"\")",
          )
          |> se.indent(
            indent,
            "let cookie_val = \"" <> cookie_name <> "=\" <> " <> val_var,
          )
          |> se.indent(indent, "let new_cookie = case existing {")
          |> se.indent(indent + 1, "\"\" -> cookie_val")
          |> se.indent(indent + 1, "_ -> existing <> \"; \" <> cookie_val")
          |> se.indent(indent, "}")
          |> se.indent(
            indent,
            "let req = request.set_header(req, \"cookie\", new_cookie)",
          )
        Ok(spec.HttpScheme(scheme: "basic", ..)) ->
          sb
          |> se.indent(
            indent,
            "let req = request.set_header(req, \"authorization\", \"Basic \" <> "
              <> val_var
              <> ")",
          )
        Ok(spec.HttpScheme(scheme: "digest", ..)) ->
          sb
          |> se.indent(
            indent,
            "let req = request.set_header(req, \"authorization\", \"Digest \" <> "
              <> val_var
              <> ")",
          )
        Ok(spec.HttpScheme(scheme: "bearer", ..))
        | Ok(spec.OAuth2Scheme(..))
        | Ok(spec.OpenIdConnectScheme(..)) ->
          sb
          |> se.indent(
            indent,
            "let req = request.set_header(req, \"authorization\", \"Bearer \" <> "
              <> val_var
              <> ")",
          )
        Ok(spec.HttpScheme(scheme: scheme_name, ..)) ->
          sb
          |> se.indent(
            indent,
            "let req = request.set_header(req, \"authorization\", \""
              <> capitalize_first(scheme_name)
              <> " \" <> "
              <> val_var
              <> ")",
          )
        _ -> sb
      }
    _ -> sb
  }
}

/// Wrap a value expression with uri.percent_encode or not, based on allowReserved.
/// When allowReserved is true, reserved characters are sent as-is per OpenAPI spec.
fn maybe_percent_encode(value_expr: String, param: spec.Parameter) -> String {
  case param.allow_reserved {
    True -> value_expr
    False -> "uri.percent_encode(" <> value_expr <> ")"
  }
}
