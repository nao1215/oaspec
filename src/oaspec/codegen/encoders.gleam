//// JSON encoder generation.
////
//// Split out of `decoders.gleam` so each module owns one direction of
//// the codec pipeline — decoders produces `decode.gleam`, encoders
//// produces `encode.gleam`. Shared traversal helpers (`list_at_or`,
//// `qualified_schema_ref_type`) are intentionally duplicated rather
//// than lifted into a third module; the helpers are small, the
//// duplication is stable, and extracting a shared dispatch module is
//// tracked as follow-up to #212.

import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oaspec/codegen/allof_merge
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/ir_build
import oaspec/codegen/schema_dispatch
import oaspec/codegen/types as type_gen
import oaspec/config
import oaspec/openapi/dedup
import oaspec/openapi/operations
import oaspec/openapi/schema.{
  type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema, BooleanSchema,
  Forbidden, Inline, IntegerSchema, NumberSchema, ObjectSchema, OneOfSchema,
  Reference, StringSchema, Typed, Unspecified, Untyped,
}
import oaspec/openapi/spec.{type Resolved, Value}
import oaspec/util/naming
import oaspec/util/string_extra as se

/// Generate the `encode.gleam` module for the resolved spec.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let operations = operations.collect_operations(ctx)
  let content = generate_encoders(ctx, operations)
  [
    GeneratedFile(
      path: "encode.gleam",
      content: content,
      target: context.SharedTarget,
      write_mode: context.Overwrite,
    ),
  ]
}

