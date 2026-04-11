import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  Inline, ObjectSchema, OneOfSchema, Reference, Typed,
}
import oaspec/openapi/spec.{
  type OpenApiSpec, type PathItem, type RefOr, Components, OpenApiSpec, PathItem,
  Ref, Value,
}
import oaspec/util/http
import oaspec/util/naming

/// Accumulated state during the hoisting traversal.
type HoistState {
  HoistState(
    /// New schemas to add to components.schemas
    new_schemas: Dict(String, SchemaRef),
    /// Set of all existing schema names (original + new) for raw collision checks
    existing_names: Dict(String, Nil),
    /// Set of all generated type names after case normalization
    existing_type_names: Dict(String, Nil),
  )
}

/// Hoist inline complex schemas into components.schemas, replacing them with $ref.
/// This is a pre-processing pass that runs after parsing and before validation.
/// The function is idempotent: running it twice produces the same result.
pub fn hoist(spec: OpenApiSpec(stage)) -> OpenApiSpec(stage) {
  let existing_schemas = case spec.components {
    Some(components) -> components.schemas
    None -> dict.new()
  }
  let existing_names =
    dict.keys(existing_schemas)
    |> list.map(fn(k) { #(k, Nil) })
    |> dict.from_list()
  let existing_type_names =
    dict.keys(existing_schemas)
    |> list.map(fn(k) { #(naming.schema_to_type_name(k), Nil) })
    |> dict.from_list()

  let state =
    HoistState(
      new_schemas: dict.new(),
      existing_names: existing_names,
      existing_type_names: existing_type_names,
    )

  // 1. Hoist within existing component schemas (nested inline objects)
  let #(hoisted_component_schemas, state) =
    hoist_component_schemas(existing_schemas, state)

  // 2. Hoist within all paths/operations
  let #(hoisted_paths, state) = hoist_paths(spec.paths, state)

  // 3. Merge all new schemas into components
  let final_schemas = dict.merge(hoisted_component_schemas, state.new_schemas)
  let components = case spec.components {
    Some(c) -> Some(Components(..c, schemas: final_schemas))
    None ->
      case dict.is_empty(state.new_schemas) {
        True -> None
        False ->
          Some(Components(
            schemas: final_schemas,
            parameters: dict.new(),
            request_bodies: dict.new(),
            responses: dict.new(),
            security_schemes: dict.new(),
            path_items: dict.new(),
            headers: dict.new(),
            examples: dict.new(),
            links: dict.new(),
          ))
      }
  }

  OpenApiSpec(..spec, paths: hoisted_paths, components: components)
}

/// Determine if a SchemaObject is complex and should be hoisted.
fn needs_hoisting(schema_obj: SchemaObject) -> Bool {
  case schema_obj {
    ObjectSchema(..) -> True
    AllOfSchema(..) -> True
    OneOfSchema(..) -> True
    AnyOfSchema(..) -> True
    ArraySchema(items: Inline(inner), ..) -> needs_hoisting(inner)
    _ -> False
  }
}

/// Generate a unique schema name, handling collisions by appending 2, 3, etc.
fn make_unique_name(
  base_name: String,
  state: HoistState,
) -> #(String, HoistState) {
  let type_name = naming.schema_to_type_name(base_name)
  case
    dict.has_key(state.existing_names, base_name)
    || dict.has_key(state.existing_type_names, type_name)
  {
    False -> {
      let state =
        HoistState(
          ..state,
          existing_names: dict.insert(state.existing_names, base_name, Nil),
          existing_type_names: dict.insert(
            state.existing_type_names,
            type_name,
            Nil,
          ),
        )
      #(base_name, state)
    }
    True -> find_unique_name(base_name, 2, state)
  }
}

/// Try incrementing suffixes until a unique name is found.
fn find_unique_name(
  base_name: String,
  suffix: Int,
  state: HoistState,
) -> #(String, HoistState) {
  let candidate = base_name <> int.to_string(suffix)
  let type_name = naming.schema_to_type_name(candidate)
  case
    dict.has_key(state.existing_names, candidate)
    || dict.has_key(state.existing_type_names, type_name)
  {
    False -> {
      let state =
        HoistState(
          ..state,
          existing_names: dict.insert(state.existing_names, candidate, Nil),
          existing_type_names: dict.insert(
            state.existing_type_names,
            type_name,
            Nil,
          ),
        )
      #(candidate, state)
    }
    True -> find_unique_name(base_name, suffix + 1, state)
  }
}

/// Hoist a single SchemaRef if it is inline and complex.
/// Returns the (possibly replaced) SchemaRef and updated state.
fn hoist_schema_ref(
  schema_ref: SchemaRef,
  name_prefix: String,
  name_suffix: String,
  state: HoistState,
) -> #(SchemaRef, HoistState) {
  case schema_ref {
    Reference(..) -> #(schema_ref, state)
    Inline(schema_obj) -> {
      case needs_hoisting(schema_obj) {
        False -> #(schema_ref, state)
        True -> {
          // Recursively hoist nested schemas within this object first (depth-first)
          let base_name =
            naming.to_pascal_case(name_prefix)
            <> naming.to_pascal_case(name_suffix)
          let #(hoisted_obj, state) =
            hoist_within_schema(schema_obj, base_name, state)

          // Generate unique name and insert into new_schemas
          let #(unique_name, state) = make_unique_name(base_name, state)
          let state =
            HoistState(
              ..state,
              new_schemas: dict.insert(
                state.new_schemas,
                unique_name,
                Inline(hoisted_obj),
              ),
            )

          let ref = "#/components/schemas/" <> unique_name
          #(schema.make_reference(ref), state)
        }
      }
    }
  }
}

/// Hoist a single SchemaRef unconditionally if it is inline.
/// Used for oneOf/anyOf variants where codegen requires all variants to be $ref.
fn hoist_schema_ref_always(
  schema_ref: SchemaRef,
  name_prefix: String,
  name_suffix: String,
  state: HoistState,
) -> #(SchemaRef, HoistState) {
  case schema_ref {
    Reference(..) -> #(schema_ref, state)
    Inline(schema_obj) -> {
      let base_name =
        naming.to_pascal_case(name_prefix) <> naming.to_pascal_case(name_suffix)
      let #(hoisted_obj, state) =
        hoist_within_schema(schema_obj, base_name, state)
      let #(unique_name, state) = make_unique_name(base_name, state)
      let state =
        HoistState(
          ..state,
          new_schemas: dict.insert(
            state.new_schemas,
            unique_name,
            Inline(hoisted_obj),
          ),
        )
      let ref = "#/components/schemas/" <> unique_name
      #(schema.make_reference(ref), state)
    }
  }
}

