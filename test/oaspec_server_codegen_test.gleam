import gleam/list
import gleam/string
import gleeunit/should
import oaspec/config
import oaspec/generate
import oaspec/internal/codegen/context
import oaspec/openapi/parser
import oaspec_support as support

pub fn server_param_and_body_codegen_test() {
  let _ = support.server_bool_path_param_case_insensitive_case()
  let _ = support.server_bool_query_param_case_insensitive_case()
  let _ = support.server_header_param_name_lowercased_case()
  let _ = support.server_optional_header_param_name_lowercased_case()
  let _ = support.server_bool_optional_query_param_case_insensitive_case()
  let _ = support.server_float_path_param_parsed_case()
  let _ =
    support.server_cookie_params_are_generated_without_todo_placeholders_case()
  let _ = support.server_cookie_router_imports_list_for_cookie_lookup_case()
  let _ = support.server_cookie_router_percent_decodes_cookie_values_case()
  let _ = support.server_query_and_header_scalars_are_parsed_case()
  let _ = support.server_header_array_params_are_parsed_case()
  let _ = support.server_query_array_params_use_query_multimap_case()
  let _ = support.server_deep_object_params_are_parsed_case()
  let _ = support.server_form_urlencoded_body_is_parsed_case()
  let _ = support.server_nested_form_urlencoded_body_is_parsed_case()
  let _ = support.server_multipart_body_is_parsed_case()
  let _ = support.server_form_urlencoded_ref_fields_are_parsed_case()
  let _ = support.server_multipart_ref_fields_are_parsed_case()
  let _ = support.server_multipart_enum_field_dispatches_to_variant_case()
  let _ = support.server_form_urlencoded_enum_field_dispatches_to_variant_case()
  let _ = support.server_cookie_param_generates_cookie_lookup_case()
  let _ = support.server_cookie_param_optional_string_case()
  let _ = support.server_cookie_param_integer_case()
  let _ = support.server_cookie_param_boolean_case()
  let _ = support.server_cookie_param_float_case()
  let _ = support.server_multipart_array_field_codegen_case()
  let _ = support.server_form_urlencoded_two_level_nesting_codegen_case()
}

pub fn response_types_and_server_outputs_test() {
  let _ = support.response_types_omits_types_import_when_no_body_case()
  let _ = support.server_multi_content_response_sets_first_content_type_case()
  let _ = support.response_types_includes_types_import_when_ref_body_case()
  let _ = support.server_wildcard_status_generates_response_types_case()
  let _ = support.client_wildcard_status_generates_client_case()
  let _ = support.client_no_servers_generates_case()
  let _ = support.server_empty_response_body_generates_case()
  let _ = support.client_default_response_only_generates_case()
  let _ = support.server_default_response_only_generates_case()
  let _ = support.server_default_response_carries_status_field_case()
  let _ = support.client_default_response_passes_status_through_case()
  let _ = support.octet_stream_request_body_emits_bit_array_case()
  let _ = support.server_router_uses_underscored_unused_route_args_case()
}

pub fn server_security_codegen_test() {
  let _ = support.security_and_3_schemes_wildcard_case()
}

// --- `handlers:` layout ---

fn generate_server_files(
  spec_path: String,
  layout: config.HandlerLayout,
) -> List(context.GeneratedFile) {
  let assert Ok(spec) = parser.parse_file(spec_path)
  let cfg =
    config.new(
      input: spec_path,
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
      validate: True,
    )
    |> config.with_handler_layout(layout)
  let assert Ok(summary) = generate.generate(spec, cfg)
  summary.files
}

fn file_content(files: List(context.GeneratedFile), path: String) -> String {
  let assert Ok(file) = list.find(files, fn(f) { f.path == path })
  file.content
}

pub fn config_handlers_defaults_to_single_file_test() {
  let assert Ok(cfg) = config.load("test/fixtures/oaspec.yaml")
  config.handler_layout(cfg) |> should.equal(config.SingleFile)
}

pub fn config_handlers_per_operation_is_shared_by_every_target_test() {
  let assert Ok(cfgs) =
    config.load_all("test/fixtures/oaspec_handlers_per_operation.yaml")
  cfgs
  |> list.map(config.handler_layout)
  |> should.equal([config.PerOperation, config.PerOperation])
}

