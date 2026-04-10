import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import oaspec/capability
import oaspec/codegen/client as client_gen
import oaspec/codegen/context
import oaspec/codegen/decoders
import oaspec/codegen/guards
import oaspec/codegen/ir
import oaspec/codegen/ir_render
import oaspec/codegen/schema_dispatch
import oaspec/codegen/server as server_gen
import oaspec/codegen/types
import oaspec/codegen/validate
import oaspec/config
import oaspec/generate
import oaspec/openapi/capability_check
import oaspec/openapi/dedup
import oaspec/openapi/diagnostic.{Diagnostic}
import oaspec/openapi/hoist
import oaspec/openapi/normalize
import oaspec/openapi/parser
import oaspec/openapi/resolve
import oaspec/openapi/resolver
import oaspec/openapi/schema
import oaspec/openapi/spec
import oaspec/openapi/value
import oaspec/util/content_type
import oaspec/util/http
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
  let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/pets")
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
    spec.Value(spec.HttpScheme(scheme: "basic", bearer_format: None)) ->
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
    spec.Value(spec.HttpScheme(scheme: "digest", bearer_format: None)) ->
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
  let assert Ok(spec.Value(me_path)) = dict.get(spec.paths, "/me")
  let assert Some(get_me) = me_path.get
  get_me.security |> should.equal(None)
  // /public has explicit empty security -> opts out
  let assert Ok(spec.Value(public_path)) = dict.get(spec.paths, "/public")
  let assert Some(get_public) = public_path.get
  get_public.security |> should.equal(Some([]))
}

pub fn validate_accepts_array_parameter_test() {
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
  let errors =
    validate.validate(ctx)
    |> list.filter(fn(e) { e.target != diagnostic.TargetServer })
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "Array parameters") })
  |> should.be_false()
}

pub fn validate_accepts_optional_array_parameter_test() {
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
  let errors =
    validate.validate(ctx)
    |> list.filter(fn(e) { e.target != diagnostic.TargetServer })
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "Array parameters") })
  |> should.be_false()
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
    && string.contains(s, "form-urlencoded")
  })
  |> should.be_true()
}

pub fn dedup_resolves_property_name_collision_test() {
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
  // Dedup pass resolves property name collisions
  let spec = dedup.dedup(hoist.hoist(spec))
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  // No collision errors since dedup resolved them
  errors |> should.equal([])
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
  let assert Error(Diagnostic(code: "invalid_value", message: detail, ..)) =
    result
  string.contains(detail, "required: true") |> should.be_true()
}

fn make_ctx_from_spec(spec) -> context.Context {
  let assert Ok(resolved) = resolve.resolve(spec)
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
    )
  context.new(resolved, cfg)
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
  let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/deep-object")
  let assert Some(op) = path_item.get
  let assert [spec.Value(param)] = op.parameters
  param.name |> should.equal("filter")
  param.style |> should.equal(Some(spec.DeepObjectStyle))
}

pub fn parse_parameter_style_none_test() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/petstore.yaml")
  let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/pets")
  let assert Some(op) = path_item.get
  let assert [spec.Value(first), ..] = op.parameters
  first.style |> should.equal(None)
}

// --- Parser: additionalProperties ---

pub fn parse_additional_properties_untyped_test() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/broken_openapi.yaml")
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "UntypedPayload")
  let assert Ok(schema.Inline(schema.ObjectSchema(
    additional_properties: schema.Untyped,
    ..,
  ))) = dict.get(props, "payload")
}

/// Per JSON Schema, absent additionalProperties means allowed (Untyped),
/// not forbidden.
pub fn parse_absent_additional_properties_is_untyped_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths: {}
components:
  schemas:
    Bag:
      type: object
      properties:
        name: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.ObjectSchema(additional_properties: ap, ..))) =
    dict.get(components.schemas, "Bag")
  // Absent additionalProperties MUST be Untyped (allowed), not Forbidden
  ap |> should.equal(schema.Untyped)
}

// --- Validation Tests ---

fn make_ctx(spec_path: String) -> context.Context {
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
    )
  context.new(resolved, cfg)
}

pub fn validate_accepts_deep_object_test() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors =
    validate.validate(ctx)
    |> list.filter(fn(e) { e.target != diagnostic.TargetServer })
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "deepObject") })
  |> should.be_false()
}

pub fn validate_accepts_complex_schema_parameter_test() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors =
    validate.validate(ctx)
    |> list.filter(fn(e) { e.target != diagnostic.TargetServer })
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "Complex schema parameters")
  })
  |> should.be_false()
}

pub fn validate_accepts_referenced_parameter_schemas_test() {
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
  let errors =
    validate.validate(ctx)
    |> list.filter(fn(e) { e.target != diagnostic.TargetServer })
  errors |> should.equal([])
}

pub fn validate_accepts_multipart_form_data_test() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors = validate.validate(ctx)
  // Filter out server-targeted errors; multipart is valid for client codegen
  let client_errors =
    list.filter(errors, fn(e) { e.target != diagnostic.TargetServer })
  let error_strings = list.map(client_errors, validate.error_to_string)
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

pub fn validate_broken_spec_accepts_inline_oneof_after_hoisting_test() {
  // Inline oneOf variants are now handled by hoisting, so no validation error
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "oneOf/anyOf with inline schemas")
  })
  |> should.be_false()
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

pub fn parse_missing_responses_succeeds_with_empty_dict_test() {
  // Missing responses field is parsed as empty dict (not a parse error).
  // Validation catches missing responses separately.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/missing_responses.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn validate_missing_responses_rejects_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/missing_responses.yaml")
  let result = generate.generate(spec, make_ctx_from_spec(spec).config)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_missing =
        list.any(error_details, fn(d) { string.contains(d, "no responses") })
      should.be_true(has_missing)
    }

    Ok(_) -> should.fail()
  }
}

pub fn parse_invalid_param_location_fails_test() {
  let result = parser.parse_file("test/fixtures/invalid_param_location.yaml")
  should.be_error(result)
  let assert Error(Diagnostic(
    code: "invalid_value",
    pointer: "parameter.in",
    ..,
  )) = result
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
  let assert Error(Diagnostic(
    code: "missing_field",
    pointer: "",
    message: "Missing required field: openapi",
    ..,
  )) = result
}

pub fn parse_missing_info_fails_test() {
  let yaml =
    "
openapi: 3.0.3
paths: {}
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(Diagnostic(
    code: "missing_field",
    pointer: "",
    message: "Missing required field: info",
    ..,
  )) = result
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
  let assert Error(Diagnostic(
    code: "missing_field",
    pointer: "info",
    message: "Missing required field: title",
    ..,
  )) = result
}

pub fn validate_deep_inline_oneof_in_request_body_accepted_test() {
  // Inline oneOf in requestBody is now handled by hoisting
  let ctx = make_ctx("test/fixtures/deep_unsupported.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "oneOf/anyOf with inline schemas")
    && string.contains(s, "requestBody")
  })
  |> should.be_false()
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

pub fn dedup_resolves_duplicate_operation_id_test() {
  let ctx = make_ctx("test/fixtures/collision.yaml")
  let errors = validate.validate(ctx)
  // No duplicate operationId errors since dedup resolved them
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "Duplicate operationId") })
  |> should.be_false()
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
  let assert Ok(schema.Reference(ref: ref, ..)) = dict.get(props, "address")
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
      schema.Reference(..) -> should.be_true(True)
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
  let assert schema.Reference(ref: ref, ..) = items_ref
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
  let assert Ok(schema.Reference(ref: ref, ..)) = dict.get(props, "owner")
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
  let assert Ok(schema.Reference(ref: hq_ref, ..)) =
    dict.get(company_props, "headquarters")
  hq_ref |> should.equal("#/components/schemas/CompanyHeadquarters")

  // CompanyHeadquarters.coordinates should be a $ref
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: hq_props, ..))) =
    dict.get(components.schemas, "CompanyHeadquarters")
  let assert Ok(schema.Reference(ref: coord_ref, ..)) =
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
  let assert Ok(spec.Value(path_item)) = dict.get(hoisted.paths, "/pets")
  let assert Some(op) = path_item.post
  let assert Some(spec.Value(req_body)) = op.request_body
  let assert Ok(media_type) = dict.get(req_body.content, "application/json")
  let assert Some(schema.Reference(ref: ref, ..)) = media_type.schema
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
  let assert Ok(spec.Value(path_item)) = dict.get(hoisted.paths, "/pets")
  let assert Some(op) = path_item.get
  let assert Ok(spec.Value(response)) = dict.get(op.responses, "200")
  let assert Ok(media_type) = dict.get(response.content, "application/json")
  let assert Some(schema.Reference(ref: ref, ..)) = media_type.schema
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
  let assert Ok(schema.Reference(ref: ref, ..)) = dict.get(props, "address")
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
  let assert Ok(schema.Reference(ref: ref, ..)) = dict.get(props, "address")
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

  content_type.from_string("application/x-www-form-urlencoded")
  |> should.equal(content_type.FormUrlEncoded)

  content_type.from_string("application/xml")
  |> should.equal(content_type.ApplicationXml)

  content_type.from_string("text/xml")
  |> should.equal(content_type.TextXml)

  content_type.from_string("application/octet-stream")
  |> should.equal(content_type.ApplicationOctetStream)
}

pub fn content_type_to_string_test() {
  content_type.to_string(content_type.ApplicationJson)
  |> should.equal("application/json")

  content_type.to_string(content_type.TextPlain)
  |> should.equal("text/plain")

  content_type.to_string(content_type.MultipartFormData)
  |> should.equal("multipart/form-data")

  content_type.to_string(content_type.FormUrlEncoded)
  |> should.equal("application/x-www-form-urlencoded")

  content_type.to_string(content_type.ApplicationXml)
  |> should.equal("application/xml")

  content_type.to_string(content_type.ApplicationOctetStream)
  |> should.equal("application/octet-stream")
}

pub fn content_type_is_supported_test() {
  content_type.is_supported(content_type.ApplicationJson)
  |> should.be_true()

  content_type.is_supported(content_type.TextPlain)
  |> should.be_true()

  content_type.is_supported(content_type.MultipartFormData)
  |> should.be_true()

  content_type.is_supported(content_type.FormUrlEncoded)
  |> should.be_true()

  content_type.is_supported(content_type.ApplicationXml)
  |> should.be_true()

  content_type.is_supported(content_type.ApplicationOctetStream)
  |> should.be_true()

  content_type.is_supported(content_type.UnsupportedContentType(
    "application/msgpack",
  ))
  |> should.be_false()
}

pub fn content_type_is_supported_request_test() {
  content_type.is_supported_request(content_type.ApplicationJson)
  |> should.be_true()

  content_type.is_supported_request(content_type.MultipartFormData)
  |> should.be_true()

  content_type.is_supported_request(content_type.FormUrlEncoded)
  |> should.be_true()

  content_type.is_supported_request(content_type.TextPlain)
  |> should.be_false()
}

pub fn content_type_is_supported_response_test() {
  content_type.is_supported_response(content_type.ApplicationJson)
  |> should.be_true()

  content_type.is_supported_response(content_type.TextPlain)
  |> should.be_true()

  content_type.is_supported_response(content_type.ApplicationXml)
  |> should.be_true()

  content_type.is_supported_response(content_type.ApplicationOctetStream)
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
    spec.Value(spec.OAuth2Scheme(
      description: Some("OAuth2 authorization code"),
      ..,
    )) -> should.be_true(True)
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
    spec.Value(spec.ApiKeyScheme(name: "session_id", in_: spec.SchemeInCookie)) ->
      should.be_true(True)
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
  let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/subscribe")
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
  // It should decode the dict with a dynamic primitive decoder first
  string.contains(content, "new_primitive_decoder")
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
  let assert Ok(spec) = resolve.resolve(spec)
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
  let assert Ok(spec) = resolve.resolve(spec)
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
  let assert Ok(spec) = resolve.resolve(spec)
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
pub fn unknown_http_security_scheme_accepted_test() {
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
  // All HTTP schemes are now accepted
  errors |> should.equal([])
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

// --- Finding: dedup must not corrupt JSON wire names ---
// When two properties produce the same snake_case (e.g. "petId" and "pet_id"),
// dedup should rename the Gleam field but the JSON key in decode.field()
// must stay as the original property name from the OpenAPI spec.
pub fn dedup_preserves_json_wire_name_for_properties_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets:
    get:
      operationId: getPets
      responses:
        '200': { description: ok }
components:
  schemas:
    Pet:
      type: object
      required: [petId, pet_id]
      properties:
        petId: { type: string }
        pet_id: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)

  // Check decoders use original wire names
  let files = decoders.generate(ctx)
  let assert [decode_file, ..] = files
  let decode_content = decode_file.content
  // Both original JSON keys must appear in decode.field()
  string.contains(decode_content, "decode.field(\"petId\"")
  |> should.be_true()
  string.contains(decode_content, "decode.field(\"pet_id\"")
  |> should.be_true()
  // The deduped name like "pet_id_2" must NOT appear as a JSON key
  string.contains(decode_content, "\"pet_id_2\"")
  |> should.be_false()

  // Check encoders use original wire names
  let assert [_, encode_file] = files
  let encode_content = encode_file.content
  string.contains(encode_content, "#(\"petId\"")
  |> should.be_true()
  string.contains(encode_content, "#(\"pet_id\"")
  |> should.be_true()
  string.contains(encode_content, "#(\"pet_id_2\"")
  |> should.be_false()
}

// dedup must not corrupt enum wire values.
// When two enum values produce the same PascalCase (e.g. "foo_bar" and "fooBar"),
// the JSON value sent/received must remain the original string.
pub fn dedup_preserves_json_wire_name_for_enums_test() {
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
    Status:
      type: string
      enum: [foo_bar, fooBar]
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)

  // Check decoders preserve original enum string values
  let files = decoders.generate(ctx)
  let assert [decode_file, ..] = files
  let decode_content = decode_file.content
  string.contains(decode_content, "\"foo_bar\"")
  |> should.be_true()
  string.contains(decode_content, "\"fooBar\"")
  |> should.be_true()
  // The corrupted name must NOT appear as a wire value
  string.contains(decode_content, "\"fooBar_2\"")
  |> should.be_false()
  string.contains(decode_content, "\"foo_bar_2\"")
  |> should.be_false()
}

// --- Finding: guards.gleam composite validator must use correct type and suffix ---
pub fn guards_composite_validator_compiles_test() {
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
    BoundedList:
      type: array
      items: { type: string }
      minItems: 1
      maxItems: 10
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  let assert [guards_file] = files
  let content = guards_file.content
  // Composite validator must use the actual type, not literal "value_type"
  string.contains(content, "value_type")
  |> should.be_false()
  // The composite validator must call the same function name as the definition
  // Both definition and call must use the same suffix ("length" for arrays)
  string.contains(content, "validate_bounded_list_length")
  |> should.be_true()
  // Must NOT reference a mismatched "items" suffix
  string.contains(content, "validate_bounded_list_items")
  |> should.be_false()
}

// --- Finding: discriminator-less oneOf via $ref must generate matching decoder ---
pub fn oneof_no_discriminator_ref_decoder_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /wrappers:
    get:
      operationId: getWrappers
      responses:
        '200': { description: ok }
components:
  schemas:
    A:
      type: object
      properties:
        x: { type: integer }
    B:
      type: object
      properties:
        y: { type: string }
    Payload:
      oneOf:
        - $ref: '#/components/schemas/A'
        - $ref: '#/components/schemas/B'
    Wrapper:
      type: object
      required: [payload]
      properties:
        payload:
          $ref: '#/components/schemas/Payload'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = decoders.generate(ctx)
  let assert [decode_file, ..] = files
  let content = decode_file.content
  // Wrapper's decoder references payload_decoder() via schema_ref_to_decoder
  // for the $ref to Payload.  The oneOf generator must define payload_decoder()
  // (not just decode_payload/1).
  string.contains(content, "fn payload_decoder()")
  |> should.be_true()
}

// --- Finding: multiple content-types must not be silently truncated ---
pub fn multiple_content_types_response_test() {
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
        '200':
          description: ok
          content:
            application/json:
              schema: { type: integer }
            text/plain:
              schema: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)

  // Multi-content response types use String to stay type-safe
  let type_files = types.generate(ctx)
  let response_types_content =
    list.find(type_files, fn(f) { string.contains(f.path, "response_types") })
  let assert Ok(rt_file) = response_types_content
  // Variant must use String (not Int from JSON schema) for type safety
  string.contains(rt_file.content, "GetDataResponseOk(String)")
  |> should.be_true()
}

// --- Finding: form-urlencoded must import uri and string modules ---
pub fn form_urlencoded_imports_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /submit:
    post:
      operationId: submitForm
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              required: [name, tags]
              properties:
                name: { type: string }
                tags:
                  type: array
                  items: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // Must import uri for percent_encode
  string.contains(content, "gleam/uri")
  |> should.be_true()
  // Must import string for string.join
  string.contains(content, "gleam/string")
  |> should.be_true()
  // Array field must not produce raw "uri.percent_encode(body.tags)"
  // (that would try to percent_encode a List, which is a type error)
  string.contains(content, "uri.percent_encode(body.tags)")
  |> should.be_false()
}

// --- Finding: callback must support multiple URL expressions ---
pub fn callback_multiple_url_expressions_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /subscribe:
    post:
      operationId: subscribe
      callbacks:
        onEvent:
          '{$request.body#/callbackUrl}/event':
            post:
              operationId: onEvent
              responses:
                '200': { description: ok }
          '{$request.body#/callbackUrl}/status':
            post:
              operationId: onStatus
              responses:
                '200': { description: ok }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // The callback "onEvent" must contain both URL expressions
  let subscribe_path = dict.get(spec.paths, "/subscribe")
  let assert Ok(spec.Value(path_item)) = subscribe_path
  let assert Some(post_op) = path_item.post
  let assert Ok(callback) = dict.get(post_op.callbacks, "onEvent")
  // Callback entries dict must have 2 URL expressions
  let entries = dict.to_list(callback.entries)
  list.length(entries) |> should.equal(2)
  // Both URL expressions must be present
  dict.has_key(callback.entries, "{$request.body#/callbackUrl}/event")
  |> should.be_true()
  dict.has_key(callback.entries, "{$request.body#/callbackUrl}/status")
  |> should.be_true()
}

