import oaspec_support as support

pub fn validator_core_acceptance_test() {
  let _ = support.validate_accepts_array_parameter_case()
  let _ = support.validate_accepts_optional_array_parameter_case()
  let _ = support.validate_accepts_text_plain_response_case()
  let _ = support.validate_accepts_text_plain_request_body_case()
  let _ = support.validate_accepts_octet_stream_request_body_case()
  let _ = support.validate_accepts_deep_object_case()
  let _ = support.validate_accepts_complex_schema_parameter_case()
  let _ = support.validate_accepts_referenced_parameter_schemas_case()
  let _ = support.validate_accepts_multipart_form_data_case()
  let _ = support.validate_rejects_unstringifiable_multipart_fields_case()
  let _ =
    support.validate_broken_spec_accepts_inline_oneof_after_hoisting_case()
  let _ =
    support.validate_broken_spec_accepts_untyped_additional_properties_case()
  let _ = support.validate_missing_responses_rejects_case()
  let _ = support.validate_deep_inline_oneof_in_request_body_accepted_case()
  let _ = support.validate_deep_additional_properties_in_response_case()
  let _ = support.validate_rejects_duplicate_operation_id_case()
  let _ =
    support.validate_rejects_operation_ids_colliding_after_snake_case_case()
  let _ = support.validate_accepts_unique_operation_ids_case()
  let _ = support.validate_accepts_typed_additional_properties_case()
  let _ = support.validate_accepts_untyped_additional_properties_case()
  let _ = support.validate_petstore_has_no_errors_case()
  let _ = support.validate_complex_supported_has_no_errors_case()
}

pub fn validator_generation_boundary_test() {
  let _ = support.unbound_path_template_parameter_case()
  let _ = support.path_level_parameter_binds_template_case()
  let _ = support.bound_path_template_parameter_case()
  let _ = support.unsupported_parameter_style_matrix_case()
  let _ = support.supported_parameter_style_form_case()
  let _ =
    support.validate_request_content_type_message_includes_form_urlencoded_case()
  let _ = support.validate_response_content_type_message_includes_xml_case()
  let _ = support.form_urlencoded_non_object_schema_rejected_case()
  let _ = support.form_urlencoded_object_schema_passes_case()
  let _ = support.deep_object_nested_object_rejected_case()
  let _ = support.deep_object_flat_properties_passes_case()
  let _ = support.unresolved_ref_detected_by_validator_case()
  let _ = support.resolved_ref_passes_validator_case()
  let _ = support.validate_invalid_security_ref_rejects_case()
  let _ = support.unknown_param_style_rejects_case()
  let _ = support.pipe_delimited_in_header_rejects_case()
  let _ = support.space_delimited_non_array_rejects_case()
  let _ = support.validate_accepts_delimited_param_styles_case()
}

pub fn validator_server_codegen_boundaries_test() {
  let _ = support.validate_non_json_request_body_unsupported_for_server_case()
  let _ =
    support.validate_form_urlencoded_body_multi_level_nesting_accepted_case()
  let _ = support.validate_json_request_body_ok_for_server_case()
  let _ = support.server_request_shape_boundary_fixtures_case()
  let _ = support.validate_rejects_array_params_for_server_codegen_case()
  let _ = support.validate_accepts_deep_object_params_for_server_codegen_case()
  let _ = support.validate_rejects_path_complex_params_for_server_codegen_case()
  let _ = support.validate_accepts_cookie_params_for_server_codegen_case()
  let _ = support.validate_accepts_header_array_params_for_server_codegen_case()
  let _ = support.validate_accepts_query_array_params_for_server_codegen_case()
  let _ =
    support.validate_accepts_form_urlencoded_body_for_server_codegen_case()
  let _ =
    support.validate_accepts_nested_form_urlencoded_body_for_server_codegen_case()
  let _ = support.validate_accepts_multipart_body_for_server_codegen_case()
  let _ =
    support.validate_accepts_form_urlencoded_ref_fields_for_server_codegen_case()
  let _ =
    support.validate_accepts_multipart_ref_fields_for_server_codegen_case()
  let _ = support.validate_multipart_primitive_array_field_accepted_case()
  let _ = support.validate_form_urlencoded_two_level_nesting_accepted_case()
  let _ = support.validate_deep_object_referenced_enum_leaf_accepted_case()
  let _ =
    support.validate_deep_object_referenced_primitive_alias_accepted_case()
}

pub fn validator_warnings_and_modes_test() {
  let _ = support.object_query_param_without_deep_object_warns_not_errors_case()
  let _ = support.oneof_primitive_query_param_without_style_warns_case()
  let _ = support.object_query_param_with_deep_object_passes_case()
  let _ = support.client_mode_ignores_server_target_validation_errors_case()
  let _ = support.filter_by_mode_drops_server_errors_for_client_case()
  let _ = support.filter_by_mode_drops_client_errors_for_server_case()
  let _ = support.filter_by_mode_keeps_all_errors_for_both_case()
  let _ = support.generation_summary_includes_warnings_case()
  let _ = support.validate_warns_multi_content_responses_for_server_case()
  let _ =
    support.integration_script_uses_warnings_as_errors_for_server_builds_case()
  let _ = support.capability_warnings_dont_block_case()
  let _ = support.readme_no_optional_path_param_claim_case()
  let _ = support.callback_parse_error_not_swallowed_case()
}

pub fn validator_feature_fixtures_test() {
  let _ = support.validate_wildcard_status_codes_case()
  let _ = support.validate_format_types_case()
  let _ = support.validate_enum_edge_cases_case()
  let _ = support.validate_mixed_param_locations_case()
  let _ = support.validate_complex_discriminator_case()
  let _ = support.validate_optional_required_combinations_case()
}
