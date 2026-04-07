import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_oas/codegen/context.{type Context}
import gleam_oas/codegen/types as type_gen
import gleam_oas/openapi/schema.{
  type SchemaObject, type SchemaRef, AnyOfSchema, BooleanSchema, Inline,
  IntegerSchema, NumberSchema, ObjectSchema, OneOfSchema, StringSchema,
}
import gleam_oas/openapi/spec

/// A validation error representing an unsupported OpenAPI feature.
pub type ValidationError {
  UnsupportedFeature(path: String, detail: String)
}

/// Validate the parsed spec for unsupported patterns.
/// Returns a list of errors; empty list means validation passed.
pub fn validate(ctx: Context) -> List(ValidationError) {
  let op_errors = validate_operations(ctx)
  let schema_errors = validate_component_schemas(ctx)
  list.append(op_errors, schema_errors)
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

/// Validate parameters for unsupported patterns (e.g., deepObject style).
fn validate_parameters(
  op_id: String,
  params: List(spec.Parameter),
) -> List(ValidationError) {
  list.filter_map(params, fn(param) {
    case param.style {
      Some("deepObject") ->
        Ok(UnsupportedFeature(
          path: op_id <> ".parameters." <> param.name,
          detail: "style: deepObject is not supported. Gleam cannot express deep object query serialization.",
        ))
      _ -> Error(Nil)
    }
  })
}

/// Validate request body for unsupported patterns (e.g., non-JSON content types).
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
      case non_json {
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
    }
  }
}

/// Validate response schemas for inline oneOf with mixed primitives.
fn validate_responses(
  op_id: String,
  responses: dict.Dict(String, spec.Response),
) -> List(ValidationError) {
  let entries = dict.to_list(responses)
  list.flat_map(entries, fn(entry) {
    let #(status_code, response) = entry
    let content_entries = dict.to_list(response.content)
    list.flat_map(content_entries, fn(ce) {
      let #(_media_type, media_type) = ce
      case media_type.schema {
        Some(Inline(schema_obj)) ->
          validate_schema_inline(
            op_id <> ".responses." <> status_code,
            schema_obj,
          )
        _ -> []
      }
    })
  })
}

/// Validate inline schemas for unsupported patterns.
fn validate_schema_inline(
  path: String,
  schema_obj: SchemaObject,
) -> List(ValidationError) {
  case schema_obj {
    OneOfSchema(schemas:, ..) -> validate_oneof_schemas(path, schemas)
    AnyOfSchema(schemas:, ..) -> validate_oneof_schemas(path, schemas)
    _ -> []
  }
}

/// Validate oneOf/anyOf schemas: inline primitives are unsupported.
fn validate_oneof_schemas(
  path: String,
  schemas: List(SchemaRef),
) -> List(ValidationError) {
  let has_inline_primitives = has_inline_primitive_schemas(schemas)
  case has_inline_primitives {
    True -> [
      UnsupportedFeature(
        path: path,
        detail: "oneOf/anyOf with inline primitive types is not supported. Use $ref to named schemas instead.",
      ),
    ]
    False -> []
  }
}

/// Validate component schemas for unsupported patterns.
fn validate_component_schemas(ctx: Context) -> List(ValidationError) {
  let schemas = case ctx.spec.components {
    Some(components) -> dict.to_list(components.schemas)
    None -> []
  }
  list.flat_map(schemas, fn(entry) {
    let #(name, schema_ref) = entry
    validate_component_schema("components.schemas." <> name, schema_ref)
  })
}

/// Validate a single component schema for unsupported patterns.
fn validate_component_schema(
  path: String,
  schema_ref: SchemaRef,
) -> List(ValidationError) {
  case schema_ref {
    Inline(ObjectSchema(properties:, additional_properties_untyped: True, ..)) -> {
      let prop_errors = validate_object_properties(path, properties)
      [
        UnsupportedFeature(
          path: path,
          detail: "additionalProperties: true is not supported. Gleam has no untyped map type.",
        ),
        ..prop_errors
      ]
    }
    Inline(ObjectSchema(properties:, ..)) ->
      validate_object_properties(path, properties)
    Inline(OneOfSchema(schemas:, ..)) -> validate_oneof_schemas(path, schemas)
    Inline(AnyOfSchema(schemas:, ..)) -> validate_oneof_schemas(path, schemas)
    _ -> []
  }
}

/// Validate object properties for unsupported patterns.
fn validate_object_properties(
  path: String,
  properties: dict.Dict(String, SchemaRef),
) -> List(ValidationError) {
  let entries = dict.to_list(properties)
  list.flat_map(entries, fn(entry) {
    let #(prop_name, prop_ref) = entry
    let prop_path = path <> "." <> prop_name
    case prop_ref {
      Inline(OneOfSchema(schemas:, ..)) ->
        validate_oneof_schemas(prop_path, schemas)
      Inline(AnyOfSchema(schemas:, ..)) ->
        validate_oneof_schemas(prop_path, schemas)
      Inline(ObjectSchema(additional_properties_untyped: True, ..)) -> [
        UnsupportedFeature(
          path: prop_path,
          detail: "additionalProperties: true is not supported. Gleam has no untyped map type.",
        ),
      ]
      _ -> []
    }
  })
}

/// Check if any schema in a list is an inline primitive type.
fn has_inline_primitive_schemas(schemas: List(SchemaRef)) -> Bool {
  list.any(schemas, fn(s) {
    case s {
      Inline(StringSchema(..)) -> True
      Inline(IntegerSchema(..)) -> True
      Inline(NumberSchema(..)) -> True
      Inline(BooleanSchema(..)) -> True
      _ -> False
    }
  })
}
