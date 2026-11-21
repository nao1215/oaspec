//// Rules over `oaspec/config.Config` that the CLI applies after loading a
//// config, kept out of the public config module.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oaspec/config.{
  type Config, type ConfigError, type GenerateMode, type Include, Both, Client,
  Config, InvalidValue, Server,
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

/// True when no filter is active (both tag and path lists empty).
pub fn include_is_empty(include: Include) -> Bool {
  list.is_empty(include.tags) && list.is_empty(include.paths)
}

/// Apply output base directory override.
/// Derives server/client paths as <dir>/<package> and <dir>/<package>_client
/// in `Both` mode. In client-only mode the client path drops the suffix
/// so generated `import <package>/...` lines resolve.
///
/// The suffix decision reads `config.mode` at call time, so apply the
/// `--mode` override first — otherwise the client path will reflect the
/// previous mode's default.
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
/// (the new default sinceboth server and client share the same
/// `<dir>` and need distinct basenames). Anything else is a misconfigured
/// package/output mismatch the user should be told about.
///
/// Nested packages: a `package` containing `/` such as
/// `dco_check/github` declares an N-segment Gleam module path. The path
/// tail compared against the package is N segments deep — the LAST N
/// segments of the output path must equal the package's segments. The
/// `_client` suffix attaches to the LAST package segment only, matching
/// the single-segment behaviour (`dco_check/github` →
/// `dco_check/github_client`, never `dco_check_client/github`).
pub fn validate_output_package_match(
  config: Config,
) -> Result(Nil, ConfigError) {
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
/// When `output.dir` is something like `./src/gen`, generated
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
/// Nested packages: for a package like `dco_check/github`
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
  let earlier_parents = drop_last_n(parent_segments, 1)
  case list.last(parent_segments) {
    // 'src' is the immediate parent of the package's top-level
    // directory. Still a foot-gun if `src` ALSO appears earlier in
    // the parent chain (e.g. `./src/foo/src/<pkg>`), because Gleam
    // resolves imports against the outermost `src/` and the inner
    // copy ends up baked into the module path.
    Ok("src") -> list.any(earlier_parents, fn(s) { s == "src" })
    // No parent segment, or some other parent: foot-gun iff 'src'
    // appears anywhere in the parent chain.
    _ -> list.any(parent_segments, fn(s) { s == "src" })
  }
}
