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
import oaspec/internal/progress
import oaspec/openapi/diagnostic
import oaspec/openapi/parser
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

# Output settings (optional).
# output:
#   dir: ./gen                    # Base directory; default paths are
#                                 #   server -> <dir>/<package>
#                                 #   client -> <dir>/<package>_client
#                                 # so a single `gleam build` rooted at <dir>
#                                 # picks up both.
#   server: ./gen/api             # Override server output path
#   client: ./gen/api_client      # Override client output path

# Operation filter (optional, Issue #387). When set, codegen only
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

# Multi-target codegen (optional, Issue #387). When `targets:` is
# set, the same input spec is generated once per entry, each with
# its own `package`, `output`, and `include`. The top-level
# `input`, `mode`, and `validate` are shared across every target.
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

  // Issue #387: a config may declare multiple `targets:`. Each target
  // produces its own package + output tree from the same input spec.
  // The single-target legacy shape returns a 1-element list here.
  use cfgs <- require(
    load_configs(config_path, mode_opt, output_opt),
    load_config_error_to_string,
  )
  let cfgs =
    list.map(cfgs, fn(c) {
      case validate_mode {
        True -> config.with_validate(c, True)
        False -> c
      }
    })

  // Reject configs where two targets would write to the same
  // directory — generated files would clobber each other and there
  // is no sensible default order.
  use _ <- require(
    validate_no_target_overlap(cfgs),
    load_config_error_to_string,
  )

  print_resolved_paths_for_all(config_path, cfgs)

  // The input spec is shared across every target, so parse it once.
  // `load_configs` rejects empty target lists at config-load time,
  // so `cfgs` is guaranteed non-empty by the time we get here.
  // nolint: assert_ok_pattern -- `load_configs` rejects empty target lists; reaching the empty branch would be an internal invariant violation.
  let assert [first_cfg, ..] = cfgs
  let shared_input = config.input(first_cfg)
  io.println("Parsing OpenAPI spec: " <> shared_input)
  let reporter = progress.stdout_with_elapsed()
  use spec <- require(
    parser.parse_file_with_progress(shared_input, reporter),
    fn(e) { "Error: " <> parser.parse_error_to_string(e) },
  )

  // Run codegen once per target. `generate_with_progress` re-runs
  // every per-target stage (filter / hoist / dedup / validate /
  // codegen) so each target sees only the operations its filter
  // keeps. `parse` and `normalize` would be re-run too if we passed
  // the same `OpenApiSpec(Unresolved)` value through the pipeline,
  // but those stages are pure and cheap relative to codegen.
  let multi_target = case cfgs {
    [_, _, ..] -> True
    _ -> False
  }
  list.each(cfgs, fn(cfg) {
    case multi_target {
      True -> {
        io.println("")
        io.println("[target: " <> config.package(cfg) <> "]")
      }
      False -> Nil
    }
    use summary <- require(
      generate.generate_with_progress(spec, cfg, reporter),
      format_generate_error,
    )
    io.println("Spec loaded: " <> summary.spec_title)
    print_warnings(summary.warnings)
    case fail_on_warnings && summary.warnings != [] {
      True -> {
        io.println_error("")
        io.println_error(
          "Error: warnings present and --fail-on-warnings is set.",
        )
        halt(1)
      }
      False -> Nil
    }
    case check_mode {
      True -> run_check(summary.files, cfg)
      False -> write_files(summary.files, cfg)
    }
  })
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

