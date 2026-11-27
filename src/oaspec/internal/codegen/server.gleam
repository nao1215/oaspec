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
import oaspec/internal/codegen/operation_ir
import oaspec/internal/codegen/router_ir
import oaspec/internal/codegen/runtime_snippets
import oaspec/internal/codegen/schema_dispatch
import oaspec/internal/codegen/server_request_decode as decode_helpers
import oaspec/internal/openapi/dedup
import oaspec/internal/openapi/spec
import oaspec/internal/util/content_type
import oaspec/internal/util/http
import oaspec/internal/util/naming
import oaspec/internal/util/string_extra as se
import oaspec/openapi.{type Resolved, Inline, Reference, Value}

/// Generate server stub files.
///
/// The handler surface is split in two:
///
/// - `handlers.gleam` carries user-editable panic stubs and is emitted
///   only on first generation (`SkipIfExists`). Re-running
///   `oaspec generate` leaves it alone, so user implementations
///   survive regeneration.
/// - `handlers_generated.gleam` is a sealed delegator that `router.gleam`
///   imports. Each operation forwards to `handlers.<op_name>(req)`. It
///   is always overwritten so the wiring stays in lock-step with the
///   spec.
///
/// With `handlers: per_operation` the user-owned side is split further:
/// `handlers.gleam` carries only `State`, and each operation gets its
/// own `handlers/<operation>.gleam` stub (also `SkipIfExists`), so an
/// operation added to the spec gets a stub on the next run.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let operations = context.operations(ctx)
  let router_content = generate_router(ctx, operations)

  let user_files = case context.config(ctx).handler_layout {
    config.SingleFile -> [
      GeneratedFile(
        path: "handlers.gleam",
        content: generate_handlers(ctx, operations),
        target: context.ServerTarget,
        write_mode: context.SkipIfExists,
      ),
      GeneratedFile(
        path: "handlers_generated.gleam",
        content: generate_handlers_generated(ctx, operations),
        target: context.ServerTarget,
        write_mode: context.Overwrite,
      ),
    ]
    config.PerOperation -> [
      GeneratedFile(
        path: "handlers.gleam",
        content: generate_state_only_handlers(),
        target: context.ServerTarget,
        write_mode: context.SkipIfExists,
      ),
      ..list.append(
        list.map(operations, fn(op) {
          let context.AnalyzedOperation(op_id, operation, _path, _method) = op
          GeneratedFile(
            path: "handlers/"
              <> naming.operation_to_function_name(op_id)
              <> ".gleam",
            content: generate_operation_handler(ctx, op_id, operation),
            target: context.ServerTarget,
            write_mode: context.SkipIfExists,
          )
        }),
        [
          GeneratedFile(
            path: "handlers_generated.gleam",
            content: generate_per_operation_handlers_generated(ctx, operations),
            target: context.ServerTarget,
            write_mode: context.Overwrite,
          ),
        ],
      )
    ]
  }

  list.append(user_files, [
    GeneratedFile(
      path: "router.gleam",
      content: router_content,
      target: context.ServerTarget,
      write_mode: context.Overwrite,
    ),
  ])
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
      context.config(ctx).package <> "/request_types",
      context.config(ctx).package <> "/response_types",
    ])
    |> state_type()

  let sb =
    list.fold(operations, sb, fn(sb, op) {
      let context.AnalyzedOperation(op_id, operation, _path, _method) = op
      generate_handler(sb, op_id, operation)
    })

  // Callbacks are parsed and resolved but NOT emitted as handler stubs.
  // A stub without request type, response type or execution path would
  // mislead more than help, so callbacks are documented as
  // parsed-but-not-codegen.
  se.to_string(sb)
}

/// Emit the user-owned `State` type shared by every handler.
fn state_type(sb: se.StringBuilder) -> se.StringBuilder {
  sb
  |> se.doc_comment("Application state passed to every handler.")
  |> se.doc_comment(
    "Add fields here for DB connections, config, loggers, etc. Construct a value of this type in your `main` and pass it to `router.route` as the first argument.",
  )
  |> se.line("pub type State {")
  |> se.indent(1, "State")
  |> se.line("}")
  |> se.blank_line()
}