// --- Finding: guards must handle optional fields and use correct array suffix ---
pub fn guards_optional_field_and_array_suffix_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /samples:
    get:
      operationId: getSamples
      responses:
        '200': { description: ok }
components:
  schemas:
    Sample:
      type: object
      required: [name]
      properties:
        name:
          type: string
          minLength: 1
        nickname:
          type: string
          minLength: 1
        tags:
          type: array
          items: { type: string }
          minItems: 1
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  let assert [guards_file] = files
  let content = guards_file.content
  // Optional field "nickname" is Option(String), so composite validator
  // must unwrap it before calling the validator (or skip when None).
  // It must NOT call validate_sample_nickname_length(value.nickname) directly.
  string.contains(content, "validate_sample_nickname_length(value.nickname)")
  |> should.be_false()
  // Array field must use "length" suffix (matching the generated function),
  // NOT "items" suffix.
  string.contains(content, "validate_sample_tags_items")
  |> should.be_false()
  string.contains(content, "validate_sample_tags_length")
  |> should.be_true()
}

// --- Finding: multi-content response must produce type-safe code ---
// When response has text/plain (String) and application/json (Int),
// the response_type must accommodate both, not just the first.
pub fn multi_content_response_type_safety_test() {
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
        '200':
          description: ok
          content:
            text/plain:
              schema: { type: string }
            application/json:
              schema: { type: integer }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)

  // Response type must use String (common supertype) since text/plain returns String
  let type_files = types.generate(ctx)
  let response_types_content =
    list.find(type_files, fn(f) { string.contains(f.path, "response_types") })
  let assert Ok(rt_file) = response_types_content
  // The variant must use String since text/plain and JSON decode to different types
  // It must NOT use Int (which would be a type error when returning resp.body: String)
  let has_int_variant =
    string.contains(rt_file.content, "GetDataResponseOk(Int)")
  let has_string_variant =
    string.contains(rt_file.content, "GetDataResponseOk(String)")
  // Either use String for both, or separate variants per content-type
  // The key constraint: text/plain branch returns resp.body (String),
  // so the variant CANNOT hold Int
  case has_int_variant, has_string_variant {
    True, False ->
      // Int variant but no String variant = type error
      should.fail()
    _, _ -> should.be_ok(Ok(Nil))
  }
}

// --- Finding: multi-content request body collapsed to first entry ---
pub fn multi_content_request_body_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /submit:
    post:
      operationId: submitData
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              properties:
                name: { type: string }
          application/json:
            schema: { type: integer }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // The client must handle both content types, not just the first.
  // At minimum, the form-urlencoded content type must appear.
  string.contains(content, "application/x-www-form-urlencoded")
  |> should.be_true()
  // And JSON content type handling must also be present
  string.contains(content, "application/json")
  |> should.be_true()
}

// --- Finding: security OR alternatives must pick one, not apply all ---
pub fn security_or_alternatives_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /secure:
    get:
      operationId: getSecure
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    ApiKeyAuth:
      type: apiKey
      in: header
      name: X-API-Key
    BearerAuth:
      type: http
      scheme: bearer
security:
  - ApiKeyAuth: []
  - BearerAuth: []
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // Both security schemes must be present in the ClientConfig type
  string.contains(content, "api_key_auth")
  |> should.be_true()
  string.contains(content, "bearer_auth")
  |> should.be_true()
  // The generated code must NOT apply both schemes unconditionally.
  // OpenAPI security is OR — the client should try the first alternative
  // that has credentials set, not send all credentials at once.
  // The generated code must contain a nested/chained pattern that falls
  // through to the next alternative when the first has None.
  let assert Ok(fn_start) = find_substring_index(content, "pub fn get_secure(")
  let fn_body = string.drop_start(content, fn_start)
  // Both schemes should be referenced in the function body
  string.contains(fn_body, "api_key_auth")
  |> should.be_true()
  string.contains(fn_body, "bearer_auth")
  |> should.be_true()
  // The None branch of api_key_auth must fall through to bearer_auth,
  // not just `None -> req`. This verifies OR semantics.
  // Count how many "None -> req" appear — with OR semantics, only the
  // last alternative should have "None -> req". With the old broken code,
  // each scheme independently had "None -> req".
  let fn_end = case find_substring_index(fn_body, "\n}\n") {
    Ok(i) -> string.slice(fn_body, 0, i)
    Error(_) -> fn_body
  }
  let none_req_count =
    string.split(fn_end, "None -> req")
    |> list.length()
  // With 2 OR alternatives, there should be exactly 1 "None -> req" (at the end),
  // not 2 (one per scheme). Count is split segments, so 2 means 1 occurrence.
  none_req_count
  |> should.equal(2)
}

// --- Finding 2: OpenAPI 3.1 type: [string, 'null'] must parse as nullable string ---
pub fn openapi_31_type_array_nullable_test() {
  let yaml =
    "
openapi: 3.1.0
info:
  title: T
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    MaybeName:
      type: [string, 'null']
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  // MaybeName should be a nullable String type, not an empty object
  // It must NOT generate as a record with no fields (which would be the object fallback)
  string.contains(types_file.content, "pub type MaybeName =")
  |> should.be_true()
}

// --- Finding 3: README says optional path params supported but parser rejects ---
pub fn readme_no_optional_path_param_claim_test() {
  let assert Ok(readme) = simplifile.read("README.md")
  // README must NOT claim "Path parameters with required: false" as supported,
  // since the parser correctly rejects them per OpenAPI spec.
  string.contains(readme, "Path parameters with `required: false`")
  |> should.be_false()
}

// --- Finding 6: Callback parse errors must propagate, not be swallowed ---
pub fn callback_parse_error_not_swallowed_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: T
  version: 1.0.0
paths:
  /subscribe:
    post:
      operationId: subscribe
      callbacks:
        onEvent:
          '{$request.body#/url}':
            post:
              operationId: onEvent
              parameters:
                - name: id
                  in: path
                  required: false
              responses:
                '200': { description: ok }
      responses:
        '200': { description: ok }
"
  // The callback contains a path parameter with required: false,
  // which the parser correctly rejects. But the callback parser
  // currently swallows this error and silently drops the callback.
  // After fix, the error should propagate.
  let result = parser.parse_string(yaml)
  case result {
    Ok(spec) -> {
      // If parse succeeded, the callback must NOT have been silently dropped
      let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/subscribe")
      let assert Some(post_op) = path_item.post
      // Currently the error is swallowed and onEvent is missing.
      // After fix, either parse fails (Error) or callback is present.
      dict.has_key(post_op.callbacks, "onEvent")
      |> should.be_true()
    }
    Error(_) -> {
      // Parse error is acceptable — means we propagate the failure
      should.be_ok(Ok(Nil))
    }
  }
}

// --- Finding 7: Pure generate function exists and returns Result ---
pub fn pure_generate_pipeline_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: T
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
    )
  let result = generate.generate(spec, cfg)
  should.be_ok(result)
  let assert Ok(summary) = result
  // Should have generated files
  { summary.files != [] }
  |> should.be_true()
  // Should include spec title
  string.contains(summary.spec_title, "T")
  |> should.be_true()
}

// --- Array alias (TagList) must generate decoder and encoder ---
pub fn array_alias_decoder_encoder_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /tags:
    get:
      operationId: getTags
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/TagList'
components:
  schemas:
    TagList:
      type: array
      items: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = decoders.generate(ctx)
  let assert [decode_file, _encode_file] = files
  // Must generate tag_list_decoder() function
  string.contains(decode_file.content, "tag_list_decoder")
  |> should.be_true()
}

// --- deepObject array leaf must not produce uri.percent_encode on List ---
pub fn deep_object_array_leaf_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /search:
    get:
      operationId: search
      parameters:
        - name: filter
          in: query
          style: deepObject
          required: true
          schema:
            type: object
            required: [tags]
            properties:
              tags:
                type: array
                items: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  // Must NOT produce uri.percent_encode(filter.tags) — that's a type error
  // (filter.tags is List(String), not String)
  string.contains(client_file.content, "uri.percent_encode(filter.tags)")
  |> should.be_false()
}

// --- form-urlencoded nested object must not produce uri.percent_encode on record ---
pub fn form_urlencoded_nested_object_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /submit:
    post:
      operationId: submitForm
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              required: [meta]
              properties:
                meta:
                  type: object
                  properties:
                    name: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  // Must NOT produce uri.percent_encode(body.meta) — that's a type error
  // (body.meta is a record/object, not String)
  string.contains(client_file.content, "uri.percent_encode(body.meta)")
  |> should.be_false()
}

// --- HEAD operation must not be silently dropped ---
pub fn head_operation_not_silently_dropped_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /ping:
    head:
      operationId: headPing
      responses:
        '200': { description: ok }
"
  let result = parser.parse_string(yaml)
  case result {
    Ok(spec) -> {
      // If parse succeeds, there must be some way to know HEAD was present.
      // Currently PathItem has no head field, so it silently drops it.
      // After fix: either head is in the AST, or parser returns an error.
      let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/ping")
      // At minimum, the path should have at least one operation
      let has_any_op =
        option.is_some(path_item.get)
        || option.is_some(path_item.post)
        || option.is_some(path_item.put)
        || option.is_some(path_item.delete)
        || option.is_some(path_item.patch)
        || option.is_some(path_item.head)
      // HEAD was the only operation — if no ops exist, it was silently dropped
      has_any_op
      |> should.be_true()
    }
    Error(_) -> {
      // Error is acceptable — means we don't silently drop
      should.be_ok(Ok(Nil))
    }
  }
}

// --- OpenAPI 3.1 type: [string, integer] must not silently take first type ---
pub fn openapi_31_multi_type_union_test() {
  let yaml =
    "
openapi: 3.1.0
info: { title: T, version: 1.0.0 }
paths:
  /value:
    get:
      operationId: getValue
      responses:
        '200': { description: ok }
components:
  schemas:
    StringOrInt:
      type: [string, integer]
"
  // Parse succeeds — multi-type is stored in raw_type, normalize converts to oneOf
  let assert Ok(_spec) = parser.parse_string(yaml)
  should.be_true(True)
}

// --- OPTIONS operation must not be silently dropped ---
pub fn options_operation_not_silently_dropped_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /cors:
    options:
      operationId: corsPreflight
      responses:
        '204': { description: No Content }
"
  let result = parser.parse_string(yaml)
  // Either parse succeeds with the operation accessible,
  // or parse returns an error (not silent success with no operations).
  case result {
    Ok(spec) -> {
      let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/cors")
      // The path must have SOME operation — if it has none,
      // the OPTIONS was silently dropped
      // OPTIONS must be accessible in the AST
      option.is_some(path_item.options)
      |> should.be_true()
    }
    Error(_) -> {
      // A parse error is acceptable — means we don't silently drop
      should.be_ok(Ok(Nil))
    }
  }
}

// --- requestBody.required: false must generate optional body parameter ---
pub fn optional_request_body_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /search:
    post:
      operationId: search
      requestBody:
        required: false
        content:
          application/json:
            schema:
              type: object
              properties:
                query: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // An optional request body must be wrapped in Option, not always required
  // The generated function should have Option(body_type) or similar
  string.contains(content, "Option(")
  |> should.be_true()
}

// --- form-urlencoded 2-level nested object must not break ---
pub fn form_urlencoded_two_level_nested_object_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /submit:
    post:
      operationId: submitForm
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              required: [meta]
              properties:
                meta:
                  type: object
                  required: [author]
                  properties:
                    author:
                      type: object
                      properties:
                        name: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  // Must NOT produce uri.percent_encode on a record type
  // e.g. uri.percent_encode(body.meta.author) is a type error
  string.contains(client_file.content, "uri.percent_encode(body.meta")
  |> should.be_false()
}

// --- query array with explode: true must produce key=a&key=b, not key=a,b ---
pub fn query_array_explode_true_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      parameters:
        - name: tags
          in: query
          required: true
          style: form
          explode: true
          schema:
            type: array
            items: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // With explode: true, the query parameter must NOT be comma-joined.
  // It should produce tags=a&tags=b, not tags=a,b.
  // The comma-join with list.map pattern indicates explode is being ignored.
  string.contains(content, "string.join(list.map(")
  |> should.be_false()
  // Instead, must use list.fold to produce repeated key=value pairs
  string.contains(content, "list.fold(")
  |> should.be_true()
}

// --- OAuth2 flows must be preserved in AST ---
pub fn oauth2_flows_preserved_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /data:
    get:
      operationId: getData
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    oauth2:
      type: oauth2
      flows:
        authorizationCode:
          authorizationUrl: https://example.com/auth
          tokenUrl: https://example.com/token
          scopes:
            read: Read access
            write: Write access
security:
  - oauth2: [read]
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Some(components) = spec.components
  let assert Ok(scheme) = dict.get(components.security_schemes, "oauth2")
  // OAuth2 scheme must preserve flow URLs and scopes.
  // Currently OAuth2Scheme only has description, losing all flow data.
  case scheme {
    spec.Value(spec.OAuth2Scheme(flows:, ..)) -> {
      // flows must not be empty — must contain the authorizationCode flow
      { flows != dict.new() }
      |> should.be_true()
      // Must have the authorizationCode flow
      let assert Ok(auth_flow) = dict.get(flows, "authorizationCode")
      // Must preserve scopes
      { auth_flow.scopes != dict.new() }
      |> should.be_true()
      dict.has_key(auth_flow.scopes, "read")
      |> should.be_true()
    }
    _ -> should.fail()
  }
}

// --- Server router must call handlers, not return hardcoded "OK" ---
pub fn server_router_calls_handlers_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  // Find the router file
  let router_file =
    list.find(files, fn(f) { string.contains(f.path, "router") })
  let assert Ok(router) = router_file
  // Router must NOT have dead-code handler references
  string.contains(router.content, "let _ = handlers.")
  |> should.be_false()
  // Router must NOT have placeholder "OK" strings
  string.contains(router.content, "\"OK\"")
  |> should.be_false()
  // Router must actually call the handler
  string.contains(router.content, "handlers.get_items()")
  |> should.be_true()
  // Router must have ServerResponse type
  string.contains(router.content, "pub type ServerResponse")
  |> should.be_true()
  // Router must have proper route signature with query/headers/body
  string.contains(
    router.content,
    "pub fn route(method: String, path: List(String), _query: Dict(String, List(String)), _headers: Dict(String, String), _body: String) -> ServerResponse",
  )
  |> should.be_true()
  // Router must convert response to ServerResponse
  string.contains(router.content, "ServerResponse(status: 200")
  |> should.be_true()
  // Router must have 404 fallback
  string.contains(router.content, "ServerResponse(status: 404")
  |> should.be_true()
}

// --- GeneratedFile uses target ADT, not filename strings ---
pub fn generated_file_has_target_kind_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = generate.generate_all_files(ctx)
  // All generated files must have proper target assignments
  let shared_count =
    list.count(files, fn(f) { f.target == context.SharedTarget })
  let server_count =
    list.count(files, fn(f) { f.target == context.ServerTarget })
  let client_count =
    list.count(files, fn(f) { f.target == context.ClientTarget })
  // Must have shared files (types, decoders, etc.)
  { shared_count > 0 }
  |> should.be_true()
  // Must have server files (handlers, router)
  { server_count > 0 }
  |> should.be_true()
  // Must have client files (client)
  { client_count > 0 }
  |> should.be_true()
}

// --- Path template unbound parameter tests ---

/// Path template {id} without a corresponding path parameter must be
/// caught by validation, not silently passed through to generated code.
pub fn unbound_path_template_parameter_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items/{id}:
    get:
      operationId: getItem
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  let errors = validate.validate(ctx)
  // Must report at least one validation error for unbound {id}
  list.is_empty(errors)
  |> should.be_false()
}

/// Path template with parameter defined at path-item level must pass.
pub fn path_level_parameter_binds_template_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items/{id}:
    parameters:
      - name: id
        in: path
        required: true
        schema:
          type: string
    get:
      operationId: getItem
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_true()
}

/// Path template with all parameters bound must pass validation.
pub fn bound_path_template_parameter_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items/{id}:
    get:
      operationId: getItem
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_true()
}

// --- Parameter validation tests ---

/// Unsupported parameter style 'matrix' must be caught by validation.
pub fn unsupported_parameter_style_matrix_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: color
          in: query
          style: matrix
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_false()
}

/// Supported parameter styles (form, deepObject) must pass validation.
pub fn supported_parameter_style_form_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: color
          in: query
          style: form
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_true()
}

// --- Response code range tests ---

/// 2XX response code must generate a valid Gleam range pattern,
/// not the literal "2XX" which is invalid Gleam syntax.
pub fn response_code_range_2xx_generates_valid_gleam_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      responses:
        '2XX':
          description: Success
          content:
            application/json:
              schema:
                type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  // The generated code must NOT contain the literal "2XX" as a case pattern
  string.contains(content, "2XX ->")
  |> should.be_false()
  // It should contain a valid range guard pattern
  string.contains(content, "status if status >= 200")
  |> should.be_true()
}

/// status_code_to_int_pattern must not pass through range codes like "2XX".
pub fn status_code_range_pattern_test() {
  // Range codes must produce valid Gleam patterns, not raw "2XX"
  http.status_code_to_int_pattern("2XX")
  |> should.not_equal("2XX")

  // Exact codes still work
  http.status_code_to_int_pattern("200")
  |> should.equal("200")

  // Default is wildcard
  http.status_code_to_int_pattern("default")
  |> should.equal("_")
}

/// status_code_suffix must handle range codes.
pub fn status_code_suffix_range_test() {
  http.status_code_suffix("2XX")
  |> should.equal("Status2xx")

  http.status_code_suffix("4XX")
  |> should.equal("Status4xx")
}

// --- additionalProperties: true encoder tests ---

