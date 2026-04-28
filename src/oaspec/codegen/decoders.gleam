import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/codegen/allof_merge
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/ir_build
import oaspec/codegen/schema_dispatch
import oaspec/codegen/schema_utils
import oaspec/codegen/types as type_gen
import oaspec/config
import oaspec/openapi/dedup
import oaspec/openapi/operations
import oaspec/openapi/resolver
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  BooleanSchema, Forbidden, Inline, IntegerSchema, NumberSchema, ObjectSchema,
  OneOfSchema, Reference, StringSchema, Typed, Unspecified, Untyped,
}
import oaspec/openapi/spec.{type Resolved, Value}
import oaspec/util/http
import oaspec/util/naming
import oaspec/util/string_extra as se

/// Generate the `decode.gleam` module for the resolved spec.
///
/// Encoder generation lives in `src/oaspec/codegen/encoders.gleam`; see
/// `generate.gleam::generate_shared` for how the two halves are combined.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let operations = operations.collect_operations(ctx)
  let decode_content = generate_decoders(ctx, operations)

  [
    GeneratedFile(
      path: "decode.gleam",
      content: decode_content,
      target: context.SharedTarget,
      write_mode: context.Overwrite,
    ),
  ]
}

// ===================================================================
// Decoders
// ===================================================================

