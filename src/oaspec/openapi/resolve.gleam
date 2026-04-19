import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import oaspec/openapi/diagnostic.{type Diagnostic, NoSourceLoc}
import oaspec/openapi/spec.{
  type Callback, type Components, type OpenApiSpec, type Operation,
  type Parameter, type PathItem, type RefOr, type RequestBody, type Resolved,
  type Response, type Unresolved, Callback, Components, Operation, PathItem, Ref,
  Value,
}

/// Resolve all RefOr aliases in the spec.
/// Call after parse and normalize, before capability_check and codegen.
/// Resolves both component-level aliases and inline $ref within operations.
pub fn resolve(
  spec: OpenApiSpec(Unresolved),
) -> Result(OpenApiSpec(Resolved), List(Diagnostic)) {
  use resolved <- result.try(resolve_internal(spec))
  Ok(coerce_stage(resolved))
}

/// Safe phantom type cast — stage has no runtime representation.
@external(erlang, "gleam_stdlib", "identity")
fn coerce_stage(spec: OpenApiSpec(a)) -> OpenApiSpec(b)

/// Internal resolve that preserves the input stage parameter.
fn resolve_internal(
  spec: OpenApiSpec(stage),
) -> Result(OpenApiSpec(stage), List(Diagnostic)) {
  let empty_components =
    Components(
      schemas: dict.new(),
      parameters: dict.new(),
      request_bodies: dict.new(),
      responses: dict.new(),
      security_schemes: dict.new(),
      path_items: dict.new(),
      headers: dict.new(),
      examples: dict.new(),
      links: dict.new(),
    )
  case spec.components {
    None -> {
      // Even without components, paths/webhooks may contain inline $ref
      // that must be resolved (or reported as errors).
      use resolved_paths <- result.try(resolve_inline_paths(
        spec.paths,
        empty_components,
      ))
      use resolved_webhooks <- result.try(resolve_inline_paths(
        spec.webhooks,
        empty_components,
      ))
      Ok(
        spec.OpenApiSpec(
          ..spec,
          paths: resolved_paths,
          webhooks: resolved_webhooks,
        ),
      )
    }
    Some(components) -> {
      use parameters <- result.try(
        resolve_component_dict(components.parameters, "components.parameters")
        |> result.map_error(fn(e) { [e] }),
      )
      use request_bodies <- result.try(
        resolve_component_dict(
          components.request_bodies,
          "components.requestBodies",
        )
        |> result.map_error(fn(e) { [e] }),
      )
      use responses <- result.try(
        resolve_component_dict(components.responses, "components.responses")
        |> result.map_error(fn(e) { [e] }),
      )
      use security_schemes <- result.try(
        resolve_component_dict(
          components.security_schemes,
          "components.securitySchemes",
        )
        |> result.map_error(fn(e) { [e] }),
      )
      use path_items <- result.try(
        resolve_component_dict(components.path_items, "components.pathItems")
        |> result.map_error(fn(e) { [e] }),
      )
      let resolved_components =
        Components(
          ..components,
          parameters: parameters,
          request_bodies: request_bodies,
          responses: responses,
          security_schemes: security_schemes,
          path_items: path_items,
        )
      // Resolve inline $ref in paths and webhooks
      use resolved_paths <- result.try(resolve_inline_paths(
        spec.paths,
        resolved_components,
      ))
      use resolved_webhooks <- result.try(resolve_inline_paths(
        spec.webhooks,
        resolved_components,
      ))
      Ok(
        spec.OpenApiSpec(
          ..spec,
          components: Some(resolved_components),
          paths: resolved_paths,
          webhooks: resolved_webhooks,
        ),
      )
    }
  }
}

/// Resolve all aliases in a component dict.
/// After resolution, all entries are Value.
fn resolve_component_dict(
  entries: Dict(String, RefOr(a)),
  context: String,
) -> Result(Dict(String, RefOr(a)), Diagnostic) {
  dict.to_list(entries)
  |> list.try_fold(entries, fn(acc, entry) {
    let #(name, value) = entry
    case value {
      Value(_) -> Ok(acc)
      Ref(ref) -> {
        use resolved <- result.try(resolve_alias(
          entries,
          ref,
          context <> "." <> name,
          set.new(),
        ))
        Ok(dict.insert(acc, name, Value(resolved)))
      }
    }
  })
}

