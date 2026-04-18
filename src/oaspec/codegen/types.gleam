import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import oaspec/codegen/allof_merge
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/ir_build
import oaspec/codegen/ir_render
import oaspec/codegen/schema_dispatch
import oaspec/codegen/schema_utils
import oaspec/config
import oaspec/openapi/operations
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  Inline, ObjectSchema, OneOfSchema, Reference,
}
import oaspec/openapi/spec.{type Resolved, Value}
import oaspec/util/content_type
import oaspec/util/http
import oaspec/util/naming
import oaspec/util/string_extra as se

/// Generate type definitions from OpenAPI schemas.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let operations = operations.collect_operations(ctx)
  let types_content = generate_types(ctx)
  let request_types_content = generate_request_types(ctx, operations)
  let response_types_content = generate_response_types(ctx, operations)

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

/// Generate request types for all operations via the IR pipeline.
/// Shape of each RecordType matches the former string-builder output;
/// `gleam format` normalizes whitespace either way so the final on-disk
/// content is unchanged.
fn generate_request_types(
  ctx: Context,
  _operations: List(
    #(String, spec.Operation(Resolved), String, spec.HttpMethod),
  ),
) -> String {
  ir_build.build_request_types_module(ctx)
  |> ir_render.render()
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
              case content_type.from_string(media_type_name) {
                content_type.TextPlain
                | content_type.ApplicationXml
                | content_type.TextXml
                | content_type.ApplicationOctetStream -> False
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
fn generate_response_types(
  ctx: Context,
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> String {
  let needs_types = responses_need_types_import(operations, ctx)
  let imports = case needs_types {
    True -> [config.package(context.config(ctx)) <> "/types"]
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
                  case content_type.from_string(media_type_name) {
                    // text/plain, XML, octet-stream: always use String type
                    content_type.TextPlain
                    | content_type.ApplicationXml
                    | content_type.TextXml
                    | content_type.ApplicationOctetStream ->
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
