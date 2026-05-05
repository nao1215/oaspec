//// Schema-object parsing. Split out of `parser.gleam` so top-level spec
//// flow (paths / operations / components) and schema traversal can evolve
//// independently. The only public entry point is `parse_schema_ref`; the
//// rest (object/allOf/oneOf/anyOf/typed/properties/discriminator) is
//// recursive internal machinery.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import oaspec/internal/openapi/location_index.{type LocationIndex}
import oaspec/internal/openapi/parser_value
import oaspec/internal/openapi/parser_yay_error
import oaspec/internal/openapi/schema.{
  type Discriminator, type SchemaObject, type SchemaRef, AllOfSchema,
  AnyOfSchema, ArraySchema, BooleanSchema, Discriminator, Inline, IntegerSchema,
  NumberSchema, ObjectSchema, OneOfSchema, StringSchema,
}
import oaspec/openapi/diagnostic.{type Diagnostic}
import yay

/// Parse a schema ref (`$ref`) or an inline schema object.
pub fn parse_schema_ref(
  node: yay.Node,
  path: String,
  index: LocationIndex,
) -> Result(SchemaRef, Diagnostic) {
  case yay.extract_optional_string(node, "$ref") {
    Ok(Some(ref)) -> Ok(schema.make_reference(ref))
    _ -> {
      use schema_obj <- result.try(parse_schema_object(node, path, index))
      Ok(Inline(schema_obj))
    }
  }
}

/// Parse a schema object.
fn parse_schema_object(
  node: yay.Node,
  path: String,
  index: LocationIndex,
) -> Result(SchemaObject, Diagnostic) {
  let nullable = parser_value.bool_default(node, "nullable", False)
  let description = parser_value.optional_string(node, "description")
  let deprecated = parser_value.bool_default(node, "deprecated", False)
  let title = parser_value.optional_string(node, "title")
  let read_only = parser_value.bool_default(node, "readOnly", False)
  let write_only = parser_value.bool_default(node, "writeOnly", False)

  let default = parser_value.extract_optional(node, "default")

  let example = parser_value.extract_optional(node, "example")

  let const_value = parser_value.extract_optional(node, "const")

  let unsupported_keywords = detect_unsupported_keywords(node)

  let metadata =
    schema.SchemaMetadata(
      description:,
      nullable:,
      deprecated:,
      title:,
      read_only:,
      write_only:,
      default:,
      example:,
      const_value:,
      raw_type: None,
      unsupported_keywords:,
      internal: False,
      provenance: schema.UserAuthored,
    )

  // Check for composition keywords first
  case yay.select_sugar(from: node, selector: "allOf") {
    Ok(yay.NodeSeq(items)) -> {
      use schemas <- result.try(
        list.try_map(items, parse_schema_ref(_, path <> ".allOf", index)),
      )
      Ok(AllOfSchema(metadata:, schemas:))
    }
    _ ->
      case yay.select_sugar(from: node, selector: "oneOf") {
        Ok(yay.NodeSeq(items)) -> {
          let #(non_null_items, has_null) = partition_null_branches(items)
          let metadata = case has_null {
            True -> schema.SchemaMetadata(..metadata, nullable: True)
            False -> metadata
          }
          use schemas <- result.try(
            list.try_map(non_null_items, parse_schema_ref(
              _,
              path <> ".oneOf",
              index,
            )),
          )
          use discriminator <- result.try(
            case
              result.is_ok(yay.select_sugar(
                from: node,
                selector: "discriminator",
              ))
            {
              True -> {
                use d <- result.try(parse_discriminator(node, index))
                Ok(Some(d))
              }
              False -> Ok(None)
            },
          )
          Ok(OneOfSchema(metadata:, schemas:, discriminator:))
        }
        _ ->
          case yay.select_sugar(from: node, selector: "anyOf") {
            Ok(yay.NodeSeq(items)) -> {
              let #(non_null_items, has_null) = partition_null_branches(items)
              let metadata = case has_null {
                True -> schema.SchemaMetadata(..metadata, nullable: True)
                False -> metadata
              }
              use schemas <- result.try(
                list.try_map(non_null_items, parse_schema_ref(
                  _,
                  path <> ".anyOf",
                  index,
                )),
              )
              use discriminator <- result.try(
                case
                  result.is_ok(yay.select_sugar(
                    from: node,
                    selector: "discriminator",
                  ))
                {
                  True -> {
                    use d <- result.try(parse_discriminator(node, index))
                    Ok(Some(d))
                  }
                  False -> Ok(None)
                },
              )
              Ok(AnyOfSchema(metadata:, schemas:, discriminator:))
            }
            _ -> parse_typed_schema(node, metadata, path, index)
          }
      }
  }
}

