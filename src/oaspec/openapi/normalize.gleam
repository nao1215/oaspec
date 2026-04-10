import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import oaspec/openapi/schema.{
  type SchemaMetadata, type SchemaObject, type SchemaRef, AllOfSchema,
  AnyOfSchema, ArraySchema, BooleanSchema, Inline, IntegerSchema, NumberSchema,
  ObjectSchema, OneOfSchema, Reference, SchemaMetadata, StringSchema,
}
import oaspec/openapi/spec.{
  type Callback, type Components, type Header, type MediaType, type OpenApiSpec,
  type Operation, type Parameter, type PathItem, type RequestBody, type Response,
  Callback, Components, ConcreteEntry, Header, MediaType, OpenApiSpec, Operation,
  Parameter, PathItem, RequestBody, Response,
}

/// Normalize an OpenApiSpec after parsing.
/// Converts OAS 3.1 patterns to 3.0-compatible representations:
/// - raw_type with multiple types becomes oneOf
/// - const_value becomes a single-value enum
pub fn normalize(spec: OpenApiSpec) -> OpenApiSpec {
  let components = case spec.components {
    Some(c) -> Some(normalize_components(c))
    None -> None
  }
  let paths =
    dict.map_values(spec.paths, fn(_path, item) { normalize_path_item(item) })
  let webhooks =
    dict.map_values(spec.webhooks, fn(_path, item) { normalize_path_item(item) })
  OpenApiSpec(..spec, components: components, paths: paths, webhooks: webhooks)
}

fn normalize_components(c: Components) -> Components {
  let schemas =
    dict.map_values(c.schemas, fn(_k, v) { normalize_schema_ref(v) })
  let parameters =
    dict.map_values(c.parameters, fn(_k, entry) {
      case entry {
        ConcreteEntry(p) -> ConcreteEntry(normalize_parameter(p))
        other -> other
      }
    })
  let request_bodies =
    dict.map_values(c.request_bodies, fn(_k, entry) {
      case entry {
        ConcreteEntry(rb) -> ConcreteEntry(normalize_request_body(rb))
        other -> other
      }
    })
  let responses =
    dict.map_values(c.responses, fn(_k, entry) {
      case entry {
        ConcreteEntry(r) -> ConcreteEntry(normalize_response(r))
        other -> other
      }
    })
  let path_items =
    dict.map_values(c.path_items, fn(_k, entry) {
      case entry {
        ConcreteEntry(pi) -> ConcreteEntry(normalize_path_item(pi))
        other -> other
      }
    })
  let headers = dict.map_values(c.headers, fn(_k, h) { normalize_header(h) })
  Components(
    ..c,
    schemas: schemas,
    parameters: parameters,
    request_bodies: request_bodies,
    responses: responses,
    path_items: path_items,
    headers: headers,
  )
}

fn normalize_path_item(item: PathItem) -> PathItem {
  PathItem(
    ..item,
    get: option.map(item.get, normalize_operation),
    post: option.map(item.post, normalize_operation),
    put: option.map(item.put, normalize_operation),
    delete: option.map(item.delete, normalize_operation),
    patch: option.map(item.patch, normalize_operation),
    head: option.map(item.head, normalize_operation),
    options: option.map(item.options, normalize_operation),
    trace: option.map(item.trace, normalize_operation),
    parameters: list.map(item.parameters, normalize_parameter),
  )
}

fn normalize_operation(op: Operation) -> Operation {
  Operation(
    ..op,
    parameters: list.map(op.parameters, normalize_parameter),
    request_body: option.map(op.request_body, normalize_request_body),
    responses: dict.map_values(op.responses, fn(_k, r) { normalize_response(r) }),
    callbacks: dict.map_values(op.callbacks, fn(_k, cb) {
      normalize_callback(cb)
    }),
  )
}

fn normalize_callback(cb: Callback) -> Callback {
  Callback(
    entries: dict.map_values(cb.entries, fn(_k, item) {
      normalize_path_item(item)
    }),
  )
}

fn normalize_parameter(p: Parameter) -> Parameter {
  Parameter(
    ..p,
    schema: option.map(p.schema, normalize_schema_ref),
    content: dict.map_values(p.content, fn(_k, mt) { normalize_media_type(mt) }),
  )
}

fn normalize_request_body(rb: RequestBody) -> RequestBody {
  RequestBody(
    ..rb,
    content: dict.map_values(rb.content, fn(_k, mt) { normalize_media_type(mt) }),
  )
}

