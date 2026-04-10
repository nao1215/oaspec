import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/string
import oaspec/codegen/context.{type Context}
import oaspec/config
import oaspec/openapi/diagnostic.{
  type Diagnostic, SeverityError, SeverityWarning, TargetBoth, TargetClient,
  TargetServer,
}
import oaspec/openapi/operations
import oaspec/openapi/resolver
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  BooleanSchema, Forbidden, Inline, IntegerSchema, NumberSchema, ObjectSchema,
  OneOfSchema, Reference, StringSchema, Typed, Untyped,
}
import oaspec/openapi/spec.{type SpecStage, Value}
import oaspec/util/content_type

/// Validate the parsed spec for unsupported patterns.
/// Returns a list of errors; empty list means validation passed.
/// Name collisions and duplicate operationIds are handled by the dedup pass
/// before validation, so they are no longer checked here.
pub fn validate(ctx: Context) -> List(Diagnostic) {
  let op_errors = validate_operations(ctx)
  let schema_errors = validate_component_schemas(ctx)
  let security_errors = validate_security_schemes(ctx)
  let preserved_warnings = validate_preserved_but_unused(ctx)
  list.flatten([op_errors, schema_errors, security_errors, preserved_warnings])
}

/// Filter to only errors (not warnings).
pub fn errors_only(issues: List(Diagnostic)) -> List(Diagnostic) {
  diagnostic.errors_only(issues)
}

/// Filter to only warnings (not errors).
pub fn warnings_only(issues: List(Diagnostic)) -> List(Diagnostic) {
  diagnostic.warnings_only(issues)
}

/// Filter validation issues to those relevant for the selected generation mode.
pub fn filter_by_mode(
  issues: List(Diagnostic),
  mode: config.GenerateMode,
) -> List(Diagnostic) {
  diagnostic.filter_by_mode(issues, mode)
}

/// Convert a validation error to a human-readable string.
pub fn error_to_string(error: Diagnostic) -> String {
  diagnostic.to_string(error)
}

/// Validate all operations for unsupported patterns.
fn validate_operations(ctx: Context) -> List(Diagnostic) {
  let operations = operations.collect_operations(ctx)
  list.flat_map(operations, fn(op) {
    let #(op_id, operation, path, _method) = op
    let resolved_params =
      list.filter_map(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) -> Ok(p)
          _ -> Error(Nil)
        }
      })
    let resolved_request_body = case operation.request_body {
      Some(Value(rb)) -> Some(rb)
      _ -> None
    }
    let resolved_responses =
      dict.to_list(operation.responses)
      |> list.filter_map(fn(entry) {
        let #(code, ref_or) = entry
        case ref_or {
          Value(resp) -> Ok(#(code, resp))
          _ -> Error(Nil)
        }
      })
      |> dict.from_list
    let path_errors =
      validate_path_template_params(op_id, path, resolved_params)
    let param_errors = validate_parameters(op_id, resolved_params, ctx)
    let body_errors = validate_request_body(op_id, resolved_request_body, ctx)
    let response_errors = validate_responses(op_id, resolved_responses, ctx)
    let missing_responses_errors = case dict.is_empty(resolved_responses) {
      True -> [
        diagnostic.validation(
          severity: SeverityError,
          target: TargetBoth,
          path: op_id,
          detail: "Operation has no responses defined. OpenAPI 3.x requires at least one response.",
        ),
      ]
      False -> []
    }
    list.flatten([
      path_errors,
      param_errors,
      body_errors,
      response_errors,
      missing_responses_errors,
    ])
  })
}

/// Validate that all {param} templates in the path have a corresponding
/// path parameter definition. Reports unbound templates that would produce
/// invalid generated code with literal {param} in URLs.
fn validate_path_template_params(
  op_id: String,
  path: String,
  params: List(spec.Parameter(SpecStage)),
) -> List(Diagnostic) {
  let template_names = extract_path_template_names(path)
  let path_param_names =
    list.filter_map(params, fn(p) {
      case p.in_ {
        spec.InPath -> Ok(p.name)
        _ -> Error(Nil)
      }
    })
  list.filter_map(template_names, fn(name) {
    case list.contains(path_param_names, name) {
      True -> Error(Nil)
      False ->
        Ok(diagnostic.validation(
          severity: SeverityError,
          target: TargetBoth,
          path: op_id <> ".path",
          detail: "Path template parameter '{"
            <> name
            <> "}' in '"
            <> path
            <> "' has no corresponding parameter definition.",
        ))
    }
  })
}

