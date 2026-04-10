import gleam/option
import gleam/string
import oaspec/openapi/diagnostic

/// Errors that can occur during OpenAPI spec parsing.
pub type ParseError {
  FileError(detail: String)
  YamlError(detail: String)
  MissingField(path: String, field: String)
  InvalidValue(path: String, detail: String)
}

/// Convert a parse error to a human-readable string.
pub fn parse_error_to_string(error: ParseError) -> String {
  case error {
    FileError(detail:) -> detail
    YamlError(detail:) -> detail
    MissingField(path:, field:) -> {
      let location = case path {
        "" -> "root"
        p -> p
      }
      "Missing required field '"
      <> field
      <> "' at "
      <> location
      <> ". Check your OpenAPI spec structure."
    }
    InvalidValue(path:, detail:) -> {
      let location = case path {
        "" -> "root"
        p -> p
      }
      "Invalid value at " <> location <> ": " <> detail
    }
  }
}

/// Convert a ParseError to a Diagnostic for CLI display.
pub fn parse_error_to_diagnostic(error: ParseError) -> diagnostic.Diagnostic {
  case error {
    FileError(detail:) ->
      diagnostic.Diagnostic(
        code: "file-error",
        severity: diagnostic.Error,
        pointer: "",
        message: detail,
        hint: option.None,
        phase: diagnostic.Parsing,
      )
    YamlError(detail:) ->
      diagnostic.Diagnostic(
        code: "yaml-error",
        severity: diagnostic.Error,
        pointer: "",
        message: detail,
        hint: option.Some("Check that the file is valid YAML or JSON."),
        phase: diagnostic.Parsing,
      )
    MissingField(path:, field:) -> {
      let location = case path {
        "" -> "root"
        p -> p
      }
      diagnostic.Diagnostic(
        code: "missing-field",
        severity: diagnostic.Error,
        pointer: location,
        message: "Missing required field '" <> field <> "'",
        hint: option.Some(
          "Add the '"
          <> field
          <> "' field to your OpenAPI spec at "
          <> location
          <> ".",
        ),
        phase: diagnostic.Parsing,
      )
    }
    InvalidValue(path:, detail:) -> {
      let location = case path {
        "" -> "root"
        p -> p
      }
      diagnostic.Diagnostic(
        code: "invalid-value",
        severity: diagnostic.Error,
        pointer: location,
        message: detail,
        hint: option.None,
        phase: diagnostic.Parsing,
      )
    }
  }
}

/// Validate that a $ref string starts with the expected local prefix
/// (e.g. "#/components/parameters/"). Rejects external refs and
/// refs that point to the wrong component kind.
pub fn validate_ref_prefix(
  ref_str: String,
  expected_prefix: String,
  kind: String,
) -> Result(String, ParseError) {
  case string.starts_with(ref_str, expected_prefix) {
    True -> {
      let name = string.drop_start(ref_str, string.length(expected_prefix))
      Ok(name)
    }
    False ->
      Error(InvalidValue(
        path: kind <> ".$ref",
        detail: "Reference '"
          <> ref_str
          <> "' is not a local "
          <> kind
          <> " reference. Expected prefix: "
          <> expected_prefix,
      ))
  }
}
