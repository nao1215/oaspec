/// Build IR modules from OpenAPI component schemas.
/// Converts schema definitions into IR declarations that ir_render can turn
/// into Gleam source text.  This replaces the direct string-concatenation
/// approach formerly used in types.gleam's generate_types function.
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oaspec/codegen/allof_merge
import oaspec/codegen/context.{type Context}
import oaspec/codegen/ir.{
  type Declaration, type Module, Declaration, EnumType, Field, Module,
  RecordType, TypeAlias, UnionType, VariantWithType,
}
import oaspec/codegen/schema_dispatch
import oaspec/codegen/schema_utils
import oaspec/openapi/dedup
import oaspec/openapi/operations
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, Forbidden, Inline,
  ObjectSchema, OneOfSchema, Reference, StringSchema, Typed, Untyped,
}
import oaspec/openapi/spec.{type Resolved, Value}
import oaspec/util/http
import oaspec/util/naming

/// Build an IR Module for the types.gleam file from component schemas.
pub fn build_types_module(ctx: Context) -> Module {
  let schemas = case ctx.spec.components {
    Some(components) ->
      list.sort(dict.to_list(components.schemas), fn(a, b) {
        string.compare(a.0, b.0)
      })
      |> list.filter(fn(entry) { !is_internal_schema(entry.1) })
    None -> []
  }

  let imports = compute_imports(schemas, ctx)

  // First pass: inline enum types from object properties
  let inline_enum_decls =
    list.flat_map(schemas, fn(entry) {
      let #(name, schema_ref) = entry
      inline_enums_for_schema(name, schema_ref, ctx)
    })

  // Second pass: main type definitions
  let main_decls =
    list.flat_map(schemas, fn(entry) {
      let #(name, schema_ref) = entry
      type_def_decls(name, schema_ref, ctx)
    })

  // Anonymous types from operations
  let anon_decls = anonymous_type_decls(ctx)

  Module(
    header: "",
    imports: imports,
    declarations: list.flatten([inline_enum_decls, main_decls, anon_decls]),
  )
}

// ---------------------------------------------------------------------------
// Imports
// ---------------------------------------------------------------------------