/// Extract parameter names from path template, e.g. "/items/{id}" -> ["id"].
fn extract_path_template_names(path: String) -> List(String) {
  let assert Ok(re) = regexp.from_string("\\{([^}]+)\\}")
  regexp.scan(re, path)
  |> list.filter_map(fn(match) {
    case match.submatches {
      [Some(name)] -> Ok(name)
      _ -> Error(Nil)
    }
  })
}

/// Validate parameters for unsupported serialization styles.
/// Supported: form (default), deepObject (query+object), exploded array.
/// Unsupported: matrix, label, simple, spaceDelimited, pipeDelimited.
fn validate_parameters(
  op_id: String,
  params: List(spec.Parameter(SpecStage)),
  ctx: Context,
) -> List(Diagnostic) {
  list.flat_map(params, fn(p) {
    let path = op_id <> ".parameters." <> p.name
    let style_errors = case p.style {
      Some(spec.MatrixStyle)
      | Some(spec.LabelStyle)
      | Some(spec.SpaceDelimitedStyle)
      | Some(spec.PipeDelimitedStyle) -> [
        diagnostic.validation(
          severity: SeverityError,
          target: TargetBoth,
          path: path,
          detail: "Parameter style is not supported. Supported styles: form, deepObject, simple.",
        ),
      ]
      _ -> []
    }
    // Parameter.payload is ParameterContent when Parameter.content is used instead of schema.
    // We don't support the content-based parameter serialization.
    let content_errors = case p.payload {
      spec.ParameterContent(_) -> [
        diagnostic.validation(
          severity: SeverityError,
          target: TargetBoth,
          path: path,
          detail: "Parameters using 'content' instead of 'schema' are not supported.",
        ),
      ]
      spec.ParameterSchema(_) -> []
    }
    // Object/complex schemas in query/header/cookie params require deepObject
    // style. Without it, codegen cannot stringify the value and falls through
    // to raw variable name, producing invalid generated code.
    let complex_schema_errors = validate_complex_param_schema(path, p, ctx)
    let server_structured_param_errors =
      validate_server_structured_param(path, p, ctx)
    let cookie_errors = validate_server_cookie_param(path, p, ctx)
    list.flatten([
      style_errors,
      content_errors,
      complex_schema_errors,
      server_structured_param_errors,
      cookie_errors,
    ])
  })
}

fn validate_server_structured_param(
  path: String,
  param: spec.Parameter(SpecStage),
  ctx: Context,
) -> List(Diagnostic) {
  case ctx.config.mode {
    config.Client -> []
    _ -> {
      let schema_obj = resolve_schema_object(spec.parameter_schema(param), ctx)
      let array_errors = case param.in_, schema_obj {
        spec.InQuery, Some(ArraySchema(items: Inline(StringSchema(..)), ..))
        | spec.InQuery, Some(ArraySchema(items: Inline(IntegerSchema(..)), ..))
        | spec.InQuery, Some(ArraySchema(items: Inline(NumberSchema(..)), ..))
        | spec.InQuery, Some(ArraySchema(items: Inline(BooleanSchema(..)), ..))
        -> []
        spec.InQuery, Some(ArraySchema(..)) -> [
          diagnostic.validation(
            severity: SeverityError,
            target: TargetServer,
            path: path,
            detail: "Query array parameters are only supported for inline primitive items in server code generation.",
          ),
        ]
        spec.InHeader, Some(ArraySchema(items: Inline(StringSchema(..)), ..))
        | spec.InHeader, Some(ArraySchema(items: Inline(IntegerSchema(..)), ..))
        | spec.InHeader, Some(ArraySchema(items: Inline(NumberSchema(..)), ..))
        | spec.InHeader, Some(ArraySchema(items: Inline(BooleanSchema(..)), ..))
        -> []
        spec.InHeader, Some(ArraySchema(..)) -> [
          diagnostic.validation(
            severity: SeverityError,
            target: TargetServer,
            path: path,
            detail: "Header array parameters are only supported for inline primitive items in server code generation.",
          ),
        ]
        _, _ -> []
      }
      let deep_object_errors =
        validate_server_deep_object_param(path, param, ctx)
      list.flatten([array_errors, deep_object_errors])
    }
  }
}

