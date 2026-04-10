import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import glint
import oaspec/codegen/context
import oaspec/codegen/validate
import oaspec/codegen/writer
import oaspec/config
import oaspec/generate
import oaspec/openapi/parser
import simplifile

/// Set up the CLI application.
pub fn app() -> glint.Glint(Nil) {
  glint.new()
  |> glint.with_name("oaspec")
  |> glint.global_help("Generate Gleam code from OpenAPI 3.x specifications")
  |> glint.pretty_help(glint.default_pretty_help())
  |> glint.add(at: ["generate"], do: generate_command())
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

          run_generate(config_path, mode_opt, output_opt)
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
) -> Nil {
  io.println("oaspec v" <> context.version)
  io.println("Loading config from: " <> config_path)

  case load_config(config_path, mode_opt, output_opt) {
    Error(msg) -> {
      io.println("Error: " <> msg)
      halt(1)
    }
    Ok(cfg) -> {
      io.println("Parsing OpenAPI spec: " <> cfg.input)
      case parser.parse_file(cfg.input) {
        Error(e) -> {
          io.println("Error: " <> parser.parse_error_to_string(e))
          halt(1)
        }
        Ok(spec) -> {
          case generate.generate(spec, cfg) {
            Error(generate.ValidationErrors(errors:)) -> {
              io.println("Error: OpenAPI spec contains unsupported features:")
              list.each(errors, fn(e) {
                io.println("  - " <> validate.error_to_string(e))
              })
              halt(1)
            }
            Error(generate.ResolveError(detail:)) -> {
              io.println(
                "Error: Failed to resolve component aliases: " <> detail,
              )
              halt(1)
            }
            Ok(summary) -> {
              io.println("Spec loaded: " <> summary.spec_title)
              case summary.warnings {
                [] -> Nil
                warnings -> {
                  io.println("Warnings:")
                  list.each(warnings, fn(w) {
                    io.println("  - " <> validate.error_to_string(w))
                  })
                }
              }
              io.println("Generating code...")
              case
                writer.write_all(summary.files, cfg, fn(path) {
                  io.println("  Generated: " <> path)
                })
              {
                Ok(written) -> {
                  io.println("")
                  io.println(
                    "Successfully generated "
                    <> int.to_string(list.length(written))
                    <> " files",
                  )
                }
                Error(e) -> {
                  io.println("Error: " <> writer.error_to_string(e))
                  halt(1)
                }
              }
            }
          }
        }
      }
    }
  }
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

/// Exit the process with a status code.
@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
