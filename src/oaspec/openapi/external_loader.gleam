//// Support for external `$ref` values that point at component definitions
//// in a sibling YAML/JSON file — `./other.yaml#/components/schemas/Foo`
//// style. Walks `components.schemas`, pulls referenced schemas from the
//// target file into the main spec, and rewrites the refs to local form.
////
//// Supported shapes:
////   - top-level component schema entries (`components.schemas.Foo: $ref: ...`)
////   - ObjectSchema property values (`properties.field: $ref: ...`)
////   - ArraySchema item values (`items: $ref: ...`)
////   - ObjectSchema additionalProperties values (`additionalProperties: $ref: ...`)
////   - composition branches (`oneOf`, `anyOf`, `allOf` variant refs)
////   - `components.parameters.*.schema: $ref: ...` (parameter schema only)
////   - `components.parameters.*.content.*.schema: $ref: ...`
////   - `components.request_bodies.*.content.*.schema: $ref: ...`
////   - `components.responses.*.content.*.schema: $ref: ...`
////   - operation-level `parameters[*].schema` / `parameters[*].content.*.schema`
////     on both `paths.<path>.parameters` and `paths.<path>.<method>.parameters`
////   - operation-level `requestBody.content.*.schema`
////   - operation-level `responses.<code>.content.*.schema`
////   - `components.headers.*.schema` and every `Response.headers.*.schema`
////     (both under `components.responses` and operation-level responses)
////   - refs inside `components.path_items.*` (reusable PathItem
////     definitions, walked via the same `rewrite_path_item` helper
////     used at the top level)
////   - refs inside `operation.callbacks.*.entries.*` PathItems (recursive)
////   - whole-object external refs for `components.parameters`,
////     `components.requestBodies`, `components.responses`, and
////     `components.pathItems` (e.g., `$ref: './other.yaml#/components/parameters/Foo'`)
////   - one level of alias chaining inside the same external file
////     (`LegacyX: $ref: "#/components/schemas/X"` in the external file).
////     Cross-file chains collapse naturally because parse_file runs
////     the resolver on every loaded file before handing it back, so a
////     target that is itself an external ref is already inline by the
////     time we look it up.
////
//// Out of scope (see issue #98 parent):
////   - alias chains longer than one hop inside the same file
////   - HTTP/HTTPS URLs
////
//// Cyclic external refs (e.g., `A.yaml` → `B.yaml` → `A.yaml`) used
//// to loop forever, but are now detected: `parser.parse_file`
//// threads a visited-file stack through every recursive load and
//// emits a dedicated `invalid_value` diagnostic that shows the cycle
//// path instead of recursing indefinitely (issue #233).
////
//// Name collisions — when an external ref would overwrite an existing local
//// schema, or when two external refs pull in the same fragment name from
//// different files — are surfaced as `Diagnostic` errors rather than
//// silently dropping one side.

import filepath
import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import oaspec/openapi/diagnostic.{type Diagnostic}
import oaspec/openapi/schema.{type SchemaRef, Inline, Reference}
import oaspec/openapi/spec.{
  type Components, type OpenApiSpec, type Parameter, type PathItem,
  type RequestBody, type Response, type Unresolved, Components, OpenApiSpec,
}
import oaspec/util/http

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
    Some(components), Some(dir) -> {
      let original_local_names =
        local_schema_names(dict.to_list(components.schemas))
      use #(top_resolved, top_imported) <- result.try(process_components(
        components,
        dir,
        parse_file,
        original_local_names,
      ))
      use whole_resolved <- result.try(process_whole_object_refs(
        top_resolved,
        dir,
        parse_file,
      ))
      use #(nested_resolved, nested_imports) <- result.try(
        process_nested_property_refs(
          whole_resolved,
          dir,
          parse_file,
          original_local_names,
          top_imported,
        ),
      )
      use #(param_resolved, param_imports) <- result.try(
        process_parameter_schemas(
          nested_resolved,
          dir,
          parse_file,
          original_local_names,
          nested_imports,
        ),
      )
      use #(body_resolved, body_imports) <- result.try(
        process_body_response_schemas(
          param_resolved,
          dir,
          parse_file,
          original_local_names,
          param_imports,
        ),
      )
      use #(header_resolved, header_imports) <- result.try(
        process_component_headers(
          body_resolved,
          dir,
          parse_file,
          original_local_names,
          body_imports,
        ),
      )
      use #(path_items_resolved, path_items_imports) <- result.try(
        process_component_path_items(
          header_resolved,
          dir,
          parse_file,
          original_local_names,
          header_imports,
        ),
      )
      use #(new_paths, op_final_components) <- result.try(
        process_operation_schemas(
          spec.paths,
          path_items_resolved,
          dir,
          parse_file,
          original_local_names,
          path_items_imports,
        ),
      )
      Ok(
        OpenApiSpec(
          ..spec,
          paths: new_paths,
          components: Some(op_final_components),
        ),
      )
    }
    _, _ -> Ok(spec)
  }
}

