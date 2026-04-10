import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/schema_dispatch
import oaspec/codegen/types as type_gen
import oaspec/openapi/dedup
import oaspec/openapi/operations
import oaspec/openapi/resolver
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  BooleanSchema, Forbidden, Inline, IntegerSchema, NumberSchema, ObjectSchema,
  OneOfSchema, Reference, StringSchema, Typed, Untyped,
}
import oaspec/openapi/spec.{type Resolved, Value}
import oaspec/util/http
import oaspec/util/naming
import oaspec/util/string_extra as se

/// Generate decoder and encoder modules.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let decode_content = generate_decoders(ctx)
  let encode_content = generate_encoders(ctx)

  [
    GeneratedFile(
      path: "decode.gleam",
      content: decode_content,
      target: context.SharedTarget,
    ),
    GeneratedFile(
      path: "encode.gleam",
      content: encode_content,
      target: context.SharedTarget,
    ),
  ]
}

// ===================================================================
// Decoders
// ===================================================================

/// Generate JSON decoders for all component schemas and anonymous types.
fn generate_decoders(ctx: Context) -> String {
  let schemas = case ctx.spec.components {
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
    True -> list.append(base_imports, [ctx.config.package <> "/types"])
    False -> base_imports
  }
  let imports = case needs_option {
    True -> list.append(base_imports, ["gleam/option"])
    False -> base_imports
  }

  let sb =
    se.file_header(context.version)
    |> se.imports(imports)

  let schemas = case ctx.spec.components {
    Some(components) ->
      list.sort(dict.to_list(components.schemas), fn(a, b) {
        string.compare(a.0, b.0)
      })
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
  let sb = generate_anonymous_decoders(sb, ctx)

  se.to_string(sb)
}

/// Generate decoders for anonymous inline schemas (response/requestBody).
fn generate_anonymous_decoders(
  sb: se.StringBuilder,
  ctx: Context,
) -> se.StringBuilder {
  let operations = operations.collect_operations(ctx)
  list.fold(operations, sb, fn(sb, op) {
    let #(op_id, operation, _path, _method) = op
    let sb = generate_anonymous_response_decoders(sb, op_id, operation, ctx)
    let sb = generate_anonymous_request_body_decoder(sb, op_id, operation, ctx)
    sb
  })
}

/// Generate decoders for inline response schemas.
fn generate_anonymous_response_decoders(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation(Resolved),
  ctx: Context,
) -> se.StringBuilder {
  let responses = dict.to_list(operation.responses)
  list.fold(responses, sb, fn(sb, entry) {
    let #(status_code, ref_or_response) = entry
    case ref_or_response {
      Value(response) -> {
        let content_entries = dict.to_list(response.content)
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
      let content_entries = dict.to_list(rb.content)
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
  let props = case schema_ref {
    Inline(ObjectSchema(properties:, ..)) -> dict.to_list(properties)
    Inline(AllOfSchema(schemas:, ..)) -> {
      let merged =
        list.fold(schemas, dict.new(), fn(acc, s_ref) {
          case s_ref {
            Inline(ObjectSchema(properties:, ..)) -> dict.merge(acc, properties)
            Reference(..) ->
              case resolver.resolve_schema_ref(s_ref, ctx.spec) {
                Ok(ObjectSchema(properties:, ..)) -> dict.merge(acc, properties)
                _ -> acc
              }
            _ -> acc
          }
        })
      dict.to_list(merged)
    }
    _ -> []
  }
  list.fold(props, sb, fn(sb, entry) {
    let #(prop_name, prop_ref) = entry
    case prop_ref {
      Inline(StringSchema(enum_values:, ..)) if enum_values != [] -> {
        let enum_name =
          naming.schema_to_type_name(parent_name)
          <> naming.schema_to_type_name(prop_name)
        generate_decoder(sb, enum_name, prop_ref, ctx)
      }
      _ -> sb
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
    )) -> {
      let sb = maybe_doc_comment(sb, metadata.description)
      let sb =
        sb
        |> se.line(
          "pub fn "
          <> decoder_fn_name
          <> "() -> decode.Decoder(types."
          <> type_name
          <> ") {",
        )

      let props = dict.to_list(properties)
      let deduped_names =
        dedup.dedup_property_names(list.map(props, fn(e) { e.0 }))
      let sb =
        list.index_fold(props, sb, fn(sb, entry, idx) {
          let #(prop_name, prop_ref) = entry
          let field_name =
            list_at_or(deduped_names, idx, naming.to_snake_case(prop_name))
          // writeOnly fields may not appear in responses, so treat them
          // as optional even if listed in required
          let is_write_only = type_gen.schema_ref_is_write_only(prop_ref, ctx)
          let is_required = list.contains(required, prop_name) && !is_write_only
          let field_decoder =
            schema_ref_to_decoder(prop_ref, name, prop_name, ctx)
          let is_nullable_schema = schema_ref_is_nullable(prop_ref, ctx)

          // For nullable schemas, the Gleam type is Option(T),
          // so the decoder must be decode.optional(inner_decoder).
          let effective_decoder = case is_nullable_schema {
            True -> "decode.optional(" <> field_decoder <> ")"
            False -> field_decoder
          }

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
            schema_ref_to_decoder(ap_ref, name, "additional_properties", ctx)
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
          |> se.indent(
            5,
            "Ok(decoded) -> Ok(dict.insert(decoded_acc, k, decoded))",
          )
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
        Forbidden -> sb
      }

      let param_names =
        list.index_map(props, fn(entry, idx) {
          let #(prop_name, _) = entry
          let field_name =
            list_at_or(deduped_names, idx, naming.to_snake_case(prop_name))
          field_name <> ": " <> field_name
        })

      // Add additional_properties to param names if present
      let param_names = case additional_properties {
        Typed(_) | Untyped ->
          list.append(param_names, [
            "additional_properties: additional_properties",
          ])
        Forbidden -> param_names
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
      let sb =
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
        |> se.indent(
          1,
          "json.parse(json_string, " <> list_decoder_fn_name <> "())",
        )
        |> se.line("}")
        |> se.blank_line()

      sb
    }

    Inline(StringSchema(metadata:, enum_values:, ..)) if enum_values != [] -> {
      let sb = maybe_doc_comment(sb, metadata.description)
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
      let sb =
        sb
        |> se.indent(
          2,
          "_ -> decode.failure(types."
            <> naming.schema_to_type_name(type_name)
            <> first_variant_suffix
            <> ", \""
            <> type_name
            <> "\")",
        )
        |> se.indent(1, "}")
        |> se.line("}")
        |> se.blank_line()

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

      sb
    }

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

    Inline(OneOfSchema(metadata:, schemas:, discriminator:)) -> {
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
    }

    Inline(AnyOfSchema(metadata:, schemas:, ..)) -> {
      // anyOf = inclusive union: try all sub-decoders, collect successes
      let sb = maybe_doc_comment(sb, metadata.description)

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
              <> " <- decode.then(decode.one_of(["
              <> decoder_name
              <> "() |> decode.map(option.Some)], option.None))",
          )
        })

      // Construct the record
      let field_assignments =
        list.map(variant_fields, fn(f) {
          let #(field_name, _, _) = f
          field_name <> ": " <> field_name
        })
      let sb =
        sb
        |> se.indent(
          1,
          "decode.success(types."
            <> type_name
            <> "("
            <> string.join(field_assignments, ", ")
            <> "))",
        )
      let sb = sb |> se.line("}") |> se.blank_line()

      // JSON parse wrapper
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

      sb
    }

    // Primitive schemas: generate decoder/encoder wrappers
    // Nullable primitives use decode.optional / Option(T) types.
    Inline(StringSchema(metadata:, enum_values: [], ..)) -> {
      let #(gleam_type, decoder_expr) = case metadata.nullable {
        True -> #("Option(String)", "decode.optional(decode.string)")
        False -> #("String", "decode.string")
      }
      let sb =
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
      sb
    }

    Inline(IntegerSchema(metadata:, ..)) -> {
      let #(gleam_type, decoder_expr) = case metadata.nullable {
        True -> #("Option(Int)", "decode.optional(decode.int)")
        False -> #("Int", "decode.int")
      }
      let sb =
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
      sb
    }

    Inline(NumberSchema(metadata:, ..)) -> {
      let #(gleam_type, decoder_expr) = case metadata.nullable {
        True -> #("Option(Float)", "decode.optional(decode.float)")
        False -> #("Float", "decode.float")
      }
      let sb =
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
      sb
    }

    Inline(BooleanSchema(metadata:)) -> {
      let #(gleam_type, decoder_expr) = case metadata.nullable {
        True -> #("Option(Bool)", "decode.optional(decode.bool)")
        False -> #("Bool", "decode.bool")
      }
      let sb =
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
      sb
    }

    Inline(ArraySchema(items:, ..)) -> {
      let inner_decoder = schema_ref_to_decoder(items, name, "", ctx)
      let inner_type = qualified_schema_ref_type(items, ctx)
      let gleam_type = "List(" <> inner_type <> ")"
      let sb =
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
      sb
    }

    _ -> sb
  }
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
  ctx: Context,
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

          // For unknown discriminator values, decode as the first variant
          // then immediately fail. This avoids needing a placeholder value
          // while maintaining the correct return type.
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

          let sb =
            sb
            |> se.indent(2, "_ -> {")
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
          let sb =
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

          sb
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
          let sb =
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

          let _ = ctx
          sb
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
    Error(_) -> ref_name
  }
}

