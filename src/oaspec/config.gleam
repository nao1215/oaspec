import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oaspec/internal/openapi/parser_value
import simplifile
import yay

/// One generation target: which spec to read, what to generate and where
/// to write it.
///
/// `load` and `load_all` build it from an `oaspec.yaml`. To build one in
/// code, write the record and change fields with the record update syntax.
///
/// ## Examples
///
/// ```gleam
/// let cfg =
///   config.Config(
///     input: "openapi.yaml",
///     output_server: "./src/api",
///     output_client: "./src/api_client",
///     package: "api",
///     mode: config.Both,
///     validate: True,
///     include: config.Include(tags: [], paths: []),
///     handler_layout: config.SingleFile,
///   )
/// config.Config(..cfg, mode: config.Client)
/// ```
///
pub type Config {
  Config(
    /// Path of the OpenAPI document.
    input: String,
    /// Directory the server modules are written to; it must end in
    /// `package`.
    output_server: String,
    /// Directory the client modules are written to; it must end in
    /// `package` or `<package>_client`.
    output_client: String,
    /// Module prefix of the generated code, such as `api` for
    /// `import api/types`.
    package: String,
    mode: GenerateMode,
    /// Whether the generated server checks request values against the
    /// schema's constraints before calling a handler.
    validate: Bool,
    include: Include,
    handler_layout: HandlerLayout,
  )
}

/// How the user-owned server handler stubs are laid out on disk.
///
/// `SingleFile` (the default, `handlers: single`) writes every stub into
/// `handlers.gleam`. `PerOperation` (`handlers: per_operation`) writes
/// `handlers.gleam` with only the `State` type and one
/// `handlers/<operation>.gleam` per operation, so an operation added to
/// the spec gets its own stub on the next `oaspec generate` while the
/// files already written are left alone.
pub type HandlerLayout {
  SingleFile
  PerOperation
}

/// Subset filter for codegen. When non-empty, only
/// operations matching at least one of the listed `tags` or `paths`
/// are kept; the others are dropped before capability check, hoist,
/// and validate.
///
/// Path patterns may end in `/**` to match any path under a prefix
/// (`"/repos/**"` matches `/repos/foo`, `/repos/foo/bar`, …);
/// otherwise the pattern is compared by exact string equality.
///
/// `tags` and `paths` combine with OR semantics — an operation is
/// kept if EITHER its tag list intersects `Include.tags` OR its path
/// matches one of `Include.paths`. With both lists empty (the
/// default), no filtering is applied.
pub type Include {
  Include(tags: List(String), paths: List(String))
}

/// Which side of the API to generate.
pub type GenerateMode {
  /// Types, decoders, router and handler stubs for a server.
  Server
  /// Types, decoders and a client.
  Client
  /// Both of the above, into the two output directories.
  Both
}

/// A reason `load` or `load_all` could not build a `Config`.
pub type ConfigError {
  /// No file exists at the path.
  FileNotFound(path: String)
  /// The file exists but could not be read.
  CannotReadFile(path: String, reason: simplifile.FileError)
  /// The file is not YAML, or the YAML does not parse.
  InvalidYaml(detail: String)
  /// A required key, such as `input`, is missing.
  MissingField(field: String)
  /// A key has a value oaspec does not accept. `field` is the key path,
  /// such as `mode` or `targets[1].package`.
  InvalidValue(field: String, detail: String)
}

/// Reads an `oaspec.yaml` that declares one target.
///
/// Paths are resolved against the current directory. A config with more
/// than one entry under `targets:` is an `InvalidValue` error; use
/// `load_all` for those.
///
/// ## Examples
///
/// ```gleam
/// config.load("oaspec.yaml")
/// // -> Ok(Config(input: "openapi.yaml", package: "api", ..))
/// ```
///
/// ```gleam
/// config.load("missing.yaml")
/// // -> Error(FileNotFound("missing.yaml"))
/// ```
///
pub fn load(path: String) -> Result(Config, ConfigError) {
  use targets <- result.try(load_all(path))
  case targets {
    [single] -> Ok(single)
    [_, _, ..] ->
      Error(InvalidValue(
        field: "targets",
        detail: "config declares multiple targets; use config.load_all/1 to retrieve the full list",
      ))
    [] ->
      Error(InvalidValue(
        field: "targets",
        detail: "must declare at least one target",
      ))
  }
}

