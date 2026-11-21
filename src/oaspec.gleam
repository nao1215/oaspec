//// Generate Gleam code from an OpenAPI 3.x document.
////
//// oaspec is a command line tool (`gleam run -m oaspec -- generate`), and
//// the same steps are available as functions: read a document, resolve
//// its `$ref`s, generate the modules and write them.
////
//// ```gleam
//// import oaspec
//// import oaspec/config
////
//// pub fn main() {
////   let assert Ok(cfg) = config.load("oaspec.yaml")
////   let assert Ok(spec) = oaspec.parse_file(cfg.input)
////   let assert Ok(generated) = oaspec.generate(spec, cfg)
////   let assert Ok(_paths) = oaspec.write(generated)
//// }
//// ```

import argv
import gleam/io
import gleam/list
import gleam/result
import glint
import oaspec/config.{type Config}
import oaspec/internal/cli
import oaspec/internal/codegen/context
import oaspec/internal/codegen/writer
import oaspec/internal/config_check
import oaspec/internal/generate as internal_generate
import oaspec/internal/openapi/parser
import oaspec/openapi.{
  type Diagnostic, type OpenApiSpec, type Resolved, type Unresolved,
}
import simplifile

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

/// Runs the oaspec command line tool with the program's arguments.
///
/// Errors go to stderr and requested output, such as `--help`, to stdout.
/// The process exits with status 1 on failure.
///
pub fn main() -> Nil {
  let arguments = argv.load().arguments
  case arguments {
    ["--version", ..] -> io.println("oaspec v" <> context.version)
    _ -> run_glint(cli.normalize_argv(arguments))
  }
}

fn run_glint(arguments: List(String)) -> Nil {
  case glint.execute(cli.app(), arguments) {
    Error(message) -> {
      io.println_error(message)
      halt(1)
    }
    Ok(glint.Help(text)) -> io.println(text)
    Ok(glint.Out(_)) -> Nil
  }
}

/// The modules `generate` produced, and the warnings it reported.
pub type Generated {
  Generated(files: List(GeneratedFile), warnings: List(Diagnostic))
}

/// One generated module.
pub type GeneratedFile {
  GeneratedFile(
    /// Where the file goes: the output directory from the config joined
    /// with the module path, such as `./src/api/types.gleam`.
    path: String,
    content: String,
    write_mode: WriteMode,
  )
}

/// What `write` does when the file already exists.
pub type WriteMode {
  /// Replace it. Used for every module the generator owns.
  Overwrite
  /// Leave it alone. Used for the server handler stubs, which the user
  /// fills in.
  SkipIfExists
}

/// A reason `generate` or `validate` refused a document.
pub type GenerateError {
  /// The document uses features oaspec cannot generate code for, or has
  /// references that do not resolve. Each problem is one diagnostic.
  InvalidSpec(errors: List(Diagnostic))
  /// The config's output directories do not fit its `package`: the server
  /// directory must end in the package path, the client directory in the
  /// package path or `<package>_client`, and a `src` directory may only be
  /// the direct parent of the package directory. These are the checks the
  /// CLI runs after loading `oaspec.yaml`.
  InvalidConfig(error: config.ConfigError)
}

/// A reason `write` stopped. Files written before the failure stay on
/// disk.
pub type WriteError {
  CannotCreateDirectory(path: String, reason: simplifile.FileError)
  CannotWriteFile(path: String, reason: simplifile.FileError)
}

/// Reads an OpenAPI document from a YAML (`.yaml`, `.yml`) or JSON
/// (`.json`) file.
///
/// `$ref`s to other local files are loaded and merged in; URLs are not
/// followed. The result is not resolved yet: pass it to `generate`, or to
/// `resolve` to inspect it.
///
/// A file larger than 16 MiB is refused with a `parse_limit_exceeded`
/// diagnostic before it is parsed.
///
/// ## Examples
///
/// ```gleam
/// oaspec.parse_file("openapi.yaml")
/// // -> Ok(OpenApiSpec(openapi: "3.0.3", ..))
/// ```
///
/// ```gleam
/// oaspec.parse_file("missing.yaml")
/// // -> Error(Diagnostic(code: "file_error", ..))
/// ```
///
pub fn parse_file(path: String) -> Result(OpenApiSpec(Unresolved), Diagnostic) {
  parser.parse_file(path)
}

/// Parses an OpenAPI document from a string. Content that starts with `{`
/// or `[` is read as JSON, anything else as YAML.
///
/// `$ref`s to other files are left as they are. Content larger than 16 MiB
/// is refused with a `parse_limit_exceeded` diagnostic before it is parsed.
///
/// ## Examples
///
/// ```gleam
/// oaspec.parse_string("openapi: 3.0.3\ninfo: {title: Pets, version: '1'}\npaths: {}")
/// // -> Ok(OpenApiSpec(openapi: "3.0.3", ..))
/// ```
///
/// ```gleam
/// oaspec.parse_string("openapi: 3.0.3\npaths: {}")
/// // -> Error(Diagnostic(code: "missing_field", ..))
/// ```
///
pub fn parse_string(
  content: String,
) -> Result(OpenApiSpec(Unresolved), Diagnostic) {
  parser.parse_string_or_json_with_locations(content)
  |> result.map(fn(pair) { pair.0 })
}