/// Generate JSON decoders for all component schemas and anonymous types.
fn generate_decoders(
  ctx: Context,
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> String {
  let schemas = case context.spec(ctx).components {
    Some(components) ->
      list.sort(dict.to_list(components.schemas), fn(a, b) {
        string.compare(a.0, b.0)
      })
    None -> []
  }

  // Check if option module is needed (any schema with optional fields)
  let needs_option =
    list.any(schemas, fn(entry) {
      let #(_, schema_ref) = entry
      type_gen.schema_has_optional_fields(schema_ref, ctx)
    })

  // Check if dict module is needed (any schema with typed or untyped additionalProperties)
  let needs_dict =
    list.any(schemas, fn(entry) {
      let #(_, schema_ref) = entry
      type_gen.schema_has_additional_properties(schema_ref, ctx)
    })

  // Check if types module is needed (any non-primitive schema)
  let needs_types =
    list.any(schemas, fn(entry) {
      let #(_, schema_ref) = entry
      case schema_ref {
        Inline(ObjectSchema(..))
        | Inline(AllOfSchema(..))
        | Inline(OneOfSchema(..))
        | Inline(AnyOfSchema(..)) -> True
        Inline(StringSchema(enum_values:, ..)) if enum_values != [] -> True
        _ -> False
      }
    })

  let base_imports = case needs_dict {
    True -> ["gleam/dict", "gleam/dynamic/decode", "gleam/json"]
    False -> ["gleam/dynamic/decode", "gleam/json"]
  }
  let base_imports = case needs_types {
    True ->
      list.append(base_imports, [
        config.package(context.config(ctx)) <> "/types",
      ])
    False -> base_imports
  }
  let imports = case needs_option {
    True -> list.append(base_imports, ["gleam/option"])
    False -> base_imports
  }

  let sb =
    se.file_header(context.version)
    |> se.imports(imports)

  let schemas = case context.spec(ctx).components {
    Some(components) ->
      list.sort(dict.to_list(components.schemas), fn(a, b) {
        string.compare(a.0, b.0)
      })
      |> list.filter(fn(entry) { !ir_build.is_internal_schema(entry.1) })
    None -> []
  }

  // First pass: generate inline enum decoders from object/allOf properties
  let sb =
    list.fold(schemas, sb, fn(sb, entry) {
      let #(name, schema_ref) = entry
      generate_inline_enum_decoders(sb, name, schema_ref, ctx)
    })

  // Second pass: generate main type decoders
  let sb =
    list.fold(schemas, sb, fn(sb, entry) {
      let #(name, schema_ref) = entry
      generate_decoder(sb, name, schema_ref, ctx)
    })

  // Generate decoders for anonymous inline schemas from operations
  let sb = generate_anonymous_decoders(sb, ctx, operations)

  se.to_string(sb)
}

/// Generate decoders for anonymous inline schemas (response/requestBody).
fn generate_anonymous_decoders(
  sb: se.StringBuilder,
  ctx: Context,
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> se.StringBuilder {
  list.fold(operations, sb, fn(sb, op) {
    let #(op_id, operation, _path, _method) = op
    let sb = generate_anonymous_response_decoders(sb, op_id, operation, ctx)
    generate_anonymous_request_body_decoder(sb, op_id, operation, ctx)
  })
}

/// Generate decoders for inline response schemas.
fn generate_anonymous_response_decoders(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation(Resolved),
  ctx: Context,
) -> se.StringBuilder {
  let responses = http.sort_response_entries(dict.to_list(operation.responses))
  list.fold(responses, sb, fn(sb, entry) {
    let #(status_code, ref_or_response) = entry
    case ref_or_response {
      Value(response) -> {
        let content_entries = ir_build.sorted_entries(response.content)
        case content_entries {
          [#(_, media_type), ..] ->
            case media_type.schema {
              Some(Inline(schema_obj)) -> {
                // Filter out writeOnly properties from response decoders
                let filtered_schema =
                  type_gen.filter_write_only_properties(schema_obj, ctx)
                let suffix = "Response" <> http.status_code_suffix(status_code)
                generate_anonymous_schema_decoder(
                  sb,
                  op_id,
                  suffix,
                  filtered_schema,
                  ctx,
                )
              }
              _ -> sb
            }
          _ -> sb
        }
      }
      spec.Ref(_) -> sb
    }
  })
}

/// Generate decoder for an inline requestBody schema.
fn generate_anonymous_request_body_decoder(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation(Resolved),
  ctx: Context,
) -> se.StringBuilder {
  case operation.request_body {
    Some(Value(rb)) -> {
      let content_entries = ir_build.sorted_entries(rb.content)
      case content_entries {
        [#(_, media_type), ..] ->
          case media_type.schema {
            Some(Inline(schema_obj)) -> {
              // Filter out readOnly properties from request body decoders
              let filtered_schema =
                type_gen.filter_read_only_properties(schema_obj, ctx)
              generate_anonymous_schema_decoder(
                sb,
                op_id,
                "RequestBody",
                filtered_schema,
                ctx,
              )
            }
            _ -> sb
          }
        _ -> sb
      }
    }
    Some(spec.Ref(_)) -> sb
    None -> sb
  }
}

/// Generate decoder for an anonymous schema with a composed name.
fn generate_anonymous_schema_decoder(
  sb: se.StringBuilder,
  op_id: String,
  suffix: String,
  schema_obj: SchemaObject,
  ctx: Context,
) -> se.StringBuilder {
  let name = naming.to_snake_case(op_id) <> "_" <> naming.to_snake_case(suffix)
  let schema_ref = Inline(schema_obj)
  generate_decoder(sb, name, schema_ref, ctx)
}

/// Generate inline enum decoders found in object/allOf properties.
fn generate_inline_enum_decoders(
  sb: se.StringBuilder,
  parent_name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> se.StringBuilder {
  let #(props, required) = case schema_ref {
    Inline(ObjectSchema(properties:, required:, ..)) -> #(
      ir_build.sorted_entries(properties),
      required,
    )
    Inline(AllOfSchema(schemas:, ..)) -> {
      let merged = allof_merge.merge_allof_schemas(schemas, ctx)
      #(ir_build.sorted_entries(merged.properties), merged.required)
    }
    _ -> #([], [])
  }
  list.fold(props, sb, fn(sb, entry) {
    let #(prop_name, prop_ref) = entry
    // Issue #309: a required inline single-value string-enum has no
    // corresponding type in `types.gleam` (the IR pass elided it), so
    // emitting a decoder for it would produce orphan code that
    // references a missing type. Skip it; the constant value is
    // validated inline by the parent object decoder instead.
    case schema_utils.constant_property_value(prop_ref, prop_name, required) {
      Some(_) -> sb
      None ->
        case prop_ref {
          Inline(StringSchema(enum_values:, ..)) if enum_values != [] -> {
            let enum_name =
              naming.schema_to_type_name(parent_name)
              <> naming.schema_to_type_name(prop_name)
            generate_decoder(sb, enum_name, prop_ref, ctx)
          }
          _ -> sb
        }
    }
  })
}

/// Generate decoder functions for a schema.
fn generate_decoder(
  sb: se.StringBuilder,
  name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> se.StringBuilder {
  let type_name = naming.schema_to_type_name(name)
  let fn_name = "decode_" <> naming.to_snake_case(name)
  let decoder_fn_name = naming.to_snake_case(name) <> "_decoder"

  case schema_ref {
    Inline(ObjectSchema(
      properties:,
      required:,
      additional_properties:,
      metadata:,
      ..,
    )) ->
      generate_object_decoder(
        sb,
        name,
        type_name,
        fn_name,
        decoder_fn_name,
        metadata.description,
        properties,
        required,
        additional_properties,
        ctx,
      )

    Inline(StringSchema(metadata:, enum_values:, ..)) if enum_values != [] ->
      generate_enum_decoder(
        sb,
        type_name,
        fn_name,
        decoder_fn_name,
        metadata.description,
        enum_values,
      )

    Inline(AllOfSchema(metadata:, schemas:)) -> {
      let merged = type_gen.merge_allof_schemas(schemas, ctx)
      let merged_schema =
        Inline(ObjectSchema(
          metadata:,
          properties: merged.properties,
          required: merged.required,
          additional_properties: merged.additional_properties,
          min_properties: option.None,
          max_properties: option.None,
        ))
      generate_decoder(sb, name, merged_schema, ctx)
    }

    Inline(OneOfSchema(metadata:, schemas:, discriminator:)) ->
      generate_oneof_decoder(
        sb,
        name,
        type_name,
        fn_name,
        decoder_fn_name,
        metadata.description,
        schemas,
        discriminator,
        ctx,
      )

    Inline(AnyOfSchema(metadata:, schemas:, ..)) ->
      generate_anyof_decoder(
        sb,
        type_name,
        fn_name,
        decoder_fn_name,
        metadata.description,
        schemas,
      )

    Inline(StringSchema(metadata:, enum_values: [], ..)) -> {
      let #(gleam_type, decoder_expr) = case metadata.nullable {
        True -> #("Option(String)", "decode.optional(decode.string)")
        False -> #("String", "decode.string")
      }
      generate_primitive_decoder(
        sb,
        fn_name,
        decoder_fn_name,
        gleam_type,
        decoder_expr,
      )
    }

    Inline(IntegerSchema(metadata:, ..)) -> {
      let #(gleam_type, decoder_expr) = case metadata.nullable {
        True -> #("Option(Int)", "decode.optional(decode.int)")
        False -> #("Int", "decode.int")
      }
      generate_primitive_decoder(
        sb,
        fn_name,
        decoder_fn_name,
        gleam_type,
        decoder_expr,
      )
    }

    Inline(NumberSchema(metadata:, ..)) -> {
      let #(gleam_type, decoder_expr) = case metadata.nullable {
        True -> #("Option(Float)", "decode.optional(decode.float)")
        False -> #("Float", "decode.float")
      }
      generate_primitive_decoder(
        sb,
        fn_name,
        decoder_fn_name,
        gleam_type,
        decoder_expr,
      )
    }

    Inline(BooleanSchema(metadata:)) -> {
      let #(gleam_type, decoder_expr) = case metadata.nullable {
        True -> #("Option(Bool)", "decode.optional(decode.bool)")
        False -> #("Bool", "decode.bool")
      }
      generate_primitive_decoder(
        sb,
        fn_name,
        decoder_fn_name,
        gleam_type,
        decoder_expr,
      )
    }

    Inline(ArraySchema(items:, ..)) ->
      generate_array_decoder(sb, name, fn_name, decoder_fn_name, items, ctx)

    _ -> sb
  }
}

