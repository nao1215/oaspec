//// Component schema reachability pruning for the OpenAPI generation
//// pipeline (Issue #501).
////
//// `filter.apply` drops operations the user does not want, but it
//// leaves `spec.components.schemas` untouched on purpose so that
//// component pruning can be a separate, audit-able stage. Without that
//// prune the type / encoder / decoder / guard generators iterate over
//// every component the spec declares — a one-path filter against
//// GitHub's REST OpenAPI still emits megabytes of generated code.
////
//// `prune/1` walks every schema reachable from the surviving
//// operations (and from webhooks, which the include filter never
//// touches) and keeps only those entries in `components.schemas`. It
//// is intended to run after `hoist.hoist` (so synthetic schemas
//// hoisting introduces are considered) and before `dedup.dedup` (so
//// dedup operates on the smaller surviving set).
////
//// The walker recurses through every schema reference path the
//// codebase models — `properties`, `items`, `additionalProperties`,
//// `allOf` / `oneOf` / `anyOf` — plus `discriminator.mapping` values,
//// which name component schemas by string and would otherwise be
//// invisible to a structural walk.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import oaspec/internal/openapi/schema.{
  type Discriminator, type SchemaObject, type SchemaRef, AllOfSchema,
  AnyOfSchema, ArraySchema, Forbidden, Inline, ObjectSchema, OneOfSchema,
  Reference, Typed, Unspecified, Untyped,
}
import oaspec/internal/openapi/spec.{
  type Callback, type MediaType, type OpenApiSpec, type Operation,
  type Parameter, type PathItem, type RefOr, type Resolved, type Response,
  Callback, Components, OpenApiSpec, ParameterContent, ParameterSchema, Ref,
  Value,
}

/// Set of reachable component schema names. Implemented as `Dict(_, Nil)`
/// because Gleam's stdlib does not ship a Set; only `dict.has_key` and
/// `dict.insert` are needed.
type Reached =
  Dict(String, Nil)

/// Prune unreachable component schemas from a Resolved spec.
///
/// Reachability is computed from operations surviving any earlier
/// `filter.apply` pass plus webhooks (which the include filter never
/// touches). When `spec.components` is `None`, the function is a no-op.
pub fn prune(spec: OpenApiSpec(Resolved)) -> OpenApiSpec(Resolved) {
  case spec.components {
    None -> spec
    Some(components) -> {
      let seeds = collect_seed_refs(spec)
      let reached = walk(seeds, dict.new(), components.schemas)
      let pruned_schemas =
        components.schemas
        |> dict.to_list
        |> list.filter(fn(entry) { dict.has_key(reached, entry.0) })
        |> dict.from_list
      OpenApiSpec(
        ..spec,
        components: Some(Components(..components, schemas: pruned_schemas)),
      )
    }
  }
}

/// Gather every SchemaRef syntactically reachable from operations and
/// webhooks. Order does not matter — `walk/3` deduplicates via the
/// `Reached` set.
fn collect_seed_refs(spec: OpenApiSpec(Resolved)) -> List(SchemaRef) {
  let path_refs =
    dict.values(spec.paths)
    |> list.flat_map(refs_from_path_ref)
  let webhook_refs =
    dict.values(spec.webhooks)
    |> list.flat_map(refs_from_path_ref)
  list.flatten([path_refs, webhook_refs])
}

fn refs_from_path_ref(path_ref: RefOr(PathItem(Resolved))) -> List(SchemaRef) {
  case path_ref {
    Value(item) -> refs_from_path_item(item)
    Ref(_) -> []
  }
}

fn refs_from_path_item(item: PathItem(Resolved)) -> List(SchemaRef) {
  let path_param_refs = list.flat_map(item.parameters, refs_from_parameter_ref)
  let op_refs =
    [
      item.get,
      item.post,
      item.put,
      item.delete,
      item.patch,
      item.head,
      item.options,
      item.trace,
    ]
    |> list.filter_map(option_to_result)
    |> list.flat_map(refs_from_operation)
  list.flatten([path_param_refs, op_refs])
}

fn option_to_result(opt: Option(a)) -> Result(a, Nil) {
  case opt {
    Some(v) -> Ok(v)
    None -> Error(Nil)
  }
}