fn compute_imports(
  schemas: List(#(String, SchemaRef)),
  ctx: Context,
) -> List(String) {
  let needs_option =
    list.any(schemas, fn(entry) {
      let #(_, schema_ref) = entry
      case schema_ref {
        Inline(AnyOfSchema(..)) -> True
        _ -> schema_utils.schema_has_optional_fields(schema_ref, ctx)
      }
    })

  let needs_dict =
    list.any(schemas, fn(entry) {
      let #(_, schema_ref) = entry
      schema_utils.schema_has_additional_properties(schema_ref, ctx)
    })

  let needs_dynamic =
    list.any(schemas, fn(entry) {
      let #(_, schema_ref) = entry
      schema_utils.schema_has_untyped_additional_properties(schema_ref, ctx)
    })

  case needs_option, needs_dict, needs_dynamic {
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
}

// ---------------------------------------------------------------------------
// Inline enums
// ---------------------------------------------------------------------------

fn inline_enums_for_schema(
  parent_name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> List(Declaration) {
  case schema_ref {
    Inline(ObjectSchema(properties:, ..)) ->
      inline_enums_from_properties(parent_name, properties, ctx)
    Inline(AllOfSchema(schemas:, ..)) -> {
      let merged = allof_merge.merge_allof_schemas(schemas, ctx)
      inline_enums_from_properties(parent_name, merged.properties, ctx)
    }
    _ -> []
  }
}

fn inline_enums_from_properties(
  parent_name: String,
  properties: dict.Dict(String, SchemaRef),
  _ctx: Context,
) -> List(Declaration) {
  let entries = sorted_entries(properties)
  list.filter_map(entries, fn(entry) {
    let #(prop_name, prop_ref) = entry
    case prop_ref {
      Inline(StringSchema(metadata:, enum_values:, ..)) if enum_values != [] -> {
        let type_name =
          naming.schema_to_type_name(parent_name)
          <> naming.schema_to_type_name(prop_name)
        let deduped_variants = dedup.dedup_enum_variants(enum_values)
        let variants =
          list.zip(enum_values, deduped_variants)
          |> list.map(fn(pair) {
            let #(_, variant_suffix) = pair
            naming.schema_to_type_name(type_name) <> variant_suffix
          })
        Ok(Declaration(
          doc: metadata.description,
          type_def: EnumType(name: type_name, variants: variants),
        ))
      }
      _ -> Error(Nil)
    }
  })
}

// ---------------------------------------------------------------------------
// Main type definitions
// ---------------------------------------------------------------------------

fn type_def_decls(
  name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> List(Declaration) {
  let type_name = naming.schema_to_type_name(name)
  case schema_ref {
    Inline(schema) -> schema_type_decls(type_name, name, schema, ctx)
    Reference(name: ref_name, ..) -> {
      let resolved_type = naming.schema_to_type_name(ref_name)
      [
        Declaration(
          doc: None,
          type_def: TypeAlias(name: type_name, target: resolved_type),
        ),
      ]
    }
  }
}

fn schema_type_decls(
  type_name: String,
  raw_name: String,
  schema: SchemaObject,
  ctx: Context,
) -> List(Declaration) {
  case schema {
    ObjectSchema(metadata:, properties:, required:, additional_properties:, ..) -> {
      let props = sorted_entries(properties)
      let deduped_names =
        dedup.dedup_property_names(list.map(props, fn(e) { e.0 }))

      let fields =
        list.zip(props, deduped_names)
        |> list.map(fn(pair) {
          let #(entry, field_name) = pair
          let #(prop_name, prop_ref) = entry
          let field_type =
            schema_ref_to_type_with_inline_enum(
              prop_ref,
              raw_name,
              prop_name,
              ctx,
            )
          let is_required = list.contains(required, prop_name)
          let is_already_optional =
            schema_utils.schema_ref_is_nullable(prop_ref, ctx)
          let final_type = case is_required, is_already_optional {
            True, _ -> field_type
            False, True -> field_type
            False, False -> "Option(" <> field_type <> ")"
          }
          Field(name: field_name, type_expr: final_type)
        })

      // Add additional_properties field if present
      let fields = case additional_properties {
        Typed(ap_ref) -> {
          let inner_type = schema_ref_to_type(ap_ref, ctx)
          list.append(fields, [
            Field(
              name: "additional_properties",
              type_expr: "Dict(String, " <> inner_type <> ")",
            ),
          ])
        }
        Untyped -> {
          list.append(fields, [
            Field(
              name: "additional_properties",
              type_expr: "Dict(String, Dynamic)",
            ),
          ])
        }
        Forbidden -> fields
      }

      [
        Declaration(
          doc: metadata.description,
          type_def: RecordType(name: type_name, fields: fields),
        ),
      ]
    }

    StringSchema(metadata:, enum_values:, ..) if enum_values != [] -> {
      let deduped_variants = dedup.dedup_enum_variants(enum_values)
      let variants =
        list.zip(enum_values, deduped_variants)
        |> list.map(fn(pair) {
          let #(_, variant_suffix) = pair
          naming.schema_to_type_name(type_name) <> variant_suffix
        })
      [
        Declaration(
          doc: metadata.description,
          type_def: EnumType(name: type_name, variants: variants),
        ),
      ]
    }

    OneOfSchema(metadata:, schemas:, ..) -> {
      let variants =
        list.map(schemas, fn(s_ref) {
          let variant_type = schema_ref_to_type(s_ref, ctx)
          let variant_name = type_name <> variant_type
          VariantWithType(name: variant_name, inner_type: variant_type)
        })
      [
        Declaration(
          doc: metadata.description,
          type_def: UnionType(name: type_name, variants: variants),
        ),
      ]
    }

    AnyOfSchema(metadata:, schemas:, ..) -> {
      let fields =
        list.map(schemas, fn(s_ref) {
          let variant_type = schema_ref_to_type(s_ref, ctx)
          let field_name = naming.to_snake_case(variant_type)
          Field(name: field_name, type_expr: "Option(" <> variant_type <> ")")
        })
      [
        Declaration(
          doc: metadata.description,
          type_def: RecordType(name: type_name, fields: fields),
        ),
      ]
    }

    AllOfSchema(metadata:, schemas:) -> {
      let merged = allof_merge.merge_allof_schemas(schemas, ctx)
      let merged_schema =
        ObjectSchema(
          metadata:,
          properties: merged.properties,
          required: merged.required,
          additional_properties: merged.additional_properties,
          min_properties: None,
          max_properties: None,
        )
      schema_type_decls(type_name, raw_name, merged_schema, ctx)
    }

    _ -> {
      let gleam_type = schema_dispatch.schema_type(schema)
      [
        Declaration(
          doc: None,
          type_def: TypeAlias(name: type_name, target: gleam_type),
        ),
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Anonymous types from operations
// ---------------------------------------------------------------------------

fn anonymous_type_decls(ctx: Context) -> List(Declaration) {
  let operations = operations.collect_operations(ctx)
  list.flat_map(operations, fn(op) {
    let #(op_id, operation, _path, _method): #(
      String,
      spec.Operation(Resolved),
      String,
      spec.HttpMethod,
    ) = op
    let response_decls = anonymous_response_type_decls(op_id, operation, ctx)
    let request_decls = anonymous_request_body_type_decls(op_id, operation, ctx)
    list.append(response_decls, request_decls)
  })
}

fn anonymous_response_type_decls(
  op_id: String,
  operation: spec.Operation(Resolved),
  ctx: Context,
) -> List(Declaration) {
  let responses = http.sort_response_entries(dict.to_list(operation.responses))
  list.flat_map(responses, fn(entry) {
    let #(status_code, ref_or) = entry
    case ref_or {
      Value(response) -> {
        let content_entries = sorted_entries(response.content)
        case content_entries {
          [#(_media_type, media_type), ..] ->
            case media_type.schema {
              Some(Inline(schema_obj)) -> {
                let filtered_schema =
                  schema_utils.filter_write_only_properties(schema_obj, ctx)
                anonymous_type_for_schema(
                  op_id,
                  "Response" <> http.status_code_suffix(status_code),
                  filtered_schema,
                  ctx,
                )
              }
              _ -> []
            }
          _ -> []
        }
      }
      _ -> []
    }
  })
}

fn anonymous_request_body_type_decls(
  op_id: String,
  operation: spec.Operation(Resolved),
  ctx: Context,
) -> List(Declaration) {
  case operation.request_body {
    Some(Value(rb)) -> {
      let content_entries = sorted_entries(rb.content)
      case content_entries {
        [#(_media_type, media_type), ..] ->
          case media_type.schema {
            Some(Inline(schema_obj)) -> {
              let filtered_schema =
                schema_utils.filter_read_only_properties(schema_obj, ctx)
              anonymous_type_for_schema(
                op_id,
                "RequestBody",
                filtered_schema,
                ctx,
              )
            }
            _ -> []
          }
        _ -> []
      }
    }
    _ -> []
  }
}

fn anonymous_type_for_schema(
  op_id: String,
  suffix: String,
  schema_obj: SchemaObject,
  ctx: Context,
) -> List(Declaration) {
  let type_name = naming.schema_to_type_name(op_id) <> suffix
  let raw_name = op_id <> "_" <> suffix

  case schema_obj {
    ObjectSchema(..) -> schema_type_decls(type_name, raw_name, schema_obj, ctx)
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
          let variants =
            list.map(schemas, fn(s_ref) {
              let variant_type = schema_ref_to_type(s_ref, ctx)
              let variant_name = type_name <> variant_type
              VariantWithType(name: variant_name, inner_type: variant_type)
            })
          [
            Declaration(
              doc: None,
              type_def: UnionType(name: type_name, variants: variants),
            ),
          ]
        }
        False -> []
      }
    }
    AnyOfSchema(..) -> schema_type_decls(type_name, raw_name, schema_obj, ctx)
    AllOfSchema(metadata:, schemas:) -> {
      let merged = allof_merge.merge_allof_schemas(schemas, ctx)
      let merged_schema =
        ObjectSchema(
          metadata:,
          properties: merged.properties,
          required: merged.required,
          additional_properties: merged.additional_properties,
          min_properties: None,
          max_properties: None,
        )
      schema_type_decls(type_name, raw_name, merged_schema, ctx)
    }
    _ -> []
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

fn schema_ref_to_type(ref: SchemaRef, _ctx: Context) -> String {
  case ref {
    Inline(s) -> schema_dispatch.schema_type(s)
    Reference(name:, ..) -> naming.schema_to_type_name(name)
  }
}

/// Sort dict entries by key for deterministic output ordering.
/// Gleam Dict does not guarantee iteration order, so all codegen paths
/// that produce output from dict entries must sort first.
pub fn sorted_entries(d: dict.Dict(String, v)) -> List(#(String, v)) {
  dict.to_list(d) |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

/// Check if a schema ref is marked as internal (allOf helper type).
pub fn is_internal_schema(schema_ref: schema.SchemaRef) -> Bool {
  case schema_ref {
    Inline(obj) -> schema.get_metadata(obj).internal
    _ -> False
  }
}
