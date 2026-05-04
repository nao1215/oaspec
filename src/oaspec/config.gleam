import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import yay

/// Configuration for oaspec code generation.
///
/// Opaque: external callers construct via `new/6` and read fields via
/// the accessors below. Mutators (`with_mode`, `with_validate`,
/// `with_output`) live in this module too, so every change to a
/// `Config` value goes through an explicit function.
pub opaque type Config {
  Config(
    input: String,
    output_server: String,
    output_client: String,
    package: String,
    mode: GenerateMode,
    validate: Bool,
  )
}

/// Construct a new `Config` from its six fields. Prefer `load/1` in
/// production code; `new/6` is primarily for tests and ad-hoc tooling
/// that assembles a config in memory.
pub fn new(
  input input: String,
  output_server output_server: String,
  output_client output_client: String,
  package package: String,
  mode mode: GenerateMode,
  validate validate: Bool,
) -> Config {
  Config(input:, output_server:, output_client:, package:, mode:, validate:)
}

/// Path to the OpenAPI spec this config was built for.
pub fn input(cfg: Config) -> String {
  cfg.input
}

/// Output directory for server-side generated files.
pub fn output_server(cfg: Config) -> String {
  cfg.output_server
}

/// Output directory for client-side generated files.
pub fn output_client(cfg: Config) -> String {
  cfg.output_client
}

/// Gleam package name (module prefix) for generated files.
pub fn package(cfg: Config) -> String {
  cfg.package
}

/// Generation mode: server, client, or both.
pub fn mode(cfg: Config) -> GenerateMode {
  cfg.mode
}

