import filepath
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import glint
import oaspec/codegen/writer
import oaspec/config
import oaspec/generate
import oaspec/internal/codegen/context
import oaspec/internal/formatter
import oaspec/internal/openapi/location_index.{type LocationIndex}
import oaspec/internal/progress
import oaspec/openapi/diagnostic
import oaspec/openapi/parser
import oaspec/openapi/spec.{type OpenApiSpec, type Unresolved}
import simplifile

@external(erlang, "oaspec_ffi", "is_stdout_tty")
fn is_stdout_tty() -> Bool

@external(erlang, "oaspec_ffi", "no_color_set")
fn no_color_set() -> Bool

/// Apply colour styling only when stdout is a terminal and NO_COLOR is unset,
/// per <https://no-color.org/> and the CLIG "colorize when stdout is a TTY only"
/// guideline. When either check fails, glint keeps its `pretty_help` as `None`
/// and emits plain text.
fn maybe_pretty_help(glint: glint.Glint(a)) -> glint.Glint(a) {
  case is_stdout_tty(), no_color_set() {
    True, False -> glint.pretty_help(glint, glint.default_pretty_help())
    _, _ -> glint
  }
}

/// Long-option flag names that take a value across all subcommands. Used by
/// the argv-normalisation step in `oaspec.main` to translate the GNU
/// `--name value` form into glint's expected `--name=value` form. Must stay
/// in sync with the `glint.string_flag(...)` calls below: any new
/// value-bearing long-option flag must be added here, otherwise the
/// space-separated form will fail with `invalid flag '<name>'`.
pub const value_flag_names = ["config", "mode", "output"]

/// Set up the CLI application.
pub fn app() -> glint.Glint(Nil) {
  glint.new()
  |> glint.with_name("oaspec")
  |> glint.global_help(
    "Generate Gleam code from OpenAPI 3.x specifications\n\nCommands:\n  init       Create a default oaspec.yaml config file\n  generate   Generate Gleam code from an OpenAPI spec\n  validate   Validate an OpenAPI spec without generating code\n  version    Print the oaspec version and exit\n\nRun 'oaspec <command> --help' for more information.\nUse 'oaspec --version' for a flag-style version check.",
  )
  |> maybe_pretty_help
  |> glint.add(at: ["init"], do: init_command())
  |> glint.add(at: ["generate"], do: generate_command())
  |> glint.add(at: ["validate"], do: validate_command())
  |> glint.add(at: ["version"], do: version_command())
}

/// The version command definition.
fn version_command() -> glint.Command(Nil) {
  glint.command_help("Print the oaspec version and exit", fn() {
    glint.command(fn(_named_args, _args, _flags) {
      io.println("oaspec v" <> context.version)
    })
  })
}

/// The generate command definition.
fn generate_command() -> glint.Command(Nil) {
  {
    use config_path <- glint.flag(
      glint.string_flag("config")
      |> glint.flag_default("./oaspec.yaml")
      |> glint.flag_help("Path to config file"),
    )

    use mode <- glint.flag(
      glint.string_flag("mode")
      |> glint.flag_default("")
      |> glint.flag_help(
        "Generation mode: server, client, or both (overrides config)",
      ),
    )

    use output <- glint.flag(
      glint.string_flag("output")
      |> glint.flag_default("")
      |> glint.flag_help("Output directory override"),
    )

    use check <- glint.flag(
      glint.bool_flag("check")
      |> glint.flag_default(False)
      |> glint.flag_help(
        "Check that generated code matches existing files without writing",
      ),
    )

    use fail_on_warnings <- glint.flag(
      glint.bool_flag("fail-on-warnings")
      |> glint.flag_default(False)
      |> glint.flag_help("Treat warnings as errors"),
    )

    use validate <- glint.flag(
      glint.bool_flag("validate")
      |> glint.flag_default(False)
      |> glint.flag_help(
        "Force-enable guard validation in generated server/client code. One-way override: cannot disable validation set by oaspec.yaml. Set validate: false in the config to turn it off.",
      ),
    )

    glint.command_help(
      "Generate Gleam code from an OpenAPI specification",
      fn() {
        glint.command(fn(_named_args, _args, flags) {
          let config_path = config_path(flags) |> result.unwrap("./oaspec.yaml")
          let mode_opt = case mode(flags) |> result.unwrap("") {
            "" -> None
            s -> Some(s)
          }
          let output_opt = case output(flags) |> result.unwrap("") {
            "" -> None
            s -> Some(s)
          }
          let check_mode = check(flags) |> result.unwrap(False)
          let fail_on_warnings_mode =
            fail_on_warnings(flags) |> result.unwrap(False)
          let validate_mode = validate(flags) |> result.unwrap(False)

          run_generate(
            config_path,
            mode_opt,
            output_opt,
            check_mode,
            fail_on_warnings_mode,
            validate_mode,
          )
        })
      },
    )
  }
}

