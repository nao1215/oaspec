//// Pure planning helpers for the external `$ref` loader. This module
//// contains every decision the loader makes that does not require
//// filesystem IO: ref-string parsing, schema lookups inside a parsed
//// external document, alias resolution, and collision diagnostics.
////
//// The companion `external_loader` module orchestrates the IO side
//// (calling the `parse_file` callback) and delegates each pure decision
//// here. Splitting these responsibilities lets every diagnostic — local
//// collision, cross-file collision, missing component, alias chain,
//// chained external ref — be unit tested without staging fixture files
//// on disk (issue #372).

import filepath
import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/openapi/diagnostic.{type Diagnostic}
import oaspec/openapi/schema.{type SchemaRef, Inline, Reference}
import oaspec/openapi/spec.{
  type Components, type OpenApiSpec, type Parameter, type PathItem,
  type RequestBody, type Response, type Unresolved,
}

/// Names in the current spec that are *not themselves* external refs.
/// These are the schemas the external loader must not silently overwrite.
pub fn local_schema_names(entries: List(#(String, SchemaRef))) -> List(String) {
  list.filter_map(entries, fn(entry) {
    case extract_external_ref(entry.1) {
      Some(_) -> Error(Nil)
      None -> Ok(entry.0)
    }
  })
}

/// Detect external refs like `./other.yaml#/components/parameters/Foo`.
/// Returns Some(#(file_path, component_prefix, name)) or None.
/// Supported prefixes: parameters, requestBodies, responses, pathItems.
pub fn extract_external_component_ref(
  ref_str: String,
) -> Option(#(String, String, String)) {
  let is_relative =
    string.starts_with(ref_str, "./") || string.starts_with(ref_str, "../")
  use <- bool.guard(!is_relative, None)
  case string.split_once(ref_str, "#") {
    Ok(#(file_path, fragment)) ->
      try_component_prefix(file_path, fragment, [
        "/components/parameters/",
        "/components/requestBodies/",
        "/components/responses/",
        "/components/pathItems/",
      ])
    _ -> None
  }
}

/// Try each component prefix against a fragment, returning the first match.
fn try_component_prefix(
  file_path: String,
  fragment: String,
  prefixes: List(String),
) -> Option(#(String, String, String)) {
  case prefixes {
    [] -> None
    [prefix, ..rest] ->
      case string.starts_with(fragment, prefix) {
        True -> {
          let name = string.replace(fragment, prefix, "")
          case string.contains(name, "/"), name {
            False, "" -> None
            False, _ -> Some(#(file_path, prefix, name))
            True, _ -> None
          }
        }
        False -> try_component_prefix(file_path, fragment, rest)
      }
  }
}

/// Look up a parameter by name in an external file's components.
pub fn find_external_parameter(
  loaded: OpenApiSpec(Unresolved),
  name: String,
  source_path: String,
) -> Result(Parameter(Unresolved), Diagnostic) {
  case loaded.components {
    Some(components) ->
      case dict.get(components.parameters, name) {
        Ok(spec.Value(p)) -> Ok(p)
        Ok(spec.Ref(_)) ->
          Error(diagnostic.validation(
            severity: diagnostic.SeverityError,
            target: diagnostic.TargetBoth,
            path: source_path,
            detail: "External parameter '"
              <> name
              <> "' in '"
              <> source_path
              <> "' is itself a $ref; chained external refs are not supported.",
            hint: Some(
              "Inline the parameter in the external file or flatten the ref chain.",
            ),
          ))
        Error(Nil) ->
          Error(diagnostic.validation(
            severity: diagnostic.SeverityError,
            target: diagnostic.TargetBoth,
            path: source_path,
            detail: "External file '"
              <> source_path
              <> "' has no components.parameters."
              <> name,
            hint: Some(
              "Verify the ref path and that the referenced file defines the parameter.",
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
          "Add a components.parameters section to the referenced file.",
        ),
      ))
  }
}

/// Look up a request body by name in an external file's components.
pub fn find_external_request_body(
  loaded: OpenApiSpec(Unresolved),
  name: String,
  source_path: String,
) -> Result(RequestBody(Unresolved), Diagnostic) {
  case loaded.components {
    Some(components) ->
      case dict.get(components.request_bodies, name) {
        Ok(spec.Value(rb)) -> Ok(rb)
        Ok(spec.Ref(_)) ->
          Error(diagnostic.validation(
            severity: diagnostic.SeverityError,
            target: diagnostic.TargetBoth,
            path: source_path,
            detail: "External request body '"
              <> name
              <> "' in '"
              <> source_path
              <> "' is itself a $ref; chained external refs are not supported.",
            hint: Some(
              "Inline the request body in the external file or flatten the ref chain.",
            ),
          ))
        Error(Nil) ->
          Error(diagnostic.validation(
            severity: diagnostic.SeverityError,
            target: diagnostic.TargetBoth,
            path: source_path,
            detail: "External file '"
              <> source_path
              <> "' has no components.requestBodies."
              <> name,
            hint: Some(
              "Verify the ref path and that the referenced file defines the request body.",
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
          "Add a components.requestBodies section to the referenced file.",
        ),
      ))
  }
}

/// Look up a response by name in an external file's components.
pub fn find_external_response(
  loaded: OpenApiSpec(Unresolved),
  name: String,
  source_path: String,
) -> Result(Response(Unresolved), Diagnostic) {
  case loaded.components {
    Some(components) ->
      case dict.get(components.responses, name) {
        Ok(spec.Value(r)) -> Ok(r)
        Ok(spec.Ref(_)) ->
          Error(diagnostic.validation(
            severity: diagnostic.SeverityError,
            target: diagnostic.TargetBoth,
            path: source_path,
            detail: "External response '"
              <> name
              <> "' in '"
              <> source_path
              <> "' is itself a $ref; chained external refs are not supported.",
            hint: Some(
              "Inline the response in the external file or flatten the ref chain.",
            ),
          ))
        Error(Nil) ->
          Error(diagnostic.validation(
            severity: diagnostic.SeverityError,
            target: diagnostic.TargetBoth,
            path: source_path,
            detail: "External file '"
              <> source_path
              <> "' has no components.responses."
              <> name,
            hint: Some(
              "Verify the ref path and that the referenced file defines the response.",
            ),
          ))
      }
    None ->
      Error(diagnostic.validation(
        severity: diagnostic.SeverityError,
        target: diagnostic.TargetBoth,
        path: source_path,
        detail: "External file '" <> source_path <> "' has no components block.",
        hint: Some("Add a components.responses section to the referenced file."),
      ))
  }
}

/// Look up a path item by name in an external file's components.
pub fn find_external_path_item(
  loaded: OpenApiSpec(Unresolved),
  name: String,
  source_path: String,
) -> Result(PathItem(Unresolved), Diagnostic) {
  case loaded.components {
    Some(components) ->
      case dict.get(components.path_items, name) {
        Ok(spec.Value(pi)) -> Ok(pi)
        Ok(spec.Ref(_)) ->
          Error(diagnostic.validation(
            severity: diagnostic.SeverityError,
            target: diagnostic.TargetBoth,
            path: source_path,
            detail: "External path item '"
              <> name
              <> "' in '"
              <> source_path
              <> "' is itself a $ref; chained external refs are not supported.",
            hint: Some(
              "Inline the path item in the external file or flatten the ref chain.",
            ),
          ))
        Error(Nil) ->
          Error(diagnostic.validation(
            severity: diagnostic.SeverityError,
            target: diagnostic.TargetBoth,
            path: source_path,
            detail: "External file '"
              <> source_path
              <> "' has no components.pathItems."
              <> name,
            hint: Some(
              "Verify the ref path and that the referenced file defines the path item.",
            ),
          ))
      }
    None ->
      Error(diagnostic.validation(
        severity: diagnostic.SeverityError,
        target: diagnostic.TargetBoth,
        path: source_path,
        detail: "External file '" <> source_path <> "' has no components block.",
        hint: Some("Add a components.pathItems section to the referenced file."),
      ))
  }
}

/// Reject a nested property ref whose fragment name collides with a schema
/// that was authored inline in the main spec. Without this guard the nested
/// import would silently rebind to the local schema — even if its shape is
/// unrelated — because the merged dict already holds that slot.
pub fn check_nested_local_collision(
  fragment_name: String,
  source_path: String,
  original_local_names: List(String),
) -> Result(Nil, Diagnostic) {
  use <- bool.guard(
    !list.contains(original_local_names, fragment_name),
    Ok(Nil),
  )
  Error(diagnostic.validation(
    severity: diagnostic.SeverityError,
    target: diagnostic.TargetBoth,
    path: source_path,
    detail: "Nested property $ref imports schema '"
      <> fragment_name
      <> "' from '"
      <> source_path
      <> "', but a local schema with the same name is already defined.",
    hint: Some(
      "Rename one of the colliding schemas, or point the external ref at a file whose fragment name is unique.",
    ),
  ))
}

/// Same shape as `check_cross_file_collision` but reads from the
/// `imports: Dict(fragment_name, #(source_path, target_schema))` dict used
/// by the nested-property phase.
pub fn check_nested_cross_file_collision(
  fragment_name: String,
  resolved_path: String,
  imports: dict.Dict(String, #(String, SchemaRef)),
) -> Result(Nil, Diagnostic) {
  case dict.get(imports, fragment_name) {
    // nolint: thrown_away_error -- dict.get Error only signals absent key; no diagnostic to propagate
    Error(_) -> Ok(Nil)
    Ok(#(prev_path, _)) ->
      case prev_path == resolved_path {
        True -> Ok(Nil)
        False ->
          Error(diagnostic.validation(
            severity: diagnostic.SeverityError,
            target: diagnostic.TargetBoth,
            path: resolved_path,
            detail: "Nested property $ref imports schema '"
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

/// Reject an external ref whose fragment name would collide with a schema
/// already defined locally in the same spec. The case where the entry name
/// equals the fragment name (`Widget: $ref: './other.yaml#/.../Widget'`) is
/// intentionally allowed — we treat it as the user asking for that slot to
/// hold the imported schema.
pub fn check_local_collision(
  entry_name: String,
  fragment_name: String,
  source_path: String,
  original_local_names: List(String),
) -> Result(Nil, Diagnostic) {
  use <- bool.guard(entry_name == fragment_name, Ok(Nil))
  use <- bool.guard(
    !list.contains(original_local_names, fragment_name),
    Ok(Nil),
  )
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

/// Reject two external refs that both pull the same fragment name from
/// different source files. Re-importing the same name from the same path is
/// allowed (idempotent) to keep error messages narrow.
pub fn check_cross_file_collision(
  fragment_name: String,
  resolved_path: String,
  imported: dict.Dict(String, String),
) -> Result(Nil, Diagnostic) {
  case dict.get(imported, fragment_name) {
    // nolint: thrown_away_error -- dict.get Error only signals absent key; no diagnostic to propagate
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
pub fn extract_external_ref(schema_ref: SchemaRef) -> Option(#(String, String)) {
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

/// Look up a schema by name in an external file. Returns the inline schema
/// (resolving one level of local aliasing) or surfaces a diagnostic if the
/// file lacks `components`, the schema is missing, or the alias chain is
/// not single-hop / cross-file.
pub fn find_external_schema(
  loaded: OpenApiSpec(Unresolved),
  name: String,
  source_path: String,
) -> Result(SchemaRef, Diagnostic) {
  case loaded.components {
    Some(components) -> find_schema_follow_alias(components, name, source_path)
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

/// Look up `name` in the external file's `components.schemas`. If the
/// value is inline, return it directly. If it is a local alias
/// (`#/components/schemas/Other`) pointing at another schema *in the
/// same file*, follow the alias one level. Cross-file chained refs and
/// longer alias chains still surface a diagnostic.
pub fn find_schema_follow_alias(
  components: Components(Unresolved),
  name: String,
  source_path: String,
) -> Result(SchemaRef, Diagnostic) {
  case dict.get(components.schemas, name) {
    Ok(Inline(_) as s) -> Ok(s)
    Ok(Reference(ref:, ..)) ->
      case local_schema_name_from_ref(ref) {
        Some(aliased) ->
          case dict.get(components.schemas, aliased) {
            Ok(Inline(_) as s) -> Ok(s)
            _ ->
              Error(diagnostic.validation(
                severity: diagnostic.SeverityError,
                target: diagnostic.TargetBoth,
                path: source_path,
                detail: "External schema '"
                  <> name
                  <> "' in '"
                  <> source_path
                  <> "' aliases '"
                  <> aliased
                  <> "', but the target is itself a $ref or missing; only a single level of aliasing inside the same file is supported.",
                hint: Some(
                  "Flatten the alias chain in the external file so the target resolves to an inline schema.",
                ),
              ))
          }
        None ->
          Error(diagnostic.validation(
            severity: diagnostic.SeverityError,
            target: diagnostic.TargetBoth,
            path: source_path,
            detail: "External schema '"
              <> name
              <> "' in '"
              <> source_path
              <> "' is itself a $ref pointing outside this file; chained external refs are not supported yet.",
            hint: Some(
              "Inline the external schema or flatten the ref to live inside the same file.",
            ),
          ))
      }
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
}

/// If `ref` is a local component-schemas ref inside the same file (no
/// leading file part), return the schema name. Otherwise return None
/// so the caller can surface a cross-file diagnostic.
pub fn local_schema_name_from_ref(ref: String) -> Option(String) {
  let prefix = "#/components/schemas/"
  case string.starts_with(ref, prefix) {
    True -> {
      let name = string.replace(ref, prefix, "")
      case string.contains(name, "/"), name {
        False, "" -> None
        False, _ -> Some(name)
        True, _ -> None
      }
    }
    False -> None
  }
}

/// Helper used by `parser.parse_file` to compute a spec's base directory.
/// Empty-string (current working directory) is returned when the filepath
/// module can't extract a parent — callers can then pass `Some("")` which
/// resolves relative refs against CWD.
pub fn base_dir_of(path: String) -> Option(String) {
  case filepath.directory_name(path) {
    "" -> Some(".")
    dir -> Some(dir)
  }
}
