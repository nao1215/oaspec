import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import glint
import oaspec/codegen/context
import oaspec/codegen/writer
import oaspec/config
import oaspec/formatter
import oaspec/generate
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
        "Enable guard validation in generated server/client code",
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

# Enable guard validation in generated server/client code (default: false).
# When enabled, generated routers validate request bodies against schema
# constraints and return 422 on failure. Generated clients validate
# request bodies before sending.
# validate: false

# Output settings (optional).
# output:
#   dir: ./gen                    # Base directory; default paths are
#                                 #   server -> <dir>/<package>
#                                 #   client -> <dir>/<package>_client
#                                 # so a single `gleam build` rooted at <dir>
#                                 # picks up both.
#   server: ./gen/api             # Override server output path
#   client: ./gen/api_client      # Override client output path
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

  use cfg <- require(
    load_config(config_path, mode_opt, output_opt),
    load_config_error_to_string,
  )
  let cfg = case validate_mode {
    True -> config.with_validate(cfg, True)
    False -> cfg
  }

  io.println("Parsing OpenAPI spec: " <> config.input(cfg))
  use spec <- require(parser.parse_file(config.input(cfg)), fn(e) {
    "Error: " <> parser.parse_error_to_string(e)
  })

  use summary <- require(generate.generate(spec, cfg), format_generate_error)

  io.println("Spec loaded: " <> summary.spec_title)
  print_warnings(summary.warnings)
  case fail_on_warnings && summary.warnings != [] {
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

/// Execute the validation-only pipeline.
fn run_validate(config_path: String, mode_opt: Option(String)) -> Nil {
  io.println("oaspec v" <> context.version)
  io.println("Loading config from: " <> config_path)

  use cfg <- require(
    load_config(config_path, mode_opt, None),
    load_config_error_to_string,
  )

  io.println("Parsing OpenAPI spec: " <> config.input(cfg))
  use spec <- require(parser.parse_file(config.input(cfg)), fn(e) {
    "Error: " <> parser.parse_error_to_string(e)
  })

  use summary <- require(
    generate.validate_only(spec, cfg),
    format_generate_error,
  )

  io.println("Spec loaded: " <> summary.spec_title)
  print_warnings(summary.warnings)
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

/// Pure config loading and validation pipeline.
fn load_config(
  config_path: String,
  mode_opt: Option(String),
  output_opt: Option(String),
) -> Result(config.Config, LoadConfigError) {
  use cfg <- result.try(
    config.load(config_path)
    |> result.map_error(ConfigLoadError),
  )
  use cfg <- result.try(case mode_opt {
    None -> Ok(cfg)
    Some(mode_str) ->
      config.parse_mode(mode_str)
      |> result.map(fn(parsed) { config.with_mode(cfg, parsed) })
      |> result.map_error(ModeParseError)
  })
  let cfg = case output_opt {
    None -> cfg
    Some(path) -> config.with_output(cfg, Some(path))
  }
  config.validate_output_package_match(cfg)
  |> result.map(fn(_) { cfg })
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