/// Convert a SchemaRef to a decoder expression string.
/// parent_name is used to resolve inline enum decoder names.
fn schema_ref_to_decoder(
  ref: SchemaRef,
  parent_name: String,
  prop_name: String,
  ctx: Context,
) -> String {
  let _ = ctx
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
      let inner = schema_ref_to_decoder(items, parent_name, prop_name, ctx)
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
      case resolver.resolve_schema_ref(ref, ctx.spec) {
        Ok(s) -> schema.is_nullable(s)
        Error(_) -> False
      }
  }
}

// ===================================================================
// Encoders
// ===================================================================

/// Generate JSON encoders for all component schemas and anonymous types.
fn generate_encoders(ctx: Context) -> String {
  let schemas = case ctx.spec.components {
    Some(components) ->
      list.sort(dict.to_list(components.schemas), fn(a, b) {
        string.compare(a.0, b.0)
      })
    None -> []
  }

  // Check if types module is needed
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

  // Check if dict/list modules are needed (for additionalProperties encoding)
  let needs_dict =
    list.any(schemas, fn(entry) {
      let #(_, schema_ref) = entry
      case schema_ref {
        Inline(ObjectSchema(additional_properties: Typed(_), ..)) -> True
        Inline(ObjectSchema(additional_properties: Untyped, ..)) -> True
        _ -> False
      }
    })

  // Check if dynamic module is needed (for untyped additionalProperties encoding)
  let needs_dynamic =
    list.any(schemas, fn(entry) {
      let #(_, schema_ref) = entry
      case schema_ref {
        Inline(ObjectSchema(additional_properties: Untyped, ..)) -> True
        _ -> False
      }
    })

  let base_imports = case needs_dict, needs_dynamic {
    True, True -> [
      "gleam/dict",
      "gleam/dynamic",
      "gleam/dynamic/decode",
      "gleam/json",
      "gleam/list",
    ]
    True, False -> ["gleam/dict", "gleam/json", "gleam/list"]
    _, _ -> ["gleam/json"]
  }
  let imports = case needs_types {
    True -> list.append(base_imports, [ctx.config.package <> "/types"])
    False -> base_imports
  }

  let sb =
    se.file_header(context.version)
    |> se.imports(imports)

  // First pass: generate inline enum encoders
  let sb =
    list.fold(schemas, sb, fn(sb, entry) {
      let #(name, schema_ref) = entry
      generate_inline_enum_encoders(sb, name, schema_ref, ctx)
    })

  // Second pass: generate main type encoders
  let sb =
    list.fold(schemas, sb, fn(sb, entry) {
      let #(name, schema_ref) = entry
      generate_encoder(sb, name, schema_ref, ctx)
    })

  // Generate encoders for anonymous inline schemas from operations
  let sb = generate_anonymous_encoders(sb, ctx)

  // Generate encode_dynamic helper if needed for untyped additionalProperties
  let sb = case needs_dynamic {
    True ->
      sb
      |> se.doc_comment(
        "Encode a Dynamic value to JSON by inspecting its runtime type.",
      )
      |> se.line("fn encode_dynamic(value: dynamic.Dynamic) -> json.Json {")
      |> se.indent(1, "case dynamic.classify(value) {")
      |> se.indent(2, "\"String\" -> {")
      |> se.indent(3, "let assert Ok(s) = decode.run(value, decode.string)")
      |> se.indent(3, "json.string(s)")
      |> se.indent(2, "}")
      |> se.indent(2, "\"Int\" -> {")
      |> se.indent(3, "let assert Ok(i) = decode.run(value, decode.int)")
      |> se.indent(3, "json.int(i)")
      |> se.indent(2, "}")
      |> se.indent(2, "\"Float\" -> {")
      |> se.indent(3, "let assert Ok(f) = decode.run(value, decode.float)")
      |> se.indent(3, "json.float(f)")
      |> se.indent(2, "}")
      |> se.indent(2, "\"Bool\" -> {")
      |> se.indent(3, "let assert Ok(b) = decode.run(value, decode.bool)")
      |> se.indent(3, "json.bool(b)")
      |> se.indent(2, "}")
      |> se.indent(2, "\"Nil\" -> json.null()")
      |> se.indent(2, "_ -> json.string(dynamic.classify(value))")
      |> se.indent(1, "}")
      |> se.line("}")
      |> se.blank_line()
    False -> sb
  }

  se.to_string(sb)
}

