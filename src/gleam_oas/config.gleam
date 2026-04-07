import gleam/option.{type Option, None, Some}
import gleam/result
import simplifile
import yay

/// Configuration for gleam-oas code generation.
pub type Config {
  Config(
    input: String,
    output_server: String,
    output_client: String,
    package: String,
    mode: GenerateMode,
  )
}

/// Generation mode.
pub type GenerateMode {
  Server
  Client
  Both
}

/// Errors that can occur when loading config.
pub type ConfigError {
  FileNotFound(path: String)
  FileReadError(path: String, detail: String)
  ParseError(detail: String)
  MissingField(field: String)
  InvalidValue(field: String, detail: String)
}

/// Parse a mode string into GenerateMode.
pub fn parse_mode(mode: String) -> Result(GenerateMode, ConfigError) {
  case mode {
    "server" -> Ok(Server)
    "client" -> Ok(Client)
    "both" -> Ok(Both)
    _ ->
      Error(InvalidValue(
        field: "mode",
        detail: "must be one of: server, client, both",
      ))
  }
}

/// Load config from a YAML file.
pub fn load(path: String) -> Result(Config, ConfigError) {
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) { FileNotFound(path:) }),
  )

  use docs <- result.try(
    yay.parse_string(content)
    |> result.map_error(fn(e) {
      ParseError(detail: "YAML parse error: " <> yaml_error_to_string(e))
    }),
  )

  use doc <- result.try(case docs {
    [first, ..] -> Ok(first)
    [] -> Error(ParseError(detail: "Empty YAML document"))
  })

  let root = yay.document_root(doc)

  use input <- result.try(
    yay.extract_string(root, "input")
    |> result.map_error(fn(_) { MissingField(field: "input") }),
  )

  let package =
    yay.extract_optional_string(root, "package")
    |> result.unwrap(None)
    |> option.unwrap("api")

  // Determine output base directory first, then derive server/client paths.
  // Priority: output.server/client (explicit) > output.dir (base) > default "./gen"
  let output_dir =
    extract_nested_string(root, "output", "dir")
    |> option.unwrap("./gen")

  let output_server =
    extract_nested_string(root, "output", "server")
    |> option.unwrap(output_dir <> "/" <> package)

  let output_client =
    extract_nested_string(root, "output", "client")
    |> option.unwrap(output_dir <> "/" <> package <> "_client")

  use mode <- result.try(
    case yay.extract_optional_string(root, "mode") |> result.unwrap(None) {
      Some("server") -> Ok(Server)
      Some("client") -> Ok(Client)
      Some("both") -> Ok(Both)
      None -> Ok(Both)
      Some(other) ->
        Error(InvalidValue(
          field: "mode",
          detail: "must be one of: server, client, both (got: " <> other <> ")",
        ))
    },
  )

  Ok(Config(input:, output_server:, output_client:, package:, mode:))
}

/// Apply CLI overrides to a config.
pub fn with_mode(config: Config, mode: GenerateMode) -> Config {
  Config(..config, mode:)
}

/// Apply output base directory override.
/// Derives server/client paths as <dir>/<package> and <dir>/<package>_client.
pub fn with_output(config: Config, output: Option(String)) -> Config {
  case output {
    Some(dir) ->
      Config(
        ..config,
        output_server: dir <> "/" <> config.package,
        output_client: dir <> "/" <> config.package <> "_client",
      )
    None -> config
  }
}

/// Convert config error to a human-readable string.
pub fn error_to_string(error: ConfigError) -> String {
  case error {
    FileNotFound(path:) -> "Config file not found: " <> path
    FileReadError(path:, detail:) ->
      "Error reading config file " <> path <> ": " <> detail
    ParseError(detail:) -> "Config parse error: " <> detail
    MissingField(field:) -> "Missing required config field: " <> field
    InvalidValue(field:, detail:) ->
      "Invalid value for " <> field <> ": " <> detail
  }
}

/// Extract a nested string value from YAML like output.server.
fn extract_nested_string(
  root: yay.Node,
  key1: String,
  key2: String,
) -> Option(String) {
  case yay.select_sugar(from: root, selector: key1 <> "." <> key2) {
    Ok(yay.NodeStr(value)) -> Some(value)
    _ -> None
  }
}

/// Convert a yay YAML error to string.
fn yaml_error_to_string(error: yay.YamlError) -> String {
  case error {
    yay.UnexpectedParsingError -> "Unexpected parsing error"
    yay.ParsingError(msg:, ..) -> msg
  }
}