/// Generate JSON encoders for all component schemas and anonymous types.
fn generate_encoders(
  ctx: Context,
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> String {
  let schemas = case context.spec(ctx).components {
    Some(components) ->
      list.sort(dict.to_list(components.schemas), fn(a, b) {
        string.compare(a.0, b.0)
      })
      |> list.filter(fn(entry) { !ir_build.is_internal_schema(entry.1) })
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

  // Issue #303: object schemas with at least one optional non-nullable
  // property emit `case value.<f> { option.None -> [] option.Some(x) -> ... }`
  // wrapped in `list.flatten([...])`. Both the option module and the list
  // module need to be imported for those modules to resolve.
  let needs_option_and_list =
    list.any(schemas, fn(entry) {
      let #(_, schema_ref) = entry
      case schema_ref {
        Inline(ObjectSchema(properties:, required:, ..)) ->
          properties
          |> ir_build.sorted_entries
          |> list.any(fn(p) {
            let #(prop_name, prop_ref) = p
            !list.contains(required, prop_name)
            && !schema_ref_is_nullable(prop_ref)
          })
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
  let base_imports = case needs_option_and_list {
    True ->
      base_imports
      |> ensure_import("gleam/list")
      |> ensure_import("gleam/option")
    False -> base_imports
  }
  let imports = case needs_types {
    True ->
      list.append(base_imports, [
        config.package(context.config(ctx)) <> "/types",
      ])
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
  let sb = generate_anonymous_encoders(sb, ctx, operations)

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
      // Fallback: unsupported dynamic classifications (List, Dict, Tuple,
      // etc.) emit `json.null()` rather than the type name as a string.
      // Emitting the type name silently corrupts payloads; null at least
      // fails loud when the receiving end doesn't tolerate it.
      |> se.indent(2, "_ -> json.null()")
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
    Inline(ObjectSchema(properties:, ..)) -> ir_build.sorted_entries(properties)
    Inline(AllOfSchema(schemas:, ..)) ->
      ir_build.sorted_entries(
        allof_merge.merge_allof_schemas(schemas, ctx).properties,
      )
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
  operations: List(#(String, spec.Operation(Resolved), String, spec.HttpMethod)),
) -> se.StringBuilder {
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
      let content_entries = ir_build.sorted_entries(rb.content)
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

      // When additional_properties is Typed or Untyped we emit a `base_props`
      // list and merge in dict entries; Forbidden and Unspecified (Issue #249)
      // both go through `json.object([...])` directly with no AP merge.
      let has_ap = case additional_properties {
        Typed(_) | Untyped -> True
        Forbidden | Unspecified -> False
      }

      // Filter out readOnly properties -- they should not be sent to the server
      let all_props = ir_build.sorted_entries(properties)
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

      // Issue #303: a property that is in `properties` but not in `required`
      // and is not `nullable: true` MUST be omitted entirely from the JSON
      // object when its `Option` field is `None` — emitting `"<key>": null`
      // is schema-invalid (only `nullable: true` allows null on the wire).
      // When any property falls into that bucket we switch the encoder
      // shape from a static `[<pairs>]` literal to `list.flatten([<lists>])`
      // so each optional-non-nullable property can contribute either an
      // empty list (None) or a singleton pair list (Some).
      let has_omittable =
        list.any(props_with_names, fn(entry) {
          let #(prop_name, prop_ref, _) = entry
          !list.contains(required, prop_name)
          && !schema_ref_is_nullable(prop_ref)
        })

      let sb = case has_ap, has_omittable {
        True, False ->
          sb
          |> se.indent(1, "let base_props = [")
        True, True ->
          sb
          |> se.indent(1, "let base_props = list.flatten([")
        False, False ->
          sb
          |> se.indent(1, "json.object([")
        False, True ->
          sb
          |> se.indent(1, "json.object(list.flatten([")
      }
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
            )

          // Issue #296: required+nullable properties have Gleam type
          // Option(T) and must use json.nullable, not the bare encoder.
          let is_nullable = schema_ref_is_nullable(prop_ref)
          let is_omittable = !is_required && !is_nullable
          case has_omittable, is_required, is_nullable, is_omittable {
            // No optional-non-nullable in the schema → static list, current shape.
            False, True, False, _ ->
              sb
              |> se.indent(
                2,
                "#(\"" <> prop_name <> "\", " <> encoder_expr <> ")" <> trailing,
              )
            False, _, _, _ ->
              sb
              |> se.indent(
                2,
                "#(\""
                  <> prop_name
                  <> "\", json.nullable(value."
                  <> field_name
                  <> ", "
                  <> schema_ref_to_json_encoder_fn(prop_ref, name, prop_name)
                  <> "))"
                  <> trailing,
              )
            // Schema has at least one optional-non-nullable → list-of-lists.
            True, _, _, True -> {
              // Issue #303: omit the key when the value is None.
              // Re-derive the encoder expression with `x` substituted for
              // `value.<field>` so we encode the unwrapped Some value.
              let some_encoder_expr =
                schema_ref_to_json_encoder("x", prop_ref, name, prop_name)
              sb
              |> se.indent(2, "case value." <> field_name <> " {")
              |> se.indent(3, "option.None -> []")
              |> se.indent(
                3,
                "option.Some(x) -> [#(\""
                  <> prop_name
                  <> "\", "
                  <> some_encoder_expr
                  <> ")]",
              )
              |> se.indent(2, "}" <> trailing)
            }
            True, True, False, _ ->
              sb
              |> se.indent(
                2,
                "[#(\""
                  <> prop_name
                  <> "\", "
                  <> encoder_expr
                  <> ")]"
                  <> trailing,
              )
            True, _, _, _ ->
              // Required+nullable or optional+nullable: keep `json.nullable`
              // (None → wire-format null is permitted because nullable: true).
              sb
              |> se.indent(
                2,
                "[#(\""
                  <> prop_name
                  <> "\", json.nullable(value."
                  <> field_name
                  <> ", "
                  <> schema_ref_to_json_encoder_fn(prop_ref, name, prop_name)
                  <> "))]"
                  <> trailing,
              )
          }
        })

      let close_props_list = case has_omittable {
        True -> "])"
        False -> "]"
      }
      let sb = case additional_properties {
        Typed(ap_ref) -> {
          let inner_encoder_fn =
            schema_ref_to_json_encoder_fn(ap_ref, name, "additional_properties")
          sb
          |> se.indent(1, close_props_list)
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
          |> se.indent(1, close_props_list)
          |> se.indent(
            1,
            "let extra_props = dict.to_list(value.additional_properties) |> list.map(fn(entry) { let #(k, v) = entry\n  #(k, encode_dynamic(v)) })",
          )
          |> se.indent(1, "json.object(list.append(base_props, extra_props))")
        }
        Forbidden | Unspecified ->
          sb
          |> se.indent(1, case has_omittable {
            True -> "]))"
            False -> "])"
          })
      }

      let sb =
        sb
        |> se.line("}")
        |> se.blank_line()

      // String version: wraps _json
      sb
      |> se.line(
        "pub fn " <> fn_name <> "(value: types." <> type_name <> ") -> String {",
      )
      |> se.indent(1, json_fn_name <> "(value) |> json.to_string()")
      |> se.line("}")
      |> se.blank_line()
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

      sb
      |> se.indent(1, "}")
      |> se.line("}")
      |> se.blank_line()
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
        False ->
          panic as {
            "oaspec: oneOf schema '"
            <> name
            <> "' contains inline variant(s) which are not supported for encoder generation. "
            <> "Move all oneOf variants to components/schemas and use $ref instead."
          }
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
        False ->
          panic as {
            "oaspec: anyOf schema '"
            <> name
            <> "' contains inline variant(s) which are not supported for encoder generation. "
            <> "Move all anyOf variants to components/schemas and use $ref instead."
          }
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
        }
      }
    }

    Inline(StringSchema(metadata:, enum_values: [], ..)) -> {
      let #(gleam_type, json_expr) = case metadata.nullable {
        True -> #("Option(String)", "json.nullable(value, json.string)")
        False -> #("String", "json.string(value)")
      }
      generate_primitive_encoder(
        sb,
        fn_name,
        json_fn_name,
        gleam_type,
        json_expr,
      )
    }

    Inline(IntegerSchema(metadata:, ..)) -> {
      let #(gleam_type, json_expr) = case metadata.nullable {
        True -> #("Option(Int)", "json.nullable(value, json.int)")
        False -> #("Int", "json.int(value)")
      }
      generate_primitive_encoder(
        sb,
        fn_name,
        json_fn_name,
        gleam_type,
        json_expr,
      )
    }

    Inline(NumberSchema(metadata:, ..)) -> {
      let #(gleam_type, json_expr) = case metadata.nullable {
        True -> #("Option(Float)", "json.nullable(value, json.float)")
        False -> #("Float", "json.float(value)")
      }
      generate_primitive_encoder(
        sb,
        fn_name,
        json_fn_name,
        gleam_type,
        json_expr,
      )
    }

    Inline(BooleanSchema(metadata:)) -> {
      let #(gleam_type, json_expr) = case metadata.nullable {
        True -> #("Option(Bool)", "json.nullable(value, json.bool)")
        False -> #("Bool", "json.bool(value)")
      }
      generate_primitive_encoder(
        sb,
        fn_name,
        json_fn_name,
        gleam_type,
        json_expr,
      )
    }

    Inline(ArraySchema(items:, ..)) -> {
      let inner_type = qualified_schema_ref_type(items, ctx)
      let gleam_type = "List(" <> inner_type <> ")"
      let inner_encoder = schema_ref_to_json_encoder_fn(items, name, "")
      generate_primitive_encoder(
        sb,
        fn_name,
        json_fn_name,
        gleam_type,
        "json.array(value, " <> inner_encoder <> ")",
      )
    }

    _ -> sb
  }
}

