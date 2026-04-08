import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import glint
import oaspec/codegen/context
import oaspec/codegen/validate
import oaspec/codegen/writer
import oaspec/config
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
          let config_path = case config_path(flags) {
            Ok(p) -> p
            Error(_) -> "./oaspec.yaml"
          }

          let mode_str = case mode(flags) {
            Ok(m) -> m
            Error(_) -> "both"
          }

          let output_str = case output(flags) {
            Ok(o) -> o
            Error(_) -> ""
          }

          run_generate(config_path, mode_str, output_str)
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
fn run_generate(
  config_path: String,
  mode_str: String,
  output_str: String,
) -> Nil {
  io.println("oaspec v" <> context.version)
  io.println("Loading config from: " <> config_path)

  // Load config
  let cfg = case config.load(config_path) {
    Ok(c) -> c
    Error(e) -> {
      io.println("Error: " <> config.error_to_string(e))
      halt(1)
      panic as "unreachable"
    }
  }

  // Apply mode override (only if CLI flag was explicitly set)
  let cfg = case mode_str {
    "" -> cfg
    _ ->
      case config.parse_mode(mode_str) {
        Ok(m) -> config.with_mode(cfg, m)
        Error(e) -> {
          io.println("Error: " <> config.error_to_string(e))
          halt(1)
          panic as "unreachable"
        }
      }
  }

  // Apply output override
  let cfg = case output_str {
    "" -> cfg
    path -> config.with_output(cfg, Some(path))
  }

  // Validate config after all overrides
  case config.validate_output_package_match(cfg) {
    Ok(_) -> Nil
    Error(e) -> {
      io.println("Error: " <> config.error_to_string(e))
      halt(1)
    }
  }

  io.println("Parsing OpenAPI spec: " <> cfg.input)

  // Parse the OpenAPI spec
  let spec = case parser.parse_file(cfg.input) {
    Ok(s) -> s
    Error(e) -> {
      let detail = case e {
        parser.FileError(detail:) -> detail
        parser.YamlError(detail:) -> detail
        parser.MissingField(path:, field:) ->
          "Missing field '" <> field <> "' at " <> path
        parser.InvalidValue(path:, detail:) ->
          "Invalid value at " <> path <> ": " <> detail
      }
      io.println("Error: " <> detail)
      halt(1)
      panic as "unreachable"
    }
  }

  io.println("Spec loaded: " <> spec.info.title <> " v" <> spec.info.version)

  // Create generation context
  let ctx = context.new(spec, cfg)

  // Validate spec for unsupported features
  let validation_errors = validate.validate(ctx)
  case list.is_empty(validation_errors) {
    True -> Nil
    False -> {
      io.println("Error: OpenAPI spec contains unsupported features:")
      list.each(validation_errors, fn(e) {
        io.println("  - " <> validate.error_to_string(e))
      })
      halt(1)
    }
  }

  // Generate files
  io.println("Generating code...")
  case
    writer.generate_all(ctx, fn(path) { io.println("  Generated: " <> path) })
  {
    Ok(files) -> {
      io.println("")
      io.println(
        "Successfully generated "
        <> int.to_string(list_length(files))
        <> " files",
      )
    }
    Error(e) -> {
      io.println("Error: " <> writer.error_to_string(e))
      halt(1)
    }
  }
}

/// Exit the process with a status code.
@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

/// Get list length.
fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}