fn validate_server_deep_object_param(
  path: String,
  param: spec.Parameter(SpecStage),
  ctx: Context,
) -> List(Diagnostic) {
  case
    param.in_,
    param.style,
    resolve_schema_object(spec.parameter_schema(param), ctx)
  {
    spec.InQuery,
      Some(spec.DeepObjectStyle),
      Some(ObjectSchema(properties:, ..))
    ->
      dict.to_list(properties)
      |> list.flat_map(fn(entry) {
        let #(prop_name, prop_ref) = entry
        case deep_object_server_leaf_supported(prop_ref, ctx) {
          True -> []
          False -> [
            diagnostic.validation(
              severity: SeverityError,
              target: TargetServer,
              path: path <> "." <> prop_name,
              detail: "deepObject properties are only supported for inline primitive scalars and inline primitive array leaves in server code generation.",
            ),
          ]
        }
      })
    _, _, _ -> []
  }
}

fn deep_object_server_leaf_supported(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  case schema_ref {
    Inline(StringSchema(..))
    | Inline(IntegerSchema(..))
    | Inline(NumberSchema(..))
    | Inline(BooleanSchema(..))
    | Inline(ArraySchema(items: Inline(StringSchema(..)), ..))
    | Inline(ArraySchema(items: Inline(IntegerSchema(..)), ..))
    | Inline(ArraySchema(items: Inline(NumberSchema(..)), ..))
    | Inline(ArraySchema(items: Inline(BooleanSchema(..)), ..)) -> True
    Reference(..) ->
      case resolve_schema_object(Some(schema_ref), ctx) {
        Some(StringSchema(..))
        | Some(IntegerSchema(..))
        | Some(NumberSchema(..))
        | Some(BooleanSchema(..))
        | Some(ArraySchema(items: Inline(StringSchema(..)), ..))
        | Some(ArraySchema(items: Inline(IntegerSchema(..)), ..))
        | Some(ArraySchema(items: Inline(NumberSchema(..)), ..))
        | Some(ArraySchema(items: Inline(BooleanSchema(..)), ..)) -> True
        _ -> False
      }
    _ -> False
  }
}

fn validate_server_cookie_param(
  path: String,
  param: spec.Parameter(SpecStage),
  ctx: Context,
) -> List(Diagnostic) {
  let _ = path
  let _ = param
  let _ = ctx
  []
}

/// Check if a parameter has a complex schema (object, oneOf, allOf, anyOf)
/// that is not handled by deepObject style.
fn validate_complex_param_schema(
  path: String,
  param: spec.Parameter(SpecStage),
  ctx: Context,
) -> List(Diagnostic) {
  case param.style {
    Some(spec.DeepObjectStyle) ->
      // deepObject supports one level of object nesting only.
      // Reject nested object properties since codegen produces
      // invalid code (e.g., uri.percent_encode(filter.meta)).
      validate_deep_object_no_nested_objects(path, param, ctx)
    _ ->
      case resolve_schema_object(spec.parameter_schema(param), ctx) {
        Some(ObjectSchema(..))
        | Some(AllOfSchema(..))
        | Some(OneOfSchema(..))
        | Some(AnyOfSchema(..)) ->
          case param.in_ {
            spec.InPath ->
              case ctx.config.mode {
                config.Client -> []
                _ -> [
                  diagnostic.validation(
                    severity: SeverityError,
                    target: TargetServer,
                    path: path,
                    detail: "Complex path parameters are not supported for server code generation.",
                  ),
                ]
              }
            _ -> [
              diagnostic.validation(
                severity: SeverityError,
                target: TargetBoth,
                path: path,
                detail: "Complex schema (object/oneOf/allOf/anyOf) parameters require style: deepObject. Without it, the parameter cannot be serialized.",
              ),
            ]
          }
        _ -> []
      }
  }
}

/// Validate that a deepObject parameter has no nested object properties.
fn validate_deep_object_no_nested_objects(
  path: String,
  param: spec.Parameter(SpecStage),
  ctx: Context,
) -> List(Diagnostic) {
  case resolve_schema_object(spec.parameter_schema(param), ctx) {
    Some(ObjectSchema(properties:, ..)) ->
      dict.to_list(properties)
      |> list.flat_map(fn(entry) {
        let #(prop_name, prop_ref) = entry
        case resolve_schema_object(Some(prop_ref), ctx) {
          Some(ObjectSchema(..))
          | Some(AllOfSchema(..))
          | Some(OneOfSchema(..))
          | Some(AnyOfSchema(..)) -> [
            diagnostic.validation(
              severity: SeverityError,
              target: TargetBoth,
              path: path <> "." <> prop_name,
              detail: "Nested object properties in deepObject parameters are not supported. Only one level of object nesting is supported (e.g., filter[name]=value).",
            ),
          ]
          _ -> []
        }
      })
    _ -> []
  }
}

