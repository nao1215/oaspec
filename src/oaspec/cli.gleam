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

/// Set up the CLI application.
pub fn app() -> glint.Glint(Nil) {
  glint.new()
  |> glint.with_name("oaspec")
  |> glint.global_help("Generate Gleam code from OpenAPI 3.x specifications")
  |> glint.pretty_help(glint.default_pretty_help())
  |> glint.add(at: ["generate"], do: generate_command())
  |> glint.add(at: ["validate"], do: validate_command())
  |> glint.add(at: ["init"], do: init_command())
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

          run_generate(
            config_path,
            mode_opt,
            output_opt,
            check_mode,
            fail_on_warnings_mode,
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
        let path = case output_path(flags) {
          Ok(p) -> p
          Error(_) -> "./oaspec.yaml"
        }
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

# Output settings (optional).
# output:
#   dir: ./gen                    # Base output directory (default: ./gen)
#   server: ./gen/api             # Override server output path
#   client: ./gen_client/api      # Override client output path
"

  case simplifile.is_file(path) {
    Ok(True) -> {
      io.println("Error: " <> path <> " already exists")
      halt(1)
    }
    _ -> {
      case simplifile.write(path, template) {
        Ok(_) -> io.println("Created " <> path)
        Error(_) -> {
          io.println("Error: failed to write " <> path)
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
) -> Nil {
  io.println("oaspec v" <> context.version)
  io.println("Loading config from: " <> config_path)

  use cfg <- require(load_config(config_path, mode_opt, output_opt), fn(msg) {
    "Error: " <> msg
  })

  io.println("Parsing OpenAPI spec: " <> cfg.input)
  use spec <- require(parser.parse_file(cfg.input), fn(e) {
    "Error: " <> parser.parse_error_to_string(e)
  })

  use summary <- require(generate.generate(spec, cfg), format_generate_error)

  io.println("Spec loaded: " <> summary.spec_title)
  print_warnings(summary.warnings)
  case fail_on_warnings && summary.warnings != [] {
    True -> {
      io.println("")
      io.println("Error: warnings present and --fail-on-warnings is set.")
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
fn run_check(files: List(context.GeneratedFile), cfg: config.Config) -> Nil {
  io.println("Checking generated code against existing files...")
  let resolved = writer.resolve_paths(files, cfg)
  let expected_paths = list.map(resolved, fn(entry) { entry.0 })

  // Format generated content via temp files before comparison
  let resolved = format_resolved_content(resolved)

  // Check for missing or differing files
  let diffs =
    list.filter_map(resolved, fn(entry) {
      let #(path, content) = entry
      case simplifile.read(path) {
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
      io.println("")
      list.each(all_issues, fn(d) { io.println("  " <> d) })
      io.println(
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
    Error(_) -> resolved
    Ok(Nil) -> {
      // Write each file to the temp directory with unique indexed names
      let temp_entries =
        list.index_map(resolved, fn(entry, idx) {
          let #(original_path, content) = entry
          let temp_path = temp_dir <> "/" <> int.to_string(idx) <> ".gleam"
          let _ = simplifile.write(temp_path, content)
          #(original_path, temp_path)
        })

      // Format all temp files
      let temp_paths = list.map(temp_entries, fn(e) { e.1 })
      let formatted_resolved = case formatter.format_files(temp_paths) {
        Ok(Nil) -> {
          list.map(temp_entries, fn(entry) {
            let #(original_path, temp_path) = entry
            case simplifile.read(temp_path) {
              Ok(formatted) -> #(original_path, formatted)
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
        Error(_) -> resolved
      }

      // Clean up temp directory
      let _ = simplifile.delete(temp_dir)
      formatted_resolved
    }
  }
}

/// Generate a unique ID string for temp directories.
@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn unique_id() -> String {
  let n = unique_integer()
  case n < 0 {
    True -> "n" <> int.to_string(-n)
    False -> int.to_string(n)
  }
}

/// Execute the validation-only pipeline.
fn run_validate(config_path: String, mode_opt: Option(String)) -> Nil {
  io.println("oaspec v" <> context.version)
  io.println("Loading config from: " <> config_path)

  use cfg <- require(load_config(config_path, mode_opt, None), fn(msg) {
    "Error: " <> msg
  })

  io.println("Parsing OpenAPI spec: " <> cfg.input)
  use spec <- require(parser.parse_file(cfg.input), fn(e) {
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

/// Pure config loading and validation pipeline.
fn load_config(
  config_path: String,
  mode_opt: Option(String),
  output_opt: Option(String),
) -> Result(config.Config, String) {
  use cfg <- result.try(
    config.load(config_path)
    |> result.map_error(config.error_to_string),
  )
  use cfg <- result.try(case mode_opt {
    None -> Ok(cfg)
    Some(mode_str) ->
      config.parse_mode(mode_str)
      |> result.map(fn(m) { config.with_mode(cfg, m) })
      |> result.map_error(config.error_to_string)
  })
  let cfg = case output_opt {
    None -> cfg
    Some(path) -> config.with_output(cfg, Some(path))
  }
  config.validate_output_package_match(cfg)
  |> result.map(fn(_) { cfg })
  |> result.map_error(config.error_to_string)
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
      io.println(to_message(err))
      halt(1)
    }
  }
}

/// Format a GenerateError into a printable error message.
fn format_generate_error(err: generate.GenerateError) -> String {
  case err {
    generate.ValidationErrors(errors:) ->
      "Error: OpenAPI spec contains unsupported features:\n"
      <> string.join(
        list.map(errors, fn(e) { "  - " <> diagnostic.to_short_string(e) }),
        "\n",
      )
  }
}

/// Print warnings if any exist.
fn print_warnings(warnings: List(diagnostic.Diagnostic)) -> Nil {
  case warnings {
    [] -> Nil
    _ -> {
      io.println("Warnings:")
      list.each(warnings, fn(w) {
        io.println("  - " <> diagnostic.to_short_string(w))
      })
    }
  }
}

/// Exit the process with a status code.
@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
