//// yay → JsonValue bridge helpers used by the parsing layer.
////
//// Split out of `oaspec/internal/openapi/value` so the JsonValue type itself
//// stays target-neutral (pure Gleam, no yay/BEAM dependency) and only the
//// extraction helpers that touch yay nodes carry the BEAM-only coupling.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import oaspec/internal/openapi/value.{
  type JsonValue, JsonArray, JsonBool, JsonFloat, JsonInt, JsonNull, JsonObject,
  JsonString,
}
import yay

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
pub fn extract_optional(node: yay.Node, key: String) -> Option(JsonValue) {
  case yay.select_sugar(from: node, selector: key) {
    Ok(yay.NodeNil) -> option.None
    Ok(child) -> option.Some(from_node(child))
    // nolint: thrown_away_error -- yay.SelectorError here only signals absent/mismatched key; absence is represented as None
    Error(_) -> option.None
  }
}

/// Extract an optional bool, collapsing yay's
/// `Result(Option(Bool), _)` into a plain `Option(Bool)`.
pub fn optional_bool(node: yay.Node, key: String) -> Option(Bool) {
  case yay.extract_optional_bool(node, key) {
    Ok(value) -> value
    // nolint: thrown_away_error -- yay extractor errors collapse to "absent" for these helpers; the explicit Diagnostic surface is a separate concern handled elsewhere
    Error(_) -> None
  }
}

/// Extract an optional string, collapsing yay's nested result/option.
pub fn optional_string(node: yay.Node, key: String) -> Option(String) {
  case yay.extract_optional_string(node, key) {
    Ok(value) -> value
    // nolint: thrown_away_error -- absence is the only meaningful outcome here; see optional_bool
    Error(_) -> None
  }
}

/// Extract an optional int, collapsing yay's nested result/option.
pub fn optional_int(node: yay.Node, key: String) -> Option(Int) {
  case yay.extract_optional_int(node, key) {
    Ok(value) -> value
    // nolint: thrown_away_error -- absence is the only meaningful outcome here; see optional_bool
    Error(_) -> None
  }
}

/// Extract an optional float, collapsing yay's nested result/option.
pub fn optional_float(node: yay.Node, key: String) -> Option(Float) {
  case yay.extract_optional_float(node, key) {
    Ok(value) -> value
    // nolint: thrown_away_error -- absence is the only meaningful outcome here; see optional_bool
    Error(_) -> None
  }
}

/// Extract a bool with a default. Replaces the very common
/// `extract_optional_bool |> result.unwrap(None) |> option.unwrap(default)`
/// chain.
pub fn bool_default(node: yay.Node, key: String, default: Bool) -> Bool {
  case optional_bool(node, key) {
    Some(value) -> value
    None -> default
  }
}

/// Extract a string with a default.
pub fn string_default(node: yay.Node, key: String, default: String) -> String {
  case optional_string(node, key) {
    Some(value) -> value
    None -> default
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
