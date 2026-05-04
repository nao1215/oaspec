import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import oaspec/config
import oaspec/internal/capability
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/openapi/location_index.{type LocationIndex}
import oaspec/internal/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  Inline, ObjectSchema, OneOfSchema, Reference, Typed,
}
import oaspec/internal/openapi/spec.{
  type HttpMethod, type OpenApiSpec, type Resolved, Value,
}
import oaspec/internal/util/http
import oaspec/openapi/diagnostic.{
  type Diagnostic, type SourceLoc, SeverityError, SeverityWarning, TargetBoth,
  TargetServer,
}

/// Run capability checks on a resolved spec.
/// Returns errors for unsupported features and warnings for parsed-but-unused features.
///
/// The `index` carries YAML line/column information used to attach
/// `SourceLoc` to each diagnostic (Issue #411). Callers that genuinely
/// have no source-location data (e.g. tests that synthesise a
/// `OpenApiSpec` directly) can pass `location_index.empty()`; every
/// diagnostic will then carry `NoSourceLoc`, matching pre-#411 behaviour.
pub fn check(
  spec: OpenApiSpec(Resolved),
  index: LocationIndex,
) -> List(Diagnostic) {
  let schema_errors = check_schemas(spec, index)
  let security_errors = check_security_schemes(spec, index)
  list.flatten([schema_errors, security_errors])
}

/// Check all schemas for unsupported keywords stored during lossless parse.
/// Covers both component schemas and inline schemas in operations.
fn check_schemas(
  spec: OpenApiSpec(Resolved),
  index: LocationIndex,
) -> List(Diagnostic) {
  let component_errors = case spec.components {
    None -> []
    Some(components) ->
      dict.to_list(components.schemas)
      |> list.flat_map(fn(entry) {
        let #(name, schema_ref) = entry
        check_schema_ref("components.schemas." <> name, schema_ref, index)
      })
  }
  let inline_errors = check_inline_schemas(spec, index)
  list.append(component_errors, inline_errors)
}

/// Check inline schemas within operations (request bodies, responses, parameters).
fn check_inline_schemas(
  spec: OpenApiSpec(Resolved),
  index: LocationIndex,
) -> List(Diagnostic) {
  dict.to_list(spec.paths)
  |> list.flat_map(fn(path_entry) {
    let #(path, ref_or) = path_entry
    case ref_or {
      Value(path_item) ->
        check_path_item_schemas("paths." <> path, path_item, index)
      _ -> []
    }
  })
}

fn check_path_item_schemas(
  base_path: String,
  pi: spec.PathItem(Resolved),
  index: LocationIndex,
) -> List(Diagnostic) {
  let method_ops = [
    #("get", pi.get),
    #("post", pi.post),
    #("put", pi.put),
    #("delete", pi.delete),
    #("patch", pi.patch),
    #("head", pi.head),
    #("options", pi.options),
    #("trace", pi.trace),
  ]
  list.flat_map(method_ops, fn(entry) {
    let #(method, maybe_op) = entry
    case maybe_op {
      Some(op) -> check_operation_schemas(base_path <> "." <> method, op, index)
      None -> []
    }
  })
}

fn check_operation_schemas(
  base_path: String,
  op: spec.Operation(Resolved),
  index: LocationIndex,
) -> List(Diagnostic) {
  // Check request body schemas
  let rb_errors = case op.request_body {
    Some(Value(rb)) ->
      dict.to_list(rb.content)
      |> list.flat_map(fn(entry) {
        let #(ct, mt) = entry
        case mt.schema {
          Some(sr) ->
            check_schema_ref(
              base_path <> ".requestBody.content." <> ct <> ".schema",
              sr,
              index,
            )
          None -> []
        }
      })
    _ -> []
  }
  // Check response schemas
  let resp_errors =
    dict.to_list(op.responses)
    |> list.flat_map(fn(entry) {
      let #(code, ref_or) = entry
      case ref_or {
        Value(resp) ->
          dict.to_list(resp.content)
          |> list.flat_map(fn(ct_entry) {
            let #(ct, mt) = ct_entry
            case mt.schema {
              Some(sr) ->
                check_schema_ref(
                  base_path
                    <> ".responses."
                    <> http.status_code_to_string(code)
                    <> ".content."
                    <> ct
                    <> ".schema",
                  sr,
                  index,
                )
              None -> []
            }
          })
        _ -> []
      }
    })
  list.append(rb_errors, resp_errors)
}

/// Check a SchemaRef recursively for unsupported keywords.
fn check_schema_ref(
  path: String,
  ref: SchemaRef,
  index: LocationIndex,
) -> List(Diagnostic) {
  case ref {
    Reference(..) -> []
    Inline(schema_obj) -> check_schema(path, schema_obj, index)
  }
}

