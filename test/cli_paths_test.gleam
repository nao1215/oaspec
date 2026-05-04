import gleeunit/should
import oaspec/config
import oaspec/internal/cli

pub fn resolve_path_from_cwd_expands_relative_paths_test() {
  cli.resolve_path_from_cwd("./specs/../openapi.yaml", "/work/project")
  |> should.equal("/work/project/openapi.yaml")
}

pub fn resolve_path_from_cwd_preserves_unix_absolute_paths_test() {
  cli.resolve_path_from_cwd("/tmp/oaspec.yaml", "/work/project")
  |> should.equal("/tmp/oaspec.yaml")
}

pub fn resolve_path_from_cwd_preserves_windows_drive_paths_test() {
  cli.resolve_path_from_cwd("C:/repo/oaspec.yaml", "/work/project")
  |> should.equal("C:/repo/oaspec.yaml")
}

pub fn resolved_path_entries_include_active_outputs_for_both_mode_test() {
  let cfg =
    config.new(
      input: "./openapi.yaml",
      output_server: "./gen/api",
      output_client: "./gen/api_client",
      package: "api",
      mode: config.Both,
      validate: True,
    )

  cli.resolved_path_entries("./oaspec.yaml", cfg, "/work/project")
  |> should.equal([
    #("config", "/work/project/oaspec.yaml"),
    #("input", "/work/project/openapi.yaml"),
    #("output.server", "/work/project/gen/api"),
    #("output.client", "/work/project/gen/api_client"),
  ])
}

pub fn resolved_path_entries_omit_inactive_output_for_client_mode_test() {
  let cfg =
    config.new(
      input: "./openapi.yaml",
      output_server: "./ignored/server",
      output_client: "./gen/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )

  cli.resolved_path_entries("./oaspec.yaml", cfg, "/work/project")
  |> should.equal([
    #("config", "/work/project/oaspec.yaml"),
    #("input", "/work/project/openapi.yaml"),
    #("output.client", "/work/project/gen/api"),
  ])
}
