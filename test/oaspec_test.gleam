import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import oaspec/codegen/client as client_gen
import oaspec/codegen/context
import oaspec/codegen/decoders
import oaspec/codegen/guards
import oaspec/codegen/types
import oaspec/codegen/validate
import oaspec/config
import oaspec/openapi/hoist
import oaspec/openapi/parser
import oaspec/openapi/resolver
import oaspec/openapi/schema
import oaspec/openapi/spec
import oaspec/util/content_type
import oaspec/util/naming
import simplifile

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

pub fn deduplicate_names_no_collision_test() {
  naming.deduplicate_names(["foo", "bar", "baz"])
  |> should.equal(["foo", "bar", "baz"])
}

pub fn deduplicate_names_with_collision_test() {
  naming.deduplicate_names(["pet_id", "pet_id", "name"])
  |> should.equal(["pet_id", "pet_id_2", "name"])
}

pub fn deduplicate_names_triple_collision_test() {
  naming.deduplicate_names(["x", "x", "x"])
  |> should.equal(["x", "x_2", "x_3"])
}

pub fn deduplicate_names_empty_test() {
  naming.deduplicate_names([])
  |> should.equal([])
}

// --- Config Tests ---

pub fn load_config_test() {
  let assert Ok(cfg) = config.load("test/fixtures/oaspec.yaml")
  cfg.input |> should.equal("test/fixtures/petstore.yaml")
  cfg.output_server |> should.equal("./test_output/api")
  cfg.output_client |> should.equal("./test_output_client/api")
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

pub fn config_package_dir_mismatch_test() {
  let cfg =
    config.Config(
      input: "openapi.yaml",
      output_server: "./gen/wrong_name",
      output_client: "./gen/api",
      package: "api",
      mode: config.Both,
    )
  let result = config.validate_output_package_match(cfg)
  should.be_error(result)
}

pub fn config_client_dir_mismatch_test() {
  let cfg =
    config.Config(
      input: "openapi.yaml",
      output_server: "./gen/api",
      output_client: "./gen/wrong_client",
      package: "api",
      mode: config.Both,
    )
  let result = config.validate_output_package_match(cfg)
  should.be_error(result)
}

pub fn config_package_dir_match_test() {
  let cfg =
    config.Config(
      input: "openapi.yaml",
      output_server: "./gen/api",
      output_client: "./gen_client/api",
      package: "api",
      mode: config.Both,
    )
  let result = config.validate_output_package_match(cfg)
  should.be_ok(result)
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

pub fn parse_secure_api_has_security_schemes_test() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/secure_api.yaml")
  let assert Some(components) = spec.components
  dict.size(components.security_schemes) |> should.equal(2)
}

pub fn parse_secure_api_operation_has_security_test() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/secure_api.yaml")
  let assert Ok(path_item) = dict.get(spec.paths, "/pets")
  let assert Some(get_op) = path_item.get
  let assert Some(sec) = get_op.security
  list.length(sec) |> should.equal(1)
}

pub fn parse_accepts_basic_auth_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  securitySchemes:
    BasicAuth:
      type: http
      scheme: basic
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Some(components) = spec.components
  let assert Ok(scheme) = dict.get(components.security_schemes, "BasicAuth")
  case scheme {
    spec.HttpScheme(scheme: "basic", bearer_format: None) ->
      should.be_true(True)
    _ -> should.fail()
  }
}

pub fn parse_accepts_digest_auth_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  securitySchemes:
    DigestAuth:
      type: http
      scheme: digest
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Some(components) = spec.components
  let assert Ok(scheme) = dict.get(components.security_schemes, "DigestAuth")
  case scheme {
    spec.HttpScheme(scheme: "digest", bearer_format: None) ->
      should.be_true(True)
    _ -> should.fail()
  }
}

pub fn parse_rejects_malformed_security_scopes_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      security:
        - ApiKeyAuth: 123
      responses:
        '200':
          description: ok
