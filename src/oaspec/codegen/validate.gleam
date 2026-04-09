import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/string
import oaspec/codegen/context.{type Context}
import oaspec/codegen/types as type_gen
import oaspec/openapi/resolver
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  BooleanSchema, Inline, IntegerSchema, NumberSchema, ObjectSchema, OneOfSchema,
  Reference, StringSchema,
}
import oaspec/openapi/spec
import oaspec/util/content_type

/// Severity level for validation issues.
pub type Severity {
  SeverityError
  SeverityWarning
}

/// Target indicating which generation mode the issue applies to.
pub type Target {
  TargetBoth
  TargetClient
  TargetServer
}

/// A validation issue representing an unsupported or noteworthy OpenAPI feature.
pub type ValidationError {
  ValidationError(
    path: String,
    detail: String,
    severity: Severity,
    target: Target,
  )
}

/// Validate the parsed spec for unsupported patterns.
/// Returns a list of errors; empty list means validation passed.
/// Name collisions and duplicate operationIds are handled by the dedup pass
/// before validation, so they are no longer checked here.
pub fn validate(ctx: Context) -> List(ValidationError) {
  let op_errors = validate_operations(ctx)
  let schema_errors = validate_component_schemas(ctx)
  let security_errors = validate_security_schemes(ctx)
  let preserved_warnings = validate_preserved_but_unused(ctx)
  list.flatten([op_errors, schema_errors, security_errors, preserved_warnings])
}

/// Filter to only errors (not warnings).
pub fn errors_only(issues: List(ValidationError)) -> List(ValidationError) {
  list.filter(issues, fn(e) { e.severity == SeverityError })
}

/// Filter to only warnings (not errors).
pub fn warnings_only(issues: List(ValidationError)) -> List(ValidationError) {
  list.filter(issues, fn(e) { e.severity == SeverityWarning })
}

/// Convert a validation error to a human-readable string.
pub fn error_to_string(error: ValidationError) -> String {
  let prefix = case error.severity {
    SeverityError -> "Error"
    SeverityWarning -> "Warning"
  }
  prefix <> " at " <> error.path <> ": " <> error.detail
}

/// Validate all operations for unsupported patterns.
fn validate_operations(ctx: Context) -> List(ValidationError) {
  let operations = type_gen.collect_operations(ctx)
  list.flat_map(operations, fn(op) {
    let #(op_id, operation, path, _method) = op
    let path_errors =
      validate_path_template_params(op_id, path, operation.parameters)
    let param_errors = validate_parameters(op_id, operation.parameters, ctx)
    let body_errors = validate_request_body(op_id, operation.request_body, ctx)
    let response_errors = validate_responses(op_id, operation.responses, ctx)
    list.flatten([path_errors, param_errors, body_errors, response_errors])
  })
}

