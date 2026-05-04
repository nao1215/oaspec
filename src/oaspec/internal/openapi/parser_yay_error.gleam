//// `yay` → diagnostic bridge. Turns extractor and selector failures
//// from the `yay` YAML library into the project's `Diagnostic` type
//// via the pure `parser_error.missing_field_with_hint` helper.
////
//// Split out of `parser_error` so the diagnostic-assembly logic itself
//// stays target-neutral and only the yay-specific detail extraction
//// carries the BEAM coupling.

import gleam/int
import oaspec/internal/openapi/parser_error
import oaspec/openapi/diagnostic.{type Diagnostic, type SourceLoc}
import yay

/// Build a `missing_field` diagnostic from a `yay.ExtractionError`,
/// folding the extractor-internal detail into the diagnostic's hint so
/// nothing is silently dropped.
pub fn missing_field_from_extraction(
  err: yay.ExtractionError,
  path path: String,
  field field: String,
  loc loc: SourceLoc,
) -> Diagnostic {
  parser_error.missing_field_with_hint(
    detail: yay.extraction_error_to_string(err),
    path:,
    field:,
    loc:,
  )
}

/// Build a `missing_field` diagnostic from a `yay.SelectorError`. The
/// selector error is collapsed to its constructor name since the
/// detail isn't meaningful to users, but we still thread it through
/// rather than discarding it outright.
pub fn missing_field_from_selector(
  err: yay.SelectorError,
  path path: String,
  field field: String,
  loc loc: SourceLoc,
) -> Diagnostic {
  let detail = case err {
    yay.NodeNotFound(at:) ->
      "selector resolved up to segment " <> int.to_string(at)
    yay.SelectorParseError -> "selector parse error"
  }
  parser_error.missing_field_with_hint(detail:, path:, field:, loc:)
}
