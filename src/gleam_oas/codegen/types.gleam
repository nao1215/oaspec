import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_oas/codegen/context.{
  type Context, type GeneratedFile, GeneratedFile,
}
import gleam_oas/openapi/resolver
import gleam_oas/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  BooleanSchema, Inline, IntegerSchema, NumberSchema, ObjectSchema, OneOfSchema,
  Reference, StringSchema,
}
import gleam_oas/openapi/spec
import gleam_oas/util/naming
import gleam_oas/util/string_extra as se

/// Generate type definitions from OpenAPI schemas.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let types_content = generate_types(ctx)
  let request_types_content = generate_request_types(ctx)
  let response_types_content = generate_response_types(ctx)

  [
    GeneratedFile(path: "types.gleam", content: types_content),
    GeneratedFile(path: "request_types.gleam", content: request_types_content),
    GeneratedFile(path: "response_types.gleam", content: response_types_content),
  ]
}

/// Generate types from component schemas.
fn generate_types(ctx: Context) -> String {
  let sb =
    se.file_header(context.version)
    |> se.imports([
      "gleam/option.{type Option}",
    ])

  let schemas = case ctx.spec.components {
    Some(components) -> dict.to_list(components.schemas)
    None -> []
  }

  let sb =
    list.fold(schemas, sb, fn(sb, entry) {
      let #(name, schema_ref) = entry
      generate_type_def(sb, name, schema_ref, ctx)
    })

  se.to_string(sb)
}