/// Generate decoder for an ObjectSchema (properties, required, additionalProperties).
fn generate_object_decoder(
  sb: se.StringBuilder,
  name: String,
  type_name: String,
  fn_name: String,
  decoder_fn_name: String,
  description: Option(String),
  properties: dict.Dict(String, SchemaRef),
  required: List(String),
  additional_properties: schema.AdditionalProperties,
  ctx: Context,
) -> se.StringBuilder {
  let sb = maybe_doc_comment(sb, description)
  let sb =
    sb
    |> se.line(
      "pub fn "
      <> decoder_fn_name
      <> "() -> decode.Decoder(types."
      <> type_name
      <> ") {",
    )

  let props = ir_build.sorted_entries(properties)
  let deduped_names = dedup.dedup_property_names(list.map(props, fn(e) { e.0 }))
  let sb =
    list.index_fold(props, sb, fn(sb, entry, idx) {
      let #(prop_name, prop_ref) = entry
      let field_name =
        list_at_or(deduped_names, idx, naming.to_snake_case(prop_name))
      // writeOnly fields may not appear in responses, so treat them
      // as optional even if listed in required
      let is_write_only = type_gen.schema_ref_is_write_only(prop_ref, ctx)
      let is_required = list.contains(required, prop_name) && !is_write_only
      let field_decoder = schema_ref_to_decoder(prop_ref, name, prop_name)
      let is_nullable_schema = schema_ref_is_nullable(prop_ref, ctx)

      // For nullable schemas, the Gleam type is Option(T),
      // so the decoder must be decode.optional(inner_decoder).
      let effective_decoder = case is_nullable_schema {
        True -> "decode.optional(" <> field_decoder <> ")"
        False -> field_decoder
      }

      // Issue #309: a required, inline single-value string-enum
      // property is elided from the generated record. The decoder
      // must still observe the wire value and reject mismatches —
      // otherwise a spec violation would silently slip through. The
      // emitted decoder reads the field as a string, validates it
      // against the codegen-time constant via `decode.then`, and
      // discards the value (the record has no slot for it).
      case schema_utils.constant_property_value(prop_ref, prop_name, required) {
        Some(constant_value) ->
          sb
          |> emit_constant_field_decoder(prop_name, constant_value)
        None ->
          case is_required {
            True ->
              sb
              |> se.indent(
                1,
                "use "
                  <> field_name
                  <> " <- decode.field(\""
                  <> prop_name
                  <> "\", "
                  <> effective_decoder
                  <> ")",
              )
            False ->
              case is_nullable_schema {
                True ->
                  // Type is Option(T), default is None
                  sb
                  |> se.indent(
                    1,
                    "use "
                      <> field_name
                      <> " <- decode.optional_field(\""
                      <> prop_name
                      <> "\", option.None, "
                      <> effective_decoder
                      <> ")",
                  )
                False ->
                  sb
                  |> se.indent(
                    1,
                    "use "
                      <> field_name
                      <> " <- decode.optional_field(\""
                      <> prop_name
                      <> "\", option.None, decode.optional("
                      <> field_decoder
                      <> "))",
                  )
              }
          }
      }
    })

  // Decode additional_properties as Dict, then drop known property keys
  // so only unknown/extra keys remain in additional_properties.
  let known_keys_expr = case list.is_empty(props) {
    True -> "[]"
    False ->
      "["
      <> se.join_with(
        list.map(props, fn(entry) {
          let #(prop_name, _) = entry
          "\"" <> prop_name <> "\""
        }),
        ", ",
      )
      <> "]"
  }
  // For additionalProperties, decode the raw dict with dynamic values first
  // to avoid forcing the value decoder on known properties (which may have
  // incompatible types). Then drop known keys and decode remaining values.
  let sb = case additional_properties {
    Typed(ap_ref) -> {
      let inner_decoder =
        schema_ref_to_decoder(ap_ref, name, "additional_properties")
      sb
      |> se.indent(
        1,
        "use all_props <- decode.then(decode.dict(decode.string, decode.new_primitive_decoder(\"Dynamic\", fn(x) { Ok(x) })))",
      )
      |> se.indent(
        1,
        "let extra_props = dict.drop(all_props, " <> known_keys_expr <> ")",
      )
      |> se.indent(
        1,
        "let additional_properties_result = dict.fold(extra_props, Ok(dict.new()), fn(acc, k, v) {",
      )
      |> se.indent(2, "case acc {")
      |> se.indent(3, "Ok(decoded_acc) ->")
      |> se.indent(4, "case decode.run(v, " <> inner_decoder <> ") {")
      |> se.indent(5, "Ok(decoded) -> Ok(dict.insert(decoded_acc, k, decoded))")
      |> se.indent(5, "Error(_) -> Error(Nil)")
      |> se.indent(4, "}")
      |> se.indent(3, "Error(_) -> Error(Nil)")
      |> se.indent(2, "}")
      |> se.indent(1, "})")
      |> se.indent(
        1,
        "use additional_properties <- decode.then(case additional_properties_result {",
      )
      |> se.indent(2, "Ok(decoded) -> decode.success(decoded)")
      |> se.indent(
        2,
        "Error(_) -> decode.failure(dict.new(), \"additionalProperties\")",
      )
      |> se.indent(1, "})")
    }
    Untyped -> {
      sb
      |> se.indent(
        1,
        "use all_props <- decode.then(decode.dict(decode.string, decode.new_primitive_decoder(\"Dynamic\", fn(x) { Ok(x) })))",
      )
      |> se.indent(
        1,
        "let additional_properties = dict.drop(all_props, "
          <> known_keys_expr
          <> ")",
      )
    }
    Forbidden | Unspecified -> sb
  }

  let param_names =
    list.index_map(props, fn(entry, idx) {
      let #(prop_name, prop_ref) = entry
      let field_name =
        list_at_or(deduped_names, idx, naming.to_snake_case(prop_name))
      #(prop_name, prop_ref, field_name)
    })
    // Issue #309: constant properties are elided from the record, so
    // their decoder consumed-and-discarded the wire value above. They
    // must NOT appear in the success constructor's argument list.
    |> list.filter(fn(entry) {
      let #(prop_name, prop_ref, _) = entry
      option.is_none(schema_utils.constant_property_value(
        prop_ref,
        prop_name,
        required,
      ))
    })
    |> list.map(fn(entry) {
      let #(_, _, field_name) = entry
      field_name <> ": " <> field_name
    })

  // Add additional_properties to param names only when the generated record
  // surfaces the field (Typed or Untyped). Forbidden / Unspecified suppress
  // it — see Issue #249.
  let param_names = case additional_properties {
    Typed(_) | Untyped ->
      list.append(param_names, [
        "additional_properties: additional_properties",
      ])
    Forbidden | Unspecified -> param_names
  }

  let sb =
    sb
    |> se.indent(
      1,
      "decode.success(types."
        <> type_name
        <> "("
        <> se.join_with(param_names, ", ")
        <> "))",
    )

  let sb = sb |> se.line("}") |> se.blank_line()

  // json.parse wrapper
  let sb =
    sb
    |> se.line(
      "pub fn "
      <> fn_name
      <> "(json_string: String) -> Result(types."
      <> type_name
      <> ", json.DecodeError) {",
    )
    |> se.indent(1, "json.parse(json_string, " <> decoder_fn_name <> "())")
    |> se.line("}")
    |> se.blank_line()

  // List decoder for typed client array responses
  let list_fn_name = fn_name <> "_list"
  let list_decoder_fn_name = decoder_fn_name <> "_list"
  sb
  |> se.line(
    "pub fn "
    <> list_decoder_fn_name
    <> "() -> decode.Decoder(List(types."
    <> type_name
    <> ")) {",
  )
  |> se.indent(1, "decode.list(" <> decoder_fn_name <> "())")
  |> se.line("}")
  |> se.blank_line()
  |> se.line(
    "pub fn "
    <> list_fn_name
    <> "(json_string: String) -> Result(List(types."
    <> type_name
    <> "), json.DecodeError) {",
  )
  |> se.indent(1, "json.parse(json_string, " <> list_decoder_fn_name <> "())")
  |> se.line("}")
  |> se.blank_line()
}