/// The validate command definition.
fn validate_command() -> glint.Command(Nil) {
  {
    use config_path <- glint.flag(
      glint.string_flag("config")
      |> glint.flag_default("./oaspec.yaml")
      |> glint.flag_help("Path to config file"),
    )

    use mode <- glint.flag(
      glint.string_flag("mode")
      |> glint.flag_default("")
      |> glint.flag_help(
        "Generation mode: server, client, or both (overrides config)",
      ),
    )

    glint.command_help(
      "Validate an OpenAPI specification without generating code",
      fn() {
        glint.command(fn(_named_args, _args, flags) {
          let config_path = config_path(flags) |> result.unwrap("./oaspec.yaml")
          let mode_opt = case mode(flags) |> result.unwrap("") {
            "" -> None
            s -> Some(s)
          }

          run_validate(config_path, mode_opt)
        })
      },
    )
  }
}

/// The init command definition.
fn init_command() -> glint.Command(Nil) {
  {
    use output_path <- glint.flag(
      glint.string_flag("output")
      |> glint.flag_default("./oaspec.yaml")
      |> glint.flag_help("Output path for the config file"),
    )

    glint.command_help("Create a oaspec.yaml config file", fn() {
      glint.command(fn(_named_args, _args, flags) {
        let path = output_path(flags) |> result.unwrap("./oaspec.yaml")
        run_init(path)
      })
    })
  }
}

/// Create a config file template.
fn run_init(path: String) -> Nil {
  let template =
    "# oaspec configuration file
# See https://github.com/nao1215/oaspec for documentation.

# Path to your OpenAPI 3.x specification (YAML or JSON).
input: openapi.yaml

# Gleam module namespace for generated code.
# Generated imports will be `import <package>/types`, etc.
package: api

# Generation mode: server, client, or both (default: both).
# mode: both

# Enable guard validation in generated server/client code.
# Default: true for mode: server / both (fail-closed: server handlers
# should not receive schema-invalid input by default), false for
# mode: client (clients pre-validating before sending is nice but
# optional). When enabled, generated routers validate request bodies
# against schema constraints and return 422 on failure. Generated
# clients validate request bodies before sending. Set explicitly to
# override the mode-dependent default.
# validate: true

# Layout of the user-owned server handler stubs: single (default) keeps
# them all in handlers.gleam; per_operation writes one
# handlers/<operation>.gleam per operation, so an operation added to the
# spec gets its own stub on the next run.
# handlers: single

# Output settings (optional). Defaults land inside ./src so a
# freshly-generated project is buildable by `gleam build` without
# any further config:
#   server -> ./src/<package>
#   client -> ./src/<package>_client (Both mode) or ./src/<package> (Client mode)
# Override individual targets via output.server / output.client, or
# set output.dir to change the base directory for both at once.
# output:
#   dir: ./src                    # Base directory; defaults to ./src
#                                 # so generated modules drop into the
#                                 # standard Gleam project layout.
#   server: ./src/api             # Override server output path
#   client: ./src/api_client      # Override client output path

# Operation filter (optional). When set, codegen only
# emits operations whose tag list intersects `tags` OR whose path
# matches one of `paths` (the two lists are unioned, not
# intersected). Path patterns ending in `/**` match any path that
# extends the prefix with a `/<rest>` segment. Both lists empty /
# both keys omitted = no filter.
# include:
#   tags:
#     - issues
#   paths:
#     - \"/users/{username}\"
#     - \"/repos/**\"

# Multi-target codegen (optional). When `targets:` is
# set, the same input spec is generated once per entry, each with
# its own `package`, `output`, and `include`. The top-level
# `input`, `mode`, `validate`, and `handlers` are shared across every
# target.
# Targets whose output paths overlap are rejected at config-load
# time. `--output` cannot be used with multi-target configs.
# targets:
#   - package: my_app/issues
#     output:
#       dir: ./src
#     include:
#       tags: [issues]
#   - package: my_app/repos
#     output:
#       dir: ./src
#     include:
#       paths: [\"/repos/**\"]
"

  case simplifile.is_file(path) {
    Ok(True) -> {
      io.println_error("Error: " <> path <> " already exists")
      halt(1)
    }
    _ -> {
      case simplifile.write(path, template) {
        Ok(_) -> io.println("Created " <> path)
        Error(write_err) -> {
          io.println_error(
            "Error: failed to write "
            <> path
            <> ": "
            <> simplifile.describe_error(write_err),
          )
          halt(1)
        }
      }
    }
  }
}

