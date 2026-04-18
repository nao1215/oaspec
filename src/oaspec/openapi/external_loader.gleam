//// Narrow support for external `$ref` values that point at component
//// schemas in a sibling YAML/JSON file — `./other.yaml#/components/schemas/Foo`
//// style. Walks `components.schemas`, pulls referenced schemas from the
//// target file into the main spec, and rewrites the refs to local form.
////
//// Out of scope (see issue #98 parent):
////   - external refs to parameters / request bodies / responses / path items
////   - nested external refs inside ObjectSchema properties (only top-level
////     component-schema entries are handled today)
////   - HTTP/HTTPS URLs
////
//// Name collisions — when an external ref would overwrite an existing local
//// schema, or when two external refs pull in the same fragment name from
//// different files — are surfaced as `Diagnostic` errors rather than
//// silently dropping one side.

import filepath
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import oaspec/openapi/diagnostic.{type Diagnostic}
import oaspec/openapi/schema.{type SchemaRef, Inline, Reference}
import oaspec/openapi/spec.{
  type Components, type OpenApiSpec, type Unresolved, Components, OpenApiSpec,
}
import simplifile

/// Load every `components.schemas` entry whose value is an external
/// filesystem ref, merge the referenced schema into the main spec, and
/// rewrite the entry to a local ref. `base_dir` is the directory of the
/// file this spec was loaded from (used to resolve relative paths).
///
/// If `base_dir` is None (spec loaded from string), external refs are
/// treated as unresolvable and passed through unchanged — downstream
/// validation still rejects them.
pub fn resolve_external_component_refs(
  spec: OpenApiSpec(Unresolved),
  base_dir: option.Option(String),
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
) -> Result(OpenApiSpec(Unresolved), Diagnostic) {
  case spec.components, base_dir {
    Some(components), Some(dir) ->
      process_components(components, dir, parse_file)
      |> result.map(fn(updated) {
        OpenApiSpec(..spec, components: Some(updated))
      })
    _, _ -> Ok(spec)
  }
}

fn process_components(
  components: Components(Unresolved),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
) -> Result(Components(Unresolved), Diagnostic) {
  let entries = dict.to_list(components.schemas)
  let original_local_names = local_schema_names(entries)
  use #(new_entries, _imported) <- result.try(
    list.try_fold(entries, #([], dict.new()), fn(acc, entry) {
      let #(pending, imported) = acc
      let #(name, schema_ref) = entry
      case extract_external_ref(schema_ref) {
        Some(#(rel_path, fragment_name)) -> {
          let resolved_path = filepath.join(base_dir, rel_path)
          use _ <- result.try(check_local_collision(
            name,
            fragment_name,
            resolved_path,
            original_local_names,
          ))
          use _ <- result.try(check_cross_file_collision(
            fragment_name,
            resolved_path,
            imported,
          ))
          use loaded <- result.try(parse_file(resolved_path))
          use target <- result.try(find_external_schema(
            loaded,
            fragment_name,
            resolved_path,
          ))
          // Rewrite the entry to a local ref pointing at the imported schema,
          // and emit the target schema under the same fragment name so a
          // local lookup succeeds.
          let local_ref =
            Reference(
              ref: "#/components/schemas/" <> fragment_name,
              name: fragment_name,
            )
          let pending = [
            #(name, local_ref),
            #(fragment_name, target),
            ..pending
          ]
          let imported = dict.insert(imported, fragment_name, resolved_path)
          Ok(#(pending, imported))
        }
        None -> Ok(#([#(name, schema_ref), ..pending], imported))
      }
    }),
  )
  let merged =
    list.fold(new_entries, dict.new(), fn(d, pair) {
      dict.insert(d, pair.0, pair.1)
    })
  Ok(Components(..components, schemas: merged))
}

