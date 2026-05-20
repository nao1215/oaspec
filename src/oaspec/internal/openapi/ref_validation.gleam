//// Schema-level `$ref` existence and cycle validation for resolved specs.
////
//// The component-level `resolve.resolve` pass already promotes `RefOr`
//// aliases inside components / paths / operations and rejects unresolved
//// or cyclic component-level aliases. It does NOT, however, walk into
//// `SchemaRef.Reference` values stored inside schema trees — a response
//// body whose `schema: { $ref: '#/components/schemas/Nonexistent' }`
//// passes `resolve.resolve` unchanged. This module fills that gap so the
//// new `parser.parse_string_resolved` entry point can surface the same
//// diagnostics that codegen-side validation would, without dragging in
//// a `Config` / `Context`. (#616)

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set.{type Set}
import oaspec/openapi/diagnostic.{type Diagnostic, NoSourceLoc}
import oaspec/openapi/schema.{
  type AdditionalProperties, type SchemaObject, type SchemaRef, AllOfSchema,
  AnyOfSchema, ArraySchema, Forbidden, Inline, ObjectSchema, OneOfSchema,
  Reference, Typed, Unspecified, Untyped,
}
import oaspec/openapi/spec.{
  type Header, type MediaType, type OpenApiSpec, type Operation, type Parameter,
  type PathItem, type RefOr, type RequestBody, type Resolved, type Response,
  ParameterContent, ParameterSchema, Ref, Value,
}

/// Walk every `SchemaRef` reachable from `spec` and verify each
/// `Reference` resolves to a concrete schema in `components.schemas`
/// (catching missing references) and that the chain does not loop
/// (catching circular references — including cycles that travel
/// through inline-object properties, array items, and composition
/// branches). Returns the accumulated diagnostics, or `Ok(Nil)` if
/// every reference is well-formed.
///
/// The walker covers the surfaces a real spec uses today:
///
///   - `components.schemas`
///   - `paths` / `webhooks` path items → operation parameters,
///     request bodies, responses, callbacks
///   - parameter schemas (including `parameters.content.<media>.schema`)
///   - response media-type schemas, response header schemas
///   - request body media-type schemas
///   - nested `ObjectSchema.properties`,
///     `ObjectSchema.additional_properties` (when `Typed`),
///     `ArraySchema.items`, `AllOfSchema.schemas`,
///     `OneOfSchema.schemas`, `AnyOfSchema.schemas`
pub fn validate_schema_refs(
  spec: OpenApiSpec(Resolved),
) -> Result(Nil, List(Diagnostic)) {
  let diags =
    list.flatten([
      validate_components_schemas(spec),
      validate_paths(spec.paths, "paths", spec),
      validate_paths(spec.webhooks, "webhooks", spec),
    ])
  case diags {
    [] -> Ok(Nil)
    _ -> Error(diags)
  }
}

fn validate_components_schemas(spec: OpenApiSpec(Resolved)) -> List(Diagnostic) {
  case spec.components {
    None -> []
    Some(components) ->
      dict.to_list(components.schemas)
      |> list.flat_map(fn(entry) {
        let #(name, schema_ref) = entry
        validate_schema_ref(
          "components.schemas." <> name,
          schema_ref,
          spec,
          set.new(),
        )
      })
  }
}

fn validate_paths(
  paths: dict.Dict(String, RefOr(PathItem(Resolved))),
  prefix: String,
  spec: OpenApiSpec(Resolved),
) -> List(Diagnostic) {
  dict.to_list(paths)
  |> list.flat_map(fn(entry) {
    let #(path, ref_or) = entry
    let context = prefix <> "." <> path
    case ref_or {
      // After `resolve.resolve`, path-level `Ref` entries pointing at
      // `components.pathItems` have been left as `Ref(_)` (resolve only
      // verifies the target exists) — there is no schema-ref surface
      // attached to a `Ref(_)` path entry itself, so we have nothing to
      // walk here.
      Ref(_) -> []
      Value(pi) -> validate_path_item(pi, context, spec)
    }
  })
}