/// Follow a $ref chain to find the concrete value.
fn resolve_alias(
  entries: Dict(String, RefOr(a)),
  ref: String,
  context: String,
  seen: set.Set(String),
) -> Result(a, Diagnostic) {
  use <- bool.guard(
    set.contains(seen, ref),
    Error(diagnostic.resolve_error(
      path: context,
      detail: "Circular component alias detected: " <> ref,
      hint: Some(
        "Check that component $ref chains don't form a cycle. Each $ref must eventually point to a concrete definition.",
      ),
      loc: NoSourceLoc,
    )),
  )
  let new_seen = set.insert(seen, ref)
  let ref_name = extract_ref_name(ref)
  case dict.get(entries, ref_name) {
    Ok(Value(value)) -> Ok(value)
    Ok(Ref(next_ref)) -> resolve_alias(entries, next_ref, context, new_seen)
    Error(_) ->
      Error(diagnostic.resolve_error(
        path: context,
        detail: "Unresolved component alias: "
          <> ref
          <> " — target '"
          <> ref_name
          <> "' not found.",
        hint: Some(
          "Verify the target component exists and the $ref path is spelled correctly.",
        ),
        loc: NoSourceLoc,
      ))
  }
}

/// Extract the last segment of a $ref path.
fn extract_ref_name(ref: String) -> String {
  ref
  |> string.split("/")
  |> list.last
  |> result.unwrap("unknown")
}

/// Validate that a $ref string points to the expected component kind.
/// Returns Ok(name) if valid, Error(diagnostic) if wrong kind or external.
fn validate_ref_kind(
  ref_str: String,
  expected_prefix: String,
  context_path: String,
) -> Result(String, Diagnostic) {
  use <- bool.guard(
    string.starts_with(ref_str, expected_prefix),
    Ok(extract_ref_name(ref_str)),
  )
  Error(diagnostic.resolve_error(
    path: context_path,
    detail: "$ref '"
      <> ref_str
      <> "' points to wrong component kind; expected prefix '"
      <> expected_prefix
      <> "'",
    hint: Some(
      "Use the correct $ref prefix for the component type (e.g., #/components/schemas/ for schemas).",
    ),
    loc: NoSourceLoc,
  ))
}

// ============================================================================
// Inline ref resolution: resolve Ref(...) within paths, operations, etc.
// ============================================================================

/// Resolve inline refs in a paths dict by looking up components.
fn resolve_inline_paths(
  paths: Dict(String, RefOr(PathItem(stage))),
  components: Components(stage),
) -> Result(Dict(String, RefOr(PathItem(stage))), List(Diagnostic)) {
  dict.to_list(paths)
  |> list.try_fold(dict.new(), fn(acc, entry) {
    let #(path, ref_or) = entry
    case ref_or {
      Ref(ref_str) ->
        case resolve_path_item_ref(ref_str, path, components) {
          Ok(resolved) -> Ok(dict.insert(acc, path, resolved))
          Error(e) -> Error([e])
        }
      Value(pi) ->
        case resolve_inline_path_item(pi, path, components) {
          Ok(resolved_pi) -> Ok(dict.insert(acc, path, Value(resolved_pi)))
          Error(errs) -> Error(errs)
        }
    }
  })
}