/// Names in the current spec that are *not themselves* external refs.
/// These are the schemas the external loader must not silently overwrite.
fn local_schema_names(entries: List(#(String, SchemaRef))) -> List(String) {
  list.filter_map(entries, fn(entry) {
    case extract_external_ref(entry.1) {
      Some(_) -> Error(Nil)
      None -> Ok(entry.0)
    }
  })
}

/// Reject an external ref whose fragment name would collide with a schema
/// already defined locally in the same spec. The case where the entry name
/// equals the fragment name (`Widget: $ref: './other.yaml#/.../Widget'`) is
/// intentionally allowed — we treat it as the user asking for that slot to
/// hold the imported schema.
fn check_local_collision(
  entry_name: String,
  fragment_name: String,
  source_path: String,
  original_local_names: List(String),
) -> Result(Nil, Diagnostic) {
  case entry_name == fragment_name {
    True -> Ok(Nil)
    False ->
      case list.contains(original_local_names, fragment_name) {
        False -> Ok(Nil)
        True ->
          Error(diagnostic.validation(
            severity: diagnostic.SeverityError,
            target: diagnostic.TargetBoth,
            path: source_path,
            detail: "External $ref imports schema '"
              <> fragment_name
              <> "' from '"
              <> source_path
              <> "', but a local schema with the same name is already defined.",
            hint: Some(
              "Rename one of the colliding schemas, or point the external ref at a file whose fragment name is unique.",
            ),
          ))
      }
  }
}

/// Reject two external refs that both pull the same fragment name from
/// different source files. Re-importing the same name from the same path is
/// allowed (idempotent) to keep error messages narrow.
fn check_cross_file_collision(
  fragment_name: String,
  resolved_path: String,
  imported: dict.Dict(String, String),
) -> Result(Nil, Diagnostic) {
  case dict.get(imported, fragment_name) {
    Error(_) -> Ok(Nil)
    Ok(prev_path) ->
      case prev_path == resolved_path {
        True -> Ok(Nil)
        False ->
          Error(diagnostic.validation(
            severity: diagnostic.SeverityError,
            target: diagnostic.TargetBoth,
            path: resolved_path,
            detail: "External $ref imports schema '"
              <> fragment_name
              <> "' from '"
              <> resolved_path
              <> "', but the same name was already imported from '"
              <> prev_path
              <> "'.",
            hint: Some(
              "Rename one of the schemas in the source files so imports do not collide.",
            ),
          ))
      }
  }
}

/// Detect a `./...#/components/schemas/Name` or `../...#/components/schemas/Name`
/// ref. Returns `Some(#(file_path, schema_name))` when it matches, `None`
/// otherwise.
fn extract_external_ref(
  schema_ref: SchemaRef,
) -> option.Option(#(String, String)) {
  case schema_ref {
    Reference(ref:, ..) ->
      case string.starts_with(ref, "./") || string.starts_with(ref, "../") {
        True ->
          case string.split_once(ref, "#") {
            Ok(#(file_path, fragment)) ->
              case string.starts_with(fragment, "/components/schemas/") {
                True -> {
                  let name =
                    string.replace(fragment, "/components/schemas/", "")
                  case string.contains(name, "/"), name {
                    False, "" -> None
                    False, _ -> Some(#(file_path, name))
                    True, _ -> None
                  }
                }
                False -> None
              }
            _ -> None
          }
        False -> None
      }
    _ -> None
  }
}

fn find_external_schema(
  loaded: OpenApiSpec(Unresolved),
  name: String,
  source_path: String,
) -> Result(SchemaRef, Diagnostic) {
  case loaded.components {
    Some(components) ->
      case dict.get(components.schemas, name) {
        Ok(Inline(_) as s) -> Ok(s)
        Ok(Reference(..)) ->
          Error(diagnostic.validation(
            severity: diagnostic.SeverityError,
            target: diagnostic.TargetBoth,
            path: source_path,
            detail: "External schema '"
              <> name
              <> "' in '"
              <> source_path
              <> "' is itself a $ref; chained external refs are not supported yet.",
            hint: Some(
              "Inline the external schema or flatten one level of indirection.",
            ),
          ))
        Error(Nil) ->
          Error(diagnostic.validation(
            severity: diagnostic.SeverityError,
            target: diagnostic.TargetBoth,
            path: source_path,
            detail: "External file '"
              <> source_path
              <> "' has no components.schemas."
              <> name,
            hint: Some(
              "Verify the ref path and that the referenced file defines the schema.",
            ),
          ))
      }
    None ->
      Error(diagnostic.validation(
        severity: diagnostic.SeverityError,
        target: diagnostic.TargetBoth,
        path: source_path,
        detail: "External file '" <> source_path <> "' has no components block.",
        hint: Some(
          "Add a components.schemas section to the referenced file or inline the schema.",
        ),
      ))
  }
}

/// Helper used by `parser.parse_file` to compute a spec's base directory.
/// Empty-string (current working directory) is returned when the filepath
/// module can't extract a parent — callers can then pass `Some("")` which
/// resolves relative refs against CWD.
pub fn base_dir_of(path: String) -> option.Option(String) {
  case filepath.directory_name(path) {
    "" -> Some(".")
    dir -> Some(dir)
  }
}

/// Read a file from disk. Extracted so tests can stub file I/O by passing
/// their own `parse_file` callback.
pub fn read_file(path: String) -> Result(String, Diagnostic) {
  simplifile.read(path)
  |> result.map_error(fn(_) {
    diagnostic.file_error(detail: "Cannot read external file: " <> path)
  })
}