/// Recursively hoist within a SchemaObject's children.
fn hoist_within_schema(
  schema_obj: SchemaObject,
  name_prefix: String,
  state: HoistState,
) -> #(SchemaObject, HoistState) {
  case schema_obj {
    ObjectSchema(properties:, additional_properties:, ..) as obj -> {
      // Hoist each property
      let #(new_props, state) =
        dict.to_list(properties)
        |> list.fold(#(dict.new(), state), fn(acc, entry) {
          let #(props_acc, state) = acc
          let #(prop_name, prop_ref) = entry
          let #(hoisted_ref, state) =
            hoist_schema_ref(prop_ref, name_prefix, prop_name, state)
          #(dict.insert(props_acc, prop_name, hoisted_ref), state)
        })

      // Hoist additional_properties if present
      let #(new_ap, state) = case additional_properties {
        Typed(ap_ref) -> {
          let #(hoisted, state) =
            hoist_schema_ref(ap_ref, name_prefix, "Value", state)
          #(Typed(hoisted), state)
        }
        other -> #(other, state)
      }

      let result =
        ObjectSchema(
          ..obj,
          properties: new_props,
          additional_properties: new_ap,
        )
      #(result, state)
    }

    ArraySchema(items:, ..) as arr -> {
      let #(hoisted_items, state) =
        hoist_schema_ref(items, name_prefix, "Item", state)
      #(ArraySchema(..arr, items: hoisted_items), state)
    }

    OneOfSchema(metadata:, schemas:, discriminator:) -> {
      let #(hoisted_schemas_rev, state) =
        list.index_fold(schemas, #([], state), fn(acc, s_ref, idx) {
          let #(schemas_acc, state) = acc
          let suffix = "Variant" <> int.to_string(idx)
          let #(hoisted, state) =
            hoist_schema_ref_always(s_ref, name_prefix, suffix, state)
          #([hoisted, ..schemas_acc], state)
        })
      #(
        OneOfSchema(
          metadata:,
          schemas: list.reverse(hoisted_schemas_rev),
          discriminator:,
        ),
        state,
      )
    }

    AnyOfSchema(metadata:, schemas:, discriminator:) -> {
      let #(hoisted_schemas_rev, state) =
        list.index_fold(schemas, #([], state), fn(acc, s_ref, idx) {
          let #(schemas_acc, state) = acc
          let suffix = "Variant" <> int.to_string(idx)
          let #(hoisted, state) =
            hoist_schema_ref_always(s_ref, name_prefix, suffix, state)
          #([hoisted, ..schemas_acc], state)
        })
      #(
        AnyOfSchema(
          metadata:,
          schemas: list.reverse(hoisted_schemas_rev),
          discriminator:,
        ),
        state,
      )
    }

    AllOfSchema(metadata:, schemas:) -> {
      let #(hoisted_schemas_rev, state) =
        list.index_fold(schemas, #([], state), fn(acc, s_ref, idx) {
          let #(schemas_acc, state) = acc
          let suffix = "Part" <> int.to_string(idx)
          let #(hoisted, state) =
            hoist_schema_ref(s_ref, name_prefix, suffix, state)
          // Mark hoisted allOf parts as internal so they don't appear
          // in the public generated API (types, decoders, encoders).
          let state = case hoisted {
            Reference(name:, ..) ->
              case dict.get(state.new_schemas, name) {
                Ok(Inline(obj)) ->
                  HoistState(
                    ..state,
                    new_schemas: dict.insert(
                      state.new_schemas,
                      name,
                      Inline(schema.set_internal(obj)),
                    ),
                  )
                _ -> state
              }
            _ -> state
          }
          #([hoisted, ..schemas_acc], state)
        })
      #(
        AllOfSchema(metadata:, schemas: list.reverse(hoisted_schemas_rev)),
        state,
      )
    }

    _ -> #(schema_obj, state)
  }
}