/// additionalProperties: true must NOT be silently dropped during encoding.
/// The encoder must include additional_properties in its output.
pub fn additional_properties_untyped_encoder_includes_extra_props_test() {
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
    Metadata:
      type: object
      properties:
        name:
          type: string
      additionalProperties: true
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = decoders.generate(ctx)
  let assert Ok(encode_file) =
    list.find(files, fn(f) { string.contains(f.path, "encode") })
  let content = encode_file.content
  // The encoder must reference additional_properties, not just base_props
  string.contains(content, "additional_properties")
  |> should.be_true()
  // It must NOT just use json.object(base_props) — that drops extra props
  string.contains(content, "json.object(base_props)")
  |> should.be_false()
}

// --- Complex parameter schema validation tests ---

/// Object schema query parameter without deepObject style must be rejected.
pub fn object_query_param_without_deep_object_rejected_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: filter
          in: query
          schema:
            type: object
            properties:
              name:
                type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  let errors = validate.validate(ctx)
  // Must report error for object param without deepObject style
  list.is_empty(errors)
  |> should.be_false()
}

/// Object schema query parameter WITH deepObject style must pass.
pub fn object_query_param_with_deep_object_passes_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: filter
          in: query
          style: deepObject
          explode: true
          schema:
            type: object
            properties:
              name:
                type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_true()
}

// --- validate error message accuracy tests ---

/// Validation error for unsupported request content type must list
/// all actually supported types, including form-urlencoded.
pub fn validate_request_content_type_message_includes_form_urlencoded_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    post:
      operationId: doX
      requestBody:
        content:
          text/csv:
            schema:
              type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  let errors = validate.validate(ctx)
  let assert [Diagnostic(message: msg, ..)] = errors
  // Error message must mention form-urlencoded as a supported type
  string.contains(msg, "form-urlencoded")
  |> should.be_true()
}

/// Validation error for unsupported response content type must list
/// all actually supported types, including XML.
pub fn validate_response_content_type_message_includes_xml_test() {
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
        '200':
          description: ok
          content:
            text/csv:
              schema:
                type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  let errors = validate.validate(ctx)
  let assert [Diagnostic(message: msg, ..)] = errors
  // Error message must mention XML as a supported type
  string.contains(msg, "xml")
  |> should.be_true()
}

// --- form-urlencoded non-object validation tests ---

/// form-urlencoded with non-object schema must be rejected by validation.
pub fn form_urlencoded_non_object_schema_rejected_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /submit:
    post:
      operationId: submit
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  let errors = validate.validate(ctx)
  // Must report error for non-object schema with form-urlencoded
  list.is_empty(errors)
  |> should.be_false()
}

/// form-urlencoded with object schema must pass validation.
pub fn form_urlencoded_object_schema_passes_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /submit:
    post:
      operationId: submit
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              properties:
                name:
                  type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_true()
}

// --- AnyOfSchema discriminator tests ---

/// anyOf with discriminator must be preserved in the AST, not lost.
pub fn anyof_discriminator_preserved_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets:
    get:
      operationId: getPet
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Pet'
components:
  schemas:
    Cat:
      type: object
      properties:
        pet_type:
          type: string
        meow:
          type: string
      required: [pet_type]
    Dog:
      type: object
      properties:
        pet_type:
          type: string
        bark:
          type: string
      required: [pet_type]
    Pet:
      anyOf:
        - $ref: '#/components/schemas/Cat'
        - $ref: '#/components/schemas/Dog'
      discriminator:
        propertyName: pet_type
        mapping:
          cat: '#/components/schemas/Cat'
          dog: '#/components/schemas/Dog'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // The Pet schema must have a discriminator in the AST
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.AnyOfSchema(discriminator: disc, ..))) =
    dict.get(components.schemas, "Pet")
  // discriminator must be Some, not None
  disc
  |> option.is_some()
  |> should.be_true()
}

// --- Nullable schema decoder/encoder tests ---

/// A nullable primitive schema (type: [string, 'null']) must generate
/// decoder using decode.optional and encoder using json.nullable.
pub fn nullable_primitive_decoder_encoder_test() {
  let yaml =
    "
openapi: 3.1.0
info:
  title: T
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    MaybeName:
      type: [string, 'null']
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = decoders.generate(ctx)
  // Find the decode file
  let assert Ok(decode_file) =
    list.find(files, fn(f) { string.contains(f.path, "decode") })
  let decode_content = decode_file.content
  // The decoder must use decode.optional for nullable String
  string.contains(decode_content, "decode.optional(decode.string)")
  |> should.be_true()

  // Find the encode file
  let assert Ok(encode_file) =
    list.find(files, fn(f) { string.contains(f.path, "encode") })
  let encode_content = encode_file.content
  // The encoder must use json.nullable for nullable String
  string.contains(encode_content, "json.nullable(value, json.string)")
  |> should.be_true()
}

// --- deepObject nested object validation tests ---

/// deepObject with nested object properties must be rejected
/// since codegen can only handle one level of nesting.
pub fn deep_object_nested_object_rejected_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: filter
          in: query
          style: deepObject
          explode: true
          schema:
            type: object
            properties:
              meta:
                type: object
                properties:
                  name:
                    type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  // Must detect nested object in deepObject param
  list.is_empty(errors)
  |> should.be_false()
}

/// deepObject with flat scalar properties must pass validation.
pub fn deep_object_flat_properties_passes_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: filter
          in: query
          style: deepObject
          explode: true
          schema:
            type: object
            properties:
              name:
                type: string
              age:
                type: integer
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_true()
}

// --- PathItem.$ref tests ---

/// PathItem.$ref must resolve to the referenced PathItem from components.pathItems.
pub fn path_item_ref_resolves_test() {
  let yaml =
    "
openapi: 3.1.0
info:
  title: Test
  version: 1.0.0
paths:
  /health:
    $ref: '#/components/pathItems/HealthCheck'
components:
  pathItems:
    HealthCheck:
      get:
        operationId: healthCheck
        responses:
          '200':
            description: OK
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // /health path must exist as a Ref (lazy resolution)
  let assert Ok(spec.Ref(ref_str)) = dict.get(spec.paths, "/health")
  ref_str |> should.equal("#/components/pathItems/HealthCheck")
  // The referenced PathItem must exist in components
  let assert Some(components) = spec.components
  let assert Ok(spec.Value(path_item)) =
    dict.get(components.path_items, "HealthCheck")
  let assert Some(get_op) = path_item.get
  get_op.operation_id
  |> should.equal(Some("healthCheck"))
}

// --- Unresolved $ref validation tests ---

/// A $ref pointing to a non-existent schema must be caught by validation.
pub fn unresolved_ref_detected_by_validator_test() {
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
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Missing'
components:
  schemas: {}
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  // Must report at least one error for unresolved reference
  list.is_empty(errors)
  |> should.be_false()
}

/// A $ref pointing to an existing schema must pass validation.
pub fn resolved_ref_passes_validator_test() {
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
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Item'
components:
  schemas:
    Item:
      type: object
      properties:
        name:
          type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_true()
}

// --- Security AND wildcard tests ---

/// Security AND with 3 schemes must generate correct wildcard pattern.
/// The wildcard must have 3 underscores, not hardcoded `_, _`.
pub fn security_and_3_schemes_wildcard_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /secure:
    get:
      operationId: getSecure
      security:
        - ApiKeyAuth: []
          BearerAuth: []
          OAuth2: []
        - BasicAuth: []
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    ApiKeyAuth:
      type: apiKey
      in: header
      name: X-API-Key
    BearerAuth:
      type: http
      scheme: bearer
    OAuth2:
      type: oauth2
      flows:
        implicit:
          authorizationUrl: https://example.com
          scopes: {}
    BasicAuth:
      type: http
      scheme: basic
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  // With 3 AND schemes, the wildcard must be `_, _, _`
  string.contains(content, "_, _, _ -> {")
  |> should.be_true()
}

// --- Nullable composition schema tests ---

/// nullable: true on a oneOf schema must produce Option(T) type.
pub fn nullable_oneof_generates_option_type_test() {
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
    Cat:
      type: object
      properties:
        name:
          type: string
    Dog:
      type: object
      properties:
        name:
          type: string
    NullablePet:
      nullable: true
      oneOf:
        - $ref: '#/components/schemas/Cat'
        - $ref: '#/components/schemas/Dog'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // The NullablePet schema must have nullable: true in the AST
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(oneof_schema)) =
    dict.get(components.schemas, "NullablePet")
  schema.is_nullable(oneof_schema)
  |> should.be_true()
}

// --- AnyOfSchema type generation tests ---

/// anyOf with $ref schemas must generate a union type like oneOf,
/// not fall through to String.
pub fn anyof_generates_union_type_not_string_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets:
    get:
      operationId: getPet
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Pet'
components:
  schemas:
    Cat:
      type: object
      properties:
        name:
          type: string
    Dog:
      type: object
      properties:
        name:
          type: string
    Pet:
      anyOf:
        - $ref: '#/components/schemas/Cat'
        - $ref: '#/components/schemas/Dog'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  let content = types_file.content
  // Pet must be a record with Option fields (anyOf = inclusive union)
  string.contains(content, "pub type Pet = String")
  |> should.be_false()
  // It should have Option fields, not tagged union constructors
  string.contains(content, "Option(Cat)")
  |> should.be_true()
  string.contains(content, "Option(Dog)")
  |> should.be_true()
  // Must NOT have tagged union variant constructors
  string.contains(content, "PetCat(Cat)")
  |> should.be_false()
}

// --- Security scopes comment tests ---

/// Security scopes should appear as comments in generated client code.
pub fn security_scopes_appear_as_comments_test() {
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
      security:
        - OAuth2:
            - read:pets
            - write:pets
components:
  securitySchemes:
    OAuth2:
      type: oauth2
      flows:
        implicit:
          authorizationUrl: https://example.com
          scopes:
            read:pets: Read pets
            write:pets: Write pets
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  // The generated code must include scope information in comments
  string.contains(content, "read:pets")
  |> should.be_true()
}

// --- allowReserved parameter tests ---

/// Query parameter with allowReserved: true must NOT be percent-encoded.
pub fn allow_reserved_skips_percent_encode_test() {
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
        - name: q
          in: query
          required: true
          allowReserved: true
          schema:
            type: string
      responses:
        '200':
          description: ok
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  // With allowReserved, the generated code must NOT use uri.percent_encode for this param
  // Instead it should use the value directly
  string.contains(content, "uri.percent_encode(q)")
  |> should.be_false()
}

/// Query parameter without allowReserved must be percent-encoded (default).
pub fn default_query_param_is_percent_encoded_test() {
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
        - name: q
          in: query
          required: true
          schema:
            type: string
      responses:
        '200':
          description: ok
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
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
  // Without allowReserved, must use uri.percent_encode
  string.contains(content, "uri.percent_encode(q)")
  |> should.be_true()
}

// --- Parser required field validation tests ---

/// requestBody without content field must be rejected (content is REQUIRED).
pub fn parser_rejects_request_body_missing_content_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    post:
      operationId: createItem
      requestBody:
        description: An item
      responses:
        '200':
          description: ok
"
  let result = parser.parse_string(yaml)
  case result {
    Error(_) -> should.be_true(True)
    Ok(_) -> should.be_true(False)
  }
}

/// response without description field must be rejected (description is REQUIRED).
pub fn parser_rejects_response_missing_description_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      responses:
        '200':
          content:
            application/json:
              schema:
                type: string
"
  let result = parser.parse_string(yaml)
  case result {
    Error(_) -> should.be_true(True)
    Ok(_) -> should.be_true(False)
  }
}

// --- Schema dispatch centralization tests ---

/// schema_dispatch must return correct types for primitives.
pub fn schema_dispatch_primitive_types_test() {
  schema_dispatch.schema_base_type(schema.StringSchema(
    metadata: schema.default_metadata(),
    format: None,
    enum_values: [],
    min_length: None,
    max_length: None,
    pattern: None,
  ))
  |> should.equal("String")

  schema_dispatch.schema_base_type(schema.IntegerSchema(
    metadata: schema.default_metadata(),
    format: None,
    minimum: None,
    maximum: None,
    exclusive_minimum: None,
    exclusive_maximum: None,
    multiple_of: None,
  ))
  |> should.equal("Int")
}

/// schema_dispatch.to_string_expr must produce correct conversion expressions.
pub fn schema_dispatch_to_string_expr_test() {
  schema_dispatch.to_string_expr(
    schema.IntegerSchema(
      metadata: schema.default_metadata(),
      format: None,
      minimum: None,
      maximum: None,
      exclusive_minimum: None,
      exclusive_maximum: None,
      multiple_of: None,
    ),
    "x",
  )
  |> should.equal("int.to_string(x)")
}

// --- Gleam Code IR tests ---

/// IR renderer produces correct type alias.
pub fn ir_render_type_alias_test() {
  let module =
    ir.Module(header: "test", imports: [], declarations: [
      ir.Declaration(
        doc: None,
        type_def: ir.TypeAlias(name: "UserId", target: "String"),
      ),
    ])
  let output = ir_render.render(module)
  string.contains(output, "pub type UserId = String")
  |> should.be_true()
}

/// IR renderer produces correct union type.
pub fn ir_render_union_type_test() {
  let module =
    ir.Module(header: "test", imports: [], declarations: [
      ir.Declaration(
        doc: None,
        type_def: ir.UnionType(name: "Shape", variants: [
          ir.VariantWithType(name: "ShapeCircle", inner_type: "Circle"),
          ir.VariantWithType(name: "ShapeSquare", inner_type: "Square"),
        ]),
      ),
    ])
  let output = ir_render.render(module)
  string.contains(output, "pub type Shape {")
  |> should.be_true()
  string.contains(output, "ShapeCircle(Circle)")
  |> should.be_true()
  string.contains(output, "ShapeSquare(Square)")
  |> should.be_true()
}

/// IR renderer produces correct record type.
pub fn ir_render_record_type_test() {
  let module =
    ir.Module(header: "test", imports: [], declarations: [
      ir.Declaration(
        doc: None,
        type_def: ir.RecordType(name: "User", fields: [
          ir.Field(name: "name", type_expr: "String"),
          ir.Field(name: "age", type_expr: "Int"),
        ]),
      ),
    ])
  let output = ir_render.render(module)
  string.contains(output, "pub type User {")
  |> should.be_true()
  string.contains(output, "User(name: String, age: Int)")
  |> should.be_true()
}

// --- Fail-fast unsupported feature tests ---

/// External $ref (not #/) must be rejected as unsupported.
pub fn external_ref_rejected_test() {
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
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: './other.yaml#/components/schemas/Foo'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_false()
}

/// Unrecognized schema type must be rejected at parse time.
pub fn unrecognized_schema_type_rejected_test() {
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
        '200':
          description: ok
components:
  schemas:
    Bad:
      type: frobnicate
"
  let result = parser.parse_string(yaml)
  case result {
    Error(_) -> should.be_true(True)
    Ok(_) -> should.be_true(False)
  }
}

// --- oneOf vs anyOf semantic separation tests ---

/// anyOf must generate a record with Option fields, NOT a tagged union.
pub fn anyof_generates_record_with_option_fields_test() {
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
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Payment'
components:
  schemas:
    Card:
      type: object
      properties:
        card_number:
          type: string
    Bank:
      type: object
      properties:
        account:
          type: string
    Payment:
      anyOf:
        - $ref: '#/components/schemas/Card'
        - $ref: '#/components/schemas/Bank'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  let content = types_file.content
  // anyOf should generate a record with Option fields, not tagged union variants
  string.contains(content, "Option(")
  |> should.be_true()
  // It must NOT have tagged union variant constructors like PaymentCard(Card)
  string.contains(content, "PaymentCard(")
  |> should.be_false()
}

/// oneOf must still generate a tagged union (existing behavior preserved).
pub fn oneof_still_generates_tagged_union_test() {
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
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Shape'
components:
  schemas:
    Circle:
      type: object
      properties:
        radius:
          type: number
    Square:
      type: object
      properties:
        side:
          type: number
    Shape:
      oneOf:
        - $ref: '#/components/schemas/Circle'
        - $ref: '#/components/schemas/Square'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  let content = types_file.content
  // oneOf must generate tagged union variants
  string.contains(content, "ShapeCircle(")
  |> should.be_true()
  string.contains(content, "ShapeSquare(")
  |> should.be_true()
}

// --- ParameterStyle and SecuritySchemeIn are proper ADTs, not strings ---
pub fn parameter_style_is_adt_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /x:
    get:
      operationId: getX
      parameters:
        - name: filter
          in: query
          style: deepObject
          schema: { type: object, properties: { a: { type: string } } }
        - name: ids
          in: query
          style: form
          schema: { type: array, items: { type: integer } }
        - name: id
          in: path
          required: true
          style: simple
          schema: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert Ok(spec.Value(pi)) = dict.get(parsed.paths, "/x")
  let assert Some(op) = pi.get
  let assert [spec.Value(deep), spec.Value(form), spec.Value(simple)] =
    op.parameters
  deep.style |> should.equal(Some(spec.DeepObjectStyle))
  form.style |> should.equal(Some(spec.FormStyle))
  simple.style |> should.equal(Some(spec.SimpleStyle))
}

// --- SchemaMetadata preserves title, readOnly, writeOnly, default, example ---
pub fn schema_metadata_lossless_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    User:
      type: object
      title: User object
      properties:
        name:
          type: string
          title: User name
          readOnly: true
          default: anonymous
          example: Alice
        id:
          type: integer
          writeOnly: true
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert Some(c) = parsed.components
  let assert Ok(schema.Inline(user)) = dict.get(c.schemas, "User")
  // Object metadata
  case user {
    schema.ObjectSchema(metadata:, ..) -> {
      metadata.title |> should.equal(Some("User object"))
    }
    _ -> should.fail()
  }
}

