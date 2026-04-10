import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import oaspec/openapi/parse_error.{type ParseError, MissingField}
import oaspec/openapi/parse_schema
import oaspec/openapi/spec.{
  type Encoding, type Header, type Link, type MediaType, Encoding, Header, Link,
  MediaType,
}
import yay

/// Parse content map, requiring at least one entry for request bodies.
pub fn parse_required_content(
  node: yay.Node,
  context: String,
) -> Result(Dict(String, MediaType), ParseError) {
  case yay.select_sugar(from: node, selector: "content") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(media_type_name) -> {
            use mt_schema <- result.try(
              case yay.select_sugar(from: value_node, selector: "schema") {
                Ok(schema_node) -> {
                  use sr <- result.try(parse_schema.parse_schema_ref(
                    schema_node,
                    context <> ".schema",
                  ))
                  Ok(Some(sr))
                }
                _ -> Ok(None)
              },
            )
            let mt_example = case
              yay.select_sugar(from: value_node, selector: "example")
            {
              Ok(val_node) -> Some(parse_schema.parse_json_value(val_node))
              Error(_) -> None
            }
            let mt_examples =
              parse_schema.parse_json_value_map(value_node, "examples")
            let mt_encoding = parse_encoding_map(value_node)
            Ok(dict.insert(
              acc,
              media_type_name,
              MediaType(
                schema: mt_schema,
                example: mt_example,
                examples: mt_examples,
                encoding: mt_encoding,
              ),
            ))
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Error(MissingField(path: context <> ".requestBody", field: "content"))
  }
}

/// Parse content map (media type -> schema).
pub fn parse_content(
  node: yay.Node,
  context: String,
) -> Result(Dict(String, MediaType), ParseError) {
  case yay.select_sugar(from: node, selector: "content") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(media_type_name) -> {
            use mt_schema <- result.try(
              case yay.select_sugar(from: value_node, selector: "schema") {
                Ok(schema_node) -> {
                  use sr <- result.try(parse_schema.parse_schema_ref(
                    schema_node,
                    context <> ".schema",
                  ))
                  Ok(Some(sr))
                }
                _ -> Ok(None)
              },
            )
            let mt_example = case
              yay.select_sugar(from: value_node, selector: "example")
            {
              Ok(val_node) -> Some(parse_schema.parse_json_value(val_node))
              Error(_) -> None
            }
            let mt_examples =
              parse_schema.parse_json_value_map(value_node, "examples")
            let mt_encoding = parse_encoding_map(value_node)
            Ok(dict.insert(
              acc,
              media_type_name,
              MediaType(
                schema: mt_schema,
                example: mt_example,
                examples: mt_examples,
                encoding: mt_encoding,
              ),
            ))
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse encoding map from a media type node (without style parsing).
pub fn parse_encoding_map(node: yay.Node) -> Dict(String, Encoding) {
  case yay.select_sugar(from: node, selector: "encoding") {
    Ok(yay.NodeMap(entries)) ->
      list.fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(prop_name) -> {
            let content_type =
              yay.extract_optional_string(value_node, "contentType")
              |> result.unwrap(None)
            let explode =
              yay.extract_optional_bool(value_node, "explode")
              |> result.unwrap(None)
            dict.insert(
              acc,
              prop_name,
              Encoding(content_type:, style: None, explode:),
            )
          }
          _ -> acc
        }
      })
    _ -> dict.new()
  }
}

/// Parse headers map from a node.
pub fn parse_headers_map(node: yay.Node) -> Dict(String, Header) {
  case yay.select_sugar(from: node, selector: "headers") {
    Ok(yay.NodeMap(entries)) ->
      list.fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(header_name) -> {
            let description =
              yay.extract_optional_string(value_node, "description")
              |> result.unwrap(None)
            let required =
              yay.extract_optional_bool(value_node, "required")
              |> result.unwrap(None)
              |> option.unwrap(False)
            let hdr_schema = case
              yay.select_sugar(from: value_node, selector: "schema")
            {
              Ok(schema_node) ->
                case
                  parse_schema.parse_schema_ref(
                    schema_node,
                    "header." <> header_name <> ".schema",
                  )
                {
                  Ok(sr) -> Some(sr)
                  _ -> None
                }
              _ -> None
            }
            dict.insert(
              acc,
              header_name,
              Header(description:, required:, schema: hdr_schema),
            )
          }
          _ -> acc
        }
      })
    _ -> dict.new()
  }
}

/// Parse links map from a node.
pub fn parse_links_map(node: yay.Node) -> Dict(String, Link) {
  case yay.select_sugar(from: node, selector: "links") {
    Ok(yay.NodeMap(entries)) ->
      list.fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(link_name) -> {
            let operation_id =
              yay.extract_optional_string(value_node, "operationId")
              |> result.unwrap(None)
            let description =
              yay.extract_optional_string(value_node, "description")
              |> result.unwrap(None)
            dict.insert(acc, link_name, Link(operation_id:, description:))
          }
          _ -> acc
        }
      })
    _ -> dict.new()
  }
}
