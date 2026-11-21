//// Pure helper for assembling `missing_field` diagnostics with a
//// "Check your OpenAPI spec structure. (...)" hint, used by the parser
//// modules. The detail string carries whatever extractor- or
//// selector-internal information would otherwise be silently dropped.
////
//// Target-neutral: this module knows nothing about `yay`. The
//// `yay` → detail-string conversion lives in the BEAM-coupled
//// `parser_yay_error` sibling.

import gleam/option.{Some}
import oaspec/openapi/diagnostic.{type Diagnostic, type SourceLoc, Diagnostic}

/// Build a `missing_field` diagnostic whose hint surfaces the given
/// detail string so an extractor- or selector-internal failure is not
/// silently dropped.
pub fn missing_field_with_hint(
  detail detail: String,
  path path: String,
  field field: String,
  location location: SourceLoc,
) -> Diagnostic {
  let base = diagnostic.missing_field(path:, field:, loc: location)
  Diagnostic(
    ..base,
    hint: Some("Check your OpenAPI spec structure. (" <> detail <> ")"),
  )
}