components:
  securitySchemes:
    ApiKeyAuth:
      type: apiKey
      in: header
      name: X-Key
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
}

pub fn parse_primitive_api_test() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/primitive_api.yaml")
  spec.info.title |> should.equal("Primitive API")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(1)
}

pub fn parse_global_security_inherited_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/global_security_api.yaml")
  // Top-level security should be parsed
  list.length(spec.security) |> should.equal(1)
  // /me has no operation-level security -> inherits
  let assert Ok(me_path) = dict.get(spec.paths, "/me")
  let assert Some(get_me) = me_path.get
  get_me.security |> should.equal(None)
  // /public has explicit empty security -> opts out
  let assert Ok(public_path) = dict.get(spec.paths, "/public")
  let assert Some(get_public) = public_path.get
  get_public.security |> should.equal(Some([]))
}

pub fn validate_rejects_array_parameter_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /search:
    get:
      operationId: search
      parameters:
        - name: tags
          in: query
          schema:
            type: array
            items: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "Array parameters") })
  |> should.be_true()
}

pub fn validate_rejects_optional_array_parameter_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /search:
    get:
      operationId: search
      parameters:
        - name: tags
          in: query
          required: false
          schema:
            type: array
            items: { type: integer }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "Array parameters") })
  |> should.be_true()
}

pub fn validate_accepts_text_plain_response_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /health:
    get:
      operationId: getHealth
      responses:
        '200':
          description: ok
          content:
            text/plain:
              schema: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  errors |> should.equal([])
}

pub fn validate_rejects_text_plain_request_body_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /echo:
    post:
      operationId: postEcho
      requestBody:
        required: true
        content:
          text/plain:
            schema: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "multipart/form-data")
    && string.contains(s, "request bodies")
  })
  |> should.be_true()
}

pub fn validate_rejects_property_name_collision_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    Pet:
      type: object
      required: [pet-id, pet_id]
      properties:
        pet-id: { type: string }
        pet_id: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "Property name collision")
  })
  |> should.be_true()
}

pub fn parse_rejects_optional_path_parameter_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets/{petId}:
    get:
      operationId: getPet
      parameters:
        - name: petId
          in: path
          required: false
          schema: { type: string }
      responses:
        '200': { description: ok }
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(parser.InvalidValue(path: _, detail: detail)) = result
  string.contains(detail, "required: true") |> should.be_true()
}

fn make_ctx_from_spec(spec) -> context.Context {
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
    )
  context.new(spec, cfg)
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
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
    )
  context.new(spec, cfg)
}

pub fn validate_rejects_deep_object_test() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "deepObject") })
  |> should.be_true()
}

pub fn validate_rejects_complex_schema_parameter_test() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "Complex schema parameters")
  })
  |> should.be_true()
}

pub fn validate_rejects_referenced_unsupported_parameter_schemas_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items/{filter}:
    get:
      operationId: getItems
      parameters:
        - name: filter
          in: path
          required: true
          schema:
            $ref: '#/components/schemas/Filter'
        - name: tags
          in: query
          required: false
          schema:
            $ref: '#/components/schemas/TagList'
      responses:
        '200': { description: ok }
components:
  schemas:
    Filter:
      type: object
      properties:
        q: { type: string }
    TagList:
      type: array
      items:
        type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)

  list.any(error_strings, fn(s) {
    string.contains(s, "Complex schema parameters")
  })
  |> should.be_true()
  list.any(error_strings, fn(s) { string.contains(s, "Array parameters") })
  |> should.be_true()
}

pub fn validate_accepts_multipart_form_data_test() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "multipart/form-data") })
  |> should.be_false()
}

pub fn validate_rejects_unstringifiable_multipart_fields_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /upload:
    post:
      operationId: uploadFile
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required: [metadata]
              properties:
                metadata:
                  $ref: '#/components/schemas/Metadata'
      responses:
        '200': { description: ok }
components:
  schemas:
    Metadata:
      type: object
      properties:
        title: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "multipart/form-data fields")
  })
  |> should.be_true()
}

