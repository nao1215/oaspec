import oaspec_support as support

pub fn oss_libopenapi_cases_test() {
  let _ = support.oss_libopenapi_all_components_parses_case()
  let _ = support.oss_libopenapi_all_components_validates_security_case()
  let _ = support.oss_libopenapi_burgershop_rejects_not_keyword_case()
  let _ = support.oss_libopenapi_petstorev3_parses_case()
  let _ = support.oss_libopenapi_circular_rejects_missing_info_case()
}

pub fn oss_oapi_codegen_cases_test() {
  let _ = support.oss_oapi_codegen_cookies_parses_case()
  let _ = support.oss_oapi_codegen_name_conflicts_parses_case()
  let _ = support.oss_oapi_codegen_illegal_enums_parses_case()
  let _ = support.oss_oapi_codegen_nullable_parses_case()
  let _ = support.oss_oapi_codegen_nullable_generates_case()
  let _ = support.oss_oapi_codegen_recursive_allof_parses_case()
  let _ = support.oss_oapi_codegen_allof_additional_parses_case()
  let _ = support.oss_oapi_codegen_allof_additional_generates_case()
  let _ = support.oss_oapi_codegen_security_parses_case()
  let _ = support.oss_oapi_codegen_multi_content_parses_case()
  let _ =
    support.oss_oapi_codegen_multi_content_rejects_unsupported_types_case()
  let _ = support.oss_oapi_codegen_issue_312_colon_path_parses_case()
  let _ = support.oss_oapi_codegen_issue_312_generates_case()
  let _ = support.oss_oapi_codegen_issue_936_recursive_oneof_parses_case()
  let _ =
    support.oss_oapi_codegen_issue_52_recursive_additional_props_parses_case()
  let _ = support.oss_oapi_codegen_issue_52_generates_case()
  let _ = support.oss_oapi_codegen_issue_1168_allof_discriminator_parses_case()
  let _ = support.oss_oapi_codegen_issue_1168_problem_json_generates_case()
  let _ = support.oss_oapi_codegen_issue_832_recursive_oneof_parses_case()
  let _ = support.oss_oapi_codegen_issue_579_enum_special_chars_parses_case()
  let _ = support.oss_oapi_codegen_issue_579_generates_case()
  let _ = support.oss_oapi_codegen_issue_2185_nullable_array_items_parses_case()
  let _ = support.oss_oapi_codegen_issue_2185_generates_case()
  let _ = support.oss_oapi_codegen_issue_1087_rejects_unresolved_ref_case()
  let _ = support.oss_oapi_codegen_issue_1963_parses_case()
  let _ = support.oss_oapi_codegen_issue_2232_parses_case()
  let _ = support.oss_oapi_codegen_issue_2238_header_array_parses_case()
  let _ = support.oss_oapi_codegen_issue_2113_rejects_external_ref_case()
  let _ = support.oss_oapi_codegen_issue_1397_rejects_missing_info_case()
  let _ = support.oss_oapi_codegen_issue_1914_rejects_missing_info_case()
  let _ = support.oss_oapi_codegen_head_digit_httpheader_parses_case()
  let _ = support.oss_oapi_codegen_head_digit_operation_id_parses_case()
}

pub fn oss_openapi_generator_cases_test() {
  let _ = support.oss_openapi_gen_issue_4947_wildcard_content_parses_case()
  let _ = support.oss_openapi_gen_issue_9719_dot_operationid_parses_case()
  let _ = support.oss_openapi_gen_issue_9719_generates_case()
  let _ = support.oss_openapi_gen_issue_13917_patch_allof_parses_case()
  let _ = support.oss_openapi_gen_issue_13917_rejects_json_patch_content_case()
  let _ = support.oss_openapi_gen_petstore_server_parses_case()
  let _ = support.oss_openapi_gen_petstore_server_generates_client_case()
  let _ = support.oss_openapi_gen_issue_11897_array_of_string_parses_case()
  let _ = support.oss_openapi_gen_issue_11897_generates_case()
  let _ =
    support.oss_openapi_gen_issue_14731_discriminator_mapping_parses_case()
  let _ = support.oss_openapi_gen_issue_1666_optional_body_parses_case()
  let _ = support.oss_openapi_gen_issue_1666_generates_case()
  let _ = support.oss_openapi_gen_recursion_bug_4650_parses_case()
  let _ = support.oss_openapi_gen_issue_18516_parses_case()
  let _ = support.oss_openapi_gen_issue_18516_generates_case()
  let _ = support.oss_openapi_gen_oneof_fruit_parses_case()
  let _ = support.oss_openapi_gen_array_nullable_items_parses_case()
  let _ = support.combined_oneof_nullable_array_parses_case()
  let _ = support.combined_oneof_nullable_array_generates_tagged_union_case()
  let _ = support.oss_openapi_gen_type_alias_parses_case()
  let _ = support.oss_openapi_gen_enum_uri_parses_case()
  let _ = support.oss_openapi_gen_missing_info_rejects_case()
  let _ = support.oss_openapi_gen_missing_info_attr_rejects_case()
}