/// Execute the generation pipeline.
/// Handles IO (printing, exit codes) while delegating pure logic to
/// generate.generate and load_config.
fn run_generate(
  config_path: String,
  mode_opt: Option(String),
  output_opt: Option(String),
  check_mode: Bool,
  fail_on_warnings: Bool,
  validate_mode: Bool,
) -> Nil {
  io.println("oaspec v" <> context.version)
  io.println("Loading config from: " <> config_path)

  // A config may declare multiple `targets:`. Each target produces its
  // own package + output tree from the same input spec.
  use #(first, rest) <- require(
    load_configs(config_path, mode_opt, output_opt),
    load_config_error_to_string,
  )
  let targets =
    list.map([first, ..rest], fn(c) {
      case validate_mode {
        True -> config.with_validate(c, True)
        False -> c
      }
    })

  // Reject configs where two targets would write to the same
  // directory — generated files would clobber each other and there
  // is no sensible default order.
  use _ <- require(
    validate_no_target_overlap(targets),
    load_config_error_to_string,
  )

  print_resolved_paths_for_all(config_path, targets)

  // `generate_with_progress` re-runs every per-target stage (filter /
  // hoist / dedup / validate / codegen) so each target sees only the
  // operations its filter keeps.
  use cfg, input <- for_each_target(targets)
  use summary <- require(
    generate.generate_with_progress_and_locations(
      input.spec,
      input.locations,
      cfg,
      input.reporter,
    ),
    format_generate_error_for(input.path),
  )
  io.println("Spec loaded: " <> summary.spec_title)
  print_warnings_for(input.path, summary.warnings)
  // `--check` already reports orphaned stubs as errors.
  let layout_warnings = case check_mode {
    True -> []
    False -> handler_layout_warnings(summary.files, cfg)
  }
  list.each(layout_warnings, fn(w) { io.println_error("Warning: " <> w) })
  case fail_on_warnings && { summary.warnings != [] || layout_warnings != [] } {
    True -> {
      io.println_error("")
      io.println_error("Error: warnings present and --fail-on-warnings is set.")
      halt(1)
    }
    False -> Nil
  }
  case check_mode {
    True -> run_check(summary.files, cfg)
    False -> write_files(summary.files, cfg)
  }
}

/// The input spec every target shares, parsed once.
type ParsedInput {
  ParsedInput(
    path: String,
    spec: OpenApiSpec(Unresolved),
    locations: LocationIndex,
    reporter: progress.Reporter,
  )
}

/// Parse the input spec the targets share once, then call `run` for every
/// target, printing a `[target: <package>]` header first when there is more
/// than one target. The targets list is never empty: `load_configs` returns
/// the first target separately.
fn for_each_target(
  targets: List(config.Config),
  run: fn(config.Config, ParsedInput) -> Nil,
) -> Nil {
  case targets {
    [] -> Nil
    [first, ..rest] -> {
      let path = config.input(first)
      io.println("Parsing OpenAPI spec: " <> path)
      let reporter = progress.stdout_with_elapsed()
      use parsed <- require(
        parser.parse_file_with_progress_and_locations(path, reporter),
        fn(e) { "Error: " <> parser.parse_error_to_string(e) },
      )
      let #(spec, locations) = parsed
      let input = ParsedInput(path:, spec:, locations:, reporter:)
      list.each(targets, fn(cfg) {
        case rest {
          [] -> Nil
          [_, ..] -> {
            io.println("")
            io.println("[target: " <> config.package(cfg) <> "]")
          }
        }
        run(cfg, input)
      })
    }
  }
}

