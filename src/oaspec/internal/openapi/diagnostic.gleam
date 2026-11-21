//// Builders, filters and renderers for `oaspec/openapi.Diagnostic`.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/config
import oaspec/internal/openapi/diagnostic_format
import oaspec/openapi.{
  type Diagnostic, type Severity, type SourceLoc, type Target, Diagnostic,
  NoSourceLoc, PhaseCapabilityCheck, PhaseParse, PhaseResolve, PhaseValidate,
  SeverityError, SeverityWarning, SourceLoc, TargetBoth, TargetClient,
  TargetServer,
}

pub fn file_error(detail detail: String) -> Diagnostic {
  Diagnostic(
    code: "file_error",
    phase: PhaseParse,
    severity: SeverityError,
    target: TargetBoth,
    pointer: "",
    source_loc: NoSourceLoc,
    message: detail,
    hint: None,
  )
}

pub fn yaml_error(detail detail: String, loc loc: SourceLoc) -> Diagnostic {
  Diagnostic(
    code: "yaml_error",
    phase: PhaseParse,
    severity: SeverityError,
    target: TargetBoth,
    pointer: "",
    source_loc: loc,
    message: detail,
    hint: None,
  )
}

/// Builds the diagnostic for input that exceeds one of the parser's
/// built-in size limits. The message names the limit, the cap and the
/// actual value.
pub fn parse_limit_exceeded(
  limit limit: String,
  configured configured: Int,
  actual actual: Int,
) -> Diagnostic {
  Diagnostic(
    code: "parse_limit_exceeded",
    phase: PhaseParse,
    severity: SeverityError,
    target: TargetBoth,
    pointer: "",
    source_loc: NoSourceLoc,
    message: "Parser limit '"
      <> limit
      <> "' exceeded: configured cap "
      <> int.to_string(configured)
      <> ", actual "
      <> int.to_string(actual)
      <> ". The input was refused before parsing to bound denial-of-service exposure.",
    hint: option.Some(
      "Reduce the spec below the cap, for example by removing unused paths or components.",
    ),
  )
}

pub fn missing_field(
  path path: String,
  field field: String,
  loc loc: SourceLoc,
) -> Diagnostic {
  Diagnostic(
    code: "missing_field",
    phase: PhaseParse,
    severity: SeverityError,
    target: TargetBoth,
    pointer: path,
    source_loc: loc,
    message: "Missing required field: " <> field,
    hint: Some("Check your OpenAPI spec structure."),
  )
}

pub fn invalid_value(
  path path: String,
  detail detail: String,
  loc loc: SourceLoc,
) -> Diagnostic {
  Diagnostic(
    code: "invalid_value",
    phase: PhaseParse,
    severity: SeverityError,
    target: TargetBoth,
    pointer: path,
    source_loc: loc,
    message: detail,
    hint: None,
  )
}

/// A YAML mapping at `path` contains the same key twice.
/// yamerl tolerates duplicate mapping keys (only the last value
/// survives), so this is the only signal users get that their spec
/// silently dropped one of two definitions. Surfaced as a parse-phase
/// error so `oaspec validate` rejects the file before generation.
///
/// `key` is the duplicated key as it appears in the source (e.g.
/// `"200"` for a duplicated response status code, `"foo"` for a
/// duplicated component name).
pub fn duplicate_key(
  path path: String,
  key key: String,
  loc loc: SourceLoc,
) -> Diagnostic {
  Diagnostic(
    code: "duplicate_key",
    phase: PhaseParse,
    severity: SeverityError,
    target: TargetBoth,
    pointer: path,
    source_loc: loc,
    message: "Duplicate key '" <> key <> "' in " <> path,
    hint: Some(
      "OpenAPI inherits JSON-object key uniqueness; YAML 1.2 §3.2.1.3 leaves duplicate mapping keys undefined. Remove or rename the duplicate so the spec parses unambiguously.",
    ),
  )
}

pub fn resolve_error(
  path path: String,
  detail detail: String,
  hint hint: Option(String),
  loc loc: SourceLoc,
) -> Diagnostic {
  Diagnostic(
    code: "resolve_error",
    phase: PhaseResolve,
    severity: SeverityError,
    target: TargetBoth,
    pointer: path,
    source_loc: loc,
    message: detail,
    hint: hint,
  )
}

/// Capability checks now thread a YAML `SourceLoc` through
/// every diagnostic. Pass `NoSourceLoc` only when the caller genuinely
/// has no LocationIndex available (e.g. tests that bypass the parser
/// path); production code always has one because it goes through
/// `parser.parse_file_with_locations` / `generate.generate_with_locations`.
pub fn capability(
  path path: String,
  detail detail: String,
  severity severity: Severity,
  target target: Target,
  hint hint: Option(String),
  loc loc: SourceLoc,
) -> Diagnostic {
  Diagnostic(
    code: "capability",
    phase: PhaseCapabilityCheck,
    severity: severity,
    target: target,
    pointer: path,
    source_loc: loc,
    message: detail,
    hint: hint,
  )
}

