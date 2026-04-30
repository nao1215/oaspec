import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oaspec/config
import oaspec/internal/codegen/client_request
import oaspec/internal/codegen/client_response
import oaspec/internal/codegen/client_security
import oaspec/internal/codegen/context.{
  type Context, type GeneratedFile, GeneratedFile,
}
import oaspec/internal/codegen/guards
import oaspec/internal/codegen/import_analysis
import oaspec/internal/codegen/ir_build
import oaspec/internal/openapi/operations
import oaspec/internal/openapi/resolver
import oaspec/internal/openapi/schema.{Inline, Reference}
import oaspec/internal/openapi/spec.{type Resolved, ParameterSchema, Value}
import oaspec/internal/util/content_type as ct_util
import oaspec/internal/util/http
import oaspec/internal/util/naming
import oaspec/internal/util/string_extra as se

/// Generate client SDK files.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let client_content = generate_client(ctx)

  [
    GeneratedFile(
      path: "client.gleam",
      content: client_content,
      target: context.ClientTarget,
      write_mode: context.Overwrite,
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

  let has_multipart =
    list.any(operations, fn(op) {
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

  let needs_list =
    has_form_urlencoded
    || has_multi_content_response
    || list.any(all_params, fn(p) { p.in_ == spec.InQuery })
    || list.any(all_params, fn(p) { p.in_ == spec.InCookie })
    || list.any(all_params, fn(p) { p.in_ == spec.InHeader })
    || list.any(all_params, fn(p) {
      case p.payload {
        ParameterSchema(Inline(schema.ArraySchema(..))) -> True
        ParameterSchema(Reference(..) as sr) ->
          case resolver.resolve_schema_ref(sr, context.spec(ctx)) {
            Ok(schema.ArraySchema(..)) -> True
            _ -> False
          }
        _ -> False
      }
    })

  let needs_dyn_decode =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) ->
            list.any(dict.to_list(response.content), fn(ce) {
              let #(media_type_name, mt) = ce
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

  let needs_string =
    has_multi_content_response
    || has_form_urlencoded
    || has_multipart
    || list.any(all_params, fn(p) {
      p.in_ == spec.InPath || p.in_ == spec.InCookie
    })

  // Decode/encode/types modules — same logic as before.
  let needs_typed_schemas =
    import_analysis.operations_need_typed_schemas(operations)

  // `type Option` is only referenced in operation signatures when
  // optional params / bodies exist; `Some` and `None` are also used
  // for the `base_url` field of every emitted `transport.Request`
  // literal, so we track them independently.
  let needs_option_type =
    import_analysis.operations_have_optional_params(operations)
    || import_analysis.operations_have_optional_body(operations)
  let needs_some_ctor =
    needs_option_type || any_operation_has_server(operations, ctx)
  let needs_none_ctor =
    needs_option_type || any_operation_has_no_server(operations, ctx)
  let option_import_items = case
    needs_option_type,
    needs_some_ctor,
    needs_none_ctor
  {
    True, _, _ -> Some("gleam/option.{type Option, None, Some}")
    False, True, True -> Some("gleam/option.{None, Some}")
    False, True, False -> Some("gleam/option.{Some}")
    False, False, True -> Some("gleam/option.{None}")
    False, False, False -> None
  }

  let needs_int =
    list.any(all_params, fn(p) {
      case p.payload {
        ParameterSchema(Inline(schema.IntegerSchema(..))) -> True
        ParameterSchema(Inline(schema.ArraySchema(
          items: Inline(schema.IntegerSchema(..)),
          ..,
        ))) -> True
        ParameterSchema(Reference(..) as sr) ->
          case resolver.resolve_schema_ref(sr, context.spec(ctx)) {
            Ok(schema.IntegerSchema(..)) -> True
            Ok(schema.ArraySchema(items: Inline(schema.IntegerSchema(..)), ..)) ->
              True
            _ -> False
          }
        _ -> False
      }
    })

  // Need binary helpers when any response declares binary content.
  let needs_bytes_helper =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) ->
            list.any(dict.to_list(response.content), fn(ce) {
              let #(name, _) = ce
              ct_util.from_string(name) == ct_util.ApplicationOctetStream
            })
          _ -> False
        }
      })
    })

  // Need text helpers when any response decodes a body — which is
  // basically every spec-decoded response. We compute this once here
  // so we can suppress the helper for spec'd-empty operations.
  let needs_text_helper =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) ->
            list.any(dict.to_list(response.content), fn(ce) {
              let #(_, mt) = ce
              case mt.schema {
                Some(_) -> True
                None -> False
              }
            })
          _ -> False
        }
      })
    })

  // result is always needed: every operation uses `use _ <- result.try`.
  let base_imports = [
    "gleam/result",
    "oaspec/transport",
    config.package(context.config(ctx)) <> "/decode",
    config.package(context.config(ctx)) <> "/response_types",
  ]
  let base_imports = case needs_int {
    True -> ["gleam/int", ..base_imports]
    False -> base_imports
  }
  let base_imports = case option_import_items {
    Some(import_line) -> [import_line, ..base_imports]
    None -> base_imports
  }
  let base_imports = case needs_typed_schemas {
    True ->
      list.append(
        [
          config.package(context.config(ctx)) <> "/types",
          config.package(context.config(ctx)) <> "/encode",
        ],
        base_imports,
      )
    False -> base_imports
  }
  // request_types is always needed (every operation emits a
  // _with_request wrapper).
  let base_imports = [
    config.package(context.config(ctx)) <> "/request_types",
    ..base_imports
  ]
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

  // uri for path-parameter percent-encoding, cookie value encoding, and
  // form-urlencoded body assembly.
  let needs_uri =
    has_form_urlencoded
    || list.any(all_params, fn(p) {
      p.in_ == spec.InPath || p.in_ == spec.InCookie
    })
  let imports = case needs_uri {
    True -> ["gleam/uri", ..imports]
    False -> imports
  }

  let needs_guards =
    config.validate(context.config(ctx))
    && list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(Value(rb)) -> {
          let content_entries = dict.to_list(rb.content)
          case content_entries {
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
    })
  let imports = case needs_guards {
    True -> [config.package(context.config(ctx)) <> "/guards", ..imports]
    False -> imports
  }

  let sb =
    se.file_header(context.version)
    |> se.imports(imports)

  // ClientError type
  let sb =
    sb
    |> se.doc_comment("HTTP client errors.")
    |> se.line("pub type ClientError {")
    |> se.indent(1, "TransportError(error: transport.TransportError)")
    |> se.indent(1, "DecodeFailure(detail: String)")
    |> se.indent(1, "InvalidResponse(detail: String)")
    |> se.indent(1, "UnexpectedStatus(")
    |> se.indent(2, "status: Int,")
    |> se.indent(2, "headers: List(#(String, String)),")
    |> se.indent(2, "body: transport.Body,")
    |> se.indent(1, ")")
  let sb = case needs_guards {
    True ->
      sb
      |> se.indent(1, "ValidationError(errors: List(guards.ValidationFailure))")
    False -> sb
  }
  let sb =
    sb
    |> se.line("}")
    |> se.blank_line()

  // default_base_url
  let sb = generate_default_base_url(sb, ctx)

  // text_body / bytes_body helpers
  let sb = case needs_text_helper {
    True -> generate_text_body_helper(sb)
    False -> sb
  }
  let sb = case needs_bytes_helper {
    True -> generate_bytes_body_helper(sb)
    False -> sb
  }

  // Operation functions
  let sb =
    list.fold(operations, sb, fn(sb, op) {
      let #(op_id, operation, path, method) = op
      generate_client_function(sb, op_id, operation, path, method, ctx)
    })

  se.to_string(sb)
}

