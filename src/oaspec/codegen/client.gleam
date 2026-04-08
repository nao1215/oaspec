import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/string
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/types as type_gen
import oaspec/openapi/resolver
import oaspec/openapi/schema.{
  Inline, IntegerSchema, NumberSchema, Reference, StringSchema,
}
import oaspec/openapi/spec
import oaspec/util/http
import oaspec/util/naming
import oaspec/util/string_extra as se

/// Generate client SDK files.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let client_content = generate_client(ctx)

  [GeneratedFile(path: "client.gleam", content: client_content)]
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
  let needs_list =
    list.any(all_params, fn(p) {
      case p.schema {
        Some(Inline(schema.ArraySchema(..))) -> True
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
  // security query apiKey, and multipart/form-data body building
  let needs_string =
    list.any(operations, fn(op) {
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
          #(_, spec.ApiKeyScheme(in_: "query", ..)) -> True
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
              Some(Reference(_)) -> True
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
            Some(Reference(_)) -> True
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

  // uri module needed for percent-encoding parameter values
  let needs_uri =
    list.any(operations, fn(op) {
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
          #(_, spec.ApiKeyScheme(in_: "cookie", ..)) -> True
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

  // Generate operation functions
  let sb =
    list.fold(operations, sb, fn(sb, op) {
      let #(op_id, operation, path, method) = op
      generate_client_function(sb, op_id, operation, path, method, ctx)
    })

  se.to_string(sb)
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
          case p.required {
            True -> {
              let to_str = to_str_for_required(p, param_name, ctx)
              sb
              |> se.indent(
                1,
                "let query_parts = [\""
                  <> p.name
                  <> "=\" <> uri.percent_encode("
                  <> to_str
                  <> "), ..query_parts]",
              )
            }
            False -> {
              let to_str = to_str_for_optional_value(p, ctx)
              sb
              |> se.indent(1, "let query_parts = case " <> param_name <> " {")
              |> se.indent(
                2,
                "Some(v) -> [\""
                  <> p.name
                  <> "=\" <> uri.percent_encode("
                  <> to_str
                  <> "), ..query_parts]",
              )
              |> se.indent(2, "None -> query_parts")
              |> se.indent(1, "}")
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
  }

  let sb =
    sb
    |> se.indent(1, "let assert Ok(req) = request.to(config.base_url <> path)")
    |> se.indent(1, "let req = request.set_method(req, " <> http_method <> ")")

  // Only set content-type for requests with body
  let sb = case operation.request_body {
    Some(rb) -> {
      let content_entries = dict.to_list(rb.content)
      let is_multipart = case content_entries {
        [#("multipart/form-data", _), ..] -> True
        _ -> False
      }
      case is_multipart {
        True -> generate_multipart_body(sb, rb, op_id, ctx)
        False -> {
          let body_encode_expr = get_body_encode_expr(rb, op_id, ctx)
          sb
          |> se.indent(
            1,
            "let req = request.set_header(req, \"content-type\", \"application/json\")",
          )
          |> se.indent(
            1,
            "let req = request.set_body(req, " <> body_encode_expr <> ")",
          )
        }
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

  // Apply security schemes.
  // OpenAPI security is OR of alternatives; each alternative is AND of
  // schemes. We apply ALL scheme refs from the FIRST alternative only,
  // since the generated client cannot dynamically choose at runtime.
  let effective_security = option.unwrap(operation.security, [])
  let first_alternative_schemes = case effective_security {
    [first, ..] -> first.schemes
    [] -> []
  }
  let sb =
    list.fold(first_alternative_schemes, sb, fn(sb, sec_ref) {
      let field_name = naming.to_snake_case(sec_ref.scheme_name)
      // Look up the scheme definition
      case ctx.spec.components {
        Some(components) ->
          case dict.get(components.security_schemes, sec_ref.scheme_name) {
            Ok(spec.ApiKeyScheme(name: header_name, in_: "header")) ->
              sb
              |> se.indent(1, "let req = case config." <> field_name <> " {")
              |> se.indent(
                2,
                "Some(key) -> request.set_header(req, \""
                  <> string.lowercase(header_name)
                  <> "\", key)",
              )
              |> se.indent(2, "None -> req")
              |> se.indent(1, "}")
            Ok(spec.ApiKeyScheme(name: query_name, in_: "query")) ->
              sb
              |> se.indent(1, "let req = case config." <> field_name <> " {")
              |> se.indent(2, "Some(key) -> {")
              |> se.indent(
                3,
                "let sep = case string.contains(req.path, \"?\") {",
              )
              |> se.indent(4, "True -> \"&\"")
              |> se.indent(4, "False -> \"?\"")
              |> se.indent(3, "}")
              |> se.indent(
                3,
                "request.Request(..req, path: req.path <> sep <> \""
                  <> query_name
                  <> "=\" <> key)",
              )
              |> se.indent(2, "}")
              |> se.indent(2, "None -> req")
              |> se.indent(1, "}")
            Ok(spec.ApiKeyScheme(name: cookie_name, in_: "cookie")) ->
              sb
              |> se.indent(1, "let req = case config." <> field_name <> " {")
              |> se.indent(2, "Some(value) -> {")
              |> se.indent(
                3,
                "let existing = list.key_find(req.headers, \"cookie\") |> result.unwrap(\"\")",
              )
              |> se.indent(
                3,
                "let cookie_val = \"" <> cookie_name <> "=\" <> value",
              )
              |> se.indent(3, "let new_cookie = case existing {")
              |> se.indent(4, "\"\" -> cookie_val")
              |> se.indent(4, "_ -> existing <> \"; \" <> cookie_val")
              |> se.indent(3, "}")
              |> se.indent(3, "request.set_header(req, \"cookie\", new_cookie)")
              |> se.indent(2, "}")
              |> se.indent(2, "None -> req")
              |> se.indent(1, "}")
            Ok(spec.HttpScheme(scheme: "basic", ..)) ->
              sb
              |> se.indent(1, "let req = case config." <> field_name <> " {")
              |> se.indent(
                2,
                "Some(token) -> request.set_header(req, \"authorization\", \"Basic \" <> token)",
              )
              |> se.indent(2, "None -> req")
              |> se.indent(1, "}")
            Ok(spec.HttpScheme(scheme: "digest", ..)) ->
              sb
              |> se.indent(1, "let req = case config." <> field_name <> " {")
              |> se.indent(
                2,
                "Some(token) -> request.set_header(req, \"authorization\", \"Digest \" <> token)",
              )
              |> se.indent(2, "None -> req")
              |> se.indent(1, "}")
            Ok(spec.HttpScheme(scheme: "bearer", ..))
            | Ok(spec.OAuth2Scheme(..)) ->
              sb
              |> se.indent(1, "let req = case config." <> field_name <> " {")
              |> se.indent(
                2,
                "Some(token) -> request.set_header(req, \"authorization\", \"Bearer \" <> token)",
              )
              |> se.indent(2, "None -> req")
              |> se.indent(1, "}")
            _ -> sb
          }
        _ -> sb
      }
    })

  // Send request and decode response into typed variant
  let sb =
    sb
    |> se.indent(1, "case config.send(req) {")
    |> se.indent(2, "Error(e) -> Error(e)")
    |> se.indent(2, "Ok(resp) -> {")

  let responses = dict.to_list(operation.responses)
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
        [#(media_type_name, media_type), ..] ->
          case media_type_name {
            // text/plain responses: return the body string directly
            "text/plain" ->
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
            // JSON and other content types: decode the response body
            _ ->
              case media_type.schema {
                Some(schema_ref) -> {
                  let decode_expr =
                    get_response_decode_expr(
                      schema_ref,
                      op_id,
                      status_code,
                      ctx,
                    )
                  sb
                  |> se.indent(
                    4,
                    http.status_code_to_int_pattern(status_code) <> " -> {",
                  )
                  |> se.indent(5, "case " <> decode_expr <> " {")
                  |> se.indent(
                    6,
                    "Ok(decoded) -> Ok(" <> variant_name <> "(decoded))",
                  )
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
      [", body: " <> body_type]
    }
    _ -> []
  }

  string.join(list.append(param_strs, body_param), "")
}

/// Convert a parameter to its Gleam type string.
fn param_to_type(param: spec.Parameter, _ctx: Context) -> String {
  let base = case param.schema {
    Some(Inline(StringSchema(..))) -> "String"
    Some(Inline(IntegerSchema(..))) -> "Int"
    Some(Inline(schema.NumberSchema(..))) -> "Float"
    Some(Inline(schema.BooleanSchema(..))) -> "Bool"
    Some(Inline(schema.ArraySchema(items:, ..))) -> {
      let item_type = case items {
        Inline(StringSchema(..)) -> "String"
        Inline(IntegerSchema(..)) -> "Int"
        Inline(schema.NumberSchema(..)) -> "Float"
        Inline(schema.BooleanSchema(..)) -> "Bool"
        Reference(ref:) ->
          "types." <> naming.schema_to_type_name(resolver.ref_to_name(ref))
        _ -> "String"
      }
      "List(" <> item_type <> ")"
    }
    Some(Reference(ref:)) ->
      "types." <> naming.schema_to_type_name(resolver.ref_to_name(ref))
    _ -> "String"
  }
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
    Some(Inline(IntegerSchema(..))) -> "int.to_string(" <> param_name <> ")"
    Some(Inline(NumberSchema(..))) -> "float.to_string(" <> param_name <> ")"
    Some(Inline(schema.BooleanSchema(..))) ->
      "bool.to_string(" <> param_name <> ")"
    Some(Inline(schema.ArraySchema(items:, ..))) -> {
      let item_to_str = array_item_to_string_fn(items, ctx)
      "string.join(list.map("
      <> param_name
      <> ", "
      <> item_to_str
      <> "), \",\")"
    }
    Some(Reference(ref:) as schema_ref) -> {
      // Resolve the $ref to determine the actual schema type
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(StringSchema(enum_values:, ..)) if enum_values != [] -> {
          let name = resolver.ref_to_name(ref)
          "encode.encode_"
          <> naming.to_snake_case(name)
          <> "_to_string("
          <> param_name
          <> ")"
        }
        Ok(schema.ArraySchema(items:, ..)) -> {
          let item_to_str = array_item_to_string_fn(items, ctx)
          "string.join(list.map("
          <> param_name
          <> ", "
          <> item_to_str
          <> "), \",\")"
        }
        Ok(IntegerSchema(..)) -> "int.to_string(" <> param_name <> ")"
        Ok(NumberSchema(..)) -> "float.to_string(" <> param_name <> ")"
        Ok(schema.BooleanSchema(..)) -> "bool.to_string(" <> param_name <> ")"
        Ok(StringSchema(..)) -> param_name
        _ -> param_name
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
    Some(Inline(IntegerSchema(..))) -> "int.to_string(v)"
    Some(Inline(NumberSchema(..))) -> "float.to_string(v)"
    Some(Inline(schema.BooleanSchema(..))) -> "bool.to_string(v)"
    Some(Inline(schema.ArraySchema(items:, ..))) -> {
      let item_to_str = array_item_to_string_fn(items, ctx)
      "string.join(list.map(v, " <> item_to_str <> "), \",\")"
    }
    Some(Reference(ref:) as schema_ref) -> {
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(StringSchema(enum_values:, ..)) if enum_values != [] -> {
          let name = resolver.ref_to_name(ref)
          "encode.encode_" <> naming.to_snake_case(name) <> "_to_string(v)"
        }
        Ok(schema.ArraySchema(items:, ..)) -> {
          let item_to_str = array_item_to_string_fn(items, ctx)
          "string.join(list.map(v, " <> item_to_str <> "), \",\")"
        }
        Ok(IntegerSchema(..)) -> "int.to_string(v)"
        Ok(NumberSchema(..)) -> "float.to_string(v)"
        Ok(schema.BooleanSchema(..)) -> "bool.to_string(v)"
        Ok(StringSchema(..)) -> "v"
        _ -> "v"
      }
    }
    _ -> "v"
  }
}

/// Get the Gleam type for a request body parameter.
fn get_body_type(rb: spec.RequestBody, op_id: String) -> String {
  let content_entries = dict.to_list(rb.content)
  case content_entries {
    [#(_, media_type), ..] ->
      case media_type.schema {
        Some(Reference(ref:)) ->
          "types." <> naming.schema_to_type_name(resolver.ref_to_name(ref))
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
        Some(Reference(ref:)) -> {
          let name = resolver.ref_to_name(ref)
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
        Some(Reference(ref:) as schema_ref) ->
          case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
            Ok(schema.ObjectSchema(properties:, required:, ..)) -> {
              let _ = ref
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
    Reference(_) as schema_ref ->
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
  case field_schema {
    Inline(schema.IntegerSchema(..)) -> "int.to_string"
    Inline(schema.NumberSchema(..)) -> "float.to_string"
    Inline(schema.BooleanSchema(..)) -> "bool.to_string"
    Reference(ref:) as schema_ref ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(schema.StringSchema(enum_values:, ..)) if enum_values != [] -> {
          let name = resolver.ref_to_name(ref)
          "encode.encode_" <> naming.to_snake_case(name) <> "_to_string"
        }
        Ok(schema.IntegerSchema(..)) -> "int.to_string"
        Ok(schema.NumberSchema(..)) -> "float.to_string"
        Ok(schema.BooleanSchema(..)) -> "bool.to_string"
        _ -> ""
      }
    _ -> ""
  }
}

/// Get the decode expression for a response body.
fn get_response_decode_expr(
  schema_ref: schema.SchemaRef,
  op_id: String,
  status_code: String,
  _ctx: Context,
) -> String {
  case schema_ref {
    Reference(ref:) -> {
      let name = resolver.ref_to_name(ref)
      "decode.decode_" <> naming.to_snake_case(name) <> "(resp.body)"
    }
    Inline(schema.ArraySchema(items:, ..)) ->
      case items {
        Reference(ref:) -> {
          let name = resolver.ref_to_name(ref)
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
  case items {
    Inline(IntegerSchema(..)) -> "int.to_string"
    Inline(NumberSchema(..)) -> "float.to_string"
    Inline(schema.BooleanSchema(..)) -> "bool.to_string"
    Inline(StringSchema(..)) -> "fn(x) { x }"
    Reference(ref:) -> {
      case resolver.resolve_schema_ref(items, ctx.spec) {
        Ok(StringSchema(enum_values:, ..)) if enum_values != [] -> {
          let name = resolver.ref_to_name(ref)
          "encode.encode_" <> naming.to_snake_case(name) <> "_to_string"
        }
        Ok(IntegerSchema(..)) -> "int.to_string"
        Ok(NumberSchema(..)) -> "float.to_string"
        Ok(schema.BooleanSchema(..)) -> "bool.to_string"
        Ok(StringSchema(..)) -> "fn(x) { x }"
        _ -> "fn(x) { x }"
      }
    }
    _ -> "fn(x) { x }"
  }
}