fn print_resolved_paths_for_all(
  config_path: String,
  cfgs: List(config.Config),
) -> Nil {
  case cfgs {
    [single] -> print_resolved_paths(config_path, single)
    multiple -> {
      case simplifile.current_directory() {
        Ok(cwd) -> {
          io.println("Resolved paths:")
          io.println("  config: " <> resolve_path_from_cwd(config_path, cwd))
          let inputs =
            multiple
            |> list.map(fn(c) { config.input(c) })
            |> list.unique
          list.each(inputs, fn(p) {
            io.println("  input: " <> resolve_path_from_cwd(p, cwd))
          })
          list.each(multiple, fn(cfg) {
            io.println("  target [" <> config.package(cfg) <> "]:")
            print_target_outputs(cfg, cwd, "    ")
          })
        }
        // nolint: thrown_away_error -- path printing is best-effort.
        Error(_) -> Nil
      }
    }
  }
}

fn print_target_outputs(
  cfg: config.Config,
  cwd: String,
  prefix: String,
) -> Nil {
  case config.mode(cfg) {
    config.Server -> {
      io.println(
        prefix
        <> "output.server: "
        <> resolve_path_from_cwd(config.output_server(cfg), cwd),
      )
    }
    config.Client -> {
      io.println(
        prefix
        <> "output.client: "
        <> resolve_path_from_cwd(config.output_client(cfg), cwd),
      )
    }
    config.Both -> {
      io.println(
        prefix
        <> "output.server: "
        <> resolve_path_from_cwd(config.output_server(cfg), cwd),
      )
      io.println(
        prefix
        <> "output.client: "
        <> resolve_path_from_cwd(config.output_client(cfg), cwd),
      )
    }
  }
}

/// Every active output path across every target must be
/// unique. Two targets writing to the same directory would clobber
/// each other on disk and surface random "wrong package" errors at
/// the Gleam compiler level depending on which generate ran second.
fn validate_no_target_overlap(
  cfgs: List(config.Config),
) -> Result(Nil, config.ConfigError) {
  let paths =
    cfgs
    |> list.flat_map(fn(cfg) { active_output_paths(cfg) })
  case first_duplicate(paths, []) {
    None -> Ok(Nil)
    Some(path) ->
      Error(config.InvalidValue(
        field: "targets",
        detail: "two targets resolve to the same output directory '"
          <> path
          <> "' — give them distinct package or output paths so generated files do not clobber each other",
      ))
  }
}

fn active_output_paths(cfg: config.Config) -> List(String) {
  case config.mode(cfg) {
    config.Server -> [config.output_server(cfg)]
    config.Client -> [config.output_client(cfg)]
    // For a single config with `mode: both`, `output.server` and
    // `output.client` may legitimately resolve to the same directory.
    // The codegen writes shared files (types/decode/encode/guards/
    // request_types/response_types) with identical content for both
    // modes, plus server-only files (router/handlers/handlers_generated)
    // and one client-only file (client.gleam) that have unique names —
    // so a shared output directory does not clobber anything. Dedupe
    // intra-config to allow this case while still letting
    // `validate_no_target_overlap` reject cross-config (multi-target)
    // collisions.
    config.Both -> {
      let server_path = config.output_server(cfg)
      let client_path = config.output_client(cfg)
      case server_path == client_path {
        True -> [server_path]
        False -> [server_path, client_path]
      }
    }
  }
}

/// The first path that appears twice, if any.
fn first_duplicate(
  remaining: List(String),
  seen: List(String),
) -> Option(String) {
  case remaining {
    [] -> None
    [path, ..rest] ->
      case list.contains(seen, path) {
        True -> Some(path)
        False -> first_duplicate(rest, [path, ..seen])
      }
  }
}

fn print_resolved_paths(config_path: String, cfg: config.Config) -> Nil {
  case simplifile.current_directory() {
    Ok(cwd) -> {
      io.println("Resolved paths:")
      resolved_path_entries(config_path, cfg, cwd)
      |> list.each(fn(entry) {
        let #(label, path) = entry
        io.println("  " <> label <> ": " <> path)
      })
    }
    // nolint: thrown_away_error -- path printing is best-effort; if the cwd cannot be read we silently skip rather than abort generation.
    Error(_) -> Nil
  }
}

