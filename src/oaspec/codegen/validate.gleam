import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
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
import oaspec/util/naming

/// A validation error representing an unsupported OpenAPI feature.
pub type ValidationError {
  UnsupportedFeature(path: String, detail: String)
}

/// Validate the parsed spec for unsupported patterns.
/// Returns a list of errors; empty list means validation passed.
pub fn validate(ctx: Context) -> List(ValidationError) {
  let op_errors = validate_operations(ctx)
  let schema_errors = validate_component_schemas(ctx)
  let collision_errors = validate_name_collisions(ctx)
  let security_errors = validate_security_schemes(ctx)
  list.flatten([op_errors, schema_errors, collision_errors, security_errors])
}

/// Convert a validation error to a human-readable string.
pub fn error_to_string(error: ValidationError) -> String {
  case error {
    UnsupportedFeature(path:, detail:) ->
      "Unsupported feature at " <> path <> ": " <> detail
  }
}

/// Validate all operations for unsupported patterns.
fn validate_operations(ctx: Context) -> List(ValidationError) {
  let operations = type_gen.collect_operations(ctx)
  list.flat_map(operations, fn(op) {
    let #(op_id, operation, _path, _method) = op
    let param_errors = validate_parameters(op_id, operation.parameters, ctx)
    let body_errors = validate_request_body(op_id, operation.request_body, ctx)
    let response_errors = validate_responses(op_id, operation.responses)
    list.flatten([param_errors, body_errors, response_errors])
  })
}

/// Validate parameters for unsupported patterns.
fn validate_parameters(
  op_id: String,
  params: List(spec.Parameter),
  ctx: Context,
) -> List(ValidationError) {
  list.flat_map(params, fn(param) {
    let path = op_id <> ".parameters." <> param.name
    let resolved_schema = resolve_schema_object(param.schema, ctx)
    let deep_object_errors = case param.style {
      Some("deepObject") -> [
        UnsupportedFeature(
          path: path,
          detail: "Parameter style 'deepObject' is not supported.",
        ),
      ]
      _ -> []
    }
    let complex_schema_errors = case resolved_schema {
      Some(ObjectSchema(..))
      | Some(AllOfSchema(..))
      | Some(OneOfSchema(..))
      | Some(AnyOfSchema(..)) -> [
        UnsupportedFeature(
          path: path,
          detail: "Complex schema parameters (object/allOf/oneOf/anyOf) are not supported.",
        ),
      ]
      _ -> []
    }
    let array_errors = case param.in_, resolved_schema {
      spec.InPath, _ -> []
      _, Some(ArraySchema(..)) -> [
        UnsupportedFeature(
          path: path,
          detail: "Array parameters in query/header/cookie are not supported.",
        ),
      ]
      _, _ -> []
    }
    let required_errors = case param.in_, param.required {
      spec.InPath, False -> [
        UnsupportedFeature(
          path: path,
          detail: "Path parameters with required: false are not supported.",
        ),
      ]
      _, _ -> []
    }
    list.flatten([
      deep_object_errors,
      complex_schema_errors,
      array_errors,
      required_errors,
    ])
  })
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
          UnsupportedFeature(
            path: op_id <> ".requestBody",
            detail: "Content type '"
              <> media_type
              <> "' is not supported. Only 'application/json' and 'multipart/form-data' are supported for request bodies.",
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
              validate_schema_ref_recursive(op_id <> ".requestBody", schema_ref)
            None -> []
          }
        })
      let multipart_field_errors =
        validate_multipart_request_body_fields(op_id, rb.content, ctx)
      list.flatten([
        content_type_errors,
        schema_errors,
        multipart_field_errors,
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
                UnsupportedFeature(
                  path: op_id <> ".requestBody.multipart." <> field_name,
                  detail: "multipart/form-data fields must be string, integer, number, boolean, binary, or string enums.",
                ),
              ]
            }
          })
        Some(_) -> [
          UnsupportedFeature(
            path: op_id <> ".requestBody",
            detail: "multipart/form-data request bodies must use an object schema.",
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
          UnsupportedFeature(
            path: path,
            detail: "Response content type '"
              <> media_type_name
              <> "' is not supported. Only 'application/json' and 'text/plain' are supported.",
          ),
        ]
      }
      let schema_errors = case media_type.schema {
        Some(schema_ref) -> validate_schema_ref_recursive(path, schema_ref)
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
    validate_schema_ref_recursive("components.schemas." <> name, schema_ref)
  })
}