/// Check a single schema and recurse into children.
fn check_schema(
  path: String,
  schema_obj: SchemaObject,
  index: LocationIndex,
) -> List(Diagnostic) {
  let metadata = schema.get_metadata(schema_obj)

  // Check unsupported keywords stored by lossless parser. Try the
  // first offending keyword's exact YAML path (e.g.
  // `...WithDefs.$defs`) before falling back to the schema-level loc;
  // pointing at the keyword itself is more useful in editors than
  // the surrounding schema header.
  let keyword_errors = case metadata.unsupported_keywords {
    [] -> []
    keywords -> {
      let keyword_list = string.join(keywords, "', '")
      let loc = case keywords {
        [first, ..] ->
          location_index.lookup_with_ancestor(index, path <> "." <> first)
        [] -> location_index.lookup_with_ancestor(index, path)
      }
      [
        diagnostic.capability(
          severity: SeverityError,
          target: TargetBoth,
          path: path,
          detail: "Unsupported JSON Schema keyword '"
            <> keyword_list
            <> "' found. Remove or model differently. See: "
            <> string.join(
            list.filter_map(keywords, fn(k) {
              list.find(capability.registry(), fn(c) { c.name == k })
              |> result.map(fn(c) { c.note })
            }),
            "; ",
          ),
          hint: Some(
            "Remove the keyword or restructure the schema using supported constructs.",
          ),
          loc: loc,
        ),
      ]
    }
  }

  // Recurse into children
  let child_errors = case schema_obj {
    ObjectSchema(properties:, additional_properties:, ..) -> {
      let prop_errors =
        dict.to_list(properties)
        |> list.flat_map(fn(e) {
          check_schema_ref(path <> ".properties." <> e.0, e.1, index)
        })
      let ap_errors = case additional_properties {
        Typed(ap) ->
          check_schema_ref(path <> ".additionalProperties", ap, index)
        _ -> []
      }
      list.append(prop_errors, ap_errors)
    }
    ArraySchema(items:, ..) -> check_schema_ref(path <> ".items", items, index)
    AllOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s) {
        check_schema_ref(path <> ".allOf", s, index)
      })
    OneOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s) {
        check_schema_ref(path <> ".oneOf", s, index)
      })
    AnyOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s) {
        check_schema_ref(path <> ".anyOf", s, index)
      })
    _ -> []
  }

  list.append(keyword_errors, child_errors)
}

/// Check security schemes for unsupported types (e.g. mutualTLS).
fn check_security_schemes(
  spec: OpenApiSpec(Resolved),
  index: LocationIndex,
) -> List(Diagnostic) {
  case spec.components {
    None -> []
    Some(components) ->
      dict.to_list(components.security_schemes)
      |> list.filter_map(fn(entry) {
        let #(name, ref_or) = entry
        case ref_or {
          Value(spec.UnsupportedScheme(scheme_type:)) -> {
            let path = "components.securitySchemes." <> name
            Ok(diagnostic.capability(
              severity: SeverityError,
              target: TargetBoth,
              path: path,
              detail: "Unsupported security scheme type: '"
                <> scheme_type
                <> "'. Supported types: apiKey, http, oauth2, openIdConnect.",
              hint: Some(
                "Use apiKey, http (bearer), oauth2, or openIdConnect instead.",
              ),
              loc: location_index.lookup_with_ancestor(index, path),
            ))
          }
          _ -> Error(Nil)
        }
      })
  }
}

/// Render a `paths.<url>.<method>` YAML pointer for the AnalyzedOperation
/// the LocationIndex was built from. The index keys URLs verbatim
/// (matching yamerl's literal YAML key text) so no `~1` escaping is
/// needed; method names are folded to lowercase to match the YAML
/// document.
fn operation_yaml_prefix(url: String, method: HttpMethod) -> String {
  "paths." <> url <> "." <> string.lowercase(spec.method_to_string(method))
}

/// Translate a capability-check `op_id`-rooted path into a YAML pointer
/// the LocationIndex understands. Unmatched paths (e.g. `webhooks`,
/// `components.*`) pass through unchanged.
fn capability_path_to_yaml(
  path: String,
  operations: List(context.AnalyzedOperation),
) -> String {
  case string.split(path, ".") {
    [first, ..rest] ->
      case
        list.find_map(operations, fn(op) {
          let #(op_id, _, url, method) = op
          case op_id == first {
            True -> Ok(operation_yaml_prefix(url, method))
            False -> Error(Nil)
          }
        })
      {
        Ok(prefix) ->
          case rest {
            [] -> prefix
            _ -> prefix <> "." <> string.join(rest, ".")
          }
        // nolint: thrown_away_error -- non-op_id paths (e.g. `webhooks`, `components.*`) pass through unchanged; there is no error to propagate here.
        Error(_) -> path
      }
    [] -> path
  }
}