/// Generate inline enum encoders found in object/allOf properties.
fn generate_inline_enum_encoders(
  sb: se.StringBuilder,
  parent_name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> se.StringBuilder {
  let props = case schema_ref {
    Inline(ObjectSchema(properties:, ..)) -> dict.to_list(properties)
    Inline(AllOfSchema(schemas:, ..)) -> {
      let merged =
        list.fold(schemas, dict.new(), fn(acc, s_ref) {
          case s_ref {
            Inline(ObjectSchema(properties:, ..)) -> dict.merge(acc, properties)
            Reference(..) ->
              case resolver.resolve_schema_ref(s_ref, ctx.spec) {
                Ok(ObjectSchema(properties:, ..)) -> dict.merge(acc, properties)
                _ -> acc
              }
            _ -> acc
          }
        })
      dict.to_list(merged)
    }
    _ -> []
  }
  list.fold(props, sb, fn(sb, entry) {
    let #(prop_name, prop_ref) = entry
    case prop_ref {
      Inline(StringSchema(enum_values:, ..)) if enum_values != [] -> {
        let enum_name =
          naming.schema_to_type_name(parent_name)
          <> naming.schema_to_type_name(prop_name)
        generate_encoder(sb, enum_name, prop_ref, ctx)
      }
      _ -> sb
    }
  })
}

/// Generate encoders for anonymous inline schemas (response/requestBody).
fn generate_anonymous_encoders(
  sb: se.StringBuilder,
  ctx: Context,
) -> se.StringBuilder {
  let operations = operations.collect_operations(ctx)
  list.fold(operations, sb, fn(sb, op) {
    let #(op_id, operation, _path, _method) = op
    // Only requestBody inline schemas need encoders (for client body encoding)
    generate_anonymous_request_body_encoder(sb, op_id, operation, ctx)
  })
}

/// Generate encoder for an inline requestBody schema.
fn generate_anonymous_request_body_encoder(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation(Resolved),
  ctx: Context,
) -> se.StringBuilder {
  case operation.request_body {
    Some(Value(rb)) -> {
      let content_entries = dict.to_list(rb.content)
      case content_entries {
        [#(_, media_type), ..] ->
          case media_type.schema {
            Some(Inline(schema_obj)) -> {
              // Filter out readOnly properties from request body encoders
              let filtered_schema =
                type_gen.filter_read_only_properties(schema_obj, ctx)
              let name = naming.to_snake_case(op_id) <> "_request_body"
              generate_encoder(sb, name, Inline(filtered_schema), ctx)
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

/// Generate an encoder function for a schema.
/// Each type gets two functions:
///   encode_x_json(value) -> json.Json  (for composition in objects)
///   encode_x(value) -> String          (for standalone use)
fn generate_encoder(
  sb: se.StringBuilder,
  name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> se.StringBuilder {
  let type_name = naming.schema_to_type_name(name)
  let fn_name = "encode_" <> naming.to_snake_case(name)
  let json_fn_name = fn_name <> "_json"

  case schema_ref {
    Inline(ObjectSchema(properties:, required:, additional_properties:, ..)) -> {
      // _json version: returns json.Json
      let sb =
        sb
        |> se.line(
          "pub fn "
          <> json_fn_name
          <> "(value: types."
          <> type_name
          <> ") -> json.Json {",
        )

      // When additional_properties exist, we merge fixed props with dict entries
      let has_ap = additional_properties != Forbidden
      let sb = case has_ap {
        True ->
          sb
          |> se.indent(1, "let base_props = [")
        False ->
          sb
          |> se.indent(1, "json.object([")
      }

      // Filter out readOnly properties -- they should not be sent to the server
      let all_props = dict.to_list(properties)
      let all_deduped_names =
        dedup.dedup_property_names(list.map(all_props, fn(e) { e.0 }))
      // Build list of (prop_name, prop_ref, field_name) with readOnly filtered out
      let props_with_names =
        list.index_map(all_props, fn(entry, idx) {
          let #(prop_name, prop_ref) = entry
          let field_name =
            list_at_or(all_deduped_names, idx, naming.to_snake_case(prop_name))
          #(prop_name, prop_ref, field_name)
        })
        |> list.filter(fn(entry) {
          let #(_, prop_ref, _) = entry
          !type_gen.schema_ref_is_read_only(prop_ref, ctx)
        })
      let sb =
        list.index_fold(props_with_names, sb, fn(sb, entry, idx) {
          let #(prop_name, prop_ref, field_name) = entry
          let is_required = list.contains(required, prop_name)
          let trailing = case idx == list.length(props_with_names) - 1 {
            True -> ""
            False -> ","
          }

          let encoder_expr =
            schema_ref_to_json_encoder(
              "value." <> field_name,
              prop_ref,
              name,
              prop_name,
              ctx,
            )

          case is_required {
            True ->
              sb
              |> se.indent(
                2,
                "#(\"" <> prop_name <> "\", " <> encoder_expr <> ")" <> trailing,
              )
            False ->
              sb
              |> se.indent(
                2,
                "#(\""
                  <> prop_name
                  <> "\", json.nullable(value."
                  <> field_name
                  <> ", "
                  <> schema_ref_to_json_encoder_fn(
                  prop_ref,
                  name,
                  prop_name,
                  ctx,
                )
                  <> "))"
                  <> trailing,
              )
          }
        })

      let sb = case additional_properties {
        Typed(ap_ref) -> {
          let inner_encoder_fn =
            schema_ref_to_json_encoder_fn(
              ap_ref,
              name,
              "additional_properties",
              ctx,
            )
          sb
          |> se.indent(1, "]")
          |> se.indent(
            1,
            "let extra_props = dict.to_list(value.additional_properties) |> list.map(fn(entry) { let #(k, v) = entry; #(k, "
              <> inner_encoder_fn
              <> "(v)) })",
          )
          |> se.indent(1, "json.object(list.append(base_props, extra_props))")
        }
        Untyped -> {
          // Untyped additional_properties (Dynamic) are re-encoded using
          // dynamic type inspection to preserve round-trip fidelity.
          sb
          |> se.indent(1, "]")
          |> se.indent(
            1,
            "let extra_props = dict.to_list(value.additional_properties) |> list.map(fn(entry) { let #(k, v) = entry\n  #(k, encode_dynamic(v)) })",
          )
          |> se.indent(1, "json.object(list.append(base_props, extra_props))")
        }
        Forbidden ->
          sb
          |> se.indent(1, "])")
      }

      let sb =
        sb
        |> se.line("}")
        |> se.blank_line()

      // String version: wraps _json
      let sb =
        sb
        |> se.line(
          "pub fn "
          <> fn_name
          <> "(value: types."
          <> type_name
          <> ") -> String {",
        )
        |> se.indent(1, json_fn_name <> "(value) |> json.to_string()")
        |> se.line("}")
        |> se.blank_line()

      sb
    }

    Inline(StringSchema(enum_values:, ..)) if enum_values != [] -> {
      let enc_deduped_variants = dedup.dedup_enum_variants(enum_values)
      // _json version: returns json.Json
      let sb =
        sb
        |> se.line(
          "pub fn "
          <> json_fn_name
          <> "(value: types."
          <> type_name
          <> ") -> json.Json {",
        )
        |> se.indent(1, "let str = case value {")

      let sb =
        list.index_fold(enum_values, sb, fn(sb, value, idx) {
          let variant_suffix =
            list_at_or(enc_deduped_variants, idx, naming.to_pascal_case(value))
          let variant = naming.schema_to_type_name(type_name) <> variant_suffix
          sb
          |> se.indent(2, "types." <> variant <> " -> \"" <> value <> "\"")
        })

      let sb =
        sb
        |> se.indent(1, "}")
        |> se.indent(1, "json.string(str)")
        |> se.line("}")
        |> se.blank_line()

      // String version (JSON-encoded with quotes)
      let sb =
        sb
        |> se.line(
          "pub fn "
          <> fn_name
          <> "(value: types."
          <> type_name
          <> ") -> String {",
        )
        |> se.indent(1, json_fn_name <> "(value) |> json.to_string()")
        |> se.line("}")
        |> se.blank_line()

      // Plain string version for URL/header serialization (no JSON quotes)
      let to_string_fn_name = fn_name <> "_to_string"
      let sb =
        sb
        |> se.line(
          "pub fn "
          <> to_string_fn_name
          <> "(value: types."
          <> type_name
          <> ") -> String {",
        )
        |> se.indent(1, "case value {")

      let sb =
        list.index_fold(enum_values, sb, fn(sb, value, idx) {
          let variant_suffix =
            list_at_or(enc_deduped_variants, idx, naming.to_pascal_case(value))
          let variant = naming.schema_to_type_name(type_name) <> variant_suffix
          sb
          |> se.indent(2, "types." <> variant <> " -> \"" <> value <> "\"")
        })

      let sb =
        sb
        |> se.indent(1, "}")
        |> se.line("}")
        |> se.blank_line()

      sb
    }

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
      generate_encoder(sb, name, merged_schema, ctx)
    }

    Inline(OneOfSchema(schemas:, ..)) -> {
      // oneOf encoder: pattern match on tagged union variants
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
          let sb =
            sb
            |> se.line(
              "pub fn "
              <> json_fn_name
              <> "(value: types."
              <> type_name
              <> ") -> json.Json {",
            )
            |> se.indent(1, "case value {")
          let sb =
            list.fold(schemas, sb, fn(sb, s_ref) {
              case s_ref {
                Reference(name:, ..) -> {
                  let variant_type = naming.schema_to_type_name(name)
                  let variant_name = type_name <> variant_type
                  let inner_encoder =
                    "encode_" <> naming.to_snake_case(name) <> "_json"
                  sb
                  |> se.indent(
                    2,
                    "types."
                      <> variant_name
                      <> "(inner) -> "
                      <> inner_encoder
                      <> "(inner)",
                  )
                }
                _ -> sb
              }
            })
          let sb =
            sb
            |> se.indent(1, "}")
            |> se.line("}")
            |> se.blank_line()
          let sb =
            sb
            |> se.line(
              "pub fn "
              <> fn_name
              <> "(value: types."
              <> type_name
              <> ") -> String {",
            )
            |> se.indent(1, json_fn_name <> "(value) |> json.to_string()")
            |> se.line("}")
            |> se.blank_line()
          sb
        }
      }
    }

    Inline(AnyOfSchema(schemas:, ..)) -> {
      // anyOf encoder: encode the first non-None field from the record
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
          let variant_fields =
            list.map(schemas, fn(s_ref) {
              case s_ref {
                Reference(name:, ..) -> #(
                  naming.to_snake_case(name),
                  "encode_" <> naming.to_snake_case(name) <> "_json",
                )
                Inline(_) -> #("unknown", "json.null")
              }
            })
          // _json version: try each field in order, encode first Some
          let sb =
            sb
            |> se.line(
              "pub fn "
              <> json_fn_name
              <> "(value: types."
              <> type_name
              <> ") -> json.Json {",
            )
          let sb =
            list.fold(variant_fields, sb, fn(sb, field) {
              let #(field_name, encoder_fn) = field
              sb
              |> se.indent(1, "case value." <> field_name <> " {")
              |> se.indent(2, "option.Some(v) -> " <> encoder_fn <> "(v)")
              |> se.indent(2, "option.None ->")
            })
          let sb =
            sb
            |> se.indent({ list.length(variant_fields) + 1 }, "json.null()")
          // Close all the case expressions
          let sb =
            list.fold(variant_fields, sb, fn(sb, _) { sb |> se.indent(1, "}") })
          let sb =
            sb
            |> se.line("}")
            |> se.blank_line()
          // String version
          let sb =
            sb
            |> se.line(
              "pub fn "
              <> fn_name
              <> "(value: types."
              <> type_name
              <> ") -> String {",
            )
            |> se.indent(1, json_fn_name <> "(value) |> json.to_string()")
            |> se.line("}")
            |> se.blank_line()
          sb
        }
      }
    }

    // Primitive schemas: generate encoder wrappers
    // Nullable primitives use json.nullable / Option(T) types.
    Inline(StringSchema(metadata:, enum_values: [], ..)) -> {
      let #(gleam_type, json_expr) = case metadata.nullable {
        True -> #("Option(String)", "json.nullable(value, json.string)")
        False -> #("String", "json.string(value)")
      }
      sb
      |> se.line(
        "pub fn "
        <> json_fn_name
        <> "(value: "
        <> gleam_type
        <> ") -> json.Json {",
      )
      |> se.indent(1, json_expr)
      |> se.line("}")
      |> se.blank_line()
      |> se.line(
        "pub fn " <> fn_name <> "(value: " <> gleam_type <> ") -> String {",
      )
      |> se.indent(1, json_fn_name <> "(value) |> json.to_string()")
      |> se.line("}")
      |> se.blank_line()
    }

    Inline(IntegerSchema(metadata:, ..)) -> {
      let #(gleam_type, json_expr) = case metadata.nullable {
        True -> #("Option(Int)", "json.nullable(value, json.int)")
        False -> #("Int", "json.int(value)")
      }
      sb
      |> se.line(
        "pub fn "
        <> json_fn_name
        <> "(value: "
        <> gleam_type
        <> ") -> json.Json {",
      )
      |> se.indent(1, json_expr)
      |> se.line("}")
      |> se.blank_line()
      |> se.line(
        "pub fn " <> fn_name <> "(value: " <> gleam_type <> ") -> String {",
      )
      |> se.indent(1, json_fn_name <> "(value) |> json.to_string()")
      |> se.line("}")
      |> se.blank_line()
    }

    Inline(NumberSchema(metadata:, ..)) -> {
      let #(gleam_type, json_expr) = case metadata.nullable {
        True -> #("Option(Float)", "json.nullable(value, json.float)")
        False -> #("Float", "json.float(value)")
      }
      sb
      |> se.line(
        "pub fn "
        <> json_fn_name
        <> "(value: "
        <> gleam_type
        <> ") -> json.Json {",
      )
      |> se.indent(1, json_expr)
      |> se.line("}")
      |> se.blank_line()
      |> se.line(
        "pub fn " <> fn_name <> "(value: " <> gleam_type <> ") -> String {",
      )
      |> se.indent(1, json_fn_name <> "(value) |> json.to_string()")
      |> se.line("}")
      |> se.blank_line()
    }

    Inline(BooleanSchema(metadata:)) -> {
      let #(gleam_type, json_expr) = case metadata.nullable {
        True -> #("Option(Bool)", "json.nullable(value, json.bool)")
        False -> #("Bool", "json.bool(value)")
      }
      sb
      |> se.line(
        "pub fn "
        <> json_fn_name
        <> "(value: "
        <> gleam_type
        <> ") -> json.Json {",
      )
      |> se.indent(1, json_expr)
      |> se.line("}")
      |> se.blank_line()
      |> se.line(
        "pub fn " <> fn_name <> "(value: " <> gleam_type <> ") -> String {",
      )
      |> se.indent(1, json_fn_name <> "(value) |> json.to_string()")
      |> se.line("}")
      |> se.blank_line()
    }

    Inline(ArraySchema(items:, ..)) -> {
      let inner_type = qualified_schema_ref_type(items, ctx)
      let gleam_type = "List(" <> inner_type <> ")"
      let inner_encoder = schema_ref_to_json_encoder_fn(items, name, "", ctx)
      sb
      |> se.line(
        "pub fn "
        <> json_fn_name
        <> "(value: "
        <> gleam_type
        <> ") -> json.Json {",
      )
      |> se.indent(1, "json.array(value, " <> inner_encoder <> ")")
      |> se.line("}")
      |> se.blank_line()
      |> se.line(
        "pub fn " <> fn_name <> "(value: " <> gleam_type <> ") -> String {",
      )
      |> se.indent(1, json_fn_name <> "(value) |> json.to_string()")
      |> se.line("}")
      |> se.blank_line()
    }

    _ -> sb
  }
}

