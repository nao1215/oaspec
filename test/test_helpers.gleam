import gleam/bool
import gleam/dict
import gleam/option.{None}
import gleam/string
import oaspec/config
import oaspec/internal/codegen/context
import oaspec/internal/openapi/dedup
import oaspec/internal/openapi/hoist
import oaspec/internal/openapi/resolve
import oaspec/internal/openapi/schema
import oaspec/openapi
import oaspec/openapi/parser

/// Create a context from a parsed (unresolved) spec.
pub fn make_ctx_from_spec(spec) -> context.Context {
  let assert Ok(resolved) = resolve.resolve(spec)
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
      include: config.Include(tags: [], paths: []),
      handler_layout: config.SingleFile,
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
    config.Config(
      input: spec_path,
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
      include: config.Include(tags: [], paths: []),
      handler_layout: config.SingleFile,
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
  in_: openapi.ParameterIn,
  required: Bool,
  payload: openapi.ParameterPayload,
  style: option.Option(openapi.ParameterStyle),
  explode: option.Option(Bool),
  allow_reserved: Bool,
) -> openapi.Parameter(openapi.Resolved) {
  openapi.Parameter(
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

pub fn string_schema() -> openapi.SchemaObject {
  openapi.StringSchema(
    metadata: schema.default_metadata(),
    format: None,
    enum_values: [],
    min_length: None,
    max_length: None,
    pattern: None,
  )
}

pub fn int_schema() -> openapi.SchemaObject {
  openapi.IntegerSchema(
    metadata: schema.default_metadata(),
    format: None,
    minimum: None,
    maximum: None,
    exclusive_minimum: None,
    exclusive_maximum: None,
    multiple_of: None,
  )
}

pub fn float_schema() -> openapi.SchemaObject {
  openapi.NumberSchema(
    metadata: schema.default_metadata(),
    format: None,
    minimum: None,
    maximum: None,
    exclusive_minimum: None,
    exclusive_maximum: None,
    multiple_of: None,
  )
}

pub fn bool_schema() -> openapi.SchemaObject {
  openapi.BooleanSchema(metadata: schema.default_metadata())
}

pub fn simple_param(
  name: String,
  required: Bool,
  schema_obj: openapi.SchemaObject,
) -> openapi.Parameter(openapi.Resolved) {
  make_test_param(
    name,
    openapi.InQuery,
    required,
    openapi.ParameterSchema(openapi.Inline(schema_obj)),
    None,
    None,
    False,
  )
}

/// Create a minimal context with no operations for unit testing.
pub fn make_minimal_ctx() -> context.Context {
  let minimal_spec =
    openapi.OpenApiSpec(
      openapi: "3.0.3",
      info: openapi.Info(
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
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
      include: config.Include(tags: [], paths: []),
      handler_layout: config.SingleFile,
    )
  context.new(minimal_spec, cfg)
}