fn resolve_schema_object(
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> Option(SchemaObject) {
  case schema_ref {
    Some(Inline(schema_obj)) -> Some(schema_obj)
    Some(schema_ref) ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(schema_obj) -> Some(schema_obj)
        Error(_) -> None
      }
    None -> None
  }
}

/// Validate request body for unsupported patterns.
fn validate_request_body(
  op_id: String,
  request_body: Option(spec.RequestBody(SpecStage)),
  ctx: Context,
) -> List(Diagnostic) {
  case request_body {
    None -> []
    Some(rb) -> {
      let content_keys = dict.keys(rb.content)
      let unsupported =
        list.filter(content_keys, fn(key) {
          !content_type.is_supported_request(content_type.from_string(key))
        })
      let content_type_errors = case unsupported {
        [] -> []
        [media_type, ..] -> [
          diagnostic.validation(
            severity: SeverityError,
            target: TargetBoth,
            path: op_id <> ".requestBody",
            detail: "Content type '"
              <> media_type
              <> "' is not supported. Supported request content types: application/json, multipart/form-data, application/x-www-form-urlencoded.",
          ),
        ]
      }
      // Recurse into request body schemas
      let schema_errors =
        dict.to_list(rb.content)
        |> list.flat_map(fn(entry) {
          let #(_media_type, media_type) = entry
          case media_type.schema {
            Some(schema_ref) ->
              validate_schema_ref_recursive(
                op_id <> ".requestBody",
                schema_ref,
                ctx,
              )
            None -> []
          }
        })
      let multipart_field_errors =
        validate_multipart_request_body_fields(op_id, rb.content, ctx)
      let form_urlencoded_errors =
        validate_form_urlencoded_schema(op_id, rb.content, ctx)
      let server_form_urlencoded_errors =
        validate_server_form_urlencoded_request_body(
          op_id,
          rb.content,
          content_keys,
          ctx,
        )
      let server_multipart_errors =
        validate_server_multipart_request_body(
          op_id,
          rb.content,
          content_keys,
          ctx,
        )
      // Server router has explicit typed support for application/json,
      // application/x-www-form-urlencoded, and multipart/form-data. Other
      // supported content types still fall back to raw String and must be
      // rejected here.
      let server_body_errors =
        validate_server_request_body_content_types(op_id, content_keys, ctx)
      list.flatten([
        content_type_errors,
        schema_errors,
        multipart_field_errors,
        form_urlencoded_errors,
        server_form_urlencoded_errors,
        server_multipart_errors,
        server_body_errors,
      ])
    }
  }
}

fn validate_multipart_request_body_fields(
  op_id: String,
  content: dict.Dict(String, spec.MediaType),
  ctx: Context,
) -> List(Diagnostic) {
  case dict.get(content, "multipart/form-data") {
    Ok(media_type) ->
      case resolve_schema_object(media_type.schema, ctx) {
        Some(ObjectSchema(properties:, ..)) ->
          dict.to_list(properties)
          |> list.flat_map(fn(entry) {
            let #(field_name, field_schema) = entry
            case multipart_field_is_stringifiable(field_schema, ctx) {
              True -> []
              False -> [
                diagnostic.validation(
                  severity: SeverityError,
                  target: TargetBoth,
                  path: op_id <> ".requestBody.multipart." <> field_name,
                  detail: "multipart/form-data fields must be string, integer, number, boolean, binary, or string enums.",
                ),
              ]
            }
          })
        Some(_) -> [
          diagnostic.validation(
            severity: SeverityError,
            target: TargetBoth,
            path: op_id <> ".requestBody",
            detail: "multipart/form-data request bodies must use an object schema.",
          ),
        ]
        None -> []
      }
    Error(_) -> []
  }
}

