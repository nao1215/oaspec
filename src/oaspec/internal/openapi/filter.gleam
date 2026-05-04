//// Subset filter for the OpenAPI generation pipeline (Issue #387).
////
//// Applies the user's `include:` config (`tags` and / or `paths`)
//// to a Resolved OpenApiSpec by keeping only operations whose tag
//// list intersects `include.tags` OR whose path matches one of
//// `include.paths`. Paths whose every operation gets dropped are
//// removed from `spec.paths`. Components, webhooks, security
//// schemes, and other top-level fields are left untouched —
//// component pruning is a separate optimisation.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/config.{type Include}
import oaspec/internal/openapi/spec.{
  type OpenApiSpec, type Operation, type PathItem, type RefOr, type Resolved,
  OpenApiSpec, PathItem, Ref, Value,
}

/// Apply the include filter to a Resolved spec. When the filter is
/// empty (`include_is_empty == True`), the spec is returned
/// unchanged. Otherwise paths are walked, each operation is checked
/// against tag and path criteria, and operations / paths that fail
/// are dropped.
pub fn apply(
  spec: OpenApiSpec(Resolved),
  include: Include,
) -> OpenApiSpec(Resolved) {
  use <- bool.guard(config.include_is_empty(include), spec)
  let new_paths = filter_paths(spec.paths, include)
  OpenApiSpec(..spec, paths: new_paths)
}

fn filter_paths(
  paths: Dict(String, RefOr(PathItem(Resolved))),
  include: Include,
) -> Dict(String, RefOr(PathItem(Resolved))) {
  paths
  |> dict.to_list
  |> list.filter_map(fn(entry) {
    let #(path, ref_or_item) = entry
    case ref_or_item {
      Value(item) -> {
        let filtered_item = filter_path_item(path, item, include)
        case path_item_has_operations(filtered_item) {
          True -> Ok(#(path, Value(filtered_item)))
          False -> Error(Nil)
        }
      }
      // Resolve eliminates `Ref(_)` before this filter runs; if one
      // somehow survives we leave it alone rather than silently
      // dropping it, which would mask a deeper bug.
      Ref(_) -> Ok(entry)
    }
  })
  |> dict.from_list
}

fn filter_path_item(
  path: String,
  item: PathItem(Resolved),
  include: Include,
) -> PathItem(Resolved) {
  let keep = fn(op) { keep_operation(path, op, include) }
  PathItem(
    ..item,
    get: filter_op(item.get, keep),
    post: filter_op(item.post, keep),
    put: filter_op(item.put, keep),
    delete: filter_op(item.delete, keep),
    patch: filter_op(item.patch, keep),
    head: filter_op(item.head, keep),
    options: filter_op(item.options, keep),
    trace: filter_op(item.trace, keep),
  )
}

fn filter_op(
  op: Option(Operation(Resolved)),
  keep: fn(Operation(Resolved)) -> Bool,
) -> Option(Operation(Resolved)) {
  case op {
    None -> None
    Some(o) ->
      case keep(o) {
        True -> Some(o)
        False -> None
      }
  }
}

fn path_item_has_operations(item: PathItem(Resolved)) -> Bool {
  option.is_some(item.get)
  || option.is_some(item.post)
  || option.is_some(item.put)
  || option.is_some(item.delete)
  || option.is_some(item.patch)
  || option.is_some(item.head)
  || option.is_some(item.options)
  || option.is_some(item.trace)
}

fn keep_operation(
  path: String,
  op: Operation(Resolved),
  include: Include,
) -> Bool {
  // OR semantics across the two axes: an operation passes if its
  // tags intersect `include.tags` OR its path matches one of
  // `include.paths`. With a single axis active, the other is "no
  // restriction"; with both empty the caller short-circuits via
  // `apply/2`'s `include_is_empty` check.
  case include.tags, include.paths {
    [], [] -> True
    [], _ -> path_matches(path, include.paths)
    _, [] -> tags_match(op.tags, include.tags)
    _, _ ->
      tags_match(op.tags, include.tags) || path_matches(path, include.paths)
  }
}

fn tags_match(op_tags: List(String), include_tags: List(String)) -> Bool {
  list.any(op_tags, fn(t) { list.contains(include_tags, t) })
}

/// Match a path string against a list of include patterns. A pattern
/// ending in `/**` matches any path that has the prefix-up-to-`/**`
/// followed by a `/` segment. Otherwise the pattern is compared by
/// exact equality.
pub fn path_matches(path: String, patterns: List(String)) -> Bool {
  list.any(patterns, fn(pattern) {
    case string.ends_with(pattern, "/**") {
      True -> {
        // Drop the trailing 3 characters (`/**`) to recover the
        // prefix; require the path to extend the prefix with `/<rest>`
        // so `/repos/**` matches `/repos/foo` but not `/repository`.
        let prefix = string.drop_end(pattern, 3)
        string.starts_with(path, prefix <> "/")
      }
      False -> path == pattern
    }
  })
}
