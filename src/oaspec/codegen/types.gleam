import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
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
    GeneratedFile(path: "types.gleam", content: types_content),
    GeneratedFile(path: "request_types.gleam", content: request_types_content),
    GeneratedFile(path: "response_types.gleam", content: response_types_content),
  ]
}

/// Generate types from component schemas and anonymous types from operations.
fn generate_types(ctx: Context) -> String {
  // Generate component schema types
  let schemas = case ctx.spec.components {
    Some(components) ->
      list.sort(dict.to_list(components.schemas), fn(a, b) {
        string.compare(a.0, b.0)
      })
    None -> []
  }

  // Check if Option is needed (any optional/nullable fields)
  let needs_option =
    list.any(schemas, fn(entry) {
      let #(_, schema_ref) = entry
      schema_has_optional_fields(schema_ref, ctx)
    })

  // Check if Dict is needed (any schema with typed or untyped additionalProperties)
  let needs_dict =
    list.any(schemas, fn(entry) {
      let #(_, schema_ref) = entry
      schema_has_additional_properties(schema_ref, ctx)
    })

  // Check if Dynamic is needed (any schema with untyped additionalProperties)
  let needs_dynamic =
    list.any(schemas, fn(entry) {
      let #(_, schema_ref) = entry
      schema_has_untyped_additional_properties(schema_ref, ctx)
    })

  let imports = case needs_option, needs_dict, needs_dynamic {
    True, True, True -> [
      "gleam/dict.{type Dict}",
      "gleam/dynamic.{type Dynamic}",
      "gleam/option.{type Option}",
    ]
    True, True, False -> [
      "gleam/dict.{type Dict}",
      "gleam/option.{type Option}",
    ]
    True, False, _ -> ["gleam/option.{type Option}"]
    False, True, True -> [
      "gleam/dict.{type Dict}",
      "gleam/dynamic.{type Dynamic}",
    ]
    False, True, False -> ["gleam/dict.{type Dict}"]
    False, False, _ -> []
  }

  let sb =
    se.file_header(context.version)
    |> se.imports(imports)

  // First pass: collect inline enum types from object properties
  let sb =
    list.fold(schemas, sb, fn(sb, entry) {
      let #(name, schema_ref) = entry
      generate_inline_enums_for_schema(sb, name, schema_ref, ctx)
    })

  // Second pass: generate the main types
  let sb =
    list.fold(schemas, sb, fn(sb, entry) {
      let #(name, schema_ref) = entry
      generate_type_def(sb, name, schema_ref, ctx)
    })

  // Generate anonymous types from operations (inline response/request schemas)
  let sb = generate_anonymous_types(sb, ctx)

  se.to_string(sb)
}