/// Generate a single type definition.
fn generate_type_def(
  sb: se.StringBuilder,
  name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> se.StringBuilder {
  let type_name = naming.schema_to_type_name(name)

  case schema_ref {
    Inline(schema) -> generate_schema_type(sb, type_name, schema, ctx)
    Reference(ref:) -> {
      let resolved_name = resolver.ref_to_name(ref)
      let resolved_type = naming.schema_to_type_name(resolved_name)
      sb
      |> se.line("pub type " <> type_name <> " = " <> resolved_type)
      |> se.blank_line()
    }
  }
}

/// Generate a type from a schema object.
fn generate_schema_type(
  sb: se.StringBuilder,
  type_name: String,
  schema: SchemaObject,
  ctx: Context,
) -> se.StringBuilder {
  case schema {
    ObjectSchema(description:, properties:, required:, ..) -> {
      let sb = maybe_doc_comment(sb, description)
      let sb = sb |> se.line("pub type " <> type_name <> " {")
      let sb = sb |> se.indent(1, type_name <> "(")

      let props = dict.to_list(properties)
      let sb =
        list.index_fold(props, sb, fn(sb, entry, idx) {
          let #(prop_name, prop_ref) = entry
          let field_name = naming.to_snake_case(prop_name)
          let field_type = schema_ref_to_type(prop_ref, ctx)
          let is_required = list.contains(required, prop_name)
          let is_already_optional = schema_ref_is_nullable(prop_ref)
          // Avoid Option(Option(T)): if schema is nullable, type is
          // already Option(T), so don't wrap again for optional fields.
          let final_type = case is_required, is_already_optional {
            True, _ -> field_type
            False, True -> field_type
            False, False -> "Option(" <> field_type <> ")"
          }
          let trailing = case idx == list.length(props) - 1 {
            True -> ""
            False -> ","
          }
          sb |> se.indent(2, field_name <> ": " <> final_type <> trailing)
        })

      sb
      |> se.indent(1, ")")
      |> se.line("}")
      |> se.blank_line()
    }

    StringSchema(description:, enum_values:, ..) if enum_values != [] -> {
      let sb = maybe_doc_comment(sb, description)
      let sb = sb |> se.line("pub type " <> type_name <> " {")
      let sb =
        list.fold(enum_values, sb, fn(sb, value) {
          let variant_name =
            naming.schema_to_type_name(type_name <> "_" <> value)
          sb |> se.indent(1, variant_name)
        })
      sb
      |> se.line("}")
      |> se.blank_line()
    }

    OneOfSchema(description:, schemas:, ..) -> {
      let sb = maybe_doc_comment(sb, description)
      let sb = sb |> se.line("pub type " <> type_name <> " {")
      let sb =
        list.fold(schemas, sb, fn(sb, s_ref) {
          let variant_type = schema_ref_to_type(s_ref, ctx)
          let variant_name = type_name <> variant_type
          sb |> se.indent(1, variant_name <> "(" <> variant_type <> ")")
        })
      sb
      |> se.line("}")
      |> se.blank_line()
    }

    AllOfSchema(description:, schemas:) -> {
      // Merge all properties into a single object type
      let sb = maybe_doc_comment(sb, description)
      let merged_props =
        list.fold(schemas, dict.new(), fn(acc, s_ref) {
          case s_ref {
            Inline(ObjectSchema(properties:, ..)) -> dict.merge(acc, properties)
            Reference(_) -> {
              case resolver.resolve_schema_ref(s_ref, ctx.spec) {
                Ok(ObjectSchema(properties:, ..)) -> dict.merge(acc, properties)
                _ -> acc
              }
            }
            _ -> acc
          }
        })
      let merged_required =
        list.flat_map(schemas, fn(s_ref) {
          case s_ref {
            Inline(ObjectSchema(required:, ..)) -> required
            Reference(_) ->
              case resolver.resolve_schema_ref(s_ref, ctx.spec) {
                Ok(ObjectSchema(required:, ..)) -> required
                _ -> []
              }
            _ -> []
          }
        })

      let merged_schema =
        ObjectSchema(
          description:,
          properties: merged_props,
          required: merged_required,
          additional_properties: None,
          nullable: False,
        )
      generate_schema_type(sb, type_name, merged_schema, ctx)
    }

    _ -> {
      // Simple type alias
      let gleam_type = schema_to_gleam_type(schema, ctx)
      sb
      |> se.line("pub type " <> type_name <> " = " <> gleam_type)
      |> se.blank_line()
    }
  }
}

/// Convert a SchemaRef to a qualified Gleam type string (with types. prefix).
/// Used in response_types and request_types where types are in a separate module.
fn schema_ref_to_type_qualified(ref: SchemaRef, ctx: Context) -> String {
  case ref {
    Inline(schema) -> schema_to_gleam_type_qualified(schema, ctx)
    Reference(ref:) -> {
      let name = resolver.ref_to_name(ref)
      "types." <> naming.schema_to_type_name(name)
    }
  }
}

/// Convert a schema to a qualified Gleam type with types. prefix for compound types.
fn schema_to_gleam_type_qualified(schema: SchemaObject, ctx: Context) -> String {
  case schema {
    ArraySchema(items:, ..) ->
      case items {
        Reference(ref:) -> {
          let name = resolver.ref_to_name(ref)
          "List(types." <> naming.schema_to_type_name(name) <> ")"
        }
        _ -> schema_to_gleam_type(schema, ctx)
      }
    _ -> schema_to_gleam_type(schema, ctx)
  }
}

/// Convert a SchemaRef to a Gleam type string.
pub fn schema_ref_to_type(ref: SchemaRef, ctx: Context) -> String {
  case ref {
    Inline(schema) -> schema_to_gleam_type(schema, ctx)
    Reference(ref:) -> {
      let name = resolver.ref_to_name(ref)
      naming.schema_to_type_name(name)
    }
  }
}

/// Convert a schema object to a Gleam type string.
pub fn schema_to_gleam_type(schema: SchemaObject, _ctx: Context) -> String {
  let base_type = case schema {
    StringSchema(..) -> "String"
    IntegerSchema(..) -> "Int"
    NumberSchema(..) -> "Float"
    BooleanSchema(..) -> "Bool"
    ArraySchema(items:, ..) ->
      case items {
        Reference(ref:) -> {
          let name = resolver.ref_to_name(ref)
          "List(" <> naming.schema_to_type_name(name) <> ")"
        }
        Inline(inner) -> {
          let inner_type = case inner {
            StringSchema(..) -> "String"
            IntegerSchema(..) -> "Int"
            NumberSchema(..) -> "Float"
            BooleanSchema(..) -> "Bool"
            _ -> "String"
          }
          "List(" <> inner_type <> ")"
        }
      }
    ObjectSchema(..) -> "String"
    AllOfSchema(..) -> "String"
    OneOfSchema(..) -> "String"
    AnyOfSchema(..) -> "String"
  }

  case schema.is_nullable(schema) {
    True -> "Option(" <> base_type <> ")"
    False -> base_type
  }
}

/// Generate request types for all operations.
fn generate_request_types(ctx: Context) -> String {
  let sb =
    se.file_header(context.version)
    |> se.imports([
      "gleam/option.{type Option}",
      ctx.config.package <> "/types",
    ])

  let operations = collect_operations(ctx)

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
  _ctx: Context,
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
            Some(Reference(ref:)) ->
              naming.schema_to_type_name(resolver.ref_to_name(ref))
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
          let body_type = extract_request_body_type(rb)
          sb |> se.indent(2, "body: " <> body_type)
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
            [#(_media_type, media_type), ..] ->
              case media_type.schema {
                Some(ref) -> {
                  let inner_type = schema_ref_to_type_qualified(ref, ctx)
                  sb
                  |> se.indent(1, variant_name <> "(" <> inner_type <> ")")
                }
                None -> sb |> se.indent(1, variant_name)
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
  let suffix = case code {
    "200" -> "Ok"
    "201" -> "Created"
    "204" -> "NoContent"
    "400" -> "BadRequest"
    "401" -> "Unauthorized"
    "403" -> "Forbidden"
    "404" -> "NotFound"
    "409" -> "Conflict"
    "422" -> "UnprocessableEntity"
    "500" -> "InternalServerError"
    "default" -> "Default"
    other -> "Status" <> other
  }
  type_name <> suffix
}

/// Collect all operations from the spec with their IDs, paths, and methods.
pub fn collect_operations(
  ctx: Context,
) -> List(#(String, spec.Operation, String, spec.HttpMethod)) {
  let paths = dict.to_list(ctx.spec.paths)
  list.flat_map(paths, fn(entry) {
    let #(path, path_item) = entry
    let ops = [
      #(path_item.get, spec.Get),
      #(path_item.post, spec.Post),
      #(path_item.put, spec.Put),
      #(path_item.delete, spec.Delete),
      #(path_item.patch, spec.Patch),
    ]
    list.filter_map(ops, fn(op_entry) {
      let #(maybe_op, method) = op_entry
      case maybe_op {
        Some(operation) -> {
          // Merge path-level parameters with operation parameters.
          // Operation params take precedence (by name) over path-level ones.
          let op_param_names = list.map(operation.parameters, fn(p) { p.name })
          let inherited_params =
            list.filter(path_item.parameters, fn(p) {
              !list.contains(op_param_names, p.name)
            })
          let merged_params =
            list.append(inherited_params, operation.parameters)
          let operation = spec.Operation(..operation, parameters: merged_params)

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

/// Check if a SchemaRef is nullable (avoids wrapping in Option twice).
fn schema_ref_is_nullable(ref: SchemaRef) -> Bool {
  case ref {
    Inline(s) -> schema.is_nullable(s)
    Reference(_) -> False
  }
}

/// Extract the Gleam type for a request body from its content media types.
/// Uses types. prefix since request body schemas live in the types module.
fn extract_request_body_type(rb: spec.RequestBody) -> String {
  let content_entries = dict.to_list(rb.content)
  case content_entries {
    [#(_media_type, media_type), ..] ->
      case media_type.schema {
        Some(Reference(ref:)) ->
          "types." <> naming.schema_to_type_name(resolver.ref_to_name(ref))
        Some(Inline(ObjectSchema(..))) -> "String"
        Some(Inline(StringSchema(..))) -> "String"
        Some(Inline(IntegerSchema(..))) -> "Int"
        Some(Inline(NumberSchema(..))) -> "Float"
        Some(Inline(BooleanSchema(..))) -> "Bool"
        _ -> "String"
      }
    [] -> "String"
  }
}

/// Add a doc comment if description is present.
fn maybe_doc_comment(
  sb: se.StringBuilder,
  description: Option(String),
) -> se.StringBuilder {
  case description {
    Some(desc) -> sb |> se.doc_comment(desc)
    None -> sb
  }
}
