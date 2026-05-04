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
  let _ = support.server_router_uses_underscored_unused_route_args_case()
}

pub fn server_security_codegen_test() {
  let _ = support.security_and_3_schemes_wildcard_case()
}