/// Detect a schema branch that is a standalone `type: "null"` (the
/// OpenAPI 3.1 way to express nullability inside a oneOf/anyOf).
///
/// Returns `True` only if the node is an inline schema whose only
/// shape-bearing key is `type: "null"`. A `$ref` to a separately-
/// defined `type: "null"` schema is not detected here — those are
/// handled by the standalone `parse_typed_schema` "null" branch.
fn is_null_branch(node: yay.Node) -> Bool {
  // A `$ref` branch is never a null literal at this level.
  case yay.extract_optional_string(node, "$ref") {
    Ok(Some(_)) -> False
    _ ->
      case yay.select_sugar(from: node, selector: "type") {
        Ok(yay.NodeStr("null")) -> True
        _ -> False
      }
  }
}

/// Split oneOf/anyOf members into the non-null branches and a flag
/// indicating whether any branch was a `type: "null"` literal. Used
/// to translate OpenAPI 3.1 nullable-via-union into the existing
/// `nullable: True` metadata flag, mirroring how the array form of
/// `type` ([T, "null"]) is already handled in `parse_typed_schema`.
fn partition_null_branches(items: List(yay.Node)) -> #(List(yay.Node), Bool) {
  let #(non_null, has_null) =
    list.fold(items, #([], False), fn(acc, item) {
      let #(kept, seen) = acc
      case is_null_branch(item) {
        True -> #(kept, True)
        False -> #([item, ..kept], seen)
      }
    })
  #(list.reverse(non_null), has_null)
}

/// Detect unsupported JSON Schema 2020-12 keywords present in a schema node.
/// Returns a list of keyword names found (does NOT fail — stores them for later).
/// Note: `const` is NOT in this list because it is parsed into `const_value`.
fn detect_unsupported_keywords(node: yay.Node) -> List(String) {
  let keywords = [
    "$defs", "prefixItems", "if", "then", "else", "dependentSchemas",
    "unevaluatedProperties", "unevaluatedItems", "contentEncoding",
    "contentMediaType", "contentSchema", "not",
  ]
  list.filter(keywords, fn(keyword) {
    result.is_ok(yay.select_sugar(from: node, selector: keyword))
  })
}