/// Generate decoder for a string enum schema.
fn generate_enum_decoder(
  sb: se.StringBuilder,
  type_name: String,
  fn_name: String,
  decoder_fn_name: String,
  description: Option(String),
  enum_values: List(String),
) -> se.StringBuilder {
  let sb = maybe_doc_comment(sb, description)
  let sb =
    sb
    |> se.line(
      "pub fn "
      <> decoder_fn_name
      <> "() -> decode.Decoder(types."
      <> type_name
      <> ") {",
    )
    |> se.indent(1, "use value <- decode.then(decode.string)")
    |> se.indent(1, "case value {")

  let deduped_variants = dedup.dedup_enum_variants(enum_values)
  let sb =
    list.index_fold(enum_values, sb, fn(sb, value, idx) {
      let variant_suffix =
        list_at_or(deduped_variants, idx, naming.to_pascal_case(value))
      let variant = naming.schema_to_type_name(type_name) <> variant_suffix
      sb
      |> se.indent(
        2,
        "\"" <> value <> "\" -> decode.success(types." <> variant <> ")",
      )
    })

  // Unknown enum values → decode failure, not silent fallback
  let first_variant_suffix =
    list_at_or(deduped_variants, 0, case enum_values {
      [first, ..] -> naming.to_pascal_case(first)
      [] -> "Unknown"
    })
  sb
  |> se.indent(
    2,
    "_ -> decode.failure(types."
      <> naming.schema_to_type_name(type_name)
      <> first_variant_suffix
      <> ", \""
      <> type_name
      <> ": unknown variant \" <> value)",
  )
  |> se.indent(1, "}")
  |> se.line("}")
  |> se.blank_line()
  // json.parse wrapper
  |> se.line(
    "pub fn "
    <> fn_name
    <> "(json_string: String) -> Result(types."
    <> type_name
    <> ", json.DecodeError) {",
  )
  |> se.indent(1, "json.parse(json_string, " <> decoder_fn_name <> "())")
  |> se.line("}")
  |> se.blank_line()
}

