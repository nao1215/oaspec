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

pub fn capability(
  path path: String,
  detail detail: String,
  severity severity: Severity,
  target target: Target,
  hint hint: Option(String),
) -> Diagnostic {
  Diagnostic(
    code: "capability",
    phase: PhaseCapabilityCheck,
    severity: severity,
    target: target,
    pointer: path,
    source_loc: NoSourceLoc,
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