/// Generate encoder for a primitive type (String, Int, Float, Bool) or Array.
fn generate_primitive_encoder(
  sb: se.StringBuilder,
  fn_name: String,
  json_fn_name: String,
  gleam_type: String,
  json_expr: String,
) -> se.StringBuilder {
  sb
  |> se.line(
    "pub fn " <> json_fn_name <> "(value: " <> gleam_type <> ") -> json.Json {",
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

/// Convert a SchemaRef to a json.Json encoder expression.
/// Returns an expression that produces json.Json (not String).
fn schema_ref_to_json_encoder(
  value_expr: String,
  ref: SchemaRef,
  parent_name: String,
  prop_name: String,
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
        schema_ref_to_json_encoder_fn(items, parent_name, prop_name)
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
) -> String {
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
      let inner = schema_ref_to_json_encoder_fn(items, parent_name, prop_name)
      "fn(items) { json.array(items, " <> inner <> ") }"
    }
    _ -> schema_dispatch.json_encoder_fn(ref)
  }
}

/// Check if a SchemaRef is nullable (inline schemas only — references are
/// assumed non-nullable here since the ref target's nullability is baked
/// into the generated type elsewhere).
fn schema_ref_is_nullable(ref: SchemaRef) -> Bool {
  case ref {
    Inline(inline_schema) -> schema.is_nullable(inline_schema)
    Reference(..) -> False
  }
}

/// Append `name` to `imports` if it isn't already there. Used by the
/// import builder to keep the list deterministic when more than one
/// codepath wants the same module (issue #303 wires `gleam/option` and
/// `gleam/list` for optional-non-nullable encoding even when those
/// modules were already pulled in by additionalProperties handling).
fn ensure_import(imports: List(String), name: String) -> List(String) {
  use <- bool.guard(list.contains(imports, name), imports)
  list.append(imports, [name])
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
