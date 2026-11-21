//// The library entry points in the root `oaspec` module.

import gleam/list
import gleam/option.{None}
import gleam/string
import oaspec
import oaspec/config
import oaspec/openapi
import simplifile

const yaml_spec =
  "openapi: 3.0.3
info:
  title: Pets
  version: '1'
paths:
  /pets:
    get:
      operationId: listPets
      responses:
        '200':
          description: ok
"

const json_spec =
  "{\"openapi\": \"3.0.3\", \"info\": {\"title\": \"Pets\", \"version\": \"1\"}, \"paths\": {}}"

fn config_for(dir: String, mode: config.GenerateMode) -> config.Config {
  config.Config(
    input: "unused.yaml",
    output_server: dir <> "/api",
    output_client: dir <> "/api_client",
    package: "api",
    mode:,
    validate: True,
    include: config.Include(tags: [], paths: []),
    handler_layout: config.SingleFile,
  )
}

pub fn parse_string_reads_yaml_test() {
  let assert Ok(spec) = oaspec.parse_string(yaml_spec)
  assert spec.info.title == "Pets"
}

pub fn parse_string_reads_json_test() {
  let assert Ok(spec) = oaspec.parse_string(json_spec)
  assert spec.openapi == "3.0.3"
}

pub fn parse_string_reports_missing_field_test() {
  let assert Error(diagnostic) =
    oaspec.parse_string("openapi: 3.0.3\npaths: {}\n")
  assert diagnostic.code == "missing_field"
}

pub fn diagnostic_to_string_matches_documented_example_test() {
  let diagnostic =
    openapi.Diagnostic(
      code: "missing_field",
      phase: openapi.PhaseParse,
      severity: openapi.SeverityError,
      target: openapi.TargetBoth,
      pointer: "info",
      source_loc: openapi.SourceLoc(line: 3, column: 3),
      message: "Missing required field: title",
      hint: None,
    )
  assert openapi.diagnostic_to_string(diagnostic)
    == "[Parse] Error at info: Missing required field: title (line 3, column 3)"
}

pub fn parse_file_reports_unreadable_file_test() {
  let assert Error(diagnostic) = oaspec.parse_file("test/fixtures/no_such.yaml")
  assert diagnostic.code == "file_error"
}

pub fn resolve_rejects_dangling_ref_test() {
  let assert Ok(spec) =
    oaspec.parse_string(
      "openapi: 3.0.3
info: {title: Pets, version: '1'}
paths: {}
components:
  schemas:
    Pet:
      $ref: '#/components/schemas/Missing'
",
    )
  let assert Error(_) = oaspec.resolve(spec)
}

pub fn resolve_accepts_valid_spec_test() {
  let assert Ok(spec) = oaspec.parse_string(yaml_spec)
  let assert Ok(resolved) = oaspec.resolve(spec)
  assert resolved.info.title == "Pets"
}

pub fn generate_places_files_under_output_dirs_test() {
  let assert Ok(spec) = oaspec.parse_string(yaml_spec)
  let assert Ok(generated) =
    oaspec.generate(spec, config_for("./test_output/api_test", config.Both))
  let paths = list.map(generated.files, fn(file) { file.path })
  assert list.contains(paths, "./test_output/api_test/api/types.gleam")
  assert list.contains(paths, "./test_output/api_test/api_client/client.gleam")
  let assert Ok(handlers) =
    list.find(generated.files, fn(file) {
      string.ends_with(file.path, "/handlers.gleam")
    })
  assert handlers.write_mode == oaspec.SkipIfExists
}

pub fn validate_returns_warnings_test() {
  let assert Ok(spec) = oaspec.parse_string(yaml_spec)
  let assert Ok(warnings) =
    oaspec.validate(spec, config_for("./test_output/api_test", config.Client))
  assert warnings == []
}

pub fn write_writes_files_and_keeps_user_files_test() {
  let dir = "./test_output/api_write_test"
  let _ignored_delete = simplifile.delete(dir)
  let assert Ok(spec) = oaspec.parse_string(yaml_spec)
  let assert Ok(generated) =
    oaspec.generate(spec, config_for(dir, config.Server))
  let assert Ok(written) = oaspec.write(generated)
  assert list.length(written) == list.length(generated.files)
  let handlers = dir <> "/api/handlers.gleam"
  let assert Ok(Nil) = simplifile.write(handlers, "// mine\n")
  let assert Ok(rewritten) = oaspec.write(generated)
  assert !list.contains(rewritten, handlers)
  assert simplifile.read(handlers) == Ok("// mine\n")
  let _ignored_delete = simplifile.delete(dir)
}

pub fn parse_string_refuses_input_over_the_size_cap_test() {
  let content = "openapi: 3.0.3\n# " <> string.repeat("x", 16 * 1024 * 1024)
  let assert Error(diagnostic) = oaspec.parse_string(content)
  assert diagnostic.code == "parse_limit_exceeded"
}

pub fn parse_file_refuses_input_over_the_size_cap_test() {
  let path = "./test_output/api_limit_test.yaml"
  let assert Ok(Nil) = simplifile.create_directory_all("./test_output")
  let assert Ok(Nil) =
    simplifile.write(
      path,
      "openapi: 3.0.3\n# " <> string.repeat("x", 16 * 1024 * 1024),
    )
  let result = oaspec.parse_file(path)
  let _ignored_delete = simplifile.delete(path)
  let assert Error(diagnostic) = result
  assert diagnostic.code == "parse_limit_exceeded"
}

pub fn generate_rejects_output_dir_that_does_not_match_package_test() {
  let assert Ok(spec) = oaspec.parse_string(yaml_spec)
  let cfg =
    config.Config(
      ..config_for("./test_output/api_test", config.Server),
      output_server: "./test_output/api_test/server",
    )
  let assert Error(oaspec.InvalidConfig(config.InvalidValue(
    field: "output.server",
    ..,
  ))) = oaspec.generate(spec, cfg)
  let assert Error(oaspec.InvalidConfig(_)) = oaspec.validate(spec, cfg)
}

pub fn generate_rejects_misplaced_src_directory_test() {
  let assert Ok(spec) = oaspec.parse_string(yaml_spec)
  let cfg =
    config.Config(
      ..config_for("./test_output/api_test", config.Server),
      output_server: "./src/gen/api",
    )
  let assert Error(oaspec.InvalidConfig(config.InvalidValue(
    field: "output.server",
    ..,
  ))) = oaspec.generate(spec, cfg)
}
