//// Narrow support for external `$ref` values that point at component
//// schemas in a sibling YAML/JSON file — `./other.yaml#/components/schemas/Foo`
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
////
//// Out of scope (see issue #98 parent):
////   - external `$ref` pointing at a parameter / request-body / response
////     object itself (the whole entry rather than its schema)
////   - external refs in operation-level parameters / bodies / responses
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
    Some(components), Some(dir) -> {
      let original_local_names =
        local_schema_names(dict.to_list(components.schemas))
      use #(top_resolved, top_imported) <- result.try(process_components(
        components,
        dir,
        parse_file,
        original_local_names,
      ))
      use #(nested_resolved, nested_imports) <- result.try(
        process_nested_property_refs(
          top_resolved,
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
      use body_resolved <- result.try(process_body_response_schemas(
        param_resolved,
        dir,
        parse_file,
        original_local_names,
        param_imports,
      ))
      Ok(OpenApiSpec(..spec, components: Some(body_resolved)))
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
              Ok(#([#(name, spec.Value(new_param)), ..collected], new_imports))
            }
            spec.ParameterContent(content) -> {
              use #(new_content, new_imports) <- result.try(
                rewrite_media_type_map(
                  content,
                  base_dir,
                  parse_file,
                  imports,
                  original_local_names,
                ),
              )
              let new_param =
                spec.Parameter(..p, payload: spec.ParameterContent(new_content))
              Ok(#([#(name, spec.Value(new_param)), ..collected], new_imports))
            }
          }
        spec.Ref(_) -> Ok(#([#(name, ref_or_param), ..collected], imports))
      }
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
) -> Result(Components(Unresolved), Diagnostic) {
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
          use #(new_content, new_imports) <- result.try(rewrite_media_type_map(
            resp.content,
            base_dir,
            parse_file,
            imports,
            original_local_names,
          ))
          let new_resp = spec.Response(..resp, content: new_content)
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
  Ok(
    Components(
      ..components,
      request_bodies: new_request_bodies,
      responses: new_responses_dict,
      schemas: new_schemas,
    ),
  )
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
  case list.contains(original_local_names, fragment_name) {
    False -> Ok(Nil)
    True ->
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