/// Validate that application/x-www-form-urlencoded uses an object schema.
/// Non-object schemas produce empty form bodies in the generated code.
fn validate_form_urlencoded_schema(
  op_id: String,
  content: dict.Dict(String, spec.MediaType),
  ctx: Context,
) -> List(Diagnostic) {
  case dict.get(content, "application/x-www-form-urlencoded") {
    Ok(media_type) ->
      case resolve_schema_object(media_type.schema, ctx) {
        Some(ObjectSchema(..)) -> []
        Some(_) -> [
          diagnostic.validation(
            severity: SeverityError,
            target: TargetBoth,
            path: op_id <> ".requestBody",
            detail: "application/x-www-form-urlencoded request bodies must use an object schema.",
          ),
        ]
        None -> []
      }
    Error(_) -> []
  }
}

/// Validate that request body content types are supported for server codegen.
/// Server router only handles application/json with typed decode; other types
/// that pass the general is_supported_request check (multipart/form-data,
/// application/x-www-form-urlencoded) are passed as raw String which breaks
/// the typed body contract.
fn validate_server_form_urlencoded_request_body(
  op_id: String,
  content: dict.Dict(String, spec.MediaType),
  content_keys: List(String),
  ctx: Context,
) -> List(Diagnostic) {
  case ctx.config.mode {
    config.Client -> []
    _ ->
      case dict.get(content, "application/x-www-form-urlencoded") {
        Ok(media_type) -> {
          let content_type_errors = case list.length(content_keys) > 1 {
            True -> [
              diagnostic.validation(
                severity: SeverityError,
                target: TargetServer,
                path: op_id <> ".requestBody",
                detail: "application/x-www-form-urlencoded request bodies are only supported as the sole request content type for server code generation.",
              ),
            ]
            False -> []
          }
          let field_errors = case
            resolve_schema_object(media_type.schema, ctx)
          {
            Some(ObjectSchema(properties:, ..)) ->
              dict.to_list(properties)
              |> list.flat_map(fn(entry) {
                let #(field_name, field_schema) = entry
                case
                  form_urlencoded_server_field_supported(field_schema, ctx, 0)
                {
                  True -> []
                  False -> [
                    diagnostic.validation(
                      severity: SeverityError,
                      target: TargetServer,
                      path: op_id <> ".requestBody.form." <> field_name,
                      detail: "application/x-www-form-urlencoded server request bodies only support primitive scalars, primitive arrays, and nested objects with primitive leaves (max 5 levels).",
                    ),
                  ]
                }
              })
            _ -> []
          }
          list.append(content_type_errors, field_errors)
        }
        Error(_) -> []
      }
  }
}

fn validate_server_request_body_content_types(
  op_id: String,
  content_keys: List(String),
  ctx: Context,
) -> List(Diagnostic) {
  case ctx.config.mode {
    config.Client -> []
    _ -> {
      let non_json_but_supported =
        list.filter(content_keys, fn(key) {
          key != "application/json"
          && key != "application/x-www-form-urlencoded"
          && key != "multipart/form-data"
          && content_type.is_supported_request(content_type.from_string(key))
        })
      list.map(non_json_but_supported, fn(media_type) {
        diagnostic.validation(
          severity: SeverityError,
          target: TargetServer,
          path: op_id <> ".requestBody",
          detail: "Content type '"
            <> media_type
            <> "' is not supported for server code generation. Server router only supports application/json request bodies with typed decoding.",
        )
      })
    }
  }
}

fn validate_server_multipart_request_body(
  op_id: String,
  content: dict.Dict(String, spec.MediaType),
  content_keys: List(String),
  ctx: Context,
) -> List(Diagnostic) {
  case ctx.config.mode {
    config.Client -> []
    _ ->
      case dict.get(content, "multipart/form-data") {
        Ok(media_type) -> {
          let content_type_errors = case list.length(content_keys) > 1 {
            True -> [
              diagnostic.validation(
                severity: SeverityError,
                target: TargetServer,
                path: op_id <> ".requestBody",
                detail: "multipart/form-data request bodies are only supported as the sole request content type for server code generation.",
              ),
            ]
            False -> []
          }
          let field_errors = case
            resolve_schema_object(media_type.schema, ctx)
          {
            Some(ObjectSchema(properties:, ..)) ->
              dict.to_list(properties)
              |> list.flat_map(fn(entry) {
                let #(field_name, field_schema) = entry
                case multipart_server_field_supported(field_schema, ctx) {
                  True -> []
                  False -> [
                    diagnostic.validation(
                      severity: SeverityError,
                      target: TargetServer,
                      path: op_id <> ".requestBody.multipart." <> field_name,
                      detail: "multipart/form-data server request bodies only support primitive scalar fields.",
                    ),
                  ]
                }
              })
            _ -> []
          }
          list.append(content_type_errors, field_errors)
        }
        Error(_) -> []
      }
  }
}