/// Recursively validate a SchemaRef at any depth.
fn validate_schema_ref_recursive(
  path: String,
  schema_ref: SchemaRef,
) -> List(ValidationError) {
  case schema_ref {
    Reference(_) -> []
    Inline(schema_obj) -> validate_schema_recursive(path, schema_obj)
  }
}

/// Recursively validate a SchemaObject, descending into all sub-schemas.
fn validate_schema_recursive(
  path: String,
  schema_obj: SchemaObject,
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
          validate_schema_ref_recursive(path <> ".additionalProperties", ap_ref)
        None -> []
      }
      // Recurse into properties, also catching inline objects
      let prop_errors =
        dict.to_list(properties)
        |> list.flat_map(fn(entry) {
          let #(prop_name, prop_ref) = entry
          let prop_path = path <> "." <> prop_name
          let inline_obj_errors = case prop_ref {
            Inline(ObjectSchema(..)) -> [
              UnsupportedFeature(
                path: prop_path,
                detail: "Nested inline object properties are not supported. Extract to a named schema in components.schemas and use $ref.",
              ),
            ]
            Inline(AllOfSchema(..)) -> [
              UnsupportedFeature(
                path: prop_path,
                detail: "Nested inline allOf properties are not supported. Extract to a named schema in components.schemas and use $ref.",
              ),
            ]
            _ -> []
          }
          list.append(
            inline_obj_errors,
            validate_schema_ref_recursive(prop_path, prop_ref),
          )
        })
      // Property name collisions after snake_case conversion
      let prop_names =
        dict.to_list(properties)
        |> list.map(fn(entry) {
          let #(prop_name, _) = entry
          naming.to_snake_case(prop_name)
        })
      let prop_collision_errors =
        find_name_collisions(prop_names, fn(dup) {
          UnsupportedFeature(
            path: path,
            detail: "Property name collision after snake_case conversion: '"
              <> dup
              <> "'",
          )
        })
      list.flatten([
        ap_errors,
        typed_ap_errors,
        prop_errors,
        prop_collision_errors,
      ])
    }

    ArraySchema(items:, ..) -> {
      // Reject inline complex array items
      let item_errors = case items {
        Inline(ObjectSchema(..))
        | Inline(AllOfSchema(..))
        | Inline(OneOfSchema(..))
        | Inline(AnyOfSchema(..)) -> [
          UnsupportedFeature(
            path: path <> ".items",
            detail: "Inline complex array items (object/allOf/oneOf/anyOf) are not supported. Extract to components.schemas and use $ref.",
          ),
        ]
        _ -> []
      }
      list.append(
        item_errors,
        validate_schema_ref_recursive(path <> ".items", items),
      )
    }

    OneOfSchema(schemas:, ..) -> validate_compound_schemas(path, schemas)
    AnyOfSchema(schemas:, ..) -> validate_compound_schemas(path, schemas)

    AllOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s_ref) {
        validate_schema_ref_recursive(path <> ".allOf", s_ref)
      })

    _ -> []
  }
}

/// Validate oneOf/anyOf schemas: only $ref variants are supported.
/// Inline schemas (primitives, objects, arrays) cannot be generated as
/// union variants.
fn validate_compound_schemas(
  path: String,
  schemas: List(SchemaRef),
) -> List(ValidationError) {
  let inline_errors = case has_any_inline_schemas(schemas) {
    True -> [
      UnsupportedFeature(
        path: path,
        detail: "oneOf/anyOf with inline schemas is not supported. All variants must be $ref to named schemas.",
      ),
    ]
    False -> []
  }
  // Recurse into each sub-schema
  let child_errors =
    list.flat_map(schemas, fn(s_ref) {
      validate_schema_ref_recursive(path, s_ref)
    })
  list.append(inline_errors, child_errors)
}

