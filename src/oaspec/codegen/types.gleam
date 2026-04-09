import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/ir_build
import oaspec/codegen/ir_render
import oaspec/codegen/schema_dispatch
import oaspec/openapi/resolver
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  BooleanSchema, Inline, IntegerSchema, NumberSchema, ObjectSchema, OneOfSchema,
  Reference, StringSchema,
}
import oaspec/openapi/spec
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
  let operations = collect_operations(ctx)

  // Only import Option if any operation has optional parameters or optional body
  let needs_option =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      let has_optional_params =
        list.any(operation.parameters, fn(p) { !p.required })
      let has_optional_body = case operation.request_body {
        Some(rb) -> !rb.required
        _ -> False
      }
      has_optional_params || has_optional_body
    })

  // Check if types module is needed ($ref params or non-primitive body)
  let needs_types =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      let has_ref_params =
        list.any(operation.parameters, fn(p) {
          case p.schema {
            Some(Reference(..)) -> True
            _ -> False
          }
        })
      let has_typed_body = case operation.request_body {
        Some(rb) ->
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
  operation: spec.Operation,
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
        list.index_fold(params, sb, fn(sb, param, idx) {
          let field_name = naming.to_snake_case(param.name)
          let field_type = case param.schema {
            Some(Inline(StringSchema(..))) -> "String"
            Some(Inline(IntegerSchema(..))) -> "Int"
            Some(Inline(NumberSchema(..))) -> "Float"
            Some(Inline(BooleanSchema(..))) -> "Bool"
            Some(Inline(ArraySchema(items:, ..))) -> {
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
            Some(Reference(name:, ..)) ->
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
        })

      let sb = case operation.request_body {
        Some(rb) -> {
          let body_type = extract_request_body_type(rb, op_id, ctx)
          let wrapped = case rb.required {
            True -> body_type
            False -> "Option(" <> body_type <> ")"
          }
          sb |> se.indent(2, "body: " <> wrapped)
        }
        None -> sb
      }

      sb
      |> se.indent(1, ")")
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Generate response types for all operations.
fn generate_response_types(ctx: Context) -> String {
  let sb =
    se.file_header(context.version)
    |> se.imports([ctx.config.package <> "/types"])

  let operations = collect_operations(ctx)

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
  operation: spec.Operation,
  ctx: Context,
) -> se.StringBuilder {
  let type_name = naming.schema_to_type_name(op_id) <> "Response"
  let responses = dict.to_list(operation.responses)

  case list.is_empty(responses) {
    True -> sb
    False -> {
      let sb = sb |> se.line("pub type " <> type_name <> " {")

      let sb =
        list.fold(responses, sb, fn(sb, entry) {
          let #(status_code, response) = entry
          let variant_name = status_code_to_variant(status_code, type_name)
          let content_entries = dict.to_list(response.content)

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
                        schema_ref_to_type_qualified(ref, op_id, suffix, ctx)
                      sb
                      |> se.indent(1, variant_name <> "(" <> inner_type <> ")")
                    }
                    None -> sb |> se.indent(1, variant_name)
                  }
              }
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
fn status_code_to_variant(code: String, type_name: String) -> String {
  type_name <> http.status_code_suffix(code)
}

/// Result of merging allOf sub-schemas.
pub type MergedAllOf {
  MergedAllOf(
    properties: dict.Dict(String, SchemaRef),
    required: List(String),
    additional_properties: Option(SchemaRef),
    additional_properties_untyped: Bool,
  )
}

/// Merge allOf sub-schemas: properties, required, and additionalProperties.
/// Non-object sub-schemas (primitives, arrays) are included as a synthetic
/// "value" property to preserve their constraints.
pub fn merge_allof_schemas(
  schemas: List(SchemaRef),
  ctx: Context,
) -> MergedAllOf {
  list.index_fold(
    schemas,
    MergedAllOf(
      properties: dict.new(),
      required: [],
      additional_properties: None,
      additional_properties_untyped: False,
    ),
    fn(acc, s_ref, idx) {
      let resolved = case s_ref {
        Inline(obj) -> Ok(obj)
        Reference(..) -> resolver.resolve_schema_ref(s_ref, ctx.spec)
      }
      case resolved {
        Ok(ObjectSchema(
          properties:,
          required:,
          additional_properties:,
          additional_properties_untyped:,
          ..,
        )) -> {
          let merged_ap = case
            acc.additional_properties,
            additional_properties
          {
            None, ap -> ap
            existing, _ -> existing
          }
          let merged_ap_untyped =
            acc.additional_properties_untyped || additional_properties_untyped
          MergedAllOf(
            properties: dict.merge(acc.properties, properties),
            required: list.append(acc.required, required),
            additional_properties: merged_ap,
            additional_properties_untyped: merged_ap_untyped,
          )
        }
        // Non-object sub-schemas: add as a synthetic "value" field
        Ok(schema_obj) -> {
          let field_name = case idx {
            0 -> "value"
            n -> "value_" <> int.to_string(n)
          }
          MergedAllOf(
            ..acc,
            properties: dict.insert(
              acc.properties,
              field_name,
              Inline(schema_obj),
            ),
            required: [field_name, ..acc.required],
          )
        }
        _ -> acc
      }
    },
  )
}

/// Collect all operations from the spec with their IDs, paths, and methods.
pub fn collect_operations(
  ctx: Context,
) -> List(#(String, spec.Operation, String, spec.HttpMethod)) {
  let paths =
    list.sort(dict.to_list(ctx.spec.paths), fn(a, b) {
      string.compare(a.0, b.0)
    })
  list.flat_map(paths, fn(entry) {
    let #(path, path_item) = entry
    let ops = [
      #(path_item.get, spec.Get),
      #(path_item.post, spec.Post),
      #(path_item.put, spec.Put),
      #(path_item.delete, spec.Delete),
      #(path_item.patch, spec.Patch),
      #(path_item.head, spec.Head),
      #(path_item.options, spec.Options),
      #(path_item.trace, spec.Trace),
    ]
    list.filter_map(ops, fn(op_entry) {
      let #(maybe_op, method) = op_entry
      case maybe_op {
        Some(operation) -> {
          // Merge path-level parameters with operation parameters.
          // Operation params take precedence by (name, in) key per OpenAPI spec.
          let op_param_keys =
            list.map(operation.parameters, fn(p) { #(p.name, p.in_) })
          let inherited_params =
            list.filter(path_item.parameters, fn(p) {
              !list.contains(op_param_keys, #(p.name, p.in_))
            })
          let merged_params =
            list.append(inherited_params, operation.parameters)
          // Inherit top-level security if operation doesn't define its own.
          // operation.security = None → inherit, Some([]) → no security,
          // Some([...]) → use operation-level.
          let effective_security = case operation.security {
            Some(sec) -> sec
            None -> ctx.spec.security
          }
          let operation =
            spec.Operation(
              ..operation,
              parameters: merged_params,
              security: Some(effective_security),
            )

          let op_id = case operation.operation_id {
            Some(id) -> id
            None ->
              spec.method_to_lower(method)
              <> "_"
              <> string.replace(path, "/", "_")
              |> string.replace("{", "")
              |> string.replace("}", "")
          }
          Ok(#(op_id, operation, path, method))
        }
        None -> Error(Nil)
      }
    })
  })
}

/// Check if a schema has typed or untyped additionalProperties that would need Dict.
pub fn schema_has_additional_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  case schema_ref {
    Inline(ObjectSchema(additional_properties: Some(_), ..)) -> True
    Inline(ObjectSchema(additional_properties_untyped: True, ..)) -> True
    Inline(AllOfSchema(schemas:, ..)) ->
      list.any(schemas, fn(s) { schema_has_additional_properties(s, ctx) })
    Reference(..) ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(schema_obj) ->
          schema_has_additional_properties(Inline(schema_obj), ctx)
        Error(_) -> False
      }
    _ -> False
  }
}

/// Check if a schema has untyped additionalProperties (needs Dynamic import).
pub fn schema_has_untyped_additional_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  case schema_ref {
    Inline(ObjectSchema(additional_properties_untyped: True, ..)) -> True
    Inline(AllOfSchema(schemas:, ..)) ->
      list.any(schemas, fn(s) {
        schema_has_untyped_additional_properties(s, ctx)
      })
    Reference(..) ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(schema_obj) ->
          schema_has_untyped_additional_properties(Inline(schema_obj), ctx)
        Error(_) -> False
      }
    _ -> False
  }
}

/// Check if a schema has any optional or nullable fields that would need Option.
pub fn schema_has_optional_fields(schema_ref: SchemaRef, ctx: Context) -> Bool {
  case schema_ref {
    Inline(ObjectSchema(properties:, required:, ..)) -> {
      let has_optional =
        dict.to_list(properties)
        |> list.any(fn(entry) {
          let #(prop_name, prop_ref) = entry
          !list.contains(required, prop_name)
          || schema_ref_is_nullable(prop_ref, ctx)
        })
      has_optional
    }
    Inline(AllOfSchema(schemas:, ..)) ->
      list.any(schemas, fn(s) { schema_has_optional_fields(s, ctx) })
    Reference(..) ->
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
        Ok(schema_obj) -> schema_has_optional_fields(Inline(schema_obj), ctx)
        Error(_) -> False
      }
    _ -> False
  }
}

/// Check if a SchemaRef is nullable, resolving $ref if needed.
fn schema_ref_is_nullable(ref: SchemaRef, ctx: Context) -> Bool {
  case ref {
    Inline(s) -> schema.is_nullable(s)
    Reference(..) ->
      case resolver.resolve_schema_ref(ref, ctx.spec) {
        Ok(s) -> schema.is_nullable(s)
        Error(_) -> False
      }
  }
}

/// Check if a SchemaRef has readOnly metadata, resolving $ref if needed.
pub fn schema_ref_is_read_only(ref: SchemaRef, ctx: Context) -> Bool {
  case ref {
    Inline(s) -> schema.get_metadata(s).read_only
    Reference(..) ->
      case resolver.resolve_schema_ref(ref, ctx.spec) {
        Ok(s) -> schema.get_metadata(s).read_only
        Error(_) -> False
      }
  }
}

/// Check if a SchemaRef has writeOnly metadata, resolving $ref if needed.
pub fn schema_ref_is_write_only(ref: SchemaRef, ctx: Context) -> Bool {
  case ref {
    Inline(s) -> schema.get_metadata(s).write_only
    Reference(..) ->
      case resolver.resolve_schema_ref(ref, ctx.spec) {
        Ok(s) -> schema.get_metadata(s).write_only
        Error(_) -> False
      }
  }
}

/// Filter readOnly properties from an ObjectSchema for request body context.
/// Returns a new schema with readOnly properties removed.
pub fn filter_read_only_properties(
  schema_obj: SchemaObject,
  ctx: Context,
) -> SchemaObject {
  case schema_obj {
    ObjectSchema(
      metadata:,
      properties:,
      required:,
      additional_properties:,
      additional_properties_untyped:,
      min_properties:,
      max_properties:,
    ) -> {
      let filtered_props =
        dict.filter(properties, fn(_name, prop_ref) {
          !schema_ref_is_read_only(prop_ref, ctx)
        })
      let filtered_required =
        list.filter(required, fn(name) {
          case dict.get(filtered_props, name) {
            Ok(_) -> True
            Error(_) -> False
          }
        })
      ObjectSchema(
        metadata:,
        properties: filtered_props,
        required: filtered_required,
        additional_properties:,
        additional_properties_untyped:,
        min_properties:,
        max_properties:,
      )
    }
    _ -> schema_obj
  }
}

/// Filter writeOnly properties from an ObjectSchema for response body context.
/// Returns a new schema with writeOnly properties removed.
pub fn filter_write_only_properties(
  schema_obj: SchemaObject,
  ctx: Context,
) -> SchemaObject {
  case schema_obj {
    ObjectSchema(
      metadata:,
      properties:,
      required:,
      additional_properties:,
      additional_properties_untyped:,
      min_properties:,
      max_properties:,
    ) -> {
      let filtered_props =
        dict.filter(properties, fn(_name, prop_ref) {
          !schema_ref_is_write_only(prop_ref, ctx)
        })
      let filtered_required =
        list.filter(required, fn(name) {
          case dict.get(filtered_props, name) {
            Ok(_) -> True
            Error(_) -> False
          }
        })
      ObjectSchema(
        metadata:,
        properties: filtered_props,
        required: filtered_required,
        additional_properties:,
        additional_properties_untyped:,
        min_properties:,
        max_properties:,
      )
    }
    _ -> schema_obj
  }
}

/// Extract the Gleam type for a request body from its content media types.
/// Uses types. prefix since request body schemas live in the types module.
fn extract_request_body_type(
  rb: spec.RequestBody,
  op_id: String,
  ctx: Context,
) -> String {
  let content_entries = dict.to_list(rb.content)
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
