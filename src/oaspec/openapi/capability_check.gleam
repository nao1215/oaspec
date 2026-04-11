import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import oaspec/capability
import oaspec/codegen/context.{type Context}
import oaspec/config
import oaspec/openapi/diagnostic.{
  type Diagnostic, SeverityError, SeverityWarning, TargetBoth, TargetClient,
  TargetServer,
}
import oaspec/openapi/operations
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  Inline, ObjectSchema, OneOfSchema, Reference, Typed,
}
import oaspec/openapi/spec.{type OpenApiSpec, type Resolved, Value}

/// Run capability checks on a resolved spec.
/// Returns errors for unsupported features and warnings for parsed-but-unused features.
pub fn check(spec: OpenApiSpec(Resolved)) -> List(Diagnostic) {
  let schema_errors = check_schemas(spec)
  let security_errors = check_security_schemes(spec)
  list.flatten([schema_errors, security_errors])
}

/// Check all schemas for unsupported keywords stored during lossless parse.
/// Covers both component schemas and inline schemas in operations.
fn check_schemas(spec: OpenApiSpec(Resolved)) -> List(Diagnostic) {
  let component_errors = case spec.components {
    None -> []
    Some(components) ->
      dict.to_list(components.schemas)
      |> list.flat_map(fn(entry) {
        let #(name, schema_ref) = entry
        check_schema_ref("components.schemas." <> name, schema_ref)
      })
  }
  let inline_errors = check_inline_schemas(spec)
  list.append(component_errors, inline_errors)
}

/// Check inline schemas within operations (request bodies, responses, parameters).
fn check_inline_schemas(spec: OpenApiSpec(Resolved)) -> List(Diagnostic) {
  dict.to_list(spec.paths)
  |> list.flat_map(fn(path_entry) {
    let #(path, ref_or) = path_entry
    case ref_or {
      Value(path_item) -> check_path_item_schemas("paths." <> path, path_item)
      _ -> []
    }
  })
}

fn check_path_item_schemas(
  base_path: String,
  pi: spec.PathItem(Resolved),
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
      Some(op) -> check_operation_schemas(base_path <> "." <> method, op)
      None -> []
    }
  })
}

fn check_operation_schemas(
  base_path: String,
  op: spec.Operation(Resolved),
) -> List(Diagnostic) {
  // Check request body schemas
  let rb_errors = case op.request_body {
    Some(Value(rb)) ->
      dict.to_list(rb.content)
      |> list.flat_map(fn(entry) {
        let #(ct, mt) = entry
        case mt.schema {
          Some(sr) -> check_schema_ref(base_path <> ".requestBody." <> ct, sr)
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
                  base_path <> ".responses." <> code <> "." <> ct,
                  sr,
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
fn check_schema_ref(path: String, ref: SchemaRef) -> List(Diagnostic) {
  case ref {
    Reference(..) -> []
    Inline(schema_obj) -> check_schema(path, schema_obj)
  }
}

/// Check a single schema and recurse into children.
fn check_schema(path: String, schema_obj: SchemaObject) -> List(Diagnostic) {
  let metadata = schema.get_metadata(schema_obj)

  // Check unsupported keywords stored by lossless parser
  let keyword_errors = case metadata.unsupported_keywords {
    [] -> []
    keywords -> {
      let keyword_list = string.join(keywords, "', '")
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
        ),
      ]
    }
  }

  // Recurse into children
  let child_errors = case schema_obj {
    ObjectSchema(properties:, additional_properties:, ..) -> {
      let prop_errors =
        dict.to_list(properties)
        |> list.flat_map(fn(e) { check_schema_ref(path <> "." <> e.0, e.1) })
      let ap_errors = case additional_properties {
        Typed(ap) -> check_schema_ref(path <> ".additionalProperties", ap)
        _ -> []
      }
      list.append(prop_errors, ap_errors)
    }
    ArraySchema(items:, ..) -> check_schema_ref(path <> ".items", items)
    AllOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s) { check_schema_ref(path <> ".allOf", s) })
    OneOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s) { check_schema_ref(path <> ".oneOf", s) })
    AnyOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s) { check_schema_ref(path <> ".anyOf", s) })
    _ -> []
  }

  list.append(keyword_errors, child_errors)
}

/// Check security schemes for unsupported types (e.g. mutualTLS).
fn check_security_schemes(spec: OpenApiSpec(Resolved)) -> List(Diagnostic) {
  case spec.components {
    None -> []
    Some(components) ->
      dict.to_list(components.security_schemes)
      |> list.filter_map(fn(entry) {
        let #(name, ref_or) = entry
        case ref_or {
          Value(spec.UnsupportedScheme(scheme_type:)) ->
            Ok(diagnostic.capability(
              severity: SeverityError,
              target: TargetBoth,
              path: "components.securitySchemes." <> name,
              detail: "Unsupported security scheme type: '"
                <> scheme_type
                <> "'. Supported types: apiKey, http, oauth2, openIdConnect.",
              hint: Some(
                "Use apiKey, http (bearer), oauth2, or openIdConnect instead.",
              ),
            ))
          _ -> Error(Nil)
        }
      })
  }
}