pub fn resolved_path_entries(
  config_path: String,
  cfg: config.Config,
  cwd: String,
) -> List(#(String, String)) {
  let base_entries = [
    #("config", resolve_path_from_cwd(config_path, cwd)),
    #("input", resolve_path_from_cwd(config.input(cfg), cwd)),
  ]
  let output_entries = case config.mode(cfg) {
    config.Server -> [
      #("output.server", resolve_path_from_cwd(config.output_server(cfg), cwd)),
    ]
    config.Client -> [
      #("output.client", resolve_path_from_cwd(config.output_client(cfg), cwd)),
    ]
    config.Both -> [
      #("output.server", resolve_path_from_cwd(config.output_server(cfg), cwd)),
      #("output.client", resolve_path_from_cwd(config.output_client(cfg), cwd)),
    ]
  }
  list.append(base_entries, output_entries)
}

pub fn resolve_path_from_cwd(path: String, cwd: String) -> String {
  let candidate = case path_is_absolute(path) {
    True -> path
    False -> filepath.join(cwd, path)
  }
  filepath.expand(candidate) |> result.unwrap(candidate)
}

fn path_is_absolute(path: String) -> Bool {
  filepath.is_absolute(path)
  || string.starts_with(path, "\\\\")
  || string.starts_with(path, "//")
  || is_windows_drive_absolute(path)
}

fn is_windows_drive_absolute(path: String) -> Bool {
  let prefix = string.slice(from: path, at_index: 0, length: 3)
  case string.to_graphemes(prefix) {
    [drive, ":", slash] ->
      is_ascii_letter(drive) && { slash == "/" || slash == "\\" }
    _ -> False
  }
}

fn is_ascii_letter(value: String) -> Bool {
  case string.lowercase(value) {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z" -> True
    _ -> False
  }
}

/// Write generated files to disk, format them, and print summary.
fn write_files(files: List(context.GeneratedFile), cfg: config.Config) -> Nil {
  io.println("Generating code...")
  use written <- require(
    writer.write_all(files, cfg, fn(path) {
      io.println("  Generated: " <> path)
    }),
    fn(e) { "Error: " <> writer.error_to_string(e) },
  )
  use _ <- require(formatter.format_files(writer.output_dirs(cfg)), fn(e) {
    "Error: " <> formatter.error_to_string(e)
  })
  io.println("  Formatted generated code")
  io.println("")
  io.println(
    "Successfully generated " <> int.to_string(list.length(written)) <> " files",
  )
  print_dep_hints(files)
}

/// Warnings about the user-owned handler stubs, computed before any
/// file is written so `--fail-on-warnings` can stop the run.
fn handler_layout_warnings(
  files: List(context.GeneratedFile),
  cfg: config.Config,
) -> List(String) {
  list.append(
    single_file_handlers_warning(files, cfg),
    orphaned_handlers_warnings(files, cfg),
  )
}

/// Under `handlers: per_operation` the router calls
/// `handlers/<operation>.gleam`. A `handlers.gleam` that still defines
/// a handler for one of the operations was written in single-file mode,
/// and that implementation is no longer called, so say so before the
/// new stubs take over.
fn single_file_handlers_warning(
  files: List(context.GeneratedFile),
  cfg: config.Config,
) -> List(String) {
  let server_output = case config.mode(cfg) {
    config.Server | config.Both -> True
    config.Client -> False
  }
  let handler_names =
    list.filter_map(files, fn(f) {
      case string.split(f.path, "/") {
        ["handlers", file] -> Ok(string.drop_end(file, string.length(".gleam")))
        _ -> Error(Nil)
      }
    })
  let path = config.output_server(cfg) <> "/handlers.gleam"
  case config.handler_layout(cfg), server_output, simplifile.read(path) {
    config.PerOperation, True, Ok(content) ->
      case
        list.any(handler_names, fn(name) {
          string.contains(content, "pub fn " <> name <> "(")
        })
      {
        True -> [
          path
          <> " defines handler functions, but `handlers: per_operation` routes each operation to handlers/<operation>.gleam. Move each implementation into its file under handlers/; the functions in handlers.gleam are no longer called.",
        ]
        False -> []
      }
    _, _, _ -> []
  }
}

