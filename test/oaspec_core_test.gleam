import oaspec_support as support

pub fn naming_basics_test() {
  let _ = support.to_pascal_case_case()
  let _ = support.to_pascal_case_from_kebab_case()
  let _ = support.to_pascal_case_from_camel_case()
  let _ = support.to_snake_case_case()
  let _ = support.to_snake_case_from_camel_case()
  let _ = support.capitalize_case()
  let _ = support.deduplicate_names_no_collision_case()
  let _ = support.deduplicate_names_with_collision_case()
  let _ = support.deduplicate_names_triple_collision_case()
  let _ = support.deduplicate_names_empty_case()
  let _ = support.to_pascal_case_abbreviation_case()
  let _ = support.to_pascal_case_all_caps_preserved_case()
  let _ = support.to_snake_case_abbreviation_case()
  let _ = support.to_snake_case_consecutive_caps_case()
  let _ = support.to_pascal_case_with_numbers_case()
  let _ = support.to_snake_case_with_hyphen_case()
  let _ = support.to_snake_case_with_dots_case()
}

pub fn config_defaults_test() {
  let _ = support.load_config_case()
  let _ = support.config_not_found_case()
  let _ = support.parse_mode_case()
  let _ = support.config_validate_default_server_case()
  let _ = support.config_validate_default_client_case()
  let _ = support.config_validate_default_both_case()
  let _ = support.config_validate_field_case()
  let _ = support.config_validate_default_when_omitted_case()
}

pub fn config_error_formatting_test() {
  let _ = support.config_error_to_string_file_not_found_case()
  let _ = support.config_error_to_string_file_read_error_case()
  let _ = support.config_error_to_string_parse_error_case()
  let _ = support.config_error_to_string_missing_field_case()
  let _ = support.config_error_to_string_invalid_value_case()
  let _ = support.config_load_missing_input_returns_missing_field_case()
}

pub fn config_output_paths_test() {
  let _ = support.config_client_only_default_drops_client_suffix_case()
  let _ = support.config_with_output_client_only_drops_suffix_case()
  let _ = support.config_with_output_both_keeps_suffix_case()
  let _ = support.config_package_dir_mismatch_case()
  let _ = support.config_client_dir_mismatch_case()
  let _ = support.config_package_dir_match_case()
  let _ = support.config_output_dir_under_src_subdir_is_rejected_case()
  let _ = support.config_output_dir_directly_under_src_is_accepted_case()
  let _ = support.config_output_dir_outside_src_is_accepted_case()
  let _ = support.config_output_dir_deep_under_src_is_rejected_case()
  let _ =
    support.config_output_dir_client_only_under_src_subdir_is_rejected_case()
  let _ = support.config_nested_package_dir_match_case()
  let _ = support.config_nested_package_wrong_middle_segment_rejected_case()
  let _ = support.config_nested_package_wrong_last_segment_rejected_case()
  let _ = support.config_nested_package_client_no_suffix_accepted_case()
  let _ = support.config_nested_package_layout_under_src_accepted_case()
  let _ = support.config_nested_package_layout_under_src_subdir_rejected_case()
  let _ = support.config_nested_package_layout_outside_src_accepted_case()
  let _ = support.config_nested_package_three_segments_match_case()
  let _ = support.config_nested_package_trailing_slash_match_case()
  let _ =
    support.config_output_dir_double_src_with_immediate_parent_rejected_case()
}