/// Reads an `oaspec.yaml` and returns one `Config` per target.
///
/// Without a `targets:` key the file is a single target. With one, each
/// entry gets its own `package`, `output` and `include`, and shares
/// `input`, `mode`, `validate` and `handlers` from the top level. When
/// `validate` is absent it defaults to `True` for `server` and `both`
/// and to `False` for `client`; `mode` defaults to `both` and the output
/// directory to `./src`.
///
/// ## Examples
///
/// ```gleam
/// config.load_all("oaspec.yaml")
/// // -> Ok([Config(package: "github", ..), Config(package: "stripe", ..)])
/// ```
///
/// ```gleam
/// config.load_all("oaspec.toml")
/// // -> Error(InvalidYaml("config files must be YAML; got '.toml' extension. ..."))
/// ```
///
pub fn load_all(path: String) -> Result(List(Config), ConfigError) {
  // Yay's Erlang FFI for `parse_string` returns a raw
  // `{yaml_error, Message, {Line, Col}}` tuple in some failure
  // modes, which doesn't structurally match either constructor of
  // `yay.YamlError`. The downstream `yaml_error_to_string` then
  // crashes with a `case_clause` runtime error instead of giving
  // the user a readable diagnostic. Common trigger: passing a
  // non-YAML file (e.g. `oaspec.toml` instead of `oaspec.yaml`).
  // Catch the obvious "wrong file extension" case up front and
  // return a friendly error before yay even sees the file.
  use _ <- result.try(case non_yaml_extension(path) {
    Some(ext) ->
      Error(InvalidYaml(
        detail: "config files must be YAML; got '."
        <> ext
        <> "' extension. Try renaming to '.yaml' (or '.yml').",
      ))
    None -> Ok(Nil)
  })

  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(e) {
      case e {
        simplifile.Enoent -> FileNotFound(path:)
        _ -> CannotReadFile(path:, reason: e)
      }
    }),
  )

  use docs <- result.try(
    yay.parse_string(content)
    |> result.map_error(fn(e) {
      InvalidYaml(detail: "YAML parse error: " <> yaml_error_to_string(e))
    }),
  )

  use doc <- result.try(case docs {
    [first, ..] -> Ok(first)
    [] -> Error(InvalidYaml(detail: "Empty YAML document"))
  })

  let root = yay.document_root(doc)

  use input <- result.try(
    yay.extract_string(root, "input")
    // nolint: error_context_lost -- yay ExtractionError details (KeyMissing vs KeyTypeMismatch) are internal; surfacing MissingField is the user-facing contract
    |> result.map_error(fn(_) { MissingField(field: "input") }),
  )

  use mode <- result.try(case parser_value.optional_string(root, "mode") {
    Some("server") -> Ok(Server)
    Some("client") -> Ok(Client)
    Some("both") -> Ok(Both)
    None -> Ok(Both)
    Some(other) ->
      Error(InvalidValue(
        field: "mode",
        detail: "must be one of: server, client, both (got: " <> other <> ")",
      ))
  })

  // When `validate:` is omitted, the default is mode-dependent.
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

  use handler_layout <- result.try(
    case parser_value.optional_string(root, "handlers") {
      None | Some("single") -> Ok(SingleFile)
      Some("per_operation") -> Ok(PerOperation)
      Some(other) ->
        Error(InvalidValue(
          field: "handlers",
          detail: "must be one of: single, per_operation (got: " <> other <> ")",
        ))
    },
  )

  // When `targets:` is present, walk the sequence and
  // build one `Config` per item, each inheriting the shared
  // input/mode/validate values from the root. When absent, the root
  // itself is the implicit single target (legacy single-target
  // shape: top-level package / output / include).
  case yay.select_sugar(from: root, selector: "targets") {
    // nolint: thrown_away_error -- absent `targets:` is the documented default for single-target configs.
    Error(_) -> {
      use cfg <- result.try(parse_target_node(
        root,
        input,
        mode,
        validate,
        handler_layout,
      ))
      Ok([cfg])
    }
    Ok(yay.NodeSeq(items)) ->
      case items {
        [] ->
          Error(InvalidValue(
            field: "targets",
            detail: "must declare at least one target",
          ))
        _ ->
          items
          |> list.index_map(fn(item, idx) {
            parse_target_item(item, idx, input, mode, validate, handler_layout)
          })
          |> result.all
      }
    Ok(_) ->
      Error(InvalidValue(
        field: "targets",
        detail: "must be a sequence of target objects",
      ))
  }
}

