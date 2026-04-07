import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_oas/codegen/context.{
  type Context, type GeneratedFile, GeneratedFile,
}
import gleam_oas/openapi/resolver
import gleam_oas/openapi/schema.{
  type SchemaRef, ArraySchema, BooleanSchema, Inline, IntegerSchema,
  NumberSchema, ObjectSchema, Reference, StringSchema,
}
import gleam_oas/util/naming
import gleam_oas/util/string_extra as se

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

    _ -> sb
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