/// Whether guard-based runtime validation is enabled.
pub fn validate(cfg: Config) -> Bool {
  cfg.validate
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
    // nolint: error_context_lost -- yay ExtractionError details (KeyMissing vs KeyTypeMismatch) are internal; surfacing MissingField is the user-facing contract
    |> result.map_error(fn(_) { MissingField(field: "input") }),
  )

  let package =
    yay.extract_optional_string(root, "package")
    |> result.unwrap(None)
    |> option.unwrap("api")

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

  // Determine output base directory, then derive mode-aware server/client
  // defaults. Priority: output.server/client (explicit) > output.dir (base)
  // > default "./gen".
  //
  // The `_client` suffix is only needed in `Both` mode to disambiguate the
  // two output trees inside a single `<dir>`. In client-only mode there is
  // no server output to clash with, so the default client output is just
  // `<dir>/<package>` and the generated `import <package>/...` lines
  // resolve correctly (Issue #262).
  //
  // The unused field in single-mode configs (e.g. `output_server` in
  // client-only mode) is set to a sensible-looking placeholder for
  // diagnostics; it is never read by the writer or codegen.
  let output_dir =
    extract_nested_string(root, "output", "dir")
    |> option.unwrap("./gen")

  let server_default = output_dir <> "/" <> package
  let client_default = case mode {
    Client -> output_dir <> "/" <> package
    Server | Both -> output_dir <> "/" <> package <> "_client"
  }

  let output_server =
    extract_nested_string(root, "output", "server")
    |> option.unwrap(server_default)

  let output_client =
    extract_nested_string(root, "output", "client")
    |> option.unwrap(client_default)

  // When `validate:` is omitted, the default is mode-dependent (issue #268).
  // Server-mode codegen with `validate: false` lets schema-invalid input
  // (`minimum`, `maximum`, `pattern`, `minLength`, `maxLength` violations)
  // through to user handlers — security-adjacent and surprising. The
  // generator emits the guard functions either way; the only knob is whether
  // the router calls them. So fail-closed by default for any mode that
  // produces a server (`Server` and `Both`), and keep `False` only for the
  // pure-client case where pre-validating before send is nice but optional.
  // Explicit `validate: true` / `validate: false` continues to override.
  use validate <- result.try(
    case yay.select_sugar(from: root, selector: "validate") {
      Ok(yay.NodeBool(True)) | Ok(yay.NodeStr("true")) -> Ok(True)
      Ok(yay.NodeBool(False)) | Ok(yay.NodeStr("false")) -> Ok(False)
      // nolint: thrown_away_error -- missing optional 'validate' key defaults to mode-dependent value
      Error(_) ->
        case mode {
          Server | Both -> Ok(True)
          Client -> Ok(False)
        }
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
/// Derives server/client paths as <dir>/<package> and <dir>/<package>_client
/// in `Both` mode. In client-only mode the client path drops the suffix
/// (Issue #262) so generated `import <package>/...` lines resolve.
///
/// The suffix decision reads `config.mode` at call time, so apply
/// `with_mode/2` before `with_output/2` if both overrides are needed —
/// otherwise the client path will reflect the previous mode's default.
pub fn with_output(config: Config, output: Option(String)) -> Config {
  case output {
    Some(dir) ->
      Config(
        ..config,
        output_server: dir <> "/" <> config.package,
        output_client: case config.mode {
          Client -> dir <> "/" <> config.package
          Server | Both -> dir <> "/" <> config.package <> "_client"
        },
      )
    None -> config
  }
}

/// Validate that output directory basenames are valid Gleam module names
/// usable as import roots.
///
/// Server output must end in `<package>` so generated imports such as
/// `import <package>/types` resolve. Client output may end in either
/// `<package>` (when client lives in its own project) or `<package>_client`
/// (the new default since Issue #248 — both server and client share the same
/// `<dir>` and need distinct basenames). Anything else is a misconfigured
/// package/output mismatch the user should be told about.
///
/// Nested packages (Issue #387): a `package` containing `/` such as
/// `dco_check/github` declares an N-segment Gleam module path. The path
/// tail compared against the package is N segments deep — the LAST N
/// segments of the output path must equal the package's segments. The
/// `_client` suffix attaches to the LAST package segment only, matching
/// the single-segment behaviour (`dco_check/github` →
/// `dco_check/github_client`, never `dco_check_client/github`).
pub fn validate_output_package_match(config: Config) -> Result(Nil, ConfigError) {
  let pkg = package_segments(config.package)
  case pkg {
    // Empty package would make the rule vacuously true; bail out
    // explicitly so a stray `package: ""` does not silently disable
    // the validation.
    [] -> Ok(Nil)
    _ ->
      case config.mode {
        Server | Both ->
          validate_path_tail_matches_package(
            "output.server",
            config.output_server,
            pkg,
            False,
          )
        Client -> Ok(Nil)
      }
      |> result.try(fn(_) {
        case config.mode {
          Client | Both ->
            validate_path_tail_matches_package(
              "output.client",
              config.output_client,
              pkg,
              True,
            )
          Server -> Ok(Nil)
        }
      })
  }
}

fn validate_path_tail_matches_package(
  field: String,
  path: String,
  pkg: List(String),
  allow_client_suffix: Bool,
) -> Result(Nil, ConfigError) {
  let tail = last_n(path_segments(path), list.length(pkg))
  let pkg_with_suffix = suffix_last_segment(pkg, "_client")
  case tail == pkg, allow_client_suffix && tail == pkg_with_suffix {
    True, _ | _, True -> Ok(Nil)
    False, False ->
      Error(
        InvalidValue(field: field, detail: case allow_client_suffix {
          True ->
            "Output path tail '"
            <> string.join(tail, "/")
            <> "' must match package '"
            <> string.join(pkg, "/")
            <> "' or '"
            <> string.join(pkg_with_suffix, "/")
            <> "'"
          False ->
            "Output path tail '"
            <> string.join(tail, "/")
            <> "' must match package '"
            <> string.join(pkg, "/")
            <> "'"
        }),
      )
  }
}

/// Split a package name into its slash-separated segments. Empty
/// entries are dropped so trailing slashes and accidental double
/// slashes are tolerated. `"api"` → `["api"]`,
/// `"dco_check/github"` → `["dco_check", "github"]`.
fn package_segments(package: String) -> List(String) {
  package
  |> string.split("/")
  |> list.filter(fn(s) { s != "" })
}

/// Split a filesystem path into its segments, dropping `.` and empty
/// entries so `./src/foo/`, `src/foo`, and `./src//foo` all yield
/// `["src", "foo"]`.
fn path_segments(path: String) -> List(String) {
  path
  |> string.split("/")
  |> list.filter(fn(s) { s != "" && s != "." })
}

/// Return the last `n` entries of `items`, preserving order. If
/// `items` has fewer than `n` entries, returns `items` unchanged.
fn last_n(items: List(a), n: Int) -> List(a) {
  items |> list.reverse |> list.take(n) |> list.reverse
}

/// Drop the last `n` entries of `items`, preserving order. If
/// `items` has fewer than `n` entries, returns `[]`.
fn drop_last_n(items: List(a), n: Int) -> List(a) {
  items |> list.reverse |> list.drop(n) |> list.reverse
}

/// Append `suffix` to the LAST segment of `segments`. Empty input
/// stays empty. `["a","b"]` + `"_client"` → `["a","b_client"]`. Used
/// to derive the client-output spelling for nested packages while
/// keeping all but the leaf intact.
fn suffix_last_segment(segments: List(String), suffix: String) -> List(String) {
  case list.reverse(segments) {
    [] -> []
    [last, ..rest] -> list.reverse([last <> suffix, ..rest])
  }
}

/// Validate the on-disk layout implied by `output.dir`.
///
/// Issue #319: when `output.dir` is something like `./src/gen`, generated
/// code lands at `src/gen/<pkg>/types.gleam` whose Gleam module path is
/// `gen/<pkg>/types` — but oaspec emits `import <pkg>/types`, which the
/// compiler can't resolve. Catch this at config time so the user sees a
/// clear error instead of a wall of `Unknown module ...` from
/// `gleam build`.
///
/// Heuristic: in the path leading up to the package's top-level
/// directory, `src` must either be the immediate parent (the "<dir>
/// is the project's src/" pattern) or be absent (the standalone-
/// Gleam-project pattern). `src` in any other position is the
/// foot-gun.
///
/// Nested packages (Issue #387): for a package like `dco_check/github`
/// the "package directory" is the last 2 path segments, and the rule
/// applies to whatever sits BEFORE that pair. So `./src/dco_check/github`
/// has parent chain `[src]` (immediate parent `src` → ok), and
/// `./pkg/src/foo/dco_check/github` has parent chain
/// `[pkg, src, foo]` (last is `foo` and `src` appears earlier → bad).
pub fn validate_output_dir_layout(config: Config) -> Result(Nil, ConfigError) {
  let segment_count = list.length(package_segments(config.package))
  case segment_count {
    // Empty package: nothing to peel; skip the layout rule entirely.
    0 -> Ok(Nil)
    _ ->
      case config.mode {
        Server | Both ->
          case path_has_misplaced_src(config.output_server, segment_count) {
            False -> Ok(Nil)
            True ->
              Error(misplaced_src_error("output.server", config.output_server))
          }
        Client -> Ok(Nil)
      }
      |> result.try(fn(_) {
        case config.mode {
          Client | Both ->
            case path_has_misplaced_src(config.output_client, segment_count) {
              False -> Ok(Nil)
              True ->
                Error(misplaced_src_error("output.client", config.output_client))
            }
          Server -> Ok(Nil)
        }
      })
  }
}

fn misplaced_src_error(field: String, path: String) -> ConfigError {
  InvalidValue(
    field: field,
    detail: "'"
      <> path
      <> "' contains a 'src' segment that is not the immediate parent of the package directory. Generated code lands inside src/.../<package>/, but oaspec emits imports as `<package>/...`, which the Gleam compiler resolves relative to src/, not relative to <dir>. Either set the path so that 'src' is the direct parent of the package directory (e.g. './src'), or move the output outside any 'src/' tree (e.g. './gen') and treat that directory as a standalone Gleam project root with its own gleam.toml.",
  )
}

fn path_has_misplaced_src(path: String, package_segment_count: Int) -> Bool {
  let parent_segments = drop_last_n(path_segments(path), package_segment_count)
  case list.last(parent_segments) {
    // 'src' is the immediate parent of the package's top-level
    // directory — correct shape.
    Ok("src") -> False
    // No parent segment, or some other parent: foot-gun iff 'src'
    // appears anywhere earlier in the path.
    _ -> list.any(parent_segments, fn(s) { s == "src" })
  }
}

/// Convert config error to a human-readable string.
pub fn error_to_string(error: ConfigError) -> String {
  case error {
    FileNotFound(path:) ->
      "Config file not found: "
      <> path
      <> " (paths resolve relative to the current working directory)"
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