/// Convert a SchemaRef to a json.Json encoder expression.
/// Returns an expression that produces json.Json (not String).
fn schema_ref_to_json_encoder(
  value_expr: String,
  ref: SchemaRef,
  parent_name: String,
  prop_name: String,
  ctx: Context,
) -> String {
  case ref {
    Inline(StringSchema(enum_values:, ..)) if enum_values != [] -> {
      let fn_name =
        "encode_"
        <> naming.to_snake_case(
          naming.schema_to_type_name(parent_name)
          <> naming.schema_to_type_name(prop_name),
        )
        <> "_json"
      fn_name <> "(" <> value_expr <> ")"
    }
    Inline(ArraySchema(items:, ..)) -> {
      let inner_fn =
        schema_ref_to_json_encoder_fn(items, parent_name, prop_name, ctx)
      "json.array(" <> value_expr <> ", " <> inner_fn <> ")"
    }
    _ -> schema_dispatch.json_encoder_expr(ref, value_expr)
  }
}

/// Convert a SchemaRef to a json.Json encoder function reference.
/// Used for json.nullable(value, <fn>) and json.array(list, <fn>).
fn schema_ref_to_json_encoder_fn(
  ref: SchemaRef,
  parent_name: String,
  prop_name: String,
  ctx: Context,
) -> String {
  let _ = ctx
  case ref {
    Inline(StringSchema(enum_values:, ..)) if enum_values != [] -> {
      "encode_"
      <> naming.to_snake_case(
        naming.schema_to_type_name(parent_name)
        <> naming.schema_to_type_name(prop_name),
      )
      <> "_json"
    }
    Inline(ArraySchema(items:, ..)) -> {
      let inner =
        schema_ref_to_json_encoder_fn(items, parent_name, prop_name, ctx)
      "fn(items) { json.array(items, " <> inner <> ") }"
    }
    _ -> schema_dispatch.json_encoder_fn(ref)
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