fn print_target_outputs(cfg: config.Config, cwd: String, prefix: String) -> Nil {
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

/// Issue #387: every active output path across every target must be
/// unique. Two targets writing to the same directory would clobber
/// each other on disk and surface random "wrong package" errors at
/// the Gleam compiler level depending on which generate ran second.
fn validate_no_target_overlap(
  cfgs: List(config.Config),
) -> Result(Nil, LoadConfigError) {
  let paths =
    cfgs
    |> list.flat_map(fn(cfg) { active_output_paths(cfg) })
  find_duplicate_path(paths, [])
  |> result.map_error(fn(err) {
    let DuplicateOutputPath(path) = err
    OutputValidationError(error: config.InvalidValue(
      field: "targets",
      detail: "two targets resolve to the same output directory '"
        <> path
        <> "' — give them distinct package or output paths so generated files do not clobber each other",
    ))
  })
}

fn active_output_paths(cfg: config.Config) -> List(String) {
  case config.mode(cfg) {
    config.Server -> [config.output_server(cfg)]
    config.Client -> [config.output_client(cfg)]
    config.Both -> [config.output_server(cfg), config.output_client(cfg)]
  }
}

/// Internal error from `find_duplicate_path/2`. Wrapping the offending
/// path in a named record (rather than a bare String) keeps the
/// linter happy and makes the failure mode explicit for any future
/// caller that wants the path on its own.
type DuplicateOutputPathError {
  DuplicateOutputPath(path: String)
}

fn find_duplicate_path(
  remaining: List(String),
  seen: List(String),
) -> Result(Nil, DuplicateOutputPathError) {
  case remaining {
    [] -> Ok(Nil)
    [path, ..rest] ->
      case list.contains(seen, path) {
        True -> Error(DuplicateOutputPath(path: path))
        False -> find_duplicate_path(rest, [path, ..seen])
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

@internal
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

@internal
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

/// Issue #284: when the generated code imports a Gleam stdlib module
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
/// Issue #247: user-owned `handlers.gleam` (`SkipIfExists`) is dropped from
/// the byte-comparison list (`resolve_paths` does that filtering) but kept in
/// the expected-paths list so orphan detection still recognises it as a known
/// generator output instead of flagging it as an orphan.
fn run_check(files: List(context.GeneratedFile), cfg: config.Config) -> Nil {
  io.println("Checking generated code against existing files...")
  let resolved = writer.resolve_paths(files, cfg)
  let expected_paths = writer.expected_paths(files, cfg)

  // Format generated content via temp files before comparison
  let resolved = format_resolved_content(resolved)

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

  // Check for orphaned files in output directories
  let output_dirs = writer.output_dirs(cfg)
  let orphans =
    list.flat_map(output_dirs, fn(dir) {
      case simplifile.read_directory(dir) {
        // nolint: thrown_away_error -- unreadable output dir simply has no orphans to report
        Error(_) -> []
        Ok(entries) ->
          list.filter_map(entries, fn(name) {
            case string.ends_with(name, ".gleam") {
              False -> Error(Nil)
              True -> {
                let full_path = dir <> "/" <> name
                case list.contains(expected_paths, full_path) {
                  True -> Error(Nil)
                  False -> Ok(full_path <> " (orphaned)")
                }
              }
            }
          })
      }
    })

  let all_issues = list.append(diffs, orphans)
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

/// Format resolved content by writing to a temp directory, running gleam format,
/// and reading back the formatted content.
fn format_resolved_content(
  resolved: List(#(String, String)),
) -> List(#(String, String)) {
  let temp_dir = "/tmp/oaspec_check_" <> unique_id()
  case simplifile.create_directory_all(temp_dir) {
    // nolint: thrown_away_error -- if temp dir cannot be created we fall back to unformatted content
    Error(_) -> resolved
    Ok(Nil) -> {
      // Write each file to the temp directory with unique indexed names
      let temp_entries =
        list.index_map(resolved, fn(entry, idx) {
          let #(original_path, content) = entry
          let temp_path = temp_dir <> "/" <> int.to_string(idx) <> ".gleam"
          // Best-effort temp write; formatter step falls back if anything failed
          let _ignored_write = simplifile.write(temp_path, content)
          #(original_path, temp_path)
        })

      // Format all temp files
      let temp_paths = list.map(temp_entries, fn(entry) { entry.1 })
      let formatted_resolved = case formatter.format_files(temp_paths) {
        Ok(Nil) -> {
          list.map(temp_entries, fn(entry) {
            let #(original_path, temp_path) = entry
            case simplifile.read(temp_path) {
              Ok(formatted) -> #(original_path, formatted)
              // nolint: thrown_away_error -- unreadable temp file falls back to unformatted original content
              Error(_) -> {
                let content =
                  list.find(resolved, fn(r) { r.0 == original_path })
                  |> result.map(fn(r) { r.1 })
                  |> result.unwrap("")
                #(original_path, content)
              }
            }
          })
        }
        // nolint: thrown_away_error -- formatter failure falls back to unformatted content
        Error(_) -> resolved
      }

      // Clean up temp directory; leaked temp dirs are not fatal
      let _ignored_delete = simplifile.delete(temp_dir)
      formatted_resolved
    }
  }
}

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

  use cfgs <- require(
    load_configs(config_path, mode_opt, None),
    load_config_error_to_string,
  )

  // `load_configs` rejects empty target lists; the destructure
  // documents that invariant for any future reader.
  // nolint: assert_ok_pattern -- `load_configs` rejects empty target lists; reaching the empty branch would be an internal invariant violation.
  let assert [first_cfg, ..] = cfgs
  let shared_input = config.input(first_cfg)
  io.println("Parsing OpenAPI spec: " <> shared_input)
  let reporter = progress.stdout_with_elapsed()
  use spec <- require(
    parser.parse_file_with_progress(shared_input, reporter),
    fn(e) { "Error: " <> parser.parse_error_to_string(e) },
  )

  let multi_target = case cfgs {
    [_, _, ..] -> True
    _ -> False
  }
  list.each(cfgs, fn(cfg) {
    case multi_target {
      True -> {
        io.println("")
        io.println("[target: " <> config.package(cfg) <> "]")
      }
      False -> Nil
    }
    use summary <- require(
      generate.validate_only_with_progress(spec, cfg, reporter),
      format_generate_error,
    )
    io.println("Spec loaded: " <> summary.spec_title)
    print_warnings(summary.warnings)
  })
  io.println("")
  io.println("Validation passed.")
}

/// Errors surfaced while loading and validating the oaspec config.
/// Wraps the underlying `config.ConfigError` so `load_config` can return a
/// structured error type rather than a plain string.
type LoadConfigError {
  ConfigLoadError(error: config.ConfigError)
  ModeParseError(error: config.ConfigError)
  OutputValidationError(error: config.ConfigError)
}

/// Format a `LoadConfigError` into a user-facing message.
fn load_config_error_to_string(error: LoadConfigError) -> String {
  let detail = case error {
    ConfigLoadError(error:) -> config.error_to_string(error)
    ModeParseError(error:) -> config.error_to_string(error)
    OutputValidationError(error:) -> config.error_to_string(error)
  }
  "Error: " <> detail
}

/// Pure config loading and validation pipeline. Issue #387: returns
/// every target the config declares (1 for legacy single-target,
/// N for multi-target). CLI overrides (`--mode`, `--output`) are
/// applied uniformly to every target; `--output` over a multi-
/// target config is rejected because each target already declares
/// its own per-package output directory.
fn load_configs(
  config_path: String,
  mode_opt: Option(String),
  output_opt: Option(String),
) -> Result(List(config.Config), LoadConfigError) {
  use cfgs <- result.try(
    config.load_all(config_path)
    |> result.map_error(ConfigLoadError),
  )
  use cfgs <- result.try(case mode_opt {
    None -> Ok(cfgs)
    Some(mode_str) ->
      config.parse_mode(mode_str)
      |> result.map(fn(parsed) {
        list.map(cfgs, fn(c) { config.with_mode(c, parsed) })
      })
      |> result.map_error(ModeParseError)
  })
  use cfgs <- result.try(case output_opt, cfgs {
    None, _ -> Ok(cfgs)
    Some(path), [single] -> Ok([config.with_output(single, Some(path))])
    Some(_), [_, _, ..] ->
      Error(
        OutputValidationError(error: config.InvalidValue(
          field: "--output",
          detail: "cannot override the output directory for a multi-target config; each target already declares its own output (set per-target output: in oaspec.yaml or drop the --output flag)",
        )),
      )
    Some(_), [] ->
      Error(
        OutputValidationError(error: config.InvalidValue(
          field: "targets",
          detail: "must declare at least one target",
        )),
      )
  })
  // Each target's own server/client paths must satisfy the per-
  // target invariants (basename matches package, src placement is
  // safe). Run both validators on every target.
  use _ <- result.try(
    cfgs
    |> list.try_map(fn(cfg) { validate_target_paths(cfg) })
    |> result.map(fn(_) { Nil }),
  )
  Ok(cfgs)
}

fn validate_target_paths(cfg: config.Config) -> Result(Nil, LoadConfigError) {
  use _ <- result.try(
    config.validate_output_package_match(cfg)
    |> result.map_error(OutputValidationError),
  )
  config.validate_output_dir_layout(cfg)
  |> result.map_error(OutputValidationError)
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
fn format_generate_error(err: generate.GenerateError) -> String {
  let generate.ValidationErrors(errors:) = err
  "Error: OpenAPI spec contains unsupported features:\n"
  <> string.join(
    list.map(errors, fn(validation_error) {
      "  - " <> diagnostic.to_short_string(validation_error)
    }),
    "\n",
  )
}

/// Print warnings if any exist. Warnings are diagnostics, so they go to stderr
/// to keep stdout reserved for requested output.
fn print_warnings(warnings: List(diagnostic.Diagnostic)) -> Nil {
  case warnings {
    [] -> Nil
    _ -> {
      io.println_error("Warnings:")
      list.each(warnings, fn(w) {
        io.println_error("  - " <> diagnostic.to_short_string(w))
      })
    }
  }
}

/// Exit the process with a status code.
@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