/// Validate that all {param} templates in the path have a corresponding
/// path parameter definition. Reports unbound templates that would produce
/// invalid generated code with literal {param} in URLs.
fn validate_path_template_params(
  op_id: String,
  path: String,
  params: List(spec.Parameter),
) -> List(ValidationError) {
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
        Ok(ValidationError(
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
  params: List(spec.Parameter),
  ctx: Context,
) -> List(ValidationError) {
  list.flat_map(params, fn(p) {
    let path = op_id <> ".parameters." <> p.name
    let style_errors = case p.style {
      Some(spec.MatrixStyle)
      | Some(spec.LabelStyle)
      | Some(spec.SpaceDelimitedStyle)
      | Some(spec.PipeDelimitedStyle) -> [
        ValidationError(
          severity: SeverityError,
          target: TargetBoth,
          path: path,
          detail: "Parameter style is not supported. Supported styles: form, deepObject, simple.",
        ),
      ]
      _ -> []
    }
    // Parameter.schema is None when Parameter.content is used instead.
    // We don't support the content-based parameter serialization.
    let content_errors = case p.schema {
      None -> [
        ValidationError(
          severity: SeverityError,
          target: TargetBoth,
          path: path,
          detail: "Parameters using 'content' instead of 'schema' are not supported.",
        ),
      ]
      _ -> []
    }
    // Object/complex schemas in query/header/cookie params require deepObject
    // style. Without it, codegen cannot stringify the value and falls through
    // to raw variable name, producing invalid generated code.
    let complex_schema_errors = validate_complex_param_schema(path, p, ctx)
    list.flatten([style_errors, content_errors, complex_schema_errors])
  })
}

/// Check if a parameter has a complex schema (object, oneOf, allOf, anyOf)
/// that is not handled by deepObject style.
fn validate_complex_param_schema(
  path: String,
  param: spec.Parameter,
  ctx: Context,
) -> List(ValidationError) {
  case param.style {
    Some(spec.DeepObjectStyle) ->
      // deepObject supports one level of object nesting only.
      // Reject nested object properties since codegen produces
      // invalid code (e.g., uri.percent_encode(filter.meta)).
      validate_deep_object_no_nested_objects(path, param, ctx)
    _ ->
      case param.in_ {
        spec.InPath -> []
        _ ->
          case resolve_schema_object(param.schema, ctx) {
            Some(ObjectSchema(..))
            | Some(AllOfSchema(..))
            | Some(OneOfSchema(..))
            | Some(AnyOfSchema(..)) -> [
              ValidationError(
                severity: SeverityError,
                target: TargetBoth,
                path: path,
                detail: "Complex schema (object/oneOf/allOf/anyOf) parameters require style: deepObject. Without it, the parameter cannot be serialized.",
              ),
            ]
            _ -> []
          }
      }
  }
}

/// Validate that a deepObject parameter has no nested object properties.
fn validate_deep_object_no_nested_objects(
  path: String,
  param: spec.Parameter,
  ctx: Context,
) -> List(ValidationError) {
  case resolve_schema_object(param.schema, ctx) {
    Some(ObjectSchema(properties:, ..)) ->
      dict.to_list(properties)
      |> list.flat_map(fn(entry) {
        let #(prop_name, prop_ref) = entry
        case resolve_schema_object(Some(prop_ref), ctx) {
          Some(ObjectSchema(..))
          | Some(AllOfSchema(..))
          | Some(OneOfSchema(..))
          | Some(AnyOfSchema(..)) -> [
            ValidationError(
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
  request_body: Option(spec.RequestBody),
  ctx: Context,
) -> List(ValidationError) {
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
          ValidationError(
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
      list.flatten([
        content_type_errors,
        schema_errors,
        multipart_field_errors,
        form_urlencoded_errors,
      ])
    }
  }
}

fn validate_multipart_request_body_fields(
  op_id: String,
  content: dict.Dict(String, spec.MediaType),
  ctx: Context,
) -> List(ValidationError) {
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
                ValidationError(
                  severity: SeverityError,
                  target: TargetBoth,
                  path: op_id <> ".requestBody.multipart." <> field_name,
                  detail: "multipart/form-data fields must be string, integer, number, boolean, binary, or string enums.",
                ),
              ]
            }
          })
        Some(_) -> [
          ValidationError(
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
) -> List(ValidationError) {
  case dict.get(content, "application/x-www-form-urlencoded") {
    Ok(media_type) ->
      case resolve_schema_object(media_type.schema, ctx) {
        Some(ObjectSchema(..)) -> []
        Some(_) -> [
          ValidationError(
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
  responses: dict.Dict(String, spec.Response),
  ctx: Context,
) -> List(ValidationError) {
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
          ValidationError(
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
fn validate_component_schemas(ctx: Context) -> List(ValidationError) {
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
) -> List(ValidationError) {
  case schema_ref {
    Reference(ref:, ..) ->
      // Detect external refs (not starting with #/) before resolution
      case string.starts_with(ref, "#/") {
        False -> [
          ValidationError(
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
              ValidationError(
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
) -> List(ValidationError) {
  case schema_obj {
    ObjectSchema(
      properties:,
      additional_properties:,
      additional_properties_untyped:,
      ..,
    ) -> {
      // additionalProperties: true is supported via Dict(String, Dynamic)
      let ap_errors = []
      let _ = additional_properties_untyped
      // Recurse into typed additionalProperties schema
      let typed_ap_errors = case additional_properties {
        Some(ap_ref) ->
          validate_schema_ref_recursive(
            path <> ".additionalProperties",
            ap_ref,
            ctx,
          )
        None -> []
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

/// Validate security schemes for unsupported types.
/// All scheme types are now supported: apiKey, HTTP (any scheme), OAuth2,
/// and OpenID Connect.
fn validate_security_schemes(_ctx: Context) -> List(ValidationError) {
  []
}

/// Check for AST fields that are parsed but not used by codegen, emitting
/// warnings so users are aware their spec contains features we preserve but
/// do not generate code for.
fn validate_preserved_but_unused(ctx: Context) -> List(ValidationError) {
  let webhook_warnings = case dict.is_empty(ctx.spec.webhooks) {
    True -> []
    False -> [
      ValidationError(
        severity: SeverityWarning,
        target: TargetBoth,
        path: "webhooks",
        detail: "Webhooks are parsed but not used by code generation.",
      ),
    ]
  }
  let operations = type_gen.collect_operations(ctx)
  let response_warnings =
    list.flat_map(operations, fn(op) {
      let #(op_id, operation, _path, _method) = op
      let entries = dict.to_list(operation.responses)
      list.flat_map(entries, fn(entry) {
        let #(status_code, response) = entry
        let base_path = op_id <> ".responses." <> status_code
        let header_warnings = case dict.is_empty(response.headers) {
          True -> []
          False -> [
            ValidationError(
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
            ValidationError(
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
                ValidationError(
                  severity: SeverityWarning,
                  target: TargetBoth,
                  path: base_path <> "." <> media_type_name <> ".encoding",
                  detail: "MediaType encoding is parsed but not used by code generation.",
                ),
              ]
            }
          })
        list.flatten([header_warnings, link_warnings, encoding_warnings])
      })
    })
  list.flatten([webhook_warnings, response_warnings])
}
