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
import oaspec/codegen/import_analysis
import oaspec/codegen/ir.{
  type Declaration, type Field, type Module, type Variant, EnumType, Field,
  RecordType, TypeAlias, UnionType, VariantEmpty, VariantWithHeaders,
  VariantWithType, VariantWithTypeAndHeaders,
}
import oaspec/codegen/schema_dispatch
import oaspec/codegen/schema_utils
import oaspec/config
import oaspec/openapi/dedup
import oaspec/openapi/operations
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  BooleanSchema, Forbidden, Inline, IntegerSchema, NumberSchema, ObjectSchema,
  OneOfSchema, Reference, StringSchema, Typed, Unspecified, Untyped,
}
import oaspec/openapi/spec.{type Resolved, Value}
import oaspec/util/content_type
import oaspec/util/http
import oaspec/util/naming

/// Build an IR Module for the types.gleam file from component schemas.
pub fn build_types_module(ctx: Context) -> Module {
  let schemas = case context.spec(ctx).components {
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

  ir.module(
    header: "",
    imports: imports,
    declarations: list.flatten([inline_enum_decls, main_decls, anon_decls]),
  )
}

/// Build an IR Module for the request_types.gleam file from operations.
/// Each operation with at least one parameter or a request body yields a
/// single `RecordType` declaration. Operations with neither parameters nor
/// body produce no declaration — matching the former string-builder
/// behavior that simply skipped them.
pub fn build_request_types_module(ctx: Context) -> Module {
  let operations = operations.collect_operations(ctx)
  let imports = compute_request_type_imports(operations, ctx)
  let declarations =
    list.filter_map(operations, fn(op) {
      let #(op_id, operation, _path, _method) = op
      request_type_decl(op_id, operation, ctx)
    })
  ir.module(header: "", imports: imports, declarations: declarations)
}

fn compute_request_type_imports(
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
  ctx: Context,
) -> List(String) {
  let needs_option =
    import_analysis.operations_have_optional_params(operations)
    || import_analysis.operations_have_optional_body(operations)
  let needs_types = import_analysis.operations_need_typed_schemas(operations)
  let base_imports = case needs_types {
    True -> [config.package(context.config(ctx)) <> "/types"]
    False -> []
  }
  case needs_option {
    True -> ["gleam/option.{type Option}", ..base_imports]
    False -> base_imports
  }
}

fn request_type_decl(
  op_id: String,
  operation: spec.Operation(Resolved),
  ctx: Context,
) -> Result(Declaration, Nil) {
  let params = operation.parameters
  case list.is_empty(params) && option.is_none(operation.request_body) {
    True -> Error(Nil)
    False -> {
      let type_name = naming.schema_to_type_name(op_id) <> "Request"
      let resolved_params =
        list.filter_map(params, fn(ref_p) {
          case ref_p {
            Value(param) -> Ok(param)
            _ -> Error(Nil)
          }
        })
      let deduped_names = dedup.dedup_param_field_names(resolved_params)
      let param_fields =
        list.map(list.zip(resolved_params, deduped_names), fn(pair) {
          let #(param, field_name) = pair
          request_param_field(param, field_name)
        })
      let body_field = case operation.request_body {
        Some(Value(rb)) -> [request_body_field(rb, op_id, ctx)]
        _ -> []
      }
      Ok(ir.declaration(
        doc: operation.description,
        type_def: RecordType(
          name: type_name,
          fields: list.append(param_fields, body_field),
        ),
      ))
    }
  }
}

fn request_param_field(
  param: spec.Parameter(Resolved),
  field_name: String,
) -> Field {
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
  Field(name: field_name, type_expr: final_type)
}

fn request_body_field(
  rb: spec.RequestBody(Resolved),
  op_id: String,
  ctx: Context,
) -> Field {
  let body_type = request_body_type(rb, op_id, ctx)
  let final_type = case rb.required {
    True -> body_type
    False -> "Option(" <> body_type <> ")"
  }
  Field(name: "body", type_expr: final_type)
}

fn request_body_type(
  rb: spec.RequestBody(Resolved),
  op_id: String,
  _ctx: Context,
) -> String {
  let content_entries = sorted_entries(rb.content)
  case content_entries {
    [#(_media_type, media_type), ..] ->
      case media_type.schema {
        Some(Reference(name:, ..)) ->
          "types." <> naming.schema_to_type_name(name)
        Some(Inline(schema_obj)) -> inline_request_body_type(schema_obj, op_id)
        _ -> "String"
      }
    [] -> "String"
  }
}

/// Build an IR Module for the response_types.gleam file from operations.
/// Each operation with at least one response yields a `UnionType`
/// declaration whose variants correspond to HTTP status codes. Variant
/// payloads follow the same rules the former string-builder applied:
/// empty responses become `VariantEmpty`; text/XML/octet-stream bodies
/// become `VariantWithType("String")`; JSON (and other structured) bodies
/// become `VariantWithType(<qualified schema type>)`.
pub fn build_response_types_module(ctx: Context) -> Module {
  let operations = operations.collect_operations(ctx)
  let header_records = build_response_header_records(operations)
  let needs_option_for_headers = response_headers_need_option(header_records)
  let imports = case
    responses_need_types_import(operations),
    needs_option_for_headers
  {
    True, True -> [
      "gleam/option.{type Option}",
      config.package(context.config(ctx)) <> "/types",
    ]
    True, False -> [config.package(context.config(ctx)) <> "/types"]
    False, True -> ["gleam/option.{type Option}"]
    False, False -> []
  }
  let declarations =
    list.filter_map(operations, fn(op) {
      let #(op_id, operation, _path, _method) = op
      response_type_decl(op_id, operation)
    })
  ir.module_with_header_records(
    header: "",
    imports: imports,
    declarations: declarations,
    header_records: header_records,
  )
}

/// Build ResponseHeaderRecord list from all operations.
fn build_response_header_records(
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> List(ir.ResponseHeaderRecord) {
  list.flat_map(operations, fn(op) {
    let #(op_id, operation, _path, _method) = op
    let type_name = naming.schema_to_type_name(op_id) <> "Response"
    let responses =
      http.sort_response_entries(dict.to_list(operation.responses))
    list.filter_map(responses, fn(entry) {
      let #(status_code, ref_or) = entry
      case ref_or {
        Value(response) -> {
          let headers = sorted_entries(response.headers)
          case headers {
            [] -> Error(Nil)
            _ -> {
              let record_name =
                type_name <> http.status_code_suffix(status_code) <> "Headers"
              let fields =
                list.map(headers, fn(h_entry) {
                  let #(header_name, header) = h_entry
                  let field_name = naming.to_snake_case(header_name)
                  let field_type = header_schema_to_type(header.schema)
                  let final_type = case header.required {
                    True -> field_type
                    False -> "Option(" <> field_type <> ")"
                  }
                  Field(name: field_name, type_expr: final_type)
                })
              Ok(ir.ResponseHeaderRecord(name: record_name, fields: fields))
            }
          }
        }
        _ -> Error(Nil)
      }
    })
  })
}

/// Convert a header schema to a Gleam type string.
/// Handles both inline primitive schemas and `$ref` references (#294).
fn header_schema_to_type(schema_opt: option.Option(schema.SchemaRef)) -> String {
  case schema_opt {
    Some(Inline(IntegerSchema(..))) -> "Int"
    Some(Inline(NumberSchema(..))) -> "Float"
    Some(Inline(BooleanSchema(..))) -> "Bool"
    Some(Inline(StringSchema(..))) -> "String"
    Some(Reference(name:, ..)) -> "types." <> naming.schema_to_type_name(name)
    _ -> "String"
  }
}

/// Check if any response header record has optional fields.
fn response_headers_need_option(records: List(ir.ResponseHeaderRecord)) -> Bool {
  list.any(records, fn(rec) {
    list.any(rec.fields, fn(f) { string.starts_with(f.type_expr, "Option(") })
  })
}

fn responses_need_types_import(
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
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

fn response_type_decl(
  op_id: String,
  operation: spec.Operation(Resolved),
) -> Result(Declaration, Nil) {
  let type_name = naming.schema_to_type_name(op_id) <> "Response"
  let responses = http.sort_response_entries(dict.to_list(operation.responses))
  case responses {
    [] -> Error(Nil)
    _ -> {
      let variants =
        list.filter_map(responses, fn(entry) {
          let #(status_code, ref_or) = entry
          case ref_or {
            Value(response) ->
              Ok(response_variant(type_name, op_id, status_code, response))
            _ -> Error(Nil)
          }
        })
      Ok(ir.declaration(
        doc: None,
        type_def: UnionType(name: type_name, variants: variants),
      ))
    }
  }
}

fn response_variant(
  type_name: String,
  op_id: String,
  status_code: http.HttpStatusCode,
  response: spec.Response(Resolved),
) -> Variant {
  let variant_name = type_name <> http.status_code_suffix(status_code)
  let content_entries = sorted_entries(response.content)
  // Issue #306: when the response declares headers, the variant carries
  // an additional typed headers record so handlers can supply values
  // and the router can serialise them onto the wire.
  let headers_type_opt = case sorted_entries(response.headers) {
    [] -> None
    _ -> Some(variant_name <> "Headers")
  }
  case content_entries {
    [] -> empty_variant_with_optional_headers(variant_name, headers_type_opt)
    [_, _, ..] ->
      typed_variant_with_optional_headers(
        variant_name,
        "String",
        headers_type_opt,
      )
    [#(media_type_name, media_type)] ->
      case content_type.from_string(media_type_name) {
        content_type.TextPlain
        | content_type.ApplicationXml
        | content_type.TextXml ->
          case media_type.schema {
            Some(_) ->
              typed_variant_with_optional_headers(
                variant_name,
                "String",
                headers_type_opt,
              )
            None ->
              empty_variant_with_optional_headers(
                variant_name,
                headers_type_opt,
              )
          }
        // Issue #304: binary response payloads ride a BitArray variant
        // so handlers can produce real bytes instead of forcing the
        // payload through `String`.
        content_type.ApplicationOctetStream ->
          case media_type.schema {
            Some(_) ->
              typed_variant_with_optional_headers(
                variant_name,
                "BitArray",
                headers_type_opt,
              )
            None ->
              empty_variant_with_optional_headers(
                variant_name,
                headers_type_opt,
              )
          }
        _ ->
          case media_type.schema {
            Some(ref) -> {
              let suffix = "Response" <> http.status_code_suffix(status_code)
              let inner_type = schema_ref_to_type_qualified(ref, op_id, suffix)
              typed_variant_with_optional_headers(
                variant_name,
                inner_type,
                headers_type_opt,
              )
            }
            None ->
              empty_variant_with_optional_headers(
                variant_name,
                headers_type_opt,
              )
          }
      }
  }
}

/// Pick the empty-body variant kind based on whether typed headers exist.
fn empty_variant_with_optional_headers(
  variant_name: String,
  headers_type_opt: option.Option(String),
) -> Variant {
  case headers_type_opt {
    Some(headers_type) ->
      VariantWithHeaders(name: variant_name, headers_type: headers_type)
    None -> VariantEmpty(name: variant_name)
  }
}

/// Pick the body-bearing variant kind based on whether typed headers exist.
fn typed_variant_with_optional_headers(
  variant_name: String,
  inner_type: String,
  headers_type_opt: option.Option(String),
) -> Variant {
  case headers_type_opt {
    Some(headers_type) ->
      VariantWithTypeAndHeaders(
        name: variant_name,
        inner_type: inner_type,
        headers_type: headers_type,
      )
    None -> VariantWithType(name: variant_name, inner_type: inner_type)
  }
}

fn schema_ref_to_type_qualified(
  ref: SchemaRef,
  op_id: String,
  suffix: String,
) -> String {
  case ref {
    Inline(schema_obj) ->
      schema_to_gleam_type_qualified(schema_obj, op_id, suffix)
    Reference(name:, ..) -> "types." <> naming.schema_to_type_name(name)
  }
}

fn schema_to_gleam_type_qualified(
  schema_obj: SchemaObject,
  op_id: String,
  suffix: String,
) -> String {
  case schema_obj {
    ArraySchema(items:, ..) ->
      case items {
        Reference(name:, ..) ->
          "List(types." <> naming.schema_to_type_name(name) <> ")"
        _ -> schema_dispatch.schema_type(schema_obj)
      }
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
        False -> schema_dispatch.schema_type(schema_obj)
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
        False -> schema_dispatch.schema_type(schema_obj)
      }
    }
    AllOfSchema(..) -> {
      let type_name = naming.schema_to_type_name(op_id) <> suffix
      "types." <> type_name
    }
    _ -> schema_dispatch.schema_type(schema_obj)
  }
}

fn inline_request_body_type(schema_obj: SchemaObject, op_id: String) -> String {
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
    _ -> schema_dispatch.schema_type(schema_obj)
  }
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
    Inline(ObjectSchema(properties:, required:, ..)) ->
      inline_enums_from_properties(parent_name, properties, required, ctx)
    Inline(AllOfSchema(schemas:, ..)) -> {
      let merged = allof_merge.merge_allof_schemas(schemas, ctx)
      inline_enums_from_properties(
        parent_name,
        merged.properties,
        merged.required,
        ctx,
      )
    }
    _ -> []
  }
}

fn inline_enums_from_properties(
  parent_name: String,
  properties: dict.Dict(String, SchemaRef),
  required: List(String),
  _ctx: Context,
) -> List(Declaration) {
  let entries = sorted_entries(properties)
  list.filter_map(entries, fn(entry) {
    let #(prop_name, prop_ref) = entry
    // Issue #309: a required property whose schema is an inline
    // string-enum with exactly one allowed value is fully determined
    // — the dispatching union variant or the single legal wire value
    // already carries the choice. Skip emitting a tautological
    // one-variant `*Kind` enum for it.
    case schema_utils.constant_property_value(prop_ref, prop_name, required) {
      Some(_) -> Error(Nil)
      None ->
        case prop_ref {
          Inline(StringSchema(metadata:, enum_values:, ..))
            if enum_values != []
          -> {
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
            Ok(ir.declaration(
              doc: metadata.description,
              type_def: EnumType(name: type_name, variants: variants),
            ))
          }
          _ -> Error(Nil)
        }
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
        ir.declaration(
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
      // Issue #309: drop constant properties (required, inline,
      // single-value string enums) from the generated record. The
      // value is fixed at codegen time, so encoder emits the literal
      // and decoder validates it — keeping the field would force
      // every constructor call to restate `kind: KindOnly`.
      let props =
        sorted_entries(properties)
        |> list.filter(fn(entry) {
          let #(prop_name, prop_ref) = entry
          option.is_none(schema_utils.constant_property_value(
            prop_ref,
            prop_name,
            required,
          ))
        })
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
          // Issue #321: for an inline nullable schema, `field_type`
          // already includes the `Option(...)` wrapper (added inside
          // `schema_dispatch.schema_type`). For a $ref to a nullable
          // schema (which `hoist` produces for any non-trivial inline
          // shape, e.g. a `nullable: true` object with
          // `additionalProperties: ...`), the type renderer drops the
          // Option, but the matching decoder/encoder treat the field
          // as `Option(T)`. Detect that case and wrap explicitly so
          // the three modules agree.
          let field_type = case prop_ref, is_already_optional {
            Reference(..), True ->
              case string.starts_with(field_type, "Option(") {
                True -> field_type
                False -> "Option(" <> field_type <> ")"
              }
            _, _ -> field_type
          }
          let final_type = case is_required, is_already_optional {
            True, _ -> field_type
            False, True -> field_type
            False, False -> "Option(" <> field_type <> ")"
          }
          Field(name: field_name, type_expr: final_type)
        })

      // Add additional_properties field only when the spec opted in.
      // Forbidden (explicit false) and Unspecified (key absent) both
      // suppress the field; the latter avoids constructor-noise on
      // closed-object schemas — see Issue #249.
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
        Forbidden | Unspecified -> fields
      }

      [
        ir.declaration(
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
        ir.declaration(
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
        ir.declaration(
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
        ir.declaration(
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
        ir.declaration(
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
            ir.declaration(
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
