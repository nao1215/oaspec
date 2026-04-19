import gleam/bool
import gleam/dict
import gleam/option.{None}
import gleam/string
import oaspec/codegen/context
import oaspec/config
import oaspec/openapi/dedup
import oaspec/openapi/hoist
import oaspec/openapi/parser
import oaspec/openapi/resolve
import oaspec/openapi/schema
import oaspec/openapi/spec

/// Create a context from a parsed (unresolved) spec.
pub fn make_ctx_from_spec(spec) -> context.Context {
  let assert Ok(resolved) = resolve.resolve(spec)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  context.new(resolved, cfg)
}

/// Create a fully-resolved context from a fixture file path.
pub fn make_ctx(spec_path: String) -> context.Context {
  let assert Ok(spec) = parser.parse_file(spec_path)
  let assert Ok(resolved) = resolve.resolve(spec)
  let resolved = hoist.hoist(resolved)
  let resolved = dedup.dedup(resolved)
  let cfg =
    config.new(
      input: spec_path,
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  context.new(resolved, cfg)
}

/// Find the byte offset of a substring in a string.
pub fn find_substring_index(
  haystack: String,
  needle: String,
) -> Result(Int, Nil) {
  use <- bool.guard(!string.contains(haystack, needle), Error(Nil))
  let parts = string.split(haystack, needle)
  case parts {
    [before, ..] -> Ok(string.length(before))
    _ -> Error(Nil)
  }
}

/// Create a test parameter with all fields specified.
pub fn make_test_param(
  name: String,
  in_: spec.ParameterIn,
  required: Bool,
  payload: spec.ParameterPayload,
  style: option.Option(spec.ParameterStyle),
  explode: option.Option(Bool),
  allow_reserved: Bool,
) -> spec.Parameter(spec.Resolved) {
  spec.Parameter(
    name: name,
    in_: in_,
    description: None,
    required: required,
    payload: payload,
    style: style,
    explode: explode,
    deprecated: False,
    allow_reserved: allow_reserved,
    examples: dict.new(),
  )
}

pub fn string_schema() -> schema.SchemaObject {
  schema.StringSchema(
    metadata: schema.default_metadata(),
    format: None,
    enum_values: [],
    min_length: None,
    max_length: None,
    pattern: None,
  )
}

pub fn int_schema() -> schema.SchemaObject {
  schema.IntegerSchema(
    metadata: schema.default_metadata(),
    format: None,
    minimum: None,
    maximum: None,
    exclusive_minimum: None,
    exclusive_maximum: None,
    multiple_of: None,
  )
}

pub fn float_schema() -> schema.SchemaObject {
  schema.NumberSchema(
    metadata: schema.default_metadata(),
    format: None,
    minimum: None,
    maximum: None,
    exclusive_minimum: None,
    exclusive_maximum: None,
    multiple_of: None,
  )
}

pub fn bool_schema() -> schema.SchemaObject {
  schema.BooleanSchema(metadata: schema.default_metadata())
}

pub fn simple_param(
  name: String,
  required: Bool,
  schema_obj: schema.SchemaObject,
) -> spec.Parameter(spec.Resolved) {
  make_test_param(
    name,
    spec.InQuery,
    required,
    spec.ParameterSchema(schema.Inline(schema_obj)),
    None,
    None,
    False,
  )
}

/// Create a minimal context with no operations for unit testing.
pub fn make_minimal_ctx() -> context.Context {
  let minimal_spec =
    spec.OpenApiSpec(
      openapi: "3.0.3",
      info: spec.Info(
        title: "Test",
        description: None,
        version: "1.0.0",
        summary: None,
        terms_of_service: None,
        contact: None,
        license: None,
      ),
      paths: dict.new(),
      components: None,
      servers: [],
      security: [],
      webhooks: dict.new(),
      tags: [],
      external_docs: None,
      json_schema_dialect: None,
    )
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  context.new(minimal_spec, cfg)
}