fn validate_path_item(
  pi: PathItem(Resolved),
  context: String,
  spec: OpenApiSpec(Resolved),
) -> List(Diagnostic) {
  let operations =
    [
      #("get", pi.get),
      #("post", pi.post),
      #("put", pi.put),
      #("delete", pi.delete),
      #("patch", pi.patch),
      #("head", pi.head),
      #("options", pi.options),
      #("trace", pi.trace),
    ]
    |> list.filter_map(fn(pair) {
      let #(method, op) = pair
      case op {
        Some(o) -> Ok(#(method, o))
        None -> Error(Nil)
      }
    })
  let op_diags =
    list.flat_map(operations, fn(pair) {
      let #(method, op) = pair
      validate_operation(op, context <> "." <> method, spec)
    })
  let path_param_diags =
    validate_parameters(pi.parameters, context <> ".parameters", spec)
  list.append(path_param_diags, op_diags)
}

fn validate_operation(
  op: Operation(Resolved),
  context: String,
  spec: OpenApiSpec(Resolved),
) -> List(Diagnostic) {
  let param_diags =
    validate_parameters(op.parameters, context <> ".parameters", spec)
  let request_body_diags = case op.request_body {
    None -> []
    Some(rb) -> validate_request_body_refor(rb, context <> ".requestBody", spec)
  }
  let response_diags =
    dict.to_list(op.responses)
    |> list.flat_map(fn(entry) {
      let #(_status, response_refor) = entry
      validate_response_refor(response_refor, context <> ".responses", spec)
    })
  let callback_diags =
    dict.to_list(op.callbacks)
    |> list.flat_map(fn(entry) {
      let #(name, cb_refor) = entry
      let callback_path = context <> ".callbacks." <> name
      case cb_refor {
        // Callback `$ref` chains are validated by `resolve.resolve` —
        // nothing schema-shaped to walk here.
        Ref(_) -> []
        Value(callback) ->
          dict.to_list(callback.entries)
          |> list.flat_map(fn(cb_entry) {
            let #(url, pi_refor) = cb_entry
            let cb_path = callback_path <> "." <> url
            case pi_refor {
              Ref(_) -> []
              Value(pi) -> validate_path_item(pi, cb_path, spec)
            }
          })
      }
    })
  list.flatten([param_diags, request_body_diags, response_diags, callback_diags])
}

fn validate_parameters(
  parameters: List(RefOr(Parameter(Resolved))),
  context: String,
  spec: OpenApiSpec(Resolved),
) -> List(Diagnostic) {
  list.flat_map(parameters, fn(p) {
    case p {
      Ref(_) -> []
      Value(param) -> validate_parameter(param, context, spec)
    }
  })
}

fn validate_parameter(
  param: Parameter(Resolved),
  context: String,
  spec: OpenApiSpec(Resolved),
) -> List(Diagnostic) {
  let param_path = context <> "." <> param.name
  case param.payload {
    ParameterSchema(schema_ref) ->
      validate_schema_ref(param_path <> ".schema", schema_ref, spec, set.new())
    ParameterContent(content) ->
      validate_media_type_map(content, param_path <> ".content", spec)
  }
}

fn validate_request_body_refor(
  rb_refor: RefOr(RequestBody(Resolved)),
  context: String,
  spec: OpenApiSpec(Resolved),
) -> List(Diagnostic) {
  case rb_refor {
    Ref(_) -> []
    Value(rb) ->
      validate_media_type_map(rb.content, context <> ".content", spec)
  }
}

fn validate_response_refor(
  response_refor: RefOr(Response(Resolved)),
  context: String,
  spec: OpenApiSpec(Resolved),
) -> List(Diagnostic) {
  case response_refor {
    Ref(_) -> []
    Value(response) -> validate_response(response, context, spec)
  }
}

fn validate_response(
  response: Response(Resolved),
  context: String,
  spec: OpenApiSpec(Resolved),
) -> List(Diagnostic) {
  let content_diags =
    validate_media_type_map(response.content, context <> ".content", spec)
  let header_diags =
    dict.to_list(response.headers)
    |> list.flat_map(fn(entry) {
      let #(name, header) = entry
      validate_header(header, context <> ".headers." <> name, spec)
    })
  list.append(content_diags, header_diags)
}

fn validate_header(
  header: Header,
  context: String,
  spec: OpenApiSpec(Resolved),
) -> List(Diagnostic) {
  case header.schema {
    None -> []
    Some(schema_ref) ->
      validate_schema_ref(context <> ".schema", schema_ref, spec, set.new())
  }
}

fn validate_media_type_map(
  media_types: dict.Dict(String, MediaType),
  context: String,
  spec: OpenApiSpec(Resolved),
) -> List(Diagnostic) {
  dict.to_list(media_types)
  |> list.flat_map(fn(entry) {
    let #(media_type_name, media_type) = entry
    let mt_path = context <> "." <> media_type_name
    case media_type.schema {
      None -> []
      Some(schema_ref) ->
        validate_schema_ref(mt_path <> ".schema", schema_ref, spec, set.new())
    }
  })
}

/// Resolve `schema_ref` and surface a diagnostic if the target is
/// missing or its expansion forms a cycle. `expanding` is the set of
/// component-schema names currently on the expansion stack — re-entering
/// any of them while walking an inline body counts as a cycle, which
/// catches `A.properties.next.$ref: A`–style loops that the pure
/// `resolver.resolve_schema_ref` chain walker misses (it only follows
/// `Reference -> Reference` aliases, not references that travel through
/// inline composite schemas). (#616)
fn validate_schema_ref(
  path: String,
  schema_ref: SchemaRef,
  spec: OpenApiSpec(Resolved),
  expanding: Set(String),
) -> List(Diagnostic) {
  case schema_ref {
    Inline(schema_obj) ->
      validate_inline_schema(path, schema_obj, spec, expanding)
    Reference(ref:, name:) ->
      case set.contains(expanding, name) {
        True -> [
          diagnostic.resolve_error(
            path: path,
            detail: "Circular schema reference detected at '"
              <> ref
              <> "'. The $ref chain re-enters '"
              <> name
              <> "' before reaching a concrete schema.",
            hint: Some(
              "Break the cycle by replacing one $ref in the chain with an inline schema or restructuring the components.",
            ),
            loc: NoSourceLoc,
          ),
        ]
        False ->
          case lookup_component_schema(spec, name) {
            Error(Nil) -> [
              diagnostic.resolve_error(
                path: path,
                detail: "Unresolved schema reference: '"
                  <> ref
                  <> "'. The referenced schema does not exist in components.schemas.",
                hint: Some(
                  "Verify the schema is defined in components.schemas and the $ref path is spelled correctly.",
                ),
                loc: NoSourceLoc,
              ),
            ]
            Ok(target) ->
              validate_schema_ref(
                path,
                target,
                spec,
                set.insert(expanding, name),
              )
          }
      }
  }
}

fn lookup_component_schema(
  spec: OpenApiSpec(Resolved),
  name: String,
) -> Result(SchemaRef, Nil) {
  case spec.components {
    None -> Error(Nil)
    Some(components) -> dict.get(components.schemas, name)
  }
}

fn validate_inline_schema(
  path: String,
  schema_obj: SchemaObject,
  spec: OpenApiSpec(Resolved),
  expanding: Set(String),
) -> List(Diagnostic) {
  case schema_obj {
    ObjectSchema(properties:, additional_properties:, ..) -> {
      let prop_diags =
        dict.to_list(properties)
        |> list.flat_map(fn(entry) {
          let #(prop_name, prop_ref) = entry
          validate_schema_ref(
            path <> "." <> prop_name,
            prop_ref,
            spec,
            expanding,
          )
        })
      let ap_diags =
        validate_additional_properties(
          additional_properties,
          path <> ".additionalProperties",
          spec,
          expanding,
        )
      list.append(prop_diags, ap_diags)
    }
    ArraySchema(items:, ..) ->
      validate_schema_ref(path <> ".items", items, spec, expanding)
    AllOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s) {
        validate_schema_ref(path <> ".allOf", s, spec, expanding)
      })
    OneOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s) {
        validate_schema_ref(path <> ".oneOf", s, spec, expanding)
      })
    AnyOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s) {
        validate_schema_ref(path <> ".anyOf", s, spec, expanding)
      })
    // Leaf scalar schemas hold no nested refs.
    _ -> []
  }
}

fn validate_additional_properties(
  ap: AdditionalProperties,
  path: String,
  spec: OpenApiSpec(Resolved),
  expanding: Set(String),
) -> List(Diagnostic) {
  case ap {
    Typed(ref) -> validate_schema_ref(path, ref, spec, expanding)
    Forbidden | Untyped | Unspecified -> []
  }
}