/// Parse a single target node — either the YAML root (legacy
/// single-target config) or one element of the `targets:` sequence
/// — into a fully-formed `Config`. The shared `input` / `mode` /
/// `validate` / `handlers` come from the top-level YAML and are baked
/// into the returned value.
fn parse_target_node(
  node: yay.Node,
  input: String,
  mode: GenerateMode,
  validate: Bool,
  handler_layout: HandlerLayout,
) -> Result(Config, ConfigError) {
  let package = parser_value.string_default(node, "package", "api")

  // Determine output base directory, then derive mode-aware
  // server/client defaults. Priority: output.server/client
  // (explicit) > output.dir (base) > default "./src".
  //
  // The default lands inside `./src` so a freshly-generated project
  // is buildable by `gleam build` in one step — `./src` is the
  // standard location Gleam picks modules from. Earlier versions
  // defaulted to `./gen`, which produced the worst-of-both first-
  // contact friction: the generator reported success but
  // `gleam build` could not see the generated modules until the
  // user added an `output:` block.
  //
  // The `_client` suffix is only needed in `Both` mode to
  // disambiguate the two output trees inside a single `<dir>`. In
  // client-only mode there is no server output to clash with, so
  // the default client output is just `<dir>/<package>` and the
  // generated `import <package>/...` lines resolve correctly.
  //
  // The unused field in single-mode configs (e.g. `output_server`
  // in client-only mode) is set to a sensible-looking placeholder
  // for diagnostics; it is never read by the writer or codegen.
  let output_dir =
    extract_nested_string(node, "output", "dir")
    |> option.unwrap("./src")

  let server_default = output_dir <> "/" <> package
  let client_default = case mode {
    Client -> output_dir <> "/" <> package
    Server | Both -> output_dir <> "/" <> package <> "_client"
  }

  let output_server =
    extract_nested_string(node, "output", "server")
    |> option.unwrap(server_default)

  let output_client =
    extract_nested_string(node, "output", "client")
    |> option.unwrap(client_default)

  use include <- result.try(parse_include(node))

  Ok(Config(
    input:,
    output_server:,
    output_client:,
    package:,
    mode:,
    validate:,
    include:,
    handler_layout:,
  ))
}

fn parse_target_item(
  node: yay.Node,
  idx: Int,
  input: String,
  mode: GenerateMode,
  validate: Bool,
  handler_layout: HandlerLayout,
) -> Result(Config, ConfigError) {
  // Each entry in `targets:` MUST declare its own `package:` —
  // unlike the single-target shape (which falls back to "api"),
  // multiple targets sharing the default package would clobber each
  // other on disk and via Gleam imports. Reject early with a clear
  // index-tagged error.
  case parser_value.optional_string(node, "package") {
    None ->
      Error(InvalidValue(
        field: "targets[" <> int.to_string(idx) <> "].package",
        detail: "each target must declare a package name",
      ))
    Some(_) -> parse_target_node(node, input, mode, validate, handler_layout)
  }
}