/// Generate decoder for an anyOf (inclusive union) schema.
fn generate_anyof_decoder(
  sb: se.StringBuilder,
  type_name: String,
  fn_name: String,
  decoder_fn_name: String,
  description: Option(String),
  schemas: List(SchemaRef),
) -> se.StringBuilder {
  let sb = maybe_doc_comment(sb, description)

  // Generate field decoders that try each variant
  let variant_fields =
    list.map(schemas, fn(s_ref) {
      case s_ref {
        Reference(name: ref_name, ..) -> {
          let field_name = naming.to_snake_case(ref_name)
          let decoder_name =
            "decode_" <> naming.to_snake_case(ref_name) <> "_decoder"
          #(field_name, decoder_name, ref_name)
        }
        Inline(_) -> #("unknown", "decode.string", "Unknown")
      }
    })

  // Decoder function
  let sb =
    sb
    |> se.line(
      "pub fn "
      <> decoder_fn_name
      <> "() -> decode.Decoder(types."
      <> type_name
      <> ") {",
    )

  // Try each variant decoder, wrap in Some on success, None on failure
  let sb =
    list.fold(variant_fields, sb, fn(sb, field) {
      let #(field_name, decoder_name, _) = field
      sb
      |> se.indent(
        1,
        "use "
          <> field_name
          <> " <- decode.then(decode.one_of("
          <> decoder_name
          <> "() |> decode.map(option.Some), or: [decode.success(option.None)]))",
      )
    })

  // Construct the record
  let field_assignments =
    list.map(variant_fields, fn(f) {
      let #(field_name, _, _) = f
      field_name <> ": " <> field_name
    })
  sb
  |> se.indent(
    1,
    "decode.success(types."
      <> type_name
      <> "("
      <> string.join(field_assignments, ", ")
      <> "))",
  )
  |> se.line("}")
  |> se.blank_line()
  // JSON parse wrapper
  |> se.line(
    "pub fn "
    <> fn_name
    <> "(json_string: String) -> Result(types."
    <> type_name
    <> ", json.DecodeError) {",
  )
  |> se.indent(1, "json.parse(json_string, " <> decoder_fn_name <> "())")
  |> se.line("}")
  |> se.blank_line()
}

