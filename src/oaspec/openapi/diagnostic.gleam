import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/config
import oaspec/internal/openapi/diagnostic_format

/// Pipeline phase that produced the diagnostic.
pub type Phase {
  PhaseParse
  PhaseNormalize
  PhaseResolve
  PhaseCapabilityCheck
  PhaseValidate
  PhaseCodegen
}

/// Severity level for diagnostics.
pub type Severity {
  SeverityError
  SeverityWarning
}

/// Target indicating which generation mode the issue applies to.
pub type Target {
  TargetBoth
  TargetClient
  TargetServer
}

/// Source location from YAML/JSON parsing.
pub type SourceLoc {
  SourceLoc(line: Int, column: Int)
  NoSourceLoc
}

/// Unified diagnostic type for all pipeline phases.
pub type Diagnostic {
  Diagnostic(
    code: String,
    phase: Phase,
    severity: Severity,
    target: Target,
    pointer: String,
    source_loc: SourceLoc,
    message: String,
    hint: Option(String),
  )
}

// ============================================================================
// Convenience constructors for parse phase
// ============================================================================

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

/// Parser refused the input because it exceeded a configured DoS
/// limit (see `parser.ParseLimits`). The message names the limit, the
/// configured cap, and the actual value so callers can either bump
/// the limit (when they trust the source) or reject the input.
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
      <> int_to_string(configured)
      <> ", actual "
      <> int_to_string(actual)
      <> ". The input was refused before parsing to bound denial-of-service exposure (issue #553).",
    hint: option.Some(
      "If the source is trusted, raise '"
      <> limit
      <> "' via parser.ParseLimits and call parse_string_with_limits with the larger cap. Untrusted sources should keep the default cap.",
    ),
  )
}

@external(erlang, "erlang", "integer_to_binary")
@external(javascript, "../oaspec_ffi.mjs", "integer_to_string")
fn int_to_string(n: Int) -> String

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

/// Issue #573: a YAML mapping at `path` contains the same key twice.
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

// ============================================================================
// Convenience constructors for resolve phase
// ============================================================================

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

// ============================================================================
// Convenience constructors for capability_check phase
// ============================================================================

/// Issue #411: capability checks now thread a YAML `SourceLoc` through
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

// ============================================================================
// Convenience constructors for validate phase
// ============================================================================

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

/// Issue #416: severity / target shortcut builders for the common
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

// ============================================================================
// Filtering
// ============================================================================

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

// ============================================================================
// Display
// ============================================================================

/// Convert a diagnostic to a human-readable string.
pub fn to_string(d: Diagnostic) -> String {
  let phase_str = case d.phase {
    PhaseParse -> "Parse"
    PhaseNormalize -> "Normalize"
    PhaseResolve -> "Resolve"
    PhaseCapabilityCheck -> "CapabilityCheck"
    PhaseValidate -> "Validate"
    PhaseCodegen -> "Codegen"
  }
  let severity_str = case d.severity {
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
  let pointer_str = case d.pointer {
    "" -> ""
    p -> " at " <> p
  }
  let hint_str = case d.hint {
    Some(h) -> " " <> h
    None -> ""
  }
  "["
  <> phase_str
  <> "] "
  <> severity_str
  <> pointer_str
  <> ": "
  <> d.message
  <> loc_str
  <> hint_str
}

/// Render a diagnostic with an editor-clickable `path:line:column:`
/// prefix when the spec file path and a `SourceLoc` are both known.
/// Falls back to plain `to_string` otherwise.
///
/// Issue #411: CI runs that process several specs need a breadcrumb to
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
      <> to_string(d)
    Some(path), NoSourceLoc -> path <> ": " <> to_string(d)
    None, _ -> to_string(d)
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
