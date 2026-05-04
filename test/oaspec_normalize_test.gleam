import oaspec_support as support

pub fn capability_registry_and_pipeline_test() {
  let _ = support.validation_errors_include_hints_case()
  let _ = support.capability_warnings_include_hints_case()
  let _ = support.capability_registry_names_appear_in_readme_boundaries_case()
  let _ = support.capability_check_uses_registry_case()
  let _ = support.readme_boundaries_match_registry_case()
  let _ = support.server_boundary_checklist_matches_registry_case()
  let _ = support.pure_generate_pipeline_case()
  let _ = support.pipeline_end_to_end_case()
  let _ = support.capability_check_warns_on_callbacks_case()
}

pub fn normalize_and_capability_cases_test() {
  let _ = support.openapi_31_multi_type_union_case()
  let _ = support.unsupported_const_normalized_case()
  let _ = support.unsupported_if_then_else_capability_check_case()
  let _ = support.unsupported_prefix_items_capability_check_case()
  let _ = support.unsupported_not_capability_check_case()
  let _ = support.unsupported_defs_capability_check_case()
  let _ = support.unsupported_nested_const_normalized_case()
  let _ = support.inline_not_keyword_rejected_case()
  let _ = support.normalize_const_to_enum_case()
  let _ = support.normalize_preserves_non_string_const_case()
  let _ = support.normalize_flags_non_string_const_as_unsupported_case()
  let _ = support.generate_rejects_non_string_const_case()
  let _ = support.generate_rejects_multi_type_with_constraints_case()
  let _ = support.normalize_multi_type_to_oneof_case()
  let _ = support.normalize_type_null_to_nullable_case()
}
