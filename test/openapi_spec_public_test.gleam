import gleam/dict
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import oaspec/openapi/schema
import oaspec/openapi/spec

pub fn main() {
  gleeunit.main()
}

// Smoke test: the public `oaspec/openapi/spec` module exposes the
// core OpenAPI spec types (#615). Callers must be able to *destructure*
// them — not just read fields — without reaching into `oaspec/internal/*`.
// The assertions below construct each public type with its constructor
// and pattern-match its fields, which fails to compile if either the
// type or the constructor is missing from the public surface.

pub fn openapi_spec_public_module_exposes_core_types_test() {
  // Info: simple metadata record. Building it requires the `Info`
  // constructor to be visible from the public module.
  let info =
    spec.Info(
      title: "smoke",
      description: None,
      version: "1.0.0",
      summary: None,
      terms_of_service: None,
      contact: None,
      license: None,
    )

  // OpenApiSpec: top-level record, phantom-typed by `Unresolved`.
  // Pattern-matching the `info` field exercises both the OpenApiSpec
  // constructor and field access.
  let api: spec.OpenApiSpec(spec.Unresolved) =
    spec.OpenApiSpec(
      openapi: "3.1.0",
      info: info,
      paths: dict.new(),
      components: None,
      servers: [],
      security: [],
      webhooks: dict.new(),
      tags: [],
      external_docs: None,
      json_schema_dialect: None,
    )

  let spec.OpenApiSpec(info: parsed_info, ..) = api
  parsed_info.title
  |> should.equal("smoke")
}

pub fn openapi_spec_public_module_exposes_pathitem_and_operation_test() {
  let op =
    spec.Operation(
      operation_id: Some("getThing"),
      summary: None,
      description: None,
      tags: [],
      parameters: [],
      request_body: None,
      responses: dict.new(),
      deprecated: False,
      security: None,
      callbacks: dict.new(),
      servers: [],
      external_docs: None,
    )

  let path_item: spec.PathItem(spec.Unresolved) =
    spec.PathItem(
      summary: None,
      description: None,
      get: Some(op),
      post: None,
      put: None,
      delete: None,
      patch: None,
      head: None,
      options: None,
      trace: None,
      parameters: [],
      servers: [],
    )

  case path_item.get {
    Some(spec.Operation(operation_id: Some(id), ..)) -> id
    Some(spec.Operation(operation_id: None, ..)) -> "unnamed"
    None -> "missing"
  }
  |> should.equal("getThing")
}

/// Helper: hide the concrete variant behind a function boundary so the
/// caller's `case` is forced to handle both `Ref` and `Value` rather
/// than the compiler narrowing it to the literal constructor.
fn refor_id(is_ref: Bool) -> spec.RefOr(Int) {
  case is_ref {
    True -> spec.Ref("#/components/schemas/Thing")
    False -> spec.Value(42)
  }
}

pub fn openapi_spec_public_module_exposes_refor_test() {
  // RefOr lets callers branch on whether a value is a $ref string or
  // a concrete value. Both variants must be reachable from the public
  // module for runtime introspection to work.
  case refor_id(True) {
    spec.Ref(name) -> name
    spec.Value(_) -> "value"
  }
  |> should.equal("#/components/schemas/Thing")

  case refor_id(False) {
    spec.Ref(_) -> 0
    spec.Value(v) -> v
  }
  |> should.equal(42)
}

pub fn openapi_spec_public_module_exposes_parameter_test() {
  // Build a Parameter using the public surface (constructor + variants
  // for ParameterIn / ParameterPayload). This proves the entire
  // Parameter family is destructurable from outside `internal/`.
  let inline_schema =
    schema.Inline(schema.StringSchema(
      metadata: schema.default_metadata(),
      format: None,
      enum_values: [],
      min_length: None,
      max_length: None,
      pattern: None,
    ))

  let param: spec.Parameter(spec.Unresolved) =
    spec.Parameter(
      name: "id",
      in_: spec.InPath,
      description: None,
      required: True,
      payload: spec.ParameterSchema(inline_schema),
      style: None,
      explode: None,
      deprecated: False,
      allow_reserved: False,
      examples: dict.new(),
    )

  case param.in_ {
    spec.InPath -> "path"
    spec.InQuery -> "query"
    spec.InHeader -> "header"
    spec.InCookie -> "cookie"
  }
  |> should.equal("path")

  case spec.parameter_schema(param) {
    Some(_) -> "ok"
    None -> "missing"
  }
  |> should.equal("ok")
}