/// Resolves the `$ref`s in a parsed document so every `RefOr` is a
/// `Value`, after rewriting OAS 3.1 forms to their 3.0 equivalents.
///
/// Fails on a `$ref` that points at nothing or on a cycle of references,
/// with the first problem found.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(spec) = oaspec.parse_file("openapi.yaml")
/// oaspec.resolve(spec)
/// // -> Ok(OpenApiSpec(..))
/// ```
///
/// ```gleam
/// // components.schemas.Pet is { $ref: '#/components/schemas/Missing' }
/// oaspec.resolve(spec)
/// // -> Error(Diagnostic(code: "resolve_error", ..))
/// ```
///
pub fn resolve(
  spec: OpenApiSpec(Unresolved),
) -> Result(OpenApiSpec(Resolved), Diagnostic) {
  parser.resolve_spec(spec)
}

/// Generates the Gleam modules for a document, without writing them.
///
/// `config` decides what is generated (`mode`, `include`,
/// `handler_layout`) and where each file goes. Its output directories are
/// checked against its `package` first, as the CLI does. Problems that do
/// not stop generation come back in `warnings`.
///
/// ## Examples
///
/// ```gleam
/// oaspec.generate(spec, cfg)
/// // -> Ok(Generated(files: [GeneratedFile(path: "./src/api/types.gleam", ..), ..], warnings: []))
/// ```
///
/// ```gleam
/// // The document has a requestBody type oaspec cannot generate.
/// oaspec.generate(spec, cfg)
/// // -> Error(InvalidSpec([Diagnostic(..)]))
/// ```
///
/// ```gleam
/// // cfg.package is "api" but cfg.output_server is "./src/server"
/// oaspec.generate(spec, cfg)
/// // -> Error(InvalidConfig(config.InvalidValue(field: "output.server", ..)))
/// ```
///
pub fn generate(
  from spec: OpenApiSpec(Unresolved),
  with config: Config,
) -> Result(Generated, GenerateError) {
  use _ <- result.try(check_config(config))
  use summary <- result.map(
    internal_generate.generate(spec, config)
    |> result.map_error(from_internal_generate_error),
  )
  let files =
    writer.place(summary.files, config)
    |> list.map(fn(entry) {
      let #(path, file) = entry
      GeneratedFile(
        path:,
        content: file.content,
        write_mode: case file.write_mode {
          context.Overwrite -> Overwrite
          context.SkipIfExists -> SkipIfExists
        },
      )
    })
  Generated(files:, warnings: summary.warnings)
}

/// Runs the same checks as `generate`, including the config checks,
/// without generating code, and returns the warnings.
///
/// ## Examples
///
/// ```gleam
/// oaspec.validate(spec, cfg)
/// // -> Ok([])
/// ```
///
/// ```gleam
/// oaspec.validate(spec, cfg)
/// // -> Error(InvalidSpec([Diagnostic(..)]))
/// ```
///
pub fn validate(
  from spec: OpenApiSpec(Unresolved),
  with config: Config,
) -> Result(List(Diagnostic), GenerateError) {
  use _ <- result.try(check_config(config))
  internal_generate.validate_only(spec, config)
  |> result.map(fn(summary) { summary.warnings })
  |> result.map_error(from_internal_generate_error)
}

/// Writes the generated files, creating directories as needed, and
/// returns the paths it wrote in order.
///
/// A `SkipIfExists` file that already exists is left alone and is not in
/// the returned list.
///
/// ## Examples
///
/// ```gleam
/// oaspec.write(generated)
/// // -> Ok(["./src/api/types.gleam", "./src/api/decode.gleam", ..])
/// ```
///
/// ```gleam
/// // ./src is read-only
/// oaspec.write(generated)
/// // -> Error(CannotCreateDirectory("./src/api", simplifile.Eacces))
/// ```
///
pub fn write(generated: Generated) -> Result(List(String), WriteError) {
  generated.files
  |> list.map(fn(file) {
    #(file.path, file.content, case file.write_mode {
      Overwrite -> context.Overwrite
      SkipIfExists -> context.SkipIfExists
    })
  })
  |> writer.write_placed
  |> result.map_error(fn(error) {
    case error {
      writer.CannotCreateDirectory(path:, reason:) ->
        CannotCreateDirectory(path:, reason:)
      writer.CannotWriteFile(path:, reason:) -> CannotWriteFile(path:, reason:)
    }
  })
}

fn check_config(config: Config) -> Result(Nil, GenerateError) {
  config_check.validate_output_package_match(config)
  |> result.try(fn(_) { config_check.validate_output_dir_layout(config) })
  |> result.map_error(InvalidConfig)
}

fn from_internal_generate_error(
  error: internal_generate.GenerateError,
) -> GenerateError {
  let internal_generate.ValidationErrors(errors:) = error
  InvalidSpec(errors:)
}
