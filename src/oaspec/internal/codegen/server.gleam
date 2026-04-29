import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oaspec/config
import oaspec/internal/codegen/context.{
  type Context, type GeneratedFile, GeneratedFile,
}
import oaspec/internal/codegen/guards
import oaspec/internal/codegen/import_analysis
import oaspec/internal/codegen/server_request_decode as decode_helpers
import oaspec/internal/openapi/dedup
import oaspec/internal/openapi/operations
import oaspec/internal/openapi/schema.{Inline, Reference}
import oaspec/internal/openapi/spec.{type Resolved, Value}
import oaspec/internal/util/content_type
import oaspec/internal/util/http
import oaspec/internal/util/naming
import oaspec/internal/util/string_extra as se

/// Generate server stub files.
///
/// Issue #247 splits the handler surface in two:
///
/// - `handlers.gleam` carries user-editable panic stubs and is emitted
///   only on first generation (`SkipIfExists`). Re-running
///   `oaspec generate` leaves it alone, so user implementations
///   survive regeneration.
/// - `handlers_generated.gleam` is a sealed delegator that `router.gleam`
///   imports. Each operation forwards to `handlers.<op_name>(req)`. It
///   is always overwritten so the wiring stays in lock-step with the
///   spec.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let operations = operations.collect_operations(ctx)
  let handlers_content = generate_handlers(ctx, operations)
  let handlers_generated_content = generate_handlers_generated(ctx, operations)
  let router_content = generate_router(ctx, operations)

  [
    GeneratedFile(
      path: "handlers.gleam",
      content: handlers_content,
      target: context.ServerTarget,
      write_mode: context.SkipIfExists,
    ),
    GeneratedFile(
      path: "handlers_generated.gleam",
      content: handlers_generated_content,
      target: context.ServerTarget,
      write_mode: context.Overwrite,
    ),
    GeneratedFile(
      path: "router.gleam",
      content: router_content,
      target: context.ServerTarget,
      write_mode: context.Overwrite,
    ),
  ]
}