fn form_urlencoded_server_field_supported(
  schema_ref: SchemaRef,
  ctx: Context,
  depth: Int,
) -> Bool {
  case resolve_schema_object(Some(schema_ref), ctx) {
    Some(StringSchema(..))
    | Some(IntegerSchema(..))
    | Some(NumberSchema(..))
    | Some(BooleanSchema(..)) -> True
    Some(ArraySchema(items:, ..)) ->
      form_urlencoded_server_array_item_supported(items, ctx)
    Some(ObjectSchema(properties:, ..)) if depth < 5 ->
      dict.to_list(properties)
      |> list.all(fn(entry) {
        let #(_, child_schema) = entry
        form_urlencoded_server_field_supported(child_schema, ctx, depth + 1)
      })
    _ -> False
  }
}

fn form_urlencoded_server_array_item_supported(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  case resolve_schema_object(Some(schema_ref), ctx) {
    Some(StringSchema(..))
    | Some(IntegerSchema(..))
    | Some(NumberSchema(..))
    | Some(BooleanSchema(..)) -> True
    _ -> False
  }
}

fn multipart_server_field_supported(schema_ref: SchemaRef, ctx: Context) -> Bool {
  case resolve_schema_object(Some(schema_ref), ctx) {
    Some(StringSchema(..))
    | Some(IntegerSchema(..))
    | Some(NumberSchema(..))
    | Some(BooleanSchema(..)) -> True
    Some(ArraySchema(items:, ..)) ->
      multipart_server_array_item_supported(items, ctx)
    _ -> False
  }
}

fn multipart_server_array_item_supported(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  case resolve_schema_object(Some(schema_ref), ctx) {
    Some(StringSchema(..))
    | Some(IntegerSchema(..))
    | Some(NumberSchema(..))
    | Some(BooleanSchema(..)) -> True
    _ -> False
  }
}

fn multipart_field_is_stringifiable(schema_ref: SchemaRef, ctx: Context) -> Bool {
  case resolve_schema_object(Some(schema_ref), ctx) {
    Some(StringSchema(..))
    | Some(IntegerSchema(..))
    | Some(NumberSchema(..))
    | Some(BooleanSchema(..)) -> True
    _ -> False
  }
}

/// Validate response schemas and content types.
fn validate_responses(
  op_id: String,
  responses: dict.Dict(String, spec.Response(SpecStage)),
  ctx: Context,
) -> List(Diagnostic) {
  let entries = dict.to_list(responses)
  list.flat_map(entries, fn(entry) {
    let #(status_code, response) = entry
    let content_entries = dict.to_list(response.content)
    list.flat_map(content_entries, fn(ce) {
      let #(media_type_name, media_type) = ce
      let path = op_id <> ".responses." <> status_code
      let content_type_errors = case
        content_type.is_supported_response(content_type.from_string(
          media_type_name,
        ))
      {
        True -> []
        False -> [
          diagnostic.validation(
            severity: SeverityError,
            target: TargetBoth,
            path: path,
            detail: "Response content type '"
              <> media_type_name
              <> "' is not supported. Supported response content types: application/json, text/plain, application/octet-stream, application/xml, text/xml.",
          ),
        ]
      }
      let schema_errors = case media_type.schema {
        Some(schema_ref) -> validate_schema_ref_recursive(path, schema_ref, ctx)
        None -> []
      }
      list.append(content_type_errors, schema_errors)
    })
  })
}

/// Validate component schemas recursively.
fn validate_component_schemas(ctx: Context) -> List(Diagnostic) {
  let schemas = case ctx.spec.components {
    Some(components) -> dict.to_list(components.schemas)
    None -> []
  }
  list.flat_map(schemas, fn(entry) {
    let #(name, schema_ref) = entry
    validate_schema_ref_recursive(
      "components.schemas." <> name,
      schema_ref,
      ctx,
    )
  })
}