pub fn validate_broken_spec_detects_inline_oneof_test() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "oneOf/anyOf with inline schemas")
  })
  |> should.be_true()
}

pub fn validate_broken_spec_accepts_untyped_additional_properties_test() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  // additionalProperties: true is now supported via Dict(String, Dynamic),
  // so it should NOT appear as a validation error
  list.any(error_strings, fn(s) { string.contains(s, "additionalProperties") })
  |> should.be_false()
}

// --- Parser: fail-fast tests ---

pub fn parse_missing_responses_fails_test() {
  let result = parser.parse_file("test/fixtures/missing_responses.yaml")
  should.be_error(result)
  let assert Error(parser.MissingField(path: _, field: "responses")) = result
}

pub fn parse_invalid_param_location_fails_test() {
  let result = parser.parse_file("test/fixtures/invalid_param_location.yaml")
  should.be_error(result)
  let assert Error(parser.InvalidValue(path: "parameter.in", detail: _)) =
    result
}

pub fn parse_missing_openapi_field_fails_test() {
  let yaml =
    "
info:
  title: Test
  version: 1.0.0
paths: {}
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(parser.MissingField(path: "", field: "openapi")) = result
}

pub fn parse_missing_info_fails_test() {
  let yaml =
    "
openapi: 3.0.3
paths: {}
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(parser.MissingField(path: "", field: "info")) = result
}

pub fn parse_missing_info_title_fails_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  version: 1.0.0
paths: {}
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(parser.MissingField(path: "info", field: "title")) = result
}

pub fn validate_deep_inline_oneof_in_request_body_test() {
  let ctx = make_ctx("test/fixtures/deep_unsupported.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  // oneOf with inline primitives in requestBody should be caught
  list.any(error_strings, fn(s) {
    string.contains(s, "oneOf/anyOf with inline schemas")
    && string.contains(s, "requestBody")
  })
  |> should.be_true()
}

pub fn validate_deep_additional_properties_in_response_test() {
  let ctx = make_ctx("test/fixtures/deep_unsupported.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  // additionalProperties: true is now supported, so no error for it
  list.any(error_strings, fn(s) {
    string.contains(s, "additionalProperties") && string.contains(s, "payload")
  })
  |> should.be_false()
}

pub fn validate_duplicate_operation_id_test() {
  let ctx = make_ctx("test/fixtures/collision.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "Duplicate operationId") && string.contains(s, "getUser")
  })
  |> should.be_true()
}

pub fn validate_accepts_typed_additional_properties_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /config:
    get:
      operationId: getConfig
      responses:
        '200': { description: ok }
components:
  schemas:
    Config:
      type: object
      required: [name]
      properties:
        name: { type: string }
      additionalProperties:
        type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  errors |> should.equal([])
}

pub fn validate_accepts_untyped_additional_properties_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /data:
    get:
      operationId: getData
      responses:
        '200': { description: ok }
components:
  schemas:
    Payload:
      type: object
      required: [name]
      properties:
        name: { type: string }
      additionalProperties: true
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  errors |> should.equal([])
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

// --- Hoist Tests ---

pub fn hoist_inline_object_property_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    Pet:
      type: object
      required: [name]
      properties:
        name: { type: string }
        address:
          type: object
          properties:
            street: { type: string }
            city: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // PetAddress should exist in components.schemas
  dict.has_key(components.schemas, "PetAddress") |> should.be_true()

  // Pet.address should now be a $ref
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "Pet")
  let assert Ok(schema.Reference(ref: ref)) = dict.get(props, "address")
  ref |> should.equal("#/components/schemas/PetAddress")

  // PetAddress should have street and city properties
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: addr_props, ..))) =
    dict.get(components.schemas, "PetAddress")
  dict.has_key(addr_props, "street") |> should.be_true()
  dict.has_key(addr_props, "city") |> should.be_true()
}

