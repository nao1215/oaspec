import gleam/option.{type Option, None, Some}

/// Source phase where the diagnostic was produced.
pub type Phase {
  Parsing
  Validation
  CodeGeneration
}

/// Severity level.
pub type Severity {
  Error
  Warning
  Info
}

/// A structured diagnostic message with full context.
pub type Diagnostic {
  Diagnostic(
    /// Machine-readable error code (e.g. "missing-field", "unsupported-keyword")
    code: String,
    /// Severity level
    severity: Severity,
    /// JSON-pointer-style path to the problematic element
    pointer: String,
    /// Human-readable summary of what happened
    message: String,
    /// Actionable hint for how to fix it
    hint: Option(String),
    /// Which phase produced this diagnostic
    phase: Phase,
  )
}

/// Format a diagnostic for CLI display.
pub fn to_string(diag: Diagnostic) -> String {
  let severity_str = case diag.severity {
    Error -> "error"
    Warning -> "warning"
    Info -> "info"
  }
  let base =
    severity_str
    <> "["
    <> diag.code
    <> "] "
    <> diag.pointer
    <> ": "
    <> diag.message
  case diag.hint {
    Some(hint) -> base <> "\n  hint: " <> hint
    None -> base
  }
}

/// Check if a diagnostic is an error (not warning/info).
pub fn is_error(diag: Diagnostic) -> Bool {
  diag.severity == Error
}
