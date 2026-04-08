import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import oaspec/codegen/context.{type Context}
import oaspec/codegen/types as type_gen
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  Inline, ObjectSchema, OneOfSchema, Reference,
}
import oaspec/openapi/spec
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
  list.flatten([op_errors, schema_errors, collision_errors])
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
    let param_errors = validate_parameters(op_id, operation.parameters)
    let body_errors = validate_request_body(op_id, operation.request_body)
    let response_errors = validate_responses(op_id, operation.responses)
    list.flatten([param_errors, body_errors, response_errors])
  })
}

/// Validate parameters for unsupported patterns.
fn validate_parameters(
  op_id: String,
  params: List(spec.Parameter),
) -> List(ValidationError) {
  list.flat_map(params, fn(param) {
    let path = op_id <> ".parameters." <> param.name
    let style_errors = case param.style {
      Some("deepObject") -> [
        UnsupportedFeature(
          path: path,
          detail: "style: deepObject is not supported. Gleam cannot express deep object query serialization.",
        ),
      ]
      _ -> []
    }
    // Reject array and complex schema parameters
    let schema_errors = case param.schema {
      Some(Inline(ArraySchema(..))) -> [
        UnsupportedFeature(
          path: path,
          detail: "Array parameters are not yet supported. Use a single-value parameter instead.",
        ),
      ]
      Some(Inline(ObjectSchema(..)))
      | Some(Inline(AllOfSchema(..)))
      | Some(Inline(OneOfSchema(..)))
      | Some(Inline(AnyOfSchema(..))) -> [
        UnsupportedFeature(
          path: path,
          detail: "Complex schema parameters (object/allOf/oneOf/anyOf) are not supported.",
        ),
      ]
      _ -> []
    }
    list.append(style_errors, schema_errors)
  })
}

/// Validate request body for unsupported patterns.
fn validate_request_body(
  op_id: String,
  request_body: Option(spec.RequestBody),
) -> List(ValidationError) {
  case request_body {
    None -> []
    Some(rb) -> {
      let content_keys = dict.keys(rb.content)
      let non_json =
        list.filter(content_keys, fn(key) { key != "application/json" })
      let content_type_errors = case non_json {
        [] -> []
        [media_type, ..] -> [
          UnsupportedFeature(
            path: op_id <> ".requestBody",
            detail: "Content type '"
              <> media_type
              <> "' is not supported. Only 'application/json' is supported.",
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
      list.append(content_type_errors, schema_errors)
    }
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
      let content_type_errors = case media_type_name {
        "application/json" -> []
        _ -> [
          UnsupportedFeature(
            path: path,
            detail: "Response content type '"
              <> media_type_name
              <> "' is not supported. Only 'application/json' is supported.",
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
      // Check additionalProperties: true
      let ap_errors = case additional_properties_untyped {
        True -> [
          UnsupportedFeature(
            path: path,
            detail: "additionalProperties: true is not supported. Gleam has no untyped map type.",
          ),
        ]
        False -> []
      }
      // Check typed additionalProperties (unsupported for now)
      let typed_ap_errors = case additional_properties {
        Some(_) -> [
          UnsupportedFeature(
            path: path,
            detail: "Typed additionalProperties is not yet supported.",
          ),
        ]
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
      // Check property name collisions after snake_case conversion
      let prop_names =
        dict.to_list(properties)
        |> list.map(fn(entry) {
          let #(prop_name, _) = entry
          naming.to_snake_case(prop_name)
        })
      let prop_collision_errors =
        find_string_duplicates(prop_names, fn(dup) {
          UnsupportedFeature(
            path: path,
            detail: "Property name collision after snake_case: '" <> dup <> "'",
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

    _ -> {
      // Check enum variant collisions for string enums
      case schema_obj {
        schema.StringSchema(enum_values:, ..) if enum_values != [] -> {
          let variant_names =
            list.map(enum_values, fn(v) { naming.schema_to_type_name(v) })
          find_string_duplicates(variant_names, fn(dup) {
            UnsupportedFeature(
              path: path,
              detail: "Enum variant collision after PascalCase: '" <> dup <> "'",
            )
          })
        }
        _ -> []
      }
    }
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

  // Check snake_case function name collisions
  let fn_name_errors =
    find_duplicates(
      operations,
      fn(op) {
        let #(op_id, _, _, _) = op
        naming.operation_to_function_name(op_id)
      },
      fn(dup) {
        UnsupportedFeature(
          path: "paths",
          detail: "Function name collision after snake_case conversion: '"
            <> dup
            <> "'",
        )
      },
    )

  // Check PascalCase type name collisions for response/request types
  let type_name_errors =
    find_duplicates(
      operations,
      fn(op) {
        let #(op_id, _, _, _) = op
        naming.schema_to_type_name(op_id)
      },
      fn(dup) {
        UnsupportedFeature(
          path: "paths",
          detail: "Type name collision after PascalCase conversion: '"
            <> dup
            <> "'",
        )
      },
    )

  list.flatten([op_id_errors, fn_name_errors, type_name_errors])
}

/// Find duplicates in a list of strings.
fn find_string_duplicates(
  items: List(String),
  error_fn: fn(String) -> ValidationError,
) -> List(ValidationError) {
  find_duplicates(items, fn(s) { s }, error_fn)
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