pub fn config_handlers_rejects_unknown_layout_test() {
  config.load("test/fixtures/oaspec_handlers_invalid.yaml")
  |> should.equal(
    Error(config.InvalidValue(
      field: "handlers",
      detail: "must be one of: single, per_operation (got: per_tag)",
    )),
  )
}

pub fn single_file_layout_keeps_stubs_in_handlers_gleam_test() {
  let files =
    generate_server_files("test/fixtures/petstore.yaml", config.SingleFile)
  files
  |> list.filter(fn(f) { string.starts_with(f.path, "handlers/") })
  |> should.equal([])
  file_content(files, "handlers.gleam")
  |> string.contains("pub fn get_pet(")
  |> should.be_true()
}

pub fn per_operation_layout_writes_one_user_owned_stub_per_operation_test() {
  let files =
    generate_server_files("test/fixtures/petstore.yaml", config.PerOperation)
  let stubs =
    list.filter(files, fn(f) { string.starts_with(f.path, "handlers/") })
  stubs
  |> list.map(fn(f) { #(f.path, f.write_mode) })
  |> should.equal([
    #("handlers/list_pets.gleam", context.SkipIfExists),
    #("handlers/create_pet.gleam", context.SkipIfExists),
    #("handlers/get_pet.gleam", context.SkipIfExists),
    #("handlers/delete_pet.gleam", context.SkipIfExists),
  ])
  let get_pet = file_content(files, "handlers/get_pet.gleam")
  get_pet
  |> string.contains("import api/handlers.{type State}")
  |> should.be_true()
  get_pet |> string.contains("pub fn get_pet(") |> should.be_true()
}

pub fn per_operation_layout_handlers_gleam_holds_only_state_test() {
  let files =
    generate_server_files("test/fixtures/petstore.yaml", config.PerOperation)
  let handlers = file_content(files, "handlers.gleam")
  handlers |> string.contains("pub type State {") |> should.be_true()
  handlers |> string.contains("pub fn ") |> should.be_false()
  handlers |> string.contains("import ") |> should.be_false()
}

pub fn per_operation_layout_delegator_aliases_each_handler_module_test() {
  // An operation named like another generated module must not produce
  // a duplicate import in handlers_generated.gleam.
  let files =
    generate_server_files(
      "test/fixtures/per_operation_handlers.yaml",
      config.PerOperation,
    )
  let delegator = file_content(files, "handlers_generated.gleam")
  delegator
  |> string.contains(
    "import api/handlers/request_types as request_types_handler",
  )
  |> should.be_true()
  delegator
  |> string.contains("import api/handlers/handlers as handlers_handler")
  |> should.be_true()
  delegator
  |> string.contains("request_types_handler.request_types(state, req)")
  |> should.be_true()
  // Reserved words are escaped in the module path as well.
  delegator
  |> string.contains("import api/handlers/echo_ as echo__handler")
  |> should.be_true()
}

pub fn per_operation_stub_imports_request_types_only_when_used_test() {
  let files =
    generate_server_files(
      "test/fixtures/per_operation_handlers.yaml",
      config.PerOperation,
    )
  file_content(files, "handlers/health.gleam")
  |> string.contains("import api/request_types")
  |> should.be_false()
  file_content(files, "handlers/echo_.gleam")
  |> string.contains("import api/request_types")
  |> should.be_true()
}

pub fn router_skips_encode_import_for_primitive_json_responses_test() {
  // Every response in this fixture is a primitive JSON schema, which the
  // router encodes with `json.*`; importing `api/encode` there is an
  // unused import that fails `gleam build --warnings-as-errors`.
  let files =
    generate_server_files(
      "test/fixtures/per_operation_handlers.yaml",
      config.SingleFile,
    )
  file_content(files, "router.gleam")
  |> string.contains("import api/encode")
  |> should.be_false()
  generate_server_files("test/fixtures/petstore.yaml", config.SingleFile)
  |> file_content("router.gleam")
  |> string.contains("import api/encode")
  |> should.be_true()
}