/// Generate decoder for a primitive type (String, Int, Float, Bool).
fn generate_primitive_decoder(
  sb: se.StringBuilder,
  fn_name: String,
  decoder_fn_name: String,
  gleam_type: String,
  decoder_expr: String,
) -> se.StringBuilder {
  sb
  |> se.line(
    "pub fn "
    <> decoder_fn_name
    <> "() -> decode.Decoder("
    <> gleam_type
    <> ") {",
  )
  |> se.indent(1, decoder_expr)
  |> se.line("}")
  |> se.blank_line()
  |> se.line(
    "pub fn "
    <> fn_name
    <> "(json_string: String) -> Result("
    <> gleam_type
    <> ", json.DecodeError) {",
  )
  |> se.indent(1, "json.parse(json_string, " <> decoder_expr <> ")")
  |> se.line("}")
  |> se.blank_line()
}

/// Generate decoder for an ArraySchema.
fn generate_array_decoder(
  sb: se.StringBuilder,
  name: String,
  fn_name: String,
  decoder_fn_name: String,
  items: SchemaRef,
  ctx: Context,
) -> se.StringBuilder {
  let inner_decoder = schema_ref_to_decoder(items, name, "")
  let inner_type = qualified_schema_ref_type(items, ctx)
  let gleam_type = "List(" <> inner_type <> ")"
  sb
  |> se.line(
    "pub fn "
    <> decoder_fn_name
    <> "() -> decode.Decoder("
    <> gleam_type
    <> ") {",
  )
  |> se.indent(1, "decode.list(" <> inner_decoder <> ")")
  |> se.line("}")
  |> se.blank_line()
  |> se.line(
    "pub fn "
    <> fn_name
    <> "(json_string: String) -> Result("
    <> gleam_type
    <> ", json.DecodeError) {",
  )
  |> se.indent(1, "json.parse(json_string, " <> decoder_fn_name <> "())")
  |> se.line("}")
  |> se.blank_line()
}