/// Parse a typed schema (string, integer, number, boolean, array, object).
fn parse_typed_schema(
  node: yay.Node,
  metadata: schema.SchemaMetadata,
  path: String,
  index: LocationIndex,
) -> Result(SchemaObject, Diagnostic) {
  // OpenAPI 3.1 allows type to be an array, e.g. type: [string, 'null'].
  // Extract the primary type and detect nullable from the array form.
  // Multi-type unions (e.g. [string, integer]) are not supported.
  use #(type_str, metadata) <- result.try(
    case yay.select_sugar(from: node, selector: "type") {
      Ok(yay.NodeSeq(type_nodes)) -> {
        let type_strs =
          list.filter_map(type_nodes, fn(n) {
            case n {
              yay.NodeStr(s) -> Ok(s)
              _ -> Error(Nil)
            }
          })
        let has_null = list.contains(type_strs, "null")
        let non_null_types = list.filter(type_strs, fn(s) { s != "null" })
        case non_null_types {
          [single] ->
            Ok(#(
              single,
              schema.SchemaMetadata(
                ..metadata,
                nullable: metadata.nullable || has_null,
              ),
            ))
          [] ->
            Ok(#(
              "object",
              schema.SchemaMetadata(
                ..metadata,
                nullable: metadata.nullable || has_null,
              ),
            ))
          _ -> {
            // Store multi-type for normalize pass
            let updated_meta =
              schema.SchemaMetadata(
                ..metadata,
                raw_type: Some(non_null_types),
                nullable: metadata.nullable || has_null,
              )
            // Default to first type for now; normalize will convert to oneOf
            let primary = case non_null_types {
              [first, ..] -> first
              [] -> "object"
            }
            Ok(#(primary, updated_meta))
          }
        }
      }
      Ok(yay.NodeStr("null")) ->
        // OpenAPI 3.1 allows `type: "null"` to mean "the value is
        // JSON null". Mirror the existing array-form fallback for
        // `type: ["null"]` (no non-null types): treat as an
        // unrestricted nullable schema by lifting the null marker
        // to the metadata `nullable` flag and falling through to
        // the regular "object" branch for any sibling keywords.
        Ok(#("object", schema.SchemaMetadata(..metadata, nullable: True)))
      Ok(yay.NodeStr(type_name)) -> Ok(#(type_name, metadata))
      _ -> {
        // When type is absent, default to "object".
        // Unsupported keywords (const, if/then/else, etc.) are already caught
        // by check_unsupported_schema_keywords before reaching this point,
        // so this fallback is safe for legitimate type-less schemas.
        let type_name = parser_value.string_default(node, "type", "object")
        Ok(#(type_name, metadata))
      }
    },
  )

  let format = parser_value.optional_string(node, "format")

  case type_str {
    "string" -> {
      let enum_values = case yay.extract_string_list(node, "enum") {
        Ok(values) -> values
        _ -> []
      }
      let min_length = parser_value.optional_int(node, "minLength")
      let max_length = parser_value.optional_int(node, "maxLength")
      let pattern = parser_value.optional_string(node, "pattern")
      Ok(StringSchema(
        metadata:,
        format:,
        enum_values:,
        min_length:,
        max_length:,
        pattern:,
      ))
    }

    "integer" -> {
      let raw_minimum = parser_value.optional_int(node, "minimum")
      let raw_maximum = parser_value.optional_int(node, "maximum")
      let numeric_excl_min = parser_value.optional_int(node, "exclusiveMinimum")
      let numeric_excl_max = parser_value.optional_int(node, "exclusiveMaximum")
      // Issue #523: OAS 3.0 expresses exclusive bounds as a boolean
      // companion to `minimum` / `maximum` (`exclusiveMinimum: true`
      // → `minimum` becomes a strict lower bound). OAS 3.1 expresses
      // them as a numeric value with no separate `minimum`. Accept
      // both: if the numeric form is present, use it; otherwise look
      // for the boolean companion and promote `minimum` (or
      // `maximum`) accordingly.
      let bool_excl_min = parser_value.optional_bool(node, "exclusiveMinimum")
      let bool_excl_max = parser_value.optional_bool(node, "exclusiveMaximum")
      let #(minimum, exclusive_minimum) = case
        numeric_excl_min,
        bool_excl_min,
        raw_minimum
      {
        Some(_), _, _ -> #(raw_minimum, numeric_excl_min)
        None, Some(True), Some(_) -> #(None, raw_minimum)
        _, _, _ -> #(raw_minimum, None)
      }
      let #(maximum, exclusive_maximum) = case
        numeric_excl_max,
        bool_excl_max,
        raw_maximum
      {
        Some(_), _, _ -> #(raw_maximum, numeric_excl_max)
        None, Some(True), Some(_) -> #(None, raw_maximum)
        _, _, _ -> #(raw_maximum, None)
      }
      let multiple_of = parser_value.optional_int(node, "multipleOf")
      Ok(IntegerSchema(
        metadata:,
        format:,
        minimum:,
        maximum:,
        exclusive_minimum:,
        exclusive_maximum:,
        multiple_of:,
      ))
    }

    "number" -> {
      let raw_minimum = parser_value.optional_float(node, "minimum")
      let raw_maximum = parser_value.optional_float(node, "maximum")
      let numeric_excl_min =
        parser_value.optional_float(node, "exclusiveMinimum")
      let numeric_excl_max =
        parser_value.optional_float(node, "exclusiveMaximum")
      // Issue #523: OAS 3.0 boolean form for `exclusiveMinimum` /
      // `exclusiveMaximum`. See the integer branch above.
      let bool_excl_min = parser_value.optional_bool(node, "exclusiveMinimum")
      let bool_excl_max = parser_value.optional_bool(node, "exclusiveMaximum")
      let #(minimum, exclusive_minimum) = case
        numeric_excl_min,
        bool_excl_min,
        raw_minimum
      {
        Some(_), _, _ -> #(raw_minimum, numeric_excl_min)
        None, Some(True), Some(_) -> #(None, raw_minimum)
        _, _, _ -> #(raw_minimum, None)
      }
      let #(maximum, exclusive_maximum) = case
        numeric_excl_max,
        bool_excl_max,
        raw_maximum
      {
        Some(_), _, _ -> #(raw_maximum, numeric_excl_max)
        None, Some(True), Some(_) -> #(None, raw_maximum)
        _, _, _ -> #(raw_maximum, None)
      }
      let multiple_of = parser_value.optional_float(node, "multipleOf")
      Ok(NumberSchema(
        metadata:,
        format:,
        minimum:,
        maximum:,
        exclusive_minimum:,
        exclusive_maximum:,
        multiple_of:,
      ))
    }

    "boolean" -> Ok(BooleanSchema(metadata:))

    "array" -> {
      use items <- result.try(
        case yay.select_sugar(from: node, selector: "items") {
          Ok(items_node) ->
            parse_schema_ref(items_node, path <> ".items", index)
          _ ->
            Error(diagnostic.missing_field(
              path: path,
              field: "items",
              loc: location_index.lookup_field(index, path, "items"),
            ))
        },
      )
      let min_items = parser_value.optional_int(node, "minItems")
      let max_items = parser_value.optional_int(node, "maxItems")
      let unique_items = parser_value.bool_default(node, "uniqueItems", False)
      Ok(ArraySchema(metadata:, items:, min_items:, max_items:, unique_items:))
    }

    "object" -> {
      use properties <- result.try(parse_properties(node, path, index))
      let required = case yay.extract_string_list(node, "required") {
        Ok(r) -> r
        _ -> []
      }
      use additional_properties <- result.try(
        case yay.select_sugar(from: node, selector: "additionalProperties") {
          Ok(yay.NodeBool(True)) -> Ok(schema.Untyped)
          Ok(yay.NodeBool(False)) -> Ok(schema.Forbidden)
          Ok(ap_node) -> {
            use sr <- result.try(parse_schema_ref(
              ap_node,
              path <> ".additionalProperties",
              index,
            ))
            Ok(schema.Typed(sr))
          }
          // Per JSON Schema, absent additionalProperties still permits extra
          // keys at runtime, but we surface them in generated types only when
          // the spec asks for them (true / schema). See Issue #249.
          _ -> Ok(schema.Unspecified)
        },
      )
      let min_properties = parser_value.optional_int(node, "minProperties")
      let max_properties = parser_value.optional_int(node, "maxProperties")
      Ok(ObjectSchema(
        metadata:,
        properties:,
        required:,
        additional_properties:,
        min_properties:,
        max_properties:,
      ))
    }

    unrecognized ->
      Error(diagnostic.invalid_value(
        path: path <> ".type",
        detail: "Unrecognized schema type '"
          <> unrecognized
          <> "'. Supported types: string, integer, number, boolean, array, object.",
        loc: location_index.lookup(index, path <> ".type"),
      ))
  }
}

/// Parse properties map from an object schema.
fn parse_properties(
  node: yay.Node,
  path: String,
  index: LocationIndex,
) -> Result(Dict(String, SchemaRef), Diagnostic) {
  case yay.select_sugar(from: node, selector: "properties") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(prop_name) -> {
            use schema_ref <- result.try(parse_schema_ref(
              value_node,
              path <> "." <> prop_name,
              index,
            ))
            Ok(dict.insert(acc, prop_name, schema_ref))
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse discriminator from a node.
fn parse_discriminator(
  node: yay.Node,
  index: LocationIndex,
) -> Result(Discriminator, Diagnostic) {
  use disc_node <- result.try(
    yay.select_sugar(from: node, selector: "discriminator")
    |> result.map_error(parser_yay_error.missing_field_from_selector(
      _,
      path: "schema",
      field: "discriminator",
      loc: location_index.lookup_field(index, "schema", "discriminator"),
    )),
  )

  use property_name <- result.try(
    yay.extract_string(disc_node, "propertyName")
    |> result.map_error(parser_yay_error.missing_field_from_extraction(
      _,
      path: "discriminator",
      field: "propertyName",
      loc: location_index.lookup_field(index, "discriminator", "propertyName"),
    )),
  )

  let mapping = case yay.extract_string_map(disc_node, "mapping") {
    Ok(m) -> m
    _ -> dict.new()
  }

  Ok(Discriminator(property_name:, mapping:))
}