pub fn hoist_inline_oneof_variants_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    PetType:
      oneOf:
        - type: object
          properties:
            bark_volume: { type: integer }
        - type: object
          properties:
            purr_frequency: { type: number }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // The oneOf variants should now be $ref references
  let assert Ok(schema.Inline(schema.OneOfSchema(schemas: variants, ..))) =
    dict.get(components.schemas, "PetType")
  list.each(variants, fn(v) {
    case v {
      schema.Reference(_) -> should.be_true(True)
      schema.Inline(_) -> should.fail()
    }
  })

  // Hoisted schemas should exist (naming: PetType0, PetType1 or similar)
  // At minimum, components.schemas should have more than just PetType
  dict.size(components.schemas) |> should.equal(3)
}

pub fn hoist_inline_array_items_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    PetList:
      type: array
      items:
        type: object
        properties:
          name: { type: string }
          age: { type: integer }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // Array items should now be a $ref
  let assert Ok(schema.Inline(schema.ArraySchema(items: items_ref, ..))) =
    dict.get(components.schemas, "PetList")
  let assert schema.Reference(ref: ref) = items_ref
  string.contains(ref, "#/components/schemas/") |> should.be_true()

  // The extracted schema should exist in components.schemas
  dict.size(components.schemas) |> should.equal(2)
}

pub fn hoist_preserves_refs_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    Pet:
      type: object
      properties:
        name: { type: string }
        owner:
          $ref: '#/components/schemas/Owner'
    Owner:
      type: object
      properties:
        name: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // No extra schemas should be added
  dict.size(components.schemas) |> should.equal(2)

  // The $ref should remain unchanged
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "Pet")
  let assert Ok(schema.Reference(ref: ref)) = dict.get(props, "owner")
  ref |> should.equal("#/components/schemas/Owner")
}

pub fn hoist_preserves_primitives_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    User:
      type: object
      properties:
        name: { type: string }
        age: { type: integer }
        active: { type: boolean }
        score: { type: number }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // No extra schemas should be added for primitives
  dict.size(components.schemas) |> should.equal(1)

  // Properties should remain inline primitives
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "User")
  let assert Ok(schema.Inline(schema.StringSchema(..))) =
    dict.get(props, "name")
  let assert Ok(schema.Inline(schema.IntegerSchema(..))) =
    dict.get(props, "age")
  let assert Ok(schema.Inline(schema.BooleanSchema(..))) =
    dict.get(props, "active")
  let assert Ok(schema.Inline(schema.NumberSchema(..))) =
    dict.get(props, "score")
}

pub fn hoist_nested_inline_objects_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    Company:
      type: object
      properties:
        name: { type: string }
        headquarters:
          type: object
          properties:
            city: { type: string }
            coordinates:
              type: object
              properties:
                lat: { type: number }
                lon: { type: number }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // Both nested levels should be hoisted
  dict.has_key(components.schemas, "CompanyHeadquarters") |> should.be_true()
  dict.has_key(components.schemas, "CompanyHeadquartersCoordinates")
  |> should.be_true()

  // Company.headquarters should be a $ref
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: company_props, ..))) =
    dict.get(components.schemas, "Company")
  let assert Ok(schema.Reference(ref: hq_ref)) =
    dict.get(company_props, "headquarters")
  hq_ref |> should.equal("#/components/schemas/CompanyHeadquarters")

  // CompanyHeadquarters.coordinates should be a $ref
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: hq_props, ..))) =
    dict.get(components.schemas, "CompanyHeadquarters")
  let assert Ok(schema.Reference(ref: coord_ref)) =
    dict.get(hq_props, "coordinates")
  coord_ref
  |> should.equal("#/components/schemas/CompanyHeadquartersCoordinates")

  // CompanyHeadquartersCoordinates should have lat and lon
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: coord_props, ..))) =
    dict.get(components.schemas, "CompanyHeadquartersCoordinates")
  dict.has_key(coord_props, "lat") |> should.be_true()
  dict.has_key(coord_props, "lon") |> should.be_true()
}