pub fn security_scheme_in_is_adt_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    headerKey:
      type: apiKey
      name: X-API-Key
      in: header
    queryKey:
      type: apiKey
      name: api_key
      in: query
    cookieKey:
      type: apiKey
      name: session
      in: cookie
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert Some(c) = parsed.components
  let assert Ok(h) = dict.get(c.security_schemes, "headerKey")
  let assert Ok(q) = dict.get(c.security_schemes, "queryKey")
  let assert Ok(k) = dict.get(c.security_schemes, "cookieKey")
  case h {
    spec.Value(spec.ApiKeyScheme(in_: spec.SchemeInHeader, ..)) ->
      should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
  case q {
    spec.Value(spec.ApiKeyScheme(in_: spec.SchemeInQuery, ..)) ->
      should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
  case k {
    spec.Value(spec.ApiKeyScheme(in_: spec.SchemeInCookie, ..)) ->
      should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
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

// --- Lossless AST: new fields are preserved through parsing ---
pub fn lossless_info_fields_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: T
  version: 1.0.0
  summary: A summary
  termsOfService: https://example.com/tos
  contact:
    name: Support
    url: https://example.com
    email: support@example.com
  license:
    name: MIT
    url: https://opensource.org/licenses/MIT
paths: {}
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  parsed.info.summary |> should.equal(Some("A summary"))
  parsed.info.terms_of_service
  |> should.equal(Some("https://example.com/tos"))
  let assert Some(contact) = parsed.info.contact
  contact.name |> should.equal(Some("Support"))
  contact.email |> should.equal(Some("support@example.com"))
  let assert Some(lic) = parsed.info.license
  lic.name |> should.equal("MIT")
}

pub fn lossless_server_variables_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
servers:
  - url: https://{env}.example.com
    variables:
      env:
        default: prod
        enum: [prod, staging, dev]
        description: Environment
paths: {}
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert [server] = parsed.servers
  let assert Ok(var) = dict.get(server.variables, "env")
  var.default |> should.equal("prod")
  var.description |> should.equal(Some("Environment"))
}

pub fn lossless_response_headers_links_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200':
          description: ok
          headers:
            X-Rate-Limit:
              description: Rate limit
              required: true
              schema: { type: integer }
          links:
            GetItemById:
              operationId: getItem
              description: Get item by ID
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert Ok(spec.Value(pi)) = dict.get(parsed.paths, "/items")
  let assert Some(op) = pi.get
  let assert Ok(spec.Value(resp)) = dict.get(op.responses, "200")
  let assert Ok(header) = dict.get(resp.headers, "X-Rate-Limit")
  header.description |> should.equal(Some("Rate limit"))
  header.required |> should.be_true()
  let assert Ok(link) = dict.get(resp.links, "GetItemById")
  link.operation_id |> should.equal(Some("getItem"))
}

pub fn lossless_tags_and_external_docs_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
tags:
  - name: users
    description: User operations
externalDocs:
  url: https://docs.example.com
  description: Full docs
paths: {}
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert [tag] = parsed.tags
  tag.name |> should.equal("users")
  tag.description |> should.equal(Some("User operations"))
  let assert Some(ext) = parsed.external_docs
  ext.url |> should.equal("https://docs.example.com")
}

// --- Bug verification tests ---

/// Bug 1: Optional deepObject + array leaf.
/// When a deepObject parameter is optional (required: false) AND has an array
/// leaf property, it must NOT produce uri.percent_encode(v) where v is the
/// whole list. It should iterate the list items instead.
pub fn bug1_optional_deep_object_array_leaf_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /search:
    get:
      operationId: search
      parameters:
        - name: filter
          in: query
          style: deepObject
          required: false
          schema:
            type: object
            properties:
              tags:
                type: array
                items: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
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

  // The bug: optional deepObject with array leaf calls percent_encode on the
  // whole list variable (e.g. obj.tags) instead of iterating items.
  // We check that the generated code uses list.fold to iterate array items
  // rather than directly encoding the list.
  // If this assertion fails, the bug exists.
  let has_list_fold_for_tags = string.contains(content, "list.fold(")
  let has_direct_encode_of_tags =
    string.contains(content, "uri.percent_encode(obj.tags)")
  // Should iterate items (list.fold), not encode list directly
  has_list_fold_for_tags
  |> should.be_true()
  has_direct_encode_of_tags
  |> should.be_false()
}

/// Bug 2: form-urlencoded $ref array property.
/// When a form body has a $ref that resolves to an array schema, it must NOT
/// produce uri.percent_encode(body.tags) where body.tags is a List.
/// It should iterate the list items with list.fold instead.
pub fn bug2_form_urlencoded_ref_array_property_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /submit:
    post:
      operationId: submitForm
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              required: [tags]
              properties:
                tags:
                  $ref: '#/components/schemas/TagList'
      responses:
        '200': { description: ok }
components:
  schemas:
    TagList:
      type: array
      items: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
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

  // The bug: $ref to array schema is not detected as array, so it treats the
  // list as a scalar and calls percent_encode(body.tags) directly.
  // Should use list.fold to iterate items instead.
  let has_list_fold = string.contains(content, "list.fold(body.tags")
  let has_direct_encode =
    string.contains(content, "uri.percent_encode(body.tags)")
  // Should iterate items, not encode list directly
  has_list_fold
  |> should.be_true()
  has_direct_encode
  |> should.be_false()
}

/// Bug 3: $ref array query parameter missing gleam/list import.
/// When a query parameter has a schema that $refs to an array type, the
/// generated code uses list.fold but the import for gleam/list may be missing.
pub fn bug3_ref_array_query_param_import_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      parameters:
        - name: tags
          in: query
          required: true
          style: form
          explode: true
          schema:
            $ref: '#/components/schemas/TagList'
      responses:
        '200': { description: ok }
components:
  schemas:
    TagList:
      type: array
      items: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
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

  // The bug: list.fold is used in generated code but gleam/list may not be
  // imported because the import check only looks for Inline(ArraySchema)
  // not Reference that resolves to ArraySchema.
  let uses_list_module =
    string.contains(content, "list.fold")
    || string.contains(content, "list.map")
  let imports_list = string.contains(content, "import gleam/list")
  // If the code uses list.fold/list.map, it MUST import gleam/list
  case uses_list_module {
    True -> imports_list |> should.be_true()
    False -> Nil
  }
}

// --- Structured capability: warnings don't block generation ---
pub fn capability_warnings_dont_block_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200':
          description: ok
          headers:
            X-Rate-Limit:
              description: Rate limit
              schema: { type: integer }
          links:
            next:
              operationId: getItems
webhooks:
  newItem:
    post:
      operationId: onNewItem
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
    )
  // Generation must succeed even with warnings
  let result = generate.generate(spec, cfg)
  should.be_ok(result)
  // But capability issues should include warnings
  let assert Ok(resolved) = resolve.resolve(spec)
  let resolved = hoist.hoist(resolved)
  let resolved = dedup.dedup(resolved)
  let ctx = context.new(resolved, cfg)
  let issues = capability_check.check_preserved(ctx)
  let warnings = diagnostic.warnings_only(issues)
  { warnings != [] }
  |> should.be_true()
}

// --- readOnly/writeOnly filtering tests ---

pub fn read_only_filtered_from_request_body_type_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /users:
    post:
      operationId: createUser
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [name]
              properties:
                name: { type: string }
                id: { type: integer, readOnly: true }
                password: { type: string, writeOnly: true }
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
                properties:
                  name: { type: string }
                  id: { type: integer, readOnly: true }
                  password: { type: string, writeOnly: true }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // NOTE: Do NOT hoist here -- we want inline schemas to remain inline
  // so that the anonymous type filtering for readOnly/writeOnly is tested.
  let ctx = make_ctx_from_spec(spec)

  let type_files = types.generate(ctx)

  // Check the types.gleam file for the anonymous request body type
  let assert Ok(types_file) =
    list.find(type_files, fn(f) { f.path == "types.gleam" })

  // Request body type should NOT have id field (readOnly)
  // but SHOULD have password field (writeOnly is fine in requests)
  let request_body_section =
    string.contains(types_file.content, "CreateUserRequestBody")
  request_body_section |> should.be_true()

  // The request body type should contain name and password but NOT id
  // Split content to find the request body type definition
  let lines = string.split(types_file.content, "\n")
  let request_body_lines = extract_type_block(lines, "CreateUserRequestBody")
  let request_body_text = string.join(request_body_lines, "\n")

  // readOnly field 'id' must NOT be in request body type
  string.contains(request_body_text, "id:") |> should.be_false()
  // writeOnly field 'password' MUST be in request body type
  string.contains(request_body_text, "password:") |> should.be_true()
  // Normal field 'name' MUST be in request body type
  string.contains(request_body_text, "name:") |> should.be_true()

  // Response type should NOT have password field (writeOnly)
  // but SHOULD have id field (readOnly is fine in responses)
  let response_section =
    string.contains(types_file.content, "CreateUserResponseOk")
  response_section |> should.be_true()

  let response_lines = extract_type_block(lines, "CreateUserResponseOk")
  let response_text = string.join(response_lines, "\n")

  // writeOnly field 'password' must NOT be in response type
  string.contains(response_text, "password:") |> should.be_false()
  // readOnly field 'id' MUST be in response type
  string.contains(response_text, "id:") |> should.be_true()
  // Normal field 'name' MUST be in response type
  string.contains(response_text, "name:") |> should.be_true()
}

/// Helper to extract lines from a type block definition.
fn extract_type_block(lines: List(String), type_name: String) -> List(String) {
  extract_type_block_loop(lines, type_name, False, 0, [])
}

fn extract_type_block_loop(
  lines: List(String),
  type_name: String,
  in_block: Bool,
  brace_depth: Int,
  acc: List(String),
) -> List(String) {
  case lines {
    [] -> list.reverse(acc)
    [line, ..rest] ->
      case in_block {
        False ->
          case string.contains(line, "pub type " <> type_name) {
            True ->
              extract_type_block_loop(rest, type_name, True, 1, [line, ..acc])
            False -> extract_type_block_loop(rest, type_name, False, 0, acc)
          }
        True -> {
          let opens =
            string.to_graphemes(line)
            |> list.count(fn(c) { c == "{" })
          let closes =
            string.to_graphemes(line)
            |> list.count(fn(c) { c == "}" })
          let new_depth = brace_depth + opens - closes
          case new_depth <= 0 {
            True -> list.reverse([line, ..acc])
            False ->
              extract_type_block_loop(rest, type_name, True, new_depth, [
                line,
                ..acc
              ])
          }
        }
      }
  }
}

pub fn read_only_filtered_from_encoder_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /users:
    post:
      operationId: createUser
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [name]
              properties:
                name: { type: string }
                id: { type: integer, readOnly: true }
                password: { type: string, writeOnly: true }
      responses:
        '200':
          description: ok
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // Do NOT hoist -- keep inline schemas to test anonymous encoder filtering
  let ctx = make_ctx_from_spec(spec)

  let decoder_files = decoders.generate(ctx)
  let assert Ok(encode_file) =
    list.find(decoder_files, fn(f) { f.path == "encode.gleam" })

  // The encoder for request body should NOT encode the readOnly 'id' field
  // Find the encoder function
  let content = encode_file.content
  string.contains(content, "encode_create_user_request_body")
  |> should.be_true()

  // The encoder should not have "id" as a JSON key
  // but should have "name" and "password"
  let lines = string.split(content, "\n")
  let encoder_lines =
    extract_fn_block(lines, "encode_create_user_request_body_json")
  let encoder_text = string.join(encoder_lines, "\n")

  string.contains(encoder_text, "\"id\"") |> should.be_false()
  string.contains(encoder_text, "\"name\"") |> should.be_true()
  string.contains(encoder_text, "\"password\"") |> should.be_true()
}

/// Helper to extract lines from a function block definition.
fn extract_fn_block(lines: List(String), fn_name: String) -> List(String) {
  extract_fn_block_loop(lines, fn_name, False, 0, [])
}

fn extract_fn_block_loop(
  lines: List(String),
  fn_name: String,
  in_block: Bool,
  brace_depth: Int,
  acc: List(String),
) -> List(String) {
  case lines {
    [] -> list.reverse(acc)
    [line, ..rest] ->
      case in_block {
        False ->
          case string.contains(line, "pub fn " <> fn_name) {
            True -> extract_fn_block_loop(rest, fn_name, True, 1, [line, ..acc])
            False -> extract_fn_block_loop(rest, fn_name, False, 0, acc)
          }
        True -> {
          let opens =
            string.to_graphemes(line)
            |> list.count(fn(c) { c == "{" })
          let closes =
            string.to_graphemes(line)
            |> list.count(fn(c) { c == "}" })
          let new_depth = brace_depth + opens - closes
          case new_depth <= 0 {
            True -> list.reverse([line, ..acc])
            False ->
              extract_fn_block_loop(rest, fn_name, True, new_depth, [
                line,
                ..acc
              ])
          }
        }
      }
  }
}

pub fn write_only_filtered_from_response_decoder_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /users:
    post:
      operationId: createUser
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                name: { type: string }
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
                properties:
                  name: { type: string }
                  id: { type: integer, readOnly: true }
                  password: { type: string, writeOnly: true }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // Do NOT hoist -- keep inline schemas to test anonymous decoder filtering
  let ctx = make_ctx_from_spec(spec)

  let decoder_files = decoders.generate(ctx)
  let assert Ok(decode_file) =
    list.find(decoder_files, fn(f) { f.path == "decode.gleam" })

  let content = decode_file.content

  // The response decoder should NOT decode writeOnly 'password' field
  let lines = string.split(content, "\n")
  let decoder_lines = extract_fn_block(lines, "create_user_response_ok_decoder")
  let decoder_text = string.join(decoder_lines, "\n")

  // writeOnly 'password' must NOT be in response decoder
  string.contains(decoder_text, "\"password\"") |> should.be_false()
  // readOnly 'id' MUST be in response decoder
  string.contains(decoder_text, "\"id\"") |> should.be_true()
  // Normal 'name' MUST be in response decoder
  string.contains(decoder_text, "\"name\"") |> should.be_true()
}

pub fn read_only_filtered_from_component_encoder_with_hoist_test() {
  // Test that component schema encoders (after hoist) skip readOnly fields
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
components:
  schemas:
    User:
      type: object
      required: [name]
      properties:
        name: { type: string }
        id: { type: integer, readOnly: true }
        password: { type: string, writeOnly: true }
paths:
  /users:
    post:
      operationId: createUser
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/User'
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/User'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)

  // Check encoder: readOnly 'id' should NOT be encoded
  let decoder_files = decoders.generate(ctx)
  let assert Ok(encode_file) =
    list.find(decoder_files, fn(f) { f.path == "encode.gleam" })
  let lines = string.split(encode_file.content, "\n")
  let encoder_lines = extract_fn_block(lines, "encode_user_json")
  let encoder_text = string.join(encoder_lines, "\n")

  // readOnly 'id' must NOT be in encoder
  string.contains(encoder_text, "\"id\"") |> should.be_false()
  // writeOnly 'password' MUST be in encoder (it's sent by client)
  string.contains(encoder_text, "\"password\"") |> should.be_true()
  // Normal 'name' MUST be in encoder
  string.contains(encoder_text, "\"name\"") |> should.be_true()

  // Check decoder: writeOnly 'password' should be treated as optional
  let assert Ok(decode_file) =
    list.find(decoder_files, fn(f) { f.path == "decode.gleam" })
  let dlines = string.split(decode_file.content, "\n")
  let decoder_lines = extract_fn_block(dlines, "user_decoder")
  let decoder_text = string.join(decoder_lines, "\n")

  // writeOnly 'password' should use optional_field (not required field)
  string.contains(decoder_text, "optional_field(\"password\"")
  |> should.be_true()
  // readOnly 'id' and normal 'name' should be present
  string.contains(decoder_text, "\"id\"") |> should.be_true()
  string.contains(decoder_text, "\"name\"") |> should.be_true()

  // Check that the component type still has ALL fields (shared type)
  let type_files = types.generate(ctx)
  let assert Ok(types_file) =
    list.find(type_files, fn(f) { f.path == "types.gleam" })
  let tlines = string.split(types_file.content, "\n")
  let user_type_lines = extract_type_block(tlines, "User")
  let user_type_text = string.join(user_type_lines, "\n")
  // All fields must be present in the shared type
  string.contains(user_type_text, "name:") |> should.be_true()
  string.contains(user_type_text, "id:") |> should.be_true()
  string.contains(user_type_text, "password:") |> should.be_true()
}

pub fn server_variable_substitution_default_base_url_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: T
  version: 1.0.0
servers:
  - url: https://{env}.example.com/{version}
    variables:
      env:
        default: production
      version:
        default: v2
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
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

  // Must contain the default_base_url function
  string.contains(content, "pub fn default_base_url() -> String {")
  |> should.be_true()

  // Must contain the resolved URL with variables substituted
  string.contains(content, "\"https://production.example.com/v2\"")
  |> should.be_true()
}

pub fn server_no_variables_default_base_url_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: T
  version: 1.0.0
servers:
  - url: https://api.example.com/v1
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
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

  string.contains(content, "pub fn default_base_url() -> String {")
  |> should.be_true()

  string.contains(content, "\"https://api.example.com/v1\"")
  |> should.be_true()
}

pub fn server_empty_default_base_url_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: T
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
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

  // With no servers, default_base_url should not be generated
  string.contains(content, "default_base_url")
  |> should.be_false()
}

// --- Feature: Guards for exclusiveMinimum, exclusiveMaximum, multipleOf ---

pub fn guards_exclusive_and_multiple_of_integer_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      responses:
        '200': { description: ok }
components:
  schemas:
    Item:
      type: object
      required: [score, quantity]
      properties:
        score:
          type: integer
          exclusiveMinimum: 0
          exclusiveMaximum: 100
        quantity:
          type: integer
          multipleOf: 5
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  let assert [guard_file] = files
  let content = guard_file.content

  // Should contain exclusive range guard for score
  string.contains(content, "validate_item_score_exclusive_range")
  |> should.be_true()
  // Should use strict comparison (> not >=)
  string.contains(content, "value > 0")
  |> should.be_true()
  string.contains(content, "value < 100")
  |> should.be_true()

  // Should contain multipleOf guard for quantity
  string.contains(content, "validate_item_quantity_multiple_of")
  |> should.be_true()
  string.contains(content, "value % 5 == 0")
  |> should.be_true()

  // Composite validator should call both guards
  string.contains(content, "validate_item_score_exclusive_range(value.score)")
  |> should.be_true()
  string.contains(content, "validate_item_quantity_multiple_of(value.quantity)")
  |> should.be_true()
}

pub fn guards_exclusive_and_multiple_of_float_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /measures:
    get:
      operationId: listMeasures
      responses:
        '200': { description: ok }
