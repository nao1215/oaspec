import gleeunit/should
import oaspec/internal/cli

pub fn normalize_argv_passthrough_empty_test() {
  cli.normalize_argv([])
  |> should.equal([])
}

pub fn normalize_argv_passthrough_subcommand_only_test() {
  cli.normalize_argv(["generate"])
  |> should.equal(["generate"])
}

pub fn normalize_argv_passthrough_equals_form_test() {
  cli.normalize_argv(["generate", "--config=oaspec.yaml"])
  |> should.equal(["generate", "--config=oaspec.yaml"])
}

pub fn normalize_argv_passthrough_bool_flag_test() {
  cli.normalize_argv(["generate", "--check"])
  |> should.equal(["generate", "--check"])
}

pub fn normalize_argv_joins_space_separated_config_test() {
  cli.normalize_argv(["generate", "--config", "oaspec.yaml"])
  |> should.equal(["generate", "--config=oaspec.yaml"])
}

pub fn normalize_argv_joins_space_separated_mode_test() {
  cli.normalize_argv(["generate", "--mode", "server"])
  |> should.equal(["generate", "--mode=server"])
}

pub fn normalize_argv_joins_space_separated_output_test() {
  cli.normalize_argv(["init", "--output", "./oaspec.yaml"])
  |> should.equal(["init", "--output=./oaspec.yaml"])
}

pub fn normalize_argv_joins_multiple_value_flags_test() {
  cli.normalize_argv([
    "generate", "--config", "oaspec.yaml", "--mode", "server", "--check",
  ])
  |> should.equal([
    "generate", "--config=oaspec.yaml", "--mode=server", "--check",
  ])
}

pub fn normalize_argv_preserves_dash_value_as_next_flag_test() {
  cli.normalize_argv(["generate", "--config", "--check"])
  |> should.equal(["generate", "--config", "--check"])
}

pub fn normalize_argv_does_not_join_unknown_flag_test() {
  cli.normalize_argv(["generate", "--unknown", "foo"])
  |> should.equal(["generate", "--unknown", "foo"])
}

pub fn normalize_argv_mixed_equals_and_space_test() {
  cli.normalize_argv(["validate", "--config=a.yaml", "--mode", "client"])
  |> should.equal(["validate", "--config=a.yaml", "--mode=client"])
}