fn process_components(
  components: Components(Unresolved),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  original_local_names: List(String),
) -> Result(#(Components(Unresolved), dict.Dict(String, String)), Diagnostic) {
  let entries = dict.to_list(components.schemas)
  use #(new_entries, imported) <- result.try(
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
  Ok(#(Components(..components, schemas: merged), imported))
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

/// Detect external refs like `./other.yaml#/components/parameters/Foo`.
/// Returns Some(#(file_path, component_prefix, name)) or None.
/// Supported prefixes: parameters, requestBodies, responses, pathItems.
fn extract_external_component_ref(
  ref_str: String,
) -> option.Option(#(String, String, String)) {
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
) -> option.Option(#(String, String, String)) {
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

/// Walk `components.parameters`, `request_bodies`, `responses`, and
/// `path_items`: for each `Ref(ref_str)` entry that is an external
/// component ref (e.g., `./other.yaml#/components/parameters/Foo`),
/// load the external file and replace the entry with `Value(loaded_object)`.
/// Runs after `process_components` and before `process_nested_property_refs`.
fn process_whole_object_refs(
  components: Components(Unresolved),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
) -> Result(Components(Unresolved), Diagnostic) {
  // parameters
  use new_parameters <- result.try(resolve_ref_or_dict(
    components.parameters,
    base_dir,
    parse_file,
    "/components/parameters/",
    find_external_parameter,
  ))
  // request_bodies
  use new_request_bodies <- result.try(resolve_ref_or_dict(
    components.request_bodies,
    base_dir,
    parse_file,
    "/components/requestBodies/",
    find_external_request_body,
  ))
  // responses
  use new_responses <- result.try(resolve_ref_or_dict(
    components.responses,
    base_dir,
    parse_file,
    "/components/responses/",
    find_external_response,
  ))
  // path_items
  use new_path_items <- result.try(resolve_ref_or_dict(
    components.path_items,
    base_dir,
    parse_file,
    "/components/pathItems/",
    find_external_path_item,
  ))
  Ok(
    Components(
      ..components,
      parameters: new_parameters,
      request_bodies: new_request_bodies,
      responses: new_responses,
      path_items: new_path_items,
    ),
  )
}

/// Generic helper that walks a `Dict(String, RefOr(a))`, resolving any
/// `Ref(ref_str)` whose fragment matches `target_prefix` by loading the
/// external file and looking up the named object via `finder`.
fn resolve_ref_or_dict(
  entries: dict.Dict(String, spec.RefOr(a)),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  target_prefix: String,
  finder: fn(OpenApiSpec(Unresolved), String, String) -> Result(a, Diagnostic),
) -> Result(dict.Dict(String, spec.RefOr(a)), Diagnostic) {
  let pairs = dict.to_list(entries)
  use new_pairs <- result.try(
    list.try_fold(pairs, [], fn(acc, entry) {
      let #(name, ref_or_val) = entry
      case ref_or_val {
        spec.Ref(ref_str) ->
          case extract_external_component_ref(ref_str) {
            Some(#(file_path, prefix, obj_name)) if prefix == target_prefix -> {
              let resolved_path = filepath.join(base_dir, file_path)
              use loaded <- result.try(parse_file(resolved_path))
              use target <- result.try(finder(loaded, obj_name, resolved_path))
              Ok([#(name, spec.Value(target)), ..acc])
            }
            _ -> Ok([#(name, ref_or_val), ..acc])
          }
        spec.Value(_) -> Ok([#(name, ref_or_val), ..acc])
      }
    }),
  )
  Ok(
    list.fold(new_pairs, dict.new(), fn(d, pair) {
      dict.insert(d, pair.0, pair.1)
    }),
  )
}

/// Look up a parameter by name in an external file's components.
fn find_external_parameter(
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
fn find_external_request_body(
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
fn find_external_response(
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
fn find_external_path_item(
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

/// Walk each `components.schemas` entry that is an `Inline(ObjectSchema)` and
/// hoist any property whose value is a relative-file `$ref`. The referenced
/// schema is added to `components.schemas` under its fragment name, and the
/// property is rewritten to a local `#/components/schemas/<fragment>` ref.
///
/// Runs after `process_components` so top-level external refs are already
/// merged in. Collisions are surfaced rather than silently resolved:
///   - if the nested fragment name matches a schema that was originally
///     authored inline in the main spec, error (silent-shadowing guard);
///   - if two refs pull the same fragment name from different source files
///     (whether nested or top-level), error;
///   - same-file re-imports remain idempotent.
fn process_nested_property_refs(
  components: Components(Unresolved),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  original_local_names: List(String),
  top_imported: dict.Dict(String, String),
) -> Result(
  #(Components(Unresolved), dict.Dict(String, #(String, SchemaRef))),
  Diagnostic,
) {
  let entries = dict.to_list(components.schemas)
  // Seed the nested-import tracker with every top-level external import so
  // a nested property that re-imports the same fragment from a different
  // file is caught as a cross-file collision.
  let seeded_imports =
    dict.fold(top_imported, dict.new(), fn(d, frag_name, source_path) {
      dict.insert(d, frag_name, #(source_path, no_target()))
    })
  use #(rewritten, imports) <- result.try(
    list.try_fold(entries, #([], seeded_imports), fn(acc, entry) {
      let #(rewritten_acc, imports) = acc
      let #(name, schema_ref) = entry
      case schema_ref {
        Inline(schema.ObjectSchema(
          metadata:,
          properties:,
          required:,
          additional_properties:,
          min_properties:,
          max_properties:,
        )) -> {
          use #(new_properties, props_imports) <- result.try(
            rewrite_object_properties(
              properties,
              base_dir,
              parse_file,
              imports,
              original_local_names,
            ),
          )
          use #(new_additional_properties, new_imports) <- result.try(
            rewrite_additional_properties(
              additional_properties,
              base_dir,
              parse_file,
              props_imports,
              original_local_names,
            ),
          )
          let new_obj =
            schema.ObjectSchema(
              metadata:,
              properties: new_properties,
              required:,
              additional_properties: new_additional_properties,
              min_properties:,
              max_properties:,
            )
          Ok(#([#(name, Inline(new_obj)), ..rewritten_acc], new_imports))
        }
        Inline(schema.ArraySchema(
          metadata:,
          items:,
          min_items:,
          max_items:,
          unique_items:,
        )) -> {
          use #(new_items, new_imports) <- result.try(maybe_hoist_ref(
            items,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          let new_arr =
            schema.ArraySchema(
              metadata:,
              items: new_items,
              min_items:,
              max_items:,
              unique_items:,
            )
          Ok(#([#(name, Inline(new_arr)), ..rewritten_acc], new_imports))
        }
        Inline(schema.AllOfSchema(metadata:, schemas: branches)) -> {
          use #(new_branches, new_imports) <- result.try(rewrite_schema_list(
            branches,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          let new_all = schema.AllOfSchema(metadata:, schemas: new_branches)
          Ok(#([#(name, Inline(new_all)), ..rewritten_acc], new_imports))
        }
        Inline(schema.OneOfSchema(metadata:, schemas: branches, discriminator:)) -> {
          use #(new_branches, new_imports) <- result.try(rewrite_schema_list(
            branches,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          let new_one =
            schema.OneOfSchema(metadata:, schemas: new_branches, discriminator:)
          Ok(#([#(name, Inline(new_one)), ..rewritten_acc], new_imports))
        }
        Inline(schema.AnyOfSchema(metadata:, schemas: branches, discriminator:)) -> {
          use #(new_branches, new_imports) <- result.try(rewrite_schema_list(
            branches,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          let new_any =
            schema.AnyOfSchema(metadata:, schemas: new_branches, discriminator:)
          Ok(#([#(name, Inline(new_any)), ..rewritten_acc], new_imports))
        }
        _ -> Ok(#([#(name, schema_ref), ..rewritten_acc], imports))
      }
    }),
  )
  let merged =
    list.fold(rewritten, dict.new(), fn(d, pair) {
      dict.insert(d, pair.0, pair.1)
    })
  // Nested imports populate any slot the rewritten pass hasn't filled.
  // Seeded top-level entries carry a placeholder schema (`no_target`)
  // and are only skipped — they were already merged during the top-level
  // pass.
  let merged =
    dict.fold(imports, merged, fn(d, frag_name, pair) {
      let #(_source_path, target_schema) = pair
      case dict.has_key(d, frag_name), target_schema {
        True, _ -> d
        False, Inline(_) -> dict.insert(d, frag_name, target_schema)
        False, _ -> d
      }
    })
  Ok(#(Components(..components, schemas: merged), imports))
}

/// Placeholder target used to seed the nested-import tracker with top-level
/// imports whose schema was already merged. `Reference("", "")` is never
/// emitted as a real value — the merge step filters it out by matching only
/// on `Inline(_)` targets.
fn no_target() -> SchemaRef {
  Reference(ref: "", name: "")
}

/// Walk `spec.paths`: for each inline `PathItem`, rewrite its path-level
/// `parameters` list, every populated HTTP method `Operation` (via
/// `rewrite_operation`), and feed any newly imported schemas into
/// `components.schemas`. `RefOr.Ref` path items passing pointers to
/// external files are left untouched.
fn process_operation_schemas(
  paths: dict.Dict(String, spec.RefOr(spec.PathItem(Unresolved))),
  components: Components(Unresolved),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  original_local_names: List(String),
  seeded_imports: dict.Dict(String, #(String, SchemaRef)),
) -> Result(
  #(
    dict.Dict(String, spec.RefOr(spec.PathItem(Unresolved))),
    Components(Unresolved),
  ),
  Diagnostic,
) {
  let entries = dict.to_list(paths)
  use #(rewritten, final_imports) <- result.try(
    list.try_fold(entries, #([], seeded_imports), fn(acc, entry) {
      let #(collected, imports) = acc
      let #(path_key, ref_or_item) = entry
      case ref_or_item {
        spec.Value(path_item) -> {
          use #(new_path_item, new_imports) <- result.try(rewrite_path_item(
            path_item,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          Ok(#(
            [#(path_key, spec.Value(new_path_item)), ..collected],
            new_imports,
          ))
        }
        spec.Ref(_) -> Ok(#([#(path_key, ref_or_item), ..collected], imports))
      }
    }),
  )
  let new_paths =
    list.fold(rewritten, dict.new(), fn(d, pair) {
      dict.insert(d, pair.0, pair.1)
    })
  let new_schemas =
    dict.fold(final_imports, components.schemas, fn(d, frag_name, pair) {
      let #(_source_path, target_schema) = pair
      case dict.has_key(d, frag_name), target_schema {
        True, _ -> d
        False, Inline(_) -> dict.insert(d, frag_name, target_schema)
        False, _ -> d
      }
    })
  Ok(#(new_paths, Components(..components, schemas: new_schemas)))
}

/// Rewrite each `RefOr(Parameter)` in a parameter list, threading the
/// imports tracker so collisions across operation-level and components
/// refs remain visible.
fn rewrite_parameter_list(
  parameters: List(spec.RefOr(spec.Parameter(Unresolved))),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(
    List(spec.RefOr(spec.Parameter(Unresolved))),
    dict.Dict(String, #(String, SchemaRef)),
  ),
  Diagnostic,
) {
  use #(collected, new_imports) <- result.try(
    list.try_fold(parameters, #([], imports), fn(acc, item) {
      let #(done, imports) = acc
      use #(new_item, new_imports) <- result.try(rewrite_ref_or_parameter(
        item,
        base_dir,
        parse_file,
        imports,
        original_local_names,
      ))
      Ok(#([new_item, ..done], new_imports))
    }),
  )
  Ok(#(list.reverse(collected), new_imports))
}

/// Rewrite both the path-level `parameters` list and every populated
/// method slot on a `PathItem`. Shared by the top-level paths walker
/// and the callback walker so callbacks recurse into the same helper.
fn rewrite_path_item(
  path_item: spec.PathItem(Unresolved),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(spec.PathItem(Unresolved), dict.Dict(String, #(String, SchemaRef))),
  Diagnostic,
) {
  use #(new_parameters, imports_after_params) <- result.try(
    rewrite_parameter_list(
      path_item.parameters,
      base_dir,
      parse_file,
      imports,
      original_local_names,
    ),
  )
  rewrite_path_item_methods(
    spec.PathItem(..path_item, parameters: new_parameters),
    base_dir,
    parse_file,
    imports_after_params,
    original_local_names,
  )
}

/// Rewrite every populated HTTP-method slot on a `PathItem`. Each inline
/// `Operation` has its own `parameters`, `request_body`, and `responses`
/// dicts rewritten.
fn rewrite_path_item_methods(
  path_item: spec.PathItem(Unresolved),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(spec.PathItem(Unresolved), dict.Dict(String, #(String, SchemaRef))),
  Diagnostic,
) {
  use #(get_op, imports1) <- result.try(rewrite_optional_operation(
    path_item.get,
    base_dir,
    parse_file,
    imports,
    original_local_names,
  ))
  use #(post_op, imports2) <- result.try(rewrite_optional_operation(
    path_item.post,
    base_dir,
    parse_file,
    imports1,
    original_local_names,
  ))
  use #(put_op, imports3) <- result.try(rewrite_optional_operation(
    path_item.put,
    base_dir,
    parse_file,
    imports2,
    original_local_names,
  ))
  use #(delete_op, imports4) <- result.try(rewrite_optional_operation(
    path_item.delete,
    base_dir,
    parse_file,
    imports3,
    original_local_names,
  ))
  use #(patch_op, imports5) <- result.try(rewrite_optional_operation(
    path_item.patch,
    base_dir,
    parse_file,
    imports4,
    original_local_names,
  ))
  use #(head_op, imports6) <- result.try(rewrite_optional_operation(
    path_item.head,
    base_dir,
    parse_file,
    imports5,
    original_local_names,
  ))
  use #(options_op, imports7) <- result.try(rewrite_optional_operation(
    path_item.options,
    base_dir,
    parse_file,
    imports6,
    original_local_names,
  ))
  use #(trace_op, final_imports) <- result.try(rewrite_optional_operation(
    path_item.trace,
    base_dir,
    parse_file,
    imports7,
    original_local_names,
  ))
  Ok(#(
    spec.PathItem(
      ..path_item,
      get: get_op,
      post: post_op,
      put: put_op,
      delete: delete_op,
      patch: patch_op,
      head: head_op,
      options: options_op,
      trace: trace_op,
    ),
    final_imports,
  ))
}

fn rewrite_optional_operation(
  op: option.Option(spec.Operation(Unresolved)),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(
    option.Option(spec.Operation(Unresolved)),
    dict.Dict(String, #(String, SchemaRef)),
  ),
  Diagnostic,
) {
  case op {
    Some(operation) -> {
      use #(new_op, new_imports) <- result.try(rewrite_operation(
        operation,
        base_dir,
        parse_file,
        imports,
        original_local_names,
      ))
      Ok(#(Some(new_op), new_imports))
    }
    None -> Ok(#(None, imports))
  }
}

fn rewrite_operation(
  operation: spec.Operation(Unresolved),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(spec.Operation(Unresolved), dict.Dict(String, #(String, SchemaRef))),
  Diagnostic,
) {
  use #(new_params, imports_after_params) <- result.try(rewrite_parameter_list(
    operation.parameters,
    base_dir,
    parse_file,
    imports,
    original_local_names,
  ))
  use #(new_body, imports_after_body) <- result.try(
    rewrite_optional_request_body(
      operation.request_body,
      base_dir,
      parse_file,
      imports_after_params,
      original_local_names,
    ),
  )
  use #(new_responses, imports_after_responses) <- result.try(
    rewrite_response_map(
      operation.responses,
      base_dir,
      parse_file,
      imports_after_body,
      original_local_names,
    ),
  )
  use #(new_callbacks, final_imports) <- result.try(rewrite_callback_map(
    operation.callbacks,
    base_dir,
    parse_file,
    imports_after_responses,
    original_local_names,
  ))
  Ok(#(
    spec.Operation(
      ..operation,
      callbacks: new_callbacks,
      parameters: new_params,
      request_body: new_body,
      responses: new_responses,
    ),
    final_imports,
  ))
}