/// Check if any schema in a list is inline (not a $ref).
fn has_any_inline_schemas(schemas: List(SchemaRef)) -> Bool {
  list.any(schemas, fn(s) {
    case s {
      Inline(_) -> True
      Reference(_) -> False
    }
  })
}

/// Validate for operationId duplicates and naming collisions.
fn validate_name_collisions(ctx: Context) -> List(ValidationError) {
  let operations = type_gen.collect_operations(ctx)

  // Check duplicate operationId
  let op_id_errors =
    find_duplicates(
      operations,
      fn(op) {
        let #(op_id, _, _, _) = op
        op_id
      },
      fn(dup) {
        UnsupportedFeature(
          path: "paths",
          detail: "Duplicate operationId: '" <> dup <> "'",
        )
      },
    )

  // Function name collisions after snake_case conversion
  let fn_names =
    list.map(operations, fn(op) {
      let #(op_id, _, _, _) = op
      naming.operation_to_function_name(op_id)
    })
  let fn_collision_errors =
    find_name_collisions(fn_names, fn(dup) {
      UnsupportedFeature(
        path: "paths",
        detail: "Function name collision after case conversion: '" <> dup <> "'",
      )
    })

  // Type name collisions after PascalCase conversion
  let type_names =
    list.map(operations, fn(op) {
      let #(op_id, _, _, _) = op
      naming.schema_to_type_name(op_id)
    })
  let type_collision_errors =
    find_name_collisions(type_names, fn(dup) {
      UnsupportedFeature(
        path: "paths",
        detail: "Type name collision after case conversion: '" <> dup <> "'",
      )
    })

  list.flatten([op_id_errors, fn_collision_errors, type_collision_errors])
}

/// Find duplicates in a list using a key function, producing errors via an
/// error function. Only reports the first occurrence of each duplicate.
fn find_duplicates(
  items: List(a),
  key_fn: fn(a) -> String,
  error_fn: fn(String) -> ValidationError,
) -> List(ValidationError) {
  let #(_, errors) =
    list.fold(items, #(set.new(), []), fn(acc, item) {
      let #(seen, errs) = acc
      let key = key_fn(item)
      case set.contains(seen, key) {
        True -> #(seen, [error_fn(key), ..errs])
        False -> #(set.insert(seen, key), errs)
      }
    })
  list.reverse(errors)
}

/// Find duplicate names in a simple list of strings.
fn find_name_collisions(
  names: List(String),
  error_fn: fn(String) -> ValidationError,
) -> List(ValidationError) {
  find_duplicates(names, fn(name) { name }, error_fn)
}

/// Validate security schemes for unsupported types.
fn validate_security_schemes(ctx: Context) -> List(ValidationError) {
  let schemes = case ctx.spec.components {
    Some(components) -> dict.to_list(components.security_schemes)
    None -> []
  }
  list.flat_map(schemes, fn(entry) {
    let #(name, scheme) = entry
    case scheme {
      spec.ApiKeyScheme(..) -> []
      spec.HttpScheme(scheme: "bearer", ..) -> []
      spec.HttpScheme(scheme: "basic", ..) -> []
      spec.HttpScheme(scheme: "digest", ..) -> []
      spec.HttpScheme(scheme: scheme_name, ..) -> [
        UnsupportedFeature(
          path: "components.securitySchemes." <> name,
          detail: "HTTP security scheme '"
            <> scheme_name
            <> "' is not supported. Supported schemes: bearer, basic, digest.",
        ),
      ]
      spec.OAuth2Scheme(..) -> [
        UnsupportedFeature(
          path: "components.securitySchemes." <> name,
          detail: "OAuth2 security scheme is not supported.",
        ),
      ]
    }
  })
}
