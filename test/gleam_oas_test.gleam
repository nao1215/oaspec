import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_oas/codegen/context
import gleam_oas/codegen/validate
import gleam_oas/config
import gleam_oas/openapi/parser
import gleam_oas/openapi/resolver
import gleam_oas/openapi/schema
import gleam_oas/util/naming
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// --- Naming Tests ---

pub fn to_pascal_case_test() {
  naming.to_pascal_case("pet_store")
  |> should.equal("PetStore")
}

pub fn to_pascal_case_from_kebab_test() {
  naming.to_pascal_case("get-user")
  |> should.equal("GetUser")
}

pub fn to_pascal_case_from_camel_test() {
  naming.to_pascal_case("getUserById")
  |> should.equal("GetUserById")
}

pub fn to_snake_case_test() {
  naming.to_snake_case("PetStore")
  |> should.equal("pet_store")
}

pub fn to_snake_case_from_camel_test() {
  naming.to_snake_case("getUserById")
  |> should.equal("get_user_by_id")
}

pub fn capitalize_test() {
  naming.capitalize("hello")
  |> should.equal("Hello")
}

// --- Config Tests ---

pub fn load_config_test() {
  let assert Ok(cfg) = config.load("test/fixtures/gleam-oas.yaml")
  cfg.input |> should.equal("test/fixtures/petstore.yaml")
  cfg.output_server |> should.equal("./test_output/server")
  cfg.output_client |> should.equal("./test_output/client")
  cfg.package |> should.equal("api")
}

pub fn config_not_found_test() {
  let result = config.load("nonexistent.yaml")
  case result {
    Error(config.FileNotFound(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn parse_mode_test() {
  config.parse_mode("server") |> should.be_ok()
  config.parse_mode("client") |> should.be_ok()
  config.parse_mode("both") |> should.be_ok()
  config.parse_mode("invalid") |> should.be_error()
}

// --- Parser Tests ---

pub fn parse_petstore_test() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/petstore.yaml")
  spec.info.title |> should.equal("Petstore")
  spec.info.version |> should.equal("1.0.0")
  spec.openapi |> should.equal("3.0.3")
}

pub fn parse_petstore_has_paths_test() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/petstore.yaml")
  dict.size(spec.paths) |> should.not_equal(0)
}

pub fn parse_petstore_has_components_test() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/petstore.yaml")
  case spec.components {
    Some(_) -> should.be_true(True)
    None -> should.fail()
  }
}

pub fn parse_file_not_found_test() {
  let result = parser.parse_file("nonexistent.yaml")
  should.be_error(result)
}

// --- Resolver Tests ---

pub fn ref_to_name_test() {
  resolver.ref_to_name("#/components/schemas/User")
  |> should.equal("User")
}

pub fn ref_to_name_simple_test() {
  resolver.ref_to_name("#/components/schemas/PetStatus")
  |> should.equal("PetStatus")
}

// --- Parser: style field ---

pub fn parse_parameter_style_deep_object_test() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/broken_openapi.yaml")
  let assert Ok(path_item) = dict.get(spec.paths, "/deep-object")
  let assert Some(op) = path_item.get
  let assert [param] = op.parameters
  param.name |> should.equal("filter")
  param.style |> should.equal(Some("deepObject"))
}

pub fn parse_parameter_style_none_test() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/petstore.yaml")
  let assert Ok(path_item) = dict.get(spec.paths, "/pets")
  let assert Some(op) = path_item.get
  let assert [first, ..] = op.parameters
  first.style |> should.equal(None)
}

// --- Parser: additionalProperties ---

pub fn parse_additional_properties_untyped_test() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/broken_openapi.yaml")
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "UntypedPayload")
  let assert Ok(schema.Inline(schema.ObjectSchema(
    additional_properties_untyped: untyped,
    ..,
  ))) = dict.get(props, "payload")
  untyped |> should.be_true()
}

// --- Validation Tests ---

fn make_ctx(spec_path: String) -> context.Context {
  let assert Ok(spec) = parser.parse_file(spec_path)
  let cfg =
    config.Config(
      input: spec_path,
      output_server: "./test_output/server",
      output_client: "./test_output/client",
      package: "api",
      mode: config.Both,
    )
  context.new(spec, cfg)
}

pub fn validate_broken_spec_detects_deep_object_test() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "deepObject") })
  |> should.be_true()
}

pub fn validate_broken_spec_detects_multipart_test() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "multipart/form-data") })
  |> should.be_true()
}

pub fn validate_broken_spec_detects_inline_oneof_test() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "oneOf/anyOf with inline primitive")
  })
  |> should.be_true()
}

pub fn validate_broken_spec_detects_additional_properties_test() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "additionalProperties") })
  |> should.be_true()
}

pub fn validate_petstore_has_no_errors_test() {
  let ctx = make_ctx("test/fixtures/petstore.yaml")
  let errors = validate.validate(ctx)
  errors |> should.equal([])
}

pub fn validate_complex_supported_has_no_errors_test() {
  let ctx = make_ctx("test/fixtures/complex_supported_openapi.yaml")
  let errors = validate.validate(ctx)
  errors |> should.equal([])
}
