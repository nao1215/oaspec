import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import oaspec/openapi/parse_error.{type ParseError, InvalidValue, MissingField}
import oaspec/openapi/schema.{
  type Discriminator, type SchemaObject, type SchemaRef,
  AdditionalPropertiesForbidden, AdditionalPropertiesTyped,
  AdditionalPropertiesUntyped, AllOfSchema, AnyOfSchema, ArraySchema,
  BooleanSchema, Discriminator, Inline, IntegerSchema, NumberSchema,
  ObjectSchema, OneOfSchema, StringSchema,
}
import oaspec/openapi/value
import yay

/// Parse a schema reference (either $ref or inline schema).
pub fn parse_schema_ref(
  node: yay.Node,
  path: String,
) -> Result(SchemaRef, ParseError) {
  case yay.extract_optional_string(node, "$ref") {
    Ok(Some(ref)) -> Ok(schema.make_reference(ref))
    _ -> {
      use schema_obj <- result.try(parse_schema_object(node, path))
      Ok(Inline(schema_obj))
    }
  }
}

/// Parse a schema object.
pub fn parse_schema_object(
  node: yay.Node,
  path: String,
) -> Result(SchemaObject, ParseError) {
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

  let default = case yay.select_sugar(from: node, selector: "default") {
    Ok(val_node) -> Some(parse_json_value(val_node))
    Error(_) -> None
  }

  let example = case yay.select_sugar(from: node, selector: "example") {
    Ok(val_node) -> Some(parse_json_value(val_node))
    Error(_) -> None
  }

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
    )

  use _ <- result.try(check_unsupported_schema_keywords(node, path))

  // Check for composition keywords first
  case yay.select_sugar(from: node, selector: "allOf") {
    Ok(yay.NodeSeq(items)) -> {
      use schemas <- result.try(
        list.try_map(items, parse_schema_ref(_, path <> ".allOf")),
      )
      Ok(AllOfSchema(metadata:, schemas:))
    }
    _ ->
      case yay.select_sugar(from: node, selector: "oneOf") {
        Ok(yay.NodeSeq(items)) -> {
          use schemas <- result.try(
            list.try_map(items, parse_schema_ref(_, path <> ".oneOf")),
          )
          use discriminator <- result.try(
            case yay.select_sugar(from: node, selector: "discriminator") {
              Ok(_) -> {
                use d <- result.try(parse_discriminator(node))
                Ok(Some(d))
              }
              Error(_) -> Ok(None)
            },
          )
          Ok(OneOfSchema(metadata:, schemas:, discriminator:))
        }
        _ ->
          case yay.select_sugar(from: node, selector: "anyOf") {
            Ok(yay.NodeSeq(items)) -> {
              use schemas <- result.try(
                list.try_map(items, parse_schema_ref(_, path <> ".anyOf")),
              )
              use discriminator <- result.try(
                case yay.select_sugar(from: node, selector: "discriminator") {
                  Ok(_) -> {
                    use d <- result.try(parse_discriminator(node))
                    Ok(Some(d))
                  }
                  Error(_) -> Ok(None)
                },
              )
              Ok(AnyOfSchema(metadata:, schemas:, discriminator:))
            }
            _ -> parse_typed_schema(node, metadata, path)
          }
      }
  }
}

/// Check for unsupported JSON Schema 2020-12 keywords and return an error
/// if any are found.
fn check_unsupported_schema_keywords(
  node: yay.Node,
  path: String,
) -> Result(Nil, ParseError) {
  let unsupported_keywords = [
    "const", "$defs", "prefixItems", "if", "then", "else", "dependentSchemas",
    "unevaluatedProperties", "unevaluatedItems", "contentEncoding",
    "contentMediaType", "contentSchema", "not",
  ]
  let found =
    list.filter(unsupported_keywords, fn(keyword) {
      case yay.select_sugar(from: node, selector: keyword) {
        Ok(_) -> True
        Error(_) -> False
      }
    })
  case found {
    [] -> Ok(Nil)
    keywords ->
      Error(InvalidValue(
        path: path,
        detail: "Unsupported JSON Schema keyword '"
          <> string.join(keywords, "', '")
          <> "' found. This keyword is not supported for code generation. Remove it or model the constraint differently.",
      ))
  }
}

