//// Shared helpers for parser modules that need to turn a `yay`-level
//// extraction / selector failure into a `Diagnostic`. Split out of
//// `parser.gleam` so both top-level flow parsing and schema parsing can
//// depend on the same error shape without duplicating the hint-assembly
//// logic.

import gleam/int
import gleam/option.{Some}
import oaspec/openapi/diagnostic.{type Diagnostic, type SourceLoc, Diagnostic}
import yay

/// Build a `missing_field` diagnostic from a `yay.ExtractionError`, folding
/// the extractor-internal detail into the diagnostic's hint so nothing is
/// silently dropped.
pub fn missing_field_from_extraction(
  err: yay.ExtractionError,
  path path: String,
  field field: String,
  loc loc: SourceLoc,
) -> Diagnostic {
  let base = diagnostic.missing_field(path:, field:, loc:)
  Diagnostic(
    ..base,
    hint: Some(
      "Check your OpenAPI spec structure. ("
      <> yay.extraction_error_to_string(err)
      <> ")",
    ),
  )
}

/// Build a `missing_field` diagnostic from a `yay.SelectorError`. The
/// selector error is collapsed to its constructor name since the detail
/// isn't meaningful to users, but we still thread it through rather than
/// discarding it outright.
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
  let base = diagnostic.missing_field(path:, field:, loc:)
  Diagnostic(
    ..base,
    hint: Some("Check your OpenAPI spec structure. (" <> detail <> ")"),
  )
}