/// Generate the user-owned `handlers.gleam` for `handlers: per_operation`.
/// It holds only `State`; the stubs live in `handlers/<operation>.gleam`.
fn generate_state_only_handlers() -> String {
  se.new()
  |> se.line("//// Application state shared by the handlers in `handlers/`.")
  |> se.line("//// This file is emitted once by `oaspec generate` and skipped")
  |> se.line("//// on subsequent runs, so your edits survive regeneration.")
  |> se.blank_line()
  |> state_type()
  |> se.to_string()
}

/// Generate the user-owned `handlers/<operation>.gleam` stub for
/// `handlers: per_operation`. Emitted only when the file does not exist.
fn generate_operation_handler(
  ctx: Context,
  op_id: String,
  operation: openapi.Operation(Resolved),
) -> String {
  let pkg = context.config(ctx).package
  let request_import = case has_handler_params(operation) {
    True -> [pkg <> "/request_types"]
    False -> []
  }
  se.new()
  |> se.line("//// Implement this handler. This file is emitted once by")
  |> se.line("//// `oaspec generate` and skipped on subsequent runs, so your")
  |> se.line("//// edits survive regeneration.")
  |> se.blank_line()
  |> se.imports(
    list.flatten([
      [pkg <> "/handlers.{type State}"],
      request_import,
      [pkg <> "/response_types"],
    ]),
  )
  |> generate_handler(op_id, operation)
  |> se.to_string()
}

/// Generate `handlers_generated.gleam` for `handlers: per_operation`.
/// Each operation forwards to `handlers/<operation>.gleam`, imported
/// under a `_handler` alias so an operation named like another
/// generated module (`request_types`, `handlers`) does not collide.
fn generate_per_operation_handlers_generated(
  ctx: Context,
  operations: List(context.AnalyzedOperation),
) -> String {
  let pkg = context.config(ctx).package
  let handler_imports =
    list.map(operations, fn(op) {
      let fn_name = naming.operation_to_function_name(op.operation_id)
      pkg <> "/handlers/" <> fn_name <> " as " <> fn_name <> "_handler"
    })
  let sb =
    se.file_header(context.version)
    |> se.imports(
      list.flatten([
        [pkg <> "/handlers"],
        handler_imports,
        [pkg <> "/request_types", pkg <> "/response_types"],
      ]),
    )

  list.fold(operations, sb, fn(sb, op) {
    let context.AnalyzedOperation(op_id, operation, _path, _method) = op
    let fn_name = naming.operation_to_function_name(op_id)
    generate_handler_delegator(sb, op_id, operation, fn_name <> "_handler")
  })
  |> se.to_string
}

/// True when the handler for `operation` takes a request argument.
fn has_handler_params(operation: openapi.Operation(Resolved)) -> Bool {
  !list.is_empty(operation.parameters) || option.is_some(operation.request_body)
}

/// Generate `handlers_generated.gleam`, a sealed delegator that the
/// router imports. Each operation forwards to `handlers.<op_name>(req)`.
/// This file carries the `// DO NOT EDIT` banner and is
/// always overwritten so router/handler wiring stays in sync with the
/// spec without touching the user's `handlers.gleam`.
fn generate_handlers_generated(
  ctx: Context,
  operations: List(context.AnalyzedOperation),
) -> String {
  let pkg = context.config(ctx).package
  let sb =
    se.file_header(context.version)
    |> se.imports([
      pkg <> "/handlers",
      pkg <> "/request_types",
      pkg <> "/response_types",
    ])

  let sb =
    list.fold(operations, sb, fn(sb, op) {
      let context.AnalyzedOperation(op_id, operation, _path, _method) = op
      generate_handler_delegator(sb, op_id, operation, "handlers")
    })

  se.to_string(sb)
}

/// Generate a single delegator function in `handlers_generated.gleam`
/// that forwards to `<target_module>.<op_name>`.
fn generate_handler_delegator(
  sb: se.StringBuilder,
  op_id: String,
  operation: openapi.Operation(Resolved),
  target_module: String,
) -> se.StringBuilder {
  let fn_name = naming.operation_to_function_name(op_id)
  let request_type = naming.schema_to_type_name(op_id) <> "Request"
  let response_type = naming.schema_to_type_name(op_id) <> "Response"

  case has_handler_params(operation) {
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
      |> se.indent(1, target_module <> "." <> fn_name <> "(state, req)")
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
      |> se.indent(1, target_module <> "." <> fn_name <> "(state)")
      |> se.line("}")
      |> se.blank_line()
  }
}