/// Generate decoder for oneOf/anyOf union types.
/// With discriminator: decode based on discriminator field value.
/// Without discriminator: try each variant decoder in order.
fn generate_oneof_decoder(
  sb: se.StringBuilder,
  _name: String,
  type_name: String,
  fn_name: String,
  decoder_fn_name: String,
  description: Option(String),
  schemas: List(SchemaRef),
  discriminator: Option(schema.Discriminator),
  _ctx: Context,
) -> se.StringBuilder {
  // Only handle $ref variants (inline primitives blocked by validator)
  let all_refs =
    list.all(schemas, fn(s) {
      case s {
        Reference(..) -> True
        _ -> False
      }
    })

  case all_refs {
    False -> sb
    True -> {
      let sb = maybe_doc_comment(sb, description)

      case discriminator {
        Some(disc) -> {
          // Discriminator-based decoder
          let sb =
            sb
            |> se.line(
              "pub fn "
              <> decoder_fn_name
              <> "() -> decode.Decoder(types."
              <> type_name
              <> ") {",
            )
            |> se.indent(
              1,
              "use disc_value <- decode.field(\""
                <> disc.property_name
                <> "\", decode.string)",
            )
            |> se.indent(1, "case disc_value {")

          let sb =
            list.fold(schemas, sb, fn(sb, s_ref) {
              case s_ref {
                Reference(ref:, name:) -> {
                  let ref_name = name
                  let variant_type = naming.schema_to_type_name(ref_name)
                  let variant_name = type_name <> variant_type
                  let variant_decoder =
                    naming.to_snake_case(ref_name) <> "_decoder()"
                  // Check discriminator mapping first, fallback to ref name
                  let disc_value = get_discriminator_value(disc, ref, ref_name)
                  sb
                  |> se.indent(2, "\"" <> disc_value <> "\" -> {")
                  |> se.indent(
                    3,
                    "use inner <- decode.then(" <> variant_decoder <> ")",
                  )
                  |> se.indent(
                    3,
                    "decode.success(types." <> variant_name <> "(inner))",
                  )
                  |> se.indent(2, "}")
                }
                _ -> sb
              }
            })

          // For unknown discriminator values, fail immediately with a
          // discriminator-specific error message. The second decode.then
          // is unreachable at runtime — the leading decode.failure short-
          // circuits decode.then, so the inner variant decoder is never
          // invoked — but it's required at compile time to give the case
          // branch the right Decoder(types.<TypeName>) type. Without this
          // structure, an unknown discriminator whose body also fails to
          // match the first variant would surface the *first variant's*
          // decode error instead of the discriminator error (issue #308).
          let first_ref_decoder = case schemas {
            [Reference(name:, ..), ..] -> {
              let ref_name = name
              naming.to_snake_case(ref_name) <> "_decoder()"
            }
            _ -> "decode.string"
          }
          let first_variant_name = case schemas {
            [Reference(name:, ..), ..] -> {
              let ref_name = name
              let variant_type = naming.schema_to_type_name(ref_name)
              "types." <> type_name <> variant_type
            }
            _ -> "types." <> type_name
          }

          // Build the "expected" list mirroring the discriminator values
          // each variant arm matches above. When the spec supplies an
          // explicit `mapping`, those keys win; otherwise each variant
          // falls back to its ref name (matching `get_discriminator_value`
          // semantics on lines 1099-1119).
          let valid_disc_values =
            schemas
            |> list.filter_map(fn(s_ref) {
              case s_ref {
                Reference(ref:, name:) ->
                  Ok(get_discriminator_value(disc, ref, name))
                _ -> Error(Nil)
              }
            })
            |> list.sort(string.compare)
            |> string.join("|")

          let sb =
            sb
            |> se.indent(2, "_ -> {")
            |> se.indent(
              3,
              "use _ <- decode.then(decode.failure(Nil, \""
                <> type_name
                <> ": unknown discriminator '\" <> disc_value <> \"' (expected "
                <> valid_disc_values
                <> ")\"))",
            )
            |> se.indent(3, "use v <- decode.then(" <> first_ref_decoder <> ")")
            |> se.indent(
              3,
              "decode.failure("
                <> first_variant_name
                <> "(v), \""
                <> type_name
                <> "\")",
            )
            |> se.indent(2, "}")
            |> se.indent(1, "}")
            |> se.line("}")
            |> se.blank_line()

          // json.parse wrapper
          sb
          |> se.line(
            "pub fn "
            <> fn_name
            <> "(json_string: String) -> Result(types."
            <> type_name
            <> ", json.DecodeError) {",
          )
          |> se.indent(
            1,
            "json.parse(json_string, " <> decoder_fn_name <> "())",
          )
          |> se.line("}")
          |> se.blank_line()
        }

        None -> {
          // No discriminator: generate a decode.Decoder that tries each variant
          let ref_variants =
            list.filter_map(schemas, fn(s_ref) {
              case s_ref {
                Reference(name:, ..) -> {
                  let ref_name = name
                  Ok(ref_name)
                }
                _ -> Error(Nil)
              }
            })

          let sb =
            sb
            |> se.line(
              "pub fn "
              <> decoder_fn_name
              <> "() -> decode.Decoder(types."
              <> type_name
              <> ") {",
            )

          // Build a chain of decode.one_of attempts
          let sb = case ref_variants {
            [] ->
              sb
              |> se.indent(
                1,
                "decode.failure(types."
                  <> type_name
                  <> ", \""
                  <> type_name
                  <> "\")",
              )
            [first, ..rest] -> {
              let first_variant_type = naming.schema_to_type_name(first)
              let first_decoder = naming.to_snake_case(first) <> "_decoder()"
              let sb =
                sb
                |> se.indent(
                  1,
                  "decode.one_of("
                    <> first_decoder
                    <> " |> decode.map(types."
                    <> type_name
                    <> first_variant_type
                    <> "), [",
                )
              let sb =
                list.fold(rest, sb, fn(sb, ref_name) {
                  let variant_type = naming.schema_to_type_name(ref_name)
                  let decoder = naming.to_snake_case(ref_name) <> "_decoder()"
                  sb
                  |> se.indent(
                    2,
                    decoder
                      <> " |> decode.map(types."
                      <> type_name
                      <> variant_type
                      <> "),",
                  )
                })
              sb |> se.indent(1, "])")
            }
          }

          let sb =
            sb
            |> se.line("}")
            |> se.blank_line()

          // json.parse wrapper
          sb
          |> se.line(
            "pub fn "
            <> fn_name
            <> "(json_string: String) -> Result(types."
            <> type_name
            <> ", json.DecodeError) {",
          )
          |> se.indent(
            1,
            "json.parse(json_string, " <> decoder_fn_name <> "())",
          )
          |> se.line("}")
          |> se.blank_line()
        }
      }
    }
  }
}