pub fn hoist_request_body_inline_object_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets:
    post:
      operationId: createPet
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                name: { type: string }
                tag: { type: string }
      responses:
        '201': { description: created }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // The inline request body schema should be extracted
  dict.has_key(components.schemas, "CreatePetRequest")
  |> should.be_true()

  // The request body should now reference the extracted schema
  let assert Ok(path_item) = dict.get(hoisted.paths, "/pets")
  let assert Some(op) = path_item.post
  let assert Some(req_body) = op.request_body
  let assert Ok(media_type) = dict.get(req_body.content, "application/json")
  let assert Some(schema.Reference(ref: ref)) = media_type.schema
  string.contains(ref, "#/components/schemas/") |> should.be_true()
}

pub fn hoist_response_inline_object_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets:
    get:
      operationId: listPets
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
                properties:
                  id: { type: integer }
                  name: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // The inline response schema should be extracted (with status code in name)
  dict.has_key(components.schemas, "ListPetsResponse200")
  |> should.be_true()

  // The response should now reference the extracted schema
  let assert Ok(path_item) = dict.get(hoisted.paths, "/pets")
  let assert Some(op) = path_item.get
  let assert Ok(response) = dict.get(op.responses, "200")
  let assert Ok(media_type) = dict.get(response.content, "application/json")
  let assert Some(schema.Reference(ref: ref)) = media_type.schema
  string.contains(ref, "#/components/schemas/") |> should.be_true()
}

pub fn hoist_idempotent_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    Pet:
      type: object
      properties:
        name: { type: string }
        address:
          type: object
          properties:
            street: { type: string }
            city: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted_once = hoist.hoist(spec)
  let hoisted_twice = hoist.hoist(hoisted_once)

  // Both hoisted results should have the same schemas
  let assert Some(components_once) = hoisted_once.components
  let assert Some(components_twice) = hoisted_twice.components
  dict.size(components_once.schemas)
  |> should.equal(dict.size(components_twice.schemas))

  // The schemas should be identical
  hoisted_once |> should.equal(hoisted_twice)
}

pub fn hoist_name_collision_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    Pet:
      type: object
      properties:
        name: { type: string }
        address:
          type: object
          properties:
            street: { type: string }
    PetAddress:
      type: object
      properties:
        zip: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // Original PetAddress should still exist
  dict.has_key(components.schemas, "PetAddress") |> should.be_true()

  // The hoisted schema should use a suffixed name to avoid collision
  // There should be 3 schemas: Pet, PetAddress (original), and PetAddress2 (or similar)
  dict.size(components.schemas) |> should.equal(3)

  // Pet.address should reference the suffixed name, not the original PetAddress
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "Pet")
  let assert Ok(schema.Reference(ref: ref)) = dict.get(props, "address")
  // The ref should NOT be the original PetAddress
  ref |> should.not_equal("#/components/schemas/PetAddress")
  // It should still be a valid components reference
  string.contains(ref, "#/components/schemas/") |> should.be_true()
}

pub fn hoist_case_normalized_name_collision_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    User:
      type: object
      properties:
        address:
          type: object
          properties:
            street: { type: string }
    user_address:
      type: object
      properties:
        zip: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  dict.has_key(components.schemas, "user_address") |> should.be_true()
  dict.size(components.schemas) |> should.equal(3)

  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "User")
  let assert Ok(schema.Reference(ref: ref)) = dict.get(props, "address")
  ref |> should.not_equal("#/components/schemas/UserAddress")
}

// --- ContentType Tests ---

pub fn content_type_from_string_test() {
  content_type.from_string("application/json")
  |> should.equal(content_type.ApplicationJson)

  content_type.from_string("text/plain")
  |> should.equal(content_type.TextPlain)

  content_type.from_string("multipart/form-data")
  |> should.equal(content_type.MultipartFormData)

  content_type.from_string("application/xml")
  |> should.equal(content_type.UnsupportedContentType("application/xml"))
}