/// Hoist schemas within component schemas.
fn hoist_component_schemas(
  schemas: Dict(String, SchemaRef),
  state: HoistState,
) -> #(Dict(String, SchemaRef), HoistState) {
  dict.to_list(schemas)
  |> list.fold(#(dict.new(), state), fn(acc, entry) {
    let #(result, state) = acc
    let #(name, schema_ref) = entry
    case schema_ref {
      Inline(schema_obj) -> {
        let #(hoisted_obj, state) = hoist_within_schema(schema_obj, name, state)
        #(dict.insert(result, name, Inline(hoisted_obj)), state)
      }
      Reference(..) -> #(dict.insert(result, name, schema_ref), state)
    }
  })
}

/// Walk all paths and operations, hoisting inline schemas.
fn hoist_paths(
  paths: Dict(String, RefOr(PathItem(stage))),
  state: HoistState,
) -> #(Dict(String, RefOr(PathItem(stage))), HoistState) {
  dict.to_list(paths)
  |> list.fold(#(dict.new(), state), fn(acc, entry) {
    let #(result, state) = acc
    let #(path, ref_or_path_item) = entry
    case ref_or_path_item {
      Ref(_) -> #(dict.insert(result, path, ref_or_path_item), state)
      Value(path_item) -> {
        let #(hoisted_item, state) = hoist_path_item(path_item, path, state)
        #(dict.insert(result, path, Value(hoisted_item)), state)
      }
    }
  })
}

/// Hoist schemas within a single PathItem.
fn hoist_path_item(
  path_item: PathItem(stage),
  path: String,
  state: HoistState,
) -> #(PathItem(stage), HoistState) {
  let #(get, state) = hoist_maybe_operation(path_item.get, "get", path, state)
  let #(post, state) =
    hoist_maybe_operation(path_item.post, "post", path, state)
  let #(put, state) = hoist_maybe_operation(path_item.put, "put", path, state)
  let #(delete, state) =
    hoist_maybe_operation(path_item.delete, "delete", path, state)
  let #(patch, state) =
    hoist_maybe_operation(path_item.patch, "patch", path, state)
  let #(head, state) =
    hoist_maybe_operation(path_item.head, "head", path, state)
  let #(options, state) =
    hoist_maybe_operation(path_item.options, "options", path, state)
  let #(trace, state) =
    hoist_maybe_operation(path_item.trace, "trace", path, state)

  let result =
    PathItem(
      ..path_item,
      get:,
      post:,
      put:,
      delete:,
      patch:,
      head:,
      options:,
      trace:,
    )
  #(result, state)
}

/// Hoist schemas in an optional operation.
fn hoist_maybe_operation(
  maybe_op: Option(spec.Operation(stage)),
  method: String,
  path: String,
  state: HoistState,
) -> #(Option(spec.Operation(stage)), HoistState) {
  case maybe_op {
    None -> #(None, state)
    Some(operation) -> {
      let op_id = case operation.operation_id {
        Some(id) -> id
        None ->
          method
          <> "_"
          <> string.replace(path, "/", "_")
          |> string.replace("{", "")
          |> string.replace("}", "")
      }
      let #(hoisted_op, state) = hoist_operation(operation, op_id, state)
      #(Some(hoisted_op), state)
    }
  }
}