/// Recursively validate a SchemaRef at any depth.
/// References are checked for resolvability against the spec's components.
fn validate_schema_ref_recursive(
  path: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> List(Diagnostic) {
  case schema_ref {
    Reference(ref:, ..) ->
      // Detect external refs (not starting with #/) before resolution
      case string.starts_with(ref, "#/") {
        False -> [
          diagnostic.validation(
            severity: SeverityError,
            target: TargetBoth,
            path: path,
            detail: "External $ref '"
              <> ref
              <> "' is not supported. Only local references (#/components/...) are supported.",
          ),
        ]
        True ->
          case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
            Ok(_) -> []
            Error(_) -> [
              diagnostic.validation(
                severity: SeverityError,
                target: TargetBoth,
                path: path,
                detail: "Unresolved schema reference: '"
                  <> ref
                  <> "'. The referenced schema does not exist in components.",
              ),
            ]
          }
      }
    Inline(schema_obj) -> validate_schema_recursive(path, schema_obj, ctx)
  }
}

/// Recursively validate a SchemaObject, descending into all sub-schemas.
fn validate_schema_recursive(
  path: String,
  schema_obj: SchemaObject,
  ctx: Context,
) -> List(Diagnostic) {
  case schema_obj {
    ObjectSchema(properties:, additional_properties:, ..) -> {
      // additionalProperties: true is supported via Dict(String, Dynamic)
      let ap_errors = []
      // Recurse into typed additionalProperties schema
      let typed_ap_errors = case additional_properties {
        Typed(ap_ref) ->
          validate_schema_ref_recursive(
            path <> ".additionalProperties",
            ap_ref,
            ctx,
          )
        Forbidden | Untyped -> []
      }
      // Recurse into properties
      let prop_errors =
        dict.to_list(properties)
        |> list.flat_map(fn(entry) {
          let #(prop_name, prop_ref) = entry
          let prop_path = path <> "." <> prop_name
          validate_schema_ref_recursive(prop_path, prop_ref, ctx)
        })
      list.flatten([
        ap_errors,
        typed_ap_errors,
        prop_errors,
      ])
    }

    ArraySchema(items:, ..) -> {
      validate_schema_ref_recursive(path <> ".items", items, ctx)
    }

    OneOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s_ref) {
        validate_schema_ref_recursive(path <> ".oneOf", s_ref, ctx)
      })
    AnyOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s_ref) {
        validate_schema_ref_recursive(path <> ".anyOf", s_ref, ctx)
      })

    AllOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s_ref) {
        validate_schema_ref_recursive(path <> ".allOf", s_ref, ctx)
      })

    _ -> []
  }
}

/// Validate that all security scheme references in global and operation-level
/// security requirements point to schemes defined in components.securitySchemes.
fn validate_security_schemes(ctx: Context) -> List(Diagnostic) {
  let scheme_names = case ctx.spec.components {
    Some(components) -> dict.keys(components.security_schemes)
    None -> []
  }

  let global_errors =
    list.flat_map(ctx.spec.security, fn(req) {
      list.filter_map(req.schemes, fn(scheme_ref) {
        case list.contains(scheme_names, scheme_ref.scheme_name) {
          True -> Error(Nil)
          False ->
            Ok(diagnostic.validation(
              severity: SeverityError,
              target: TargetBoth,
              path: "security." <> scheme_ref.scheme_name,
              detail: "Security requirement references scheme '"
                <> scheme_ref.scheme_name
                <> "' which is not defined in components.securitySchemes.",
            ))
        }
      })
    })

  let operations = operations.collect_operations(ctx)
  let operation_errors =
    list.flat_map(operations, fn(op) {
      let #(op_id, operation, _path, _method) = op
      case operation.security {
        Some(reqs) ->
          list.flat_map(reqs, fn(req) {
            list.filter_map(req.schemes, fn(scheme_ref) {
              case list.contains(scheme_names, scheme_ref.scheme_name) {
                True -> Error(Nil)
                False ->
                  Ok(diagnostic.validation(
                    severity: SeverityError,
                    target: TargetBoth,
                    path: op_id <> ".security." <> scheme_ref.scheme_name,
                    detail: "Security requirement references scheme '"
                      <> scheme_ref.scheme_name
                      <> "' which is not defined in components.securitySchemes.",
                  ))
              }
            })
          })
        None -> []
      }
    })

  list.append(global_errors, operation_errors)
}