pub fn content_type_to_string_test() {
  content_type.to_string(content_type.ApplicationJson)
  |> should.equal("application/json")

  content_type.to_string(content_type.TextPlain)
  |> should.equal("text/plain")

  content_type.to_string(content_type.MultipartFormData)
  |> should.equal("multipart/form-data")

  content_type.to_string(content_type.UnsupportedContentType("application/xml"))
  |> should.equal("application/xml")
}

pub fn content_type_is_supported_test() {
  content_type.is_supported(content_type.ApplicationJson)
  |> should.be_true()

  content_type.is_supported(content_type.TextPlain)
  |> should.be_true()

  content_type.is_supported(content_type.MultipartFormData)
  |> should.be_true()

  content_type.is_supported(content_type.UnsupportedContentType(
    "application/xml",
  ))
  |> should.be_false()
}

pub fn content_type_is_supported_request_test() {
  content_type.is_supported_request(content_type.ApplicationJson)
  |> should.be_true()

  content_type.is_supported_request(content_type.MultipartFormData)
  |> should.be_true()

  content_type.is_supported_request(content_type.TextPlain)
  |> should.be_false()
}

pub fn content_type_is_supported_response_test() {
  content_type.is_supported_response(content_type.ApplicationJson)
  |> should.be_true()

  content_type.is_supported_response(content_type.TextPlain)
  |> should.be_true()

  content_type.is_supported_response(content_type.MultipartFormData)
  |> should.be_false()
}

pub fn content_type_roundtrip_test() {
  content_type.from_string("application/json")
  |> content_type.to_string()
  |> should.equal("application/json")

  content_type.from_string("text/plain")
  |> content_type.to_string()
  |> should.equal("text/plain")

  content_type.from_string("multipart/form-data")
  |> content_type.to_string()
  |> should.equal("multipart/form-data")

  content_type.from_string("image/png")
  |> content_type.to_string()
  |> should.equal("image/png")
}

pub fn parse_accepts_oauth2_scheme_test() {
  let yaml =
    "
openapi: '3.0.0'
info: { title: OAuth2 API, version: '1.0' }
paths:
  /resource:
    get:
      operationId: getResource
      security:
        - oauth2Auth: []
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    oauth2Auth:
      type: oauth2
      description: OAuth2 authorization code
      flows:
        authorizationCode:
          authorizationUrl: https://example.com/auth
          tokenUrl: https://example.com/token
          scopes: {}
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert Some(components) = parsed.components
  let assert Ok(scheme) = dict.get(components.security_schemes, "oauth2Auth")
  case scheme {
    spec.OAuth2Scheme(description: Some("OAuth2 authorization code")) ->
      should.be_true(True)
    _ -> should.fail()
  }
}

pub fn parse_accepts_apikey_cookie_test() {
  let yaml =
    "
openapi: '3.0.0'
info: { title: Cookie API, version: '1.0' }
paths:
  /resource:
    get:
      operationId: getResource
      security:
        - cookieAuth: []
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    cookieAuth:
      type: apiKey
      name: session_id
      in: cookie
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert Some(components) = parsed.components
  let assert Ok(scheme) = dict.get(components.security_schemes, "cookieAuth")
  case scheme {
    spec.ApiKeyScheme(name: "session_id", in_: "cookie") -> should.be_true(True)
    _ -> should.fail()
  }
}

// --- Feature: allOf with primitive sub-schemas (Phase 4-2) ---

pub fn allof_with_primitive_sub_schema_test() {
  // allOf that mixes object and primitive schemas should not crash.
  // Primitive sub-schemas are silently ignored; object properties are merged.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    MixedAllOf:
      allOf:
        - type: string
        - type: object
          required: [name]
          properties:
            name: { type: string }
            age: { type: integer }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)

  // Should generate types without crashing
  let files = types.generate(ctx)
  // Should produce at least one file
  list.length(files) |> should.not_equal(0)

  // The generated types file should contain the MixedAllOf type
  // with properties from the object sub-schema
  let assert [types_file, ..] = files
  string.contains(types_file.content, "MixedAllOf") |> should.be_true()
  string.contains(types_file.content, "name: String") |> should.be_true()
}

