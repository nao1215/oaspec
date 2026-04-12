import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import yay

/// Configuration for oaspec code generation.
pub type Config {
  Config(
    input: String,
    output_server: String,
    output_client: String,
    package: String,
    mode: GenerateMode,
    validate: Bool,
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
    |> result.map_error(fn(e) {
      case e {
        simplifile.Enoent -> FileNotFound(path:)
        _ ->
          FileReadError(
            path:,
            detail: "Failed to read file: " <> simplifile.describe_error(e),
          )
      }
    }),
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
    |> option.unwrap(output_dir <> "_client/" <> package)

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

  use validate <- result.try(
    case yay.select_sugar(from: root, selector: "validate") {
      Ok(yay.NodeBool(True)) | Ok(yay.NodeStr("true")) -> Ok(True)
      Ok(yay.NodeBool(False)) | Ok(yay.NodeStr("false")) -> Ok(False)
      Error(_) -> Ok(False)
      Ok(_) ->
        Error(InvalidValue(
          field: "validate",
          detail: "must be a boolean (true or false)",
        ))
    },
  )

  Ok(Config(input:, output_server:, output_client:, package:, mode:, validate:))
}

/// Apply CLI overrides to a config.
pub fn with_mode(config: Config, mode: GenerateMode) -> Config {
  Config(..config, mode:)
}

/// Apply validation mode override.
pub fn with_validate(config: Config, validate: Bool) -> Config {
  Config(..config, validate:)
}

/// Apply output base directory override.
/// Derives server/client paths as <dir>/<package> and <dir>_client/<package>.
pub fn with_output(config: Config, output: Option(String)) -> Config {
  case output {
    Some(dir) ->
      Config(
        ..config,
        output_server: dir <> "/" <> config.package,
        output_client: dir <> "_client/" <> config.package,
      )
    None -> config
  }
}

/// Validate that output directory basenames match the package name.
/// Gleam imports require `import <package>/types`, so the directory must match.
pub fn validate_output_package_match(config: Config) -> Result(Nil, ConfigError) {
  case config.mode {
    Server | Both ->
      case basename(config.output_server) == config.package {
        True -> Ok(Nil)
        False ->
          Error(InvalidValue(
            field: "output.server",
            detail: "Directory basename '"
              <> basename(config.output_server)
              <> "' must match package '"
              <> config.package
              <> "'",
          ))
      }
    Client -> Ok(Nil)
  }
  |> result.try(fn(_) {
    case config.mode {
      Client | Both ->
        case basename(config.output_client) == config.package {
          True -> Ok(Nil)
          False ->
            Error(InvalidValue(
              field: "output.client",
              detail: "Directory basename '"
                <> basename(config.output_client)
                <> "' must match package '"
                <> config.package
                <> "'",
            ))
        }
      Server -> Ok(Nil)
    }
  })
}

/// Get the basename of a path (last segment after /).
fn basename(path: String) -> String {
  path
  |> string.split("/")
  |> list.last
  |> result.unwrap("")
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
