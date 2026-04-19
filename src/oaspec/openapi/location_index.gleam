import gleam/dict.{type Dict}
import gleam/list
import gleam/result
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

@external(erlang, "yaml_loc_ffi", "build_location_index")
fn do_build(content: String) -> Result(List(#(String, #(Int, Int))), Nil)