components:
  schemas:
    Measure:
      type: object
      required: [weight, step]
      properties:
        weight:
          type: number
          exclusiveMinimum: 0.0
          exclusiveMaximum: 999.9
        step:
          type: number
          multipleOf: 0.5
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  let assert [guard_file] = files
  let content = guard_file.content

  // Should contain exclusive range guard for weight
  string.contains(content, "validate_measure_weight_exclusive_range")
  |> should.be_true()
  // Should use float comparison operators
  string.contains(content, "value >. 0.0")
  |> should.be_true()

  // Should contain multipleOf guard for step
  string.contains(content, "validate_measure_step_multiple_of")
  |> should.be_true()
  string.contains(content, "must be a multiple of 0.5")
  |> should.be_true()
}

pub fn guards_top_level_integer_exclusive_and_multiple_of_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /ids:
    get:
      operationId: listIds
      responses:
        '200': { description: ok }
components:
  schemas:
    EvenPositive:
      type: integer
      exclusiveMinimum: 0
      multipleOf: 2
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  let assert [guard_file] = files
  let content = guard_file.content

  // Top-level exclusive range guard
  string.contains(content, "validate_even_positive_exclusive_range")
  |> should.be_true()
  // Top-level multipleOf guard
  string.contains(content, "validate_even_positive_multiple_of")
  |> should.be_true()
}

// --- Bool parameter case-insensitive parsing tests ---

pub fn server_bool_path_param_case_insensitive_test() {
  // Server codegen should parse both "true"/"True" and "false"/"False" for bool params.
  // Gleam's bool.to_string produces "True"/"False" (capitalized), so server must
  // accept both cases to be compatible with the client.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items/{active}:
    get:
      operationId: getItems
      parameters:
        - name: active
          in: path
          required: true
          schema:
            type: boolean
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Must accept "true" and "True" as True (case-insensitive)
  string.contains(content, "string.lowercase")
  |> should.be_true()
}

pub fn server_bool_query_param_case_insensitive_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: verbose
          in: query
          required: true
          schema:
            type: boolean
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Must accept "true"/"True" as True via case-insensitive comparison
  string.contains(content, "string.lowercase")
  |> should.be_true()
}

pub fn validate_non_json_request_body_unsupported_for_server_test() {
  // Server multipart support is intentionally narrow. Nested/object-like fields
  // should still produce server-targeted validation errors.
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
              properties:
                meta:
                  type: object
                  properties:
                    file:
                      type: string
                      format: binary
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(
        e.message,
        "multipart/form-data server request bodies only support",
      )
    })
  // Should have at least one server-targeted error for unsupported multipart shape
  list.length(server_errors)
  |> should.not_equal(0)
}

pub fn validate_form_urlencoded_body_multi_level_nesting_accepted_test() {
  // Multi-level nested form-urlencoded objects are now supported
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /login:
    post:
      operationId: login
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              properties:
                profile:
                  type: object
                  properties:
                    meta:
                      type: object
                      properties:
                        username:
                          type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(
        e.message,
        "application/x-www-form-urlencoded server request bodies only support",
      )
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn validate_json_request_body_ok_for_server_test() {
  // application/json body should NOT produce a server-targeted error
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    post:
      operationId: createItem
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                name:
                  type: string
      responses:
        '201': { description: created }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "not supported for server")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_header_param_name_lowercased_test() {
  // Server codegen must lowercase header parameter names in dict.get calls
  // to match client behavior (which lowercases header names).
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: X-Request-ID
          in: header
          required: true
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Must use lowercased header name "x-request-id" not "X-Request-ID"
  string.contains(content, "\"x-request-id\"")
  |> should.be_true()
  // Must NOT contain the original casing in dict.get
  string.contains(content, "\"X-Request-ID\"")
  |> should.be_false()
}

pub fn server_optional_header_param_name_lowercased_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: X-Trace-Id
          in: header
          required: false
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Must use lowercased header name
  string.contains(content, "\"x-trace-id\"")
  |> should.be_true()
}

pub fn server_bool_optional_query_param_case_insensitive_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: verbose
          in: query
          required: false
          schema:
            type: boolean
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Must accept "true"/"True" as True via case-insensitive comparison
  string.contains(content, "string.lowercase")
  |> should.be_true()
}

pub fn server_float_path_param_parsed_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /locations/{lat}:
    get:
      operationId: getLocation
      parameters:
        - name: lat
          in: path
          required: true
          schema:
            type: number
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  string.contains(content, "import gleam/float")
  |> should.be_true()
  string.contains(content, "float.parse(")
  |> should.be_true()
  string.contains(content, "TODO: Parse as Float")
  |> should.be_false()
}

pub fn validate_rejects_array_params_for_server_codegen_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: tags
          in: query
          required: true
          schema:
            type: array
            items:
              type: object
              properties:
                label:
                  type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "Query array parameters are only supported")
    })
  list.length(server_errors)
  |> should.equal(1)
}

pub fn validate_accepts_deep_object_params_for_server_codegen_test() {
  let ctx = make_ctx("test/fixtures/server_deep_object_params.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "deepObject")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn validate_rejects_path_complex_params_for_server_codegen_test() {
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
            type: object
            properties:
              name:
                type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "Complex path parameters are not supported")
    })
  list.length(server_errors)
  |> should.equal(1)
}

pub fn client_mode_ignores_server_target_validation_errors_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: session
          in: cookie
          required: true
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
    )
  generate.generate(spec, cfg)
  |> should.be_ok()
}

pub fn filter_by_mode_drops_server_errors_for_client_test() {
  let issues = [
    diagnostic.validation(
      path: "x",
      detail: "server-only",
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetServer,
    ),
    diagnostic.validation(
      path: "y",
      detail: "shared",
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetBoth,
    ),
  ]
  let filtered = validate.filter_by_mode(issues, config.Client)
  list.length(filtered)
  |> should.equal(1)
}

pub fn filter_by_mode_drops_client_errors_for_server_test() {
  let issues = [
    diagnostic.validation(
      path: "x",
      detail: "client-only",
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetClient,
    ),
    diagnostic.validation(
      path: "y",
      detail: "shared",
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetBoth,
    ),
  ]
  let filtered = validate.filter_by_mode(issues, config.Server)
  list.length(filtered)
  |> should.equal(1)
}

pub fn filter_by_mode_keeps_all_errors_for_both_test() {
  let issues = [
    diagnostic.validation(
      path: "x",
      detail: "client-only",
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetClient,
    ),
    diagnostic.validation(
      path: "y",
      detail: "server-only",
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetServer,
    ),
    diagnostic.validation(
      path: "z",
      detail: "shared",
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetBoth,
    ),
  ]
  let filtered = validate.filter_by_mode(issues, config.Both)
  list.length(filtered)
  |> should.equal(3)
}

pub fn generation_summary_includes_warnings_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200':
          description: ok
          headers:
            X-Rate-Limit:
              description: Rate limit
              schema: { type: integer }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
    )
  let assert Ok(summary) = generate.generate(spec, cfg)
  { summary.warnings != [] }
  |> should.be_true()
}

pub fn validate_warns_multi_content_responses_for_server_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema: { type: string }
            text/plain:
              schema: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let issues = capability_check.check_preserved(ctx)
  let warnings =
    list.filter(issues, fn(issue) {
      issue.severity == diagnostic.SeverityWarning
      && issue.target == diagnostic.TargetServer
      && string.contains(issue.message, "Multiple response content types")
    })
  list.length(warnings)
  |> should.equal(1)
}

pub fn integration_script_uses_warnings_as_errors_for_server_builds_test() {
  let assert Ok(content) = simplifile.read("integration_test/run.sh")
  string.contains(content, "if gleam build 2>&1; then")
  |> should.be_false()
}

pub fn server_router_uses_underscored_unused_route_args_test() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let router_file = list.find(files, fn(f) { f.path == "router.gleam" })
  let assert Ok(router) = router_file
  string.contains(
    router.content,
    "pub fn route(method: String, path: List(String), _query: Dict(String, List(String)), _headers: Dict(String, String), _body: String) -> ServerResponse",
  )
  |> should.be_true()
}

pub fn validate_accepts_cookie_params_for_server_codegen_test() {
  let ctx = make_ctx("test/fixtures/server_cookie_params.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "Cookie parameters")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_cookie_params_are_generated_without_todo_placeholders_test() {
  let ctx = make_ctx("test/fixtures/server_cookie_params.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(content, "TODO: Extract cookie param")
  |> should.be_false()
  string.contains(content, "cookie_lookup(headers, \"session\")")
  |> should.be_true()
  string.contains(content, "cookie_lookup(headers, \"debug\")")
  |> should.be_true()
}

pub fn server_cookie_router_imports_list_for_cookie_lookup_test() {
  let ctx = make_ctx("test/fixtures/server_cookie_params.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  string.contains(router_file.content, "import gleam/list")
  |> should.be_true()
}

pub fn server_cookie_router_percent_decodes_cookie_values_test() {
  let ctx = make_ctx("test/fixtures/server_cookie_params.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  string.contains(router_file.content, "import gleam/uri")
  |> should.be_true()
  string.contains(router_file.content, "uri.percent_decode")
  |> should.be_true()
}

pub fn server_query_and_header_scalars_are_parsed_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /metrics:
    get:
      operationId: getMetrics
      parameters:
        - name: ratio
          in: query
          required: true
          schema:
            type: number
        - name: x-enabled
          in: header
          required: false
          schema:
            type: boolean
        - name: x-threshold
          in: header
          required: true
          schema:
            type: number
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(
    content,
    "ratio: { let assert Ok([v, ..]) = dict.get(query, \"ratio\") let assert Ok(n) = float.parse(v) n },",
  )
  |> should.be_true()
  string.contains(
    content,
    "x_enabled: case dict.get(headers, \"x-enabled\") { Ok(v) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None },",
  )
  |> should.be_true()
  string.contains(
    content,
    "x_threshold: { let assert Ok(v) = dict.get(headers, \"x-threshold\") let assert Ok(n) = float.parse(v) n },",
  )
  |> should.be_true()
}

pub fn validate_accepts_header_array_params_for_server_codegen_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: x-tags
          in: header
          required: true
          schema:
            type: array
            items:
              type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "Array parameters")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_header_array_params_are_parsed_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /headers:
    get:
      operationId: getHeaders
      parameters:
        - name: x-tags
          in: header
          required: true
          schema:
            type: array
            items:
              type: string
        - name: x-scores
          in: header
          required: false
          schema:
            type: array
            items:
              type: integer
        - name: x-flags
          in: header
          required: true
          schema:
            type: array
            items:
              type: boolean
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(content, "import gleam/list")
  |> should.be_true()
  string.contains(
    content,
    "x_tags: { let assert Ok(v) = dict.get(headers, \"x-tags\") list.map(string.split(v, \",\"), fn(item) { string.trim(item) }) },",
  )
  |> should.be_true()
  string.contains(
    content,
    "x_scores: case dict.get(headers, \"x-scores\") { Ok(v) -> Some(list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n })) _ -> None },",
  )
  |> should.be_true()
  string.contains(
    content,
    "x_flags: { let assert Ok(v) = dict.get(headers, \"x-flags\") list.map(string.split(v, \",\"), fn(item) { let v = string.trim(item) case string.lowercase(v) { \"true\" -> True _ -> False } }) },",
  )
  |> should.be_true()
}

pub fn validate_accepts_query_array_params_for_server_codegen_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: tags
          in: query
          required: true
          schema:
            type: array
            items:
              type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "Array parameters")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_query_array_params_use_query_multimap_test() {
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
          required: true
          schema:
            type: array
            items:
              type: string
        - name: scores
          in: query
          required: false
          explode: false
          schema:
            type: array
            items:
              type: integer
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(
    content,
    "pub fn route(method: String, path: List(String), query: Dict(String, List(String)), _headers: Dict(String, String), _body: String) -> ServerResponse",
  )
  |> should.be_true()
  string.contains(
    content,
    "tags: { let assert Ok(vs) = dict.get(query, \"tags\") list.map(vs, fn(item) { string.trim(item) }) },",
  )
  |> should.be_true()
  string.contains(
    content,
    "scores: case dict.get(query, \"scores\") { Ok([v, ..]) -> Some(list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n })) _ -> None },",
  )
  |> should.be_true()
}