/// Resolve a SourceLoc for a capability-check diagnostic path by
/// translating to a YAML pointer (op_id → paths.<url>.<method>) and
/// falling back to the closest known ancestor when the exact path
/// isn't in the index.
fn lookup_loc(ctx: Context, index: LocationIndex, path: String) -> SourceLoc {
  let yaml_path = capability_path_to_yaml(path, context.operations(ctx))
  location_index.lookup_with_ancestor(index, yaml_path)
}

/// Check for parsed-but-unused AST features, emitting warnings.
/// This is the single source of truth for "parsed but not generated" diagnostics.
/// Requires Context because some checks iterate over resolved operations.
pub fn check_preserved(ctx: Context, index: LocationIndex) -> List(Diagnostic) {
  let webhook_warnings = case dict.is_empty(context.spec(ctx).webhooks) {
    True -> []
    False -> [
      diagnostic.capability(
        severity: SeverityWarning,
        target: TargetBoth,
        path: "webhooks",
        detail: "Webhooks are parsed but not used by code generation.",
        hint: Some(
          "Webhooks will not appear in generated code. No action needed unless you expected them.",
        ),
        loc: location_index.lookup_with_ancestor(index, "webhooks"),
      ),
    ]
  }
  let ops = context.operations(ctx)
  let response_warnings =
    list.flat_map(ops, fn(op) {
      let #(op_id, operation, _path, _method) = op
      let entries = dict.to_list(operation.responses)
      list.flat_map(entries, fn(entry) {
        let #(status_code, ref_or) = entry
        case ref_or {
          Value(response) -> {
            let base_path =
              op_id <> ".responses." <> http.status_code_to_string(status_code)
            let multi_content_warnings = case
              config.mode(context.config(ctx)),
              list.length(dict.to_list(response.content))
            {
              config.Client, _ -> []
              _, n if n > 1 -> {
                let path = base_path <> ".content"
                [
                  diagnostic.capability(
                    severity: SeverityWarning,
                    target: TargetServer,
                    path: path,
                    detail: "Multiple response content types are not fully supported for server code generation. Generated server responses lose the content-type header.",
                    hint: Some(
                      "Use a single content type per response for full server code generation support.",
                    ),
                    loc: lookup_loc(ctx, index, path),
                  ),
                ]
              }
              _, _ -> []
            }
            let header_warnings = []
            let link_warnings = case dict.is_empty(response.links) {
              True -> []
              False -> {
                let path = base_path <> ".links"
                [
                  diagnostic.capability(
                    severity: SeverityWarning,
                    target: TargetBoth,
                    path: path,
                    detail: "Response links are parsed but not used by code generation.",
                    hint: Some(
                      "Response links will not appear in generated code. No action needed.",
                    ),
                    loc: lookup_loc(ctx, index, path),
                  ),
                ]
              }
            }
            let content_entries = dict.to_list(response.content)
            let encoding_warnings =
              list.flat_map(content_entries, fn(ce) {
                let #(media_type_name, media_type) = ce
                case dict.is_empty(media_type.encoding) {
                  True -> []
                  False -> {
                    let path =
                      base_path <> ".content." <> media_type_name <> ".encoding"
                    [
                      diagnostic.capability(
                        severity: SeverityWarning,
                        target: TargetBoth,
                        path: path,
                        detail: "MediaType encoding is parsed but not used by code generation.",
                        hint: Some(
                          "Encoding settings will not affect generated code. No action needed.",
                        ),
                        loc: lookup_loc(ctx, index, path),
                      ),
                    ]
                  }
                }
              })
            list.flatten([
              multi_content_warnings,
              header_warnings,
              link_warnings,
              encoding_warnings,
            ])
          }
          _ -> []
        }
      })
    })
  let request_body_encoding_warnings =
    list.flat_map(ops, fn(op) {
      let #(op_id, operation, _path, _method) = op
      case operation.request_body {
        Some(Value(rb)) -> {
          let base_path = op_id <> ".requestBody"
          let content_entries = dict.to_list(rb.content)
          list.flat_map(content_entries, fn(ce) {
            let #(media_type_name, media_type) = ce
            case dict.is_empty(media_type.encoding) {
              True -> []
              False -> {
                let path =
                  base_path <> ".content." <> media_type_name <> ".encoding"
                [
                  diagnostic.capability(
                    severity: SeverityWarning,
                    target: TargetBoth,
                    path: path,
                    detail: "Request-body encoding is parsed but not used by code generation.",
                    hint: Some(
                      "Encoding settings (contentType, style, explode) will not affect generated code. No action needed.",
                    ),
                    loc: lookup_loc(ctx, index, path),
                  ),
                ]
              }
            }
          })
        }
        _ -> []
      }
    })
  let external_docs_warnings = case context.spec(ctx).external_docs {
    Some(_) -> [
      diagnostic.capability(
        severity: SeverityWarning,
        target: TargetBoth,
        path: "externalDocs",
        detail: "External docs are parsed but not used by code generation.",
        hint: Some(
          "External docs will not appear in generated code. Include documentation in descriptions instead.",
        ),
        loc: location_index.lookup_with_ancestor(index, "externalDocs"),
      ),
    ]
    None -> []
  }
  let tag_warnings = case list.is_empty(context.spec(ctx).tags) {
    True -> []
    False -> [
      diagnostic.capability(
        severity: SeverityWarning,
        target: TargetBoth,
        path: "tags",
        detail: "Top-level tags are parsed but not used by code generation.",
        hint: Some("Tags will not appear in generated code. No action needed."),
        loc: location_index.lookup_with_ancestor(index, "tags"),
      ),
    ]
  }
  // Operation-level and path-level server overrides are now supported in client
  // code generation (server precedence: operation > path > top-level).
  let operation_server_warnings = []
  let path_server_warnings = []
  let component_warnings = case context.spec(ctx).components {
    Some(components) -> {
      let header_w = case dict.is_empty(components.headers) {
        True -> []
        False -> [
          diagnostic.capability(
            severity: SeverityWarning,
            target: TargetBoth,
            path: "components.headers",
            // Issue #306 wired response headers through to the
            // generated router, so component headers `$ref`'d from a
            // response.headers entry now reach the wire. Standalone
            // component header definitions that aren't referenced by
            // any response are still dropped on the floor.
            detail: "Component headers are wired into generated code only when referenced from a response.headers entry; standalone definitions are not surfaced.",
            hint: Some(
              "If a component header should reach a client, reference it from the relevant response.headers entry.",
            ),
            loc: location_index.lookup_with_ancestor(
              index,
              "components.headers",
            ),
          ),
        ]
      }
      let example_w = case dict.is_empty(components.examples) {
        True -> []
        False -> [
          diagnostic.capability(
            severity: SeverityWarning,
            target: TargetBoth,
            path: "components.examples",
            detail: "Component examples are parsed but not used by code generation.",
            hint: Some(
              "Component examples will not appear in generated code. Include examples in descriptions instead.",
            ),
            loc: location_index.lookup_with_ancestor(
              index,
              "components.examples",
            ),
          ),
        ]
      }
      let link_w = case dict.is_empty(components.links) {
        True -> []
        False -> [
          diagnostic.capability(
            severity: SeverityWarning,
            target: TargetBoth,
            path: "components.links",
            detail: "Component links are parsed but not used by code generation.",
            hint: Some(
              "Component links will not appear in generated code. No action needed.",
            ),
            loc: location_index.lookup_with_ancestor(index, "components.links"),
          ),
        ]
      }
      let callback_w = case dict.is_empty(components.callbacks) {
        True -> []
        False -> [
          diagnostic.capability(
            severity: SeverityWarning,
            target: TargetBoth,
            path: "components.callbacks",
            detail: "Component callbacks are parsed and preserved but not used by code generation.",
            hint: Some(
              "Callback endpoints will not appear in generated code. No action needed unless you expected handler stubs for them.",
            ),
            loc: location_index.lookup_with_ancestor(
              index,
              "components.callbacks",
            ),
          ),
        ]
      }
      list.flatten([header_w, example_w, link_w, callback_w])
    }
    None -> []
  }
  let operation_callback_warnings =
    list.filter_map(ops, fn(op) {
      let #(op_id, operation, _path, _method) = op
      case dict.is_empty(operation.callbacks) {
        True -> Error(Nil)
        False -> {
          let path = op_id <> ".callbacks"
          Ok(diagnostic.capability(
            severity: SeverityWarning,
            target: TargetBoth,
            path: path,
            detail: "Operation-level callbacks are parsed and preserved but not used by code generation.",
            hint: Some(
              "The callback endpoints listed here will not appear in generated server/client code. No action needed unless you expected handler stubs.",
            ),
            loc: lookup_loc(ctx, index, path),
          ))
        }
      }
    })
  list.flatten([
    webhook_warnings,
    response_warnings,
    request_body_encoding_warnings,
    external_docs_warnings,
    tag_warnings,
    operation_server_warnings,
    path_server_warnings,
    component_warnings,
    operation_callback_warnings,
  ])
}
