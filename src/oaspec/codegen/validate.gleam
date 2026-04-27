import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/string
import oaspec/codegen/context.{type Context}
import oaspec/config
import oaspec/openapi/diagnostic.{
  type Diagnostic, SeverityError, TargetBoth, TargetServer,
}
import oaspec/openapi/operations
import oaspec/openapi/resolver
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  BooleanSchema, Forbidden, Inline, IntegerSchema, NumberSchema, ObjectSchema,
  OneOfSchema, Reference, StringSchema, Typed, Unspecified, Untyped,
}
import oaspec/openapi/spec.{type Resolved}
import oaspec/util/content_type
import oaspec/util/http
import oaspec/util/naming

/// Validate the parsed spec for unsupported patterns.
/// Returns a list of errors; empty list means validation passed.
///
/// operationId uniqueness is enforced here with a hard error (issue #237):
/// silently renaming duplicates would mutate the generated public API
/// surface without telling the user, which is worse than failing the spec.
pub fn validate(ctx: Context) -> List(Diagnostic) {
  let operations = operations.collect_operations(ctx)
  let op_errors = validate_operations(ctx, operations)
  let opid_errors = validate_unique_operation_ids(operations)
  let schema_errors = validate_component_schemas(ctx)
  let schema_collision_errors = validate_unique_schema_names(ctx)
  let security_errors = validate_security_schemes(ctx, operations)
  let list_decoder_errors = validate_decode_list_collisions(ctx)
  list.flatten([
    op_errors,
    opid_errors,
    schema_errors,
    schema_collision_errors,
    security_errors,
    list_decoder_errors,
  ])
}

/// Detect `Foo` + `FooList` schema name pairs that would generate two
/// `decode_foo_list` functions in `decode.gleam` and trip the gleam
/// compiler's `Duplicate definition` check. The synthetic list decoder
/// (`decode_<schema>_list` returning `List(<Schema>)`) is emitted for
/// every component schema, so any user-named `<Schema>List` schema
/// collides on the same identifier. Detected at validation time so the
/// user gets a one-line spec-level diagnostic instead of a confusing
/// post-codegen build failure. (#267)
fn validate_decode_list_collisions(ctx: Context) -> List(Diagnostic) {
  let schema_names = case context.spec(ctx).components {
    Some(components) ->
      dict.to_list(components.schemas) |> list.map(fn(entry) { entry.0 })
    None -> []
  }
  list.filter_map(schema_names, fn(base_name) {
    let collider_name = base_name <> "List"
    case list.contains(schema_names, collider_name) {
      False -> Error(Nil)
      True -> {
        let snake = naming.to_snake_case(base_name)
        Ok(diagnostic.validation(
          severity: SeverityError,
          target: TargetBoth,
          path: "components.schemas." <> collider_name,
          detail: "Schema name '"
            <> collider_name
            <> "' would generate decode_"
            <> snake
            <> "_list, which collides with the synthetic list decoder for '"
            <> base_name
            <> "' (a JSON array of "
            <> base_name
            <> "). gleam build will fail with `Duplicate definition: decode_"
            <> snake
            <> "_list`.",
          hint: Some(
            "Rename one of the schemas. Example: rename '"
            <> collider_name
            <> "' to '"
            <> base_name
            <> "Collection', '"
            <> base_name
            <> "Page', or '"
            <> base_name
            <> "Items'.",
          ),
        ))
      }
    }
  })
}