/// Parse a typed schema (string, integer, number, boolean, array, object).
pub fn parse_typed_schema(
  node: yay.Node,
  metadata: schema.SchemaMetadata,
  path: String,
) -> Result(SchemaObject, ParseError) {
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
          _ ->
            Error(InvalidValue(
              path: path <> ".type",
              detail: "Multi-type unions (type: ["
                <> string.join(non_null_types, ", ")
                <> "]) are not supported; use oneOf instead",
            ))
        }
      }
      Ok(yay.NodeStr(s)) -> Ok(#(s, metadata))
      _ -> {
        // When type is absent, default to "object".
        let s =
          yay.extract_optional_string(node, "type")
          |> result.unwrap(None)
          |> option.unwrap("object")
        Ok(#(s, metadata))
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
          Ok(items_node) -> parse_schema_ref(items_node, path <> ".items")
          _ -> Error(MissingField(path: path, field: "items"))
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
      use properties <- result.try(parse_properties(node, path))
      let required = case yay.extract_string_list(node, "required") {
        Ok(r) -> r
        _ -> []
      }
      use additional_properties <- result.try(
        case yay.select_sugar(from: node, selector: "additionalProperties") {
          Ok(yay.NodeBool(True)) -> Ok(AdditionalPropertiesUntyped)
          Ok(yay.NodeBool(False)) -> Ok(AdditionalPropertiesForbidden)
          Ok(ap_node) -> {
            use sr <- result.try(parse_schema_ref(
              ap_node,
              path <> ".additionalProperties",
            ))
            Ok(AdditionalPropertiesTyped(sr))
          }
          _ -> Ok(AdditionalPropertiesForbidden)
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
      Error(InvalidValue(
        path: path <> ".type",
        detail: "Unrecognized schema type '"
          <> unrecognized
          <> "'. Supported types: string, integer, number, boolean, array, object.",
      ))
  }
}

/// Parse properties map from an object schema.
fn parse_properties(
  node: yay.Node,
  path: String,
) -> Result(Dict(String, SchemaRef), ParseError) {
  case yay.select_sugar(from: node, selector: "properties") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(prop_name) -> {
            use schema_ref <- result.try(parse_schema_ref(
              value_node,
              path <> "." <> prop_name,
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
fn parse_discriminator(node: yay.Node) -> Result(Discriminator, ParseError) {
  use disc_node <- result.try(
    yay.select_sugar(from: node, selector: "discriminator")
    |> result.map_error(fn(_) {
      MissingField(path: "schema", field: "discriminator")
    }),
  )

  use property_name <- result.try(
    yay.extract_string(disc_node, "propertyName")
    |> result.map_error(fn(_) {
      MissingField(path: "discriminator", field: "propertyName")
    }),
  )

  let mapping = case yay.extract_string_map(disc_node, "mapping") {
    Ok(m) -> m
    _ -> dict.new()
  }

  Ok(Discriminator(property_name:, mapping:))
}

/// Convert a yay.Node to a JsonValue.
pub fn parse_json_value(node: yay.Node) -> value.JsonValue {
  case node {
    yay.NodeStr(s) -> value.JsonString(s)
    yay.NodeInt(n) -> value.JsonInt(n)
    yay.NodeFloat(f) -> value.JsonFloat(f)
    yay.NodeBool(b) -> value.JsonBool(b)
    yay.NodeNil -> value.JsonNull
    yay.NodeSeq(items) -> value.JsonArray(list.map(items, parse_json_value))
    yay.NodeMap(entries) -> {
      let pairs =
        list.filter_map(entries, fn(entry) {
          let #(key_node, val_node) = entry
          case key_node {
            yay.NodeStr(key) -> Ok(#(key, parse_json_value(val_node)))
            _ -> Error(Nil)
          }
        })
      value.JsonObject(dict.from_list(pairs))
    }
  }
}

/// Parse a string->JsonValue map from a node at a given key.
pub fn parse_json_value_map(
  node: yay.Node,
  key: String,
) -> Dict(String, value.JsonValue) {
  case yay.select_sugar(from: node, selector: key) {
    Ok(yay.NodeMap(entries)) ->
      list.fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, val_node) = entry
        case key_node {
          yay.NodeStr(k) -> dict.insert(acc, k, parse_json_value(val_node))
          _ -> acc
        }
      })
    _ -> dict.new()
  }
}