/// Generate inline enum types found in object schema properties.
/// These are generated as separate types before the parent type.
fn generate_inline_enums_for_schema(
  sb: se.StringBuilder,
  parent_name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> se.StringBuilder {
  case schema_ref {
    Inline(ObjectSchema(properties:, ..)) ->
      generate_inline_enums_from_properties(sb, parent_name, properties, ctx)
    Inline(AllOfSchema(schemas:, ..)) -> {
      // Merge properties from allOf to find inline enums
      let merged_props =
        list.fold(schemas, dict.new(), fn(acc, s_ref) {
          case s_ref {
            Inline(ObjectSchema(properties:, ..)) -> dict.merge(acc, properties)
            Reference(_) ->
              case resolver.resolve_schema_ref(s_ref, ctx.spec) {
                Ok(ObjectSchema(properties:, ..)) -> dict.merge(acc, properties)
                _ -> acc
              }
            _ -> acc
          }
        })
      generate_inline_enums_from_properties(sb, parent_name, merged_props, ctx)
    }
    _ -> sb
  }
}

/// Generate enum types for any properties that have inline enum values.
fn generate_inline_enums_from_properties(
  sb: se.StringBuilder,
  parent_name: String,
  properties: dict.Dict(String, SchemaRef),
  _ctx: Context,
) -> se.StringBuilder {
  let entries = dict.to_list(properties)
  list.fold(entries, sb, fn(sb, entry) {
    let #(prop_name, prop_ref) = entry
    case prop_ref {
      Inline(StringSchema(description:, enum_values:, ..)) if enum_values != [] -> {
        let type_name =
          naming.schema_to_type_name(parent_name)
          <> naming.schema_to_type_name(prop_name)
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
      _ -> sb
    }
  })
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
    Inline(schema) -> generate_schema_type(sb, type_name, name, schema, ctx)
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
  raw_name: String,
  schema: SchemaObject,
  ctx: Context,
) -> se.StringBuilder {
  case schema {
    ObjectSchema(
      description:,
      properties:,
      required:,
      additional_properties:,
      additional_properties_untyped:,
      ..,
    ) -> {
      let sb = maybe_doc_comment(sb, description)
      let sb = sb |> se.line("pub type " <> type_name <> " {")
      let sb = sb |> se.indent(1, type_name <> "(")

      let props = dict.to_list(properties)
      let has_additional_props =
        option.is_some(additional_properties) || additional_properties_untyped
      let sb =
        list.index_fold(props, sb, fn(sb, entry, idx) {
          let #(prop_name, prop_ref) = entry
          let field_name = naming.to_snake_case(prop_name)
          let field_type =
            schema_ref_to_type_with_inline_enum(
              prop_ref,
              raw_name,
              prop_name,
              ctx,
            )
          let is_required = list.contains(required, prop_name)
          let is_already_optional = schema_ref_is_nullable(prop_ref, ctx)
          // Avoid Option(Option(T)): if schema is nullable, type is
          // already Option(T), so don't wrap again for optional fields.
          let final_type = case is_required, is_already_optional {
            True, _ -> field_type
            False, True -> field_type
            False, False -> "Option(" <> field_type <> ")"
          }
          let is_last = idx == list.length(props) - 1
          let trailing = case is_last && !has_additional_props {
            True -> ""
            False -> ","
          }
          sb |> se.indent(2, field_name <> ": " <> final_type <> trailing)
        })

      // Add additional_properties field if typed additionalProperties exists
      // or untyped additionalProperties: true (uses Dict(String, Dynamic))
      let sb = case additional_properties, additional_properties_untyped {
        Some(ap_ref), _ -> {
          let inner_type = schema_ref_to_type(ap_ref, ctx)
          sb
          |> se.indent(
            2,
            "additional_properties: Dict(String, " <> inner_type <> ")",
          )
        }
        None, True -> {
          sb |> se.indent(2, "additional_properties: Dict(String, Dynamic)")
        }
        None, False -> sb
      }

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
      let merged = merge_allof_schemas(schemas, ctx)

      let merged_schema =
        ObjectSchema(
          description:,
          properties: merged.properties,
          required: merged.required,
          additional_properties: merged.additional_properties,
          additional_properties_untyped: merged.additional_properties_untyped,
          nullable: False,
        )
      generate_schema_type(sb, type_name, raw_name, merged_schema, ctx)
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

/// Convert a SchemaRef to a type string, using inline enum type if applicable.
fn schema_ref_to_type_with_inline_enum(
  ref: SchemaRef,
  parent_name: String,
  prop_name: String,
  ctx: Context,
) -> String {
  case ref {
    Inline(StringSchema(enum_values:, ..)) if enum_values != [] -> {
      naming.schema_to_type_name(parent_name)
      <> naming.schema_to_type_name(prop_name)
    }
    _ -> schema_ref_to_type(ref, ctx)
  }
}

/// Generate anonymous types from inline schemas in operations.
fn generate_anonymous_types(
  sb: se.StringBuilder,
  ctx: Context,
) -> se.StringBuilder {
  let operations = collect_operations(ctx)
  list.fold(operations, sb, fn(sb, op) {
    let #(op_id, operation, _path, _method) = op
    let sb = generate_anonymous_response_types(sb, op_id, operation, ctx)
    let sb = generate_anonymous_request_body_type(sb, op_id, operation, ctx)
    sb
  })
}

/// Generate anonymous types for inline response schemas.
fn generate_anonymous_response_types(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation,
  ctx: Context,
) -> se.StringBuilder {
  let responses = dict.to_list(operation.responses)
  list.fold(responses, sb, fn(sb, entry) {
    let #(status_code, response) = entry
    let content_entries = dict.to_list(response.content)
    case content_entries {
      [#(_media_type, media_type), ..] ->
        case media_type.schema {
          Some(Inline(schema_obj)) ->
            generate_anonymous_type_for_schema(
              sb,
              op_id,
              "Response" <> http.status_code_suffix(status_code),
              schema_obj,
              ctx,
            )
          _ -> sb
        }
      _ -> sb
    }
  })
}

/// Generate anonymous type for a request body if it has an inline schema.
fn generate_anonymous_request_body_type(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation,
  ctx: Context,
) -> se.StringBuilder {
  case operation.request_body {
    Some(rb) -> {
      let content_entries = dict.to_list(rb.content)
      case content_entries {
        [#(_media_type, media_type), ..] ->
          case media_type.schema {
            Some(Inline(schema_obj)) ->
              generate_anonymous_type_for_schema(
                sb,
                op_id,
                "RequestBody",
                schema_obj,
                ctx,
              )
            _ -> sb
          }
        _ -> sb
      }
    }
    None -> sb
  }
}

/// Generate a named type for an inline schema object.
fn generate_anonymous_type_for_schema(
  sb: se.StringBuilder,
  op_id: String,
  suffix: String,
  schema_obj: SchemaObject,
  ctx: Context,
) -> se.StringBuilder {
  let type_name = naming.schema_to_type_name(op_id) <> suffix
  let raw_name = op_id <> "_" <> suffix

  case schema_obj {
    ObjectSchema(..) ->
      generate_schema_type(sb, type_name, raw_name, schema_obj, ctx)
    OneOfSchema(schemas:, ..) -> {
      // Only generate if all schemas are $ref (inline primitives are caught by validation)
      let all_refs =
        list.all(schemas, fn(s) {
          case s {
            Reference(_) -> True
            _ -> False
          }
        })
      case all_refs {
        True -> {
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
        False -> sb
      }
    }
    AnyOfSchema(schemas:, ..) -> {
      let all_refs =
        list.all(schemas, fn(s) {
          case s {
            Reference(_) -> True
            _ -> False
          }
        })
      case all_refs {
        True -> {
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
        False -> sb
      }
    }
    AllOfSchema(description:, schemas:) -> {
      let merged = merge_allof_schemas(schemas, ctx)
      let merged_schema =
        ObjectSchema(
          description:,
          properties: merged.properties,
          required: merged.required,
          additional_properties: merged.additional_properties,
          additional_properties_untyped: merged.additional_properties_untyped,
          nullable: False,
        )
      generate_schema_type(sb, type_name, raw_name, merged_schema, ctx)
    }
    _ -> sb
  }
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
    Reference(ref:) -> {
      let name = resolver.ref_to_name(ref)
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
        Reference(ref:) -> {
          let name = resolver.ref_to_name(ref)
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
            Reference(_) -> True
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
            Reference(_) -> True
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
  let operations = collect_operations(ctx)

  // Only import Option if any operation has optional parameters
  let needs_option =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(p) { !p.required })
    })

  // Check if types module is needed ($ref params or non-primitive body)
  let needs_types =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      let has_ref_params =
        list.any(operation.parameters, fn(p) {
          case p.schema {
            Some(Reference(_)) -> True
            _ -> False
          }
        })
      let has_typed_body = case operation.request_body {
        Some(rb) ->
          list.any(dict.to_list(rb.content), fn(ce) {
            let #(_, mt) = ce
            case mt.schema {
              Some(Reference(_)) -> True
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
                Reference(ref:) ->
                  naming.schema_to_type_name(resolver.ref_to_name(ref))
                _ -> "String"
              }
              "List(" <> item_type <> ")"
            }
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
          let body_type = extract_request_body_type(rb, op_id, ctx)
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
            [#(media_type_name, media_type), ..] ->
              case media_type_name {
                // text/plain responses always use String type regardless of schema
                "text/plain" ->
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
pub fn merge_allof_schemas(
  schemas: List(SchemaRef),
  ctx: Context,
) -> MergedAllOf {
  list.fold(
    schemas,
    MergedAllOf(
      properties: dict.new(),
      required: [],
      additional_properties: None,
      additional_properties_untyped: False,
    ),
    fn(acc, s_ref) {
      let resolved = case s_ref {
        Inline(obj) -> Ok(obj)
        Reference(_) -> resolver.resolve_schema_ref(s_ref, ctx.spec)
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
    Reference(_) ->
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
    Reference(_) ->
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
    Reference(_) ->
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
    Reference(_) ->
      case resolver.resolve_schema_ref(ref, ctx.spec) {
        Ok(s) -> schema.is_nullable(s)
        Error(_) -> False
      }
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
        Some(Reference(ref:)) ->
          "types." <> naming.schema_to_type_name(resolver.ref_to_name(ref))
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