/// Fail the spec if two operations end up sharing an operationId, either
/// literally or after snake_case conversion to the generated function
/// name. Returns one diagnostic per distinct colliding name, listing all
/// `METHOD /path` sites that claimed it.
fn validate_unique_operation_ids(
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> List(Diagnostic) {
  let literal = group_operations_by_id(operations, fn(op_id) { op_id })
  let by_function =
    group_operations_by_id(operations, naming.operation_to_function_name)

  let literal_errors =
    dict.to_list(literal)
    |> list.filter_map(fn(entry) {
      let #(op_id, sites) = entry
      case sites {
        [_, _, ..] -> Ok(duplicate_operation_id_diagnostic(op_id, sites))
        _ -> Error(Nil)
      }
    })

  // A spec with "listItems" and "list_items" has no literal collision but
  // generates two functions called `list_items/N` — catch that too.
  // Skip cases where every site is already covered by a literal-duplicate
  // diagnostic (same sites, same name), to avoid emitting two diagnostics
  // for the same root cause.
  let function_errors =
    dict.to_list(by_function)
    |> list.filter_map(fn(entry) {
      let #(fn_name, sites) = entry
      case sites {
        [_, _, ..] -> {
          case dict.get(literal, fn_name) {
            Ok(literal_sites) if literal_sites == sites -> Error(Nil)
            _ -> Ok(duplicate_function_name_diagnostic(fn_name, sites))
          }
        }
        _ -> Error(Nil)
      }
    })

  list.append(literal_errors, function_errors)
}

fn group_operations_by_id(
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
  key_fn: fn(String) -> String,
) -> Dict(String, List(String)) {
  list.fold(operations, dict.new(), fn(acc, entry) {
    let #(op_id, _operation, path, method) = entry
    let key = key_fn(op_id)
    let site = string.uppercase(spec.method_to_string(method)) <> " " <> path
    case dict.get(acc, key) {
      Ok(existing) -> dict.insert(acc, key, list.append(existing, [site]))
      // nolint: thrown_away_error -- dict.get's Error signals absence of key; we start a new list for the first occurrence
      Error(_) -> dict.insert(acc, key, [site])
    }
  })
}

fn duplicate_operation_id_diagnostic(
  op_id: String,
  sites: List(String),
) -> Diagnostic {
  diagnostic.invalid_value(
    path: "paths.*.operationId",
    detail: "Duplicate operationId '"
      <> op_id
      <> "' found on: "
      <> string.join(sites, ", ")
      <> ". operationId must be unique across the entire spec; "
      <> "rename one of the operations to keep the generated API stable.",
    loc: diagnostic.NoSourceLoc,
  )
}

fn duplicate_function_name_diagnostic(
  fn_name: String,
  sites: List(String),
) -> Diagnostic {
  diagnostic.invalid_value(
    path: "paths.*.operationId",
    detail: "operationIds that normalize to the same generated function name '"
      <> fn_name
      <> "' found on: "
      <> string.join(sites, ", ")
      <> ". oaspec converts operationIds to snake_case, so values like "
      <> "'listItems' and 'list_items' collide; rename one of them.",
    loc: diagnostic.NoSourceLoc,
  )
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
fn validate_operations(
  ctx: Context,
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> List(Diagnostic) {
  list.flat_map(operations, fn(op) {
    let #(op_id, operation, path, _method) = op
    // All refs are guaranteed to be resolved by this point
    let resolved_params = list.map(operation.parameters, spec.unwrap_ref)
    let resolved_request_body = case operation.request_body {
      Some(ref_or) -> Some(spec.unwrap_ref(ref_or))
      None -> None
    }
    let resolved_responses =
      dict.to_list(operation.responses)
      |> list.map(fn(entry) {
        let #(status_code, ref_or) = entry
        #(status_code, spec.unwrap_ref(ref_or))
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
          hint: Some(
            "Add at least one response (e.g., '200': { description: ok }) to this operation.",
          ),
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
  params: List(spec.Parameter(Resolved)),
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
      False -> {
        let defined = case path_param_names {
          [] -> ""
          names ->
            " Defined path parameters: " <> string.join(names, ", ") <> "."
        }
        Ok(diagnostic.validation(
          severity: SeverityError,
          target: TargetBoth,
          path: op_id <> ".path",
          detail: "Path template parameter '{"
            <> name
            <> "}' in '"
            <> path
            <> "' has no corresponding parameter definition.",
          hint: Some(
            "Add a parameter definition with 'in: path' for this variable, or remove it from the path template."
            <> defined,
          ),
        ))
      }
    }
  })
}

/// Extract parameter names from path template, e.g. "/items/{id}" -> ["id"].
fn extract_path_template_names(path: String) -> List(String) {
  // nolint: assert_ok_pattern -- compile-time constant regex literal cannot fail to parse
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
/// Supported: form (default), deepObject (query+object), exploded array,
/// pipeDelimited / spaceDelimited (query+array only).
/// Unsupported: matrix, label.
fn validate_parameters(
  op_id: String,
  params: List(spec.Parameter(Resolved)),
  ctx: Context,
) -> List(Diagnostic) {
  list.flat_map(params, fn(p) {
    let path = op_id <> ".parameters." <> p.name
    let style_errors = case p.style {
      Some(spec.MatrixStyle) | Some(spec.LabelStyle) -> [
        diagnostic.validation(
          severity: SeverityError,
          target: TargetBoth,
          path: path,
          detail: "Parameter style is not supported. Supported styles: form, simple, deepObject, pipeDelimited, spaceDelimited.",
          hint: Some(
            "Use style 'form', 'simple', 'deepObject', 'pipeDelimited', or 'spaceDelimited' instead.",
          ),
        ),
      ]
      Some(spec.PipeDelimitedStyle) ->
        validate_delimited_style(path, p, "pipeDelimited", ctx)
      Some(spec.SpaceDelimitedStyle) ->
        validate_delimited_style(path, p, "spaceDelimited", ctx)
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
          hint: Some(
            "Replace the 'content' field with a 'schema' field in the parameter definition.",
          ),
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

/// Validate pipeDelimited / spaceDelimited parameter styles.
/// Both are only meaningful for array-typed query parameters; reject elsewhere.
fn validate_delimited_style(
  path: String,
  param: spec.Parameter(Resolved),
  style_name: String,
  ctx: Context,
) -> List(Diagnostic) {
  let location_errors = case param.in_ {
    spec.InQuery -> []
    _ -> [
      diagnostic.validation(
        severity: SeverityError,
        target: TargetBoth,
        path: path,
        detail: "Parameter style '"
          <> style_name
          <> "' is only supported for 'in: query'.",
        hint: Some(
          "Move this parameter to 'in: query' or switch to a style valid for its location.",
        ),
      ),
    ]
  }
  let schema_errors = case
    resolve_schema_object(spec.parameter_schema(param), ctx)
  {
    Some(ArraySchema(..)) -> []
    _ -> [
      diagnostic.validation(
        severity: SeverityError,
        target: TargetBoth,
        path: path,
        detail: "Parameter style '"
          <> style_name
          <> "' requires an array schema.",
        hint: Some(
          "Change the schema to 'type: array' or switch to style 'form'.",
        ),
      ),
    ]
  }
  list.flatten([location_errors, schema_errors])
}

fn validate_server_structured_param(
  path: String,
  param: spec.Parameter(Resolved),
  ctx: Context,
) -> List(Diagnostic) {
  case config.mode(context.config(ctx)) {
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
            hint: Some(
              "Use inline primitive items (string, integer, number, boolean) for array query parameters.",
            ),
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
            hint: Some(
              "Use inline primitive items (string, integer, number, boolean) for array header parameters.",
            ),
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
  param: spec.Parameter(Resolved),
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
              hint: Some(
                "Simplify deepObject properties to primitive scalars or primitive arrays.",
              ),
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
  _path: String,
  _param: spec.Parameter(Resolved),
  _ctx: Context,
) -> List(Diagnostic) {
  []
}

/// Check if a parameter has a complex schema (object, oneOf, allOf, anyOf)
/// that is not handled by deepObject style.
fn validate_complex_param_schema(
  path: String,
  param: spec.Parameter(Resolved),
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
              case config.mode(context.config(ctx)) {
                config.Client -> []
                _ -> [
                  diagnostic.validation(
                    severity: SeverityError,
                    target: TargetServer,
                    path: path,
                    detail: "Complex path parameters are not supported for server code generation.",
                    hint: Some(
                      "Use a simple scalar type (string, integer, number, boolean) for path parameters.",
                    ),
                  ),
                ]
              }
            _ -> [
              diagnostic.validation(
                severity: SeverityError,
                target: TargetBoth,
                path: path,
                detail: "Complex schema (object/oneOf/allOf/anyOf) parameters require style: deepObject. Without it, the parameter cannot be serialized.",
                hint: Some(
                  "Add 'style: deepObject' to the parameter definition.",
                ),
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
  param: spec.Parameter(Resolved),
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
              hint: Some(
                "Flatten the property structure to a single level of nesting.",
              ),
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
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
        Ok(schema_obj) -> Some(schema_obj)
        // nolint: thrown_away_error -- unresolved refs surface as absent; the ref error is reported elsewhere in the validator
        Error(_) -> None
      }
    None -> None
  }
}

/// Validate request body for unsupported patterns.
fn validate_request_body(
  op_id: String,
  request_body: Option(spec.RequestBody(Resolved)),
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
              <> "' is not supported. Supported request content types: application/json (and +json suffix types), multipart/form-data, application/x-www-form-urlencoded, application/octet-stream.",
            hint: Some(
              "Use application/json (or a +json suffix type like application/problem+json), multipart/form-data, application/x-www-form-urlencoded, or application/octet-stream.",
            ),
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
                  hint: Some(
                    "Use a primitive scalar type, binary, or string enum for multipart fields.",
                  ),
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
            hint: Some(
              "Wrap fields in an object schema with properties for each form field.",
            ),
          ),
        ]
        None -> []
      }
    // nolint: thrown_away_error -- absence of the content type means there is nothing to validate here
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
            hint: Some(
              "Wrap fields in an object schema with properties for each form field.",
            ),
          ),
        ]
        None -> []
      }
    // nolint: thrown_away_error -- absence of the content type means there is nothing to validate here
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
  case config.mode(context.config(ctx)) {
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
                hint: Some(
                  "Remove other content type definitions from this operation's request body.",
                ),
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
                      hint: Some(
                        "Simplify to primitive scalars, primitive arrays, or shallow nested objects.",
                      ),
                    ),
                  ]
                }
              })
            _ -> []
          }
          list.append(content_type_errors, field_errors)
        }
        // nolint: thrown_away_error -- absence of the content type means there is nothing to validate here
        Error(_) -> []
      }
  }
}

