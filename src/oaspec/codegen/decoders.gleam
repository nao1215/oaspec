import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/types as type_gen
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

/// Generate decoder and encoder modules.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let decode_content = generate_decoders(ctx)
  let encode_content = generate_encoders(ctx)

  [
    GeneratedFile(path: "decode.gleam", content: decode_content),
    GeneratedFile(path: "encode.gleam", content: encode_content),
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

  // Check if dynamic module is needed (any schema with additionalProperties —
  // both typed and untyped use dynamic.dynamic for safe initial dict decode)
  let needs_dynamic =
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

  let base_imports = case needs_dict, needs_dynamic {
    True, True -> [
      "gleam/dict",
      "gleam/dynamic",
      "gleam/dynamic/decode",
      "gleam/json",
    ]
    True, False -> ["gleam/dict", "gleam/dynamic/decode", "gleam/json"]
    False, True -> ["gleam/dynamic", "gleam/dynamic/decode", "gleam/json"]
    False, False -> ["gleam/dynamic/decode", "gleam/json"]
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
  let operations = type_gen.collect_operations(ctx)
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
  operation: spec.Operation,
  ctx: Context,
) -> se.StringBuilder {
  let responses = dict.to_list(operation.responses)
  list.fold(responses, sb, fn(sb, entry) {
    let #(status_code, response) = entry
    let content_entries = dict.to_list(response.content)
    case content_entries {
      [#(_, media_type), ..] ->
        case media_type.schema {
          Some(Inline(schema_obj)) -> {
            let suffix = "Response" <> http.status_code_suffix(status_code)
            generate_anonymous_schema_decoder(
              sb,
              op_id,
              suffix,
              schema_obj,
              ctx,
            )
          }
          _ -> sb
        }
      _ -> sb
    }
  })
}

/// Generate decoder for an inline requestBody schema.
fn generate_anonymous_request_body_decoder(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation,
  ctx: Context,
) -> se.StringBuilder {
  case operation.request_body {
    Some(rb) -> {
      let content_entries = dict.to_list(rb.content)
      case content_entries {
        [#(_, media_type), ..] ->
          case media_type.schema {
            Some(Inline(schema_obj)) ->
              generate_anonymous_schema_decoder(
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
            Reference(_) ->
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
      description:,
      properties:,
      required:,
      nullable:,
      additional_properties:,
      additional_properties_untyped:,
    )) -> {
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

      let props = dict.to_list(properties)
      let sb =
        list.fold(props, sb, fn(sb, entry) {
          let #(prop_name, prop_ref) = entry
          let field_name = naming.to_snake_case(prop_name)
          let is_required = list.contains(required, prop_name)
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
      let sb = case additional_properties, additional_properties_untyped {
        Some(ap_ref), _ -> {
          let inner_decoder =
            schema_ref_to_decoder(ap_ref, name, "additional_properties", ctx)
          sb
          |> se.indent(
            1,
            "use all_props <- decode.then(decode.dict(decode.string, dynamic.dynamic))",
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
        None, True -> {
          sb
          |> se.indent(
            1,
            "use all_props <- decode.then(decode.dict(decode.string, dynamic.dynamic))",
          )
          |> se.indent(
            1,
            "let additional_properties = dict.drop(all_props, "
              <> known_keys_expr
              <> ")",
          )
        }
        None, False -> sb
      }

      let param_names =
        list.map(props, fn(entry) {
          let #(prop_name, _) = entry
          let field_name = naming.to_snake_case(prop_name)
          field_name <> ": " <> field_name
        })

      // Add additional_properties to param names if present
      let param_names = case
        additional_properties,
        additional_properties_untyped
      {
        Some(_), _ ->
          list.append(param_names, [
            "additional_properties: additional_properties",
          ])
        None, True ->
          list.append(param_names, [
            "additional_properties: additional_properties",
          ])
        None, False -> param_names
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

      let _ = nullable
      sb
    }

    Inline(StringSchema(description:, enum_values:, ..)) if enum_values != [] -> {
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

      let sb =
        list.fold(enum_values, sb, fn(sb, value) {
          let variant = naming.schema_to_type_name(type_name <> "_" <> value)
          sb
          |> se.indent(
            2,
            "\"" <> value <> "\" -> decode.success(types." <> variant <> ")",
          )
        })

      // Unknown enum values → decode failure, not silent fallback
      let sb =
        sb
        |> se.indent(
          2,
          "_ -> decode.failure(types."
            <> naming.schema_to_type_name(
            type_name
            <> "_"
            <> {
              case enum_values {
                [first, ..] -> first
                [] -> "unknown"
              }
            },
          )
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

    Inline(AllOfSchema(description:, schemas:)) -> {
      let merged = type_gen.merge_allof_schemas(schemas, ctx)
      let merged_schema =
        Inline(ObjectSchema(
          description:,
          properties: merged.properties,
          required: merged.required,
          additional_properties: merged.additional_properties,
          additional_properties_untyped: merged.additional_properties_untyped,
          nullable: False,
        ))
      generate_decoder(sb, name, merged_schema, ctx)
    }

    Inline(OneOfSchema(description:, schemas:, discriminator:)) -> {
      generate_oneof_decoder(
        sb,
        name,
        type_name,
        fn_name,
        decoder_fn_name,
        description,
        schemas,
        discriminator,
        ctx,
      )
    }

    Inline(AnyOfSchema(description:, schemas:)) -> {
      // Treat anyOf the same as oneOf without discriminator
      generate_oneof_decoder(
        sb,
        name,
        type_name,
        fn_name,
        decoder_fn_name,
        description,
        schemas,
        None,
        ctx,
      )
    }

    // Primitive schemas: generate decoder/encoder wrappers
    Inline(StringSchema(enum_values: [], ..)) -> {
      let sb =
        sb
        |> se.line(
          "pub fn " <> decoder_fn_name <> "() -> decode.Decoder(String) {",
        )
        |> se.indent(1, "decode.string")
        |> se.line("}")
        |> se.blank_line()
        |> se.line(
          "pub fn "
          <> fn_name
          <> "(json_string: String) -> Result(String, json.DecodeError) {",
        )
        |> se.indent(1, "json.parse(json_string, decode.string)")
        |> se.line("}")
        |> se.blank_line()
      sb
    }

    Inline(IntegerSchema(..)) -> {
      let sb =
        sb
        |> se.line(
          "pub fn " <> decoder_fn_name <> "() -> decode.Decoder(Int) {",
        )
        |> se.indent(1, "decode.int")
        |> se.line("}")
        |> se.blank_line()
        |> se.line(
          "pub fn "
          <> fn_name
          <> "(json_string: String) -> Result(Int, json.DecodeError) {",
        )
        |> se.indent(1, "json.parse(json_string, decode.int)")
        |> se.line("}")
        |> se.blank_line()
      sb
    }

    Inline(NumberSchema(..)) -> {
      let sb =
        sb
        |> se.line(
          "pub fn " <> decoder_fn_name <> "() -> decode.Decoder(Float) {",
        )
        |> se.indent(1, "decode.float")
        |> se.line("}")
        |> se.blank_line()
        |> se.line(
          "pub fn "
          <> fn_name
          <> "(json_string: String) -> Result(Float, json.DecodeError) {",
        )
        |> se.indent(1, "json.parse(json_string, decode.float)")
        |> se.line("}")
        |> se.blank_line()
      sb
    }

    Inline(BooleanSchema(..)) -> {
      let sb =
        sb
        |> se.line(
          "pub fn " <> decoder_fn_name <> "() -> decode.Decoder(Bool) {",
        )
        |> se.indent(1, "decode.bool")
        |> se.line("}")
        |> se.blank_line()
        |> se.line(
          "pub fn "
          <> fn_name
          <> "(json_string: String) -> Result(Bool, json.DecodeError) {",
        )
        |> se.indent(1, "json.parse(json_string, decode.bool)")
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
        Reference(_) -> True
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
                Reference(ref:) -> {
                  let ref_name = resolver.ref_to_name(ref)
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
            [Reference(ref:), ..] -> {
              let ref_name = resolver.ref_to_name(ref)
              naming.to_snake_case(ref_name) <> "_decoder()"
            }
            _ -> "decode.string"
          }
          let first_variant_name = case schemas {
            [Reference(ref:), ..] -> {
              let ref_name = resolver.ref_to_name(ref)
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
          // No discriminator: try each variant decoder in order
          let sb =
            sb
            |> se.line(
              "pub fn "
              <> fn_name
              <> "(json_string: String) -> Result(types."
              <> type_name
              <> ", json.DecodeError) {",
            )

          let sb =
            list.fold(schemas, sb, fn(sb, s_ref) {
              case s_ref {
                Reference(ref:) -> {
                  let ref_name = resolver.ref_to_name(ref)
                  let variant_type = naming.schema_to_type_name(ref_name)
                  let variant_name = type_name <> variant_type
                  let decode_fn = "decode_" <> naming.to_snake_case(ref_name)
                  sb
                  |> se.indent(1, "case " <> decode_fn <> "(json_string) {")
                  |> se.indent(
                    2,
                    "Ok(v) -> Ok(types." <> variant_name <> "(v))",
                  )
                  |> se.indent(2, "Error(_) ->")
                }
                _ -> sb
              }
            })

          // Final error case
          let sb =
            sb
            |> se.indent(1, "Error(json.UnexpectedEndOfInput)")

          // Close all the nested case blocks
          let sb =
            list.fold(list.repeat(Nil, list.length(schemas)), sb, fn(sb, _) {
              sb |> se.indent(1, "}")
            })

          let sb =
            sb
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
    Inline(StringSchema(..)) -> "decode.string"
    Inline(IntegerSchema(..)) -> "decode.int"
    Inline(NumberSchema(..)) -> "decode.float"
    Inline(BooleanSchema(..)) -> "decode.bool"
    Inline(ArraySchema(items:, ..)) -> {
      let inner = schema_ref_to_decoder(items, parent_name, prop_name, ctx)
      "decode.list(" <> inner <> ")"
    }
    Reference(ref:) -> {
      let name = resolver.ref_to_name(ref)
      naming.to_snake_case(name) <> "_decoder()"
    }
    _ -> "decode.string"
  }
}

/// Check if a SchemaRef has nullable: true.
fn schema_ref_is_nullable(ref: SchemaRef, ctx: Context) -> Bool {
  case ref {
    Inline(schema) -> schema.is_nullable(schema)
    Reference(_) ->
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

  // Check if dict/list modules are needed (only for typed additionalProperties encoding)
  let needs_typed_dict =
    list.any(schemas, fn(entry) {
      let #(_, schema_ref) = entry
      case schema_ref {
        Inline(ObjectSchema(additional_properties: Some(_), ..)) -> True
        _ -> False
      }
    })

  let base_imports = case needs_typed_dict {
    True -> ["gleam/dict", "gleam/json", "gleam/list"]
    False -> ["gleam/json"]
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
            Reference(_) ->
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
  let operations = type_gen.collect_operations(ctx)
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
  operation: spec.Operation,
  ctx: Context,
) -> se.StringBuilder {
  case operation.request_body {
    Some(rb) -> {
      let content_entries = dict.to_list(rb.content)
      case content_entries {
        [#(_, media_type), ..] ->
          case media_type.schema {
            Some(Inline(schema_obj)) -> {
              let name = naming.to_snake_case(op_id) <> "_request_body"
              generate_encoder(sb, name, Inline(schema_obj), ctx)
            }
            _ -> sb
          }
        _ -> sb
      }
    }
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
    Inline(ObjectSchema(
      properties:,
      required:,
      additional_properties:,
      additional_properties_untyped:,
      ..,
    )) -> {
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
      let has_ap =
        option.is_some(additional_properties) || additional_properties_untyped
      let sb = case has_ap {
        True ->
          sb
          |> se.indent(1, "let base_props = [")
        False ->
          sb
          |> se.indent(1, "json.object([")
      }

      let props = dict.to_list(properties)
      let sb =
        list.index_fold(props, sb, fn(sb, entry, idx) {
          let #(prop_name, prop_ref) = entry
          let field_name = naming.to_snake_case(prop_name)
          let is_required = list.contains(required, prop_name)
          let trailing = case idx == list.length(props) - 1 {
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

      let sb = case additional_properties, additional_properties_untyped {
        Some(ap_ref), _ -> {
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
        None, True -> {
          // Untyped additional_properties (Dynamic) are decode-only;
          // skip them during encoding as they cannot be reliably re-encoded.
          sb
          |> se.indent(1, "]")
          |> se.indent(1, "json.object(base_props)")
        }
        None, False ->
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
        list.fold(enum_values, sb, fn(sb, value) {
          let variant = naming.schema_to_type_name(type_name <> "_" <> value)
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
        list.fold(enum_values, sb, fn(sb, value) {
          let variant = naming.schema_to_type_name(type_name <> "_" <> value)
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

    Inline(AllOfSchema(description:, schemas:)) -> {
      let merged = type_gen.merge_allof_schemas(schemas, ctx)
      let merged_schema =
        Inline(ObjectSchema(
          description:,
          properties: merged.properties,
          required: merged.required,
          additional_properties: merged.additional_properties,
          additional_properties_untyped: merged.additional_properties_untyped,
          nullable: False,
        ))
      generate_encoder(sb, name, merged_schema, ctx)
    }

    Inline(OneOfSchema(schemas:, ..)) | Inline(AnyOfSchema(schemas:, ..)) -> {
      // Generate encoder for oneOf/anyOf: pattern match on each variant
      let all_refs =
        list.all(schemas, fn(s) {
          case s {
            Reference(_) -> True
            _ -> False
          }
        })
      case all_refs {
        False -> sb
        True -> {
          // _json version
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
                Reference(ref:) -> {
                  let ref_name = resolver.ref_to_name(ref)
                  let variant_type = naming.schema_to_type_name(ref_name)
                  let variant_name = type_name <> variant_type
                  let inner_encoder =
                    "encode_" <> naming.to_snake_case(ref_name) <> "_json"
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
    Inline(StringSchema(enum_values: [], ..)) -> {
      sb
      |> se.line("pub fn " <> json_fn_name <> "(value: String) -> json.Json {")
      |> se.indent(1, "json.string(value)")
      |> se.line("}")
      |> se.blank_line()
      |> se.line("pub fn " <> fn_name <> "(value: String) -> String {")
      |> se.indent(1, json_fn_name <> "(value) |> json.to_string()")
      |> se.line("}")
      |> se.blank_line()
    }

    Inline(IntegerSchema(..)) -> {
      sb
      |> se.line("pub fn " <> json_fn_name <> "(value: Int) -> json.Json {")
      |> se.indent(1, "json.int(value)")
      |> se.line("}")
      |> se.blank_line()
      |> se.line("pub fn " <> fn_name <> "(value: Int) -> String {")
      |> se.indent(1, json_fn_name <> "(value) |> json.to_string()")
      |> se.line("}")
      |> se.blank_line()
    }

    Inline(NumberSchema(..)) -> {
      sb
      |> se.line("pub fn " <> json_fn_name <> "(value: Float) -> json.Json {")
      |> se.indent(1, "json.float(value)")
      |> se.line("}")
      |> se.blank_line()
      |> se.line("pub fn " <> fn_name <> "(value: Float) -> String {")
      |> se.indent(1, json_fn_name <> "(value) |> json.to_string()")
      |> se.line("}")
      |> se.blank_line()
    }

    Inline(BooleanSchema(..)) -> {
      sb
      |> se.line("pub fn " <> json_fn_name <> "(value: Bool) -> json.Json {")
      |> se.indent(1, "json.bool(value)")
      |> se.line("}")
      |> se.blank_line()
      |> se.line("pub fn " <> fn_name <> "(value: Bool) -> String {")
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
    Inline(StringSchema(..)) -> "json.string(" <> value_expr <> ")"
    Inline(IntegerSchema(..)) -> "json.int(" <> value_expr <> ")"
    Inline(NumberSchema(..)) -> "json.float(" <> value_expr <> ")"
    Inline(BooleanSchema(..)) -> "json.bool(" <> value_expr <> ")"
    Inline(ArraySchema(items:, ..)) -> {
      let inner_fn =
        schema_ref_to_json_encoder_fn(items, parent_name, prop_name, ctx)
      "json.array(" <> value_expr <> ", " <> inner_fn <> ")"
    }
    Reference(ref:) -> {
      let name = resolver.ref_to_name(ref)
      "encode_" <> naming.to_snake_case(name) <> "_json(" <> value_expr <> ")"
    }
    _ -> "json.string(" <> value_expr <> ")"
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
    Inline(StringSchema(..)) -> "json.string"
    Inline(IntegerSchema(..)) -> "json.int"
    Inline(NumberSchema(..)) -> "json.float"
    Inline(BooleanSchema(..)) -> "json.bool"
    Inline(ArraySchema(items:, ..)) -> {
      let inner =
        schema_ref_to_json_encoder_fn(items, parent_name, prop_name, ctx)
      "fn(items) { json.array(items, " <> inner <> ") }"
    }
    Reference(ref:) -> {
      let name = resolver.ref_to_name(ref)
      "encode_" <> naming.to_snake_case(name) <> "_json"
    }
    _ -> "json.string"
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
