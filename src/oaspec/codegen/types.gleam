import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import oaspec/codegen/allof_merge
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/ir_build
import oaspec/codegen/ir_render
import oaspec/codegen/schema_dispatch
import oaspec/codegen/schema_utils
import oaspec/openapi/operations
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  BooleanSchema, Inline, IntegerSchema, NumberSchema, ObjectSchema, OneOfSchema,
  Reference, StringSchema,
}
import oaspec/openapi/spec.{type Resolved, Value}
import oaspec/util/http
import oaspec/util/naming
import oaspec/util/string_extra as se

/// Generate type definitions from OpenAPI schemas.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let types_content = generate_types(ctx)
  let request_types_content = generate_request_types(ctx)
  let response_types_content = generate_response_types(ctx)

  [
    GeneratedFile(
      path: "types.gleam",
      content: types_content,
      target: context.SharedTarget,
    ),
    GeneratedFile(
      path: "request_types.gleam",
      content: request_types_content,
      target: context.SharedTarget,
    ),
    GeneratedFile(
      path: "response_types.gleam",
      content: response_types_content,
      target: context.SharedTarget,
    ),
  ]
}

/// Generate types from component schemas and anonymous types from operations.
/// Delegates to the IR pipeline: build IR declarations, then render to source.
fn generate_types(ctx: Context) -> String {
  ir_build.build_types_module(ctx)
  |> ir_render.render()
}

/// Convert a SchemaRef to a qualified Gleam type string (with types. prefix).
/// Used in response_types and request_types where types are in a separate module.
fn schema_ref_to_type_qualified(
  ref: SchemaRef,
  op_id: String,
  suffix: String,
  ctx: Context,
) -> String {
  case ref {
    Inline(schema_obj) ->
      schema_to_gleam_type_qualified(schema_obj, op_id, suffix, ctx)
    Reference(name:, ..) -> {
      "types." <> naming.schema_to_type_name(name)
    }
  }
}

/// Convert a schema to a qualified Gleam type with types. prefix for compound types.
fn schema_to_gleam_type_qualified(
  schema_obj: SchemaObject,
  op_id: String,
  suffix: String,
  ctx: Context,
) -> String {
  case schema_obj {
    ArraySchema(items:, ..) ->
      case items {
        Reference(name:, ..) -> {
          "List(types." <> naming.schema_to_type_name(name) <> ")"
        }
        _ -> schema_to_gleam_type(schema_obj, ctx)
      }
    // Inline objects, oneOf, anyOf, allOf → reference the anonymous type
    ObjectSchema(..) -> {
      let type_name = naming.schema_to_type_name(op_id) <> suffix
      "types." <> type_name
    }
    OneOfSchema(schemas:, ..) -> {
      let all_refs =
        list.all(schemas, fn(s) {
          case s {
            Reference(..) -> True
            _ -> False
          }
        })
      case all_refs {
        True -> {
          let type_name = naming.schema_to_type_name(op_id) <> suffix
          "types." <> type_name
        }
        False -> schema_to_gleam_type(schema_obj, ctx)
      }
    }
    AnyOfSchema(schemas:, ..) -> {
      let all_refs =
        list.all(schemas, fn(s) {
          case s {
            Reference(..) -> True
            _ -> False
          }
        })
      case all_refs {
        True -> {
          let type_name = naming.schema_to_type_name(op_id) <> suffix
          "types." <> type_name
        }
        False -> schema_to_gleam_type(schema_obj, ctx)
      }
    }
    AllOfSchema(..) -> {
      let type_name = naming.schema_to_type_name(op_id) <> suffix
      "types." <> type_name
    }
    _ -> schema_to_gleam_type(schema_obj, ctx)
  }
}

/// Convert a SchemaRef to a Gleam type string.
pub fn schema_ref_to_type(ref: SchemaRef, _ctx: Context) -> String {
  case ref {
    Inline(schema) -> schema_dispatch.schema_type(schema)
    Reference(name:, ..) -> naming.schema_to_type_name(name)
  }
}