fn validate_server_request_body_content_types(
  op_id: String,
  content_keys: List(String),
  ctx: Context,
) -> List(Diagnostic) {
  case config.mode(context.config(ctx)) {
    config.Client -> []
    _ -> {
      let non_json_but_supported =
        list.filter(content_keys, fn(key) {
          key != "application/json"
          && key != "application/x-www-form-urlencoded"
          && key != "multipart/form-data"
          && key != "application/octet-stream"
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
          hint: Some(
            "Use application/json for typed server request bodies, or multipart/form-data, application/x-www-form-urlencoded, or application/octet-stream for non-JSON payloads.",
          ),
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
  case config.mode(context.config(ctx)) {
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
                hint: Some(
                  "Remove other content type definitions from this operation's request body.",
                ),
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
                      hint: Some(
                        "Use primitive scalar types or arrays of primitive scalars (string, integer, number, boolean) for multipart form fields.",
                      ),
                    ),
                  ]
                }
              })
            _ -> []
          }
          list.append(content_type_errors, field_errors)
        }
        // nolint: thrown_away_error -- absence of the content type means there is nothing to validate here
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
  responses: dict.Dict(http.HttpStatusCode, spec.Response(Resolved)),
  ctx: Context,
) -> List(Diagnostic) {
  let entries = dict.to_list(responses)
  list.flat_map(entries, fn(entry) {
    let #(status_code, response) = entry
    let content_entries = dict.to_list(response.content)
    list.flat_map(content_entries, fn(ce) {
      let #(media_type_name, media_type) = ce
      let path =
        op_id <> ".responses." <> http.status_code_to_string(status_code)
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
              <> "' is not supported. Supported response content types: application/json (and +json suffix types), text/plain, application/x-ndjson, application/octet-stream, application/xml (and +xml suffix types), text/xml.",
            hint: Some(
              "Use application/json (or a +json suffix type), text/plain, application/x-ndjson, application/octet-stream, application/xml (or a +xml suffix type), or text/xml.",
            ),
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
/// Detect schema names that differ only in case and would collide when
/// mapped to the same Gleam type name via `schema_to_type_name` (#293).
fn validate_unique_schema_names(ctx: Context) -> List(Diagnostic) {
  let schemas = case context.spec(ctx).components {
    Some(components) -> dict.keys(components.schemas)
    None -> []
  }
  // Group by the generated Gleam type name — collisions appear as groups of 2+.
  let by_type_name =
    list.fold(schemas, dict.new(), fn(acc, name) {
      let key = naming.schema_to_type_name(name)
      case dict.get(acc, key) {
        Ok(existing) -> dict.insert(acc, key, [name, ..existing])
        // nolint: thrown_away_error -- dict.get's Error signals absence; we start a new list for the first name
        Error(_) -> dict.insert(acc, key, [name])
      }
    })
  dict.to_list(by_type_name)
  |> list.filter_map(fn(entry) {
    let #(type_name, names) = entry
    case names {
      [_, _, ..] ->
        Ok(diagnostic.invalid_value(
          path: "components.schemas",
          detail: "Schema names "
            <> string.join(list.map(names, fn(n) { "\"" <> n <> "\"" }), ", ")
            <> " all map to Gleam type `"
            <> type_name
            <> "` — rename one to avoid the collision",
          loc: diagnostic.NoSourceLoc,
        ))
      _ -> Error(Nil)
    }
  })
}

fn validate_component_schemas(ctx: Context) -> List(Diagnostic) {
  let schemas = case context.spec(ctx).components {
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
/// Does this `$ref` value look like an absolute URL (http/https)? These
/// are the shape that OpenAPI 3.1 `$id`-backed same-document refs take,
/// and we surface them as a dedicated diagnostic separate from generic
/// external `$ref` errors.
fn is_url_style_ref(ref: String) -> Bool {
  string.starts_with(ref, "http://") || string.starts_with(ref, "https://")
}

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
          case is_url_style_ref(ref) {
            True ->
              diagnostic.validation(
                severity: SeverityError,
                target: TargetBoth,
                path: path,
                detail: "URL-style $ref '"
                  <> ref
                  <> "' is not supported. oaspec does not resolve OpenAPI 3.1 / JSON Schema `$id`-backed identifiers — those refs are an explicit boundary.",
                hint: Some(
                  "Rewrite the schema to a local $ref (`#/components/schemas/...`) and drop the `$id` URL, or inline the schema at the use site.",
                ),
              )
            False ->
              diagnostic.validation(
                severity: SeverityError,
                target: TargetBoth,
                path: path,
                detail: "External $ref '"
                  <> ref
                  <> "' is not supported. Only local references (#/components/...) are supported.",
                hint: Some(
                  "Inline the external schema or copy it into #/components/schemas/ and use a local $ref.",
                ),
              )
          },
        ]
        True ->
          case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
            Ok(_) -> []
            // nolint: thrown_away_error -- resolver error is replaced with a user-facing diagnostic that conveys the same failure
            Error(_) -> [
              diagnostic.validation(
                severity: SeverityError,
                target: TargetBoth,
                path: path,
                detail: "Unresolved schema reference: '"
                  <> ref
                  <> "'. The referenced schema does not exist in components.",
                hint: Some(
                  "Verify the schema is defined in components.schemas and the $ref path is spelled correctly.",
                ),
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
        Forbidden | Untyped | Unspecified -> []
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
fn validate_security_schemes(
  ctx: Context,
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> List(Diagnostic) {
  let scheme_names = case context.spec(ctx).components {
    Some(components) -> dict.keys(components.security_schemes)
    None -> []
  }

  let global_errors =
    list.flat_map(context.spec(ctx).security, fn(req) {
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
              hint: Some(
                "Add the security scheme definition to components.securitySchemes or fix the scheme name.",
              ),
            ))
        }
      })
    })

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
                    hint: Some(
                      "Add the security scheme definition to components.securitySchemes or fix the scheme name.",
                    ),
                  ))
              }
            })
          })
        None -> []
      }
    })

  list.append(global_errors, operation_errors)
}