/// Generate a single handler stub.
fn generate_handler(
  sb: se.StringBuilder,
  op_id: String,
  operation: openapi.Operation(Resolved),
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

  let has_params = has_handler_params(operation)

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
  // round-trips real bytes instead of being smuggled through `String`.
  // Framework adapters pattern-match on the variant to call
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

  // Generate route function. It threads `app_state: handlers.State`
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
        // When any operation declares
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
      let context.AnalyzedOperation(op_id, operation, path, method) = op
      let fn_name = naming.operation_to_function_name(op_id)
      let method_str = spec.method_to_string(method)
      let path_pattern = path_to_pattern(path)

      let has_params =
        !list.is_empty(operation.parameters)
        || option.is_some(operation.request_body)

      // When the route signature is `body: BitArray`
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
      |> generate_route_body(op_id, fn_name, operation, has_params, ctx)
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
  operation: openapi.Operation(Resolved),
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
      |> generate_response_conversion(response_type_name, operation)
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
  operation: openapi.Operation(Resolved),
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
      p.in_ == openapi.InPath
      && decode_helpers.param_needs_result_unwrap(p, ctx)
    })

  // Required query / header / cookie params, and deep-object query params
  // with a required property. Each becomes its own enclosing case
  // expression so that a missing or invalid value returns 400.
  let required_query_params =
    list.filter(params, fn(p) {
      p.in_ == openapi.InQuery
      && p.required
      && !operation_ir.is_deep_object_param(p, ctx)
    })
  let checked_deep_object_params =
    list.filter(params, fn(p) {
      p.in_ == openapi.InQuery
      && operation_ir.is_deep_object_param(p, ctx)
      && decode_helpers.deep_object_needs_check(p, ctx)
    })
  let required_header_params =
    list.filter(params, fn(p) { p.in_ == openapi.InHeader && p.required })
  let required_cookie_params =
    list.filter(params, fn(p) { p.in_ == openapi.InCookie && p.required })
  // Optional Bool query / header / cookie params. A present value that is
  // not true / false answers 400, so each is read into a Result first.
  let checked_optional_bool_params =
    list.filter_map(params, fn(p) {
      use <- bool.guard(
        p.required || operation_ir.is_deep_object_param(p, ctx),
        Error(Nil),
      )
      case decode_helpers.optional_bool_param_result_expr(p, ctx) {
        Some(result_expr) -> Ok(#(p, result_expr))
        None -> Error(Nil)
      }
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

  // Open nested case expressions for each path param that needs parsing.
  let sb =
    list.fold(path_params_needing_parse, sb, fn(sb, p) {
      let var_name = naming.to_snake_case(p.name)
      let parse_expr = decode_helpers.param_parse_expr(var_name, p, ctx)
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
  // and explode=true int/float arrays, plus `$ref` to string-enum schemas).
  // Bool / string don't need this.
  let sb =
    list.fold(required_query_params, sb, fn(sb, p) {
      query_required_open_parse_case(sb, p, ctx)
    })

  // Open result cases for deep-object params with a required property.
  // `<param>__deep` cannot collide with a parameter variable (see the
  // checked body below).
  let sb =
    list.fold(checked_deep_object_params, sb, fn(sb, p) {
      let var_name = naming.to_snake_case(p.name) <> "__deep"
      sb
      |> se.indent(
        3,
        "let "
          <> var_name
          <> "_result = "
          <> decode_helpers.deep_object_result_expr(p.name, p, op_id, ctx),
      )
      |> se.indent(3, "case " <> var_name <> "_result {")
      |> se.indent(4, "Ok(" <> var_name <> ") -> {")
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
      single_value_required_open_parse_case(sb, p, ctx)
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
      single_value_required_open_parse_case(sb, p, ctx)
    })

  // Open result cases for optional Bool params. `<param>__bool` cannot
  // collide with a parameter variable (see the checked body below).
  let sb =
    list.fold(checked_optional_bool_params, sb, fn(sb, entry) {
      let #(p, result_expr) = entry
      sb
      |> se.indent(3, "case " <> result_expr <> " {")
      |> se.indent(4, "Ok(" <> optional_bool_var(p) <> ") -> {")
    })

  // Determine the body schema reference name (used for decode and guard validation)
  let body_schema_ref_name = case operation.request_body {
    Some(Value(rb)) -> {
      let content_entries = dict.to_list(rb.content)
      case content_entries {
        [#(_ct_name, media_type)] ->
          case media_type.schema {
            Some(openapi.Reference(name:, ..)) -> Some(name)
            _ -> None
          }
        _ -> None
      }
    }
    _ -> None
  }

  // Check if guard validation should be emitted for this body.
  // Guard validation currently only fires for $ref schemas
  // because guards.gleam generates validators keyed by component name.
  // Inline request body schemas with constraints are decoded but NOT
  // guard-validated.
  let needs_guard_validation =
    context.config(ctx).validate
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
            Some(openapi.Reference(name:, ..)) -> {
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

  // A form or multipart body with a required field is built into a Result
  // first, so a missing or invalid field answers 400. The router's own
  // variables contain `__`, which `naming.to_snake_case` never produces, so
  // they cannot collide with a parameter variable.
  let checked_body = case operation.request_body {
    Some(Value(rb)) -> decode_helpers.checked_body_result_expr(rb, op_id, ctx)
    _ -> None
  }
  let sb = case checked_body {
    Some(result_expr) ->
      sb
      |> se.indent(3, "let body__result = " <> result_expr)
      |> se.indent(3, "case body__result {")
      |> se.indent(4, "Ok(checked__body) -> {")
    None -> sb
  }

  // Build request constructor
  let sb =
    sb
    |> se.indent(3, "let request = request_types." <> request_type_name <> "(")

  let sb =
    list.fold(params_with_field_names, sb, fn(sb, entry) {
      let #(param, field_name) = entry
      let trailing = ","
      let checked_optional_bool =
        list.any(checked_optional_bool_params, fn(checked) {
          checked.0 == param
        })
      use <- bool.lazy_guard(checked_optional_bool, fn() {
        sb
        |> se.indent(4, field_name <> ": " <> optional_bool_var(param) <> ",")
      })
      let value_expr = case param.in_ {
        openapi.InPath -> {
          // Use the parsed variable if it needed Result unwrapping
          case decode_helpers.param_needs_result_unwrap(param, ctx) {
            True -> naming.to_snake_case(param.name) <> "_parsed"
            False -> {
              let var_name = naming.to_snake_case(param.name)
              decode_helpers.param_parse_expr(var_name, param, ctx)
            }
          }
        }
        openapi.InQuery -> {
          let key = param.name
          let raw_var = naming.to_snake_case(param.name) <> "_raw"
          let is_deep_object = operation_ir.is_deep_object_param(param, ctx)
          let checked_deep_object =
            is_deep_object && decode_helpers.deep_object_needs_check(param, ctx)
          use <- bool.guard(
            checked_deep_object,
            naming.to_snake_case(param.name) <> "__deep",
          )
          case is_deep_object, param.required {
            True, True ->
              decode_helpers.deep_object_required_expr(key, param, op_id, ctx)
            True, False ->
              decode_helpers.deep_object_optional_expr(key, param, op_id, ctx)
            False, True ->
              decode_helpers.query_required_expr(raw_var, param, ctx)
            False, False -> decode_helpers.query_optional_expr(key, param, ctx)
          }
        }
        openapi.InHeader -> {
          let key = string.lowercase(param.name)
          let raw_var = naming.to_snake_case(param.name) <> "_raw"
          case param.required {
            True -> decode_helpers.header_required_expr(raw_var, param, ctx)
            False -> decode_helpers.header_optional_expr(key, param)
          }
        }
        openapi.InCookie -> {
          let key = param.name
          let raw_var = naming.to_snake_case(param.name) <> "_raw"
          case param.required {
            True -> decode_helpers.cookie_required_expr(raw_var, param, ctx)
            False -> decode_helpers.cookie_optional_expr(key, param)
          }
        }
      }
      sb |> se.indent(4, field_name <> ": " <> value_expr <> trailing)
    })

  // Add body field
  let sb = case needs_body_guard, checked_body {
    True, _ -> sb |> se.indent(4, "body: decoded_body,")
    False, Some(_) -> sb |> se.indent(4, "body: checked__body,")
    False, None ->
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
    |> generate_response_conversion(response_type_name, operation)

  // Close the checked body case
  let sb = case checked_body {
    Some(_) ->
      sb
      |> se.indent(4, "}")
      |> se.indent(
        4,
        "_ -> " <> problem_response_expr(400, "invalid request body"),
      )
      |> se.indent(3, "}")
    None -> sb
  }

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
  // optional Bool, cookie parse, cookie lookup, header parse, header lookup,
  // deep object, query parse, query lookup, then finally the path parse
  // cases. The catch-all `_ ->` arm covers `Ok([])` (empty query lists)
  // along with `Error(_)` so all failure modes return 400.
  let sb =
    list.fold(list.reverse(checked_optional_bool_params), sb, fn(sb, entry) {
      let detail = case { entry.0 }.in_ {
        openapi.InQuery -> "invalid query parameter"
        openapi.InHeader | openapi.InCookie -> "invalid header or cookie"
        openapi.InPath -> "invalid path parameter"
      }
      sb
      |> se.indent(4, "}")
      |> se.indent(4, "_ -> " <> problem_response_expr(400, detail))
      |> se.indent(3, "}")
    })
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
    list.fold(checked_deep_object_params, sb, fn(sb, _p) {
      close_lookup_case(sb)
    })
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

/// The variable an optional Bool param is bound to once it parsed. The
/// router's own variables contain `__`, which `naming.to_snake_case` never
/// produces, so it cannot collide with a parameter variable.
fn optional_bool_var(p: openapi.Parameter(Resolved)) -> String {
  naming.to_snake_case(p.name) <> "__bool"
}

/// True when this query param is treated as a list (explode=true array).
/// Matches the helper used by `query_required_expr` so the open/close
/// scaffolding stays in sync with the value expression.
fn query_param_explode_array(p: openapi.Parameter(Resolved)) -> Bool {
  case spec.parameter_schema(p) {
    Some(openapi.Inline(openapi.ArraySchema(..))) -> {
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
/// - Bool or array of Bool → match `true` / `false`, see `open_bool_parse`.
/// String / array-of-string need no extra case.
fn query_required_open_parse_case(
  sb: se.StringBuilder,
  p: openapi.Parameter(Resolved),
  ctx: Context,
) -> se.StringBuilder {
  let raw_var = naming.to_snake_case(p.name) <> "_raw"
  let delim = case p.style {
    Some(openapi.PipeDelimitedStyle) -> "|"
    Some(openapi.SpaceDelimitedStyle) -> " "
    _ -> ","
  }
  let items = case query_param_explode_array(p) {
    True -> raw_var
    False -> "string.split(" <> raw_var <> ", \"" <> delim <> "\")"
  }
  use <- bool.lazy_guard(is_bool_param(p, ctx), fn() {
    open_bool_parse(sb, p, raw_var, items, ctx)
  })
  case spec.parameter_schema(p) {
    Some(openapi.Inline(openapi.IntegerSchema(..))) ->
      sb
      |> se.indent(3, "case int.parse(" <> raw_var <> ") {")
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed) -> {")
    Some(openapi.Inline(openapi.NumberSchema(..))) ->
      sb
      |> se.indent(3, "case float.parse(" <> raw_var <> ") {")
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed) -> {")
    Some(openapi.Inline(openapi.ArraySchema(
      items: Inline(openapi.IntegerSchema(..)),
      ..,
    ))) -> {
      let parse_expr = array_int_parse_expr(raw_var, p, delim)
      sb
      |> se.indent(3, "case " <> parse_expr <> " {")
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed_list) -> {")
    }
    Some(openapi.Inline(openapi.ArraySchema(
      items: Inline(openapi.NumberSchema(..)),
      ..,
    ))) -> {
      let parse_expr = array_float_parse_expr(raw_var, p, delim)
      sb
      |> se.indent(3, "case " <> parse_expr <> " {")
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed_list) -> {")
    }
    Some(ref) ->
      // Required `$ref` to a string-enum schema needs the
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
  p: openapi.Parameter(Resolved),
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
  p: openapi.Parameter(Resolved),
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

/// Open the case that parses a required Bool param (`<raw>_parsed`) or
/// list of Bools (`<raw>_parsed_list`) from `raw_var`, whose items are
/// `items` for a list. Returns `sb` unchanged for any other param.
fn open_bool_parse(
  sb: se.StringBuilder,
  p: openapi.Parameter(Resolved),
  raw_var: String,
  items: String,
  ctx: Context,
) -> se.StringBuilder {
  case decode_helpers.bool_shape(spec.parameter_schema(p), ctx) {
    Some(decode_helpers.BoolScalar) ->
      sb
      |> se.indent(
        3,
        "case " <> decode_helpers.bool_result_expr(raw_var) <> " {",
      )
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed) -> {")
    Some(decode_helpers.BoolList) ->
      sb
      |> se.indent(
        3,
        "case " <> decode_helpers.bool_list_result_expr(items) <> " {",
      )
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed_list) -> {")
    None -> sb
  }
}

fn is_bool_param(p: openapi.Parameter(Resolved), ctx: Context) -> Bool {
  option.is_some(decode_helpers.bool_shape(spec.parameter_schema(p), ctx))
}

/// Close the matching parse case for a required query param.
fn close_query_required_parse_case(
  sb: se.StringBuilder,
  p: openapi.Parameter(Resolved),
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
  use <- bool.lazy_guard(is_bool_param(p, ctx), fn() { close(sb) })
  case spec.parameter_schema(p) {
    Some(openapi.Inline(openapi.IntegerSchema(..)))
    | Some(openapi.Inline(openapi.NumberSchema(..)))
    | Some(openapi.Inline(openapi.ArraySchema(
        items: Inline(openapi.IntegerSchema(..)),
        ..,
      )))
    | Some(openapi.Inline(openapi.ArraySchema(
        items: Inline(openapi.NumberSchema(..)),
        ..,
      ))) -> close(sb)
    Some(ref) ->
      // Matches the open emitted in
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
/// scalar Integer/Number. Header/cookie arrays are parsed by a single inline
/// `list.map(string.split(...))` expression and get no parse case.
fn single_value_required_open_parse_case(
  sb: se.StringBuilder,
  p: openapi.Parameter(Resolved),
  ctx: Context,
) -> se.StringBuilder {
  let raw_var = naming.to_snake_case(p.name) <> "_raw"
  use <- bool.lazy_guard(is_bool_param(p, ctx), fn() {
    open_bool_parse(
      sb,
      p,
      raw_var,
      "string.split(" <> raw_var <> ", \",\")",
      ctx,
    )
  })
  case spec.parameter_schema(p) {
    Some(openapi.Inline(openapi.IntegerSchema(..))) ->
      sb
      |> se.indent(3, "case int.parse(" <> raw_var <> ") {")
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed) -> {")
    Some(openapi.Inline(openapi.NumberSchema(..))) ->
      sb
      |> se.indent(3, "case float.parse(" <> raw_var <> ") {")
      |> se.indent(4, "Ok(" <> raw_var <> "_parsed) -> {")
    Some(openapi.Inline(openapi.ArraySchema(
      items: Inline(openapi.IntegerSchema(..)),
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
    Some(openapi.Inline(openapi.ArraySchema(
      items: Inline(openapi.NumberSchema(..)),
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
  p: openapi.Parameter(Resolved),
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
  use <- bool.lazy_guard(is_bool_param(p, ctx), fn() { close(sb) })
  case spec.parameter_schema(p) {
    Some(openapi.Inline(openapi.IntegerSchema(..)))
    | Some(openapi.Inline(openapi.NumberSchema(..)))
    | Some(openapi.Inline(openapi.ArraySchema(
        items: Inline(openapi.IntegerSchema(..)),
        ..,
      )))
    | Some(openapi.Inline(openapi.ArraySchema(
        items: Inline(openapi.NumberSchema(..)),
        ..,
      ))) -> close(sb)
    Some(ref) ->
      // Matches the open emitted in
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
/// `application/problem+json` content.
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
  operation: openapi.Operation(Resolved),
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
              let status_int = http.status_code_to_int_literal(status_code)
              // The OpenAPI `default` response is the only
              // status whose generated variant carries a runtime status
              // code (`Foo(Int [, body] [, headers])`). The router
              // pattern grows a `status` binding and uses it as the
              // outgoing `ServerResponse.status` instead of the
              // hardcoded representative-int (which was always 500).
              let is_default = case status_code {
                openapi.DefaultStatus -> True
                _ -> False
              }
              let content_entries = dict.to_list(response.content)
              let header_specs = router_ir.sorted_header_specs(response.headers)
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
                  case media_type.schema {
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
                    Some(_) -> {
                      let body_expr = case
                        content_type.from_string(media_type_name)
                      {
                        content_type.TextPlain
                        | content_type.ApplicationXml
                        | content_type.TextXml -> "TextBody(data)"
                        // Binary responses thread bytes end-to-end via
                        // `BytesBody(BitArray)`; `*/*` responses are handed
                        // to the user as raw BitArray too. The matching
                        // response_types variant carries `BitArray`.
                        content_type.ApplicationOctetStream
                        | content_type.Wildcard -> "BytesBody(data)"
                        content_type.ApplicationJson
                        | content_type.MultipartFormData
                        | content_type.FormUrlEncoded
                        | content_type.UnsupportedContentType(_) ->
                          "TextBody(json.to_string("
                          <> get_encode_function(media_type.schema)
                          <> "(data)))"
                      }
                      emit_response_arm(
                        sb,
                        variant_name,
                        status_int,
                        has_data: True,
                        has_headers: has_headers,
                        body_expr: body_expr,
                        content_type_header: Some(media_type_name),
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

/// Emit one arm of the response dispatch `case` block.
///
/// When `has_headers` is
/// True the variant pattern grows an `hdrs` binding and the headers
/// list is materialised via `list.flatten` so spec-declared response
/// headers are appended to the implicit `content-type` tuple.
///
/// When `is_default` is True the variant pattern grows a
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
  header_specs header_specs: List(router_ir.HeaderSpec),
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
  header_specs: List(router_ir.HeaderSpec),
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
/// Int and Float values are stringified via `int.to_string` /
/// `float.to_string` (the necessary imports are added by the
/// import-analysis pass), and a Bool as `true` or `false`.
fn header_chunk_expr(spec: router_ir.HeaderSpec) -> String {
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
    "Bool" -> schema_dispatch.bool_to_wire(value_expr)
    _ -> value_expr
  }
}

/// Get the encode function name for a schema reference.
fn get_encode_function(schema_ref: option.Option(openapi.SchemaRef)) -> String {
  case schema_ref {
    Some(Reference(name:, ..)) -> {
      "encode.encode_" <> naming.to_snake_case(name) <> "_json"
    }
    Some(Inline(openapi.ArraySchema(items:, ..))) -> {
      case items {
        Reference(name:, ..) ->
          "fn(items) { json.array(items, encode.encode_"
          <> naming.to_snake_case(name)
          <> "_json) }"
        Inline(openapi.StringSchema(..)) ->
          "fn(items) { json.array(items, json.string) }"
        Inline(openapi.IntegerSchema(..)) ->
          "fn(items) { json.array(items, json.int) }"
        Inline(openapi.NumberSchema(..)) ->
          "fn(items) { json.array(items, json.float) }"
        Inline(openapi.BooleanSchema(..)) ->
          "fn(items) { json.array(items, json.bool) }"
        // Inline non-primitive items (e.g. nested ArraySchema, anonymous
        // ObjectSchema) at the top level of a response have no reusable
        // encoder. A homogeneous String array keeps the call type-checking
        // against List(_), where a bare "json.string" would not compile.
        Inline(openapi.ArraySchema(..))
        | Inline(openapi.ObjectSchema(..))
        | Inline(openapi.AllOfSchema(..))
        | Inline(openapi.OneOfSchema(..))
        | Inline(openapi.AnyOfSchema(..)) ->
          "fn(items) { json.array(items, json.string) }"
      }
    }
    Some(Inline(openapi.IntegerSchema(..))) -> "json.int"
    Some(Inline(openapi.NumberSchema(..))) -> "json.float"
    Some(Inline(openapi.BooleanSchema(..))) -> "json.bool"
    Some(Inline(openapi.StringSchema(..)))
    | Some(Inline(openapi.ObjectSchema(..)))
    | Some(Inline(openapi.AllOfSchema(..)))
    | Some(Inline(openapi.OneOfSchema(..)))
    | Some(Inline(openapi.AnyOfSchema(..)))
    | None -> "json.string"
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

  "[" <> string.join(patterns, ", ") <> "]"
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