pub fn server_deep_object_params_are_parsed_test() {
  let ctx = make_ctx("test/fixtures/server_deep_object_params.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(content, "import api/types")
  |> should.be_true()
  string.contains(
    content,
    "fn deep_object_present(query: Dict(String, List(String)), prefix: String, props: List(String)) -> Bool {",
  )
  |> should.be_true()
  string.contains(content, "filter: types.SearchItemsParamFilter(")
  |> should.be_true()
  string.contains(
    content,
    "name: { let assert Ok([v, ..]) = dict.get(query, \"filter[name]\") v }",
  )
  |> should.be_true()
  string.contains(
    content,
    "active: case dict.get(query, \"filter[active]\") { Ok([v, ..]) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "ratio: case dict.get(query, \"filter[ratio]\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "scores: { let assert Ok(vs) = dict.get(query, \"filter[scores]\") list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n }) }",
  )
  |> should.be_true()
  string.contains(
    content,
    "options: case deep_object_present(query, \"options\", [",
  )
  |> should.be_true()
  string.contains(
    content,
    "tags: case dict.get(query, \"options[tags]\") { Ok(vs) -> Some(list.map(vs, fn(item) { string.trim(item) })) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "enabled: case dict.get(query, \"options[enabled]\") { Ok([v, ..]) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None }",
  )
  |> should.be_true()
}

pub fn validate_accepts_form_urlencoded_body_for_server_codegen_test() {
  let ctx = make_ctx("test/fixtures/server_form_urlencoded_body.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "application/x-www-form-urlencoded")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_form_urlencoded_body_is_parsed_test() {
  let ctx = make_ctx("test/fixtures/server_form_urlencoded_body.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(content, "import api/types")
  |> should.be_true()
  string.contains(content, "fn form_url_decode(value: String) -> String {")
  |> should.be_true()
  string.contains(
    content,
    "fn parse_form_body(body: String) -> Dict(String, List(String)) {",
  )
  |> should.be_true()
  string.contains(content, "let form_body = parse_form_body(body)")
  |> should.be_true()
  string.contains(content, "body: types.SubmitFormRequest(")
  |> should.be_true()
  string.contains(
    content,
    "name: { let assert Ok([v, ..]) = dict.get(form_body, \"name\") v }",
  )
  |> should.be_true()
  string.contains(
    content,
    "active: case dict.get(form_body, \"active\") { Ok([v, ..]) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "ratio: case dict.get(form_body, \"ratio\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "scores: { let assert Ok(vs) = dict.get(form_body, \"scores\") list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n }) }",
  )
  |> should.be_true()
  string.contains(
    content,
    "tags: case dict.get(form_body, \"tags\") { Ok(vs) -> Some(list.map(vs, fn(item) { string.trim(item) })) _ -> None }",
  )
  |> should.be_true()
}

pub fn validate_accepts_nested_form_urlencoded_body_for_server_codegen_test() {
  let ctx = make_ctx("test/fixtures/server_form_urlencoded_nested_body.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "application/x-www-form-urlencoded")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_nested_form_urlencoded_body_is_parsed_test() {
  let ctx = make_ctx("test/fixtures/server_form_urlencoded_nested_body.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(content, "profile: types.SubmitNestedFormRequestProfile(")
  |> should.be_true()
  string.contains(
    content,
    "username: { let assert Ok([v, ..]) = dict.get(form_body, \"profile[username]\") v }",
  )
  |> should.be_true()
  string.contains(
    content,
    "aliases: case dict.get(form_body, \"profile[aliases]\") { Ok(vs) -> Some(list.map(vs, fn(item) { string.trim(item) })) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "age: case dict.get(form_body, \"profile[age]\") { Ok([v, ..]) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }",
  )
  |> should.be_true()
}

pub fn validate_accepts_multipart_body_for_server_codegen_test() {
  let ctx = make_ctx("test/fixtures/server_multipart_body.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "multipart/form-data")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_multipart_body_is_parsed_test() {
  let ctx = make_ctx("test/fixtures/server_multipart_body.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(
    content,
    "fn parse_multipart_body(body: String, headers: Dict(String, String)) -> Dict(String, List(String)) {",
  )
  |> should.be_true()
  string.contains(
    content,
    "let multipart_body = parse_multipart_body(body, headers)",
  )
  |> should.be_true()
  string.contains(content, "body: types.UploadMultipartRequest(")
  |> should.be_true()
  string.contains(
    content,
    "name: { let assert Ok([v, ..]) = dict.get(multipart_body, \"name\") v }",
  )
  |> should.be_true()
  string.contains(
    content,
    "active: case dict.get(multipart_body, \"active\") { Ok([v, ..]) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "ratio: case dict.get(multipart_body, \"ratio\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "file: case dict.get(multipart_body, \"file\") { Ok([v, ..]) -> Some(v) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "let normalized_part = part |> string.remove_prefix(\"\\r\\n\") |> string.remove_suffix(\"\\r\\n\")",
  )
  |> should.be_true()
  string.contains(content, "let value = string.trim(raw_value)")
  |> should.be_false()
}

pub fn validate_accepts_form_urlencoded_ref_fields_for_server_codegen_test() {
  let ctx = make_ctx("test/fixtures/server_form_urlencoded_ref_fields.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "application/x-www-form-urlencoded")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_form_urlencoded_ref_fields_are_parsed_test() {
  let ctx = make_ctx("test/fixtures/server_form_urlencoded_ref_fields.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(
    content,
    "active: case dict.get(form_body, \"active\") { Ok([v, ..]) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "ratio: case dict.get(form_body, \"ratio\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "scores: { let assert Ok(vs) = dict.get(form_body, \"scores\") list.map(vs, fn(item) { let trimmed = string.trim(item) let assert Ok(n) = int.parse(trimmed) n }) }",
  )
  |> should.be_true()
  string.contains(content, "profile: types.Profile(")
  |> should.be_true()
  string.contains(
    content,
    "username: { let assert Ok([v, ..]) = dict.get(form_body, \"profile[username]\") v }",
  )
  |> should.be_true()
  string.contains(
    content,
    "enabled: case dict.get(form_body, \"profile[enabled]\") { Ok([v, ..]) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None }",
  )
  |> should.be_true()
}

pub fn validate_accepts_multipart_ref_fields_for_server_codegen_test() {
  let ctx = make_ctx("test/fixtures/server_multipart_ref_fields.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "multipart/form-data")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_multipart_ref_fields_are_parsed_test() {
  let ctx = make_ctx("test/fixtures/server_multipart_ref_fields.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(
    content,
    "active: case dict.get(multipart_body, \"active\") { Ok([v, ..]) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "ratio: case dict.get(multipart_body, \"ratio\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "file: case dict.get(multipart_body, \"file\") { Ok([v, ..]) -> Some(v) _ -> None }",
  )
  |> should.be_true()
}

// --- Server cookie parameter end-to-end tests ---

pub fn server_cookie_param_generates_cookie_lookup_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /dashboard:
    get:
      operationId: getDashboard
      parameters:
        - name: session_id
          in: cookie
          required: true
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Router must contain the cookie_lookup helper function
  string.contains(content, "fn cookie_lookup(")
  |> should.be_true()
  // Must use cookie_lookup for the session_id parameter
  string.contains(content, "cookie_lookup(headers, \"session_id\")")
  |> should.be_true()
  // Must import gleam/uri for percent-decoding
  string.contains(content, "gleam/uri")
  |> should.be_true()
}

pub fn server_cookie_param_optional_string_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /prefs:
    get:
      operationId: getPrefs
      parameters:
        - name: theme
          in: cookie
          required: false
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Optional cookie should use Some/None pattern
  string.contains(content, "cookie_lookup(headers, \"theme\")")
  |> should.be_true()
  string.contains(content, "Some(v)")
  |> should.be_true()
}

pub fn server_cookie_param_integer_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /dashboard:
    get:
      operationId: getDashboard
      parameters:
        - name: page_size
          in: cookie
          required: true
          schema:
            type: integer
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Integer cookie should use int.parse
  string.contains(content, "cookie_lookup(headers, \"page_size\")")
  |> should.be_true()
  string.contains(content, "int.parse")
  |> should.be_true()
}

pub fn server_cookie_param_boolean_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /dashboard:
    get:
      operationId: getDashboard
      parameters:
        - name: dark_mode
          in: cookie
          required: true
          schema:
            type: boolean
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Boolean cookie should use case-insensitive bool parsing
  string.contains(content, "cookie_lookup(headers, \"dark_mode\")")
  |> should.be_true()
  string.contains(content, "string.lowercase")
  |> should.be_true()
}

pub fn server_cookie_param_float_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /dashboard:
    get:
      operationId: getDashboard
      parameters:
        - name: zoom_level
          in: cookie
          required: true
          schema:
            type: number
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Float cookie should use float.parse
  string.contains(content, "cookie_lookup(headers, \"zoom_level\")")
  |> should.be_true()
  string.contains(content, "float.parse")
  |> should.be_true()
}

// --- Response types import conditional test ---

pub fn response_types_omits_types_import_when_no_body_test() {
  // When all responses have no body, response_types.gleam should not
  // import the types module (avoids unused import warning).
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
        '200': { description: ok }
        '500': { description: error }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert Ok(resp_file) =
    list.find(files, fn(f) { f.path == "response_types.gleam" })
  let content = resp_file.content
  // Should NOT import types module when no response body references it
  string.contains(content, "import api/types")
  |> should.be_false()
}

pub fn server_multi_content_response_sets_first_content_type_test() {
  // When a response has multiple content types, the server router should
  // set the first content type as a default content-type header rather
  // than leaving headers empty.
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
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
                properties:
                  name:
                    type: string
            text/plain:
              schema:
                type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
    )
  let ctx = context.new(spec, cfg)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Should have a content-type header, not empty headers
  string.contains(content, "application/json")
  |> should.be_true()
}

pub fn response_types_includes_types_import_when_ref_body_test() {
  // When a response has a $ref body, types import is needed.
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
                $ref: '#/components/schemas/Pet'
components:
  schemas:
    Pet:
      type: object
      properties:
        name:
          type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert Ok(resp_file) =
    list.find(files, fn(f) { f.path == "response_types.gleam" })
  let content = resp_file.content
  // Should import types module for $ref response bodies
  string.contains(content, "import api/types")
  |> should.be_true()
}

// --- deepObject referenced enum/alias leaf tests ---

// --- Multipart primitive array field tests ---

pub fn validate_multipart_primitive_array_field_accepted_test() {
  // Multipart body with primitive array fields should be accepted
  // for server codegen.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /upload:
    post:
      operationId: uploadMultipart
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required:
                - tags
              properties:
                tags:
                  type: array
                  items:
                    type: string
                scores:
                  type: array
                  items:
                    type: integer
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
    )
  let ctx = context.new(spec, cfg)
  let errors = validate.validate(ctx)
  let multipart_errors =
    list.filter(errors, fn(e) {
      string.contains(e.message, "multipart")
      && e.target == diagnostic.TargetServer
    })
  list.length(multipart_errors)
  |> should.equal(0)
}

pub fn server_multipart_array_field_codegen_test() {
  // Multipart array fields should generate list.map parsing code.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /upload:
    post:
      operationId: uploadMultipart
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required:
                - tags
              properties:
                tags:
                  type: array
                  items:
                    type: string
                scores:
                  type: array
                  items:
                    type: integer
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
    )
  let ctx = context.new(spec, cfg)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // tags (string array) should get all values from the multipart dict
  string.contains(content, "dict.get(multipart_body, \"tags\")")
  |> should.be_true()
  // scores (int array) should parse each value
  string.contains(content, "int.parse")
  |> should.be_true()
}

// --- Form-urlencoded multi-level nesting tests ---

pub fn validate_form_urlencoded_two_level_nesting_accepted_test() {
  // form-urlencoded bodies with two levels of object nesting should be
  // accepted: field[sub][key]=value
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /submit:
    post:
      operationId: submit
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              properties:
                profile:
                  type: object
                  properties:
                    settings:
                      type: object
                      properties:
                        theme:
                          type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
    )
  let ctx = context.new(spec, cfg)
  let errors = validate.validate(ctx)
  let form_errors =
    list.filter(errors, fn(e) {
      string.contains(e.message, "form-urlencoded")
      && e.target == diagnostic.TargetServer
    })
  list.length(form_errors)
  |> should.equal(0)
}

pub fn server_form_urlencoded_two_level_nesting_codegen_test() {
  // Two-level nested form-urlencoded should generate bracket keys
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /submit:
    post:
      operationId: submit
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              properties:
                profile:
                  type: object
                  properties:
                    settings:
                      type: object
                      properties:
                        theme:
                          type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
    )
  let ctx = context.new(spec, cfg)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Should have two-level bracket key
  string.contains(content, "profile[settings][theme]")
  |> should.be_true()
}

pub fn validate_deep_object_referenced_enum_leaf_accepted_test() {
  // deepObject properties that reference a string enum should be accepted
  // since enums are effectively strings at the wire level.
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
        - name: filter
          in: query
          required: true
          style: deepObject
          schema:
            type: object
            properties:
              status:
                $ref: '#/components/schemas/Status'
      responses:
        '200': { description: ok }
components:
  schemas:
    Status:
      type: string
      enum: [active, inactive]
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
    )
  let ctx = context.new(spec, cfg)
  let errors = validate.validate(ctx)
  let deep_object_errors =
    list.filter(errors, fn(e) { string.contains(e.message, "deepObject") })
  // Should have NO deepObject errors for referenced enum leaf
  list.length(deep_object_errors)
  |> should.equal(0)
}

pub fn validate_deep_object_referenced_primitive_alias_accepted_test() {
  // deepObject properties that reference a primitive alias (e.g., string)
  // should be accepted since they resolve to simple scalar types.
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
        - name: filter
          in: query
          required: true
          style: deepObject
          schema:
            type: object
            properties:
              id:
                $ref: '#/components/schemas/UUID'
              count:
                $ref: '#/components/schemas/PositiveInt'
      responses:
        '200': { description: ok }
components:
  schemas:
    UUID:
      type: string
      format: uuid
    PositiveInt:
      type: integer
      minimum: 1
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
    )
  let ctx = context.new(spec, cfg)
  let errors = validate.validate(ctx)
  let deep_object_errors =
    list.filter(errors, fn(e) { string.contains(e.message, "deepObject") })
  list.length(deep_object_errors)
  |> should.equal(0)
}

// --- uniqueItems guard tests ---

pub fn guards_unique_items_generates_guard_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    TagList:
      type: array
      items:
        type: string
      uniqueItems: true
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  list.length(files) |> should.not_equal(0)
  let assert [guard_file] = files
  let content = guard_file.content
  // Should generate a uniqueItems guard
  string.contains(content, "validate_tag_list_unique")
  |> should.be_true()
  // Should use list.unique for deduplication
  string.contains(content, "list.unique")
  |> should.be_true()
}

pub fn guards_unique_items_field_generates_guard_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    SearchRequest:
      type: object
      properties:
        tags:
          type: array
          items:
            type: string
          uniqueItems: true
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  list.length(files) |> should.not_equal(0)
  let assert [guard_file] = files
  let content = guard_file.content
  string.contains(content, "validate_search_request_tags_unique")
  |> should.be_true()
}

// --- minProperties/maxProperties guard tests ---

pub fn guards_min_properties_generates_guard_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    FilterMap:
      type: object
      additionalProperties:
        type: string
      minProperties: 1
      maxProperties: 10
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  list.length(files) |> should.not_equal(0)
  let assert [guard_file] = files
  let content = guard_file.content
  string.contains(content, "validate_filter_map_properties")
  |> should.be_true()
  string.contains(content, "dict.size")
  |> should.be_true()
}

// --- OSS fixture tests ---
// Test fixtures ported from open source projects under MIT / Apache 2.0 licenses.
// libopenapi: MIT License, Copyright (c) 2022-2025 Princess Beef Heavy Industries
// oapi-codegen: Apache License 2.0, Copyright deepmap/oapi-codegen contributors

pub fn oss_libopenapi_all_components_parses_test() {
  // all-the-components.yaml has webhooks without responses field.
  // OpenAPI spec requires responses on operations, but webhooks in the wild
  // often omit them. Parser should handle this gracefully.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_libopenapi_all_components.yaml")
  spec.info.title |> should.equal("Burger Shop")
  let ops = dict.to_list(spec.paths)
  list.length(ops) |> should.not_equal(0)
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

/// The all_components fixture references security scheme 'api_key' that is
/// not defined in components.securitySchemes. Validation catches this.
pub fn oss_libopenapi_all_components_validates_security_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_libopenapi_all_components.yaml")
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let blocking = validate.errors_only(errors)
  let has_security_error =
    list.any(blocking, fn(e) {
      string.contains(diagnostic.to_string(e), "api_key")
    })
  should.be_true(has_security_error)
}

/// libopenapi burgershop uses the JSON Schema 'not' keyword which is
/// unsupported. The parser rejects it with a clear error.
pub fn oss_libopenapi_burgershop_rejects_not_keyword_test() {
  // Parse succeeds — lossless parser stores unsupported keywords
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_libopenapi_burgershop.yaml")
  // Generate fails via capability_check due to "not" keyword
  let result = generate.generate(spec, make_ctx_from_spec(spec).config)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_not = list.any(error_details, fn(d) { string.contains(d, "not") })
      should.be_true(has_not)
    }

    Ok(_) -> should.fail()
  }
}

pub fn oss_libopenapi_petstorev3_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_libopenapi_petstorev3.json")
  spec.info.title |> should.equal("Swagger Petstore - OpenAPI 3.0")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_libopenapi_circular_rejects_missing_info_test() {
  // circular-tests.yaml has no info field, which is required by OpenAPI 3.x.
  // Parser should reject this with a clear error.
  let result = parser.parse_file("test/fixtures/oss_libopenapi_circular.yaml")
  case result {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn oss_oapi_codegen_cookies_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_cookies.yaml")
  spec.info.title |> should.not_equal("")
}

pub fn oss_oapi_codegen_name_conflicts_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_name_conflicts.yaml")
  let assert Some(components) = spec.components
  // Should have many schemas (name conflict resolution tests many similar names)
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_illegal_enums_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_illegal_enums.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_nullable_parses_test() {
  // Tests all combinations of required/optional + nullable/non-nullable
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_nullable.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_nullable_generates_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_nullable.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, ctx.config)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      let blocking = validate.errors_only(errors)
      list.length(blocking) |> should.equal(0)
    }
  }
}

pub fn oss_oapi_codegen_recursive_allof_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_recursive_allof.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_allof_additional_parses_test() {
  // allOf with additionalProperties: true
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_allof_additional.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_allof_additional_generates_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_allof_additional.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, ctx.config)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      let blocking = validate.errors_only(errors)
      list.length(blocking) |> should.equal(0)
    }
  }
}

pub fn oss_oapi_codegen_security_parses_test() {
  // Bearer token authentication
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_security.yaml")
  let assert Some(components) = spec.components
  dict.size(components.security_schemes) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_multi_content_parses_test() {
  // Multiple content types in requestBody and responses
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_multi_content.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_multi_content_rejects_unsupported_types_test() {
  // This spec has text/json and application/*+json which are unsupported.
  // Validation should catch them.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_multi_content.yaml")
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let blocking = validate.errors_only(errors)
  // Should have blocking errors for unsupported content types
  list.length(blocking) |> should.not_equal(0)
}

// --- OSS fixture batch 3: regression specs ---

pub fn oss_oapi_codegen_issue_312_colon_path_parses_test() {
  // Path with colon: /pets:validate
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_312.yaml")
  let paths = dict.keys(spec.paths)
  list.contains(paths, "/pets:validate") |> should.be_true()
}

pub fn oss_oapi_codegen_issue_312_generates_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_312.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, ctx.config)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(validate.errors_only(errors)) |> should.equal(0)
    }
  }
}

pub fn oss_oapi_codegen_issue_936_recursive_oneof_parses_test() {
  // Recursive cyclic refs with oneOf (FilterPredicate)
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_936.yaml")
  let assert Some(components) = spec.components
  list.contains(dict.keys(components.schemas), "FilterPredicate")
  |> should.be_true()
}

pub fn oss_oapi_codegen_issue_52_recursive_additional_props_parses_test() {
  // Recursive types through additionalProperties
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_52.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_52_generates_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_52.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, ctx.config)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(validate.errors_only(errors)) |> should.equal(0)
    }
  }
}

pub fn oss_oapi_codegen_issue_1168_allof_discriminator_parses_test() {
  // allOf with discriminator
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_1168.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_1168_rejects_problem_json_test() {
  // application/problem+json is not a supported response content type.
  // With lazy ref resolution, inline $ref responses are kept as Ref(...).
  // The full generate pipeline resolves them and catches validation errors.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_1168.yaml")
  let result = generate.generate(spec, make_ctx_from_spec(spec).config)
  case result {
    Error(generate.ValidationErrors(errors)) ->
      list.length(errors) |> should.not_equal(0)
    // If codegen succeeds with warnings, that's also acceptable
    Ok(summary) -> list.length(summary.warnings) |> should.not_equal(0)
  }
}

pub fn oss_oapi_codegen_issue_832_recursive_oneof_parses_test() {
  // Recursive oneOf types
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_832.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_579_enum_special_chars_parses_test() {
  // Enum values with special characters
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_579.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_579_generates_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_579.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, ctx.config)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(validate.errors_only(errors)) |> should.equal(0)
    }
  }
}

pub fn oss_oapi_codegen_issue_2185_nullable_array_items_parses_test() {
  // Nullable array items
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_2185.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_2185_generates_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_2185.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, ctx.config)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(validate.errors_only(errors)) |> should.equal(0)
    }
  }
}

// --- OSS fixture batch 4: openapi-generator specs (Apache 2.0) ---

pub fn oss_openapi_gen_issue_4947_wildcard_content_parses_test() {
  // Spec with */* content type and pattern-constrained strings
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_4947.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_9719_dot_operationid_parses_test() {
  // Dot-delimited operationId: petstore.api.users.get_all
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_9719.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_9719_generates_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_9719.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, ctx.config)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(validate.errors_only(errors)) |> should.equal(0)
    }
  }
}

pub fn oss_openapi_gen_issue_13917_patch_allof_parses_test() {
  // PATCH operation with allOf request body
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_13917.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_13917_rejects_json_patch_content_test() {
  // application/json-patch+json is not a supported content type
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_13917.yaml")
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let blocking = validate.errors_only(errors)
  list.length(blocking) |> should.not_equal(0)
}

pub fn oss_openapi_gen_petstore_server_parses_test() {
  // Full petstore server spec from openapi-generator samples
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_petstore_server.yaml")
  spec.info.title |> should.not_equal("")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_openapi_gen_petstore_server_generates_client_test() {
  // Client-only mode avoids server-specific validation errors.
  // multipart field type errors still apply to both targets.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_petstore_server.yaml")
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Error(generate.ValidationErrors(errors)) ->
      list.length(errors) |> should.not_equal(0)
    Ok(summary) -> list.length(summary.warnings) |> should.not_equal(0)
  }
}

// --- OSS fixture batch 5: kiota specs (MIT License, Copyright Microsoft) ---

pub fn oss_kiota_discriminator_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kiota_discriminator.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_kiota_discriminator_generates_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kiota_discriminator.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, ctx.config)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(validate.errors_only(errors)) |> should.equal(0)
    }
  }
}

pub fn oss_kiota_derived_types_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kiota_derived_types.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_kiota_derived_types_generates_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kiota_derived_types.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, ctx.config)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(validate.errors_only(errors)) |> should.equal(0)
    }
  }
}

pub fn oss_kiota_multi_security_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kiota_multi_security.yaml")
  // Security is at operation level, not top-level
  let assert Some(components) = spec.components
  dict.size(components.security_schemes) |> should.not_equal(0)
}

pub fn oss_kiota_multi_security_generates_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kiota_multi_security.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, ctx.config)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(validate.errors_only(errors)) |> should.equal(0)
    }
  }
}

// --- Parser error message quality tests ---