/// Warn about `.gleam` files in a generator-owned subdirectory
/// (`handlers/` under `handlers: per_operation`) that match no
/// operation, typically a stub left behind when an operation was
/// removed from the spec or renamed.
fn orphaned_handlers_warnings(
  files: List(context.GeneratedFile),
  cfg: config.Config,
) -> List(String) {
  let output_dirs = writer.output_dirs(cfg)
  let sub_dirs =
    writer.owned_dirs(files, cfg)
    |> list.filter(fn(dir) { !list.contains(output_dirs, dir) })
  find_orphans(sub_dirs, writer.expected_paths(files, cfg))
  |> list.map(fn(path) {
    path
    <> " matches no operation in the spec. Delete it, or move its code if the operation was renamed."
  })
}

/// `.gleam` files directly inside `dirs` that are not in `expected`.
fn find_orphans(dirs: List(String), expected: List(String)) -> List(String) {
  list.flat_map(dirs, fn(dir) {
    case simplifile.read_directory(dir) {
      // nolint: thrown_away_error -- unreadable output dir simply has no orphans to report
      Error(_) -> []
      Ok(entries) ->
        entries
        |> list.filter(fn(name) { string.ends_with(name, ".gleam") })
        |> list.map(fn(name) { dir <> "/" <> name })
        |> list.filter(fn(path) { !list.contains(expected, path) })
    }
  })
}

/// When the generated code imports a Gleam stdlib module
/// whose package is not a direct dep of the consumer's project (today,
/// only `gleam/regexp` for pattern validation), `gleam build` warns
/// about the transitive import and a future Gleam release turns this
/// into a hard error. Print an actionable hint so the user adds the
/// missing dep — we deliberately do not rewrite the consumer's
/// `gleam.toml` because modifying user-managed config invisibly is
/// surprising.
fn print_dep_hints(files: List(context.GeneratedFile)) -> Nil {
  let needs_regexp =
    list.any(files, fn(f) { string.contains(f.content, "import gleam/regexp") })
  case needs_regexp {
    True -> {
      io.println("")
      io.println(
        "Note: generated code imports gleam/regexp for pattern validation.",
      )
      io.println(
        "      Run 'gleam add gleam_regexp' in your project before 'gleam build'.",
      )
    }
    False -> Nil
  }
}

/// Check that generated code matches existing files on disk.
/// Exits 0 if all files match, exits 1 if any differ, missing, or orphaned.
///
/// User-owned `handlers.gleam` (`SkipIfExists`) is dropped from
/// the byte-comparison list (`resolve_paths` does that filtering) but kept in
/// the expected-paths list so orphan detection still recognises it as a known
/// generator output instead of flagging it as an orphan. A user-owned file
/// that does not exist yet is reported as missing: the generated delegator
/// calls it, so the project does not build until `oaspec generate` writes it.
fn run_check(files: List(context.GeneratedFile), cfg: config.Config) -> Nil {
  io.println("Checking generated code against existing files...")
  let resolved = writer.resolve_paths(files, cfg)
  let expected_paths = writer.expected_paths(files, cfg)

  // Format generated content via temp files before comparison
  use resolved <- require(format_resolved_content(resolved), fn(e) {
    "Error: could not format the generated code for comparison: "
    <> check_format_error_to_string(e)
  })

  // Check for missing or differing files
  let diffs =
    list.filter_map(resolved, fn(entry) {
      let #(path, content) = entry
      case simplifile.read(path) {
        // nolint: thrown_away_error -- read failure means file is missing on disk, which is the reported diagnostic
        Error(_) -> Ok(path <> " (missing)")
        Ok(existing) ->
          case string.compare(existing, content) {
            order.Eq -> Error(Nil)
            _ -> Ok(path <> " (differs)")
          }
      }
    })

  let missing_user_files =
    files
    |> list.filter(fn(f) { f.write_mode == context.SkipIfExists })
    |> writer.expected_paths(cfg)
    |> list.filter(fn(path) { simplifile.is_file(path) != Ok(True) })
    |> list.map(fn(path) { path <> " (missing)" })

  // Check for orphaned files in output directories
  let orphans =
    find_orphans(writer.owned_dirs(files, cfg), expected_paths)
    |> list.map(fn(path) { path <> " (orphaned)" })

  let all_issues = list.flatten([diffs, missing_user_files, orphans])
  case all_issues {
    [] -> {
      io.println("")
      io.println("All files up to date, check passed.")
    }
    _ -> {
      io.println_error("")
      list.each(all_issues, fn(d) { io.println_error("  " <> d) })
      io.println_error(
        "\n"
        <> int.to_string(list.length(all_issues))
        <> " file(s) out of date. Run 'oaspec generate' to update.",
      )
      halt(1)
    }
  }
}