// --- Feature: Validation constraints generate guards (Phase 4-3) ---

pub fn validate_constraints_generate_guards_test() {
  // Schemas with minLength/maxLength/minimum/maximum should produce guard functions.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /users:
    get:
      operationId: listUsers
      responses:
        '200': { description: ok }
components:
  schemas:
    User:
      type: object
      required: [username, age]
      properties:
        username:
          type: string
          minLength: 3
          maxLength: 50
        age:
          type: integer
          minimum: 0
          maximum: 150
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)

  // Should generate guard files without crashing
  let files = guards.generate(ctx)
  // Should produce at least one file (guards.gleam)
  list.length(files) |> should.not_equal(0)

  let assert [guard_file] = files
  guard_file.path |> should.equal("guards.gleam")

  // Should contain validation functions for constrained fields
  string.contains(guard_file.content, "validate_user_username_length")
  |> should.be_true()
  string.contains(guard_file.content, "validate_user_age_range")
  |> should.be_true()
}

// --- Feature: Callbacks are ignored during parsing (Phase 4-4) ---

pub fn parse_ignores_callbacks_test() {
  // Operations with a callbacks field should parse without error.
  // The callbacks field is simply ignored.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Callback Test
  version: 1.0.0
paths:
  /subscribe:
    post:
      operationId: subscribe
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                callbackUrl:
                  type: string
      callbacks:
        onEvent:
          '{$request.body#/callbackUrl}':
            post:
              requestBody:
                content:
                  application/json:
                    schema:
                      type: object
                      properties:
                        event: { type: string }
              responses:
                '200': { description: ok }
      responses:
        '201': { description: subscribed }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  spec.info.title |> should.equal("Callback Test")
  // The operation should have parsed successfully
  let assert Ok(path_item) = dict.get(spec.paths, "/subscribe")
  let assert Some(op) = path_item.post
  op.operation_id |> should.equal(Some("subscribe"))
}

// =========================================================================
// Finding reproduction tests
// =========================================================================

// --- Finding 1: typed additionalProperties decoder must not apply value
// decoder to known fields. When a schema has additionalProperties: {type: string}
// but also has a fixed property of type integer, the decoder must not try
// to decode ALL values as strings (which would fail on the integer field).
// The fix: use dynamic.dynamic to read the raw dict, then filter + decode.
pub fn typed_additional_props_decoder_uses_dynamic_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /config:
    get:
      operationId: getConfig
      responses:
        '200': { description: ok }
components:
  schemas:
    Config:
      type: object
      required: [version]
      properties:
        version: { type: integer }
      additionalProperties:
        type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = decoders.generate(ctx)
  let assert [decode_file, ..] = files
  let content = decode_file.content
  // The decoder must NOT use decode.dict(decode.string, decode.string)
  // because that would fail on the integer "version" field.
  // It should use dynamic.dynamic for the initial dict read.
  string.contains(content, "decode.dict(decode.string, decode.string)")
  |> should.be_false()
  // It should decode the dict with dynamic values first
  string.contains(content, "dynamic.dynamic")
  |> should.be_true()
}

pub fn typed_additional_props_decoder_rejects_invalid_extra_values_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /config:
    get:
      operationId: getConfig
      responses:
        '200': { description: ok }
components:
  schemas:
    Config:
      type: object
      required: [version]
      properties:
        version: { type: integer }
      additionalProperties:
        type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = decoders.generate(ctx)
  let assert [decode_file, ..] = files
  let content = decode_file.content

  // Invalid extra values must fail decoding rather than being silently dropped.
  string.contains(content, "Error(_) -> acc")
  |> should.be_false()
  string.contains(
    content,
    "decode.failure(dict.new(), \"additionalProperties\")",
  )
  |> should.be_true()
}