/// Walk `operation.callbacks`: for each callback, rewrite every inline
/// PathItem in its `entries` dict via the same `rewrite_path_item`
/// helper used at the top level. `Ref` entries pointing at external
/// PathItem objects pass through unchanged, and now so do top-level
/// `Ref` callback entries (e.g. `myEvent: { $ref: '#/components/callbacks/foo' }`),
/// which we keep as refs rather than inlining.
fn rewrite_callback_map(
  callbacks: dict.Dict(String, spec.RefOr(spec.Callback(Unresolved))),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(
    dict.Dict(String, spec.RefOr(spec.Callback(Unresolved))),
    dict.Dict(String, #(String, SchemaRef)),
  ),
  Diagnostic,
) {
  let entries = dict.to_list(callbacks)
  use #(rewritten, new_imports) <- result.try(
    list.try_fold(entries, #([], imports), fn(acc, entry) {
      let #(collected, imports) = acc
      let #(name, ref_or_callback) = entry
      case ref_or_callback {
        spec.Ref(_) as r -> Ok(#([#(name, r), ..collected], imports))
        spec.Value(callback) -> {
          use #(new_entries, new_imports) <- result.try(
            rewrite_callback_entries(
              callback.entries,
              base_dir,
              parse_file,
              imports,
              original_local_names,
            ),
          )
          let new_callback = spec.Value(spec.Callback(entries: new_entries))
          Ok(#([#(name, new_callback), ..collected], new_imports))
        }
      }
    }),
  )
  let new_callbacks =
    list.fold(rewritten, dict.new(), fn(d, pair) {
      dict.insert(d, pair.0, pair.1)
    })
  Ok(#(new_callbacks, new_imports))
}

/// Rewrite each PathItem inside a Callback.entries dict. The entries
/// map URL-expression strings to `RefOr(PathItem)`; inline PathItems
/// recurse via `rewrite_path_item`, Ref entries pass through.
fn rewrite_callback_entries(
  entries: dict.Dict(String, spec.RefOr(spec.PathItem(Unresolved))),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(
    dict.Dict(String, spec.RefOr(spec.PathItem(Unresolved))),
    dict.Dict(String, #(String, SchemaRef)),
  ),
  Diagnostic,
) {
  let pairs = dict.to_list(entries)
  use #(rewritten, new_imports) <- result.try(
    list.try_fold(pairs, #([], imports), fn(acc, entry) {
      let #(collected, imports) = acc
      let #(url_expr, ref_or_item) = entry
      case ref_or_item {
        spec.Value(path_item) -> {
          use #(new_path_item, new_imports) <- result.try(rewrite_path_item(
            path_item,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          Ok(#(
            [#(url_expr, spec.Value(new_path_item)), ..collected],
            new_imports,
          ))
        }
        spec.Ref(_) -> Ok(#([#(url_expr, ref_or_item), ..collected], imports))
      }
    }),
  )
  let new_map =
    list.fold(rewritten, dict.new(), fn(d, pair) {
      dict.insert(d, pair.0, pair.1)
    })
  Ok(#(new_map, new_imports))
}

fn rewrite_optional_request_body(
  body: option.Option(spec.RefOr(spec.RequestBody(Unresolved))),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(
    option.Option(spec.RefOr(spec.RequestBody(Unresolved))),
    dict.Dict(String, #(String, SchemaRef)),
  ),
  Diagnostic,
) {
  case body {
    Some(spec.Value(rb)) -> {
      use #(new_content, new_imports) <- result.try(rewrite_media_type_map(
        rb.content,
        base_dir,
        parse_file,
        imports,
        original_local_names,
      ))
      let new_rb = spec.RequestBody(..rb, content: new_content)
      Ok(#(Some(spec.Value(new_rb)), new_imports))
    }
    Some(spec.Ref(_)) -> Ok(#(body, imports))
    None -> Ok(#(None, imports))
  }
}

fn rewrite_response_map(
  responses: dict.Dict(
    http.HttpStatusCode,
    spec.RefOr(spec.Response(Unresolved)),
  ),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(
    dict.Dict(http.HttpStatusCode, spec.RefOr(spec.Response(Unresolved))),
    dict.Dict(String, #(String, SchemaRef)),
  ),
  Diagnostic,
) {
  let entries = dict.to_list(responses)
  use #(rewritten, new_imports) <- result.try(
    list.try_fold(entries, #([], imports), fn(acc, entry) {
      let #(collected, imports) = acc
      let #(status, ref_or_resp) = entry
      case ref_or_resp {
        spec.Value(resp) -> {
          use #(new_resp, new_imports) <- result.try(rewrite_response_value(
            resp,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          Ok(#([#(status, spec.Value(new_resp)), ..collected], new_imports))
        }
        spec.Ref(_) -> Ok(#([#(status, ref_or_resp), ..collected], imports))
      }
    }),
  )
  let new_map =
    list.fold(rewritten, dict.new(), fn(d, pair) {
      dict.insert(d, pair.0, pair.1)
    })
  Ok(#(new_map, new_imports))
}

/// Walk `components.parameters`: for each inline `Parameter` whose payload is
/// a `ParameterSchema(SchemaRef)` pointing at a relative-file external ref,
/// hoist the target schema into `components.schemas` and rewrite the inner
/// ref. Parameters expressed via `content` media type maps, `Ref` placeholders
/// pointing at other parameter objects, and local refs all pass through.
fn process_parameter_schemas(
  components: Components(Unresolved),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  original_local_names: List(String),
  seeded_imports: dict.Dict(String, #(String, SchemaRef)),
) -> Result(
  #(Components(Unresolved), dict.Dict(String, #(String, SchemaRef))),
  Diagnostic,
) {
  let entries = dict.to_list(components.parameters)
  use #(rewritten, imports) <- result.try(
    list.try_fold(entries, #([], seeded_imports), fn(acc, entry) {
      let #(collected, imports) = acc
      let #(name, ref_or_param) = entry
      use #(new_param, new_imports) <- result.try(rewrite_ref_or_parameter(
        ref_or_param,
        base_dir,
        parse_file,
        imports,
        original_local_names,
      ))
      Ok(#([#(name, new_param), ..collected], new_imports))
    }),
  )
  let new_parameters =
    list.fold(rewritten, dict.new(), fn(d, pair) {
      dict.insert(d, pair.0, pair.1)
    })
  // Merge any newly-imported schemas into components.schemas that were not
  // already present. Seeded entries carry a placeholder target and are
  // filtered out by matching on `Inline(_)`.
  let new_schemas =
    dict.fold(imports, components.schemas, fn(d, frag_name, pair) {
      let #(_source_path, target_schema) = pair
      case dict.has_key(d, frag_name), target_schema {
        True, _ -> d
        False, Inline(_) -> dict.insert(d, frag_name, target_schema)
        False, _ -> d
      }
    })
  Ok(#(
    Components(..components, parameters: new_parameters, schemas: new_schemas),
    imports,
  ))
}

/// Walk `components.request_bodies` and `components.responses`, hoisting
/// any external `$ref` found on a `MediaType.schema` field inside the
/// `content` dict. The imports tracker is shared with earlier passes so
/// cross-file collisions across every component kind stay honest.
/// Entries whose top-level value is a `Ref(...)` (reference to an
/// external body/response object) pass through untouched — handling those
/// requires hoisting the body/response itself, not just its schema.
fn process_body_response_schemas(
  components: Components(Unresolved),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  original_local_names: List(String),
  seeded_imports: dict.Dict(String, #(String, SchemaRef)),
) -> Result(
  #(Components(Unresolved), dict.Dict(String, #(String, SchemaRef))),
  Diagnostic,
) {
  let body_entries = dict.to_list(components.request_bodies)
  use #(new_bodies, imports_after_bodies) <- result.try(
    list.try_fold(body_entries, #([], seeded_imports), fn(acc, entry) {
      let #(collected, imports) = acc
      let #(name, ref_or_body) = entry
      case ref_or_body {
        spec.Value(body) -> {
          use #(new_content, new_imports) <- result.try(rewrite_media_type_map(
            body.content,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          let new_body = spec.RequestBody(..body, content: new_content)
          Ok(#([#(name, spec.Value(new_body)), ..collected], new_imports))
        }
        spec.Ref(_) -> Ok(#([#(name, ref_or_body), ..collected], imports))
      }
    }),
  )
  let response_entries = dict.to_list(components.responses)
  use #(new_responses, final_imports) <- result.try(
    list.try_fold(response_entries, #([], imports_after_bodies), fn(acc, entry) {
      let #(collected, imports) = acc
      let #(name, ref_or_resp) = entry
      case ref_or_resp {
        spec.Value(resp) -> {
          use #(new_resp, new_imports) <- result.try(rewrite_response_value(
            resp,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          Ok(#([#(name, spec.Value(new_resp)), ..collected], new_imports))
        }
        spec.Ref(_) -> Ok(#([#(name, ref_or_resp), ..collected], imports))
      }
    }),
  )
  let new_request_bodies =
    list.fold(new_bodies, dict.new(), fn(d, pair) {
      dict.insert(d, pair.0, pair.1)
    })
  let new_responses_dict =
    list.fold(new_responses, dict.new(), fn(d, pair) {
      dict.insert(d, pair.0, pair.1)
    })
  let new_schemas =
    dict.fold(final_imports, components.schemas, fn(d, frag_name, pair) {
      let #(_source_path, target_schema) = pair
      case dict.has_key(d, frag_name), target_schema {
        True, _ -> d
        False, Inline(_) -> dict.insert(d, frag_name, target_schema)
        False, _ -> d
      }
    })
  Ok(#(
    Components(
      ..components,
      request_bodies: new_request_bodies,
      responses: new_responses_dict,
      schemas: new_schemas,
    ),
    final_imports,
  ))
}

/// Rewrite a single `RefOr(Parameter)` by hoisting external refs inside
/// either a `ParameterSchema` or a `ParameterContent` payload. `Ref`
/// entries (external parameter-object refs) pass through unchanged.
fn rewrite_ref_or_parameter(
  ref_or_param: spec.RefOr(spec.Parameter(spec.Unresolved)),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(
    spec.RefOr(spec.Parameter(spec.Unresolved)),
    dict.Dict(String, #(String, SchemaRef)),
  ),
  Diagnostic,
) {
  case ref_or_param {
    spec.Value(p) ->
      case p.payload {
        spec.ParameterSchema(schema_ref) -> {
          use #(new_ref, new_imports) <- result.try(maybe_hoist_ref(
            schema_ref,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          let new_param =
            spec.Parameter(..p, payload: spec.ParameterSchema(new_ref))
          Ok(#(spec.Value(new_param), new_imports))
        }
        spec.ParameterContent(content) -> {
          use #(new_content, new_imports) <- result.try(rewrite_media_type_map(
            content,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          let new_param =
            spec.Parameter(..p, payload: spec.ParameterContent(new_content))
          Ok(#(spec.Value(new_param), new_imports))
        }
      }
    spec.Ref(_) -> Ok(#(ref_or_param, imports))
  }
}

/// Rewrite both the `content` media map and the `headers` map of a
/// single Response value. Shared by the components-side and operation-
/// side response walkers so header schemas get the same external-ref
/// treatment as body schemas.
fn rewrite_response_value(
  response: spec.Response(Unresolved),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(spec.Response(Unresolved), dict.Dict(String, #(String, SchemaRef))),
  Diagnostic,
) {
  use #(new_content, imports_after_content) <- result.try(
    rewrite_media_type_map(
      response.content,
      base_dir,
      parse_file,
      imports,
      original_local_names,
    ),
  )
  use #(new_headers, new_imports) <- result.try(rewrite_header_map(
    response.headers,
    base_dir,
    parse_file,
    imports_after_content,
    original_local_names,
  ))
  Ok(#(
    spec.Response(..response, content: new_content, headers: new_headers),
    new_imports,
  ))
}

/// Walk a `Dict(String, Header)` and hoist any external `$ref` found
/// on `Header.schema`. Headers are not `RefOr(Header)`, so no
/// placeholder handling — just iterate the dict and rewrite each
/// entry that has a schema.
fn rewrite_header_map(
  headers: dict.Dict(String, spec.Header),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(dict.Dict(String, spec.Header), dict.Dict(String, #(String, SchemaRef))),
  Diagnostic,
) {
  let entries = dict.to_list(headers)
  use #(rewritten, new_imports) <- result.try(
    list.try_fold(entries, #([], imports), fn(acc, entry) {
      let #(collected, imports) = acc
      let #(name, header) = entry
      case header.schema {
        Some(ref) -> {
          use #(new_ref, new_imports) <- result.try(maybe_hoist_ref(
            ref,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          let new_header = spec.Header(..header, schema: Some(new_ref))
          Ok(#([#(name, new_header), ..collected], new_imports))
        }
        None -> Ok(#([#(name, header), ..collected], imports))
      }
    }),
  )
  let new_map =
    list.fold(rewritten, dict.new(), fn(d, pair) {
      dict.insert(d, pair.0, pair.1)
    })
  Ok(#(new_map, new_imports))
}

/// Walk `components.headers` (plain `Dict(String, Header)`, not
/// `RefOr`) and hoist any external `$ref` found on `Header.schema`.
/// Runs after the other components-side passes so imported schemas
/// continue to flow into `components.schemas`.
fn process_component_headers(
  components: Components(Unresolved),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  original_local_names: List(String),
  seeded_imports: dict.Dict(String, #(String, SchemaRef)),
) -> Result(
  #(Components(Unresolved), dict.Dict(String, #(String, SchemaRef))),
  Diagnostic,
) {
  use #(new_headers, final_imports) <- result.try(rewrite_header_map(
    components.headers,
    base_dir,
    parse_file,
    seeded_imports,
    original_local_names,
  ))
  let new_schemas =
    dict.fold(final_imports, components.schemas, fn(d, frag_name, pair) {
      let #(_source_path, target_schema) = pair
      case dict.has_key(d, frag_name), target_schema {
        True, _ -> d
        False, Inline(_) -> dict.insert(d, frag_name, target_schema)
        False, _ -> d
      }
    })
  Ok(#(
    Components(..components, headers: new_headers, schemas: new_schemas),
    final_imports,
  ))
}

/// Walk `components.path_items`: for each inline `PathItem`, rewrite
/// its parameters, method operations, and callbacks via the shared
/// `rewrite_path_item` helper — the same one used for top-level
/// `spec.paths` and callback PathItems. `Ref` entries pointing at
/// external PathItem objects pass through unchanged.
fn process_component_path_items(
  components: Components(Unresolved),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  original_local_names: List(String),
  seeded_imports: dict.Dict(String, #(String, SchemaRef)),
) -> Result(
  #(Components(Unresolved), dict.Dict(String, #(String, SchemaRef))),
  Diagnostic,
) {
  let entries = dict.to_list(components.path_items)
  use #(rewritten, final_imports) <- result.try(
    list.try_fold(entries, #([], seeded_imports), fn(acc, entry) {
      let #(collected, imports) = acc
      let #(name, ref_or_item) = entry
      case ref_or_item {
        spec.Value(path_item) -> {
          use #(new_path_item, new_imports) <- result.try(rewrite_path_item(
            path_item,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          Ok(#([#(name, spec.Value(new_path_item)), ..collected], new_imports))
        }
        spec.Ref(_) -> Ok(#([#(name, ref_or_item), ..collected], imports))
      }
    }),
  )
  let new_path_items =
    list.fold(rewritten, dict.new(), fn(d, pair) {
      dict.insert(d, pair.0, pair.1)
    })
  let new_schemas =
    dict.fold(final_imports, components.schemas, fn(d, frag_name, pair) {
      let #(_source_path, target_schema) = pair
      case dict.has_key(d, frag_name), target_schema {
        True, _ -> d
        False, Inline(_) -> dict.insert(d, frag_name, target_schema)
        False, _ -> d
      }
    })
  Ok(#(
    Components(..components, path_items: new_path_items, schemas: new_schemas),
    final_imports,
  ))
}

/// Walk every MediaType in a content-type dict and hoist any external ref
/// found on `MediaType.schema`. MediaType values with no schema pass
/// through unchanged.
fn rewrite_media_type_map(
  content: dict.Dict(String, spec.MediaType),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(dict.Dict(String, spec.MediaType), dict.Dict(String, #(String, SchemaRef))),
  Diagnostic,
) {
  let entries = dict.to_list(content)
  use #(rewritten, new_imports) <- result.try(
    list.try_fold(entries, #([], imports), fn(acc, entry) {
      let #(collected, imports) = acc
      let #(media_key, media) = entry
      case media.schema {
        Some(ref) -> {
          use #(new_ref, new_imports) <- result.try(maybe_hoist_ref(
            ref,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          let new_media = spec.MediaType(..media, schema: Some(new_ref))
          Ok(#([#(media_key, new_media), ..collected], new_imports))
        }
        None -> Ok(#([#(media_key, media), ..collected], imports))
      }
    }),
  )
  let new_content =
    list.fold(rewritten, dict.new(), fn(d, pair) {
      dict.insert(d, pair.0, pair.1)
    })
  Ok(#(new_content, new_imports))
}

/// Walk the properties dict of an ObjectSchema; for each property that is a
/// relative-file `$ref`, resolve it, stage the target schema for merging,
/// and rewrite the property to a local ref. Non-external property refs pass
/// through unchanged.
fn rewrite_object_properties(
  properties: dict.Dict(String, SchemaRef),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(dict.Dict(String, SchemaRef), dict.Dict(String, #(String, SchemaRef))),
  Diagnostic,
) {
  let entries = dict.to_list(properties)
  use #(new_entries, new_imports) <- result.try(
    list.try_fold(entries, #([], imports), fn(acc, entry) {
      let #(prop_acc, imports) = acc
      let #(prop_name, prop_ref) = entry
      use #(new_ref, new_imports) <- result.try(maybe_hoist_ref(
        prop_ref,
        base_dir,
        parse_file,
        imports,
        original_local_names,
      ))
      Ok(#([#(prop_name, new_ref), ..prop_acc], new_imports))
    }),
  )
  let new_properties =
    list.fold(new_entries, dict.new(), fn(d, pair) {
      dict.insert(d, pair.0, pair.1)
    })
  Ok(#(new_properties, new_imports))
}

/// Walk an ObjectSchema's `additionalProperties` value; when it is a
/// `Typed(SchemaRef)` whose ref is external, hoist the target schema and
/// rewrite the inner ref to a local reference. `Forbidden` and `Untyped`
/// pass through untouched.
fn rewrite_additional_properties(
  additional: schema.AdditionalProperties,
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(schema.AdditionalProperties, dict.Dict(String, #(String, SchemaRef))),
  Diagnostic,
) {
  case additional {
    schema.Typed(ref) -> {
      use #(new_ref, new_imports) <- result.try(maybe_hoist_ref(
        ref,
        base_dir,
        parse_file,
        imports,
        original_local_names,
      ))
      Ok(#(schema.Typed(new_ref), new_imports))
    }
    _ -> Ok(#(additional, imports))
  }
}

/// Walk a `List(SchemaRef)` produced by an allOf/oneOf/anyOf composition,
/// hoisting any relative-file external ref the same way property values
/// and array items are handled. Branches that are inline or local refs
/// pass through unchanged.
fn rewrite_schema_list(
  branches: List(SchemaRef),
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(
  #(List(SchemaRef), dict.Dict(String, #(String, SchemaRef))),
  Diagnostic,
) {
  use #(rewritten, new_imports) <- result.try(
    list.try_fold(branches, #([], imports), fn(acc, branch) {
      let #(collected, imports) = acc
      use #(new_branch, new_imports) <- result.try(maybe_hoist_ref(
        branch,
        base_dir,
        parse_file,
        imports,
        original_local_names,
      ))
      Ok(#([new_branch, ..collected], new_imports))
    }),
  )
  Ok(#(list.reverse(rewritten), new_imports))
}

/// Core external-ref hoisting step shared by the property-value and
/// array-items resolvers. If `schema_ref` is a relative-file external ref,
/// the referenced schema is staged for merging and the ref is rewritten to
/// a local `#/components/schemas/<fragment>` ref. Otherwise the ref passes
/// through unchanged.
fn maybe_hoist_ref(
  schema_ref: SchemaRef,
  base_dir: String,
  parse_file: fn(String) -> Result(OpenApiSpec(Unresolved), Diagnostic),
  imports: dict.Dict(String, #(String, SchemaRef)),
  original_local_names: List(String),
) -> Result(#(SchemaRef, dict.Dict(String, #(String, SchemaRef))), Diagnostic) {
  case extract_external_ref(schema_ref) {
    Some(#(rel_path, fragment_name)) -> {
      let resolved_path = filepath.join(base_dir, rel_path)
      use _ <- result.try(check_nested_local_collision(
        fragment_name,
        resolved_path,
        original_local_names,
      ))
      use _ <- result.try(check_nested_cross_file_collision(
        fragment_name,
        resolved_path,
        imports,
      ))
      use loaded <- result.try(parse_file(resolved_path))
      use target <- result.try(find_external_schema(
        loaded,
        fragment_name,
        resolved_path,
      ))
      let local_ref =
        Reference(
          ref: "#/components/schemas/" <> fragment_name,
          name: fragment_name,
        )
      let new_imports =
        dict.insert(imports, fragment_name, #(resolved_path, target))
      Ok(#(local_ref, new_imports))
    }
    None -> Ok(#(schema_ref, imports))
  }
}

/// Reject a nested property ref whose fragment name collides with a schema
/// that was authored inline in the main spec. Without this guard the nested
/// import would silently rebind to the local schema — even if its shape is
/// unrelated — because the merged dict already holds that slot.
fn check_nested_local_collision(
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
fn check_nested_cross_file_collision(
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
fn check_local_collision(
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
fn check_cross_file_collision(
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
fn find_schema_follow_alias(
  components: spec.Components(Unresolved),
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
fn local_schema_name_from_ref(ref: String) -> option.Option(String) {
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
pub fn base_dir_of(path: String) -> option.Option(String) {
  case filepath.directory_name(path) {
    "" -> Some(".")
    dir -> Some(dir)
  }
}