pub fn include_filter_test() {
  let _ = support.config_load_all_single_target_case()
  let _ = support.config_load_all_multi_target_case()
  let _ = support.config_load_targets_per_target_include_case()
  let _ = support.config_load_targets_per_target_output_case()
  let _ = support.config_load_target_missing_package_rejected_case()
  let _ = support.config_load_targets_empty_rejected_case()
  let _ = support.config_load_multi_target_via_load_returns_error_case()
  let _ = support.config_load_parses_include_block_case()
  let _ = support.config_load_omitted_include_is_empty_case()
  let _ = support.config_default_include_is_empty_case()
  let _ = support.config_with_include_round_trip_case()
  let _ = support.filter_apply_empty_filter_returns_spec_unchanged_case()
  let _ = support.filter_apply_path_glob_keeps_matching_paths_case()
  let _ = support.filter_apply_unknown_path_drops_everything_case()
  let _ = support.filter_apply_tag_membership_keeps_tagged_operations_case()
  let _ = support.filter_apply_tags_or_paths_unions_case()
  let _ = support.filter_path_matches_exact_and_glob_case()
  let _ = support.reachability_prune_drops_unreferenced_components_case()
  let _ =
    support.reachability_prune_keeps_transitively_reachable_components_case()
  let _ =
    support.reachability_prune_with_no_surviving_operations_drops_everything_case()
  let _ =
    support.reachability_prune_pipeline_omits_dead_types_in_generated_output_case()
}

pub fn content_type_helpers_test() {
  let _ = support.content_type_from_string_case()
  let _ = support.content_type_x_ndjson_is_supported_response_case()
  let _ = support.content_type_text_html_aliases_to_text_plain_case()
  let _ = support.content_type_text_x_markdown_aliases_to_text_plain_case()
  let _ = support.content_type_vendor_application_aliases_to_octet_stream_case()
  let _ = support.content_type_image_png_still_unsupported_case()
  let _ = support.content_type_audio_video_still_unsupported_case()
  let _ = support.content_type_text_html_is_supported_response_case()
  let _ = support.content_type_vendor_diff_is_supported_response_case()
  let _ = support.content_type_text_x_markdown_is_supported_request_case()
  let _ = support.content_type_to_string_case()
  let _ = support.content_type_is_supported_case()
  let _ = support.content_type_is_supported_request_case()
  let _ = support.content_type_is_supported_response_case()
  let _ = support.content_type_roundtrip_case()
  let _ =
    support.capability_registry_covers_content_type_response_helpers_case()
  let _ = support.capability_registry_covers_content_type_request_helpers_case()
  let _ = support.is_supported_request_rejects_unsupported_content_type_case()
  let _ = support.wildcard_content_type_passes_validation_case()
  let _ = support.wildcard_content_type_classified_as_supported_case()
  let _ = support.wildcard_content_type_generates_bitarray_bodies_case()
  let _ = support.multipart_object_array_fields_pass_validation_case()
  let _ = support.multipart_object_array_fields_emit_expected_parts_case()
  let _ = support.deep_object_nested_object_passes_client_validation_case()
  let _ = support.deep_object_nested_object_emits_bracketed_query_case()
  let _ = support.deep_object_param_client_imports_some_none_case()
  let _ = support.multipart_object_array_client_imports_list_json_case()
  let _ = support.wildcard_request_body_uses_bytes_body_case()
}

pub fn location_index_source_loc_test() {
  let _ = support.location_index_build_extracts_locations_case()
  let _ = support.location_index_lookup_field_returns_source_loc_case()
  let _ = support.location_index_lookup_missing_returns_no_source_loc_case()
  let _ = support.location_index_empty_returns_no_source_loc_case()
  let _ = support.missing_field_diagnostic_has_source_location_case()
  let _ = support.location_index_root_path_has_source_loc_case()
  let _ = support.yaml_error_has_source_location_case()
}

pub fn capability_check_source_loc_test() {
  let _ =
    support.location_index_lookup_with_ancestor_falls_back_to_parent_case()
  let _ =
    support.location_index_lookup_with_ancestor_no_match_returns_no_source_loc_case()
  let _ = support.capability_check_attaches_source_loc_to_keyword_error_case()
  let _ = support.diagnostic_render_includes_file_path_and_loc_case()
  let _ = support.diagnostic_render_without_file_path_matches_to_string_case()
}