/// Hoist schemas within a single Operation.
fn hoist_operation(
  operation: spec.Operation(stage),
  op_id: String,
  state: HoistState,
) -> #(spec.Operation(stage), HoistState) {
  // Hoist parameter schemas (complex object/array params)
  let #(parameters, state) =
    hoist_parameters(operation.parameters, op_id, state)

  // Hoist request body schemas
  let #(request_body, state) = case operation.request_body {
    None -> #(None, state)
    Some(Ref(r)) -> #(Some(Ref(r)), state)
    Some(Value(rb)) -> {
      let #(hoisted_rb, state) = hoist_request_body(rb, op_id, state)
      #(Some(Value(hoisted_rb)), state)
    }
  }

  // Hoist response schemas
  let #(responses, state) = hoist_responses(operation.responses, op_id, state)

  let result =
    spec.Operation(..operation, parameters:, request_body:, responses:)
  #(result, state)
}

/// Hoist complex schemas within operation parameters.
fn hoist_parameters(
  params: List(RefOr(spec.Parameter(stage))),
  op_id: String,
  state: HoistState,
) -> #(List(RefOr(spec.Parameter(stage))), HoistState) {
  list.fold(params, #([], state), fn(acc, ref_or_param) {
    let #(params_acc, state) = acc
    case ref_or_param {
      Ref(_) -> #(list.append(params_acc, [ref_or_param]), state)
      Value(param) -> {
        case param.payload {
          spec.ParameterSchema(schema_ref) -> {
            let suffix = "Param" <> naming.to_pascal_case(param.name)
            let #(hoisted, state) =
              hoist_schema_ref(schema_ref, op_id, suffix, state)
            let new_param =
              spec.Parameter(..param, payload: spec.ParameterSchema(hoisted))
            #(list.append(params_acc, [Value(new_param)]), state)
          }
          spec.ParameterContent(_) -> #(
            list.append(params_acc, [ref_or_param]),
            state,
          )
        }
      }
    }
  })
}

/// Hoist schemas within a RequestBody.
fn hoist_request_body(
  rb: spec.RequestBody(stage),
  op_id: String,
  state: HoistState,
) -> #(spec.RequestBody(stage), HoistState) {
  let #(new_content, state) =
    dict.to_list(rb.content)
    |> list.fold(#(dict.new(), state), fn(acc, entry) {
      let #(result, state) = acc
      let #(media_type_name, media_type) = entry
      case media_type.schema {
        Some(schema_ref) -> {
          let #(hoisted, state) =
            hoist_schema_ref(schema_ref, op_id, "Request", state)
          let mt = spec.MediaType(..media_type, schema: Some(hoisted))
          #(dict.insert(result, media_type_name, mt), state)
        }
        None -> #(dict.insert(result, media_type_name, media_type), state)
      }
    })
  #(spec.RequestBody(..rb, content: new_content), state)
}

/// Hoist schemas within response definitions.
fn hoist_responses(
  responses: Dict(http.HttpStatusCode, RefOr(spec.Response(stage))),
  op_id: String,
  state: HoistState,
) -> #(Dict(http.HttpStatusCode, RefOr(spec.Response(stage))), HoistState) {
  dict.to_list(responses)
  |> list.fold(#(dict.new(), state), fn(acc, entry) {
    let #(result, state) = acc
    let #(status_code, ref_or_response) = entry
    case ref_or_response {
      Ref(_) -> #(dict.insert(result, status_code, ref_or_response), state)
      Value(response) -> {
        let #(new_content, state) =
          dict.to_list(response.content)
          |> list.fold(#(dict.new(), state), fn(ct_acc, ct_entry) {
            let #(ct_result, state) = ct_acc
            let #(media_type_name, media_type) = ct_entry
            case media_type.schema {
              Some(schema_ref) -> {
                let suffix = "Response" <> http.status_code_suffix(status_code)
                let #(hoisted, state) =
                  hoist_schema_ref(schema_ref, op_id, suffix, state)
                let mt = spec.MediaType(..media_type, schema: Some(hoisted))
                #(dict.insert(ct_result, media_type_name, mt), state)
              }
              None -> #(
                dict.insert(ct_result, media_type_name, media_type),
                state,
              )
            }
          })
        let hoisted_response = spec.Response(..response, content: new_content)
        #(dict.insert(result, status_code, Value(hoisted_response)), state)
      }
    }
  })
}