pub fn validation(
  path path: String,
  detail detail: String,
  severity severity: Severity,
  target target: Target,
  hint hint: Option(String),
) -> Diagnostic {
  Diagnostic(
    code: "validation",
    phase: PhaseValidate,
    severity: severity,
    target: target,
    pointer: path,
    source_loc: NoSourceLoc,
    message: detail,
    hint: hint,
  )
}

/// Severity / target shortcut builders for the common
/// `validation` shapes used in `internal/codegen/validate`. The
/// project review noted that the 5-field validation/5 constructor
/// gets called 28+ times with the same severity / target pair on
/// almost every site; these helpers collapse the common shape and
/// let call sites focus on the variable bits (path / detail / hint).
/// SeverityError + TargetBoth — the most common shape across
/// validate.gleam.
pub fn validation_error_both(
  path path: String,
  detail detail: String,
  hint hint: Option(String),
) -> Diagnostic {
  validation(
    path: path,
    detail: detail,
    severity: SeverityError,
    target: TargetBoth,
    hint: hint,
  )
}

/// SeverityError + TargetServer — the second most common shape
/// (server-only feature restrictions).
pub fn validation_error_server(
  path path: String,
  detail detail: String,
  hint hint: Option(String),
) -> Diagnostic {
  validation(
    path: path,
    detail: detail,
    severity: SeverityError,
    target: TargetServer,
    hint: hint,
  )
}

/// SeverityWarning + TargetBoth — used when a spec shape is
/// supported but the user should know about it.
pub fn validation_warning_both(
  path path: String,
  detail detail: String,
  hint hint: Option(String),
) -> Diagnostic {
  validation(
    path: path,
    detail: detail,
    severity: SeverityWarning,
    target: TargetBoth,
    hint: hint,
  )
}

/// Filter to only errors (not warnings).
pub fn errors_only(issues: List(Diagnostic)) -> List(Diagnostic) {
  list.filter(issues, fn(e) { e.severity == SeverityError })
}

/// Filter to only warnings (not errors).
pub fn warnings_only(issues: List(Diagnostic)) -> List(Diagnostic) {
  list.filter(issues, fn(e) { e.severity == SeverityWarning })
}

/// Filter diagnostics to those relevant for the selected generation mode.
pub fn filter_by_mode(
  issues: List(Diagnostic),
  mode: config.GenerateMode,
) -> List(Diagnostic) {
  case mode {
    config.Client -> list.filter(issues, fn(e) { e.target != TargetServer })
    config.Server -> list.filter(issues, fn(e) { e.target != TargetClient })
    config.Both -> issues
  }
}

/// Render a diagnostic with an editor-clickable `path:line:column:`
/// prefix when the spec file path and a `SourceLoc` are both known.
/// Falls back to plain `to_string` otherwise.
///
/// CI runs that process several specs need a breadcrumb to
/// which file produced an error; editors recognise the `path:line:col:`
/// prefix and let users jump straight to the offending YAML line.
pub fn render(d: Diagnostic, file_path file_path: Option(String)) -> String {
  case file_path, d.source_loc {
    Some(path), SourceLoc(line:, column:) ->
      path
      <> ":"
      <> int.to_string(line)
      <> ":"
      <> int.to_string(column)
      <> ": "
      <> openapi.diagnostic_to_string(d)
    Some(path), NoSourceLoc -> path <> ": " <> openapi.diagnostic_to_string(d)
    None, _ -> openapi.diagnostic_to_string(d)
  }
}

/// Convert a diagnostic to a short string (for backward-compatible display).
pub fn to_short_string(d: Diagnostic) -> String {
  let prefix = case d.severity {
    SeverityError -> "Error"
    SeverityWarning -> "Warning"
  }
  let loc_str = case d.source_loc {
    SourceLoc(line:, column:) ->
      " (line "
      <> int.to_string(line)
      <> ", column "
      <> int.to_string(column)
      <> ")"
    NoSourceLoc -> ""
  }
  case d.code {
    "file_error" -> d.message
    "yaml_error" -> d.message <> loc_str
    "missing_field" -> {
      let location = diagnostic_format.pointer_to_human(d.pointer)
      let field = string.replace(d.message, "Missing required field: ", "")
      "Missing required field '"
      <> field
      <> "' at "
      <> location
      <> case d.hint {
        Some(h) -> ". " <> h
        None -> ""
      }
    }
    "invalid_value" -> {
      let location = diagnostic_format.pointer_to_human(d.pointer)
      "Invalid value at " <> location <> ": " <> d.message
    }
    _ ->
      prefix
      <> case d.pointer {
        "" -> ""
        p -> " at " <> diagnostic_format.pointer_to_human(p)
      }
      <> ": "
      <> d.message
  }
}