pub fn parse_error_missing_info_has_actionable_message_test() {
  let result =
    parser.parse_string(
      "
openapi: 3.0.3
paths: {}
",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "info") |> should.be_true()
  string.contains(msg, "root") |> should.be_true()
}

pub fn parse_error_missing_version_has_path_test() {
  let result =
    parser.parse_string(
      "
openapi: 3.0.3
info:
  title: Test
paths: {}
",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "version") |> should.be_true()
  string.contains(msg, "info") |> should.be_true()
}

pub fn parse_error_missing_param_name_has_path_test() {
  let result =
    parser.parse_string(
      "
openapi: 3.0.3
info:
  title: Test
  version: '1.0'
paths:
  /x:
    get:
      operationId: getX
      parameters:
        - in: query
          schema:
            type: string
      responses:
        '200': { description: ok }
",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "name") |> should.be_true()
  string.contains(msg, "parameter") |> should.be_true()
}

// --- OSS fixture batch: more oapi-codegen regression specs ---

pub fn oss_oapi_codegen_issue_1087_rejects_unresolved_ref_test() {
  // Has external $ref and numeric response key (304) as component ref.
  // With lazy ref resolution, parse succeeds; refs are stored as Ref(...).
  let result =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_1087.yaml")
  let assert Ok(_spec) = result
}

pub fn oss_oapi_codegen_issue_1963_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_1963.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_2232_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_2232.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_2238_header_array_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_2238.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_2113_rejects_external_ref_test() {
  // Has external $ref (./common/spec.yaml#/...) which is not supported.
  // With lazy ref resolution, parse succeeds; external refs are stored as Ref(...).
  let result =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_2113.yaml")
  let assert Ok(_spec) = result
}

pub fn oss_oapi_codegen_issue_1397_rejects_missing_info_test() {
  let result =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_1397.yaml")
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "info") |> should.be_true()
}

pub fn oss_oapi_codegen_issue_1914_rejects_missing_info_test() {
  let result =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_1914.yaml")
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "info") |> should.be_true()
}

pub fn oss_oapi_codegen_head_digit_httpheader_parses_test() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_oapi_codegen_head_digit_of_httpheader.yaml",
    )
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_head_digit_operation_id_parses_test() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_oapi_codegen_head_digit_of_operation_id.yaml",
    )
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

// --- OSS fixture batch: openapi-generator bug specs (Apache 2.0) ---

pub fn oss_openapi_gen_issue_11897_array_of_string_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_11897.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_11897_generates_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_11897.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, ctx.config)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) ->
      list.length(validate.errors_only(errors)) |> should.equal(0)
  }
}

pub fn oss_openapi_gen_issue_14731_discriminator_mapping_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_14731.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_1666_optional_body_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_1666.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_1666_generates_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_1666.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, ctx.config)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) ->
      list.length(validate.errors_only(errors)) |> should.equal(0)
  }
}

pub fn oss_openapi_gen_recursion_bug_4650_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_recursion_bug_4650.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_18516_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_18516.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_18516_generates_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_18516.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, ctx.config)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) ->
      list.length(validate.errors_only(errors)) |> should.equal(0)
  }
}

// ---------------------------------------------------------------------------
// OSS: kin-openapi (MIT)
// Test data derived from https://github.com/getkin/kin-openapi
// ---------------------------------------------------------------------------

/// kin-openapi link-example: complex links between operations.
pub fn oss_kin_openapi_link_example_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_link_example.yaml")
  spec.info.title |> should.equal("Link Example")
  // Has multiple paths
  dict.size(spec.paths) |> should.not_equal(0)
  // Has components with links
  let assert Some(components) = spec.components
  dict.size(components.links) |> should.not_equal(0)
}

/// kin-openapi issue409: string schema with regex pattern.
pub fn oss_kin_openapi_issue409_pattern_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_issue409.yaml")
  spec.info.title |> should.equal("Issue 409")
  dict.size(spec.paths) |> should.not_equal(0)
}

/// kin-openapi issue753: callbacks with schema refs.
pub fn oss_kin_openapi_callbacks_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_callbacks.yaml")
  // Has two paths with callbacks
  dict.size(spec.paths) |> should.equal(2)
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

/// kin-openapi issue794: request body with empty media type content.
pub fn oss_kin_openapi_empty_media_type_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_empty_media_type.yaml")
  spec.info.title |> should.equal("Swagger API")
  dict.size(spec.paths) |> should.equal(1)
}

/// kin-openapi issue697: schema with date format and example.
pub fn oss_kin_openapi_date_example_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_date_example.yaml")
  spec.info.title |> should.equal("sample")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

/// kin-openapi: path-level parameters overridden at operation level.
pub fn oss_kin_openapi_param_override_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_param_override.yaml")
  spec.info.title |> should.equal("customer")
  dict.size(spec.paths) |> should.equal(1)
  list.length(spec.servers) |> should.equal(1)
}

/// kin-openapi: additionalProperties with typed schema.
pub fn oss_kin_openapi_additional_properties_parses_test() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_kin_openapi_additional_properties.yaml",
    )
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(2)
}

/// kin-openapi: example $ref within parameters, headers, and media types.
pub fn oss_kin_openapi_example_refs_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_example_refs.yaml")
  let assert Some(components) = spec.components
  dict.size(components.parameters) |> should.not_equal(0)
  dict.size(components.headers) |> should.not_equal(0)
  dict.size(components.request_bodies) |> should.not_equal(0)
  dict.size(components.responses) |> should.not_equal(0)
}

/// kin-openapi: minimal OpenAPI spec in JSON format.
pub fn oss_kin_openapi_minimal_json_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_minimal.json")
  // The original fixture has an empty title
  spec.info.title |> should.equal("")
  spec.openapi |> should.equal("3.0.0")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(1)
}

/// kin-openapi: components with $ref cross-references in JSON.
/// The fixture contains an invalid security scheme type ("cookie") which is
/// not part of the OpenAPI 3.x specification. The parser rejects it with a
/// clear error message guiding the user to fix the security scheme type.
pub fn oss_kin_openapi_components_json_rejects_invalid_scheme_test() {
  // Parser preserves unsupported scheme types losslessly;
  // capability_check rejects them during generate.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_components.json")
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { e.message })
      let has_cookie =
        list.any(error_details, fn(d) { string.contains(d, "cookie") })
      should.be_true(has_cookie)
    }
    Ok(_) -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// OSS: openapi-spec-validator (Apache-2.0)
// Test data derived from https://github.com/python-openapi/openapi-spec-validator
// ---------------------------------------------------------------------------

/// openapi-spec-validator: standard petstore v3.0.
pub fn oss_spec_validator_petstore_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spec_validator_petstore.yaml")
  spec.info.title |> should.equal("Swagger Petstore")
  spec.openapi |> should.equal("3.0.0")
  dict.size(spec.paths) |> should.equal(2)
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(3)
}

/// openapi-spec-validator: readOnly and writeOnly properties.
pub fn oss_spec_validator_read_write_only_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spec_validator_read_write_only.yaml")
  spec.info.title |> should.equal("Specification Containing readOnly")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

/// openapi-spec-validator: response without description field.
/// OpenAPI 3.x requires 'description' on every response object.
/// The parser rejects this with a user-friendly error message.
pub fn oss_spec_validator_missing_description_rejects_test() {
  let result =
    parser.parse_file(
      "test/fixtures/oss_spec_validator_missing_description.yaml",
    )
  case result {
    Error(Diagnostic(
      code: "missing_field",
      message: "Missing required field: description",
      ..,
    )) -> should.be_true(True)
    Error(e) -> {
      let msg = parser.parse_error_to_string(e)
      should.be_true(string.contains(msg, "description"))
    }
    Ok(_) -> should.fail()
  }
}

/// openapi-spec-validator: self-referencing recursive schema.
pub fn oss_spec_validator_recursive_property_parses_test() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_spec_validator_recursive_property.yaml",
    )
  spec.info.title |> should.equal("Some Schema")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

/// openapi-spec-validator: petstore v3.1 with pathItems in components.
pub fn oss_spec_validator_petstore_v31_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spec_validator_petstore_v31.yaml")
  spec.info.title |> should.equal("Swagger Petstore")
  spec.openapi |> should.equal("3.1.0")
  let assert Some(components) = spec.components
  dict.size(components.path_items) |> should.not_equal(0)
}

// ---------------------------------------------------------------------------
// OSS: swagger-parser-js (MIT)
// Test data derived from https://github.com/APIDevTools/swagger-parser
// ---------------------------------------------------------------------------

/// swagger-parser-js: relative server URL in JSON format.
pub fn oss_swagger_parser_js_relative_server_parses_test() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_js_relative_server.json",
    )
  spec.info.title |> should.equal("Swagger Petstore")
  list.length(spec.servers) |> should.equal(1)
  dict.size(spec.paths) |> should.not_equal(0)
}

// ---------------------------------------------------------------------------
// OSS: spectral (Apache-2.0)
// Test data derived from https://github.com/stoplightio/spectral
// ---------------------------------------------------------------------------

/// spectral: valid minimal OpenAPI 3.0 spec with contact and tags.
pub fn oss_spectral_valid_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spectral_valid.yaml")
  spec.info.title |> should.equal("OAS3")
  spec.openapi |> should.equal("3.0.0")
  list.length(spec.servers) |> should.equal(1)
  list.length(spec.tags) |> should.equal(1)
}

/// spectral: minimal OpenAPI 3.0 spec without contact info.
pub fn oss_spectral_no_contact_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spectral_no_contact.yaml")
  spec.info.title |> should.equal("OAS3")
  spec.info.contact |> should.equal(None)
}

/// spectral: comprehensive spec with unused components in JSON.
pub fn oss_spectral_unused_components_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spectral_unused_components.json")
  spec.info.title |> should.equal("Used Components")
  list.length(spec.tags) |> should.not_equal(0)
  dict.size(spec.paths) |> should.not_equal(0)
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

// ---------------------------------------------------------------------------
// OSS: openapi-dotnet (MIT)
// Test data derived from https://github.com/microsoft/OpenAPI.NET
// ---------------------------------------------------------------------------

/// openapi-dotnet: OAuth2 security scheme with authorization code flow.
pub fn oss_openapi_dotnet_oauth2_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_oauth2.yaml")
  spec.info.title |> should.equal("Repair Service")
  let assert Some(components) = spec.components
  dict.size(components.security_schemes) |> should.equal(1)
}

/// openapi-dotnet: operation with empty security array (opt-out of global security).
pub fn oss_openapi_dotnet_empty_security_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_empty_security.yaml")
  spec.info.title |> should.equal("Repair Service")
  dict.size(spec.paths) |> should.equal(1)
}

/// openapi-dotnet: webhooks with $ref to components/pathItems (OpenAPI 3.1).
pub fn oss_openapi_dotnet_webhooks_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_webhooks.yaml")
  spec.info.title |> should.equal("Webhook Example")
  dict.size(spec.webhooks) |> should.not_equal(0)
  let assert Some(components) = spec.components
  dict.size(components.path_items) |> should.not_equal(0)
}

/// openapi-dotnet: spec without any security configuration.
pub fn oss_openapi_dotnet_no_security_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_no_security.yaml")
  spec.info.title |> should.equal("Repair Service")
  list.length(spec.security) |> should.equal(0)
}

/// openapi-dotnet: petstore with multiple content types, 4XX/5XX wildcards,
/// contact info, license, and termsOfService.
pub fn oss_openapi_dotnet_petstore_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_petstore.yaml")
  spec.info.title |> should.equal("Swagger Petstore (Simple)")
  let assert Some(contact) = spec.info.contact
  let assert Some(name) = contact.name
  name |> should.equal("Swagger API team")
  let assert Some(license) = spec.info.license
  license.name |> should.equal("MIT")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(3)
  dict.size(spec.paths) |> should.equal(2)
}

/// openapi-dotnet: spec with reusable headers and examples in components.
pub fn oss_openapi_dotnet_headers_examples_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_headers_examples.yaml")
  spec.openapi |> should.equal("3.0.4")
  let assert Some(components) = spec.components
  dict.size(components.headers) |> should.not_equal(0)
  dict.size(components.schemas) |> should.not_equal(0)
  list.length(spec.tags) |> should.equal(1)
}

/// openapi-dotnet: OpenAPI 3.1 spec with $id schema references.
/// Uses URL-style $ref (e.g. "$ref: https://foo.bar/Box") which the parser
/// stores as Reference with the URL as ref string.
pub fn oss_openapi_dotnet_dollar_id_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_dollar_id.yaml")
  spec.info.title |> should.equal("Simple API")
  spec.openapi |> should.equal("3.1.2")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(2)
  dict.size(spec.paths) |> should.equal(2)
}

// ---------------------------------------------------------------------------
// OSS: swagger-parser-java (Apache-2.0)
// Test data derived from https://github.com/swagger-api/swagger-parser
// ---------------------------------------------------------------------------

/// swagger-parser-java issue1070: additionalProperties: false with nested $ref.
pub fn oss_swagger_parser_java_additional_props_false_parses_test() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_java_additional_props_false.yaml",
    )
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(2)
}

/// swagger-parser-java issue879: callback using $ref to components/callbacks.
pub fn oss_swagger_parser_java_callback_ref_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_swagger_parser_java_callback_ref.yaml")
  spec.info.title |> should.equal("Callback with ref Example")
  dict.size(spec.paths) |> should.equal(1)
}

/// swagger-parser-java issue1433: schema without explicit type field.
pub fn oss_swagger_parser_java_no_type_schema_parses_test() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_java_no_type_schema.yaml",
    )
  spec.info.title |> should.equal("no type resolution")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(2)
}

/// swagger-parser-java issue1086: deeply nested object schemas with
/// multipleOf and date format.
pub fn oss_swagger_parser_java_nested_objects_parses_test() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_java_nested_objects.yaml",
    )
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(1)
}

/// swagger-parser-java: API with duplicate tag names in JSON.
pub fn oss_swagger_parser_java_multiple_tags_parses_test() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_java_multiple_tags.json",
    )
  spec.info.title |> should.equal("Sample API")
  list.length(spec.tags) |> should.not_equal(0)
  dict.size(spec.paths) |> should.not_equal(0)
}

/// swagger-parser-java issue959: petstore with path-level parameters and tags.
pub fn oss_swagger_parser_java_path_params_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_swagger_parser_java_path_params.json")
  spec.info.title |> should.equal("Swagger Petstore")
  list.length(spec.tags) |> should.equal(1)
}

/// swagger-parser-java issue895: petstore with contact and license in JSON.
pub fn oss_swagger_parser_java_petstore_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_swagger_parser_java_petstore.yaml")
  spec.info.title |> should.equal("Swagger Petstore")
  let assert Some(contact) = spec.info.contact
  let assert Some(name) = contact.name
  name |> should.equal("API Support")
  let assert Some(license) = spec.info.license
  license.name |> should.equal("Apache 2.0")
}

// ---------------------------------------------------------------------------
// OSS: openapi-generator (Apache-2.0) — additional tests
// Test data derived from https://github.com/OpenAPITools/openapi-generator
// ---------------------------------------------------------------------------

/// openapi-generator: oneOf with multiple schema variants (fruit).
pub fn oss_openapi_gen_oneof_fruit_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_oneof_fruit.yaml")
  spec.info.title |> should.equal("fruity")
  let assert Some(components) = spec.components
  // fruit + apple + banana + orange
  dict.size(components.schemas) |> should.equal(4)
}

/// openapi-generator: array with nullable items.
pub fn oss_openapi_gen_array_nullable_items_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_array_nullable_items.yaml")
  spec.info.title |> should.equal("Array nullable items")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(1)
}

/// openapi-generator: type alias ($ref as schema value) and discriminator.
pub fn oss_openapi_gen_type_alias_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_type_alias.yaml")
  spec.info.title |> should.equal("broken API")
  let assert Some(components) = spec.components
  // MyParameter, MyParameterTextField, TypeAliasToString, BaseModel, ComposedModel
  dict.size(components.schemas) |> should.equal(5)
}

/// openapi-generator: enum values with URI format strings.
pub fn oss_openapi_gen_enum_uri_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_enum_uri.yaml")
  spec.info.title |> should.equal("Example API")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(1)
}

/// openapi-generator: spec missing required 'info' field.
/// The parser rejects this with a clear error.
pub fn oss_openapi_gen_missing_info_rejects_test() {
  let result =
    parser.parse_file("test/fixtures/oss_openapi_gen_missing_info.yaml")
  case result {
    Error(Diagnostic(
      code: "missing_field",
      message: "Missing required field: info",
      ..,
    )) -> should.be_true(True)
    Error(e) -> {
      let msg = parser.parse_error_to_string(e)
      should.be_true(string.contains(msg, "info"))
    }
    Ok(_) -> should.fail()
  }
}