/// Generate the user-owned `handlers.gleam`. Emitted only on first
/// generation; the writer's `SkipIfExists` mode prevents subsequent
/// runs from clobbering the user's implementation. The `// DO NOT EDIT`
/// banner is intentionally absent — the user owns this file.
fn generate_handlers(
  ctx: Context,
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> String {
  let sb =
    se.line(
      se.new(),
      "//// Implement these handler functions. This file is emitted once",
    )
    |> se.line(
      "//// by `oaspec generate` and skipped on subsequent runs, so your",
    )
    |> se.line("//// edits survive regeneration. Router wiring lives in")
    |> se.line("//// `handlers_generated.gleam`, which delegates here.")
    |> se.blank_line()
    |> se.imports([
      config.package(context.config(ctx)) <> "/request_types",
      config.package(context.config(ctx)) <> "/response_types",
    ])
    |> se.doc_comment("Application state passed to every handler.")
    |> se.doc_comment(
      "Add fields here for DB connections, config, loggers, etc. Construct a value of this type in your `main` and pass it to `router.route` as the first argument.",
    )
    |> se.line("pub type State {")
    |> se.indent(1, "State")
    |> se.line("}")
    |> se.blank_line()

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

/// Generate `handlers_generated.gleam`, a sealed delegator that the
/// router imports. Each operation forwards to `handlers.<op_name>(req)`.
/// Issue #247: this file carries the `// DO NOT EDIT` banner and is
/// always overwritten so router/handler wiring stays in sync with the
/// spec without touching the user's `handlers.gleam`.
fn generate_handlers_generated(
  ctx: Context,
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> String {
  let pkg = config.package(context.config(ctx))
  let sb =
    se.file_header(context.version)
    |> se.imports([
      pkg <> "/handlers",
      pkg <> "/request_types",
      pkg <> "/response_types",
    ])

  let sb =
    list.fold(operations, sb, fn(sb, op) {
      let #(op_id, operation, _path, _method) = op
      generate_handler_delegator(sb, op_id, operation)
    })

  se.to_string(sb)
}

/// Generate a single delegator function in `handlers_generated.gleam`.
fn generate_handler_delegator(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation(Resolved),
) -> se.StringBuilder {
  let fn_name = naming.operation_to_function_name(op_id)
  let request_type = naming.schema_to_type_name(op_id) <> "Request"
  let response_type = naming.schema_to_type_name(op_id) <> "Response"

  let has_params =
    !list.is_empty(operation.parameters)
    || option.is_some(operation.request_body)

  case has_params {
    True ->
      sb
      |> se.line(
        "pub fn "
        <> fn_name
        <> "(state: handlers.State, req: request_types."
        <> request_type
        <> ") -> response_types."
        <> response_type
        <> " {",
      )
      |> se.indent(1, "handlers." <> fn_name <> "(state, req)")
      |> se.line("}")
      |> se.blank_line()
    False ->
      sb
      |> se.line(
        "pub fn "
        <> fn_name
        <> "(state: handlers.State) -> response_types."
        <> response_type
        <> " {",
      )
      |> se.indent(1, "handlers." <> fn_name <> "(state)")
      |> se.line("}")
      |> se.blank_line()
  }
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
        <> "(state: State, req: request_types."
        <> request_type
        <> ") -> response_types."
        <> response_type
        <> " {",
      )
    False ->
      sb
      |> se.line(
        "pub fn "
        <> fn_name
        <> "(state: State) -> response_types."
        <> response_type
        <> " {",
      )
  }

  let sb = sb |> se.indent(1, "let _ = state")
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
    // Issue #306: integer response headers stringify via int.to_string.
    || operations_have_response_header_of_type(operations, "Int")

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
    // Issue #306: float response headers stringify via float.to_string.
    || operations_have_response_header_of_type(operations, "Float")

  // Issue #306: boolean response headers stringify via bool.to_string —
  // generated routers had no prior need for `gleam/bool`, so this is a
  // brand new import condition.
  let needs_bool = operations_have_response_header_of_type(operations, "Bool")

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
    // Issue #306: responses that declare headers materialise the
    // ServerResponse `headers:` slot via `list.flatten([...])`.
    || operations_have_response_headers(operations)
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
    // Issue #306: optional response headers pattern-match `Some(v) | None`,
    // which needs `gleam/option` even on operations whose request side
    // has no Option-typed parameters.
    || operations_have_optional_response_header(operations)

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
  let std_imports = case needs_bool {
    True -> list.append(std_imports, ["gleam/bool"])
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

  // Issue #247: router imports the sealed delegator, not the user-owned
  // handlers module. handlers_generated.gleam forwards every call to
  // handlers.<op_name>, so the router stays in lock-step with the spec
  // without ever touching user code.
  // Issue #264: also import handlers itself so the route signature can
  // reference `handlers.State` for the threaded application state.
  let pkg_imports = [
    config.package(context.config(ctx)) <> "/handlers",
    config.package(context.config(ctx)) <> "/handlers_generated",
  ]
  // Issue #318: enum query / header / cookie parameters resolved through
  // `$ref` cause the router body to emit `types.<EnumType><Variant>`
  // references (see decode_helpers.enum_match_result_expr and
  // enum_match_option_expr). The `types` import must be present in
  // those cases too, not just for deep object / form / multipart.
  let has_enum_ref_params =
    decode_helpers.operations_have_enum_ref_params(operations, ctx)
  let pkg_imports = case
    has_deep_object
    || has_form_urlencoded_body
    || has_multipart_body
    || has_enum_ref_params
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

  // Generate ResponseBody and ServerResponse types.
  //
  // `ResponseBody` keeps text and binary payloads distinct end-to-end so a
  // spec that declares `application/octet-stream` or `image/*` responses
  // round-trips real bytes instead of being smuggled through `String`
  // (issue #304). Framework adapters pattern-match on the variant to call
  // their text- or bytes-shaped response constructor.
  let sb =
    sb
    |> se.doc_comment(
      "Response body payload — text, raw bytes, or no body. The router
emits `BytesBody` for `application/octet-stream` (and other binary
content types) so adapters never have to round-trip bytes through a
String.",
    )
    |> se.line("pub type ResponseBody {")
    |> se.indent(1, "TextBody(String)")
    |> se.indent(1, "BytesBody(BitArray)")
    |> se.indent(1, "EmptyBody")
    |> se.line("}")
    |> se.blank_line()
    |> se.doc_comment("A server response with status code, body, and headers.")
    |> se.line("pub type ServerResponse {")
    |> se.indent(
      1,
      "ServerResponse(status: Int, body: ResponseBody, headers: List(#(String, String)))",
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

  // Generate route function. Issue #264 threads `app_state: handlers.State`
  // through to handler delegators. The argument is named `app_state` (not
  // `state`) because OpenAPI specs occasionally have a parameter named
  // `state` (e.g. OAuth2 flows), which would otherwise shadow the route
  // argument inside the case body.
  let sb =
    sb
    |> se.doc_comment("Route an incoming request to the appropriate handler.")
    |> se.line(
      "pub fn route(app_state: handlers.State, method: String, path: List(String), "
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
    |> se.indent(2, "_, _ -> " <> problem_response_expr(404, "not found"))
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
      |> se.indent(
        3,
        "let response = handlers_generated." <> fn_name <> "(app_state)",
      )
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
  let deduped_field_names = dedup.dedup_param_field_names(params)
  let params_with_field_names = list.zip(params, deduped_field_names)

  // Collect path params that need Result-based parsing (int, float)
  let path_params_needing_parse =
    list.filter(params, fn(p) {
      p.in_ == spec.InPath && decode_helpers.param_needs_result_unwrap(p)
    })

  // Required query / header / cookie params. Issue #263: each of these
  // becomes its own enclosing case expression so that a missing value
  // returns 400 instead of crashing the BEAM via `let assert`. Deep
  // object query params keep their legacy `let assert`-based path for
  // now (tracked separately).
  let required_query_params =
    list.filter(params, fn(p) {
      p.in_ == spec.InQuery
      && p.required
      && !decode_helpers.is_deep_object_param(p, ctx)
    })
  let required_header_params =
    list.filter(params, fn(p) { p.in_ == spec.InHeader && p.required })
  let required_cookie_params =
    list.filter(params, fn(p) { p.in_ == spec.InCookie && p.required })

  // Check if the request body needs safe decoding (required JSON body)
  let needs_body_guard = case operation.request_body {
    Some(Value(rb)) ->
      rb.required
      && list.any(dict.to_list(rb.content), fn(entry) {
        content_type.is_json_compatible(entry.0)
      })
    _ -> False
  }

  // Open nested case expressions for each path param that needs parsing.
  let sb =
    list.fold(path_params_needing_parse, sb, fn(sb, p) {
      let var_name = naming.to_snake_case(p.name)
      let parse_expr = decode_helpers.param_parse_expr(var_name, p)
      sb
      |> se.indent(3, "case " <> parse_expr <> " {")
      |> se.indent(4, "Ok(" <> var_name <> "_parsed) -> {")
    })

  // Open lookup cases for required query params. The router pulls the
  // raw value(s) out of `query` first; numeric parsing happens in a
  // second pass below so that a parse failure also returns 400.
  let sb =
    list.fold(required_query_params, sb, fn(sb, p) {
      let raw_var = naming.to_snake_case(p.name) <> "_raw"
      let pattern = case query_param_explode_array(p) {
        True -> "Ok([_, ..] as " <> raw_var <> ")"
        False -> "Ok([" <> raw_var <> ", ..])"
      }
      sb
      |> se.indent(3, "case dict.get(query, \"" <> p.name <> "\") {")
      |> se.indent(4, pattern <> " -> {")
    })

  // Open numeric-parse cases for required query params (scalar int/float
  // and explode=true int/float arrays, plus `$ref` to string-enum schemas
  // per issue #305). Bool / string don't need this.
  let sb =
    list.fold(required_query_params, sb, fn(sb, p) {
      query_required_open_parse_case(sb, p, ctx)
    })

  // Open lookup cases for required header params.
  let sb =
    list.fold(required_header_params, sb, fn(sb, p) {
      let raw_var = naming.to_snake_case(p.name) <> "_raw"
      let key = string.lowercase(p.name)
      sb
      |> se.indent(3, "case dict.get(headers, \"" <> key <> "\") {")
      |> se.indent(4, "Ok(" <> raw_var <> ") -> {")
    })

  let sb =
    list.fold(required_header_params, sb, fn(sb, p) {
      single_value_required_open_parse_case(sb, p)
    })

  // Open lookup cases for required cookie params.
  let sb =
    list.fold(required_cookie_params, sb, fn(sb, p) {
      let raw_var = naming.to_snake_case(p.name) <> "_raw"
      sb
      |> se.indent(3, "case cookie_lookup(headers, \"" <> p.name <> "\") {")
      |> se.indent(4, "Ok(" <> raw_var <> ") -> {")
    })

  let sb =
    list.fold(required_cookie_params, sb, fn(sb, p) {
      single_value_required_open_parse_case(sb, p)
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

  // Check if guard validation should be emitted for this body.
  // Issue #292: guard validation currently only fires for $ref schemas
  // because guards.gleam generates validators keyed by component name.
  // Inline request body schemas with constraints are decoded but NOT
  // guard-validated; extending guards.gleam to synthesise validators for
  // anonymous inline schemas is tracked as a follow-up.
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
    list.fold(params_with_field_names, sb, fn(sb, entry) {
      let #(param, field_name) = entry
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
          let raw_var = naming.to_snake_case(param.name) <> "_raw"
          case decode_helpers.is_deep_object_param(param, ctx), param.required {
            True, True ->
              decode_helpers.deep_object_required_expr(key, param, op_id, ctx)
            True, False ->
              decode_helpers.deep_object_optional_expr(key, param, op_id, ctx)
            False, True ->
              decode_helpers.query_required_expr(raw_var, param, ctx)
            False, False -> decode_helpers.query_optional_expr(key, param, ctx)
          }
        }
        spec.InHeader -> {
          let key = string.lowercase(param.name)
          let raw_var = naming.to_snake_case(param.name) <> "_raw"
          case param.required {
            True -> decode_helpers.header_required_expr(raw_var, param)
            False -> decode_helpers.header_optional_expr(key, param)
          }
        }
        spec.InCookie -> {
          let key = param.name
          let raw_var = naming.to_snake_case(param.name) <> "_raw"
          case param.required {
            True -> decode_helpers.cookie_required_expr(raw_var, param)
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
    |> se.indent(
      3,
      "let response = handlers_generated." <> fn_name <> "(app_state, request)",
    )
    |> generate_response_conversion(response_type_name, operation, ctx)

  // Close guard validation (returns 422 with error details)
  let sb = case needs_guard_validation {
    True ->
      sb
      |> se.indent(4, "}")
      |> se.indent(
        4,
        "Error(errors) -> ServerResponse(status: 422, body: TextBody(json.to_string(json.array(errors, guards.validation_failure_to_json))), headers: [#(\"content-type\", \"application/json\")])",
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
        "Error(_) -> " <> problem_response_expr(400, "invalid request body"),
      )
      |> se.indent(3, "}")
    False -> sb
  }

  // Close required-param case expressions in LIFO (reverse) order:
  // cookie parse, cookie lookup, header parse, header lookup, query parse,
  // query lookup, then finally the path int/float parse cases. The
  // catch-all `_ ->` arm covers `Ok([])` (empty query lists) along with
  // `Error(_)` so all failure modes return 400.
  let sb =
    list.fold(required_cookie_params, sb, fn(sb, p) {
      close_single_value_required_parse_case(sb, p, ctx)
    })
  let sb =
    list.fold(required_cookie_params, sb, fn(sb, _p) { close_lookup_case(sb) })
  let sb =
    list.fold(required_header_params, sb, fn(sb, p) {
      close_single_value_required_parse_case(sb, p, ctx)
    })
  let sb =
    list.fold(required_header_params, sb, fn(sb, _p) { close_lookup_case(sb) })
  let sb =
    list.fold(required_query_params, sb, fn(sb, p) {
      close_query_required_parse_case(sb, p, ctx)
    })
  let sb =
    list.fold(required_query_params, sb, fn(sb, _p) { close_lookup_case(sb) })

  list.fold(path_params_needing_parse, sb, fn(sb, _p) {
    sb
    |> se.indent(4, "}")
    |> se.indent(
      4,
      "Error(_) -> " <> problem_response_expr(400, "invalid path parameter"),
    )
    |> se.indent(3, "}")
  })
}

/// True when this query param is treated as a list (explode=true array).
/// Matches the helper used by `query_required_expr` so the open/close
/// scaffolding stays in sync with the value expression.
fn query_param_explode_array(p: spec.Parameter(Resolved)) -> Bool {
  case spec.parameter_schema(p) {
    Some(schema.Inline(schema.ArraySchema(..))) -> {
      case p.explode {
        Some(False) -> False
        _ -> True
      }
    }
    _ -> False
  }
}

/// Open the secondary parse case for required query params that need it.
/// - scalar Integer/Number → `case int.parse(<raw>) { Ok(<raw>_parsed) -> {`
/// - array of Integer/Number with explode=true → `case list.try_map(<raw>, int.parse) { Ok(<raw>_parsed_list) -> {`
/// - array of Integer/Number with explode=false → split first, then try_map.
/// String / Bool / array-of-string / array-of-bool need no extra case.
fn query_required_open_parse_case(
  sb: se.StringBuilder,
  p: spec.Parameter(Resolved),
  ctx: Context,
) -> se.StringBuilder {
  let raw_var = naming.to_snake_case(p.name) <> "_raw"
  let delim = case p.style {
    Some(spec.PipeDelimitedStyle) -> "|"
    Some(spec.SpaceDelimitedStyle) -> " "
    _ -> ","
  }
  case spec.parameter_schema(p) {
    Some(schema.Inline(schema.IntegerSchema(..))) ->
      sb
      |> se.indent(3, "case int.parse(" <> raw_var <> ") {")
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed) -> {")
    Some(schema.Inline(schema.NumberSchema(..))) ->
      sb
      |> se.indent(3, "case float.parse(" <> raw_var <> ") {")
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed) -> {")
    Some(schema.Inline(schema.ArraySchema(
      items: Inline(schema.IntegerSchema(..)),
      ..,
    ))) -> {
      let parse_expr = array_int_parse_expr(raw_var, p, delim)
      sb
      |> se.indent(3, "case " <> parse_expr <> " {")
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed_list) -> {")
    }
    Some(schema.Inline(schema.ArraySchema(
      items: Inline(schema.NumberSchema(..)),
      ..,
    ))) -> {
      let parse_expr = array_float_parse_expr(raw_var, p, delim)
      sb
      |> se.indent(3, "case " <> parse_expr <> " {")
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed_list) -> {")
    }
    Some(ref) ->
      // Issue #305: required `$ref` to a string-enum schema needs the
      // same Result-based open/close scaffolding as int / float so an
      // unknown enum value falls through to the `_ -> 400` arm in
      // `close_single_value_required_parse_case` below.
      case decode_helpers.schema_ref_string_enum(ref, ctx) {
        Some(#(type_name, values)) ->
          sb
          |> se.indent(
            3,
            "case "
              <> decode_helpers.enum_match_result_expr(
              raw_var,
              type_name,
              values,
            )
              <> " {",
          )
          |> se.indent(4, "Ok(" <> raw_var <> "_parsed) -> {")
        None -> sb
      }
    _ -> sb
  }
}

fn array_int_parse_expr(
  raw_var: String,
  p: spec.Parameter(Resolved),
  delim: String,
) -> String {
  case p.explode {
    Some(False) ->
      "list.try_map(list.map(string.split("
      <> raw_var
      <> ", \""
      <> delim
      <> "\"), string.trim), int.parse)"
    _ -> "list.try_map(list.map(" <> raw_var <> ", string.trim), int.parse)"
  }
}

fn array_float_parse_expr(
  raw_var: String,
  p: spec.Parameter(Resolved),
  delim: String,
) -> String {
  case p.explode {
    Some(False) ->
      "list.try_map(list.map(string.split("
      <> raw_var
      <> ", \""
      <> delim
      <> "\"), string.trim), float.parse)"
    _ -> "list.try_map(list.map(" <> raw_var <> ", string.trim), float.parse)"
  }
}

/// Close the matching parse case for a required query param.
fn close_query_required_parse_case(
  sb: se.StringBuilder,
  p: spec.Parameter(Resolved),
  ctx: Context,
) -> se.StringBuilder {
  let close = fn(sb: se.StringBuilder) -> se.StringBuilder {
    sb
    |> se.indent(4, "}")
    |> se.indent(
      4,
      "_ -> " <> problem_response_expr(400, "invalid query parameter"),
    )
    |> se.indent(3, "}")
  }
  case spec.parameter_schema(p) {
    Some(schema.Inline(schema.IntegerSchema(..)))
    | Some(schema.Inline(schema.NumberSchema(..)))
    | Some(schema.Inline(schema.ArraySchema(
        items: Inline(schema.IntegerSchema(..)),
        ..,
      )))
    | Some(schema.Inline(schema.ArraySchema(
        items: Inline(schema.NumberSchema(..)),
        ..,
      ))) -> close(sb)
    Some(ref) ->
      // Issue #305: matches the open emitted in
      // `query_required_open_parse_case` for required `$ref` to string
      // enum schemas.
      case decode_helpers.schema_ref_string_enum(ref, ctx) {
        Some(_) -> close(sb)
        None -> sb
      }
    _ -> sb
  }
}

/// For headers / cookies, open a numeric parse case if the param schema is a
/// scalar Integer/Number. (Header/cookie array parsing is currently a single
/// inline `list.map(string.split(...))` expression and stays unsafe; that's
/// out of scope for the Issue #263 fix and tracked separately.)
fn single_value_required_open_parse_case(
  sb: se.StringBuilder,
  p: spec.Parameter(Resolved),
) -> se.StringBuilder {
  let raw_var = naming.to_snake_case(p.name) <> "_raw"
  case spec.parameter_schema(p) {
    Some(schema.Inline(schema.IntegerSchema(..))) ->
      sb
      |> se.indent(3, "case int.parse(" <> raw_var <> ") {")
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed) -> {")
    Some(schema.Inline(schema.NumberSchema(..))) ->
      sb
      |> se.indent(3, "case float.parse(" <> raw_var <> ") {")
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed) -> {")
    Some(schema.Inline(schema.ArraySchema(
      items: Inline(schema.IntegerSchema(..)),
      ..,
    ))) ->
      sb
      |> se.indent(
        3,
        "case list.try_map(list.map(string.split("
          <> raw_var
          <> ", \",\"), string.trim), int.parse) {",
      )
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed_list) -> {")
    Some(schema.Inline(schema.ArraySchema(
      items: Inline(schema.NumberSchema(..)),
      ..,
    ))) ->
      sb
      |> se.indent(
        3,
        "case list.try_map(list.map(string.split("
          <> raw_var
          <> ", \",\"), string.trim), float.parse) {",
      )
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed_list) -> {")
    _ -> sb
  }
}

fn close_single_value_required_parse_case(
  sb: se.StringBuilder,
  p: spec.Parameter(Resolved),
  ctx: Context,
) -> se.StringBuilder {
  let close = fn(sb: se.StringBuilder) -> se.StringBuilder {
    sb
    |> se.indent(4, "}")
    |> se.indent(
      4,
      "_ -> " <> problem_response_expr(400, "invalid header or cookie"),
    )
    |> se.indent(3, "}")
  }
  case spec.parameter_schema(p) {
    Some(schema.Inline(schema.IntegerSchema(..)))
    | Some(schema.Inline(schema.NumberSchema(..)))
    | Some(schema.Inline(schema.ArraySchema(
        items: Inline(schema.IntegerSchema(..)),
        ..,
      )))
    | Some(schema.Inline(schema.ArraySchema(
        items: Inline(schema.NumberSchema(..)),
        ..,
      ))) -> close(sb)
    Some(ref) ->
      // Issue #305: matches the open emitted in
      // `query_required_open_parse_case` for required `$ref` to string
      // enum schemas. Non-enum refs fall through unchanged.
      case decode_helpers.schema_ref_string_enum(ref, ctx) {
        Some(_) -> close(sb)
        None -> sb
      }
    _ -> sb
  }
}

/// Build the Gleam source expression for a `ServerResponse` carrying an
/// RFC 7807-shaped `application/problem+json` body. Used by every
/// router-side error-emit site so clients receive a structured JSON
/// response instead of plain `Bad Request` / `Not Found` text — a
/// schema-conformant default for specs that declare 4xx responses with
/// `application/problem+json` content (issue #307).
///
/// The body is emitted as a literal JSON string at codegen time —
/// stable, allocation-free, and safe to embed because `detail` is a
/// short codegen-controlled phrase (no user input is interpolated).
/// Specs that need a different Problem encoding can still override at
/// the framework adapter layer.
fn problem_response_expr(status: Int, detail: String) -> String {
  let body =
    "\"{\\\"type\\\":\\\"about:blank\\\",\\\"title\\\":\\\""
    <> detail
    <> "\\\"}\""
  "ServerResponse(status: "
  <> int.to_string(status)
  <> ", body: TextBody("
  <> body
  <> "), headers: [#(\"content-type\", \"application/problem+json\")])"
}

/// Close a required-param lookup case (`case dict.get(...) { Ok(...) -> { ... }`).
/// The catch-all `_ ->` arm covers both `Error(_)` and `Ok([])` (empty list)
/// for query params, plus the bare `Error(_)` for header/cookie lookups.
fn close_lookup_case(sb: se.StringBuilder) -> se.StringBuilder {
  sb
  |> se.indent(4, "}")
  |> se.indent(
    4,
    "_ -> " <> problem_response_expr(400, "missing or invalid parameter"),
  )
  |> se.indent(3, "}")
}

/// Check if an operation's request body needs guard validation.
/// True when the body is required, JSON-compatible, references a named schema,
/// and that schema has constraint-based validators.
///
/// Issue #292: inline request body schemas with constraints are NOT covered
/// here because guards.gleam only generates validators for named component
/// schemas. Extending guard generation to anonymous inline schemas is
/// tracked as a follow-up.
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
      |> se.indent(
        3,
        "ServerResponse(status: 200, body: EmptyBody, headers: [])",
      )
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
              let header_specs = sorted_header_specs(response.headers)
              let has_headers = !list.is_empty(header_specs)

              case content_entries {
                [] ->
                  // No content body variant
                  emit_response_arm(
                    sb,
                    variant_name,
                    status_int,
                    has_data: False,
                    has_headers: has_headers,
                    body_expr: "EmptyBody",
                    content_type_header: None,
                    header_specs: header_specs,
                  )
                [#(media_type_name, media_type)] ->
                  case content_type.from_string(media_type_name) {
                    content_type.ApplicationJson ->
                      case media_type.schema {
                        Some(_) -> {
                          let encode_fn =
                            get_encode_function(media_type.schema, ctx)
                          emit_response_arm(
                            sb,
                            variant_name,
                            status_int,
                            has_data: True,
                            has_headers: has_headers,
                            body_expr: "TextBody(json.to_string("
                              <> encode_fn
                              <> "(data)))",
                            content_type_header: Some(media_type_name),
                            header_specs: header_specs,
                          )
                        }
                        None ->
                          emit_response_arm(
                            sb,
                            variant_name,
                            status_int,
                            has_data: False,
                            has_headers: has_headers,
                            body_expr: "EmptyBody",
                            content_type_header: None,
                            header_specs: header_specs,
                          )
                      }
                    content_type.TextPlain
                    | content_type.ApplicationXml
                    | content_type.TextXml ->
                      case media_type.schema {
                        Some(_) ->
                          emit_response_arm(
                            sb,
                            variant_name,
                            status_int,
                            has_data: True,
                            has_headers: has_headers,
                            body_expr: "TextBody(data)",
                            content_type_header: Some(media_type_name),
                            header_specs: header_specs,
                          )
                        None ->
                          emit_response_arm(
                            sb,
                            variant_name,
                            status_int,
                            has_data: False,
                            has_headers: has_headers,
                            body_expr: "EmptyBody",
                            content_type_header: None,
                            header_specs: header_specs,
                          )
                      }
                    content_type.ApplicationOctetStream ->
                      // Issue #304: binary responses thread bytes end-to-end
                      // via `BytesBody(BitArray)` instead of being smuggled
                      // through `String`. The matching response_types
                      // variant carries `BitArray` (see ir_build).
                      case media_type.schema {
                        Some(_) ->
                          emit_response_arm(
                            sb,
                            variant_name,
                            status_int,
                            has_data: True,
                            has_headers: has_headers,
                            body_expr: "BytesBody(data)",
                            content_type_header: Some(media_type_name),
                            header_specs: header_specs,
                          )
                        None ->
                          emit_response_arm(
                            sb,
                            variant_name,
                            status_int,
                            has_data: False,
                            has_headers: has_headers,
                            body_expr: "EmptyBody",
                            content_type_header: None,
                            header_specs: header_specs,
                          )
                      }
                    _ ->
                      case media_type.schema {
                        Some(_) -> {
                          let encode_fn =
                            get_encode_function(media_type.schema, ctx)
                          emit_response_arm(
                            sb,
                            variant_name,
                            status_int,
                            has_data: True,
                            has_headers: has_headers,
                            body_expr: "TextBody(json.to_string("
                              <> encode_fn
                              <> "(data)))",
                            content_type_header: Some(media_type_name),
                            header_specs: header_specs,
                          )
                        }
                        None ->
                          emit_response_arm(
                            sb,
                            variant_name,
                            status_int,
                            has_data: False,
                            has_headers: has_headers,
                            body_expr: "EmptyBody",
                            content_type_header: None,
                            header_specs: header_specs,
                          )
                      }
                  }
                // Multiple content types: variant wraps String.
                // Use the first content type as default content-type header.
                [#(first_media_type, _), _, ..] ->
                  emit_response_arm(
                    sb,
                    variant_name,
                    status_int,
                    has_data: True,
                    has_headers: has_headers,
                    body_expr: "TextBody(data)",
                    content_type_header: Some(first_media_type),
                    header_specs: header_specs,
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

/// True if any response of any operation declares at least one header.
fn operations_have_response_headers(
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> Bool {
  list.any(operations, fn(op) {
    let #(_, operation, _, _) = op
    list.any(dict.to_list(operation.responses), fn(entry) {
      let #(_, ref_or) = entry
      case ref_or {
        Value(response) -> !dict.is_empty(response.headers)
        _ -> False
      }
    })
  })
}

/// True if any response header field has the given Gleam type.
/// Used to decide which primitive `gleam/<type>` import the generated
/// router needs for header value stringification (issue #306).
fn operations_have_response_header_of_type(
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
  type_name: String,
) -> Bool {
  list.any(operations, fn(op) {
    let #(_, operation, _, _) = op
    list.any(dict.to_list(operation.responses), fn(entry) {
      let #(_, ref_or) = entry
      case ref_or {
        Value(response) ->
          list.any(sorted_header_specs(response.headers), fn(spec) {
            spec.field_type == type_name
          })
        _ -> False
      }
    })
  })
}

/// True if any response header is optional. Optional headers emit
/// `case hdrs.<field> { Some(v) -> ... None -> [] }` and need `gleam/option`.
fn operations_have_optional_response_header(
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> Bool {
  list.any(operations, fn(op) {
    let #(_, operation, _, _) = op
    list.any(dict.to_list(operation.responses), fn(entry) {
      let #(_, ref_or) = entry
      case ref_or {
        Value(response) ->
          list.any(sorted_header_specs(response.headers), fn(spec) {
            !spec.required
          })
        _ -> False
      }
    })
  })
}

/// Compact spec for a single declared response header, used to render
/// the `headers:` slot of `ServerResponse` when issue #306 plumbing is
/// active. The pair (header_name, field_name) keeps the wire-form name
/// (e.g. "Pagination-Cursor") distinct from the Gleam record field
/// (`pagination_cursor`); `field_type` decides how the value is
/// stringified; `required` decides whether to emit a Some/None case.
type HeaderSpec {
  HeaderSpec(
    header_name: String,
    field_name: String,
    field_type: String,
    required: Bool,
  )
}

fn sorted_header_specs(
  headers: dict.Dict(String, spec.Header),
) -> List(HeaderSpec) {
  headers
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.map(fn(entry) {
    let #(header_name, header) = entry
    let field_name = naming.to_snake_case(header_name)
    let field_type = response_header_field_type(header.schema)
    HeaderSpec(
      header_name: header_name,
      field_name: field_name,
      field_type: field_type,
      required: header.required,
    )
  })
}

/// Mirror of `header_schema_to_type` in ir_build — kept here so the
/// router emission and the response_types record stay in sync without a
/// cross-module dependency on the IR layer.
fn response_header_field_type(
  schema_opt: option.Option(schema.SchemaRef),
) -> String {
  case schema_opt {
    Some(Inline(schema.IntegerSchema(..))) -> "Int"
    Some(Inline(schema.NumberSchema(..))) -> "Float"
    Some(Inline(schema.BooleanSchema(..))) -> "Bool"
    Some(Inline(schema.StringSchema(..))) -> "String"
    Some(Reference(name:, ..)) -> "types." <> naming.schema_to_type_name(name)
    _ -> "String"
  }
}

/// Emit one arm of the response dispatch `case` block.
///
/// Issue #306 introduces the headers plumbing: when `has_headers` is
/// True the variant pattern grows an `hdrs` binding and the headers
/// list is materialised via `list.flatten` so spec-declared response
/// headers are appended to the implicit `content-type` tuple.
fn emit_response_arm(
  sb: se.StringBuilder,
  variant_name: String,
  status_int: String,
  has_data has_data: Bool,
  has_headers has_headers: Bool,
  body_expr body_expr: String,
  content_type_header content_type_header: option.Option(String),
  header_specs header_specs: List(HeaderSpec),
) -> se.StringBuilder {
  let pattern_args = case has_data, has_headers {
    True, True -> "(data, hdrs)"
    True, False -> "(data)"
    False, True -> "(hdrs)"
    False, False -> ""
  }
  let headers_expr = headers_slot_expr(content_type_header, header_specs)
  sb
  |> se.indent(
    4,
    "response_types."
      <> variant_name
      <> pattern_args
      <> " -> ServerResponse(status: "
      <> status_int
      <> ", body: "
      <> body_expr
      <> ", headers: "
      <> headers_expr
      <> ")",
  )
}

/// Build the `headers:` argument for a `ServerResponse(...)` call.
///
/// - No content-type, no declared headers → `[]`
/// - Content-type only → `[#("content-type", "<type>")]`
/// - Declared headers (with or without content-type) → `list.flatten([...])`
///   so optional headers can contribute `[]` and required ones a
///   one-tuple list without repeated allocation. The fold keeps the
///   spec-declared order (alphabetised by `sorted_header_specs`) so
///   regenerated routers stay deterministic.
fn headers_slot_expr(
  content_type_header: option.Option(String),
  header_specs: List(HeaderSpec),
) -> String {
  let content_type_chunk = case content_type_header {
    Some(media_type_name) -> [
      "[#(\"content-type\", \"" <> media_type_name <> "\")]",
    ]
    None -> []
  }
  let header_chunks =
    list.map(header_specs, fn(spec) { header_chunk_expr(spec) })
  case content_type_chunk, header_chunks {
    [], [] -> "[]"
    [single_chunk], [] -> single_chunk
    _, _ ->
      "list.flatten(["
      <> string.join(content_type_chunk, ", ")
      |> append_chunks(header_chunks)
      <> "])"
  }
}

fn append_chunks(prefix: String, header_chunks: List(String)) -> String {
  case header_chunks {
    [] -> prefix
    _ ->
      case prefix {
        "" -> string.join(header_chunks, ", ")
        _ -> prefix <> ", " <> string.join(header_chunks, ", ")
      }
  }
}

/// Render one declared response header into a chunk that contributes
/// to the `headers:` `list.flatten` call.
///
/// Required: `[#("Pagination-Cursor", hdrs.pagination_cursor)]`
/// Optional: `case hdrs.pagination_cursor { Some(v) -> [#(...)] None -> [] }`
/// Non-string types are stringified via `int.to_string` /
/// `float.to_string` / `bool.to_string` (the necessary imports are
/// added by the import-analysis pass).
fn header_chunk_expr(spec: HeaderSpec) -> String {
  let render_value = fn(value_expr: String) -> String {
    "[#(\""
    <> spec.header_name
    <> "\", "
    <> stringify_header_value(spec.field_type, value_expr)
    <> ")]"
  }
  case spec.required {
    True -> render_value("hdrs." <> spec.field_name)
    False ->
      "case hdrs."
      <> spec.field_name
      <> " { Some(v) -> "
      <> render_value("v")
      <> " None -> [] }"
  }
}

/// Convert a typed header value into a `String` for the wire. Header
/// fields are limited to primitives (Int / Float / Bool / String) and
/// `types.<X>` aliases (which the codegen treats as String-compatible
/// — non-string aliases would fail to compile and signal the user
/// that header value coercion is unsupported for that schema).
fn stringify_header_value(field_type: String, value_expr: String) -> String {
  case field_type {
    "Int" -> "int.to_string(" <> value_expr <> ")"
    "Float" -> "float.to_string(" <> value_expr <> ")"
    "Bool" -> "bool.to_string(" <> value_expr <> ")"
    _ -> value_expr
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
        Inline(schema.StringSchema(..)) ->
          "fn(items) { json.array(items, json.string) }"
        Inline(schema.IntegerSchema(..)) ->
          "fn(items) { json.array(items, json.int) }"
        Inline(schema.NumberSchema(..)) ->
          "fn(items) { json.array(items, json.float) }"
        Inline(schema.BooleanSchema(..)) ->
          "fn(items) { json.array(items, json.bool) }"
        // Inline non-primitive items (e.g. nested ArraySchema, anonymous
        // ObjectSchema) at the top level of a response are not yet hoisted
        // into reusable encoders. Falling back to the previous "json.string"
        // shape would emit code that fails to compile against List(_); emit a
        // homogeneous String array instead so the call still type-checks even
        // when the items are not actually strings. Once such schemas get a
        // hoist + per-item encoder, replace this branch.
        _ -> "fn(items) { json.array(items, json.string) }"
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
