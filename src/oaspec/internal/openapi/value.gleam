import gleam/dict.{type Dict}
import gleam/list
import gleam/option
import yay

/// A JSON-compatible value type for preserving arbitrary data from OpenAPI specs.
/// Used for example, default, const, and other values that aren't necessarily strings.
pub type JsonValue {
  JsonNull
  JsonBool(Bool)
  JsonInt(Int)
  JsonFloat(Float)
  JsonString(String)
  JsonArray(List(JsonValue))
  JsonObject(Dict(String, JsonValue))
}

/// Convert a yay.Node to a JsonValue.
fn from_node(node: yay.Node) -> JsonValue {
  case node {
    yay.NodeNil -> JsonNull
    yay.NodeStr(s) -> JsonString(s)
    yay.NodeBool(b) -> JsonBool(b)
    yay.NodeInt(i) -> JsonInt(i)
    yay.NodeFloat(f) -> JsonFloat(f)
    yay.NodeSeq(items) -> JsonArray(list.map(items, from_node))
    yay.NodeMap(entries) ->
      JsonObject(
        list.filter_map(entries, fn(entry) {
          let #(k, v) = entry
          case k {
            yay.NodeStr(key) -> Ok(#(key, from_node(v)))
            _ -> Error(Nil)
          }
        })
        |> dict.from_list,
      )
  }
}

/// Try to extract a JsonValue from a node at a given key.
/// Returns None if the key is absent or nil.
pub fn extract_optional(node: yay.Node, key: String) -> option.Option(JsonValue) {
  case yay.select_sugar(from: node, selector: key) {
    Ok(yay.NodeNil) -> option.None
    Ok(child) -> option.Some(from_node(child))
    // nolint: thrown_away_error -- yay.SelectorError here only signals absent/mismatched key; absence is represented as None
    Error(_) -> option.None
  }
}

/// Extract a dict of JsonValues from a node at a given key.
/// Returns empty dict if key is absent.
pub fn extract_map(node: yay.Node, key: String) -> Dict(String, JsonValue) {
  case yay.select_sugar(from: node, selector: key) {
    Ok(yay.NodeMap(entries)) ->
      list.filter_map(entries, fn(entry) {
        let #(k, v) = entry
        case k {
          yay.NodeStr(name) -> Ok(#(name, from_node(v)))
          _ -> Error(Nil)
        }
      })
      |> dict.from_list
    _ -> dict.new()
  }
}