fn normalize_response(r: Response) -> Response {
  Response(
    ..r,
    content: dict.map_values(r.content, fn(_k, mt) { normalize_media_type(mt) }),
    headers: dict.map_values(r.headers, fn(_k, h) { normalize_header(h) }),
  )
}

fn normalize_header(h: Header) -> Header {
  Header(..h, schema: option.map(h.schema, normalize_schema_ref))
}

fn normalize_media_type(mt: MediaType) -> MediaType {
  MediaType(..mt, schema: option.map(mt.schema, normalize_schema_ref))
}

fn normalize_schema_ref(ref: SchemaRef) -> SchemaRef {
  case ref {
    Inline(s) -> Inline(normalize_schema(s))
    Reference(..) -> ref
  }
}

fn normalize_schema(s: SchemaObject) -> SchemaObject {
  // 1. const_value -> single-value enum
  let s = case s {
    StringSchema(metadata: m, ..) ->
      case m.const_value {
        Some(const_val) ->
          StringSchema(
            ..s,
            enum_values: [const_val],
            metadata: SchemaMetadata(..m, const_value: None),
          )
        None -> s
      }
    _ ->
      case schema.get_metadata(s).const_value {
        Some(val) -> {
          let m = schema.get_metadata(s)
          StringSchema(
            metadata: SchemaMetadata(..m, const_value: None),
            format: None,
            enum_values: [val],
            min_length: None,
            max_length: None,
            pattern: None,
          )
        }
        None -> s
      }
  }

  // 2. raw_type with multiple types -> oneOf
  let s = case schema.get_metadata(s).raw_type {
    Some(types) ->
      case list.length(types) > 1 {
        True -> {
          let m = schema.get_metadata(s)
          let type_schemas =
            list.map(types, fn(t) {
              Inline(make_typed_schema(
                t,
                SchemaMetadata(
                  ..schema.default_metadata(),
                  nullable: m.nullable,
                ),
              ))
            })
          OneOfSchema(
            metadata: SchemaMetadata(..m, raw_type: None),
            schemas: type_schemas,
            discriminator: None,
          )
        }
        False -> s
      }
    None -> s
  }

  // 3. Recurse into sub-schemas
  normalize_schema_children(s)
}

fn make_typed_schema(type_str: String, metadata: SchemaMetadata) -> SchemaObject {
  case type_str {
    "string" ->
      StringSchema(
        metadata: metadata,
        format: None,
        enum_values: [],
        min_length: None,
        max_length: None,
        pattern: None,
      )
    "integer" ->
      IntegerSchema(
        metadata: metadata,
        format: None,
        minimum: None,
        maximum: None,
        exclusive_minimum: None,
        exclusive_maximum: None,
        multiple_of: None,
      )
    "number" ->
      NumberSchema(
        metadata: metadata,
        format: None,
        minimum: None,
        maximum: None,
        exclusive_minimum: None,
        exclusive_maximum: None,
        multiple_of: None,
      )
    "boolean" -> BooleanSchema(metadata: metadata)
    _ ->
      ObjectSchema(
        metadata: metadata,
        properties: dict.new(),
        required: [],
        additional_properties: None,
        additional_properties_untyped: False,
        min_properties: None,
        max_properties: None,
      )
  }
}

fn normalize_schema_children(s: SchemaObject) -> SchemaObject {
  case s {
    ObjectSchema(
      metadata:,
      properties:,
      required:,
      additional_properties:,
      additional_properties_untyped:,
      min_properties:,
      max_properties:,
    ) -> {
      let properties =
        dict.map_values(properties, fn(_k, v) { normalize_schema_ref(v) })
      let additional_properties =
        option.map(additional_properties, normalize_schema_ref)
      ObjectSchema(
        metadata:,
        properties:,
        required:,
        additional_properties:,
        additional_properties_untyped:,
        min_properties:,
        max_properties:,
      )
    }
    ArraySchema(metadata:, items:, min_items:, max_items:, unique_items:) ->
      ArraySchema(
        metadata:,
        items: normalize_schema_ref(items),
        min_items:,
        max_items:,
        unique_items:,
      )
    AllOfSchema(metadata:, schemas:) ->
      AllOfSchema(metadata:, schemas: list.map(schemas, normalize_schema_ref))
    OneOfSchema(metadata:, schemas:, discriminator:) ->
      OneOfSchema(
        metadata:,
        schemas: list.map(schemas, normalize_schema_ref),
        discriminator:,
      )
    AnyOfSchema(metadata:, schemas:, discriminator:) ->
      AnyOfSchema(
        metadata:,
        schemas: list.map(schemas, normalize_schema_ref),
        discriminator:,
      )
    _ -> s
  }
}