fn refs_from_operation(op: Operation(Resolved)) -> List(SchemaRef) {
  let parameter_refs = list.flat_map(op.parameters, refs_from_parameter_ref)
  let body_refs = case op.request_body {
    Some(Value(rb)) -> refs_from_media_dict(rb.content)
    Some(Ref(_)) -> []
    None -> []
  }
  let response_refs =
    dict.values(op.responses)
    |> list.flat_map(fn(rr) {
      case rr {
        Value(r) -> refs_from_response(r)
        Ref(_) -> []
      }
    })
  let callback_refs =
    dict.values(op.callbacks)
    |> list.flat_map(refs_from_callback_ref)
  list.flatten([parameter_refs, body_refs, response_refs, callback_refs])
}

fn refs_from_callback_ref(cb_ref: RefOr(Callback(Resolved))) -> List(SchemaRef) {
  case cb_ref {
    Value(Callback(entries:)) ->
      dict.values(entries)
      |> list.flat_map(refs_from_path_ref)
    Ref(_) -> []
  }
}

fn refs_from_parameter_ref(pref: RefOr(Parameter(Resolved))) -> List(SchemaRef) {
  case pref {
    Value(p) ->
      case p.payload {
        ParameterSchema(s) -> [s]
        ParameterContent(content) -> refs_from_media_dict(content)
      }
    Ref(_) -> []
  }
}

fn refs_from_response(r: Response(Resolved)) -> List(SchemaRef) {
  let content_refs = refs_from_media_dict(r.content)
  let header_refs =
    dict.values(r.headers)
    |> list.filter_map(fn(h) { option_to_result(h.schema) })
  list.flatten([content_refs, header_refs])
}

fn refs_from_media_dict(content: Dict(String, MediaType)) -> List(SchemaRef) {
  dict.values(content)
  |> list.filter_map(fn(mt) { option_to_result(mt.schema) })
}

/// BFS walk: pop refs from the worklist, mark each named component
/// reachable, and follow inline structure into nested refs. Avoids
/// infinite recursion via the `reached` set.
fn walk(
  worklist: List(SchemaRef),
  reached: Reached,
  schemas: Dict(String, SchemaRef),
) -> Reached {
  case worklist {
    [] -> reached
    [ref, ..rest] ->
      case ref {
        Reference(_, name) ->
          case dict.has_key(reached, name) {
            True -> walk(rest, reached, schemas)
            False -> {
              let reached = dict.insert(reached, name, Nil)
              case dict.get(schemas, name) {
                Ok(target) -> walk([target, ..rest], reached, schemas)
                // The reference names a schema not present in
                // `components.schemas`. resolve.gleam normally fails
                // earlier on dangling refs, but discriminator mappings
                // can also produce names that point at synthetic
                // hoisted entries; keep the worklist moving without
                // surfacing a fake error here.
                Error(Nil) -> walk(rest, reached, schemas)
              }
            }
          }
        Inline(obj) -> {
          let children = refs_from_schema_object(obj)
          walk(list.append(children, rest), reached, schemas)
        }
      }
  }
}

/// Return every SchemaRef that `schema` syntactically references.
/// `discriminator.mapping` values are translated into `Reference`s via
/// `schema.make_reference` so the worklist can follow them.
fn refs_from_schema_object(schema: SchemaObject) -> List(SchemaRef) {
  case schema {
    ObjectSchema(properties:, additional_properties:, ..) -> {
      let prop_refs = dict.values(properties)
      let ap_refs = case additional_properties {
        Typed(s) -> [s]
        Forbidden | Untyped | Unspecified -> []
      }
      list.flatten([prop_refs, ap_refs])
    }
    ArraySchema(items:, ..) -> [items]
    AllOfSchema(schemas:, ..) -> schemas
    OneOfSchema(schemas:, discriminator:, ..) ->
      list.flatten([schemas, discriminator_mapping_refs(discriminator)])
    AnyOfSchema(schemas:, discriminator:, ..) ->
      list.flatten([schemas, discriminator_mapping_refs(discriminator)])
    _ -> []
  }
}

/// Translate a discriminator's mapping (schema name strings) into
/// SchemaRefs so the worklist can follow them. Mapping values are
/// allowed to be either `#/components/schemas/Name` or bare `Name`;
/// `schema.make_reference/1` handles both forms.
fn discriminator_mapping_refs(
  discriminator: Option(Discriminator),
) -> List(SchemaRef) {
  case discriminator {
    Some(d) ->
      dict.values(d.mapping)
      |> list.map(schema.make_reference)
    None -> []
  }
}