fn any_operation_has_server(
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
  ctx: Context,
) -> Bool {
  list.any(operations, fn(op) {
    let #(_, operation, _, _) = op
    case operation.servers {
      [] ->
        case context.spec(ctx).servers {
          [] -> False
          _ -> True
        }
      _ -> True
    }
  })
}

fn any_operation_has_no_server(
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
  ctx: Context,
) -> Bool {
  list.any(operations, fn(op) {
    let #(_, operation, _, _) = op
    case operation.servers {
      [] -> list.is_empty(context.spec(ctx).servers)
      _ -> False
    }
  })
}

/// Substitute server variable placeholders.
fn substitute_server_variables(
  url: String,
  variables: List(#(String, spec.ServerVariable)),
) -> String {
  list.fold(variables, url, fn(acc, entry) {
    let #(name, variable) = entry
    string.replace(acc, "{" <> name <> "}", variable.default)
  })
}

/// Generate the default_base_url function (only when servers are declared).
fn generate_default_base_url(
  sb: se.StringBuilder,
  ctx: Context,
) -> se.StringBuilder {
  case context.spec(ctx).servers {
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
          |> se.doc_comment("Default base URL declared by the OpenAPI spec.")
        doc ->
          sb
          |> se.doc_comment("Default base URL declared by the OpenAPI spec.")
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

/// Emit the text_body helper that extracts a UTF-8 string from a
/// `transport.Body`, surfacing `InvalidResponse` for non-text bodies.
fn generate_text_body_helper(sb: se.StringBuilder) -> se.StringBuilder {
  sb
  |> se.line(
    "fn text_body(body: transport.Body) -> Result(String, ClientError) {",
  )
  |> se.indent(1, "case body {")
  |> se.indent(2, "transport.TextBody(text) -> Ok(text)")
  |> se.indent(
    2,
    "transport.BytesBody(_) -> Error(InvalidResponse(detail: \"expected text body, got bytes\"))",
  )
  |> se.indent(
    2,
    "transport.EmptyBody -> Error(InvalidResponse(detail: \"expected text body, got empty body\"))",
  )
  |> se.indent(1, "}")
  |> se.line("}")
  |> se.blank_line()
}

/// Emit the bytes_body helper for binary response bodies.
fn generate_bytes_body_helper(sb: se.StringBuilder) -> se.StringBuilder {
  sb
  |> se.line(
    "fn bytes_body(body: transport.Body) -> Result(BitArray, ClientError) {",
  )
  |> se.indent(1, "case body {")
  |> se.indent(2, "transport.BytesBody(bytes) -> Ok(bytes)")
  |> se.indent(
    2,
    "transport.TextBody(_) -> Error(InvalidResponse(detail: \"expected binary body, got text\"))",
  )
  |> se.indent(
    2,
    "transport.EmptyBody -> Error(InvalidResponse(detail: \"expected binary body, got empty body\"))",
  )
  |> se.indent(1, "}")
  |> se.line("}")
  |> se.blank_line()
}

fn emit_simple_query_param(
  sb: se.StringBuilder,
  p: spec.Parameter(Resolved),
  param_name: String,
  ctx: Context,
) -> se.StringBuilder {
  case p.required {
    True -> {
      let to_str = client_request.param_to_string_expr(p, param_name, ctx)
      sb
      |> se.indent(
        1,
        "let query = [#(\"" <> p.name <> "\", " <> to_str <> "), ..query]",
      )
    }
    False -> {
      let to_str = client_request.to_str_for_optional_value(p, ctx)
      sb
      |> se.indent(1, "let query = case " <> param_name <> " {")
      |> se.indent(
        2,
        "Some(v) -> [#(\"" <> p.name <> "\", " <> to_str <> "), ..query]",
      )
      |> se.indent(2, "None -> query")
      |> se.indent(1, "}")
    }
  }
}

fn http_method_to_transport(method: spec.HttpMethod) -> String {
  case method {
    spec.Get -> "transport.Get"
    spec.Post -> "transport.Post"
    spec.Put -> "transport.Put"
    spec.Delete -> "transport.Delete"
    spec.Patch -> "transport.Patch"
    spec.Head -> "transport.Head"
    spec.Options -> "transport.Options"
    spec.Trace -> "transport.Trace"
  }
}

/// Generate the three-function unit (op + build_*_request + decode_*_response)
/// for a single operation, plus the request-record wrapper.
fn generate_client_function(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation(Resolved),
  path: String,
  method: spec.HttpMethod,
  ctx: Context,
) -> se.StringBuilder {
  let fn_name = naming.operation_to_function_name(op_id)
  let build_fn = "build_" <> fn_name <> "_request"
  let decode_fn = "decode_" <> fn_name <> "_response"
  let response_type = naming.schema_to_type_name(op_id) <> "Response"

  let unwrapped_params =
    list.filter_map(operation.parameters, fn(ref_p) {
      case ref_p {
        Value(p) -> Ok(p)
        _ -> Error(Nil)
      }
    })

  let path_params =
    list.filter(unwrapped_params, fn(p) { p.in_ == spec.InPath })
  let query_params =
    list.filter(unwrapped_params, fn(p) { p.in_ == spec.InQuery })
  let header_params =
    list.filter(unwrapped_params, fn(p) { p.in_ == spec.InHeader })
  let cookie_params =
    list.filter(unwrapped_params, fn(p) { p.in_ == spec.InCookie })

  let params_signature =
    client_request.build_param_list(
      path_params,
      query_params,
      header_params,
      cookie_params,
      operation,
      op_id,
      ctx,
    )

  let call_args =
    build_call_args(
      path_params,
      query_params,
      header_params,
      cookie_params,
      operation,
      ctx,
    )

  // ------------------------------------------------------------
  // 1. The send-first composition function
  // ------------------------------------------------------------

  let sb = case operation.summary {
    Some(summary) -> sb |> se.doc_comment(summary)
    _ -> sb
  }
  let sb = case operation.description {
    Some(desc) -> sb |> se.doc_comment(desc)
    _ -> sb
  }
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

  let sb =
    sb
    |> se.line(
      "pub fn "
      <> fn_name
      <> "(send send: transport.Send"
      <> params_signature
      <> ") -> Result(response_types."
      <> response_type
      <> ", ClientError) {",
    )

  // Validation is handled inside build_<op>_request; here we just wire
  // build → send → decode.
  let sb =
    sb
    |> se.indent(1, "use req <- result.try(" <> build_fn <> call_args <> ")")
    |> se.indent(1, "use resp <- result.try(")
    |> se.indent(2, "send(req)")
    |> se.indent(2, "|> result.map_error(TransportError),")
    |> se.indent(1, ")")
    |> se.indent(1, decode_fn <> "(resp)")
    |> se.line("}")
    |> se.blank_line()

  // ------------------------------------------------------------
  // 2. build_<op>_request
  // ------------------------------------------------------------

  let sb =
    sb
    |> se.doc_comment(
      "Build the transport request for "
      <> fn_name
      <> " without sending it. Useful for testing and for adding custom transport middleware.",
    )
    |> se.line(
      "pub fn "
      <> build_fn
      <> "("
      <> trim_leading_comma(params_signature)
      <> ") -> Result(transport.Request, ClientError) {",
    )

  let sb =
    generate_build_body(
      sb,
      op_id,
      operation,
      path,
      method,
      path_params,
      query_params,
      header_params,
      cookie_params,
      ctx,
    )

  let sb = sb |> se.line("}") |> se.blank_line()

  // ------------------------------------------------------------
  // 3. decode_<op>_response
  // ------------------------------------------------------------

  let sb =
    sb
    |> se.doc_comment(
      "Decode a transport response into the typed response variant for "
      <> fn_name
      <> ".",
    )
    |> se.line(
      "pub fn "
      <> decode_fn
      <> "(resp: transport.Response) -> Result(response_types."
      <> response_type
      <> ", ClientError) {",
    )
    |> se.indent(1, "case resp.status {")

  let responses = http.sort_response_entries(dict.to_list(operation.responses))
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
                2,
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

  let has_default =
    list.any(responses, fn(entry) {
      let #(code, _) = entry
      code == http.DefaultStatus
    })
  let sb = case has_default {
    True -> sb
    False ->
      sb
      |> se.indent(2, "_ ->")
      |> se.indent(3, "Error(UnexpectedStatus(")
      |> se.indent(4, "status: resp.status,")
      |> se.indent(4, "headers: resp.headers,")
      |> se.indent(4, "body: resp.body,")
      |> se.indent(3, "))")
  }

  let sb =
    sb
    |> se.indent(1, "}")
    |> se.line("}")
    |> se.blank_line()

  // ------------------------------------------------------------
  // 4. <op>_with_request wrapper
  // ------------------------------------------------------------

  case
    client_request.build_request_object_call_args(
      path_params,
      query_params,
      header_params,
      cookie_params,
      operation,
    )
  {
    Some(call_args2) -> {
      let request_type = naming.schema_to_type_name(op_id) <> "Request"
      let extra = case call_args2 {
        "" -> ""
        _ -> ", " <> call_args2
      }
      sb
      |> se.doc_comment(
        "Request-object wrapper. Delegates to "
        <> fn_name
        <> " with fields unpacked from the request record.",
      )
      |> se.line(
        "pub fn "
        <> fn_name
        <> "_with_request(send send: transport.Send, request request: request_types."
        <> request_type
        <> ") -> Result(response_types."
        <> response_type
        <> ", ClientError) {",
      )
      |> se.indent(1, fn_name <> "(send" <> rebind_request_fields(extra) <> ")")
      |> se.line("}")
      |> se.blank_line()
    }
    None -> sb
  }
}

/// Build the call-args list passed from `<op>` to `build_<op>_request`.
fn build_call_args(
  path_params: List(spec.Parameter(Resolved)),
  query_params: List(spec.Parameter(Resolved)),
  header_params: List(spec.Parameter(Resolved)),
  cookie_params: List(spec.Parameter(Resolved)),
  operation: spec.Operation(Resolved),
  _ctx: Context,
) -> String {
  let all_params =
    list.append(path_params, query_params)
    |> list.append(header_params)
    |> list.append(cookie_params)
  let field_names = client_request.build_param_field_names(operation)

  let names =
    list.map(all_params, fn(p) {
      let field = client_request.field_name_for(field_names, p)
      field <> ": " <> field
    })

  let body_args = case operation.request_body {
    Some(Value(rb)) -> {
      let content_entries = ir_build.sorted_entries(rb.content)
      case content_entries {
        [_, _, ..] -> ["content_type: content_type", "body: body"]
        _ -> ["body: body"]
      }
    }
    _ -> []
  }

  let all = list.append(names, body_args)
  case all {
    [] -> "()"
    _ -> "(" <> string.join(all, ", ") <> ")"
  }
}

/// Replace `req.field` references in the rebuilt call args with the
/// `request.` prefix used by the `_with_request` wrapper. The shared
/// helper builds `req.foo, req.bar`; we keep that token shape but just
/// rename the prefix.
fn rebind_request_fields(extra: String) -> String {
  string.replace(extra, "req.", "request.")
}

/// Trim a leading ", " from a parameter list snippet so it can stand on
/// its own as the argument list of `build_<op>_request`.
fn trim_leading_comma(s: String) -> String {
  use <- bool.guard(!string.starts_with(s, ", "), s)
  string.drop_start(s, 2)
}

/// Body of `build_<op>_request`. Validates request body, builds path /
/// query / headers / body / security, and assembles the
/// `transport.Request` literal.
fn generate_build_body(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation(Resolved),
  path: String,
  method: spec.HttpMethod,
  path_params: List(spec.Parameter(Resolved)),
  query_params: List(spec.Parameter(Resolved)),
  header_params: List(spec.Parameter(Resolved)),
  cookie_params: List(spec.Parameter(Resolved)),
  ctx: Context,
) -> se.StringBuilder {
  let field_names = client_request.build_param_field_names(operation)

  // Validation guard.
  let client_guard_schema = case
    config.validate(context.config(ctx)),
    operation.request_body
  {
    True, Some(Value(rb)) -> {
      let content_entries = dict.to_list(rb.content)
      case content_entries {
        [#(_, mt)] ->
          case mt.schema {
            Some(schema.Reference(name:, ..)) ->
              case guards.schema_has_validator(name, ctx) {
                True -> Some(#(name, rb.required))
                False -> None
              }
            _ -> None
          }
        _ -> None
      }
    }
    _, _ -> None
  }

  let sb = case client_guard_schema {
    Some(#(name, True)) -> {
      let validate_fn =
        "guards.validate_" <> naming.to_snake_case(name) <> "(body)"
      sb
      |> se.indent(1, "case " <> validate_fn <> " {")
      |> se.indent(2, "Error(errors) -> Error(ValidationError(errors:))")
      |> se.indent(2, "Ok(_) -> {")
    }
    Some(#(name, False)) -> {
      let validate_fn = "guards.validate_" <> naming.to_snake_case(name)
      sb
      |> se.indent(1, "let validation_errors = case body {")
      |> se.indent(2, "Some(b) -> case " <> validate_fn <> "(b) {")
      |> se.indent(3, "Error(errors) -> errors")
      |> se.indent(3, "Ok(_) -> []")
      |> se.indent(2, "}")
      |> se.indent(2, "None -> []")
      |> se.indent(1, "}")
      |> se.indent(1, "case validation_errors {")
      |> se.indent(
        2,
        "[_, ..] -> Error(ValidationError(errors: validation_errors))",
      )
      |> se.indent(2, "[] -> {")
    }
    None -> sb
  }

  // Determine effective base URL.
  let effective_server_url = case operation.servers {
    [first_server, ..] -> {
      let variables = ir_build.sorted_entries(first_server.variables)
      let resolved = substitute_server_variables(first_server.url, variables)
      Some(resolved)
    }
    [] ->
      case context.spec(ctx).servers {
        [_, ..] -> Some("default_base_url()")
        [] -> None
      }
  }

  // Wrap the path-parameter substitution in a let.
  let sb = sb |> se.indent(1, "let path = \"" <> path <> "\"")
  let sb =
    list.fold(path_params, sb, fn(sb, p) {
      let param_name = client_request.field_name_for(field_names, p)
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

  // Query as List(#(String, String)) — raw values, adapter encodes.
  let sb = case list.is_empty(query_params) {
    True -> sb |> se.indent(1, "let query = []")
    False -> {
      let sb = sb |> se.indent(1, "let query = []")
      let sb =
        list.fold(query_params, sb, fn(sb, p) {
          let param_name = client_request.field_name_for(field_names, p)
          case client_request.is_exploded_array_param(p, ctx) {
            True ->
              client_request.generate_exploded_array_query_param(
                sb,
                p,
                param_name,
                ctx,
              )
            False ->
              case client_request.is_delimited_array_param(p, ctx) {
                Some(joiner) ->
                  client_request.generate_delimited_array_query_param(
                    sb,
                    p,
                    param_name,
                    joiner,
                    ctx,
                  )
                None -> emit_simple_query_param(sb, p, param_name, ctx)
              }
          }
        })
      sb |> se.indent(1, "let query = list.reverse(query)")
    }
  }

  // Headers.
  let sb = sb |> se.indent(1, "let headers = []")

  let sb =
    list.fold(header_params, sb, fn(sb, p) {
      let param_name = client_request.field_name_for(field_names, p)
      let header_name = string.lowercase(p.name)
      case p.required {
        True -> {
          let to_str = client_request.param_to_string_expr(p, param_name, ctx)
          sb
          |> se.indent(
            1,
            "let headers = [#(\""
              <> header_name
              <> "\", "
              <> to_str
              <> "), ..headers]",
          )
        }
        False -> {
          let to_str = client_request.to_str_for_optional_value(p, ctx)
          sb
          |> se.indent(1, "let headers = case " <> param_name <> " {")
          |> se.indent(
            2,
            "Some(v) -> [#(\""
              <> header_name
              <> "\", "
              <> to_str
              <> "), ..headers]",
          )
          |> se.indent(2, "None -> headers")
          |> se.indent(1, "}")
        }
      }
    })

  // Cookies bundled into a single "cookie" header.
  let sb = case list.is_empty(cookie_params) {
    True -> sb
    False -> {
      let sb = sb |> se.indent(1, "let cookie_parts = []")
      let sb =
        list.fold(cookie_params, sb, fn(sb, p) {
          let param_name = client_request.field_name_for(field_names, p)
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
      |> se.indent(1, "let headers = case cookie_parts {")
      |> se.indent(2, "[] -> headers")
      |> se.indent(
        2,
        "_ -> [#(\"cookie\", string.join(cookie_parts, \"; \")), ..headers]",
      )
      |> se.indent(1, "}")
    }
  }

  // Reverse only when something was prepended; an empty list is a
  // no-op for `list.reverse` but still requires the import.
  let needs_reverse =
    !list.is_empty(header_params) || !list.is_empty(cookie_params)
  let sb = case needs_reverse {
    True -> sb |> se.indent(1, "let headers = list.reverse(headers)")
    False -> sb
  }

  // Body.
  let sb = case operation.request_body {
    Some(Value(rb)) -> generate_body_emission(sb, rb, op_id, ctx)
    _ -> sb |> se.indent(1, "let body = transport.EmptyBody")
  }

  // Body content-type header.
  let sb = case operation.request_body {
    Some(Value(rb)) -> {
      let content_entries = ir_build.sorted_entries(rb.content)
      let ct_expr = case content_entries {
        // Multi-content: user-provided value via `content_type:` arg.
        [_, _, ..] -> "content_type"
        // multipart/form-urlencoded: helper left `body_content_type`
        // in scope (boundary-augmented for multipart).
        [#("multipart/form-data", _)] -> "body_content_type"
        [#("application/x-www-form-urlencoded", _)] -> "body_content_type"
        [#(static_ct, _)] -> "\"" <> static_ct <> "\""
        [] -> ""
      }
      case ct_expr {
        "" -> sb
        ct -> {
          let header_line = "[#(\"content-type\", " <> ct <> "), ..headers]"
          case rb.required {
            True -> sb |> se.indent(1, "let headers = " <> header_line)
            False ->
              sb
              |> se.indent(1, "let headers = case body {")
              |> se.indent(2, "transport.EmptyBody -> headers")
              |> se.indent(2, "_ -> " <> header_line)
              |> se.indent(1, "}")
          }
        }
      }
    }
    _ -> sb
  }

  // Base URL.
  let base_url_expr = case effective_server_url {
    Some("default_base_url()") -> "Some(default_base_url())"
    Some(url) -> "Some(\"" <> url <> "\")"
    None -> "None"
  }

  // Security metadata.
  let effective_security = case operation.security {
    Some(sec) -> sec
    None -> context.spec(ctx).security
  }
  let security_literal =
    client_security.render_security_metadata(ctx, effective_security)

  let http_method = http_method_to_transport(method)

  // Assemble the request literal.
  let sb =
    sb
    |> se.indent(1, "Ok(transport.Request(")
    |> se.indent(2, "method: " <> http_method <> ",")
    |> se.indent(2, "base_url: " <> base_url_expr <> ",")
    |> se.indent(2, "path: path,")
    |> se.indent(2, "query: query,")
    |> se.indent(2, "headers: headers,")
    |> se.indent(2, "body: body,")
    |> se.indent(2, "security: " <> security_literal <> ",")
    |> se.indent(1, "))")

  // Close validation wrapper.
  case client_guard_schema {
    Some(_) ->
      sb
      |> se.indent(1, "}")
      |> se.indent(1, "}")
    None -> sb
  }
}

/// Emit the body construction. Sets `body: transport.Body` in the
/// generated scope. Multi-content uses the user-provided `body: String`
/// directly; single-content encodes per its schema.
fn generate_body_emission(
  sb: se.StringBuilder,
  rb: spec.RequestBody(Resolved),
  op_id: String,
  ctx: Context,
) -> se.StringBuilder {
  let content_entries = ir_build.sorted_entries(rb.content)
  case content_entries {
    [_, _, ..] -> {
      case rb.required {
        True -> sb |> se.indent(1, "let body = transport.TextBody(body)")
        False ->
          sb
          |> se.indent(1, "let body = case body {")
          |> se.indent(2, "Some(b) -> transport.TextBody(b)")
          |> se.indent(2, "None -> transport.EmptyBody")
          |> se.indent(1, "}")
      }
    }
    [#(content_type_key, _)] ->
      case content_type_key {
        "application/octet-stream" ->
          case rb.required {
            True -> sb |> se.indent(1, "let body = transport.BytesBody(body)")
            False ->
              sb
              |> se.indent(1, "let body = case body {")
              |> se.indent(2, "Some(b) -> transport.BytesBody(b)")
              |> se.indent(2, "None -> transport.EmptyBody")
              |> se.indent(1, "}")
          }
        "multipart/form-data" ->
          generate_multipart_body_emission(sb, rb, op_id, ctx)
        "application/x-www-form-urlencoded" ->
          generate_form_urlencoded_body_emission(sb, rb, op_id, ctx)
        "text/plain" ->
          // Plain-text bodies must travel as the raw string the caller
          // supplies. The default `_ ->` arm runs the value through the
          // schema-aware encoder, which would JSON-quote a string schema —
          // that's wrong for text/plain (the wire payload would be
          // `"foo"` instead of `foo`).
          case rb.required {
            True -> sb |> se.indent(1, "let body = transport.TextBody(body)")
            False ->
              sb
              |> se.indent(1, "let body = case body {")
              |> se.indent(2, "Some(b) -> transport.TextBody(b)")
              |> se.indent(2, "None -> transport.EmptyBody")
              |> se.indent(1, "}")
          }
        _ -> {
          let encode_expr = client_request.get_body_encode_expr(rb, op_id, ctx)
          case rb.required {
            True ->
              sb
              |> se.indent(
                1,
                "let body = transport.TextBody(" <> encode_expr <> ")",
              )
            False ->
              sb
              |> se.indent(1, "let body = case body {")
              |> se.indent(
                2,
                "Some(body) -> transport.TextBody(" <> encode_expr <> ")",
              )
              |> se.indent(2, "None -> transport.EmptyBody")
              |> se.indent(1, "}")
          }
        }
      }
    [] -> sb |> se.indent(1, "let body = transport.EmptyBody")
  }
}

fn generate_multipart_body_emission(
  sb: se.StringBuilder,
  rb: spec.RequestBody(Resolved),
  op_id: String,
  ctx: Context,
) -> se.StringBuilder {
  // Reuse the existing multipart string builder, but redirect its final
  // assembly to a `body` value rather than calling `request.set_body`.
  let sb = client_request.generate_multipart_body(sb, rb, op_id, ctx)
  // The helper leaves `body_str` and `boundary` in scope.
  sb
  |> se.indent(1, "let body = transport.TextBody(body_str)")
}

fn generate_form_urlencoded_body_emission(
  sb: se.StringBuilder,
  rb: spec.RequestBody(Resolved),
  op_id: String,
  ctx: Context,
) -> se.StringBuilder {
  let sb = client_request.generate_form_urlencoded_body(sb, rb, op_id, ctx)
  sb
  |> se.indent(1, "let body = transport.TextBody(body_str)")
}
