import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oaspec/codegen/client_request
import oaspec/codegen/client_response
import oaspec/codegen/client_security
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/ir_build
import oaspec/openapi/operations
import oaspec/openapi/resolver
import oaspec/openapi/schema.{Inline, Reference}
import oaspec/openapi/spec.{type Resolved, ParameterSchema, Value}
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
  let operations = operations.collect_operations(ctx)

  // Determine which imports are needed based on parameter types
  let all_params =
    list.flat_map(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.filter_map(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) -> Ok(p)
          _ -> Error(Nil)
        }
      })
    })
  let needs_bool =
    list.any(all_params, fn(p) {
      case p.payload {
        ParameterSchema(Inline(schema.BooleanSchema(..))) -> True
        _ -> False
      }
    })
  let needs_float =
    list.any(all_params, fn(p) {
      case p.payload {
        ParameterSchema(Inline(schema.NumberSchema(..))) -> True
        _ -> False
      }
    })
  let has_multi_content_response =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) -> list.length(dict.to_list(response.content)) > 1
          _ -> False
        }
      })
    })

  // Check if any operation has a form-urlencoded request body
  let has_form_urlencoded =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(Value(rb)) ->
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
      case p.payload {
        ParameterSchema(Inline(schema.ArraySchema(..))) -> True
        ParameterSchema(Reference(..) as sr) ->
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
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) ->
            list.any(dict.to_list(response.content), fn(ce) {
              let #(media_type_name, mt) = ce
              // text/plain responses don't need dyn_decode (body returned directly)
              case media_type_name {
                "text/plain" -> False
                _ ->
                  case mt.schema {
                    Some(Inline(schema.ArraySchema(items: Inline(_), ..))) ->
                      True
                    Some(Inline(schema.StringSchema(..))) -> True
                    Some(Inline(schema.IntegerSchema(..))) -> True
                    Some(Inline(schema.NumberSchema(..))) -> True
                    Some(Inline(schema.BooleanSchema(..))) -> True
                    _ -> False
                  }
              }
            })
          _ -> False
        }
      })
    })

  // json needed for inline primitive body encoding (without dyn_decode)
  let needs_json =
    needs_dyn_decode
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(Value(rb)) ->
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
        Some(Value(rb)) ->
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
          #(_, spec.Value(spec.ApiKeyScheme(in_: spec.SchemeInQuery, ..))) ->
            True
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
        Some(Value(rb)) ->
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
        list.any(operation.parameters, fn(ref_p) {
          case ref_p {
            Value(p) ->
              case p.payload {
                ParameterSchema(Reference(..)) -> True
                _ -> False
              }
            _ -> False
          }
        })
      has_ref_body || has_ref_params
    })

  let needs_option =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) -> !p.required
          _ -> False
        }
      })
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
          #(_, spec.Value(spec.ApiKeyScheme(in_: spec.SchemeInCookie, ..))) ->
            True
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
    Some(components) -> ir_build.sorted_entries(components.security_schemes)
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
      let variables = ir_build.sorted_entries(first_server.variables)
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
    [] -> sb
  }
}

/// Generate a client function for a single operation.
fn generate_client_function(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation(Resolved),
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
    Some(Value(rb)) -> {
      let content_entries = ir_build.sorted_entries(rb.content)
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

  let unwrapped_params =
    list.filter_map(operation.parameters, fn(ref_p) {
      case ref_p {
        Value(p) -> Ok(p)
        _ -> Error(Nil)
      }
    })

  let path_params =
    list.filter(unwrapped_params, fn(p) {
      case p.in_ {
        spec.InPath -> True
        _ -> False
      }
    })

  let query_params =
    list.filter(unwrapped_params, fn(p) {
      case p.in_ {
        spec.InQuery -> True
        _ -> False
      }
    })

  let header_params =
    list.filter(unwrapped_params, fn(p) {
      case p.in_ {
        spec.InHeader -> True
        _ -> False
      }
    })

  let cookie_params =
    list.filter(unwrapped_params, fn(p) {
      case p.in_ {
        spec.InCookie -> True
        _ -> False
      }
    })

  // Function signature
  let response_type = naming.schema_to_type_name(op_id) <> "Response"
  let params =
    client_request.build_param_list(
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
      let to_string_expr =
        client_request.param_to_string_expr(p, param_name, ctx)
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
          case p.style, client_request.is_deep_object_param(p, ctx) {
            Some(spec.DeepObjectStyle), True ->
              client_request.generate_deep_object_query_param(
                sb,
                p,
                param_name,
                ctx,
              )
            _, _ ->
              case client_request.is_exploded_array_param(p, ctx) {
                True ->
                  client_request.generate_exploded_array_query_param(
                    sb,
                    p,
                    param_name,
                    ctx,
                  )
                False ->
                  case p.required {
                    True -> {
                      let to_str =
                        client_request.to_str_for_required(p, param_name, ctx)
                      let encoded =
                        client_security.maybe_percent_encode(to_str, p)
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
                      let to_str =
                        client_request.to_str_for_optional_value(p, ctx)
                      let encoded =
                        client_security.maybe_percent_encode(to_str, p)
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
    Some(Value(rb)) -> {
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
      let content_entries = ir_build.sorted_entries(rb.content)
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
            "multipart/form-data" ->
              client_request.generate_multipart_body(sb, rb, op_id, ctx)
            "application/x-www-form-urlencoded" ->
              client_request.generate_form_urlencoded_body(sb, rb, op_id, ctx)
            _ -> {
              let body_encode_expr =
                client_request.get_body_encode_expr(rb, op_id, ctx)
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
          let to_str = client_request.param_to_string_expr(p, param_name, ctx)
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
          let to_str = client_request.to_str_for_optional_value(p, ctx)
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
              let to_str =
                client_request.param_to_string_expr(p, param_name, ctx)
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
              let to_str = client_request.to_str_for_optional_value(p, ctx)
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
      client_security.generate_security_or_chain(sb, ctx, alternatives, 1)
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
      let #(status_code, ref_or) = entry
      case ref_or {
        Value(response) -> {
          let variant_name =
            "response_types."
            <> naming.schema_to_type_name(op_id)
            <> "Response"
            <> http.status_code_suffix(status_code)
          let content_entries = ir_build.sorted_entries(response.content)
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
              client_response.generate_single_content_response(
                sb,
                status_code,
                variant_name,
                single_ct,
                single_mt,
                op_id,
                ctx,
              )
            multiple ->
              client_response.generate_multi_content_response(
                sb,
                status_code,
                variant_name,
                multiple,
                op_id,
                ctx,
              )
          }
        }
        _ -> sb
      }
    })

  // Only add a fallback _ branch if no "default" response exists
  let has_default =
    list.any(responses, fn(entry) {
      let #(code, _) = entry
      code == http.DefaultStatus
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
