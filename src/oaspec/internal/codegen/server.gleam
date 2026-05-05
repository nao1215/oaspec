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
import oaspec/internal/codegen/router_ir
import oaspec/internal/codegen/runtime_snippets
import oaspec/internal/codegen/server_request_decode as decode_helpers
import oaspec/internal/openapi/dedup
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
  let operations = context.operations(ctx)
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
  operations: List(context.AnalyzedOperation),
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
  operations: List(context.AnalyzedOperation),
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
  operations: List(context.AnalyzedOperation),
) -> String {
  let requirements = router_ir.analyze(ctx)
  let all_imports = router_ir.imports(requirements, ctx)

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
  let sb = case requirements.needs_deep_object_present {
    True -> se.raw(sb, runtime_snippets.deep_object_present)
    False -> sb
  }

  // deep_object_present_any and deep_object_additional_properties:
  // only when deep object params with additional_properties exist
  let sb = case requirements.has_deep_object_with_ap {
    True -> se.raw(sb, runtime_snippets.deep_object_present_any)
    False -> sb
  }

  // coerce_dict: type-safe identity for converting Dict value types at compile time
  // Only needed when deepObject params with Untyped additional_properties exist
  let sb = case requirements.has_deep_object_untyped_ap {
    True -> se.raw(sb, runtime_snippets.coerce_dict)
    False -> sb
  }

  let sb = case requirements.has_form_urlencoded_body {
    True -> se.raw(sb, runtime_snippets.form_url_decode_and_parse_form_body)
    False -> sb
  }

  let sb = case requirements.has_multipart_body {
    True -> se.raw(sb, runtime_snippets.multipart_helpers)
    False -> sb
  }

  let sb = case requirements.has_nested_form_urlencoded_body {
    True -> se.raw(sb, runtime_snippets.form_object_present)
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
      <> route_arg_name("query", requirements.uses_query)
      <> ": Dict(String, List(String)), "
      <> route_arg_name("headers", requirements.uses_headers)
      <> ": Dict(String, String), "
      <> route_arg_name("body", requirements.uses_body)
      <> case requirements.has_binary_request_body {
        // Issue #485: when any operation declares
        // `application/octet-stream` on its request body, the
        // router signature takes raw bytes instead of String so
        // arbitrary binary payloads round-trip without going
        // through `bit_array.to_string`. Non-binary route arms
        // shadow the parameter with a String conversion at the
        // top of each arm so the rest of the codegen template
        // is unchanged.
        True -> ": BitArray) -> ServerResponse {"
        False -> ": String) -> ServerResponse {"
      },
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

      // Issue #485: when the route signature is `body: BitArray`
      // (because some other operation in this spec declares
      // `application/octet-stream`), every non-binary arm needs to
      // shadow `body` with the String conversion at the top so the
      // existing per-content-type decoding code can keep treating
      // `body` as a String. Binary arms use `body` directly.
      let arm_sb =
        sb
        |> se.indent(2, "\"" <> method_str <> "\", " <> path_pattern <> " -> {")
      let arm_sb = case
        requirements.has_binary_request_body,
        option.is_some(operation.request_body),
        decode_helpers.operation_uses_octet_stream_body(operation)
      {
        True, True, False ->
          arm_sb
          |> se.indent(
            3,
            "let body = bit_array.to_string(body) |> result.unwrap(\"\")",
          )
        _, _, _ -> arm_sb
      }
      arm_sb
      |> generate_route_body(op_id, fn_name, operation, path, has_params, ctx)
      |> se.indent(2, "}")
    })

  let sb =
    sb
    |> se.indent(2, "_, _ -> " <> problem_response_expr(404, "not found"))
    |> se.indent(1, "}")
    |> se.line("}")
    |> se.blank_line()

  let sb = case requirements.needs_cookie_lookup {
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
  |> se.raw(runtime_snippets.cookie_lookup)
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
              // Issue #483: the OpenAPI `default` response is the only
              // status whose generated variant carries a runtime status
              // code (`Foo(Int [, body] [, headers])`). The router
              // pattern grows a `status` binding and uses it as the
              // outgoing `ServerResponse.status` instead of the
              // hardcoded representative-int (which was always 500).
              let is_default = case status_code {
                http.DefaultStatus -> True
                _ -> False
              }
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
                    is_default: is_default,
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
                            is_default: is_default,
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
                            is_default: is_default,
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
                            is_default: is_default,
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
                            is_default: is_default,
                          )
                      }
                    content_type.ApplicationOctetStream | content_type.Wildcard ->
                      // Issue #304: binary responses thread bytes end-to-end
                      // via `BytesBody(BitArray)` instead of being smuggled
                      // through `String`. The matching response_types
                      // variant carries `BitArray` (see ir_build).
                      // Issue #504: */* shares the same path — wildcard
                      // responses are handed to the user as raw BitArray.
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
                            is_default: is_default,
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
                            is_default: is_default,
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
                            is_default: is_default,
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
                            is_default: is_default,
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
                    is_default: is_default,
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
///
/// Issue #483: when `is_default` is True the variant pattern grows a
/// leading `status` binding and the outgoing `ServerResponse.status`
/// uses that bound value instead of the precomputed `status_int`. The
/// `Foo(Int [, body] [, headers])` shape comes from `VariantDefault`
/// in the IR.
fn emit_response_arm(
  sb: se.StringBuilder,
  variant_name: String,
  status_int: String,
  has_data has_data: Bool,
  has_headers has_headers: Bool,
  body_expr body_expr: String,
  content_type_header content_type_header: option.Option(String),
  header_specs header_specs: List(HeaderSpec),
  is_default is_default: Bool,
) -> se.StringBuilder {
  let pattern_args = case is_default, has_data, has_headers {
    False, True, True -> "(data, hdrs)"
    False, True, False -> "(data)"
    False, False, True -> "(hdrs)"
    False, False, False -> ""
    True, True, True -> "(status, data, hdrs)"
    True, True, False -> "(status, data)"
    True, False, True -> "(status, hdrs)"
    True, False, False -> "(status)"
  }
  let status_expr = case is_default {
    True -> "status"
    False -> status_int
  }
  let headers_expr = headers_slot_expr(content_type_header, header_specs)
  sb
  |> se.indent(
    4,
    "response_types."
      <> variant_name
      <> pattern_args
      <> " -> ServerResponse(status: "
      <> status_expr
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