/// Get the discriminator value for a $ref.
/// OpenAPI discriminator.mapping is keyed by payload values, with $ref paths
/// as values: { "dog": "#/components/schemas/Dog" }.
/// Given a ref_name like "Dog", find the mapping key that points to it.
/// Falls back to ref_name if no explicit mapping exists.
fn get_discriminator_value(
  disc: schema.Discriminator,
  ref: String,
  ref_name: String,
) -> String {
  // Search mapping entries: key = discriminator value, value = $ref path or schema name
  let found =
    dict.to_list(disc.mapping)
    |> list.find(fn(entry) {
      let #(_disc_value, target) = entry
      // The target may be a full $ref path or just the schema name
      target == ref || resolver.ref_to_name(target) == ref_name
    })
  case found {
    Ok(#(disc_value, _)) -> disc_value
    // nolint: thrown_away_error -- missing mapping entry is expected; fall back to the ref name
    Error(_) -> ref_name
  }
}

/// Convert a SchemaRef to a decoder expression string.
/// parent_name is used to resolve inline enum decoder names.
fn schema_ref_to_decoder(
  ref: SchemaRef,
  parent_name: String,
  prop_name: String,
) -> String {
  case ref {
    Inline(StringSchema(enum_values:, ..)) if enum_values != [] -> {
      // Inline enum: use the generated enum decoder
      let decoder_name =
        naming.to_snake_case(
          naming.schema_to_type_name(parent_name)
          <> naming.schema_to_type_name(prop_name),
        )
      decoder_name <> "_decoder()"
    }
    Inline(ArraySchema(items:, ..)) -> {
      let inner = schema_ref_to_decoder(items, parent_name, prop_name)
      "decode.list(" <> inner <> ")"
    }
    _ -> schema_dispatch.decoder_expr(ref)
  }
}

/// Check if a SchemaRef has nullable: true.
fn schema_ref_is_nullable(ref: SchemaRef, ctx: Context) -> Bool {
  case ref {
    Inline(schema) -> schema.is_nullable(schema)
    Reference(..) ->
      case resolver.resolve_schema_ref(ref, context.spec(ctx)) {
        Ok(resolved_schema) -> schema.is_nullable(resolved_schema)
        // nolint: thrown_away_error -- unresolved refs are treated as non-nullable here; the spec validator reports the ref error separately
        Error(_) -> False
      }
  }
}

/// Get element at index from a list, or return a default.
fn list_at_or(lst: List(String), idx: Int, default: String) -> String {
  case lst, idx {
    [], _ -> default
    [head, ..], 0 -> head
    [_, ..rest], n -> list_at_or(rest, n - 1, default)
  }
}

/// Convert a SchemaRef to a qualified Gleam type string (with types. prefix for refs).
fn qualified_schema_ref_type(ref: SchemaRef, ctx: Context) -> String {
  case ref {
    Inline(schema) -> type_gen.schema_to_gleam_type(schema, ctx)
    _ -> schema_dispatch.schema_ref_qualified_type(ref)
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

/// Emit the decoder snippet for a constant (issue #309) field.
///
/// The wire value is required and fully determined at codegen time
/// (an inline `enum: [<single>]`). The decoder reads it as a string
/// and chains a `decode.then` that fails fast on any other value.
/// `_` discards the binding because the surrounding record has no
/// slot for the field. Failing on mismatch keeps the discriminator
/// contract honest — silently accepting `kind: "media"` where only
/// `kind: "text"` is legal would defeat the purpose of the enum.
fn emit_constant_field_decoder(
  sb: se.StringBuilder,
  prop_name: String,
  constant_value: String,
) -> se.StringBuilder {
  let escaped = escape_for_string_literal(constant_value)
  sb
  |> se.indent(
    1,
    "use _ <- decode.field(\""
      <> prop_name
      <> "\", decode.then(decode.string, fn(constant_value) {",
  )
  |> se.indent(2, "case constant_value {")
  |> se.indent(3, "\"" <> escaped <> "\" -> decode.success(Nil)")
  |> se.indent(
    3,
    "other -> decode.failure(Nil, \"expected "
      <> prop_name
      <> "=\\\""
      <> escaped
      <> "\\\", got \\\"\" <> other <> \"\\\"\")",
  )
  |> se.indent(2, "}")
  |> se.indent(1, "}))")
}

/// Escape a spec-derived string so it can be safely interpolated
/// inside a generated Gleam string literal. Mirrors the helper in
/// `encoders.gleam` — extracted here to keep the decoder module
/// self-contained for issue #309.
fn escape_for_string_literal(value: String) -> String {
  value
  |> string.replace(each: "\\", with: "\\\\")
  |> string.replace(each: "\"", with: "\\\"")
}
