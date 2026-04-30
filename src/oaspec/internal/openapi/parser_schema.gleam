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
import oaspec/internal/openapi/parser_error
import oaspec/internal/openapi/schema.{
  type Discriminator, type SchemaObject, type SchemaRef, AllOfSchema,
  AnyOfSchema, ArraySchema, BooleanSchema, Discriminator, Inline, IntegerSchema,
  NumberSchema, ObjectSchema, OneOfSchema, StringSchema,
}
import oaspec/internal/openapi/value
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
  let nullable =
    yay.extract_optional_bool(node, "nullable")
    |> result.unwrap(None)
    |> option.unwrap(False)

  let description =
    yay.extract_optional_string(node, "description")
    |> result.unwrap(None)

  let deprecated =
    yay.extract_optional_bool(node, "deprecated")
    |> result.unwrap(None)
    |> option.unwrap(False)

  let title =
    yay.extract_optional_string(node, "title")
    |> result.unwrap(None)

  let read_only =
    yay.extract_optional_bool(node, "readOnly")
    |> result.unwrap(None)
    |> option.unwrap(False)

  let write_only =
    yay.extract_optional_bool(node, "writeOnly")
    |> result.unwrap(None)
    |> option.unwrap(False)

  let default = value.extract_optional(node, "default")

  let example = value.extract_optional(node, "example")

  let const_value = value.extract_optional(node, "const")

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
        let type_name =
          yay.extract_optional_string(node, "type")
          |> result.unwrap(None)
          |> option.unwrap("object")
        Ok(#(type_name, metadata))
      }
    },
  )

  let format =
    yay.extract_optional_string(node, "format")
    |> result.unwrap(None)

  case type_str {
    "string" -> {
      let enum_values = case yay.extract_string_list(node, "enum") {
        Ok(values) -> values
        _ -> []
      }
      let min_length =
        yay.extract_optional_int(node, "minLength") |> result.unwrap(None)
      let max_length =
        yay.extract_optional_int(node, "maxLength") |> result.unwrap(None)
      let pattern =
        yay.extract_optional_string(node, "pattern") |> result.unwrap(None)
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
      let minimum =
        yay.extract_optional_int(node, "minimum") |> result.unwrap(None)
      let maximum =
        yay.extract_optional_int(node, "maximum") |> result.unwrap(None)
      let exclusive_minimum =
        yay.extract_optional_int(node, "exclusiveMinimum")
        |> result.unwrap(None)
      let exclusive_maximum =
        yay.extract_optional_int(node, "exclusiveMaximum")
        |> result.unwrap(None)
      let multiple_of =
        yay.extract_optional_int(node, "multipleOf") |> result.unwrap(None)
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
      let minimum =
        yay.extract_optional_float(node, "minimum") |> result.unwrap(None)
      let maximum =
        yay.extract_optional_float(node, "maximum") |> result.unwrap(None)
      let exclusive_minimum =
        yay.extract_optional_float(node, "exclusiveMinimum")
        |> result.unwrap(None)
      let exclusive_maximum =
        yay.extract_optional_float(node, "exclusiveMaximum")
        |> result.unwrap(None)
      let multiple_of =
        yay.extract_optional_float(node, "multipleOf")
        |> result.unwrap(None)
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
      let min_items =
        yay.extract_optional_int(node, "minItems") |> result.unwrap(None)
      let max_items =
        yay.extract_optional_int(node, "maxItems") |> result.unwrap(None)
      let unique_items =
        yay.extract_optional_bool(node, "uniqueItems")
        |> result.unwrap(None)
        |> option.unwrap(False)
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
      let min_properties =
        yay.extract_optional_int(node, "minProperties")
        |> result.unwrap(None)
      let max_properties =
        yay.extract_optional_int(node, "maxProperties")
        |> result.unwrap(None)
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
    |> result.map_error(parser_error.missing_field_from_selector(
      _,
      path: "schema",
      field: "discriminator",
      loc: location_index.lookup_field(index, "schema", "discriminator"),
    )),
  )

  use property_name <- result.try(
    yay.extract_string(disc_node, "propertyName")
    |> result.map_error(parser_error.missing_field_from_extraction(
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