/// Convert a schema object to a Gleam type string.
/// Delegates to schema_dispatch for the centralized type mapping.
pub fn schema_to_gleam_type(schema: SchemaObject, _ctx: Context) -> String {
  schema_dispatch.schema_type(schema)
}

/// Generate request types for all operations.
fn generate_request_types(ctx: Context) -> String {
  let operations = operations.collect_operations(ctx)

  // Only import Option if any operation has optional parameters or optional body
  let needs_option =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      let has_optional_params =
        list.any(operation.parameters, fn(ref_p) {
          case ref_p {
            Value(p) -> !p.required
            _ -> False
          }
        })
      let has_optional_body = case operation.request_body {
        Some(Value(rb)) -> !rb.required
        _ -> False
      }
      has_optional_params || has_optional_body
    })

  // Check if types module is needed ($ref params or non-primitive body)
  let needs_types =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      let has_ref_params =
        list.any(operation.parameters, fn(ref_p) {
          case ref_p {
            Value(p) ->
              case p.payload {
                spec.ParameterSchema(Reference(..)) -> True
                _ -> False
              }
            _ -> False
          }
        })
      let has_typed_body = case operation.request_body {
        Some(Value(rb)) ->
          list.any(dict.to_list(rb.content), fn(ce) {
            let #(_, mt) = ce
            case mt.schema {
              Some(Reference(..)) -> True
              Some(Inline(schema.ObjectSchema(..))) -> True
              Some(Inline(schema.AllOfSchema(..))) -> True
              _ -> False
            }
          })
        _ -> False
      }
      has_ref_params || has_typed_body
    })

  let base_imports = case needs_types {
    True -> [ctx.config.package <> "/types"]
    False -> []
  }
  let imports = case needs_option {
    True -> ["gleam/option.{type Option}", ..base_imports]
    False -> base_imports
  }

  let sb =
    se.file_header(context.version)
    |> se.imports(imports)

  let sb =
    list.fold(operations, sb, fn(sb, op) {
      let #(op_id, operation, _path, _method) = op
      generate_request_type(sb, op_id, operation, ctx)
    })

  se.to_string(sb)
}

