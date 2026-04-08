import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/openapi/resolver
import oaspec/openapi/schema.{
  type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema, BooleanSchema, Inline,
  IntegerSchema, NumberSchema, ObjectSchema, OneOfSchema, Reference,
  StringSchema,
}
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

/// Generate JSON decoders for all component schemas.
fn generate_decoders(ctx: Context) -> String {
  let sb =
    se.file_header(context.version)
    |> se.imports([
      "gleam/dynamic/decode",
      "gleam/json",
      "gleam/option",
      ctx.config.package <> "/types",
    ])

  let schemas = case ctx.spec.components {
    Some(components) -> dict.to_list(components.schemas)
    None -> []
  }

  let sb =
    list.fold(schemas, sb, fn(sb, entry) {
      let #(name, schema_ref) = entry
      generate_decoder(sb, name, schema_ref, ctx)
    })

  se.to_string(sb)
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
    Inline(ObjectSchema(description:, properties:, required:, nullable:, ..)) -> {
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
          let field_decoder = schema_ref_to_decoder(prop_ref, ctx)
          let is_nullable_schema = schema_ref_is_nullable(prop_ref)

          // Avoid Option(Option(T)): if schema is already nullable,
          // don't wrap again for optional fields.
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
                  <> field_decoder
                  <> ")",
              )
            False ->
              case is_nullable_schema {
                True ->
                  // Schema is nullable → type is already Option(T),
                  // use optional_field with None default
                  sb
                  |> se.indent(
                    1,
                    "use "
                      <> field_name
                      <> " <- decode.optional_field(\""
                      <> prop_name
                      <> "\", option.None, "
                      <> field_decoder
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

      let param_names =
        list.map(props, fn(entry) {
          let #(prop_name, _) = entry
          let field_name = naming.to_snake_case(prop_name)
          field_name <> ": " <> field_name
        })

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
      // Merge properties from all sub-schemas (same as type generator)
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
        Inline(ObjectSchema(
          description:,
          properties: merged_props,
          required: merged_required,
          additional_properties: None,
          additional_properties_untyped: False,
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

          let first_variant = case schemas {
            [Reference(ref:), ..] -> {
              let ref_name = resolver.ref_to_name(ref)
              let variant_type = naming.schema_to_type_name(ref_name)
              type_name <> variant_type
            }
            _ -> type_name
          }

          let sb =
            sb
            |> se.indent(
              2,
              "_ -> decode.failure(types."
                <> first_variant
                <> "(todo), \""
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

/// Get the discriminator value for a $ref. Checks mapping first, falls back to ref name.
fn get_discriminator_value(
  disc: schema.Discriminator,
  _ref: String,
  ref_name: String,
) -> String {
  case dict.get(disc.mapping, ref_name) {
    Ok(mapped) -> mapped
    Error(_) -> ref_name
  }
}

/// Convert a SchemaRef to a decoder expression string.
fn schema_ref_to_decoder(ref: SchemaRef, ctx: Context) -> String {
  let _ = ctx
  case ref {
    Inline(StringSchema(..)) -> "decode.string"
    Inline(IntegerSchema(..)) -> "decode.int"
    Inline(NumberSchema(..)) -> "decode.float"
    Inline(BooleanSchema(..)) -> "decode.bool"
    Inline(ArraySchema(items:, ..)) -> {
      let inner = schema_ref_to_decoder(items, ctx)
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
fn schema_ref_is_nullable(ref: SchemaRef) -> Bool {
  case ref {
    Inline(schema) -> schema.is_nullable(schema)
    Reference(_) -> False
  }
}

// ===================================================================
// Encoders
// ===================================================================

/// Generate JSON encoders for all component schemas.
fn generate_encoders(ctx: Context) -> String {
  let sb =
    se.file_header(context.version)
    |> se.imports([
      "gleam/json",
      ctx.config.package <> "/types",
    ])

  let schemas = case ctx.spec.components {
    Some(components) -> dict.to_list(components.schemas)
    None -> []
  }

  let sb =
    list.fold(schemas, sb, fn(sb, entry) {
      let #(name, schema_ref) = entry
      generate_encoder(sb, name, schema_ref, ctx)
    })

  se.to_string(sb)
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
    Inline(ObjectSchema(properties:, required:, ..)) -> {
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
        |> se.indent(1, "json.object([")

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
            schema_ref_to_json_encoder("value." <> field_name, prop_ref, ctx)

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
                  <> schema_ref_to_json_encoder_fn(prop_ref, ctx)
                  <> "))"
                  <> trailing,
              )
          }
        })

      let sb =
        sb
        |> se.indent(1, "])")
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
      // Merge properties from all sub-schemas (same as type generator)
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
        Inline(ObjectSchema(
          description:,
          properties: merged_props,
          required: merged_required,
          additional_properties: None,
          additional_properties_untyped: False,
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

    _ -> sb
  }
}

/// Convert a SchemaRef to a json.Json encoder expression.
/// Returns an expression that produces json.Json (not String).
fn schema_ref_to_json_encoder(
  value_expr: String,
  ref: SchemaRef,
  ctx: Context,
) -> String {
  case ref {
    Inline(StringSchema(..)) -> "json.string(" <> value_expr <> ")"
    Inline(IntegerSchema(..)) -> "json.int(" <> value_expr <> ")"
    Inline(NumberSchema(..)) -> "json.float(" <> value_expr <> ")"
    Inline(BooleanSchema(..)) -> "json.bool(" <> value_expr <> ")"
    Inline(ArraySchema(items:, ..)) -> {
      let inner_fn = schema_ref_to_json_encoder_fn(items, ctx)
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
fn schema_ref_to_json_encoder_fn(ref: SchemaRef, ctx: Context) -> String {
  let _ = ctx
  case ref {
    Inline(StringSchema(..)) -> "json.string"
    Inline(IntegerSchema(..)) -> "json.int"
    Inline(NumberSchema(..)) -> "json.float"
    Inline(BooleanSchema(..)) -> "json.bool"
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