/// Check for AST fields that are parsed but not used by codegen, emitting
/// warnings so users are aware their spec contains features we preserve but
/// do not generate code for.
fn validate_preserved_but_unused(ctx: Context) -> List(Diagnostic) {
  let webhook_warnings = case dict.is_empty(ctx.spec.webhooks) {
    True -> []
    False -> [
      diagnostic.validation(
        severity: SeverityWarning,
        target: TargetBoth,
        path: "webhooks",
        detail: "Webhooks are parsed but not used by code generation.",
      ),
    ]
  }
  let operations = operations.collect_operations(ctx)
  let response_warnings =
    list.flat_map(operations, fn(op) {
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
                diagnostic.validation(
                  severity: SeverityWarning,
                  target: TargetServer,
                  path: base_path <> ".content",
                  detail: "Multiple response content types are not fully supported for server code generation. Generated server responses lose the content-type header.",
                ),
              ]
              _, _ -> []
            }
            let header_warnings = case dict.is_empty(response.headers) {
              True -> []
              False -> [
                diagnostic.validation(
                  severity: SeverityWarning,
                  target: TargetBoth,
                  path: base_path <> ".headers",
                  detail: "Response headers are parsed but not used by code generation.",
                ),
              ]
            }
            let link_warnings = case dict.is_empty(response.links) {
              True -> []
              False -> [
                diagnostic.validation(
                  severity: SeverityWarning,
                  target: TargetBoth,
                  path: base_path <> ".links",
                  detail: "Response links are parsed but not used by code generation.",
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
                    diagnostic.validation(
                      severity: SeverityWarning,
                      target: TargetBoth,
                      path: base_path <> "." <> media_type_name <> ".encoding",
                      detail: "MediaType encoding is parsed but not used by code generation.",
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
  // Warn about external docs
  let external_docs_warnings = case ctx.spec.external_docs {
    Some(_) -> [
      diagnostic.validation(
        severity: SeverityWarning,
        target: TargetBoth,
        path: "externalDocs",
        detail: "External docs are parsed but not used by code generation.",
      ),
    ]
    None -> []
  }

  // Warn about top-level tags
  let tag_warnings = case list.is_empty(ctx.spec.tags) {
    True -> []
    False -> [
      diagnostic.validation(
        severity: SeverityWarning,
        target: TargetBoth,
        path: "tags",
        detail: "Top-level tags are parsed but not used by code generation.",
      ),
    ]
  }

  // Warn about operation-level servers (client only uses top-level servers)
  let operation_server_warnings =
    list.flat_map(operations, fn(op) {
      let #(op_id, operation, _path, _method) = op
      case list.is_empty(operation.servers) {
        True -> []
        False -> [
          diagnostic.validation(
            severity: SeverityWarning,
            target: TargetClient,
            path: op_id <> ".servers",
            detail: "Operation-level servers are parsed but client code generation uses only the top-level server URL.",
          ),
        ]
      }
    })

  // Warn about path-level servers
  let path_server_warnings =
    dict.to_list(ctx.spec.paths)
    |> list.flat_map(fn(entry) {
      let #(path, ref_or) = entry
      case ref_or {
        Value(path_item) ->
          case list.is_empty(path_item.servers) {
            True -> []
            False -> [
              diagnostic.validation(
                severity: SeverityWarning,
                target: TargetClient,
                path: "paths." <> path <> ".servers",
                detail: "Path-level servers are parsed but client code generation uses only the top-level server URL.",
              ),
            ]
          }
        _ -> []
      }
    })

  // Warn about component-level headers, examples, and links
  let component_warnings = case ctx.spec.components {
    Some(components) -> {
      let header_w = case dict.is_empty(components.headers) {
        True -> []
        False -> [
          diagnostic.validation(
            severity: SeverityWarning,
            target: TargetBoth,
            path: "components.headers",
            detail: "Component headers are parsed but not used by code generation.",
          ),
        ]
      }
      let example_w = case dict.is_empty(components.examples) {
        True -> []
        False -> [
          diagnostic.validation(
            severity: SeverityWarning,
            target: TargetBoth,
            path: "components.examples",
            detail: "Component examples are parsed but not used by code generation.",
          ),
        ]
      }
      let link_w = case dict.is_empty(components.links) {
        True -> []
        False -> [
          diagnostic.validation(
            severity: SeverityWarning,
            target: TargetBoth,
            path: "components.links",
            detail: "Component links are parsed but not used by code generation.",
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