/// Generate a single request type for an operation.
fn generate_request_type(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation(Resolved),
  ctx: Context,
) -> se.StringBuilder {
  let type_name = naming.schema_to_type_name(op_id) <> "Request"

  let params = operation.parameters
  case list.is_empty(params) && option.is_none(operation.request_body) {
    True -> sb
    False -> {
      let sb = case operation.description {
        Some(desc) -> sb |> se.doc_comment(desc)
        None -> sb
      }
      let sb = sb |> se.line("pub type " <> type_name <> " {")
      let sb = sb |> se.indent(1, type_name <> "(")

      let sb =
        list.index_fold(params, sb, fn(sb, ref_p, idx) {
          case ref_p {
            Value(param) -> {
              let field_name = naming.to_snake_case(param.name)
              let field_type = case param.payload {
                spec.ParameterSchema(Inline(StringSchema(..))) -> "String"
                spec.ParameterSchema(Inline(IntegerSchema(..))) -> "Int"
                spec.ParameterSchema(Inline(NumberSchema(..))) -> "Float"
                spec.ParameterSchema(Inline(BooleanSchema(..))) -> "Bool"
                spec.ParameterSchema(Inline(ArraySchema(items:, ..))) -> {
                  let item_type = case items {
                    Inline(StringSchema(..)) -> "String"
                    Inline(IntegerSchema(..)) -> "Int"
                    Inline(NumberSchema(..)) -> "Float"
                    Inline(BooleanSchema(..)) -> "Bool"
                    Reference(name:, ..) -> naming.schema_to_type_name(name)
                    _ -> "String"
                  }
                  "List(" <> item_type <> ")"
                }
                spec.ParameterSchema(Reference(name:, ..)) ->
                  "types." <> naming.schema_to_type_name(name)
                _ -> "String"
              }
              let final_type = case param.required {
                True -> field_type
                False -> "Option(" <> field_type <> ")"
              }
              let has_more = idx < list.length(params) - 1
              let has_body = option.is_some(operation.request_body)
              let trailing = case has_more || has_body {
                True -> ","
                False -> ""
              }
              sb |> se.indent(2, field_name <> ": " <> final_type <> trailing)
            }
            _ -> sb
          }
        })

      let sb = case operation.request_body {
        Some(Value(rb)) -> {
          let body_type = extract_request_body_type(rb, op_id, ctx)
          let wrapped = case rb.required {
            True -> body_type
            False -> "Option(" <> body_type <> ")"
          }
          sb |> se.indent(2, "body: " <> wrapped)
        }
        _ -> sb
      }

      sb
      |> se.indent(1, ")")
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Check if any response variant references the types module.
fn responses_need_types_import(
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
  _ctx: Context,
) -> Bool {
  list.any(operations, fn(op) {
    let #(_op_id, operation, _path, _method) = op
    let responses = dict.to_list(operation.responses)
    list.any(responses, fn(entry) {
      let #(_status_code, ref_or) = entry
      case ref_or {
        Value(response) -> {
          let content_entries = dict.to_list(response.content)
          case content_entries {
            [] -> False
            [_, _, ..] -> False
            [#(media_type_name, media_type)] ->
              case media_type_name {
                "text/plain"
                | "application/xml"
                | "text/xml"
                | "application/octet-stream" -> False
                _ ->
                  case media_type.schema {
                    Some(Reference(..)) -> True
                    Some(Inline(ArraySchema(items: Reference(..), ..))) -> True
                    Some(Inline(ObjectSchema(..))) -> True
                    Some(Inline(OneOfSchema(..))) -> True
                    Some(Inline(AnyOfSchema(..))) -> True
                    Some(Inline(AllOfSchema(..))) -> True
                    _ -> False
                  }
              }
          }
        }
        _ -> False
      }
    })
  })
}

/// Generate response types for all operations.
fn generate_response_types(ctx: Context) -> String {
  let operations = operations.collect_operations(ctx)
  let needs_types = responses_need_types_import(operations, ctx)
  let imports = case needs_types {
    True -> [ctx.config.package <> "/types"]
    False -> []
  }
  let sb =
    se.file_header(context.version)
    |> se.imports(imports)

  let sb =
    list.fold(operations, sb, fn(sb, op) {
      let #(op_id, operation, _path, _method) = op
      generate_response_type(sb, op_id, operation, ctx)
    })

  se.to_string(sb)
}

/// Generate a response type for an operation.
fn generate_response_type(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation(Resolved),
  ctx: Context,
) -> se.StringBuilder {
  let type_name = naming.schema_to_type_name(op_id) <> "Response"
  let responses = http.sort_response_entries(dict.to_list(operation.responses))

  case list.is_empty(responses) {
    True -> sb
    False -> {
      let sb = sb |> se.line("pub type " <> type_name <> " {")

      let sb =
        list.fold(responses, sb, fn(sb, entry) {
          let #(status_code, ref_or) = entry
          case ref_or {
            Value(response) -> {
              let variant_name = status_code_to_variant(status_code, type_name)
              let content_entries = ir_build.sorted_entries(response.content)

              case content_entries {
                [] -> sb |> se.indent(1, variant_name)
                // Multiple content types: use String to stay type-safe
                // since different media types may decode to different Gleam types
                [_, _, ..] -> sb |> se.indent(1, variant_name <> "(String)")
                [#(media_type_name, media_type)] ->
                  case media_type_name {
                    // text/plain, XML, octet-stream: always use String type
                    "text/plain"
                    | "application/xml"
                    | "text/xml"
                    | "application/octet-stream" ->
                      case media_type.schema {
                        Some(_) ->
                          sb
                          |> se.indent(1, variant_name <> "(String)")
                        None -> sb |> se.indent(1, variant_name)
                      }
                    // JSON and other content types use schema-derived type
                    _ ->
                      case media_type.schema {
                        Some(ref) -> {
                          let suffix =
                            "Response" <> http.status_code_suffix(status_code)
                          let inner_type =
                            schema_ref_to_type_qualified(
                              ref,
                              op_id,
                              suffix,
                              ctx,
                            )
                          sb
                          |> se.indent(
                            1,
                            variant_name <> "(" <> inner_type <> ")",
                          )
                        }
                        None -> sb |> se.indent(1, variant_name)
                      }
                  }
              }
            }
            _ -> sb
          }
        })

      sb
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Convert an HTTP status code to a Gleam variant name.
/// Prefixed with the type name to avoid duplicate constructors across types.
fn status_code_to_variant(
  code: http.HttpStatusCode,
  type_name: String,
) -> String {
  type_name <> http.status_code_suffix(code)
}

/// Result of merging allOf sub-schemas.
/// Re-export from allof_merge for backward compatibility.
pub type MergedAllOf =
  allof_merge.MergedAllOf

/// Re-export merge_allof_schemas.
pub fn merge_allof_schemas(
  schemas: List(SchemaRef),
  ctx: Context,
) -> MergedAllOf {
  allof_merge.merge_allof_schemas(schemas, ctx)
}

/// Check if a schema has typed or untyped additionalProperties that would need Dict.
pub fn schema_has_additional_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  schema_utils.schema_has_additional_properties(schema_ref, ctx)
}

/// Check if a schema has untyped additionalProperties (needs Dynamic import).
pub fn schema_has_untyped_additional_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  schema_utils.schema_has_untyped_additional_properties(schema_ref, ctx)
}

/// Check if a schema has any optional or nullable fields that would need Option.
pub fn schema_has_optional_fields(schema_ref: SchemaRef, ctx: Context) -> Bool {
  schema_utils.schema_has_optional_fields(schema_ref, ctx)
}

/// Check if a SchemaRef has readOnly metadata, resolving $ref if needed.
pub fn schema_ref_is_read_only(ref: SchemaRef, ctx: Context) -> Bool {
  schema_utils.schema_ref_is_read_only(ref, ctx)
}

/// Check if a SchemaRef has writeOnly metadata, resolving $ref if needed.
pub fn schema_ref_is_write_only(ref: SchemaRef, ctx: Context) -> Bool {
  schema_utils.schema_ref_is_write_only(ref, ctx)
}

/// Filter readOnly properties from an ObjectSchema for request body context.
/// Returns a new schema with readOnly properties removed.
pub fn filter_read_only_properties(
  schema_obj: SchemaObject,
  ctx: Context,
) -> SchemaObject {
  schema_utils.filter_read_only_properties(schema_obj, ctx)
}

/// Filter writeOnly properties from an ObjectSchema for response body context.
/// Returns a new schema with writeOnly properties removed.
pub fn filter_write_only_properties(
  schema_obj: SchemaObject,
  ctx: Context,
) -> SchemaObject {
  schema_utils.filter_write_only_properties(schema_obj, ctx)
}

/// Extract the Gleam type for a request body from its content media types.
/// Uses types. prefix since request body schemas live in the types module.
fn extract_request_body_type(
  rb: spec.RequestBody(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  let content_entries = ir_build.sorted_entries(rb.content)
  case content_entries {
    [#(_media_type, media_type), ..] ->
      case media_type.schema {
        Some(Reference(name:, ..)) ->
          "types." <> naming.schema_to_type_name(name)
        Some(Inline(schema_obj)) ->
          extract_inline_request_body_type(schema_obj, op_id, ctx)
        _ -> "String"
      }
    [] -> "String"
  }
}

/// Extract the type for an inline request body schema.
fn extract_inline_request_body_type(
  schema_obj: SchemaObject,
  op_id: String,
  ctx: Context,
) -> String {
  case schema_obj {
    ObjectSchema(..) -> {
      let type_name = naming.schema_to_type_name(op_id) <> "RequestBody"
      "types." <> type_name
    }
    AllOfSchema(..) -> {
      let type_name = naming.schema_to_type_name(op_id) <> "RequestBody"
      "types." <> type_name
    }
    StringSchema(..) -> "String"
    IntegerSchema(..) -> "Int"
    NumberSchema(..) -> "Float"
    BooleanSchema(..) -> "Bool"
    _ -> schema_to_gleam_type(schema_obj, ctx)
  }
}