/// Resolve a path-level $ref by looking it up in components.pathItems.
fn resolve_path_item_ref(
  ref_str: String,
  path: String,
  components: Components(stage),
) -> Result(RefOr(PathItem(stage)), Diagnostic) {
  use ref_name <- result.try(validate_ref_kind(
    ref_str,
    "#/components/pathItems/",
    "paths." <> path,
  ))
  case dict.get(components.path_items, ref_name) {
    Ok(Value(pi)) ->
      case resolve_inline_path_item(pi, path, components) {
        Ok(resolved_pi) -> Ok(Value(resolved_pi))
        Error(errs) -> {
          // Take the first diagnostic from the inner resolution
          case errs {
            [first, ..] -> Error(first)
            [] ->
              Error(diagnostic.resolve_error(
                path: "paths." <> path,
                detail: "Unresolved $ref: "
                  <> ref_str
                  <> " — target not found in components",
                hint: Some(
                  "Verify the referenced component exists and the $ref path is spelled correctly.",
                ),
                loc: NoSourceLoc,
              ))
          }
        }
      }
    Ok(Ref(_)) ->
      Error(diagnostic.resolve_error(
        path: "paths." <> path,
        detail: "Unresolved $ref: "
          <> ref_str
          <> " — target not found in components",
        hint: Some(
          "Verify the referenced component exists and the $ref path is spelled correctly.",
        ),
        loc: NoSourceLoc,
      ))
    Error(_) ->
      Error(diagnostic.resolve_error(
        path: "paths." <> path,
        detail: "Unresolved $ref: "
          <> ref_str
          <> " — target not found in components",
        hint: Some(
          "Verify the referenced component exists and the $ref path is spelled correctly.",
        ),
        loc: NoSourceLoc,
      ))
  }
}

/// Resolve inline refs within a path item.
fn resolve_inline_path_item(
  pi: PathItem(stage),
  path: String,
  components: Components(stage),
) -> Result(PathItem(stage), List(Diagnostic)) {
  use get <- result.try(
    option_try(pi.get, resolve_inline_operation(_, path, components)),
  )
  use post <- result.try(
    option_try(pi.post, resolve_inline_operation(_, path, components)),
  )
  use put <- result.try(
    option_try(pi.put, resolve_inline_operation(_, path, components)),
  )
  use delete <- result.try(
    option_try(pi.delete, resolve_inline_operation(_, path, components)),
  )
  use patch <- result.try(
    option_try(pi.patch, resolve_inline_operation(_, path, components)),
  )
  use head <- result.try(
    option_try(pi.head, resolve_inline_operation(_, path, components)),
  )
  use options <- result.try(
    option_try(pi.options, resolve_inline_operation(_, path, components)),
  )
  use trace <- result.try(
    option_try(pi.trace, resolve_inline_operation(_, path, components)),
  )
  use parameters <- result.try(
    list.try_map(pi.parameters, fn(p) {
      resolve_param_ref(p, path, components)
      |> result.map_error(fn(e) { [e] })
    }),
  )
  Ok(
    PathItem(
      ..pi,
      get: get,
      post: post,
      put: put,
      delete: delete,
      patch: patch,
      head: head,
      options: options,
      trace: trace,
      parameters: parameters,
    ),
  )
}

/// Resolve inline refs within an operation.
fn resolve_inline_operation(
  op: Operation(stage),
  path: String,
  components: Components(stage),
) -> Result(Operation(stage), List(Diagnostic)) {
  use parameters <- result.try(
    list.try_map(op.parameters, fn(p) {
      resolve_param_ref(p, path, components)
      |> result.map_error(fn(e) { [e] })
    }),
  )
  use request_body <- result.try(
    option_try(op.request_body, fn(rb) {
      resolve_request_body_ref(rb, path, components)
      |> result.map_error(fn(e) { [e] })
    }),
  )
  use responses <- result.try(
    try_map_values(op.responses, fn(_code, ref_or) {
      resolve_response_ref(ref_or, path, components)
      |> result.map_error(fn(e) { [e] })
    }),
  )
  use callbacks <- result.try(
    try_map_values(op.callbacks, fn(_name, cb) {
      resolve_inline_callback(cb, path, components)
    }),
  )
  Ok(
    Operation(
      ..op,
      parameters: parameters,
      request_body: request_body,
      responses: responses,
      callbacks: callbacks,
    ),
  )
}