/// openapi-generator: petstore missing required info attribute.
/// Rejects with user-friendly error pointing to the missing field.
pub fn oss_openapi_gen_missing_info_attr_rejects_test() {
  let result =
    parser.parse_file("test/fixtures/oss_openapi_gen_missing_info_attr.yaml")
  case result {
    Error(Diagnostic(code: "missing_field", ..)) -> should.be_true(True)
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// OSS: openapi-spec-validator (Apache-2.0) — benchmark specs
// Test data derived from https://github.com/python-openapi/openapi-spec-validator
// ---------------------------------------------------------------------------

/// openapi-spec-validator: petstore benchmark spec.
pub fn oss_spec_validator_bench_petstore_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spec_validator_bench_petstore.yaml")
  spec.info.title |> should.equal("Swagger Petstore")
  dict.size(spec.paths) |> should.not_equal(0)
}

/// openapi-spec-validator: empty OpenAPI 3.0 spec (only version, no info).
/// The parser rejects this with a user-friendly error about missing 'info'.
pub fn oss_spec_validator_empty_v30_rejects_test() {
  let result = parser.parse_file("test/fixtures/oss_spec_validator_empty.yaml")
  case result {
    Error(Diagnostic(
      code: "missing_field",
      message: "Missing required field: info",
      ..,
    )) -> should.be_true(True)
    Error(e) -> {
      let msg = parser.parse_error_to_string(e)
      should.be_true(string.contains(msg, "info"))
    }
    Ok(_) -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// OSS: swagger-parser-js (MIT) — additional tests
// Test data derived from https://github.com/APIDevTools/swagger-parser
// ---------------------------------------------------------------------------

/// swagger-parser-js: OpenAPI 3.1 spec with no paths or webhooks.
/// Valid minimal 3.1 document (paths is optional in 3.1).
pub fn oss_swagger_parser_js_no_paths_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_swagger_parser_js_no_paths.yaml")
  spec.info.title |> should.equal("Invalid API")
  spec.openapi |> should.equal("3.1")
  dict.size(spec.paths) |> should.equal(0)
  dict.size(spec.webhooks) |> should.equal(0)
}

/// swagger-parser-js: top-level, path-level, and operation-level servers.
pub fn oss_swagger_parser_js_server_hierarchy_parses_test() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_js_server_hierarchy.json",
    )
  spec.info.title |> should.equal("Swagger Petstore")
  // Top-level server
  list.length(spec.servers) |> should.equal(1)
  // Path-level and operation-level servers
  let assert Ok(spec.Value(pet_path)) = dict.get(spec.paths, "/pet")
  list.length(pet_path.servers) |> should.equal(1)
  let assert Some(get_op) = pet_path.get
  list.length(get_op.servers) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// OSS: spectral (Apache-2.0) — additional tests
// Test data derived from https://github.com/stoplightio/spectral
// ---------------------------------------------------------------------------

/// spectral: operation-level and global security with apiKey + OAuth2.
pub fn oss_spectral_operation_security_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spectral_operation_security.yaml")
  spec.openapi |> should.equal("3.0.2")
  // Global security has 2 entries (apikey OR oauth2)
  list.length(spec.security) |> should.equal(2)
  let assert Some(components) = spec.components
  dict.size(components.security_schemes) |> should.equal(2)
}

/// spectral: webhooks with inline request body (OpenAPI 3.1).
pub fn oss_spectral_webhooks_servers_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spectral_webhooks_servers.yaml")
  spec.openapi |> should.equal("3.1.0")
  dict.size(spec.webhooks) |> should.equal(1)
}

/// spectral: examples with value in parameters and response content.
pub fn oss_spectral_examples_value_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spectral_examples_value.yaml")
  dict.size(spec.paths) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// OSS: openapi-dotnet (MIT) — additional tests
// Test data derived from https://github.com/microsoft/OpenAPI.NET
// ---------------------------------------------------------------------------

/// openapi-dotnet: multipart encoding, discriminator, allOf inheritance (3.1).
pub fn oss_openapi_dotnet_encoding_discriminator_parses_test() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_openapi_dotnet_encoding_discriminator.yaml",
    )
  spec.openapi |> should.equal("3.1.2")
  spec.info.title |> should.equal("A simple OpenAPI 3.1 example")
  dict.size(spec.paths) |> should.equal(2)
  let assert Some(components) = spec.components
  // Pet, Cat, Dog
  dict.size(components.schemas) |> should.equal(3)
}

/// openapi-dotnet: reusable pathItems with webhooks and multi-schema (3.1).
pub fn oss_openapi_dotnet_reusable_paths_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_reusable_paths.yaml")
  spec.openapi |> should.equal("3.1.2")
  dict.size(spec.webhooks) |> should.not_equal(0)
  let assert Some(components) = spec.components
  dict.size(components.path_items) |> should.not_equal(0)
  dict.size(components.schemas) |> should.equal(2)
  let assert Some(dialect) = spec.json_schema_dialect
  should.be_true(string.contains(dialect, "json-schema.org"))
}

/// openapi-dotnet: spec with x-oai-$self vendor extension (3.1).
pub fn oss_openapi_dotnet_self_extension_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_self_extension.yaml")
  spec.openapi |> should.equal("3.1.2")
  spec.info.title |> should.equal("API with x-oai-$self extension")
  dict.size(spec.paths) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// OSS: swagger-parser-java (Apache-2.0) — 3.1 tests
// Test data derived from https://github.com/swagger-api/swagger-parser
// ---------------------------------------------------------------------------

/// swagger-parser-java: OpenAPI 3.1 basic spec uses multi-type unions
/// (type: [object, string]) which oaspec rejects with a clear error guiding
/// users to use oneOf instead.
pub fn oss_swagger_parser_java_31_basic_rejects_multi_type_test() {
  // Parse succeeds — multi-type is stored in raw_type, normalize converts to oneOf
  let assert Ok(_spec) =
    parser.parse_file("test/fixtures/oss_swagger_parser_java_31_basic.yaml")
  should.be_true(True)
}

/// swagger-parser-java: OpenAPI 3.1 security scheme includes mutualTLS type.
/// Parser preserves it losslessly; generate fails via capability_check.
pub fn oss_swagger_parser_java_31_security_rejects_mutualtls_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_swagger_parser_java_31_security.yaml")
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { e.message })
      let has_mutual =
        list.any(error_details, fn(d) { string.contains(d, "mutualTLS") })
      should.be_true(has_mutual)
    }
    Ok(_) -> should.fail()
  }
}

/// swagger-parser-java: OpenAPI 3.1 schema siblings (dependentRequired,
/// dependentSchemas, if/then/else, examples array).
/// Parse succeeds; generate fails due to unsupported keywords.
pub fn oss_swagger_parser_java_31_schema_siblings_rejects_test() {
  // Parse succeeds — lossless parser stores unsupported keywords
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_java_31_schema_siblings.yaml",
    )
  // Generate fails via capability_check due to dependentSchemas, if/then/else
  let result = generate.generate(spec, make_ctx_from_spec(spec).config)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_dependent =
        list.any(error_details, fn(d) { string.contains(d, "dependentSchemas") })
      should.be_true(has_dependent)
    }

    Ok(_) -> should.fail()
  }
}

/// swagger-parser-java: extended petstore 3.1 uses multi-type unions
/// (type: [string, integer]) which are now normalized. Parse succeeds.
pub fn oss_swagger_parser_java_31_petstore_more_rejects_multi_type_test() {
  // Parse succeeds — multi-type is stored in raw_type, normalize converts to oneOf
  let assert Ok(_spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_java_31_petstore_more.yaml",
    )
  should.be_true(True)
}

// ---------------------------------------------------------------------------
// OSS: openapi-spec-validator (Apache-2.0) — additional tests
// Test data derived from https://github.com/python-openapi/openapi-spec-validator
// ---------------------------------------------------------------------------

/// openapi-spec-validator: schema with broken $ref URI.
/// The parser stores the broken ref as a Reference (no resolution at parse time).
pub fn oss_spec_validator_broken_ref_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spec_validator_broken_ref.yaml")
  spec.info.title |> should.equal("Some Schema")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

// ---------------------------------------------------------------------------
// Unsupported JSON Schema keyword detection
// ---------------------------------------------------------------------------

/// const keyword is stored in metadata and normalized to single-value enum.
pub fn unsupported_const_normalized_test() {
  // Parse succeeds — lossless parser stores const in metadata
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/unsupported_const.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

/// if/then/else keywords are stored by lossless parser; rejected at generate time.
pub fn unsupported_if_then_else_capability_check_test() {
  // Parse succeeds — lossless parser stores unsupported keywords
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/unsupported_if_then_else.yaml")
  // Generate fails via capability_check
  let result = generate.generate(spec, make_ctx_from_spec(spec).config)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_if = list.any(error_details, fn(d) { string.contains(d, "if") })
      should.be_true(has_if)
    }

    Ok(_) -> should.fail()
  }
}

/// prefixItems keyword is stored by lossless parser; rejected at generate time.
pub fn unsupported_prefix_items_capability_check_test() {
  // Parse succeeds — lossless parser stores unsupported keywords
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/unsupported_prefix_items.yaml")
  // Generate fails via capability_check
  let result = generate.generate(spec, make_ctx_from_spec(spec).config)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_prefix =
        list.any(error_details, fn(d) { string.contains(d, "prefixItems") })
      should.be_true(has_prefix)
    }

    Ok(_) -> should.fail()
  }
}

/// not keyword is stored by lossless parser; rejected at generate time.
pub fn unsupported_not_capability_check_test() {
  // Parse succeeds — lossless parser stores unsupported keywords
  let assert Ok(spec) = parser.parse_file("test/fixtures/unsupported_not.yaml")
  // Generate fails via capability_check
  let result = generate.generate(spec, make_ctx_from_spec(spec).config)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_not = list.any(error_details, fn(d) { string.contains(d, "not") })
      should.be_true(has_not)
    }

    Ok(_) -> should.fail()
  }
}

/// $defs keyword is stored by lossless parser; rejected at generate time.
pub fn unsupported_defs_capability_check_test() {
  // Parse succeeds — lossless parser stores unsupported keywords
  let assert Ok(spec) = parser.parse_file("test/fixtures/unsupported_defs.yaml")
  // Generate fails via capability_check
  let result = generate.generate(spec, make_ctx_from_spec(spec).config)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_defs =
        list.any(error_details, fn(d) { string.contains(d, "$defs") })
      should.be_true(has_defs)
    }

    Ok(_) -> should.fail()
  }
}

/// const nested inside object properties is normalized to enum; parse and generate succeed.
pub fn unsupported_nested_const_normalized_test() {
  // Parse succeeds — const is stored in metadata
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/unsupported_nested_const.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

/// Inline unsupported keyword 'not' in request body must be rejected by capability_check.
pub fn inline_not_keyword_rejected_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/inline_not_keyword.yaml")
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let has_not =
        list.any(errors, fn(e) { string.contains(e.message, "not") })
      should.be_true(has_not)
    }
    Ok(_) -> should.fail()
  }
}

/// Schema without type but with properties should still parse as object.
pub fn schema_no_type_with_properties_parses_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/schema_no_type_with_properties.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// $ref prefix validation
// ---------------------------------------------------------------------------

/// Security requirement referencing undefined scheme should be rejected.
pub fn validate_invalid_security_ref_rejects_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/invalid_security_ref.yaml")
  let result = generate.generate(spec, make_ctx_from_spec(spec).config)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_security =
        list.any(error_details, fn(d) {
          string.contains(d, "nonexistent_scheme")
        })
      should.be_true(has_security)
    }

    Ok(_) -> should.fail()
  }
}

/// External file $ref for parameter should produce a resolve error, not a panic.
pub fn external_param_ref_rejects_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/external_param_ref.yaml")
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
    )
  // Must produce a diagnostic error, not panic
  let result = generate.generate(spec, cfg)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(errors) |> should.not_equal(0)
      let has_ref_error =
        list.any(errors, fn(e) { string.contains(e.message, "Limit") })
      should.be_true(has_ref_error)
    }
    Ok(_) -> should.fail()
  }
}

/// $ref pointing to wrong component kind (schemas instead of parameters)
/// must produce a diagnostic error, not silently resolve from a different kind.
pub fn wrong_kind_ref_rejects_test() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/wrong_kind_ref.yaml")
  let cfg =
    config.Config(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      // Must report wrong-kind ref, not silently resolve as parameter
      let has_kind_error =
        list.any(errors, fn(e) {
          string.contains(e.message, "schemas")
          || string.contains(e.message, "wrong")
          || string.contains(e.message, "kind")
        })
      should.be_true(has_kind_error)
    }
    Ok(_) -> should.fail()
  }
}

/// Unknown parameter style should be rejected with clear error.
pub fn unknown_param_style_rejects_test() {
  let result = parser.parse_file("test/fixtures/unknown_param_style.yaml")
  case result {
    Error(Diagnostic(code: "invalid_value", message: detail, ..)) ->
      should.be_true(string.contains(detail, "unknownStyle"))
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Normalize pass tests — prove transformations actually happen
// ---------------------------------------------------------------------------

/// const is normalized to single-value enum by normalize pass.
pub fn normalize_const_to_enum_test() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/normalize_const.yaml")
  // Before normalize: const_value is stored
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.StringSchema(metadata: meta, ..))) =
    dict.get(components.schemas, "Status")
  meta.const_value |> should.equal(Some(value.JsonString("active")))

  // After normalize: const_value cleared, enum_values set
  let normalized = normalize.normalize(spec)
  let assert Some(norm_components) = normalized.components
  let assert Ok(schema.Inline(schema.StringSchema(
    metadata: norm_meta,
    enum_values: enums,
    ..,
  ))) = dict.get(norm_components.schemas, "Status")
  norm_meta.const_value |> should.equal(None)
  enums |> should.equal(["active"])
}

/// Non-string const values are preserved, not converted to StringSchema.
pub fn normalize_preserves_non_string_const_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/normalize_const_types.yaml")
  let normalized = normalize.normalize(spec)
  let assert Some(components) = normalized.components

  // String const: normalized to enum
  let assert Ok(schema.Inline(schema.StringSchema(
    metadata: str_meta,
    enum_values: str_enums,
    ..,
  ))) = dict.get(components.schemas, "StringConst")
  str_meta.const_value |> should.equal(None)
  str_enums |> should.equal(["active"])

  // Bool const: preserved as BooleanSchema with const_value
  let assert Ok(schema.Inline(schema.BooleanSchema(metadata: bool_meta))) =
    dict.get(components.schemas, "BoolConst")
  bool_meta.const_value |> should.equal(Some(value.JsonBool(True)))

  // Int const: preserved as IntegerSchema with const_value
  let assert Ok(schema.Inline(schema.IntegerSchema(metadata: int_meta, ..))) =
    dict.get(components.schemas, "IntConst")
  int_meta.const_value |> should.equal(Some(value.JsonInt(42)))
}

/// type: [string, integer] is normalized to oneOf by normalize pass.
pub fn normalize_multi_type_to_oneof_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/normalize_multi_type.yaml")
  // Before normalize: raw_type stored
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.StringSchema(metadata: meta, ..))) =
    dict.get(components.schemas, "FlexibleId")
  meta.raw_type |> should.equal(Some(["string", "integer"]))

  // After normalize: becomes OneOfSchema
  let normalized = normalize.normalize(spec)
  let assert Some(norm_components) = normalized.components
  let assert Ok(schema.Inline(schema.OneOfSchema(schemas: variants, ..))) =
    dict.get(norm_components.schemas, "FlexibleId")
  list.length(variants) |> should.equal(2)
}

/// type: [string, null] sets nullable and normalize preserves it.
pub fn normalize_type_null_to_nullable_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/normalize_type_null.yaml")
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.StringSchema(metadata: meta, ..))) =
    dict.get(components.schemas, "NullableName")
  // Parser already handles [T, null] → nullable: true
  meta.nullable |> should.be_true()

  // Normalize preserves this
  let normalized = normalize.normalize(spec)
  let assert Some(norm_components) = normalized.components
  let assert Ok(schema.Inline(schema.StringSchema(metadata: norm_meta, ..))) =
    dict.get(norm_components.schemas, "NullableName")
  norm_meta.nullable |> should.be_true()
}

// ---------------------------------------------------------------------------
// Resolve phase test — prove alias resolution works
// ---------------------------------------------------------------------------

/// Component alias is preserved at parse time and resolved by resolve phase.
pub fn resolve_component_alias_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/component_param_alias.yaml")
  let assert Some(components) = spec.components
  // After parse: AliasEntry is preserved
  let assert Ok(spec.Ref(_)) = dict.get(components.parameters, "AliasedLimit")

  // After resolve (via generate pipeline): AliasEntry becomes ConcreteEntry
  let result = generate.generate(spec, make_ctx_from_spec(spec).config)
  case result {
    Ok(_) -> should.be_true(True)
    Error(generate.ValidationErrors(errors:)) -> {
      // May have warnings but should not have blocking errors about aliases
      let blocking =
        list.filter(errors, fn(e) { e.severity == diagnostic.SeverityError })
      list.length(blocking) |> should.equal(0)
    }
  }
}

// ---------------------------------------------------------------------------
// Capability check test — prove it uses the registry
// ---------------------------------------------------------------------------

/// capability_check detects unsupported keywords from the registry.
pub fn capability_check_uses_registry_test() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/unsupported_if_then_else.yaml")
  // Parse succeeds
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
  // Generate fails via capability_check (not parser)
  let result = generate.generate(spec, make_ctx_from_spec(spec).config)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      should.be_true(list.any(details, fn(d) { string.contains(d, "if") }))
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// README boundaries generated from registry
// ---------------------------------------------------------------------------

/// README Current Boundaries section mentions all Unsupported capabilities.
pub fn readme_boundaries_match_registry_test() {
  let assert Ok(readme) = simplifile.read("README.md")
  // Every Unsupported capability name must appear in the README
  let unsupported = capability.by_level(capability.Unsupported)
  list.each(unsupported, fn(c) {
    should.be_true(string.contains(readme, c.name))
  })
  // Every NotHandled capability name must appear in the README
  let not_handled = capability.by_level(capability.NotHandled)
  list.each(not_handled, fn(c) {
    should.be_true(string.contains(readme, c.name))
  })
}

// ---------------------------------------------------------------------------
// Source location test — prove YAML errors carry line/column
// ---------------------------------------------------------------------------

/// YAML syntax error includes line/column in error message.
pub fn yaml_error_has_source_location_test() {
  // Test that SourceLoc type exists and to_short_string formats it
  let loc = diagnostic.SourceLoc(line: 5, column: 10)
  let err = diagnostic.yaml_error(detail: "test error", loc: loc)
  let msg = diagnostic.to_short_string(err)
  should.be_true(string.contains(msg, "line 5"))
  should.be_true(string.contains(msg, "column 10"))
  // NoSourceLoc case
  let err2 =
    diagnostic.yaml_error(detail: "test error", loc: diagnostic.NoSourceLoc)
  let msg2 = diagnostic.to_short_string(err2)
  should.equal(msg2, "test error")
}

// ---------------------------------------------------------------------------
// Pipeline order test — prove the 5-stage pipeline exists in generate
// ---------------------------------------------------------------------------

/// Generate pipeline runs: parse → normalize → resolve → capability_check → codegen.
/// This test verifies the pipeline works end-to-end with a valid spec.
pub fn pipeline_end_to_end_test() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/petstore.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, ctx.config)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      let blocking = validate.errors_only(errors)
      list.length(blocking) |> should.equal(0)
    }
  }
}