// --- Finding 2: multipart/form-data client must handle optional and $ref fields.
// Currently body.<field> is concatenated as-is, which breaks for Option(T) and
// typed $ref fields.
pub fn multipart_optional_field_generates_case_expr_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /upload:
    post:
      operationId: uploadFile
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required: [name]
              properties:
                name: { type: string }
                description: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx =
    context.new(
      spec,
      config.Config(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // Optional "description" field must have case/Some/None handling,
  // not raw body.description string concatenation
  string.contains(content, "case body.description")
  |> should.be_true()
}

pub fn multipart_ref_scalar_field_is_stringified_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /upload:
    post:
      operationId: uploadFile
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required: [id]
              properties:
                id:
                  $ref: '#/components/schemas/UploadId'
      responses:
        '200': { description: ok }
components:
  schemas:
    UploadId:
      type: integer
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx =
    context.new(
      spec,
      config.Config(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content

  string.contains(content, "int.to_string(body.id)")
  |> should.be_true()
}

pub fn path_ref_array_parameters_are_stringified_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items/{tags}:
    get:
      operationId: getItems
      parameters:
        - name: tags
          in: path
          required: true
          schema:
            $ref: '#/components/schemas/TagList'
      responses:
        '200': { description: ok }
components:
  schemas:
    TagList:
      type: array
      items:
        type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx =
    context.new(
      spec,
      config.Config(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content

  string.contains(content, "string.join(list.map(tags, fn(x) { x }), \",\")")
  |> should.be_true()
}

// --- Finding 3: unknown HTTP security schemes must produce a validation error
// or a warning, not be silently ignored at code generation time.
pub fn unknown_http_security_scheme_rejected_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /data:
    get:
      operationId: getData
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    myAuth:
      type: http
      scheme: hoba
security:
  - myAuth: []
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  // Unknown HTTP scheme "hoba" should be flagged
  list.any(error_strings, fn(s) {
    string.contains(s, "hoba") || string.contains(s, "security")
  })
  |> should.be_true()
}

// --- Finding 4: allOf merge must preserve additionalProperties from sub-schemas.
// Currently, merged ObjectSchema hardcodes additional_properties: None.
pub fn allof_merge_preserves_additional_properties_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200': { description: ok }
components:
  schemas:
    BaseItem:
      type: object
      required: [id]
      properties:
        id: { type: integer }
      additionalProperties:
        type: string
    ExtendedItem:
      allOf:
        - $ref: '#/components/schemas/BaseItem'
        - type: object
          properties:
            label: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  let content = types_file.content
  // ExtendedItem must have additional_properties field since BaseItem has it
  string.contains(content, "pub type ExtendedItem {")
  |> should.be_true()
  // Extract the ExtendedItem type block and check it has additional_properties
  let assert Ok(extended_start) =
    find_substring_index(content, "pub type ExtendedItem {")
  let after_extended = string.drop_start(content, extended_start)
  // The ExtendedItem block itself must contain additional_properties
  // (not just the BaseItem block above it)
  let assert Ok(closing_brace) = find_substring_index(after_extended, "\n}\n")
  let extended_block = string.slice(after_extended, 0, closing_brace + 2)
  string.contains(extended_block, "additional_properties:")
  |> should.be_true()
}

// --- Finding 5: README must not list multipart/form-data in both Supported
// and Unsupported sections.
pub fn readme_no_contradictory_multipart_test() {
  let assert Ok(content) = simplifile.read("README.md")
  // Find the Unsupported section
  let assert Ok(unsupported_start) =
    find_substring_index(content, "### Unsupported")
  let unsupported_section = string.drop_start(content, unsupported_start)
  // multipart/form-data itself should NOT be listed as unsupported
  string.contains(unsupported_section, "- `multipart/form-data` request bodies")
  |> should.be_false()
}

fn find_substring_index(haystack: String, needle: String) -> Result(Int, Nil) {
  case string.contains(haystack, needle) {
    True -> {
      let parts = string.split(haystack, needle)
      case parts {
        [before, ..] -> Ok(string.length(before))
        _ -> Error(Nil)
      }
    }
    False -> Error(Nil)
  }
}