pub fn oss_kiota_cases_test() {
  let _ = support.oss_kiota_discriminator_parses_case()
  let _ = support.oss_kiota_discriminator_generates_case()
  let _ = support.oss_kiota_derived_types_parses_case()
  let _ = support.oss_kiota_derived_types_generates_case()
  let _ = support.oss_kiota_multi_security_parses_case()
  let _ = support.oss_kiota_multi_security_generates_case()
}

pub fn oss_kin_openapi_cases_test() {
  let _ = support.oss_kin_openapi_link_example_parses_case()
  let _ = support.oss_kin_openapi_issue409_pattern_parses_case()
  let _ = support.oss_kin_openapi_callbacks_parses_case()
  let _ = support.oss_kin_openapi_empty_media_type_parses_case()
  let _ = support.oss_kin_openapi_date_example_parses_case()
  let _ = support.oss_kin_openapi_param_override_parses_case()
  let _ = support.oss_kin_openapi_additional_properties_parses_case()
  let _ = support.oss_kin_openapi_example_refs_parses_case()
  let _ = support.oss_kin_openapi_minimal_json_parses_case()
  let _ = support.oss_kin_openapi_components_json_rejects_invalid_scheme_case()
}

pub fn oss_spec_validator_cases_test() {
  let _ = support.oss_spec_validator_petstore_parses_case()
  let _ = support.oss_spec_validator_read_write_only_parses_case()
  let _ = support.oss_spec_validator_missing_description_rejects_case()
  let _ = support.oss_spec_validator_recursive_property_parses_case()
  let _ = support.oss_spec_validator_petstore_v31_parses_case()
  let _ = support.oss_spec_validator_bench_petstore_parses_case()
  let _ = support.oss_spec_validator_empty_v30_rejects_case()
  let _ = support.oss_spec_validator_broken_ref_parses_case()
}

pub fn oss_swagger_parser_js_and_spectral_cases_test() {
  let _ = support.oss_swagger_parser_js_relative_server_parses_case()
  let _ = support.oss_swagger_parser_js_no_paths_parses_case()
  let _ = support.oss_swagger_parser_js_server_hierarchy_parses_case()
  let _ = support.oss_spectral_valid_parses_case()
  let _ = support.oss_spectral_no_contact_parses_case()
  let _ = support.oss_spectral_unused_components_parses_case()
  let _ = support.oss_spectral_operation_security_parses_case()
  let _ = support.oss_spectral_webhooks_servers_parses_case()
  let _ = support.oss_spectral_examples_value_parses_case()
}

pub fn oss_openapi_dotnet_cases_test() {
  let _ = support.oss_openapi_dotnet_oauth2_parses_case()
  let _ = support.oss_openapi_dotnet_empty_security_parses_case()
  let _ = support.oss_openapi_dotnet_webhooks_parses_case()
  let _ = support.oss_openapi_dotnet_no_security_parses_case()
  let _ = support.oss_openapi_dotnet_petstore_parses_case()
  let _ = support.oss_openapi_dotnet_headers_examples_parses_case()
  let _ = support.oss_openapi_dotnet_dollar_id_parses_case()
  let _ = support.oss_openapi_dotnet_encoding_discriminator_parses_case()
  let _ = support.oss_openapi_dotnet_reusable_paths_parses_case()
  let _ = support.oss_openapi_dotnet_self_extension_parses_case()
}

pub fn oss_swagger_parser_java_cases_test() {
  let _ = support.oss_swagger_parser_java_additional_props_false_parses_case()
  let _ = support.oss_swagger_parser_java_callback_ref_parses_case()
  let _ = support.oss_swagger_parser_java_no_type_schema_parses_case()
  let _ = support.oss_swagger_parser_java_nested_objects_parses_case()
  let _ = support.oss_swagger_parser_java_multiple_tags_parses_case()
  let _ = support.oss_swagger_parser_java_path_params_parses_case()
  let _ = support.oss_swagger_parser_java_petstore_parses_case()
  let _ = support.oss_swagger_parser_java_31_basic_rejects_multi_type_case()
  let _ = support.oss_swagger_parser_java_31_security_rejects_mutualtls_case()
  let _ = support.oss_swagger_parser_java_31_schema_siblings_rejects_case()
  let _ =
    support.oss_swagger_parser_java_31_petstore_more_rejects_multi_type_case()
}