/// Format resolved content by writing it to a scratch directory under the
/// OS temp directory, running gleam format there, and reading it back.
/// Any failure is returned so the check never compares unformatted code.
fn format_resolved_content(
  resolved: List(#(String, String)),
) -> Result(List(#(String, String)), CheckFormatError) {
  let temp_dir = filepath.join(temp_dir(), "oaspec_check_" <> unique_id())
  use _ <- result.try(
    simplifile.create_directory_all(temp_dir)
    |> result.map_error(ScratchFileFailed(
      action: "create",
      path: temp_dir,
      error: _,
    )),
  )
  let formatted = format_in_dir(resolved, temp_dir)
  let deleted =
    simplifile.delete(temp_dir)
    |> result.map_error(ScratchFileFailed(
      action: "delete",
      path: temp_dir,
      error: _,
    ))
  use formatted <- result.try(formatted)
  use _ <- result.map(deleted)
  formatted
}

fn format_in_dir(
  resolved: List(#(String, String)),
  temp_dir: String,
) -> Result(List(#(String, String)), CheckFormatError) {
  use temp_entries <- result.try(
    list.index_map(resolved, fn(entry, idx) {
      #(entry, filepath.join(temp_dir, int.to_string(idx) <> ".gleam"))
    })
    |> list.try_map(fn(pair) {
      let #(#(original_path, content), temp_path) = pair
      simplifile.write(temp_path, content)
      |> result.replace(#(original_path, temp_path))
      |> result.map_error(ScratchFileFailed(
        action: "write",
        path: temp_path,
        error: _,
      ))
    }),
  )
  use _ <- result.try(
    formatter.format_files(list.map(temp_entries, fn(entry) { entry.1 }))
    |> result.map_error(FormatterFailed),
  )
  list.try_map(temp_entries, fn(entry) {
    let #(original_path, temp_path) = entry
    simplifile.read(temp_path)
    |> result.map(fn(formatted) { #(original_path, formatted) })
    |> result.map_error(ScratchFileFailed(
      action: "read",
      path: temp_path,
      error: _,
    ))
  })
}

/// Why `--check` could not format the generated code for comparison.
type CheckFormatError {
  ScratchFileFailed(action: String, path: String, error: simplifile.FileError)
  FormatterFailed(formatter.FormatError)
}

fn check_format_error_to_string(error: CheckFormatError) -> String {
  case error {
    ScratchFileFailed(action:, path:, error:) ->
      "cannot "
      <> action
      <> " "
      <> path
      <> ": "
      <> simplifile.describe_error(error)
    FormatterFailed(error) -> formatter.error_to_string(error)
  }
}

/// The OS temp directory: TMPDIR, TEMP or TMP, else the platform default.
@external(erlang, "oaspec_ffi", "temp_dir")
fn temp_dir() -> String

/// Generate a unique ID string for temp directories.
@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn unique_id() -> String {
  let integer_value = unique_integer()
  case integer_value < 0 {
    True -> "n" <> int.to_string(-integer_value)
    False -> int.to_string(integer_value)
  }
}

/// Execute the validation-only pipeline. With a multi-target
/// config, every target is validated against the same parsed spec
/// and the run only succeeds when each target validates cleanly.
fn run_validate(config_path: String, mode_opt: Option(String)) -> Nil {
  io.println("oaspec v" <> context.version)
  io.println("Loading config from: " <> config_path)

  use #(first, rest) <- require(
    load_configs(config_path, mode_opt, None),
    load_config_error_to_string,
  )
  {
    use cfg, input <- for_each_target([first, ..rest])
    use summary <- require(
      generate.validate_only_with_progress_and_locations(
        input.spec,
        input.locations,
        cfg,
        input.reporter,
      ),
      format_generate_error_for(input.path),
    )
    io.println("Spec loaded: " <> summary.spec_title)
    print_warnings_for(input.path, summary.warnings)
  }
  io.println("")
  io.println("Validation passed.")
}

fn load_config_error_to_string(error: config.ConfigError) -> String {
  "Error: " <> config.error_to_string(error)
}

/// Pure config loading and validation pipeline. Returns every target the
/// config declares, the first one separately because a config always
/// declares at least one. CLI overrides (`--mode`, `--output`) are applied
/// uniformly to every target; `--output` over a multi-target config is
/// rejected because each target already declares its own per-package
/// output directory.
fn load_configs(
  config_path: String,
  mode_opt: Option(String),
  output_opt: Option(String),
) -> Result(#(config.Config, List(config.Config)), config.ConfigError) {
  use cfgs <- result.try(config.load_all(config_path))
  use #(first, rest) <- result.try(case cfgs {
    [first, ..rest] -> Ok(#(first, rest))
    [] ->
      Error(config.InvalidValue(
        field: "targets",
        detail: "must declare at least one target",
      ))
  })
  use #(first, rest) <- result.try(case mode_opt {
    None -> Ok(#(first, rest))
    Some(mode_str) -> {
      use parsed <- result.map(config.parse_mode(mode_str))
      #(
        config.with_mode(first, parsed),
        list.map(rest, config.with_mode(_, parsed)),
      )
    }
  })
  use first <- result.try(case output_opt, rest {
    None, _ -> Ok(first)
    Some(path), [] -> Ok(config.with_output(first, Some(path)))
    Some(_), [_, ..] ->
      Error(config.InvalidValue(
        field: "--output",
        detail: "cannot override the output directory for a multi-target config; each target already declares its own output (set per-target output: in oaspec.yaml or drop the --output flag)",
      ))
  })
  // Each target's own server/client paths must satisfy the per-
  // target invariants (basename matches package, src placement is
  // safe).
  use _ <- result.try(list.try_each([first, ..rest], validate_target_paths))
  Ok(#(first, rest))
}

fn validate_target_paths(
  cfg: config.Config,
) -> Result(Nil, config.ConfigError) {
  use _ <- result.try(config.validate_output_package_match(cfg))
  config.validate_output_dir_layout(cfg)
}

/// Unwrap a Result or print the error message and exit.
/// Designed for use with `use value <- require(result, to_message)`.
fn require(
  result: Result(a, b),
  to_message: fn(b) -> String,
  continue: fn(a) -> Nil,
) -> Nil {
  case result {
    Ok(value) -> continue(value)
    Error(err) -> {
      io.println_error(to_message(err))
      halt(1)
    }
  }
}

/// Format a GenerateError into a printable error message.
///
/// Each diagnostic is rendered with an editor-clickable
/// `path:line:column:` prefix when the spec file path and a `SourceLoc`
/// are both known. Diagnostics without a `SourceLoc` use the short-string
/// format.
fn format_generate_error_for(
  file_path: String,
) -> fn(generate.GenerateError) -> String {
  fn(err: generate.GenerateError) -> String {
    let generate.ValidationErrors(errors:) = err
    let file_opt = case file_path {
      "" -> None
      _ -> Some(file_path)
    }
    "Error: OpenAPI spec contains unsupported features:\n"
    <> string.join(
      list.map(errors, fn(validation_error) {
        "  - "
        <> case validation_error.source_loc {
          diagnostic.SourceLoc(..) ->
            diagnostic.render(validation_error, file_opt)
          diagnostic.NoSourceLoc -> diagnostic.to_short_string(validation_error)
        }
      }),
      "\n",
    )
  }
}

/// Print warnings if any exist. Warnings are diagnostics, so they go to stderr
/// to keep stdout reserved for requested output. See
/// `format_generate_error_for` for the rendering contract.
fn print_warnings_for(
  file_path: String,
  warnings: List(diagnostic.Diagnostic),
) -> Nil {
  let file_opt = case file_path {
    "" -> None
    _ -> Some(file_path)
  }
  case warnings {
    [] -> Nil
    _ -> {
      io.println_error("Warnings:")
      list.each(warnings, fn(w) {
        let rendered = case w.source_loc {
          diagnostic.SourceLoc(..) -> diagnostic.render(w, file_opt)
          diagnostic.NoSourceLoc -> diagnostic.to_short_string(w)
        }
        io.println_error("  - " <> rendered)
      })
    }
  }
}

/// Exit the process with a status code.
@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