/// Parse the optional `include:` block. Returns an empty `Include`
/// when the key is absent so the absence path stays cheap.
fn parse_include(root: yay.Node) -> Result(Include, ConfigError) {
  case yay.select_sugar(from: root, selector: "include") {
    // nolint: thrown_away_error -- absent `include:` key is the documented default; the empty-include filter matches everything.
    Error(_) -> Ok(Include(tags: [], paths: []))
    Ok(include_node) -> {
      use tags <- result.try(extract_optional_string_list(
        include_node,
        "include.tags",
        "tags",
      ))
      use paths <- result.try(extract_optional_string_list(
        include_node,
        "include.paths",
        "paths",
      ))
      Ok(Include(tags: tags, paths: paths))
    }
  }
}

/// Read a list-of-strings YAML field that may be absent, in which
/// case an empty list is returned. `field_path` is the dotted name
/// shown in any `InvalidValue` diagnostic.
fn extract_optional_string_list(
  node: yay.Node,
  field_path: String,
  key: String,
) -> Result(List(String), ConfigError) {
  case yay.extract_string_list(node, key) {
    Ok(values) -> Ok(values)
    // nolint: thrown_away_error -- yay's distinction between "key absent" and "key present but not a list" is squashed here; absent → empty list, type-mismatch → InvalidValue with a specific detail string is emitted by the existence check below.
    Error(_) ->
      case yay.select_sugar(from: node, selector: key) {
        // nolint: thrown_away_error -- key truly absent: the documented default of an empty list applies.
        Error(_) -> Ok([])
        Ok(_) ->
          Error(InvalidValue(
            field: field_path,
            detail: "must be a list of strings",
          ))
      }
  }
}

/// Returns a one-line description of a config error.
///
/// ## Examples
///
/// ```gleam
/// config.error_to_string(config.MissingField("input"))
/// // -> "Missing required config field: input"
/// ```
///
pub fn error_to_string(error: ConfigError) -> String {
  case error {
    FileNotFound(path:) ->
      "Config file not found: "
      <> path
      <> " (paths resolve relative to the current working directory)"
    CannotReadFile(path:, reason:) ->
      "Error reading config file "
      <> path
      <> ": Failed to read file: "
      <> simplifile.describe_error(reason)
    InvalidYaml(detail:) -> "Config parse error: " <> detail
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

/// Detect a config path whose extension is clearly not
/// YAML so we can short-circuit with a friendly diagnostic before
/// the YAML parser hits a shape mismatch and crashes. Returns the
/// extension (lowercased, without the dot) when the file is plainly
/// non-YAML; `None` for `.yaml` / `.yml` / no extension (which we
/// pass through to yay so it can still surface a real parse error
/// for malformed content).
fn non_yaml_extension(path: String) -> Option(String) {
  let lowered = string.lowercase(path)
  case extension_of(lowered) {
    Some("yaml") | Some("yml") | None -> None
    Some(ext) -> Some(ext)
  }
}

fn extension_of(path: String) -> Option(String) {
  // Use the last segment (after the final '/') so `foo/bar.yml`
  // resolves to `yml` even when an earlier segment contains a dot.
  let last_segment = case list.last(string.split(path, "/")) {
    Ok(seg) -> seg
    // nolint: thrown_away_error -- string.split never returns the empty list, so the Error arm is unreachable
    Error(_) -> path
  }
  case string.split(last_segment, ".") {
    [_only] -> None
    [_, ..rest] ->
      case list.last(rest) {
        Ok(ext) -> Some(ext)
        // nolint: thrown_away_error -- empty-rest is impossible after the head match, but covers `last/0` totality
        Error(_) -> None
      }
    [] -> None
  }
}