/// Resolve inline refs within a callback.
fn resolve_inline_callback(
  cb: Callback(stage),
  path: String,
  components: Components(stage),
) -> Result(Callback(stage), List(Diagnostic)) {
  use entries <- result.try(
    try_map_values(cb.entries, fn(_url, ref_or) {
      case ref_or {
        Ref(ref_str) ->
          resolve_path_item_ref(ref_str, path, components)
          |> result.map_error(fn(e) { [e] })
        Value(pi) ->
          case resolve_inline_path_item(pi, path, components) {
            Ok(resolved_pi) -> Ok(Value(resolved_pi))
            Error(errs) -> Error(errs)
          }
      }
    }),
  )
  Ok(Callback(entries: entries))
}

/// Resolve a parameter Ref by looking it up in components.parameters.
fn resolve_param_ref(
  ref_or: RefOr(Parameter(stage)),
  path: String,
  components: Components(stage),
) -> Result(RefOr(Parameter(stage)), Diagnostic) {
  case ref_or {
    Value(_) -> Ok(ref_or)
    Ref(ref_str) -> {
      use ref_name <- result.try(validate_ref_kind(
        ref_str,
        "#/components/parameters/",
        "paths." <> path,
      ))
      case dict.get(components.parameters, ref_name) {
        Ok(Value(p)) -> Ok(Value(p))
        _ ->
          Error(diagnostic.resolve_error(
            path: "paths." <> path,
            detail: "Unresolved $ref: "
              <> ref_str
              <> " — target not found in components.parameters",
            hint: Some("Verify the parameter exists in components.parameters."),
            loc: NoSourceLoc,
          ))
      }
    }
  }
}

/// Resolve a request body Ref by looking it up in components.request_bodies.
fn resolve_request_body_ref(
  ref_or: RefOr(RequestBody(stage)),
  path: String,
  components: Components(stage),
) -> Result(RefOr(RequestBody(stage)), Diagnostic) {
  case ref_or {
    Value(_) -> Ok(ref_or)
    Ref(ref_str) -> {
      use ref_name <- result.try(validate_ref_kind(
        ref_str,
        "#/components/requestBodies/",
        "paths." <> path,
      ))
      case dict.get(components.request_bodies, ref_name) {
        Ok(Value(rb)) -> Ok(Value(rb))
        _ ->
          Error(diagnostic.resolve_error(
            path: "paths." <> path,
            detail: "Unresolved $ref: "
              <> ref_str
              <> " — target not found in components.requestBodies",
            hint: Some(
              "Verify the request body exists in components.requestBodies.",
            ),
            loc: NoSourceLoc,
          ))
      }
    }
  }
}

/// Resolve a response Ref by looking it up in components.responses.
fn resolve_response_ref(
  ref_or: RefOr(Response(stage)),
  path: String,
  components: Components(stage),
) -> Result(RefOr(Response(stage)), Diagnostic) {
  case ref_or {
    Value(_) -> Ok(ref_or)
    Ref(ref_str) -> {
      use ref_name <- result.try(validate_ref_kind(
        ref_str,
        "#/components/responses/",
        "paths." <> path,
      ))
      case dict.get(components.responses, ref_name) {
        Ok(Value(r)) -> Ok(Value(r))
        _ ->
          Error(diagnostic.resolve_error(
            path: "paths." <> path,
            detail: "Unresolved $ref: "
              <> ref_str
              <> " — target not found in components.responses",
            hint: Some("Verify the response exists in components.responses."),
            loc: NoSourceLoc,
          ))
      }
    }
  }
}

/// Map over an Option value with a fallible function.
fn option_try(
  opt: Option(a),
  f: fn(a) -> Result(a, List(Diagnostic)),
) -> Result(Option(a), List(Diagnostic)) {
  case opt {
    Some(v) -> result.map(f(v), Some)
    None -> Ok(None)
  }
}

/// Map over dict values with a fallible function, collecting first error.
fn try_map_values(
  d: Dict(k, a),
  f: fn(k, a) -> Result(a, List(Diagnostic)),
) -> Result(Dict(k, a), List(Diagnostic)) {
  dict.to_list(d)
  |> list.try_fold(dict.new(), fn(acc, entry) {
    let #(key, value) = entry
    use new_value <- result.try(f(key, value))
    Ok(dict.insert(acc, key, new_value))
  })
}