/// Check for parsed-but-unused AST features, emitting warnings.
/// This is the single source of truth for "parsed but not generated" diagnostics.
/// Requires Context because some checks iterate over resolved operations.
pub fn check_preserved(ctx: Context) -> List(Diagnostic) {
  let webhook_warnings = case dict.is_empty(ctx.spec.webhooks) {
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
      ),
    ]
  }
  let ops = operations.collect_operations(ctx)
  let response_warnings =
    list.flat_map(ops, fn(op) {
      let #(op_id, operation, _path, _method) = op
      let entries = dict.to_list(operation.responses)
      list.flat_map(entries, fn(entry) {
        let #(status_code, ref_or) = entry
        case ref_or {
          Value(response) -> {
            let base_path = op_id <> ".responses." <> status_code
            let multi_content_warnings = case
              ctx.config.mode,
              list.length(dict.to_list(response.content))
            {
              config.Client, _ -> []
              _, n if n > 1 -> [
                diagnostic.capability(
                  severity: SeverityWarning,
                  target: TargetServer,
                  path: base_path <> ".content",
                  detail: "Multiple response content types are not fully supported for server code generation. Generated server responses lose the content-type header.",
                  hint: Some(
                    "Use a single content type per response for full server code generation support.",
                  ),
                ),
              ]
              _, _ -> []
            }
            let header_warnings = case dict.is_empty(response.headers) {
              True -> []
              False -> [
                diagnostic.capability(
                  severity: SeverityWarning,
                  target: TargetBoth,
                  path: base_path <> ".headers",
                  detail: "Response headers are parsed but not used by code generation.",
                  hint: Some(
                    "Response headers will not appear in generated code. No action needed.",
                  ),
                ),
              ]
            }
            let link_warnings = case dict.is_empty(response.links) {
              True -> []
              False -> [
                diagnostic.capability(
                  severity: SeverityWarning,
                  target: TargetBoth,
                  path: base_path <> ".links",
                  detail: "Response links are parsed but not used by code generation.",
                  hint: Some(
                    "Response links will not appear in generated code. No action needed.",
                  ),
                ),
              ]
            }
            let content_entries = dict.to_list(response.content)
            let encoding_warnings =
              list.flat_map(content_entries, fn(ce) {
                let #(media_type_name, media_type) = ce
                case dict.is_empty(media_type.encoding) {
                  True -> []
                  False -> [
                    diagnostic.capability(
                      severity: SeverityWarning,
                      target: TargetBoth,
                      path: base_path <> "." <> media_type_name <> ".encoding",
                      detail: "MediaType encoding is parsed but not used by code generation.",
                      hint: Some(
                        "Encoding settings will not affect generated code. No action needed.",
                      ),
                    ),
                  ]
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
  let external_docs_warnings = case ctx.spec.external_docs {
    Some(_) -> [
      diagnostic.capability(
        severity: SeverityWarning,
        target: TargetBoth,
        path: "externalDocs",
        detail: "External docs are parsed but not used by code generation.",
        hint: Some(
          "External docs will not appear in generated code. Include documentation in descriptions instead.",
        ),
      ),
    ]
    None -> []
  }
  let tag_warnings = case list.is_empty(ctx.spec.tags) {
    True -> []
    False -> [
      diagnostic.capability(
        severity: SeverityWarning,
        target: TargetBoth,
        path: "tags",
        detail: "Top-level tags are parsed but not used by code generation.",
        hint: Some("Tags will not appear in generated code. No action needed."),
      ),
    ]
  }
  let operation_server_warnings =
    list.flat_map(ops, fn(op) {
      let #(op_id, operation, _path, _method) = op
      case list.is_empty(operation.servers) {
        True -> []
        False -> [
          diagnostic.capability(
            severity: SeverityWarning,
            target: TargetClient,
            path: op_id <> ".servers",
            detail: "Operation-level servers are parsed but client code generation uses only the top-level server URL.",
            hint: Some(
              "Only the first top-level server URL is used for default_base_url(). Override at runtime via ClientConfig if needed.",
            ),
          ),
        ]
      }
    })
  let path_server_warnings =
    dict.to_list(ctx.spec.paths)
    |> list.flat_map(fn(entry) {
      let #(path, ref_or) = entry
      case ref_or {
        Value(path_item) ->
          case list.is_empty(path_item.servers) {
            True -> []
            False -> [
              diagnostic.capability(
                severity: SeverityWarning,
                target: TargetClient,
                path: "paths." <> path <> ".servers",
                detail: "Path-level servers are parsed but client code generation uses only the top-level server URL.",
                hint: Some(
                  "Only the first top-level server URL is used for default_base_url(). Override at runtime via ClientConfig if needed.",
                ),
              ),
            ]
          }
        _ -> []
      }
    })
  let component_warnings = case ctx.spec.components {
    Some(components) -> {
      let header_w = case dict.is_empty(components.headers) {
        True -> []
        False -> [
          diagnostic.capability(
            severity: SeverityWarning,
            target: TargetBoth,
            path: "components.headers",
            detail: "Component headers are parsed but not used by code generation.",
            hint: Some(
              "Component headers will not appear in generated code. No action needed.",
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
          ),
        ]
      }
      list.flatten([header_w, example_w, link_w])
    }
    None -> []
  }
  list.flatten([
    webhook_warnings,
    response_warnings,
    external_docs_warnings,
    tag_warnings,
    operation_server_warnings,
    path_server_warnings,
    component_warnings,
  ])
}
