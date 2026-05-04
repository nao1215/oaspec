import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import oaspec/openapi/diagnostic.{type SourceLoc, NoSourceLoc, SourceLoc}

/// An index mapping dotted JSON-pointer paths to source locations.
/// Built by parsing YAML with yamerl (which preserves line/column),
/// then looked up when emitting diagnostics.
pub opaque type LocationIndex {
  LocationIndex(entries: Dict(String, SourceLoc))
}

/// Build a location index from raw YAML/JSON content.
/// On failure (e.g. invalid YAML), returns an empty index.
pub fn build(content: String) -> LocationIndex {
  do_build(content)
  |> result.map(fn(pairs) {
    let entries =
      list.fold(pairs, dict.new(), fn(acc, pair) {
        let #(path, #(line, col)) = pair
        dict.insert(acc, path, SourceLoc(line:, column: col))
      })
    LocationIndex(entries:)
  })
  |> result.unwrap(empty())
}

/// An empty index (no location information available).
pub fn empty() -> LocationIndex {
  LocationIndex(entries: dict.new())
}

/// Look up the source location for a given path.
/// Returns `NoSourceLoc` if the path is not in the index.
pub fn lookup(index: LocationIndex, path: String) -> SourceLoc {
  dict.get(index.entries, path)
  |> result.unwrap(NoSourceLoc)
}

/// Look up the source location for a field within a parent path.
/// Tries `parent.field` first, then falls back to `parent`, then `NoSourceLoc`.
pub fn lookup_field(
  index: LocationIndex,
  parent: String,
  field: String,
) -> SourceLoc {
  let field_path = case parent {
    "" -> field
    _ -> parent <> "." <> field
  }
  dict.get(index.entries, field_path)
  |> result.lazy_or(fn() { dict.get(index.entries, parent) })
  |> result.unwrap(NoSourceLoc)
}

/// Look up `path` exactly; on miss, drop the trailing dotted segment and
/// retry, walking up to the closest known ancestor. Returns `NoSourceLoc`
/// only when the path is empty / no ancestor is in the index.
///
/// Used by capability_check to surface the closest available line/column
/// when the diagnostic path does not exactly match a YAML node (e.g. a
/// schema property whose YAML location is one segment deeper than the
/// human-friendly path the diagnostic carries).
pub fn lookup_with_ancestor(index: LocationIndex, path: String) -> SourceLoc {
  case dict.get(index.entries, path) {
    Ok(loc) -> loc
    // nolint: thrown_away_error -- a dict miss here just signals "try the parent"; the recursion produces the actual NoSourceLoc when no ancestor exists either.
    Error(_) ->
      case string.split(path, ".") {
        [] | [_] -> NoSourceLoc
        segments -> {
          let parent_segments = case list.reverse(segments) {
            [_, ..rest_rev] -> list.reverse(rest_rev)
            [] -> []
          }
          case parent_segments {
            [] -> NoSourceLoc
            _ -> lookup_with_ancestor(index, string.join(parent_segments, "."))
          }
        }
      }
  }
}

@external(erlang, "yaml_loc_ffi", "build_location_index")
fn do_build(content: String) -> Result(List(#(String, #(Int, Int))), Nil)
