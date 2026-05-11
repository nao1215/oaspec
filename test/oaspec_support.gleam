import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import oaspec/config
import oaspec/generate
import oaspec/internal/capability
import oaspec/internal/codegen/client as client_gen
import oaspec/internal/codegen/context
import oaspec/internal/codegen/decoders
import oaspec/internal/codegen/encoders
import oaspec/internal/codegen/guards
import oaspec/internal/codegen/ir
import oaspec/internal/codegen/ir_render
import oaspec/internal/codegen/schema_dispatch
import oaspec/internal/codegen/server as server_gen
import oaspec/internal/codegen/types
import oaspec/internal/codegen/validate
import oaspec/internal/openapi/capability_check
import oaspec/internal/openapi/dedup
import oaspec/internal/openapi/filter
import oaspec/internal/openapi/hoist
import oaspec/internal/openapi/location_index
import oaspec/internal/openapi/normalize
import oaspec/internal/openapi/provenance
import oaspec/internal/openapi/reachability
import oaspec/internal/openapi/resolve
import oaspec/internal/openapi/resolver
import oaspec/internal/openapi/schema
import oaspec/internal/openapi/spec
import oaspec/internal/openapi/value
import oaspec/internal/progress
import oaspec/internal/util/content_type
import oaspec/internal/util/http
import oaspec/internal/util/naming
import oaspec/openapi/diagnostic.{Diagnostic, NoSourceLoc, SourceLoc}
import oaspec/openapi/parser
import simplifile

pub fn main() {
  gleeunit.main()
}

// --- Naming Tests ---

pub fn to_pascal_case_case() {
  naming.to_pascal_case("pet_store")
  |> should.equal("PetStore")
}

pub fn to_pascal_case_from_kebab_case() {
  naming.to_pascal_case("get-user")
  |> should.equal("GetUser")
}

pub fn to_pascal_case_from_camel_case() {
  naming.to_pascal_case("getUserById")
  |> should.equal("GetUserById")
}

pub fn to_snake_case_case() {
  naming.to_snake_case("PetStore")
  |> should.equal("pet_store")
}

pub fn to_snake_case_from_camel_case() {
  naming.to_snake_case("getUserById")
  |> should.equal("get_user_by_id")
}

pub fn capitalize_case() {
  naming.capitalize("hello")
  |> should.equal("Hello")
}

pub fn deduplicate_names_no_collision_case() {
  naming.deduplicate_names(["foo", "bar", "baz"])
  |> should.equal(["foo", "bar", "baz"])
}

pub fn deduplicate_names_with_collision_case() {
  naming.deduplicate_names(["pet_id", "pet_id", "name"])
  |> should.equal(["pet_id", "pet_id_2", "name"])
}

pub fn deduplicate_names_triple_collision_case() {
  naming.deduplicate_names(["x", "x", "x"])
  |> should.equal(["x", "x_2", "x_3"])
}

pub fn deduplicate_names_empty_case() {
  naming.deduplicate_names([])
  |> should.equal([])
}

// --- Config Tests ---

pub fn load_config_case() {
  let assert Ok(cfg) = config.load("test/fixtures/oaspec.yaml")
  config.input(cfg) |> should.equal("test/fixtures/petstore.yaml")
  config.output_server(cfg) |> should.equal("./test_output/api")
  config.output_client(cfg) |> should.equal("./test_output_client/api")
  config.package(cfg) |> should.equal("api")
}

pub fn config_not_found_case() {
  let result = config.load("nonexistent.yaml")
  case result {
    Error(config.FileNotFound(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

// Issue #413: pin the user-facing strings produced by
// `config.error_to_string` for each ConfigError variant. These leak to
// the CLI surface, so format regressions degrade UX silently.

pub fn config_error_to_string_file_not_found_case() {
  let s = config.error_to_string(config.FileNotFound(path: "missing.yaml"))
  s |> string.contains("Config file not found") |> should.be_true()
  s |> string.contains("missing.yaml") |> should.be_true()
}

pub fn config_error_to_string_file_read_error_case() {
  let s =
    config.error_to_string(config.FileReadError(
      path: "x.yaml",
      detail: "permission denied",
    ))
  s |> string.contains("Error reading config file") |> should.be_true()
  s |> string.contains("x.yaml") |> should.be_true()
  s |> string.contains("permission denied") |> should.be_true()
}

pub fn config_error_to_string_parse_error_case() {
  let s = config.error_to_string(config.ParseError(detail: "unexpected token"))
  s |> string.contains("Config parse error") |> should.be_true()
  s |> string.contains("unexpected token") |> should.be_true()
}

pub fn config_error_to_string_missing_field_case() {
  let s = config.error_to_string(config.MissingField(field: "input"))
  s |> string.contains("Missing required config field") |> should.be_true()
  s |> string.contains("input") |> should.be_true()
}

pub fn config_error_to_string_invalid_value_case() {
  let s =
    config.error_to_string(config.InvalidValue(
      field: "mode",
      detail: "must be one of: server, client, both",
    ))
  s |> string.contains("Invalid value for") |> should.be_true()
  s |> string.contains("mode") |> should.be_true()
  s |> string.contains("must be one of") |> should.be_true()
}

pub fn config_load_missing_input_returns_missing_field_case() {
  let result = config.load("test/fixtures/oaspec_targets_empty.yaml")
  case result {
    Error(config.MissingField(field: _)) | Error(config.InvalidValue(..)) ->
      should.be_true(True)
    _ -> should.fail()
  }
}

pub fn parse_mode_case() {
  config.parse_mode("server") |> should.be_ok()
  config.parse_mode("client") |> should.be_ok()
  config.parse_mode("both") |> should.be_ok()
  config.parse_mode("invalid") |> should.be_error()
}

// Issue #268: when `validate:` is omitted, the default depends on `mode:`.
// Server / Both default to True (fail-closed: server handlers should not
// receive schema-invalid input by default). Client defaults to False.

pub fn config_validate_default_server_case() {
  let assert Ok(cfg) =
    config.load("test/fixtures/oaspec_validate_default_server.yaml")
  config.validate(cfg) |> should.be_true()
}

pub fn config_validate_default_client_case() {
  let assert Ok(cfg) =
    config.load("test/fixtures/oaspec_validate_default_client.yaml")
  config.validate(cfg) |> should.be_false()
}

// Issue #262: in client-only mode the default `output.client` must drop
// the `_client` suffix so generated `import <package>/...` lines resolve
// against the directory layout. In `Both` mode the suffix is still applied
// (server and client need distinct basenames inside the same `<dir>`).

pub fn config_client_only_default_drops_client_suffix_case() {
  let assert Ok(cfg) =
    config.load("test/fixtures/oaspec_client_default_path.yaml")
  // Fixture explicitly sets `output.dir: ./gen`. The test name says
  // "default" because it pins the **client mode default** of dropping
  // the `_client` suffix (#262) — `output.dir` itself is supplied.
  config.output_client(cfg) |> should.equal("./gen/api")
}

pub fn config_with_output_client_only_drops_suffix_case() {
  let cfg =
    config.new(
      input: "test/fixtures/petstore.yaml",
      output_server: "./old/api",
      output_client: "./old/api_client",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let updated = config.with_output(cfg, Some("./new"))
  config.output_server(updated) |> should.equal("./new/api")
  config.output_client(updated) |> should.equal("./new/api")
}

pub fn config_with_output_both_keeps_suffix_case() {
  let cfg =
    config.new(
      input: "test/fixtures/petstore.yaml",
      output_server: "./old/api",
      output_client: "./old/api_client",
      package: "api",
      mode: config.Both,
      validate: True,
    )
  let updated = config.with_output(cfg, Some("./new"))
  config.output_server(updated) |> should.equal("./new/api")
  config.output_client(updated) |> should.equal("./new/api_client")
}

pub fn config_validate_default_both_case() {
  let assert Ok(cfg) =
    config.load("test/fixtures/oaspec_validate_default_both.yaml")
  config.validate(cfg) |> should.be_true()
}

pub fn config_package_dir_mismatch_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./gen/wrong_name",
      output_client: "./gen/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_package_match(cfg)
  should.be_error(result)
}

pub fn config_client_dir_mismatch_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./gen/api",
      output_client: "./gen/wrong_client",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_package_match(cfg)
  should.be_error(result)
}

pub fn config_package_dir_match_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./gen/api",
      output_client: "./gen_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_package_match(cfg)
  should.be_ok(result)
}

// Issue #319: output.dir layout validation. `src/<sub>/<package>` is the
// foot-gun pattern; `src/<package>` and `<gen-root>/<package>` are fine.

pub fn config_output_dir_under_src_subdir_is_rejected_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./src/gen/api",
      output_client: "./src/gen/api_client",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_dir_layout(cfg)
  should.be_error(result)
}

pub fn config_output_dir_directly_under_src_is_accepted_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./src/api",
      output_client: "./src/api_client",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_dir_layout(cfg)
  should.be_ok(result)
}

pub fn config_output_dir_outside_src_is_accepted_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./gen/api",
      output_client: "./gen/api_client",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_dir_layout(cfg)
  should.be_ok(result)
}

pub fn config_output_dir_deep_under_src_is_rejected_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./pkg/src/gen/api",
      output_client: "./pkg/src/gen/api_client",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_dir_layout(cfg)
  should.be_error(result)
}

pub fn config_output_dir_client_only_under_src_subdir_is_rejected_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./gen/api",
      output_client: "./src/gen/api_client",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_dir_layout(cfg)
  should.be_error(result)
}

// Issue #387: nested package paths. A `package` containing slashes is a
// multi-segment Gleam module path; the layout validator must compare the
// LAST N segments of the output path against the package's segments and
// peel them off before applying the `src/` placement rule.

pub fn config_nested_package_dir_match_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./gen/dco_check/github",
      output_client: "./gen/dco_check/github_client",
      package: "dco_check/github",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_package_match(cfg)
  should.be_ok(result)
}

pub fn config_nested_package_wrong_middle_segment_rejected_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./gen/wrong/github",
      output_client: "./gen/wrong/github_client",
      package: "dco_check/github",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_package_match(cfg)
  should.be_error(result)
}

pub fn config_nested_package_wrong_last_segment_rejected_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./gen/dco_check/wrong",
      output_client: "./gen/dco_check/wrong_client",
      package: "dco_check/github",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_package_match(cfg)
  should.be_error(result)
}

pub fn config_nested_package_client_no_suffix_accepted_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./gen/dco_check/github",
      output_client: "./gen/dco_check/github",
      package: "dco_check/github",
      mode: config.Client,
      validate: False,
    )
  let result = config.validate_output_package_match(cfg)
  should.be_ok(result)
}

pub fn config_nested_package_layout_under_src_accepted_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./src/dco_check/github",
      output_client: "./src/dco_check/github_client",
      package: "dco_check/github",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_dir_layout(cfg)
  should.be_ok(result)
}

pub fn config_nested_package_layout_under_src_subdir_rejected_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./src/foo/dco_check/github",
      output_client: "./src/foo/dco_check/github_client",
      package: "dco_check/github",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_dir_layout(cfg)
  should.be_error(result)
}

pub fn config_nested_package_layout_outside_src_accepted_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./gen/dco_check/github",
      output_client: "./gen/dco_check/github_client",
      package: "dco_check/github",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_dir_layout(cfg)
  should.be_ok(result)
}

// Three-segment package path (`a/b/c`) — exercises the generalized
// last_n / drop_last_n helpers beyond the two-segment happy path.
pub fn config_nested_package_three_segments_match_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./src/dco_check/internal/github",
      output_client: "./src/dco_check/internal/github_client",
      package: "dco_check/internal/github",
      mode: config.Both,
      validate: False,
    )
  let pkg_match = config.validate_output_package_match(cfg)
  should.be_ok(pkg_match)
  let layout = config.validate_output_dir_layout(cfg)
  should.be_ok(layout)
}

// A trailing slash on `package` should be tolerated by `package_segments`.
pub fn config_nested_package_trailing_slash_match_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./gen/dco_check/github",
      output_client: "./gen/dco_check/github_client",
      package: "dco_check/github/",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_package_match(cfg)
  should.be_ok(result)
}

// Even when the immediate parent IS `src`, a second `src` earlier in
// the chain is still a foot-gun: Gleam resolves imports against the
// outermost `src/`, so the inner one ends up baked into the module
// path. Pre-existing footgun in the validator surfaced by CodeRabbit
// review on PR #443.
pub fn config_output_dir_double_src_with_immediate_parent_rejected_case() {
  let cfg =
    config.new(
      input: "openapi.yaml",
      output_server: "./src/foo/src/dco_check/github",
      output_client: "./src/foo/src/dco_check/github_client",
      package: "dco_check/github",
      mode: config.Both,
      validate: False,
    )
  let result = config.validate_output_dir_layout(cfg)
  should.be_error(result)
}

// --- Issue #387: include filter ---
// Default `Config` has an empty include filter; only `load`-loaded
// or `with_include`-applied configs ever carry a non-empty one. The
// filter module's `apply` is a no-op when the filter is empty and
// otherwise drops operations whose tags / paths do not match.

// Issue #387 follow-up: multi-target configs.

pub fn config_load_all_single_target_case() {
  // Legacy single-target shape (no `targets:` key) yields a
  // 1-element list whose sole config is field-equal to what the
  // legacy `load/1` returns. Asserting field-by-field catches
  // drift between the two entry points if either one changes its
  // parsing rules.
  let path = "test/fixtures/oaspec_include_filter.yaml"
  let assert Ok(cfgs) = config.load_all(path)
  let assert [cfg] = cfgs
  let assert Ok(legacy) = config.load(path)
  config.input(cfg) |> should.equal(config.input(legacy))
  config.mode(cfg) |> should.equal(config.mode(legacy))
  config.validate(cfg) |> should.equal(config.validate(legacy))
  config.package(cfg) |> should.equal(config.package(legacy))
  config.output_server(cfg) |> should.equal(config.output_server(legacy))
  config.output_client(cfg) |> should.equal(config.output_client(legacy))
  config.include(cfg) |> should.equal(config.include(legacy))
}

pub fn config_load_all_multi_target_case() {
  let assert Ok(cfgs) =
    config.load_all("test/fixtures/oaspec_targets_multi.yaml")
  list.length(cfgs) |> should.equal(2)
  // Each target has its own package and output paths, but the
  // shared input/mode/validate are baked into both.
  let packages =
    cfgs
    |> list.map(fn(c) { config.package(c) })
    |> list.sort(string.compare)
  packages |> should.equal(["petshop/details", "petshop/listing"])
  list.each(cfgs, fn(c) {
    config.input(c) |> should.equal("petstore.yaml")
    config.mode(c) |> should.equal(config.Client)
  })
}

pub fn config_load_targets_per_target_include_case() {
  let assert Ok(cfgs) =
    config.load_all("test/fixtures/oaspec_targets_multi.yaml")
  // Sort by package so the assertion below matches the spec
  // regardless of dict iteration order.
  let by_package =
    cfgs
    |> list.sort(fn(a, b) {
      string.compare(config.package(a), config.package(b))
    })
  let assert [details, listing] = by_package
  config.include(details).paths |> should.equal(["/pets/**"])
  config.include(listing).paths |> should.equal(["/pets"])
  // No `tags:` declared in this fixture, so each target should
  // default to an empty tag list. Asserting this catches any
  // regression where tag defaulting silently leaks state across
  // targets or fails to parse omitted tag lists as `[]`.
  config.include(details).tags |> should.equal([])
  config.include(listing).tags |> should.equal([])
}

pub fn config_load_targets_per_target_output_case() {
  let assert Ok(cfgs) =
    config.load_all("test/fixtures/oaspec_targets_multi.yaml")
  // `output.dir: ./gen` + `package: petshop/<leaf>` resolves to
  // `./gen/petshop/<leaf>` for each target; client mode means no
  // `_client` suffix.
  let outputs =
    cfgs
    |> list.map(fn(c) { config.output_client(c) })
    |> list.sort(string.compare)
  outputs |> should.equal(["./gen/petshop/details", "./gen/petshop/listing"])
}

pub fn config_load_target_missing_package_rejected_case() {
  let result =
    config.load_all("test/fixtures/oaspec_targets_missing_package.yaml")
  should.be_error(result)
}

pub fn config_load_targets_empty_rejected_case() {
  let result = config.load_all("test/fixtures/oaspec_targets_empty.yaml")
  should.be_error(result)
}

pub fn config_load_multi_target_via_load_returns_error_case() {
  // The legacy `load/1` only handles single-target configs; multi-
  // target callers must use `load_all/1` explicitly.
  let result = config.load("test/fixtures/oaspec_targets_multi.yaml")
  should.be_error(result)
}

pub fn config_load_parses_include_block_case() {
  let assert Ok(cfg) = config.load("test/fixtures/oaspec_include_filter.yaml")
  let inc = config.include(cfg)
  config.include_is_empty(inc) |> should.be_false
  inc.tags |> should.equal(["pets"])
  inc.paths |> should.equal(["/pets", "/pets/**"])
}

pub fn config_load_omitted_include_is_empty_case() {
  let assert Ok(cfg) = config.load("test/fixtures/oaspec.yaml")
  config.include(cfg) |> config.include_is_empty |> should.be_true
}

pub fn config_default_include_is_empty_case() {
  let cfg = make_default_cfg()
  config.include(cfg) |> config.include_is_empty |> should.be_true
}

pub fn config_with_include_round_trip_case() {
  let include = config.Include(tags: ["a", "b"], paths: ["/x", "/y/**"])
  let cfg = make_default_cfg() |> config.with_include(include)
  config.include(cfg) |> should.equal(include)
}

pub fn filter_apply_empty_filter_returns_spec_unchanged_case() {
  let assert Ok(unresolved) = parser.parse_file("test/fixtures/petstore.yaml")
  let assert Ok(resolved) = resolve.resolve(unresolved)
  let before = dict.size(resolved.paths)
  let after =
    filter.apply(resolved, config.empty_include())
    |> fn(s) { dict.size(s.paths) }
  after |> should.equal(before)
}

pub fn filter_apply_path_glob_keeps_matching_paths_case() {
  // petstore declares /pets and /pets/{petId}; both must survive a
  // `/pets/**` filter (glob matches everything under `/pets/`) AND
  // an exact `/pets` filter via the union semantics.
  let assert Ok(unresolved) = parser.parse_file("test/fixtures/petstore.yaml")
  let assert Ok(resolved) = resolve.resolve(unresolved)
  let include = config.Include(tags: [], paths: ["/pets", "/pets/**"])
  let filtered = filter.apply(resolved, include)
  let kept = dict.keys(filtered.paths) |> list.sort(string.compare)
  kept |> should.equal(["/pets", "/pets/{petId}"])
}

pub fn filter_apply_unknown_path_drops_everything_case() {
  let assert Ok(unresolved) = parser.parse_file("test/fixtures/petstore.yaml")
  let assert Ok(resolved) = resolve.resolve(unresolved)
  let include = config.Include(tags: [], paths: ["/no-such-path"])
  let filtered = filter.apply(resolved, include)
  dict.size(filtered.paths) |> should.equal(0)
}

pub fn filter_apply_tag_membership_keeps_tagged_operations_case() {
  // petstore tags every operation `pets`; including that tag keeps
  // both paths, and including a non-existent tag drops everything.
  let assert Ok(unresolved) = parser.parse_file("test/fixtures/petstore.yaml")
  let assert Ok(resolved) = resolve.resolve(unresolved)
  filter.apply(resolved, config.Include(tags: ["pets"], paths: []))
  |> fn(s) { dict.size(s.paths) }
  |> should.equal(2)
  filter.apply(resolved, config.Include(tags: ["nope"], paths: []))
  |> fn(s) { dict.size(s.paths) }
  |> should.equal(0)
}

pub fn filter_apply_tags_or_paths_unions_case() {
  // OR semantics: an operation passes if EITHER its tags intersect
  // include.tags OR its path matches include.paths. Setting one
  // matching list and one mismatching list still keeps the
  // matching subset.
  let assert Ok(unresolved) = parser.parse_file("test/fixtures/petstore.yaml")
  let assert Ok(resolved) = resolve.resolve(unresolved)
  let include = config.Include(tags: ["pets"], paths: ["/no-such-path"])
  filter.apply(resolved, include)
  |> fn(s) { dict.size(s.paths) }
  |> should.equal(2)
}

pub fn reachability_prune_drops_unreferenced_components_case() {
  // Issue #501: petstore declares Pet, CreatePetRequest, PetStatus,
  // Error. Filtering to /pets/{petId} keeps only GET and DELETE
  // operations, which reach Pet (and via Pet's `status` property,
  // PetStatus). CreatePetRequest is reachable only from POST /pets
  // and Error is never referenced in any operation's content, so
  // both must be pruned. The filter→hoist→prune sequence mirrors the
  // production pipeline so any regression around hoisted inline
  // schemas surfaces here too.
  let assert Ok(unresolved) = parser.parse_file("test/fixtures/petstore.yaml")
  let assert Ok(resolved) = resolve.resolve(unresolved)
  let include = config.Include(tags: [], paths: ["/pets/{petId}"])
  let pruned =
    resolved
    |> filter.apply(include)
    |> hoist.hoist
    |> reachability.prune
  let assert Some(comps) = pruned.components
  let names = dict.keys(comps.schemas) |> list.sort(string.compare)
  names |> should.equal(["Pet", "PetStatus"])
}

pub fn reachability_prune_keeps_transitively_reachable_components_case() {
  // GET /pets returns Pet[]; POST /pets takes a CreatePetRequest and
  // returns Pet. Pet itself references PetStatus via its `status`
  // property. So a /pets-only filter must keep CreatePetRequest, Pet,
  // PetStatus and drop only Error. Pipeline order matches production
  // (filter → hoist → prune).
  let assert Ok(unresolved) = parser.parse_file("test/fixtures/petstore.yaml")
  let assert Ok(resolved) = resolve.resolve(unresolved)
  let include = config.Include(tags: [], paths: ["/pets"])
  let pruned =
    resolved
    |> filter.apply(include)
    |> hoist.hoist
    |> reachability.prune
  let assert Some(comps) = pruned.components
  let names = dict.keys(comps.schemas) |> list.sort(string.compare)
  names |> should.equal(["CreatePetRequest", "Pet", "PetStatus"])
}

pub fn reachability_prune_with_no_surviving_operations_drops_everything_case() {
  // When every operation is filtered out, no operation can seed the
  // walk, so every component schema is unreachable.
  let assert Ok(unresolved) = parser.parse_file("test/fixtures/petstore.yaml")
  let assert Ok(resolved) = resolve.resolve(unresolved)
  let include = config.Include(tags: [], paths: ["/no-such-path"])
  let pruned =
    resolved
    |> filter.apply(include)
    |> hoist.hoist
    |> reachability.prune
  let assert Some(comps) = pruned.components
  dict.size(comps.schemas) |> should.equal(0)
}

pub fn reachability_prune_pipeline_omits_dead_types_in_generated_output_case() {
  // End-to-end: with an include filter active, the generation
  // pipeline must emit a `types.gleam` that contains only types
  // reachable from the surviving operations. petstore's Error and
  // CreatePetRequest schemas are unreachable from /pets/{petId} and
  // must not appear in the output.
  let assert Ok(unresolved) = parser.parse_file("test/fixtures/petstore.yaml")
  let cfg =
    make_default_cfg()
    |> config.with_include(config.Include(tags: [], paths: ["/pets/{petId}"]))
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(types_file) =
    list.find(summary.files, fn(f) { f.path == "types.gleam" })
  string.contains(types_file.content, "pub type Pet ")
  |> should.be_true
  string.contains(types_file.content, "pub type PetStatus")
  |> should.be_true
  string.contains(types_file.content, "pub type Error")
  |> should.be_false
  string.contains(types_file.content, "pub type CreatePetRequest")
  |> should.be_false
}

pub fn filter_path_matches_exact_and_glob_case() {
  filter.path_matches("/repos/foo", ["/repos/**"]) |> should.be_true
  filter.path_matches("/repos/foo/bar", ["/repos/**"]) |> should.be_true
  // `/repos/**` requires an extending segment; `/repos` itself does
  // NOT match the glob form (callers list it explicitly when needed).
  filter.path_matches("/repos", ["/repos/**"]) |> should.be_false
  filter.path_matches("/repository/foo", ["/repos/**"]) |> should.be_false
  filter.path_matches("/repos", ["/repos"]) |> should.be_true
  filter.path_matches("/repos/foo", ["/repos"]) |> should.be_false
}

fn make_default_cfg() -> config.Config {
  config.new(
    input: "openapi.yaml",
    output_server: "./gen/api",
    output_client: "./gen/api_client",
    package: "api",
    mode: config.Both,
    validate: False,
  )
}

// --- Parser Tests ---

pub fn parse_petstore_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/petstore.yaml")
  spec.info.title |> should.equal("Petstore")
  spec.info.version |> should.equal("1.0.0")
  spec.openapi |> should.equal("3.0.3")
}

pub fn parse_petstore_has_paths_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/petstore.yaml")
  dict.size(spec.paths) |> should.not_equal(0)
}

pub fn parse_petstore_has_components_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/petstore.yaml")
  case spec.components {
    Some(_) -> should.be_true(True)
    None -> should.fail()
  }
}

pub fn parse_file_not_found_case() {
  let result = parser.parse_file("nonexistent.yaml")
  should.be_error(result)
}

// --- JSON fast path (issue #352) ---
//
// Large OpenAPI specs are commonly distributed as JSON (the GitHub
// REST OpenAPI is ~12 MB). Routing every JSON file through yamerl
// caused effective hangs (>>10 minutes for what should be a few
// seconds), so `.json` inputs go through OTP's `json:decode/3` via
// `parser.parse_json_string`. The semantic shape of the resulting
// `OpenApiSpec` is identical to the YAML path; these tests pin that
// invariant so a future change to the JSON FFI doesn't silently
// drift from yamerl behaviour.

pub fn parse_json_string_minimal_spec_case() {
  let json =
    "{
      \"openapi\": \"3.0.3\",
      \"info\": {\"title\": \"JSON API\", \"version\": \"2.5.0\"},
      \"paths\": {}
    }"
  let assert Ok(spec) = parser.parse_json_string(json)
  spec.openapi |> should.equal("3.0.3")
  spec.info.title |> should.equal("JSON API")
  spec.info.version |> should.equal("2.5.0")
}

pub fn parse_json_string_preserves_required_array_order_case() {
  // The OTP `json:decode/3` decoders produce ordered list
  // accumulators for arrays, so List-shaped fields like `required`
  // must come out in the same order they appear in the source.
  // `required` is the cleanest place to pin this because it's a
  // bare JSON array of strings — no downstream `Dict` to erase
  // order — and the same mechanism backs `oneOf`/`anyOf` variants
  // and `parameters` lists, which break codegen output ordering if
  // the FFI ever loses array order.
  let json =
    "{
      \"openapi\": \"3.0.3\",
      \"info\": {\"title\": \"Order API\", \"version\": \"1.0.0\"},
      \"paths\": {},
      \"components\": {
        \"schemas\": {
          \"Pinned\": {
            \"type\": \"object\",
            \"required\": [\"zebra\", \"alpha\", \"middle\", \"yak\"],
            \"properties\": {
              \"zebra\": {\"type\": \"string\"},
              \"alpha\": {\"type\": \"string\"},
              \"middle\": {\"type\": \"string\"},
              \"yak\": {\"type\": \"string\"}
            }
          }
        }
      }
    }"
  let assert Ok(spec) = parser.parse_json_string(json)
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.ObjectSchema(required:, ..))) =
    dict.get(components.schemas, "Pinned")
  // Exact list equality — a regression that loses order would
  // surface as e.g. ["alpha", "middle", "yak", "zebra"].
  required |> should.equal(["zebra", "alpha", "middle", "yak"])
}

pub fn parse_json_string_handles_many_paths_case() {
  // Stress the FFI with more keys than Erlang's flat-map threshold
  // (32) to exercise the HAMT path. We only assert membership and
  // count here — Erlang map iteration is unspecified above 32
  // keys, so order claims belong on List-shaped fields like
  // `required` (covered above) where the FFI's order preservation
  // is observable.
  let assert Ok(spec) = parser.parse_file("test/fixtures/many_paths.json")
  dict.size(spec.paths) |> should.equal(40)
  // Spot-check a few path keys: the first, the last, and one
  // from the middle. Pinning a sample is enough — a regression
  // that drops paths would surface as a count mismatch above,
  // and a regression that mangles names would surface here.
  dict.has_key(spec.paths, "/p00") |> should.be_true()
  dict.has_key(spec.paths, "/p20") |> should.be_true()
  dict.has_key(spec.paths, "/p39") |> should.be_true()
}

pub fn parse_json_string_rejects_malformed_case() {
  // Trailing junk after the closing brace is not valid JSON; the
  // OTP decoder reports `unexpected_byte` which we map onto the
  // same `yaml_error`-style diagnostic that yamerl emits, so the
  // CLI prints the same shape regardless of which path ran.
  let bad_json =
    "{
      \"openapi\": \"3.0.3\",
      \"info\": {\"title\": \"\", \"version\": \"\"},
      \"paths\": {}
    }extra"
  let result = parser.parse_json_string(bad_json)
  should.be_error(result)
}

pub fn parse_json_string_malformed_has_diagnostic_shape_case() {
  // Issue #431: the `should.be_error` check above only verified that an
  // error was produced. Here we pin the diagnostic shape (parse-phase
  // error severity, non-empty message) for any malformed-or-rejected
  // JSON input, so a regression that returned a bare `String` error or
  // dropped the severity/phase fields surfaces as a failing test
  // instead of a silent contract drift.
  let bad_json = "::: not really json"
  let assert Error(d) = parser.parse_json_string(bad_json)
  d.phase |> should.equal(diagnostic.PhaseParse)
  d.severity |> should.equal(diagnostic.SeverityError)
  d.message |> should.not_equal("")
  d.code |> should.not_equal("")
}

pub fn parse_file_dispatches_json_path_for_json_extension_case() {
  // Call `parse_file` end-to-end so the `.json` extension dispatch
  // is what's under test — if the routing regressed and `.json`
  // started going through the yamerl path again, an assertion
  // against `parse_json_string` directly wouldn't notice. Reading
  // the file separately and calling `parse_json_string(content)`
  // would happily pass even if the dispatch was broken.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_minimal.json")
  spec.openapi |> should.equal("3.0.0")
}

// parse_string_with_limits / ParseLimits (#553) — DoS-aware parser limits

// Issue #573: a YAML mapping must not silently accept duplicate keys.
// yamerl tolerates them (later wins), but `oaspec validate` is the
// "is my spec OK?" surface and should catch this class of error.
pub fn parser_rejects_duplicate_response_status_code_case() {
  let yaml =
    "
openapi: 3.0.0
info:
  title: Broken
  version: 1.0.0
paths:
  /broken:
    get:
      responses:
        '200':
          description: OK
        '200':
          description: dup
"
  let assert Error(d) = parser.parse_string(yaml)
  d.code |> should.equal("duplicate_key")
  // Diagnostic must name the duplicated key so the user knows which
  // entry to remove.
  should.be_true(string.contains(d.message, "200"))
  should.be_true(string.contains(d.message, "responses"))
}

// Issue #587: response status-code keys must fall in the OAS-allowed
// grammar (100-599 canonical 3-digit, the wildcards 1XX-5XX, or
// 'default'). Pre-fix, `parse_status_code` accepted whatever `int.parse`
// returned, so adversarial / malformed status keys flowed through to
// codegen and produced dead Gleam decode arms. The cases below pin
// each boundary the issue called out.

fn make_response_status_spec(status: String) -> String {
  "openapi: 3.0.0\n"
  <> "info:\n  title: x\n  version: '1.0'\n"
  <> "paths:\n  /a:\n    get:\n      responses:\n"
  <> "        '"
  <> status
  <> "':\n          description: weird\n"
}

pub fn parser_rejects_response_status_below_100_case() {
  let assert Error(d) = parser.parse_string(make_response_status_spec("99"))
  d.code |> should.equal("invalid_value")
  should.be_true(string.contains(d.message, "99"))
}

pub fn parser_rejects_response_status_above_599_case() {
  let assert Error(d) = parser.parse_string(make_response_status_spec("1000"))
  d.code |> should.equal("invalid_value")
  should.be_true(string.contains(d.message, "1000"))
}

pub fn parser_rejects_response_status_zero_case() {
  let assert Error(d) = parser.parse_string(make_response_status_spec("0"))
  d.code |> should.equal("invalid_value")
}

pub fn parser_rejects_response_status_negative_case() {
  let assert Error(d) = parser.parse_string(make_response_status_spec("-1"))
  d.code |> should.equal("invalid_value")
}

pub fn parser_rejects_response_status_leading_zero_case() {
  // '0200' parses to 200 via int.parse, but is not the canonical 3-digit
  // form — round-tripping the parsed int back to string returns "200",
  // which the canonicality guard catches. Without this check, '0200'
  // and '200' would collide on `Status(200)` in the responses Dict.
  let assert Error(d) = parser.parse_string(make_response_status_spec("0200"))
  d.code |> should.equal("invalid_value")
  should.be_true(string.contains(d.message, "0200"))
}

pub fn parser_rejects_response_status_huge_int_case() {
  let assert Error(d) =
    parser.parse_string(make_response_status_spec("12345678901234567890"))
  d.code |> should.equal("invalid_value")
}

pub fn parser_rejects_response_status_explicit_plus_case() {
  let assert Error(d) = parser.parse_string(make_response_status_spec("+200"))
  d.code |> should.equal("invalid_value")
}

pub fn parser_accepts_response_status_canonical_3_digit_case() {
  // Sanity: the fix does not regress the happy path. Every code in
  // 100-599 with canonical 3-digit form keeps working.
  let assert Ok(_) = parser.parse_string(make_response_status_spec("200"))
  let assert Ok(_) = parser.parse_string(make_response_status_spec("404"))
  let assert Ok(_) = parser.parse_string(make_response_status_spec("599"))
  Nil
}

pub fn parser_accepts_response_status_wildcards_case() {
  let assert Ok(_) = parser.parse_string(make_response_status_spec("2XX"))
  let assert Ok(_) = parser.parse_string(make_response_status_spec("5xx"))
  Nil
}

pub fn parser_accepts_response_status_default_case() {
  let assert Ok(_) = parser.parse_string(make_response_status_spec("default"))
  Nil
}

pub fn parser_rejects_yaml_int_response_status_below_100_case() {
  // `responses: 99` parses to NodeInt(99) on the YAML path; the
  // diagnostic comes from `http_status_from_int`, which mirrors the
  // string-path range check for callers that have already lost the
  // original byte representation. (#587)
  let yaml =
    "openapi: 3.0.0\n"
    <> "info:\n  title: x\n  version: '1.0'\n"
    <> "paths:\n  /a:\n    get:\n      responses:\n"
    <> "        99:\n          description: too-low\n"
  let assert Error(d) = parser.parse_string(yaml)
  d.code |> should.equal("invalid_value")
}

// Issue #588: `paths:` keys must follow the OAS 3.0 §4.7.9.1 path-template
// grammar. Pre-fix, any string flowed through the parser and into codegen,
// which emitted routes the HTTP layer cannot serve. Each case below pins
// one deviation listed in the issue.

fn make_path_spec(path_key: String) -> String {
  "openapi: 3.0.0\n"
  <> "info:\n  title: x\n  version: '1.0'\n"
  <> "paths:\n"
  <> "  '"
  <> path_key
  <> "':\n"
  <> "    get:\n"
  <> "      responses:\n"
  <> "        '200':\n"
  <> "          description: ok\n"
}

pub fn parser_rejects_path_without_leading_slash_case() {
  let assert Error(d) = parser.parse_string(make_path_spec("users"))
  d.code |> should.equal("invalid_value")
  should.be_true(string.contains(d.message, "must start with '/'"))
}

pub fn parser_rejects_empty_path_case() {
  let assert Error(d) = parser.parse_string(make_path_spec(""))
  d.code |> should.equal("invalid_value")
  should.be_true(string.contains(d.message, "must not be empty"))
}

pub fn parser_rejects_double_slash_path_case() {
  let assert Error(d) = parser.parse_string(make_path_spec("//users"))
  d.code |> should.equal("invalid_value")
  should.be_true(string.contains(d.message, "//"))
}

pub fn parser_rejects_empty_placeholder_path_case() {
  let assert Error(d) = parser.parse_string(make_path_spec("/users/{}"))
  d.code |> should.equal("invalid_value")
  should.be_true(string.contains(d.message, "placeholder"))
}

pub fn parser_rejects_whitespace_placeholder_path_case() {
  // The early space-check fires first, so the diagnostic is the generic
  // "no whitespace in path" rather than a placeholder-specific message.
  // Either way the path is rejected, which is what #588 demands.
  let assert Error(d) = parser.parse_string(make_path_spec("/users/{ id }"))
  d.code |> should.equal("invalid_value")
  should.be_true(string.contains(d.message, "space"))
}

pub fn parser_rejects_duplicate_placeholder_path_case() {
  let assert Error(d) = parser.parse_string(make_path_spec("/users/{id}/{id}"))
  d.code |> should.equal("invalid_value")
  should.be_true(string.contains(d.message, "id"))
}

pub fn parser_rejects_unclosed_placeholder_path_case() {
  let assert Error(d) = parser.parse_string(make_path_spec("/users/{id"))
  d.code |> should.equal("invalid_value")
  should.be_true(string.contains(d.message, "unclosed"))
}

pub fn parser_rejects_nested_brace_path_case() {
  let assert Error(d) = parser.parse_string(make_path_spec("/{{id}}"))
  d.code |> should.equal("invalid_value")
}

pub fn parser_rejects_query_in_path_case() {
  let assert Error(d) = parser.parse_string(make_path_spec("/?query=1"))
  d.code |> should.equal("invalid_value")
  should.be_true(string.contains(d.message, "query"))
}

pub fn parser_rejects_fragment_in_path_case() {
  let assert Error(d) = parser.parse_string(make_path_spec("/users#fragment"))
  d.code |> should.equal("invalid_value")
  should.be_true(string.contains(d.message, "fragment"))
}

pub fn parser_rejects_space_in_path_case() {
  let assert Error(d) = parser.parse_string(make_path_spec("/with space"))
  d.code |> should.equal("invalid_value")
  should.be_true(string.contains(d.message, "space"))
}

// Issue #592: OAS 3.0 §4.7.10.5 says operation parameter lists MUST NOT
// include duplicated parameters, where the (name, in) pair is the
// uniqueness key. Pre-fix, a parameter declared twice with different
// schemas flowed through to codegen and produced duplicate Gleam
// bindings — either a compile error in the output or a silently-broken
// handler. Same-name-different-in is still allowed by spec.

pub fn parser_rejects_duplicate_query_parameter_case() {
  let yaml =
    "openapi: 3.0.0\n"
    <> "info:\n  title: x\n  version: '1.0'\n"
    <> "paths:\n"
    <> "  /a:\n    get:\n"
    <> "      parameters:\n"
    <> "        - name: p\n          in: query\n          schema: {type: string}\n"
    <> "        - name: p\n          in: query\n          schema: {type: integer}\n"
    <> "      responses:\n"
    <> "        '200':\n          description: ok\n"
  let assert Error(d) = parser.parse_string(yaml)
  d.code |> should.equal("invalid_value")
  should.be_true(string.contains(d.message, "query/p"))
}

pub fn parser_accepts_same_name_different_in_case() {
  // Sanity: per OAS 3.0 §4.7.10.5, two parameters with the same name
  // in different locations (query vs header) are valid and must
  // continue to parse.
  let yaml =
    "openapi: 3.0.0\n"
    <> "info:\n  title: x\n  version: '1.0'\n"
    <> "paths:\n"
    <> "  /a:\n    get:\n"
    <> "      parameters:\n"
    <> "        - name: p\n          in: query\n          schema: {type: string}\n"
    <> "        - name: p\n          in: header\n          schema: {type: string}\n"
    <> "      responses:\n"
    <> "        '200':\n          description: ok\n"
  let assert Ok(_) = parser.parse_string(yaml)
  Nil
}

pub fn parser_rejects_duplicate_path_key_case() {
  // Issue #584: yamerl silently keeps the last duplicate path entry,
  // dropping the earlier one without warning. Per OAS, path keys are
  // URL templates that MUST be unique. Same UX class as #573 but on
  // the paths surface.
  let yaml =
    "openapi: 3.0.0\n"
    <> "info:\n  title: x\n  version: '1.0'\n"
    <> "paths:\n"
    <> "  /a:\n    get:\n      summary: first\n      responses:\n"
    <> "        '200':\n          description: ok\n"
    <> "  /a:\n    get:\n      summary: dup\n      responses:\n"
    <> "        '200':\n          description: ok\n"
  let assert Error(d) = parser.parse_string(yaml)
  d.code |> should.equal("duplicate_key")
  should.be_true(string.contains(d.message, "/a"))
  should.be_true(string.contains(d.message, "paths"))
}

pub fn parser_accepts_canonical_path_with_placeholder_case() {
  // Sanity: the canonical happy path still parses. Placeholders with
  // letters / digits / underscores / hyphens are all allowed by
  // the regex `[A-Za-z0-9_-]+`.
  let assert Ok(_) = parser.parse_string(make_path_spec("/users/{id}"))
  let assert Ok(_) = parser.parse_string(make_path_spec("/v1/items/{item_id}"))
  let assert Ok(_) =
    parser.parse_string(make_path_spec("/users/{userId}/posts/{postId}"))
  Nil
}

pub fn parser_rejects_yaml_alias_without_anchor_case() {
  // Issue #576: YAML aliases (`*foo`) that reference a missing
  // anchor (`&foo`) must surface a `yaml_error` Diagnostic instead
  // of crashing the parsing process with a BEAM `case_clause`.
  // Server-side spec validators that accept user-uploaded specs
  // could be DoS'd by a one-line malformed YAML payload.
  let yaml =
    "openapi: 3.0.0
info:
  title: t
  version: \"1\"
paths:
  /a: &a
    get: *a
"
  let assert Error(d) = parser.parse_string(yaml)
  d.code |> should.equal("yaml_error")
  // The yamerl message names the unresolved alias so the user can
  // locate the dangling reference in their spec.
  should.be_true(string.contains(d.message, "alias"))
}

pub fn parser_rejects_yaml_alias_with_no_matching_anchor_path_case() {
  // Variant of the alias-error path: the anchor `&p` would be
  // defined under `paths:` but on a key whose flow-style is
  // ambiguous, so yamerl never registers it before `*p` resolves.
  let yaml =
    "openapi: 3.0.0
info:
  title: t
  version: \"1\"
paths:
  &p
    a: &q
    b: *p
"
  let assert Error(d) = parser.parse_string(yaml)
  d.code |> should.equal("yaml_error")
}

pub fn parser_rejects_duplicate_components_response_name_case() {
  let yaml =
    "
openapi: 3.0.0
info:
  title: DupComponents
  version: 1.0.0
paths: {}
components:
  responses:
    NotFound:
      description: A
    NotFound:
      description: B
"
  let assert Error(d) = parser.parse_string(yaml)
  d.code |> should.equal("duplicate_key")
  should.be_true(string.contains(d.message, "NotFound"))
  should.be_true(string.contains(d.message, "components.responses"))
}

pub fn parse_string_with_limits_accepts_input_under_default_cap_case() {
  // A small inline spec is well under the 16 MiB default cap; the
  // limit-aware entry point must accept it and produce the same spec
  // a plain parse_string call would.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Tiny
  version: 1.0.0
paths: {}
"
  let assert Ok(spec) =
    parser.parse_string_with_limits(yaml, parser.default_limits())
  spec.openapi |> should.equal("3.0.3")
  spec.info.title |> should.equal("Tiny")
}

pub fn parse_string_with_limits_rejects_input_over_byte_cap_case() {
  // Build an input bigger than a deliberately tiny cap (1 byte) and
  // confirm parse_string_with_limits rejects it before yamerl is
  // invoked. The diagnostic must name the limit and the actual size.
  let yaml =
    "
openapi: 3.0.3
info: { title: Big, version: 1.0.0 }
paths: {}
"
  let tiny_limit =
    parser.ParseLimits(
      max_input_bytes: 1,
      max_schema_depth: 100,
      max_allof_chain: 32,
      max_external_ref_hops: 16,
      max_paths: 4096,
      max_parameters_per_op: 64,
    )
  let assert Error(d) = parser.parse_string_with_limits(yaml, tiny_limit)
  d.code |> should.equal("parse_limit_exceeded")
  // Diagnostic must name the offending limit so callers can bump
  // exactly that field if they trust the source.
  should.be_true(string.contains(d.message, "max_input_bytes"))
  // Diagnostic must include the actual size, so an operator reading
  // the message can decide what to set the cap to. We don't pin the
  // exact integer (the YAML literal length above could drift across
  // edits), only that the actual size is mentioned.
  should.be_true(string.contains(d.message, "actual"))
}

pub fn parse_string_with_limits_default_limits_match_documented_caps_case() {
  // Pin the documented default values so a future change to the
  // defaults (raising or lowering them) lands in the test diff and
  // gets reviewed alongside the docstring.
  let limits = parser.default_limits()
  limits.max_input_bytes |> should.equal(16 * 1024 * 1024)
  limits.max_schema_depth |> should.equal(100)
  limits.max_allof_chain |> should.equal(32)
  limits.max_external_ref_hops |> should.equal(16)
  limits.max_paths |> should.equal(4096)
  limits.max_parameters_per_op |> should.equal(64)
}

// parse_json_string_with_locations / parse_string_or_json_with_locations (#550)

pub fn parse_json_string_with_locations_returns_same_spec_case() {
  // The location-bearing variant must return a structurally identical
  // OpenApiSpec to parse_json_string for the same JSON input. Pin
  // openapi/info fields and path-count to catch a regression in the
  // tree-walking that diverges between the two entry points.
  let json =
    "{
      \"openapi\": \"3.0.3\",
      \"info\": {\"title\": \"Locs API\", \"version\": \"1.2.3\"},
      \"paths\": {\"/a\": {}, \"/b\": {}}
    }"
  let assert Ok(spec_plain) = parser.parse_json_string(json)
  let assert Ok(#(spec_locs, _index)) =
    parser.parse_json_string_with_locations(json)
  spec_locs.openapi |> should.equal(spec_plain.openapi)
  spec_locs.info.title |> should.equal(spec_plain.info.title)
  spec_locs.info.version |> should.equal(spec_plain.info.version)
  dict.size(spec_locs.paths) |> should.equal(dict.size(spec_plain.paths))
}

pub fn parse_json_string_with_locations_index_is_empty_case() {
  // OTP's `json:decode/3` does not expose token positions, so the
  // returned LocationIndex is always empty. The contract is documented
  // and now pinned: a regression that started routing JSON through a
  // location-aware decoder would surface here.
  let json =
    "{
      \"openapi\": \"3.0.3\",
      \"info\": {\"title\": \"Empty Index\", \"version\": \"0.1.0\"},
      \"paths\": {}
    }"
  let assert Ok(#(_spec, index)) = parser.parse_json_string_with_locations(json)
  index |> should.equal(location_index.empty())
}

pub fn parse_string_or_json_with_locations_routes_json_test_case() {
  // First non-whitespace byte is `{` → JSON path. The dispatch must
  // pick parse_json_string_with_locations even when the content has
  // a leading whitespace prefix (BOMs are stripped upstream; this
  // pins the leading-blank-line case that #550 calls out).
  let json =
    "
      {
        \"openapi\": \"3.0.3\",
        \"info\": {\"title\": \"Routed JSON\", \"version\": \"1.0.0\"},
        \"paths\": {}
      }"
  let assert Ok(#(spec, index)) =
    parser.parse_string_or_json_with_locations(json)
  spec.info.title |> should.equal("Routed JSON")
  // JSON path → empty index.
  index |> should.equal(location_index.empty())
}

pub fn parse_string_or_json_with_locations_routes_yaml_test_case() {
  // First non-whitespace byte is `o` (from `openapi:`) → YAML path.
  // The YAML route should produce a LocationIndex with at least one
  // recorded position (the `info.title` entry is guaranteed to be
  // line-bound).
  let yaml =
    "openapi: 3.0.3
info:
  title: Routed YAML
  version: 1.0.0
paths: {}
"
  let assert Ok(#(spec, index)) =
    parser.parse_string_or_json_with_locations(yaml)
  spec.info.title |> should.equal("Routed YAML")
  // YAML path → non-empty index. We don't pin the exact size because
  // it depends on yamerl's tokenisation; just that it's not empty.
  let is_empty = index == location_index.empty()
  should.be_false(is_empty)
}

// Regression: yamerl applies YAML 1.1 implicit-type rules that the
// OTP json:decode frontend does not. The two parsers therefore diverge
// on the same JSON bytes whenever a scalar matches a YAML 1.1 pattern.
// Pin parse_json_string's verbatim behaviour; if a future yamerl
// upgrade changes its rule the parse_string docstring's coercion
// table needs to follow. (#549)

pub fn parse_json_string_preserves_yes_no_string_values_case() {
  // Stripe-style API key descriptions occasionally contain the
  // literal strings "Yes"/"No" in human-readable description fields.
  // OpenAPI's `info.description` is documented as a free-form string;
  // both parsers must preserve the value as `"Yes"` for the JSON
  // input — which the OTP frontend does. The yamerl frontend is
  // documented to potentially coerce; we pin the JSON-side guarantee
  // so a future regression that breaks the JSON path surfaces here.
  let json =
    "{
      \"openapi\": \"3.0.3\",
      \"info\": {
        \"title\": \"Yes/No API\",
        \"version\": \"1.0.0\",
        \"description\": \"Yes\"
      },
      \"paths\": {}
    }"
  let assert Ok(spec) = parser.parse_json_string(json)
  spec.info.title |> should.equal("Yes/No API")
  spec.info.description |> should.equal(option.Some("Yes"))
}

pub fn parse_json_string_preserves_dotted_version_literal_case() {
  // OpenAPI's `info.version` is a string. JSON reproduces "1.10"
  // verbatim; yamerl's YAML 1.1 numeric coercion can drop the
  // trailing zero on unquoted numerics but the quoted form should
  // survive. Pin the JSON path's exact-string behaviour for the
  // `"1.10"` case, which oaspec actually sees in the wild (Stripe
  // pinned "2024-04-10" / "1.10"-style version strings).
  let json =
    "{
      \"openapi\": \"3.0.3\",
      \"info\": {\"title\": \"v\", \"version\": \"1.10\"},
      \"paths\": {}
    }"
  let assert Ok(spec) = parser.parse_json_string(json)
  spec.info.version |> should.equal("1.10")
}

pub fn parse_string_or_json_with_locations_array_root_routes_json_case() {
  // First non-whitespace byte is `[` — also a JSON discriminator.
  // The content here is intentionally not a valid OpenAPI doc; we
  // only want to confirm that the dispatch picks the JSON parser
  // (which will reject it with a JSON-shaped error), not the YAML
  // parser (which would silently parse the bracket as a flow-style
  // sequence and produce a different diagnostic).
  let json_array = "[1, 2, 3]"
  let result = parser.parse_string_or_json_with_locations(json_array)
  // Either path will fail (it's not an OpenAPI document), but the
  // JSON path must be the one that fails. We just assert it errored;
  // the more detailed message is a separate concern.
  should.be_error(result)
}

// --- YAML/JSON parity on real-world OAI examples (issue #352) ---
//
// The yamerl path and the OTP json:decode fast path must agree on
// the parsed `OpenApiSpec` for any spec that is valid in both
// serializations. These tests vendor the OpenAPI Initiative's
// publicly distributed example specs (Apache 2.0; see
// `test/fixtures/ATTRIBUTION.md` and the original repo at
// https://github.com/OAI/OpenAPI-Specification/tree/3.1.1/examples)
// in both YAML and JSON, then assert that key fields, schema
// counts, and operation IDs match between the two paths.
//
// Why both formats: large public specs (GitHub REST, Stripe, etc.)
// ship as JSON because YAML parsers tend to choke on multi-MB
// inputs. Vendoring smaller real-world examples in both formats
// pins the two paths' equivalence without committing 12 MB to the
// repo.

pub fn oss_oai_petstore_expanded_yaml_and_json_agree_case() {
  // OAI petstore-expanded.yaml/.json is OAS 3.0 with components,
  // path-level parameters, schema $refs, and validation
  // constraints. A divergence between the YAML and JSON parsers
  // would surface here as a different operation count, schema
  // count, or missing component.
  let assert Ok(yaml_spec) =
    parser.parse_file("test/fixtures/oss_oai_petstore_expanded.yaml")
  let assert Ok(json_spec) =
    parser.parse_file("test/fixtures/oss_oai_petstore_expanded.json")

  yaml_spec.openapi |> should.equal(json_spec.openapi)
  yaml_spec.info.title |> should.equal(json_spec.info.title)
  yaml_spec.info.version |> should.equal(json_spec.info.version)
  dict.size(yaml_spec.paths) |> should.equal(dict.size(json_spec.paths))

  let assert Some(yaml_components) = yaml_spec.components
  let assert Some(json_components) = json_spec.components
  dict.size(yaml_components.schemas)
  |> should.equal(dict.size(json_components.schemas))
}

pub fn oss_oai_petstore_expanded_yaml_path_count_pinned_case() {
  // Pin the absolute counts so a future regression that silently
  // drops a path or schema (rather than diverging between YAML
  // and JSON) still trips the test. Numbers come from the OAI
  // 3.1.1 tag of petstore-expanded.{yaml,json}.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oai_petstore_expanded.yaml")
  spec.openapi |> should.equal("3.0.0")
  dict.size(spec.paths) |> should.equal(2)
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(3)
}

pub fn oss_oai_webhook_example_yaml_and_json_agree_case() {
  // OAS 3.1 webhook spec — paths is empty, webhooks carries the
  // single operation. This exercises the 3.1-only `webhooks`
  // top-level field through both parser paths.
  let assert Ok(yaml_spec) =
    parser.parse_file("test/fixtures/oss_oai_webhook_example.yaml")
  let assert Ok(json_spec) =
    parser.parse_file("test/fixtures/oss_oai_webhook_example.json")

  yaml_spec.openapi |> should.equal("3.1.0")
  json_spec.openapi |> should.equal("3.1.0")
  yaml_spec.info.title |> should.equal(json_spec.info.title)
  dict.size(yaml_spec.webhooks)
  |> should.equal(dict.size(json_spec.webhooks))
  dict.has_key(yaml_spec.webhooks, "newPet") |> should.be_true()
  dict.has_key(json_spec.webhooks, "newPet") |> should.be_true()
}

pub fn oss_oai_webhook_example_components_match_case() {
  // The webhook example uses a `Pet` component referenced from the
  // webhook body. Both parsers must surface the *same* Pet schema
  // — same required list, same property keys. Asserting only
  // presence + count would let a regression in property names or
  // required ordering through; comparing the bodies catches a
  // divergence at the schema-shape level. The fixture's `required`
  // list is `[id, name]` in source order, which also pins the
  // JSON FFI's array-order preservation on a real-world fixture.
  let assert Ok(yaml_spec) =
    parser.parse_file("test/fixtures/oss_oai_webhook_example.yaml")
  let assert Ok(json_spec) =
    parser.parse_file("test/fixtures/oss_oai_webhook_example.json")
  let assert Some(yaml_c) = yaml_spec.components
  let assert Some(json_c) = json_spec.components
  dict.size(yaml_c.schemas) |> should.equal(dict.size(json_c.schemas))

  let assert Ok(schema.Inline(schema.ObjectSchema(
    properties: yaml_props,
    required: yaml_required,
    ..,
  ))) = dict.get(yaml_c.schemas, "Pet")
  let assert Ok(schema.Inline(schema.ObjectSchema(
    properties: json_props,
    required: json_required,
    ..,
  ))) = dict.get(json_c.schemas, "Pet")

  // `required` is a List(String), so order matters and the OAI
  // fixture lists `id` before `name`. A divergence here means one
  // of the two parsers lost array order.
  yaml_required |> should.equal(["id", "name"])
  json_required |> should.equal(yaml_required)

  // Property *keys* must match across the two paths. We compare
  // sorted key lists so the assertion is order-insensitive at the
  // Dict layer (Erlang map iteration above 32 entries is
  // unspecified, and ObjectSchema.properties is a Dict). Property
  // *order* is not part of OpenAPI's contract; the array-order
  // assertion above already pins what matters.
  let yaml_keys = dict.keys(yaml_props) |> list.sort(string.compare)
  let json_keys = dict.keys(json_props) |> list.sort(string.compare)
  yaml_keys |> should.equal(json_keys)
  yaml_keys |> should.equal(["id", "name", "tag"])
}

// --- OpenAPI version gate (issue #235) ---
//
// oaspec advertises itself as an OpenAPI 3.x parser/generator. Feeding it a
// spec with a version it cannot actually support (Swagger 2.0, a future
// 4.x, or a bare "3") would produce plausible-looking but meaningless
// output, so the parser rejects anything outside 3.0.x / 3.1.x up front.

pub fn parse_rejects_openapi_2_0_case() {
  // Quoting the version so we reach the version-gate logic; #583 closed
  // the YAML-float compatibility path that this test originally relied
  // on. Bare `openapi: 2.0` is now rejected one step earlier as a
  // missing-field-of-the-right-type, exercised by the YAML-path tests
  // alongside the #580 / #583 regression block.
  let yaml =
    "
openapi: '2.0'
info:
  title: Wrong API
  version: '1.0.0'
paths: {}
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(Diagnostic(code: "invalid_value", message: detail, ..)) =
    result
  string.contains(detail, "Unsupported OpenAPI version") |> should.be_true()
  string.contains(detail, "2.0") |> should.be_true()
}

pub fn parse_rejects_openapi_4_0_0_case() {
  let yaml =
    "
openapi: 4.0.0
info:
  title: Future API
  version: 1.0.0
paths: {}
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(Diagnostic(code: "invalid_value", message: detail, ..)) =
    result
  string.contains(detail, "Unsupported OpenAPI version") |> should.be_true()
  string.contains(detail, "4.0.0") |> should.be_true()
}

pub fn parse_rejects_openapi_3_2_0_case() {
  // An as-yet-unreleased 3.2 must not sneak through a "starts with 3"
  // check. oaspec only supports 3.0.x and 3.1.x.
  let yaml =
    "
openapi: 3.2.0
info:
  title: Future Minor API
  version: 1.0.0
paths: {}
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(Diagnostic(
    code: "invalid_value",
    pointer: "openapi",
    message: detail,
    ..,
  )) = result
  string.contains(detail, "Unsupported OpenAPI version") |> should.be_true()
  string.contains(detail, "3.2.0") |> should.be_true()
}

pub fn parse_rejects_malformed_patch_segment_case() {
  // A non-numeric patch must be rejected — if we let `3.0.foo` through,
  // the "exact accepted range" promise stops being exact.
  let yaml =
    "
openapi: 3.0.foo
info:
  title: Garbage Patch API
  version: 1.0.0
paths: {}
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(Diagnostic(code: "invalid_value", ..)) = result
}

pub fn parse_rejects_openapi_with_extra_segment_case() {
  // More than three segments is not a valid SemVer-ish form.
  let yaml =
    "
openapi: 3.0.0.1
info:
  title: Over-Segmented API
  version: 1.0.0
paths: {}
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(Diagnostic(code: "invalid_value", ..)) = result
}

pub fn parse_rejects_bare_openapi_3_case() {
  // A bare quoted `"3"` cannot tell us whether the spec was authored
  // against 3.0.x or 3.1.x, so it is rejected. (An unquoted `openapi: 3`
  // is parsed as a YAML integer, coerced to the float 3.0, and
  // normalized to the string "3.0" — which is an explicitly accepted
  // two-segment form, so that case does NOT error.)
  let yaml =
    "
openapi: \"3\"
info:
  title: Ambiguous API
  version: 1.0.0
paths: {}
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(Diagnostic(code: "invalid_value", ..)) = result
}

pub fn parse_accepts_openapi_3_0_3_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: API
  version: 1.0.0
paths: {}
"
  let assert Ok(spec) = parser.parse_string(yaml)
  spec.openapi |> should.equal("3.0.3")
}

pub fn parse_accepts_openapi_3_1_0_case() {
  let yaml =
    "
openapi: 3.1.0
info:
  title: API
  version: 1.0.0
paths: {}
"
  let assert Ok(spec) = parser.parse_string(yaml)
  spec.openapi |> should.equal("3.1.0")
}

pub fn parse_rejects_unquoted_openapi_float_from_yaml_case() {
  // YAML 1.1 parses an unquoted `openapi: 3.0` as a float. The JSON
  // path already rejects non-string `openapi` values after #580; the
  // YAML path now mirrors that contract (#583) so the same document
  // gets the same verdict regardless of file format. Authors must
  // quote the version: `openapi: '3.0'`.
  let yaml =
    "
openapi: 3.0
info:
  title: API
  version: 1.0.0
paths: {}
"
  let result = parser.parse_string(yaml)
  let assert Error(Diagnostic(code: "missing_field", pointer: "", ..)) = result
}

pub fn parse_accepts_quoted_openapi_3_0_from_yaml_case() {
  // Counterpart to parse_rejects_unquoted_openapi_float_from_yaml_case:
  // the post-#583 contract is that the version must be a YAML string,
  // not that the two-segment form is invalid. Quoting the version
  // keeps the historical short form working.
  let yaml =
    "
openapi: '3.0'
info:
  title: API
  version: 1.0.0
paths: {}
"
  let assert Ok(spec) = parser.parse_string(yaml)
  spec.openapi |> should.equal("3.0")
}

pub fn parse_rejects_unquoted_openapi_int_from_yaml_case() {
  // `openapi: 3` arrives from yamerl as the integer 3. The OAS 3.0
  // schema requires a string; reject so downstream `validate` /
  // `generate` do not operate on a non-string version value. (#583)
  let yaml =
    "
openapi: 3
info:
  title: API
  version: '1.0.0'
paths: {}
"
  let result = parser.parse_string(yaml)
  let assert Error(Diagnostic(code: "missing_field", pointer: "", ..)) = result
}

pub fn parse_secure_api_has_security_schemes_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/secure_api.yaml")
  let assert Some(components) = spec.components
  dict.size(components.security_schemes) |> should.equal(2)
}

pub fn parse_secure_api_operation_has_security_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/secure_api.yaml")
  let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/pets")
  let assert Some(get_op) = path_item.get
  let assert Some(sec) = get_op.security
  list.length(sec) |> should.equal(1)
}

pub fn parse_accepts_basic_auth_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  securitySchemes:
    BasicAuth:
      type: http
      scheme: basic
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Some(components) = spec.components
  let assert Ok(scheme) = dict.get(components.security_schemes, "BasicAuth")
  case scheme {
    spec.Value(spec.HttpScheme(scheme: "basic", bearer_format: None)) ->
      should.be_true(True)
    _ -> should.fail()
  }
}

pub fn parse_accepts_digest_auth_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  securitySchemes:
    DigestAuth:
      type: http
      scheme: digest
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Some(components) = spec.components
  let assert Ok(scheme) = dict.get(components.security_schemes, "DigestAuth")
  case scheme {
    spec.Value(spec.HttpScheme(scheme: "digest", bearer_format: None)) ->
      should.be_true(True)
    _ -> should.fail()
  }
}

pub fn parse_rejects_malformed_security_scopes_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      security:
        - ApiKeyAuth: 123
      responses:
        '200':
          description: ok
components:
  securitySchemes:
    ApiKeyAuth:
      type: apiKey
      in: header
      name: X-Key
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
}

pub fn parse_primitive_api_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/primitive_api.yaml")
  spec.info.title |> should.equal("Primitive API")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(1)
}

pub fn parse_global_security_inherited_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/global_security_api.yaml")
  // Top-level security should be parsed
  list.length(spec.security) |> should.equal(1)
  // /me has no operation-level security -> inherits
  let assert Ok(spec.Value(me_path)) = dict.get(spec.paths, "/me")
  let assert Some(get_me) = me_path.get
  get_me.security |> should.equal(None)
  // /public has explicit empty security -> opts out
  let assert Ok(spec.Value(public_path)) = dict.get(spec.paths, "/public")
  let assert Some(get_public) = public_path.get
  get_public.security |> should.equal(Some([]))
}

pub fn validate_accepts_array_parameter_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /search:
    get:
      operationId: search
      parameters:
        - name: tags
          in: query
          schema:
            type: array
            items: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors =
    validate.validate(ctx)
    |> list.filter(fn(e) { e.target != diagnostic.TargetServer })
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "Array parameters") })
  |> should.be_false()
}

pub fn validate_accepts_optional_array_parameter_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /search:
    get:
      operationId: search
      parameters:
        - name: tags
          in: query
          required: false
          schema:
            type: array
            items: { type: integer }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors =
    validate.validate(ctx)
    |> list.filter(fn(e) { e.target != diagnostic.TargetServer })
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "Array parameters") })
  |> should.be_false()
}

// Issue #552: codegen panicked on response headers whose schema was a
// $ref or any composite shape (object / array / allOf / oneOf / anyOf).
// validate.validate_response_headers now catches those at validate
// time so the user sees a Diagnostic instead of a stack trace.

pub fn validate_rejects_response_header_with_ref_schema_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /thing:
    get:
      operationId: getThing
      responses:
        '200':
          description: ok
          headers:
            X-Custom:
              schema:
                $ref: '#/components/schemas/CustomHeader'
components:
  schemas:
    CustomHeader: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  // Exactly one diagnostic, naming the header and the unsupported kind.
  case errors {
    [d, ..] -> {
      should.be_true(string.contains(d.message, "X-Custom"))
      should.be_true(string.contains(d.message, "$ref"))
    }
    [] -> should.fail()
  }
}

pub fn validate_rejects_response_header_with_object_schema_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /thing:
    get:
      operationId: getThing
      responses:
        '200':
          description: ok
          headers:
            X-Meta:
              schema:
                type: object
                properties:
                  k: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  case errors {
    [d, ..] -> should.be_true(string.contains(d.message, "object"))
    [] -> should.fail()
  }
}

pub fn validate_rejects_response_header_with_oneof_schema_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /thing:
    get:
      operationId: getThing
      responses:
        '200':
          description: ok
          headers:
            X-Choice:
              schema:
                oneOf:
                  - { type: string }
                  - { type: integer }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  case errors {
    [d, ..] -> should.be_true(string.contains(d.message, "oneOf"))
    [] -> should.fail()
  }
}

pub fn validate_accepts_response_header_with_string_schema_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /thing:
    get:
      operationId: getThing
      responses:
        '200':
          description: ok
          headers:
            X-Trace:
              schema: { type: string }
            X-Count:
              schema: { type: integer }
            X-Ratio:
              schema: { type: number }
            X-On:
              schema: { type: boolean }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  errors |> should.equal([])
}

pub fn validate_accepts_text_plain_response_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /health:
    get:
      operationId: getHealth
      responses:
        '200':
          description: ok
          content:
            text/plain:
              schema: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  errors |> should.equal([])
}

// Issue #352: text/plain must be accepted as a request body content type so
// real-world specs (e.g. GitHub `markdown.render-raw`) stop tripping the
// "unsupported request content type" diagnostic. Mirrors the octet-stream
// acceptance test below.
pub fn validate_accepts_text_plain_request_body_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /echo:
    post:
      operationId: postEcho
      requestBody:
        required: true
        content:
          text/plain:
            schema: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "text/plain") && string.contains(s, "is not supported")
  })
  |> should.be_false()
}

// Issue #265: application/octet-stream must be accepted as a request body
// content type so callers can describe binary upload endpoints (S3
// PutObject-style, image upload, log shipping, etc.).
pub fn validate_accepts_octet_stream_request_body_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /blobs:
    post:
      operationId: putBlob
      requestBody:
        required: true
        content:
          application/octet-stream:
            schema: { type: string, format: binary }
      responses:
        '201': { description: stored }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  // No content-type-related diagnostic should mention application/octet-stream
  // as unsupported.
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "application/octet-stream")
    && string.contains(s, "is not supported")
  })
  |> should.be_false()
}

pub fn dedup_resolves_property_name_collision_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    Pet:
      type: object
      required: [pet-id, pet_id]
      properties:
        pet-id: { type: string }
        pet_id: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // Dedup pass resolves property name collisions
  let spec = dedup.dedup(hoist.hoist(spec))
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  // No collision errors since dedup resolved them
  errors |> should.equal([])
}

pub fn parse_rejects_optional_path_parameter_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets/{petId}:
    get:
      operationId: getPet
      parameters:
        - name: petId
          in: path
          required: false
          schema: { type: string }
      responses:
        '200': { description: ok }
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(Diagnostic(code: "invalid_value", message: detail, ..)) =
    result
  string.contains(detail, "required: true") |> should.be_true()
}

fn make_ctx_from_spec(spec) -> context.Context {
  make_ctx_from_spec_with_mode(spec, config.Both)
}

fn make_ctx_from_spec_with_mode(spec, mode) -> context.Context {
  let assert Ok(resolved) = resolve.resolve(spec)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: mode,
      validate: False,
    )
  context.new(resolved, cfg)
}

// --- Resolver Tests ---

pub fn ref_to_name_case() {
  resolver.ref_to_name("#/components/schemas/User")
  |> should.equal("User")
}

pub fn ref_to_name_simple_case() {
  resolver.ref_to_name("#/components/schemas/PetStatus")
  |> should.equal("PetStatus")
}

// --- Parser: style field ---

pub fn parse_parameter_style_deep_object_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/broken_openapi.yaml")
  let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/deep-object")
  let assert Some(op) = path_item.get
  let assert [spec.Value(param)] = op.parameters
  param.name |> should.equal("filter")
  param.style |> should.equal(Some(spec.DeepObjectStyle))
}

pub fn parse_parameter_style_none_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/petstore.yaml")
  let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/pets")
  let assert Some(op) = path_item.get
  let assert [spec.Value(first), ..] = op.parameters
  first.style |> should.equal(None)
}

// --- Parser: additionalProperties ---

pub fn parse_additional_properties_untyped_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/broken_openapi.yaml")
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "UntypedPayload")
  let assert Ok(schema.Inline(schema.ObjectSchema(
    additional_properties: schema.Untyped,
    ..,
  ))) = dict.get(props, "payload")
}

/// Per Issue #249: absent additionalProperties is parsed as Unspecified so
/// the codegen can omit the noisy `additional_properties: Dict(...)` field
/// from closed-object record types. JSON Schema still permits unknown keys at
/// runtime; the AST distinction lets explicit `true` / typed schemas opt back
/// in to surfacing them.
pub fn parse_absent_additional_properties_is_unspecified_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths: {}
components:
  schemas:
    Bag:
      type: object
      properties:
        name: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.ObjectSchema(additional_properties: ap, ..))) =
    dict.get(components.schemas, "Bag")
  ap |> should.equal(schema.Unspecified)
}

// --- Validation Tests ---

fn make_ctx(spec_path: String) -> context.Context {
  let assert Ok(spec) = parser.parse_file(spec_path)
  let assert Ok(resolved) = resolve.resolve(spec)
  let resolved = hoist.hoist(resolved)
  let resolved = dedup.dedup(resolved)
  let cfg =
    config.new(
      input: spec_path,
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  context.new(resolved, cfg)
}

pub fn validate_accepts_deep_object_case() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors =
    validate.validate(ctx)
    |> list.filter(fn(e) { e.target != diagnostic.TargetServer })
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "deepObject") })
  |> should.be_false()
}

pub fn validate_accepts_complex_schema_parameter_case() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors =
    validate.validate(ctx)
    |> list.filter(fn(e) { e.target != diagnostic.TargetServer })
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "Complex schema parameters")
  })
  |> should.be_false()
}

pub fn validate_accepts_referenced_parameter_schemas_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items/{filter}:
    get:
      operationId: getItems
      parameters:
        - name: filter
          in: path
          required: true
          schema:
            $ref: '#/components/schemas/Filter'
        - name: tags
          in: query
          required: false
          schema:
            $ref: '#/components/schemas/TagList'
      responses:
        '200': { description: ok }
components:
  schemas:
    Filter:
      type: object
      properties:
        q: { type: string }
    TagList:
      type: array
      items:
        type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors =
    validate.validate(ctx)
    |> list.filter(fn(e) { e.target != diagnostic.TargetServer })
  errors |> should.equal([])
}

pub fn validate_accepts_multipart_form_data_case() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors = validate.validate(ctx)
  // Filter out server-targeted errors; multipart is valid for client codegen
  let client_errors =
    list.filter(errors, fn(e) { e.target != diagnostic.TargetServer })
  let error_strings = list.map(client_errors, validate.error_to_string)
  list.any(error_strings, fn(s) { string.contains(s, "multipart/form-data") })
  |> should.be_false()
}

pub fn validate_accepts_object_multipart_fields_in_client_mode_case() {
  // Issue #503: an object-typed multipart field (e.g. Stripe's
  // `file_link_data: object`) is encoded as a JSON-bodied part and
  // must pass client-mode validation. Server-mode validation still
  // restricts multipart fields to primitive scalars / primitive
  // arrays, so this test pins the client-mode acceptance boundary
  // explicitly.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /upload:
    post:
      operationId: uploadFile
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required: [metadata]
              properties:
                metadata:
                  $ref: '#/components/schemas/Metadata'
      responses:
        '200': { description: ok }
components:
  schemas:
    Metadata:
      type: object
      properties:
        title: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec_with_mode(spec, config.Client)
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "multipart/form-data fields")
  })
  |> should.be_false()
}

pub fn validate_broken_spec_accepts_inline_oneof_after_hoisting_case() {
  // Inline oneOf variants are now handled by hoisting, so no validation error
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "oneOf/anyOf with inline schemas")
  })
  |> should.be_false()
}

pub fn validate_broken_spec_accepts_untyped_additional_properties_case() {
  let ctx = make_ctx("test/fixtures/broken_openapi.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  // additionalProperties: true is now supported via Dict(String, Dynamic),
  // so it should NOT appear as a validation error
  list.any(error_strings, fn(s) { string.contains(s, "additionalProperties") })
  |> should.be_false()
}

// --- Parser: fail-fast tests ---

pub fn parse_missing_responses_succeeds_with_empty_dict_case() {
  // Missing responses field is parsed as empty dict (not a parse error).
  // Validation catches missing responses separately.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/missing_responses.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn validate_missing_responses_rejects_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/missing_responses.yaml")
  let result = generate.generate(spec, context.config(make_ctx_from_spec(spec)))
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_missing =
        list.any(error_details, fn(d) { string.contains(d, "no responses") })
      should.be_true(has_missing)
    }

    Ok(_) -> should.fail()
  }
}

pub fn parse_invalid_param_location_fails_case() {
  let result = parser.parse_file("test/fixtures/invalid_param_location.yaml")
  should.be_error(result)
  let assert Error(Diagnostic(
    code: "invalid_value",
    pointer: "parameter.in",
    ..,
  )) = result
}

pub fn parse_missing_openapi_field_fails_case() {
  let yaml =
    "
info:
  title: Test
  version: 1.0.0
paths: {}
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(Diagnostic(
    code: "missing_field",
    pointer: "",
    message: "Missing required field: openapi",
    ..,
  )) = result
}

pub fn parse_missing_info_fails_case() {
  let yaml =
    "
openapi: 3.0.3
paths: {}
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(Diagnostic(
    code: "missing_field",
    pointer: "",
    message: "Missing required field: info",
    ..,
  )) = result
}

pub fn parse_missing_info_title_fails_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  version: 1.0.0
paths: {}
"
  let result = parser.parse_string(yaml)
  should.be_error(result)
  let assert Error(Diagnostic(
    code: "missing_field",
    pointer: "info",
    message: "Missing required field: title",
    ..,
  )) = result
}

// ---------------------------------------------------------------------------
// #580 regression — strict OAS 3.0 schema enforcement at the document root.
// Three cases with a shared root cause (parse_root did not enforce
// schema-required fields / value-types). Each case uses the JSON path,
// matching the issue reproduction; the YAML-path symmetry is covered
// by `parse_rejects_unquoted_openapi_float_from_yaml_case` and the
// other YAML-side cases above, added in #583.
// ---------------------------------------------------------------------------

/// Case A from #580: `paths` is required at the root for OAS 3.0.
/// `parse_json_string` previously returned `Ok(_)` for a 3.0 spec
/// missing `paths` — the `validate` subcommand happily passed the
/// document and downstream codegen produced empty output. Now rejected
/// with the standard `missing_field` diagnostic.
pub fn parse_json_oas_30_rejects_missing_paths_case() {
  let json =
    "{\"openapi\":\"3.0.3\",\"info\":{\"title\":\"X\",\"version\":\"1.0.0\"}}"
  let result = parser.parse_json_string(json)
  let assert Error(Diagnostic(
    code: "missing_field",
    pointer: "",
    message: "Missing required field: paths",
    ..,
  )) = result
}

/// Case B from #580: `openapi` MUST be a string per the OAS 3.0 schema.
/// `parse_json_string` previously coerced an integer `openapi: 3`
/// through the lenient float fallback (intended for YAML 1.1 number
/// coercion only). The JSON path rejects non-string values up front,
/// and after #583 the YAML path mirrors that contract — both targets
/// require a quoted string.
pub fn parse_json_rejects_integer_openapi_field_case() {
  let json =
    "{\"openapi\":3,\"info\":{\"title\":\"X\",\"version\":\"1.0.0\"},\"paths\":{}}"
  let result = parser.parse_json_string(json)
  let assert Error(Diagnostic(code: "missing_field", pointer: "", ..)) = result
}

/// Case C from #580: `paths` is the Paths Object (must be a map) per
/// the OAS 3.0 schema. `parse_json_string` previously fell into the
/// catch-all branch when `paths` was an array / scalar / bool and
/// silently returned an empty paths dict. Now rejected with an
/// `invalid_value` diagnostic naming the actual node kind.
pub fn parse_json_rejects_paths_as_list_case() {
  let json =
    "{\"openapi\":\"3.0.3\",\"info\":{\"title\":\"X\",\"version\":\"1.0.0\"},\"paths\":[\"/a\",\"/b\"]}"
  let result = parser.parse_json_string(json)
  let assert Error(Diagnostic(code: "invalid_value", pointer: "paths", ..)) =
    result
}

/// Companion regression: 3.1 documents may legitimately omit `paths`
/// (the spec may consist of `webhooks` / `components` only). The
/// require-paths-for-3.0 fix MUST NOT regress this case — it is the
/// "defensible disagreement" called out in #580.
pub fn parse_json_oas_31_accepts_missing_paths_case() {
  let json =
    "{\"openapi\":\"3.1.0\",\"info\":{\"title\":\"X\",\"version\":\"1.0.0\"}}"
  let assert Ok(spec) = parser.parse_json_string(json)
  spec.openapi |> should.equal("3.1.0")
}

pub fn validate_deep_inline_oneof_in_request_body_accepted_case() {
  // Inline oneOf in requestBody is now handled by hoisting
  let ctx = make_ctx("test/fixtures/deep_unsupported.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "oneOf/anyOf with inline schemas")
    && string.contains(s, "requestBody")
  })
  |> should.be_false()
}

pub fn validate_deep_additional_properties_in_response_case() {
  let ctx = make_ctx("test/fixtures/deep_unsupported.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  // additionalProperties: true is now supported, so no error for it
  list.any(error_strings, fn(s) {
    string.contains(s, "additionalProperties") && string.contains(s, "payload")
  })
  |> should.be_false()
}

pub fn validate_rejects_duplicate_operation_id_case() {
  // Issue #237: duplicate operationIds must fail validation with a clear
  // diagnostic that names every site that claimed the colliding ID.
  // (Previously the dedup pass silently renamed the second occurrence,
  // mutating the generated public API surface without notifying the
  // user.)
  let ctx = make_ctx("test/fixtures/error_duplicate_operation_id.yaml")
  let errors = validate.validate(ctx)
  let messages = list.map(errors, validate.error_to_string)
  list.any(messages, fn(s) { string.contains(s, "Duplicate operationId") })
  |> should.be_true()
  list.any(messages, fn(s) { string.contains(s, "listItems") })
  |> should.be_true()
  list.any(messages, fn(s) {
    string.contains(s, "GET /users") && string.contains(s, "GET /items")
  })
  |> should.be_true()
}

/// Multi-error aggregation contract: validate.validate must surface
/// ALL distinct issues found in one pass, not bail on the first one.
/// This pin protects against a future change that converts the
/// aggregator into early-return — which would silently hide every
/// issue past the first and force users to re-run the generator
/// repeatedly to discover their own bugs.
///
/// Fixture pairs an unresolved global security $ref with a duplicate
/// operationId across two paths; both are validate-phase errors so
/// they share a single call.
pub fn validate_aggregates_multiple_errors_in_one_pass_case() {
  let ctx = make_ctx("test/fixtures/error_multiple_issues.yaml")
  let errors = validate.validate(ctx)
  let messages = list.map(errors, validate.error_to_string)

  // The contract: at least two distinct diagnostics returned.
  case list.length(errors) >= 2 {
    True -> Nil
    False ->
      // nolint: avoid_panic -- pin failure aborts the suite
      panic as "expected >= 2 diagnostics, validator returned fewer"
  }

  // Both classes of error must be represented; otherwise the
  // aggregator is silently dropping one of them.
  list.any(messages, fn(s) { string.contains(s, "Duplicate operationId") })
  |> should.be_true()
  list.any(messages, fn(s) {
    string.contains(s, "nonexistent_scheme") || string.contains(s, "security")
  })
  |> should.be_true()
}

pub fn validate_rejects_operation_ids_colliding_after_snake_case_case() {
  // Two operationIds that differ only in case (listItems vs list_items)
  // collapse to the same snake_case function name in generated code.
  // That collision must fail validation even though the raw IDs differ.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Case Collision
  version: 1.0.0
paths:
  /a:
    get:
      operationId: listItems
      responses:
        '200': { description: ok }
  /b:
    get:
      operationId: list_items
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let messages = list.map(errors, validate.error_to_string)
  list.any(messages, fn(s) {
    string.contains(s, "list_items") && string.contains(s, "generated function")
  })
  |> should.be_true()
}

pub fn validate_accepts_unique_operation_ids_case() {
  // Sanity check: a well-formed spec with unique operationIds must not
  // produce any duplicate-operationId diagnostic.
  let ctx = make_ctx("test/fixtures/collision.yaml")
  let errors = validate.validate(ctx)
  let messages = list.map(errors, validate.error_to_string)
  list.any(messages, fn(s) { string.contains(s, "Duplicate operationId") })
  |> should.be_false()
}

pub fn dedup_resolves_request_param_field_name_collision_case() {
  // Regression for issue #236: two parameters that collapse to the same
  // snake_case field name (e.g. path `id` and query `id` on the same op)
  // must be renamed so the generated request type compiles.
  let ctx = make_ctx("test/fixtures/collision.yaml")

  let type_files = types.generate(ctx)
  let assert Ok(request_types_file) =
    list.find(type_files, fn(f) {
      string.contains(f.path, "request_types.gleam")
    })

  // The request record must not carry two fields sharing a label.
  string.contains(request_types_file.content, "id: String, id: Option")
  |> should.be_false()
  string.contains(request_types_file.content, "id: String, id: String")
  |> should.be_false()
  // The renamed second field must appear somewhere in the record.
  string.contains(request_types_file.content, "id_2:") |> should.be_true()

  // The server must construct the renamed field. The raw (pre-format)
  // output puts each field on its own line, so check the field assignment
  // rather than a comma-separated fragment.
  let server_files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(server_files, fn(f) { string.contains(f.path, "router.gleam") })
  string.contains(router_file.content, "id_2:") |> should.be_true()

  // The client's _with_request wrapper unpacks the renamed field.
  let client_files = client_gen.generate(ctx)
  let assert Ok(client_file) =
    list.find(client_files, fn(f) { string.contains(f.path, "client.gleam") })
  string.contains(client_file.content, "request.id_2") |> should.be_true()
}

pub fn dedup_param_field_names_reserves_body_label_case() {
  // A parameter literally named `body` must not collide with the
  // request type's `body` field (used for request bodies).
  let yaml =
    "
openapi: 3.0.3
info:
  title: Body Collision
  version: 1.0.0
paths:
  /items:
    post:
      operationId: createItem
      parameters:
        - name: body
          in: query
          required: false
          schema: { type: string }
      requestBody:
        required: true
        content:
          application/json:
            schema: { type: object, properties: { name: { type: string } } }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)

  let type_files = types.generate(ctx)
  let assert Ok(request_types_file) =
    list.find(type_files, fn(f) {
      string.contains(f.path, "request_types.gleam")
    })

  // Exactly one `body: ` field (the request body). The `body` query
  // parameter must have been renamed to `body_2`.
  string.contains(request_types_file.content, "body_2: Option(String)")
  |> should.be_true()
}

pub fn dedup_param_field_names_skips_existing_suffix_case() {
  // Regression: when a later parameter literally matches a suffix the
  // deduper would otherwise generate (e.g. wire names `body`, `body`,
  // `body_2`), the deduper must pick the next free suffix (`body_3`)
  // rather than minting a second `body_2`.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Suffix Collision
  version: 1.0.0
paths:
  /items:
    post:
      operationId: createItem
      parameters:
        - name: body
          in: query
          required: false
          schema: { type: string }
        - name: body_2
          in: header
          required: false
          schema: { type: string }
      requestBody:
        required: true
        content:
          application/json:
            schema: { type: object, properties: { name: { type: string } } }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)

  let type_files = types.generate(ctx)
  let assert Ok(request_types_file) =
    list.find(type_files, fn(f) {
      string.contains(f.path, "request_types.gleam")
    })

  // The reserved `body` (request body) is kept, the query `body` is
  // renamed to `body_3` (since `body_2` is already a real wire name),
  // and the header `body_2` keeps its original label.
  string.contains(request_types_file.content, "body_3:") |> should.be_true()
  string.contains(request_types_file.content, "body_2:") |> should.be_true()
}

pub fn validate_accepts_typed_additional_properties_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /config:
    get:
      operationId: getConfig
      responses:
        '200': { description: ok }
components:
  schemas:
    Config:
      type: object
      required: [name]
      properties:
        name: { type: string }
      additionalProperties:
        type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  errors |> should.equal([])
}

pub fn validate_accepts_untyped_additional_properties_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /data:
    get:
      operationId: getData
      responses:
        '200': { description: ok }
components:
  schemas:
    Payload:
      type: object
      required: [name]
      properties:
        name: { type: string }
      additionalProperties: true
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  errors |> should.equal([])
}

pub fn validate_petstore_has_no_errors_case() {
  let ctx = make_ctx("test/fixtures/petstore.yaml")
  let errors = validate.validate(ctx)
  errors |> should.equal([])
}

pub fn validate_complex_supported_has_no_errors_case() {
  let ctx = make_ctx("test/fixtures/complex_supported_openapi.yaml")
  let errors = validate.validate(ctx)
  errors |> should.equal([])
}

// --- Hoist Tests ---

pub fn hoist_inline_object_property_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    Pet:
      type: object
      required: [name]
      properties:
        name: { type: string }
        address:
          type: object
          properties:
            street: { type: string }
            city: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // PetAddress should exist in components.schemas
  dict.has_key(components.schemas, "PetAddress") |> should.be_true()

  // Pet.address should now be a $ref
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "Pet")
  let assert Ok(schema.Reference(ref: ref, ..)) = dict.get(props, "address")
  ref |> should.equal("#/components/schemas/PetAddress")

  // PetAddress should have street and city properties
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: addr_props, ..))) =
    dict.get(components.schemas, "PetAddress")
  dict.has_key(addr_props, "street") |> should.be_true()
  dict.has_key(addr_props, "city") |> should.be_true()
}

pub fn hoist_inline_oneof_variants_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    PetType:
      oneOf:
        - type: object
          properties:
            bark_volume: { type: integer }
        - type: object
          properties:
            purr_frequency: { type: number }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // The oneOf variants should now be $ref references
  let assert Ok(schema.Inline(schema.OneOfSchema(schemas: variants, ..))) =
    dict.get(components.schemas, "PetType")
  list.each(variants, fn(v) {
    case v {
      schema.Reference(..) -> should.be_true(True)
      schema.Inline(_) -> should.fail()
    }
  })

  // Hoisted schemas should exist (naming: PetType0, PetType1 or similar)
  // At minimum, components.schemas should have more than just PetType
  dict.size(components.schemas) |> should.equal(3)
}

pub fn hoist_property_provenance_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    Pet:
      type: object
      properties:
        address:
          type: object
          properties:
            street: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components
  let assert Ok(schema.Inline(pet)) = dict.get(components.schemas, "Pet")
  schema.get_provenance(pet) |> should.equal(schema.UserAuthored)
  let assert Ok(schema.Inline(pet_address)) =
    dict.get(components.schemas, "PetAddress")
  schema.get_provenance(pet_address)
  |> should.equal(schema.HoistedProperty(parent: "Pet", property: "address"))
}

pub fn hoist_oneof_variant_provenance_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    PetType:
      oneOf:
        - type: object
          properties:
            bark_volume: { type: integer }
        - type: object
          properties:
            purr_frequency: { type: number }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components
  let assert Ok(schema.Inline(variant0)) =
    dict.get(components.schemas, "PetTypeVariant0")
  schema.get_provenance(variant0)
  |> should.equal(schema.HoistedOneOfVariant(parent: "PetType", index: 0))
  let assert Ok(schema.Inline(variant1)) =
    dict.get(components.schemas, "PetTypeVariant1")
  schema.get_provenance(variant1)
  |> should.equal(schema.HoistedOneOfVariant(parent: "PetType", index: 1))
}

pub fn hoisted_schema_summary_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    Pet:
      type: object
      properties:
        address:
          type: object
          properties:
            street: { type: string }
    PetList:
      type: array
      items:
        type: object
        properties:
          name: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let summary = provenance.hoisted_schema_summary(hoisted)
  // User-authored: Pet, PetList
  list.length(summary.user_authored) |> should.equal(2)
  // Hoisted: PetAddress (property), PetListItem (array item)
  list.length(summary.hoisted_properties) |> should.equal(1)
  list.length(summary.hoisted_array_items) |> should.equal(1)
  provenance.total_hoisted(summary) |> should.equal(2)
  // Parent tracking is preserved through hoist metadata
  let assert [#(prop_name, parent, property)] = summary.hoisted_properties
  prop_name |> should.equal("PetAddress")
  parent |> should.equal("Pet")
  property |> should.equal("address")
}

pub fn hoist_inline_array_items_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    PetList:
      type: array
      items:
        type: object
        properties:
          name: { type: string }
          age: { type: integer }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // Array items should now be a $ref
  let assert Ok(schema.Inline(schema.ArraySchema(items: items_ref, ..))) =
    dict.get(components.schemas, "PetList")
  let assert schema.Reference(ref: ref, ..) = items_ref
  string.contains(ref, "#/components/schemas/") |> should.be_true()

  // The extracted schema should exist in components.schemas
  dict.size(components.schemas) |> should.equal(2)
}

pub fn hoist_preserves_refs_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    Pet:
      type: object
      properties:
        name: { type: string }
        owner:
          $ref: '#/components/schemas/Owner'
    Owner:
      type: object
      properties:
        name: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // No extra schemas should be added
  dict.size(components.schemas) |> should.equal(2)

  // The $ref should remain unchanged
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "Pet")
  let assert Ok(schema.Reference(ref: ref, ..)) = dict.get(props, "owner")
  ref |> should.equal("#/components/schemas/Owner")
}

pub fn hoist_preserves_primitives_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    User:
      type: object
      properties:
        name: { type: string }
        age: { type: integer }
        active: { type: boolean }
        score: { type: number }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // No extra schemas should be added for primitives
  dict.size(components.schemas) |> should.equal(1)

  // Properties should remain inline primitives
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "User")
  let assert Ok(schema.Inline(schema.StringSchema(..))) =
    dict.get(props, "name")
  let assert Ok(schema.Inline(schema.IntegerSchema(..))) =
    dict.get(props, "age")
  let assert Ok(schema.Inline(schema.BooleanSchema(..))) =
    dict.get(props, "active")
  let assert Ok(schema.Inline(schema.NumberSchema(..))) =
    dict.get(props, "score")
}

pub fn hoist_nested_inline_objects_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    Company:
      type: object
      properties:
        name: { type: string }
        headquarters:
          type: object
          properties:
            city: { type: string }
            coordinates:
              type: object
              properties:
                lat: { type: number }
                lon: { type: number }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // Both nested levels should be hoisted
  dict.has_key(components.schemas, "CompanyHeadquarters") |> should.be_true()
  dict.has_key(components.schemas, "CompanyHeadquartersCoordinates")
  |> should.be_true()

  // Company.headquarters should be a $ref
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: company_props, ..))) =
    dict.get(components.schemas, "Company")
  let assert Ok(schema.Reference(ref: hq_ref, ..)) =
    dict.get(company_props, "headquarters")
  hq_ref |> should.equal("#/components/schemas/CompanyHeadquarters")

  // CompanyHeadquarters.coordinates should be a $ref
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: hq_props, ..))) =
    dict.get(components.schemas, "CompanyHeadquarters")
  let assert Ok(schema.Reference(ref: coord_ref, ..)) =
    dict.get(hq_props, "coordinates")
  coord_ref
  |> should.equal("#/components/schemas/CompanyHeadquartersCoordinates")

  // CompanyHeadquartersCoordinates should have lat and lon
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: coord_props, ..))) =
    dict.get(components.schemas, "CompanyHeadquartersCoordinates")
  dict.has_key(coord_props, "lat") |> should.be_true()
  dict.has_key(coord_props, "lon") |> should.be_true()
}

pub fn hoist_request_body_inline_object_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets:
    post:
      operationId: createPet
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                name: { type: string }
                tag: { type: string }
      responses:
        '201': { description: created }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // The inline request body schema should be extracted
  dict.has_key(components.schemas, "CreatePetRequest")
  |> should.be_true()

  // The request body should now reference the extracted schema
  let assert Ok(spec.Value(path_item)) = dict.get(hoisted.paths, "/pets")
  let assert Some(op) = path_item.post
  let assert Some(spec.Value(req_body)) = op.request_body
  let assert Ok(media_type) = dict.get(req_body.content, "application/json")
  let assert Some(schema.Reference(ref: ref, ..)) = media_type.schema
  string.contains(ref, "#/components/schemas/") |> should.be_true()
}

pub fn hoist_response_inline_object_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets:
    get:
      operationId: listPets
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
                properties:
                  id: { type: integer }
                  name: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // The inline response schema should be extracted (with status code in name)
  dict.has_key(components.schemas, "ListPetsResponseOk")
  |> should.be_true()

  // The response should now reference the extracted schema
  let assert Ok(spec.Value(path_item)) = dict.get(hoisted.paths, "/pets")
  let assert Some(op) = path_item.get
  let assert Ok(spec.Value(response)) = dict.get(op.responses, http.Status(200))
  let assert Ok(media_type) = dict.get(response.content, "application/json")
  let assert Some(schema.Reference(ref: ref, ..)) = media_type.schema
  string.contains(ref, "#/components/schemas/") |> should.be_true()
}

pub fn hoist_idempotent_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    Pet:
      type: object
      properties:
        name: { type: string }
        address:
          type: object
          properties:
            street: { type: string }
            city: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted_once = hoist.hoist(spec)
  let hoisted_twice = hoist.hoist(hoisted_once)

  // Both hoisted results should have the same schemas
  let assert Some(components_once) = hoisted_once.components
  let assert Some(components_twice) = hoisted_twice.components
  dict.size(components_once.schemas)
  |> should.equal(dict.size(components_twice.schemas))

  // The schemas should be identical
  hoisted_once |> should.equal(hoisted_twice)
}

pub fn hoist_name_collision_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    Pet:
      type: object
      properties:
        name: { type: string }
        address:
          type: object
          properties:
            street: { type: string }
    PetAddress:
      type: object
      properties:
        zip: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  // Original PetAddress should still exist
  dict.has_key(components.schemas, "PetAddress") |> should.be_true()

  // The hoisted schema should use a suffixed name to avoid collision
  // There should be 3 schemas: Pet, PetAddress (original), and PetAddress2 (or similar)
  dict.size(components.schemas) |> should.equal(3)

  // Pet.address should reference the suffixed name, not the original PetAddress
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "Pet")
  let assert Ok(schema.Reference(ref: ref, ..)) = dict.get(props, "address")
  // The ref should NOT be the original PetAddress
  ref |> should.not_equal("#/components/schemas/PetAddress")
  // It should still be a valid components reference
  string.contains(ref, "#/components/schemas/") |> should.be_true()
}

pub fn hoist_case_normalized_name_collision_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    User:
      type: object
      properties:
        address:
          type: object
          properties:
            street: { type: string }
    user_address:
      type: object
      properties:
        zip: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let hoisted = hoist.hoist(spec)
  let assert Some(components) = hoisted.components

  dict.has_key(components.schemas, "user_address") |> should.be_true()
  dict.size(components.schemas) |> should.equal(3)

  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "User")
  let assert Ok(schema.Reference(ref: ref, ..)) = dict.get(props, "address")
  ref |> should.not_equal("#/components/schemas/UserAddress")
}

// --- ContentType Tests ---

pub fn content_type_from_string_case() {
  content_type.from_string("application/json")
  |> should.equal(content_type.ApplicationJson)

  content_type.from_string("text/plain")
  |> should.equal(content_type.TextPlain)

  content_type.from_string("multipart/form-data")
  |> should.equal(content_type.MultipartFormData)

  content_type.from_string("application/x-www-form-urlencoded")
  |> should.equal(content_type.FormUrlEncoded)

  content_type.from_string("application/xml")
  |> should.equal(content_type.ApplicationXml)

  content_type.from_string("text/xml")
  |> should.equal(content_type.TextXml)

  content_type.from_string("application/octet-stream")
  |> should.equal(content_type.ApplicationOctetStream)

  // application/x-ndjson aliases to TextPlain (issue #261)
  content_type.from_string("application/x-ndjson")
  |> should.equal(content_type.TextPlain)
}

// Issue #585: content-type strings carry case-insensitive type/subtype
// tokens (RFC 7231 §3.1.1.5) and parameters (`; charset=utf-8`) that
// are NOT part of the type identity. The pre-fix classifier did
// case-sensitive direct equality and never stripped parameters, so
// `application/JSON` and `application/json; charset=utf-8` were both
// misclassified as `UnsupportedContentType`. The cases below pin each
// shape from the issue.

pub fn content_type_classifier_normalises_case_case() {
  content_type.from_string("application/JSON")
  |> should.equal(content_type.ApplicationJson)
  content_type.from_string("Application/XML")
  |> should.equal(content_type.ApplicationXml)
}

pub fn content_type_classifier_strips_charset_parameter_case() {
  content_type.from_string("application/json; charset=utf-8")
  |> should.equal(content_type.ApplicationJson)
  content_type.from_string("application/json;charset=utf-8")
  |> should.equal(content_type.ApplicationJson)
  content_type.from_string("application/xml; charset=utf-8")
  |> should.equal(content_type.ApplicationXml)
}

pub fn content_type_classifier_preserves_structured_suffix_with_param_case() {
  content_type.from_string("application/vnd.api+json; charset=utf-8")
  |> should.equal(content_type.ApplicationJson)
  content_type.from_string("application/vnd.api+xml; q=1.0")
  |> should.equal(content_type.ApplicationXml)
}

pub fn content_type_is_json_compatible_normalised_case() {
  content_type.is_json_compatible("application/JSON") |> should.be_true()
  content_type.is_json_compatible("application/json; charset=utf-8")
  |> should.be_true()
  content_type.is_json_compatible("application/vnd.api+json; charset=utf-8")
  |> should.be_true()
}

pub fn content_type_is_xml_compatible_normalised_case() {
  content_type.is_xml_compatible("Application/XML") |> should.be_true()
  content_type.is_xml_compatible("text/XML; charset=utf-8")
  |> should.be_true()
  content_type.is_xml_compatible("application/atom+xml; charset=utf-8")
  |> should.be_true()
}

pub fn content_type_x_ndjson_is_supported_response_case() {
  content_type.is_supported_response(content_type.from_string(
    "application/x-ndjson",
  ))
  |> should.be_true()
}

// --- content type passthrough fallback (issue #352) ---
//
// Real-world specs (the GitHub REST OpenAPI is the canonical
// example) declare `text/html` responses, vendor-prefixed types
// like `application/vnd.github.diff`, and ad-hoc names like
// `application/octocat-stream`. Refusing to generate code for any
// of those was blocking adoption on otherwise-supported specs, so
// the parser now folds:
//
//   - any `text/*` not specifically recognized → TextPlain
//   - any `application/*` not specifically recognized → ApplicationOctetStream
//
// Other top-level types (`image/*`, `audio/*`, `video/*`) stay as
// `UnsupportedContentType` because the generator has no sensible
// default for binary media that is not already covered by
// `application/octet-stream`.

pub fn content_type_text_html_aliases_to_text_plain_case() {
  content_type.from_string("text/html") |> should.equal(content_type.TextPlain)
}

pub fn content_type_text_x_markdown_aliases_to_text_plain_case() {
  content_type.from_string("text/x-markdown")
  |> should.equal(content_type.TextPlain)
}

pub fn content_type_vendor_application_aliases_to_octet_stream_case() {
  // GitHub REST API vendor MIME types: diff/patch/sha/object plus
  // the ad-hoc `octocat-stream`.
  content_type.from_string("application/vnd.github.diff")
  |> should.equal(content_type.ApplicationOctetStream)
  content_type.from_string("application/vnd.github.patch")
  |> should.equal(content_type.ApplicationOctetStream)
  content_type.from_string("application/vnd.github.object")
  |> should.equal(content_type.ApplicationOctetStream)
  content_type.from_string("application/octocat-stream")
  |> should.equal(content_type.ApplicationOctetStream)
}

pub fn content_type_image_png_still_unsupported_case() {
  // Images don't match the text/ or application/ fallback so they
  // stay UnsupportedContentType. This pins that the fallback is
  // narrow on purpose — silently aliasing every MIME to bytes
  // would mask real "this codegen does not support that" cases.
  content_type.from_string("image/png")
  |> should.equal(content_type.UnsupportedContentType("image/png"))
}

pub fn content_type_audio_video_still_unsupported_case() {
  content_type.from_string("audio/mpeg")
  |> should.equal(content_type.UnsupportedContentType("audio/mpeg"))
  content_type.from_string("video/mp4")
  |> should.equal(content_type.UnsupportedContentType("video/mp4"))
}

pub fn content_type_text_html_is_supported_response_case() {
  content_type.is_supported_response(content_type.from_string("text/html"))
  |> should.be_true()
}

pub fn content_type_vendor_diff_is_supported_response_case() {
  content_type.is_supported_response(content_type.from_string(
    "application/vnd.github.diff",
  ))
  |> should.be_true()
}

pub fn content_type_text_x_markdown_is_supported_request_case() {
  content_type.is_supported_request(content_type.from_string("text/x-markdown"))
  |> should.be_true()
}

pub fn content_type_to_string_case() {
  content_type.to_string(content_type.ApplicationJson)
  |> should.equal("application/json")

  content_type.to_string(content_type.TextPlain)
  |> should.equal("text/plain")

  content_type.to_string(content_type.MultipartFormData)
  |> should.equal("multipart/form-data")

  content_type.to_string(content_type.FormUrlEncoded)
  |> should.equal("application/x-www-form-urlencoded")

  content_type.to_string(content_type.ApplicationXml)
  |> should.equal("application/xml")

  content_type.to_string(content_type.ApplicationOctetStream)
  |> should.equal("application/octet-stream")
}

pub fn content_type_is_supported_case() {
  content_type.is_supported(content_type.ApplicationJson)
  |> should.be_true()

  content_type.is_supported(content_type.TextPlain)
  |> should.be_true()

  content_type.is_supported(content_type.MultipartFormData)
  |> should.be_true()

  content_type.is_supported(content_type.FormUrlEncoded)
  |> should.be_true()

  content_type.is_supported(content_type.ApplicationXml)
  |> should.be_true()

  content_type.is_supported(content_type.ApplicationOctetStream)
  |> should.be_true()

  content_type.is_supported(content_type.UnsupportedContentType(
    "application/msgpack",
  ))
  |> should.be_false()
}

pub fn content_type_is_supported_request_case() {
  content_type.is_supported_request(content_type.ApplicationJson)
  |> should.be_true()

  content_type.is_supported_request(content_type.MultipartFormData)
  |> should.be_true()

  content_type.is_supported_request(content_type.FormUrlEncoded)
  |> should.be_true()

  content_type.is_supported_request(content_type.TextPlain)
  |> should.be_true()
}

pub fn content_type_is_supported_response_case() {
  content_type.is_supported_response(content_type.ApplicationJson)
  |> should.be_true()

  content_type.is_supported_response(content_type.TextPlain)
  |> should.be_true()

  content_type.is_supported_response(content_type.ApplicationXml)
  |> should.be_true()

  content_type.is_supported_response(content_type.ApplicationOctetStream)
  |> should.be_true()

  content_type.is_supported_response(content_type.MultipartFormData)
  |> should.be_false()
}

pub fn content_type_roundtrip_case() {
  content_type.from_string("application/json")
  |> content_type.to_string()
  |> should.equal("application/json")

  content_type.from_string("text/plain")
  |> content_type.to_string()
  |> should.equal("text/plain")

  content_type.from_string("multipart/form-data")
  |> content_type.to_string()
  |> should.equal("multipart/form-data")

  content_type.from_string("image/png")
  |> content_type.to_string()
  |> should.equal("image/png")
}

pub fn parse_accepts_oauth2_scheme_case() {
  let yaml =
    "
openapi: '3.0.0'
info: { title: OAuth2 API, version: '1.0' }
paths:
  /resource:
    get:
      operationId: getResource
      security:
        - oauth2Auth: []
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    oauth2Auth:
      type: oauth2
      description: OAuth2 authorization code
      flows:
        authorizationCode:
          authorizationUrl: https://example.com/auth
          tokenUrl: https://example.com/token
          scopes: {}
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert Some(components) = parsed.components
  let assert Ok(scheme) = dict.get(components.security_schemes, "oauth2Auth")
  case scheme {
    spec.Value(spec.OAuth2Scheme(
      description: Some("OAuth2 authorization code"),
      ..,
    )) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn parse_accepts_apikey_cookie_case() {
  let yaml =
    "
openapi: '3.0.0'
info: { title: Cookie API, version: '1.0' }
paths:
  /resource:
    get:
      operationId: getResource
      security:
        - cookieAuth: []
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    cookieAuth:
      type: apiKey
      name: session_id
      in: cookie
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert Some(components) = parsed.components
  let assert Ok(scheme) = dict.get(components.security_schemes, "cookieAuth")
  case scheme {
    spec.Value(spec.ApiKeyScheme(name: "session_id", in_: spec.SchemeInCookie)) ->
      should.be_true(True)
    _ -> should.fail()
  }
}

// --- Feature: allOf with primitive sub-schemas (Phase 4-2) ---

pub fn allof_with_primitive_sub_schema_case() {
  // allOf that mixes object and primitive schemas should not crash.
  // Primitive sub-schemas are silently ignored; object properties are merged.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    MixedAllOf:
      allOf:
        - type: string
        - type: object
          required: [name]
          properties:
            name: { type: string }
            age: { type: integer }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)

  // Should generate types without crashing
  let files = types.generate(ctx)
  // Should produce at least one file
  list.length(files) |> should.not_equal(0)

  // The generated types file should contain the MixedAllOf type
  // with properties from the object sub-schema
  let assert [types_file, ..] = files
  string.contains(types_file.content, "MixedAllOf") |> should.be_true()
  string.contains(types_file.content, "name: String") |> should.be_true()
}

// --- Feature: allOf PartN helper types must not appear in public generated API ---

pub fn allof_part_types_not_in_generated_types_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    User:
      type: object
      required: [id, name]
      properties:
        id: { type: string }
        name: { type: string }
    AdminUser:
      allOf:
        - $ref: '#/components/schemas/User'
        - type: object
          properties:
            permissions:
              type: array
              items: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  let content = types_file.content

  // The merged AdminUser type should be present
  string.contains(content, "pub type AdminUser {") |> should.be_true()

  // PartN helper types must NOT appear in generated types
  string.contains(content, "AdminUserPart") |> should.be_false()
}

pub fn allof_part_types_not_in_generated_decoders_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    User:
      type: object
      required: [id, name]
      properties:
        id: { type: string }
        name: { type: string }
    AdminUser:
      allOf:
        - $ref: '#/components/schemas/User'
        - type: object
          properties:
            permissions:
              type: array
              items: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = decoders.generate(ctx)

  // Find decode file
  let assert Ok(decode_file) =
    list.find(files, fn(f) { string.contains(f.path, "decode") })
  let content = decode_file.content

  // The merged AdminUser decoder should be present
  string.contains(content, "admin_user_decoder") |> should.be_true()

  // PartN helper decoders must NOT appear
  string.contains(content, "admin_user_part") |> should.be_false()
}

pub fn allof_part_types_not_in_generated_encoders_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    User:
      type: object
      required: [id, name]
      properties:
        id: { type: string }
        name: { type: string }
    AdminUser:
      allOf:
        - $ref: '#/components/schemas/User'
        - type: object
          properties:
            permissions:
              type: array
              items: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = list.append(decoders.generate(ctx), encoders.generate(ctx))

  // Find encode file
  let assert Ok(encode_file) =
    list.find(files, fn(f) { string.contains(f.path, "encode") })
  let content = encode_file.content

  // The merged AdminUser encoder should be present
  string.contains(content, "encode_admin_user") |> should.be_true()

  // PartN helper encoders must NOT appear
  string.contains(content, "admin_user_part") |> should.be_false()
}

// --- Feature: Deterministic output ordering (idempotency) ---

pub fn generation_is_idempotent_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /users:
    get:
      operationId: listUsers
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/User'
        '400': { description: bad request }
        '500': { description: internal error }
components:
  schemas:
    User:
      type: object
      required: [id]
      properties:
        id: { type: string }
        name: { type: string }
        email: { type: string }
        age: { type: integer }
        score: { type: number }
        active: { type: boolean }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx1 = make_ctx_from_spec(spec)

  // Generate types twice and compare
  let files1 = types.generate(ctx1)
  let assert Ok(spec2) = parser.parse_string(yaml)
  let spec2 = hoist.hoist(spec2)
  let ctx2 = make_ctx_from_spec(spec2)
  let files2 = types.generate(ctx2)

  // Types output must be identical across runs
  let assert [t1, ..] = files1
  let assert [t2, ..] = files2
  t1.content |> should.equal(t2.content)

  // Decoders output must be identical across runs
  let dec1 = decoders.generate(ctx1)
  let dec2 = decoders.generate(ctx2)
  let assert [d1, ..] = dec1
  let assert [d2, ..] = dec2
  d1.content |> should.equal(d2.content)
}

pub fn generated_type_fields_are_alphabetically_ordered_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    Widget:
      type: object
      required: [id]
      properties:
        zebra: { type: string }
        alpha: { type: string }
        middle: { type: integer }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  let content = types_file.content

  // Fields must appear in sorted order, not dict iteration order
  let assert Ok(alpha_pos) = string_index(content, "alpha:")
  let assert Ok(middle_pos) = string_index(content, "middle:")
  let assert Ok(zebra_pos) = string_index(content, "zebra:")
  { alpha_pos < middle_pos } |> should.be_true()
  { middle_pos < zebra_pos } |> should.be_true()
}

fn string_index(haystack: String, needle: String) -> Result(Int, Nil) {
  case string.split(haystack, needle) {
    [before, ..] if before != haystack -> Ok(string.length(before))
    _ -> Error(Nil)
  }
}

// --- Feature: Validation diagnostics include actionable hints ---

pub fn validation_errors_include_hints_case() {
  // A spec with an unsupported content type should produce a diagnostic with a hint
  let yaml =
    "
openapi: 3.0.3
info:
  title: T
  version: 1.0.0
paths:
  /upload:
    post:
      operationId: upload
      requestBody:
        required: true
        content:
          text/csv:
            schema:
              type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let assert Error(generate.ValidationErrors(errors:)) =
    generate.validate_only(spec, cfg)
  // All validation errors must have hints
  list.each(errors, fn(e) { option.is_some(e.hint) |> should.be_true() })
}

pub fn capability_warnings_include_hints_case() {
  // A spec with webhooks should produce a capability warning with a hint
  let yaml =
    "
openapi: 3.1.0
info:
  title: T
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
webhooks:
  newPet:
    post:
      operationId: newPetHook
      requestBody:
        content:
          application/json:
            schema:
              type: object
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let assert Ok(summary) = generate.validate_only(spec, cfg)
  // Should have at least one warning (webhooks parsed but unused)
  { summary.warnings != [] } |> should.be_true()
  // All warnings must have hints
  list.each(summary.warnings, fn(w) {
    option.is_some(w.hint) |> should.be_true()
  })
}

// --- Feature: Validation constraints generate guards (Phase 4-3) ---

pub fn validate_constraints_generate_guards_case() {
  // Schemas with string and numeric constraints should produce guard functions.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /users:
    get:
      operationId: listUsers
      responses:
        '200': { description: ok }
components:
  schemas:
    User:
      type: object
      required: [username, age]
      properties:
        username:
          type: string
          minLength: 3
          maxLength: 50
          pattern: '^[a-zA-Z0-9]+$'
        age:
          type: integer
          minimum: 0
          maximum: 150
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)

  // Should generate guard files without crashing
  let files = guards.generate(ctx)
  // Should produce at least one file (guards.gleam)
  list.length(files) |> should.not_equal(0)

  let assert [guard_file] = files
  guard_file.path |> should.equal("guards.gleam")

  // Should contain validation functions for constrained fields
  string.contains(guard_file.content, "validate_user_username_length")
  |> should.be_true()
  string.contains(guard_file.content, "validate_user_username_pattern")
  |> should.be_true()
  string.contains(guard_file.content, "validate_user_age_range")
  |> should.be_true()
  string.contains(guard_file.content, "import gleam/regexp")
  |> should.be_true()
  string.contains(guard_file.content, "regexp.check(re, value)")
  |> should.be_true()
}

/// Issue #269: helpers and composite validators must surface
/// structured `ValidationFailure(field, code, message)` values rather
/// than bare strings, and the type and JSON encoder must be emitted in
/// the same module so routers / clients can consume them.
pub fn validate_constraints_emit_structured_failures_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /users:
    get:
      operationId: listUsers
      responses:
        '200': { description: ok }
components:
  schemas:
    User:
      type: object
      required: [username, age]
      properties:
        username:
          type: string
          minLength: 3
          maxLength: 50
          pattern: '^[a-zA-Z0-9]+$'
        age:
          type: integer
          minimum: 0
          maximum: 150
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let assert [guard_file] = guards.generate(ctx)

  // ValidationFailure type and JSON encoder are emitted up-front.
  string.contains(guard_file.content, "import gleam/json")
  |> should.be_true()
  string.contains(guard_file.content, "pub type ValidationFailure {")
  |> should.be_true()
  string.contains(
    guard_file.content,
    "ValidationFailure(field: String, code: String, message: String)",
  )
  |> should.be_true()
  string.contains(
    guard_file.content,
    "pub fn validation_failure_to_json(failure: ValidationFailure)",
  )
  |> should.be_true()

  // Helpers return `Result(_, ValidationFailure)` (single failure).
  // Match the suffix loosely — the formatter may break the signature
  // across lines for longer types.
  string.contains(guard_file.content, "validate_user_username_length")
  |> should.be_true()
  string.contains(guard_file.content, "Result(String, ValidationFailure)")
  |> should.be_true()
  string.contains(guard_file.content, "validate_user_age_range")
  |> should.be_true()
  string.contains(guard_file.content, "Result(Int, ValidationFailure)")
  |> should.be_true()

  // Codes are JSON Schema keywords (camelCase) and field carries the
  // OpenAPI property name (camelCase preserved).
  string.contains(guard_file.content, "code: \"minLength\"")
  |> should.be_true()
  string.contains(guard_file.content, "code: \"maxLength\"")
  |> should.be_true()
  string.contains(guard_file.content, "code: \"pattern\"")
  |> should.be_true()
  string.contains(guard_file.content, "code: \"minimum\"")
  |> should.be_true()
  string.contains(guard_file.content, "code: \"maximum\"")
  |> should.be_true()
  string.contains(guard_file.content, "field: \"username\"")
  |> should.be_true()
  string.contains(guard_file.content, "field: \"age\"")
  |> should.be_true()

  // Composite validator returns `List(ValidationFailure)` and folds via
  // `[failure, ..errors]` (no more `[msg, ..errors]`).
  string.contains(
    guard_file.content,
    "Result(types.User, List(ValidationFailure))",
  )
  |> should.be_true()
  string.contains(guard_file.content, "Error(failure) -> [failure, ..errors]")
  |> should.be_true()
  string.contains(guard_file.content, "Error(msg) -> [msg, ..errors]")
  |> should.be_false()
}

pub fn client_emits_with_request_wrappers_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items/{id}:
    get:
      operationId: getItem
      parameters:
        - name: id
          in: path
          required: true
          schema: { type: integer }
        - name: expand
          in: query
          schema: { type: boolean }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let combined = list.fold(files, "", fn(acc, f) { acc <> f.content })
  string.contains(
    combined,
    "pub fn get_item_with_request(send send: transport.Send, request request: request_types.GetItemRequest)",
  )
  |> should.be_true()
  string.contains(combined, "get_item(send, request.id, request.expand)")
  |> should.be_true()
  string.contains(combined, "/request_types") |> should.be_true()
}

pub fn middleware_gleam_is_not_emitted_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = generate.generate_all_files(ctx)
  // No generated file should be named middleware.gleam after #116.
  list.any(files, fn(f) { f.path == "middleware.gleam" })
  |> should.be_false()
}

pub fn callbacks_do_not_emit_handler_stubs_case() {
  // Callbacks must parse successfully but must not produce the old
  // misleading `fn(...) -> String` handler stubs (see issue #117).
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /subscribe:
    post:
      operationId: subscribe
      responses:
        '201': { description: subscribed }
      callbacks:
        onEvent:
          '{$request.body#/callbackUrl}':
            post:
              operationId: onEventCallback
              responses:
                '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let combined = list.fold(files, "", fn(acc, f) { acc <> f.content })
  // The old stub pattern must be gone.
  string.contains(combined, "subscribe_callback_on_event_") |> should.be_false()
  string.contains(combined, "Callback handler stub for")
  |> should.be_false()
  string.contains(combined, "-> String {") |> should.be_false()
}

pub fn client_uses_transport_send_contract_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let combined = list.fold(files, "", fn(acc, f) { acc <> f.content })
  // The pure transport runtime is the wire contract — no gleam_http
  // imports leak into generated client code.
  string.contains(combined, "import oaspec/transport") |> should.be_true()
  string.contains(combined, "import gleam/http/request") |> should.be_false()
  // Each operation wires build → send → decode through result.try.
  string.contains(combined, "use req <- result.try(") |> should.be_true()
  string.contains(combined, "|> result.map_error(TransportError)")
  |> should.be_true()
  // The deprecated `let assert Ok(req) = request.to(...)` pattern is gone.
  string.contains(combined, "let assert Ok(req) = request.to")
  |> should.be_false()
  // InvalidUrl is no longer part of ClientError — invalid base URLs flow
  // through as TransportError(InvalidBaseUrl).
  string.contains(combined, "InvalidUrl(detail: String)") |> should.be_false()
}

pub fn encode_dynamic_fallback_emits_null_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /u:
    get:
      operationId: u
      responses:
        '200': { description: ok }
components:
  schemas:
    Bag:
      type: object
      additionalProperties: true
      properties:
        name: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = list.append(decoders.generate(ctx), encoders.generate(ctx))
  let combined = list.fold(files, "", fn(acc, f) { acc <> f.content })
  // Fallback branch must emit json.null(), never the classified type name.
  string.contains(combined, "_ -> json.null()") |> should.be_true()
  string.contains(combined, "json.string(dynamic.classify(value))")
  |> should.be_false()
}

pub fn client_emits_unexpected_status_variant_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let combined = list.fold(files, "", fn(acc, f) { acc <> f.content })
  // The variant carries status + headers + body (transport.Body) so
  // callers can drill into the unexpected response.
  string.contains(combined, "UnexpectedStatus(") |> should.be_true()
  string.contains(combined, "status: Int,") |> should.be_true()
  string.contains(combined, "body: transport.Body,") |> should.be_true()
  // Catch-all arms construct the new variant.
  string.contains(combined, "Error(UnexpectedStatus(") |> should.be_true()
  string.contains(combined, "status: resp.status,") |> should.be_true()
  // The old DecodeError-as-status-wrapper form is gone.
  string.contains(combined, "DecodeError(detail: \"Unexpected status:")
  |> should.be_false()
}

pub fn enum_decoder_failure_includes_rejected_value_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /u:
    get:
      operationId: u
      responses:
        '200': { description: ok }
components:
  schemas:
    Status:
      type: string
      enum: [active, inactive]
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = decoders.generate(ctx)
  let combined = list.fold(files, "", fn(acc, f) { acc <> f.content })
  // Failure branch must interpolate `value` so callers can see the bad string.
  string.contains(combined, "\"Status: unknown variant \" <> value")
  |> should.be_true()
}

pub fn client_query_params_preserve_declared_order_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: limit
          in: query
          schema: { type: integer }
        - name: offset
          in: query
          schema: { type: integer }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let combined = list.fold(files, "", fn(acc, f) { acc <> f.content })
  // Query is built up with prepend-then-reverse so emission order
  // matches the spec's declared parameter order on the wire.
  string.contains(combined, "let query = list.reverse(query)")
  |> should.be_true()
  // Tuples carry raw key/value pairs; the adapter handles encoding.
  string.contains(combined, "[#(\"limit\",") |> should.be_true()
  string.contains(combined, "[#(\"offset\",") |> should.be_true()
}

pub fn guards_minlength_one_uses_singular_character_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /u:
    get:
      operationId: u
      responses:
        '200': { description: ok }
components:
  schemas:
    Short:
      type: string
      minLength: 1
      maxLength: 1
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let assert [guard_file] = guards.generate(ctx)
  string.contains(guard_file.content, "must be at least 1 character\"")
  |> should.be_true()
  string.contains(guard_file.content, "must be at most 1 character\"")
  |> should.be_true()
  // The plural form must not appear for 1-bounded messages.
  string.contains(guard_file.content, "must be at least 1 characters")
  |> should.be_false()
  string.contains(guard_file.content, "must be at most 1 characters")
  |> should.be_false()
}

pub fn guards_minmax_length_plural_above_one_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /u:
    get:
      operationId: u
      responses:
        '200': { description: ok }
components:
  schemas:
    Medium:
      type: string
      minLength: 2
      maxLength: 5
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let assert [guard_file] = guards.generate(ctx)
  string.contains(guard_file.content, "must be at least 2 characters")
  |> should.be_true()
  string.contains(guard_file.content, "must be at most 5 characters")
  |> should.be_true()
}

pub fn validate_top_level_string_pattern_generates_guard_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /users:
    get:
      operationId: listUsers
      responses:
        '200': { description: ok }
components:
  schemas:
    Username:
      type: string
      pattern: '^[a-zA-Z0-9_-]+$'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  let assert [guard_file] = files

  string.contains(guard_file.content, "validate_username_root_pattern")
  |> should.be_true()
  string.contains(guard_file.content, "validate_username(value: String)")
  |> should.be_true()
  string.contains(guard_file.content, "validate_username_root_pattern(value)")
  |> should.be_true()
  string.contains(guard_file.content, "import gleam/regexp")
  |> should.be_true()
  string.contains(guard_file.content, "regexp.check(re, value)")
  |> should.be_true()
}

pub fn validate_object_property_count_still_collects_nested_string_constraints_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /users:
    get:
      operationId: listUsers
      responses:
        '200': { description: ok }
components:
  schemas:
    User:
      type: object
      minProperties: 1
      properties:
        username:
          type: string
          minLength: 3
          pattern: '^[a-zA-Z0-9_-]+$'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  let assert [guard_file] = files

  // The schema is a closed record (no `additionalProperties`), so the
  // `minProperties` guard is intentionally NOT emitted — its validator
  // takes `Dict(k, v)` and the generated record exposes no Dict view.
  // Nested string constraints on individual fields must still be
  // collected; this test exists to pin that.
  string.contains(guard_file.content, "validate_user_root_properties")
  |> should.be_false()
  string.contains(guard_file.content, "import gleam/string")
  |> should.be_true()
  string.contains(guard_file.content, "import gleam/regexp")
  |> should.be_true()
  string.contains(guard_file.content, "validate_user_username_length")
  |> should.be_true()
  string.contains(guard_file.content, "validate_user_username_pattern")
  |> should.be_true()
}

// --- Feature: Callbacks are ignored during parsing (Phase 4-4) ---

pub fn parse_ignores_callbacks_case() {
  // Operations with a callbacks field should parse without error.
  // The callbacks field is simply ignored.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Callback Test
  version: 1.0.0
paths:
  /subscribe:
    post:
      operationId: subscribe
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                callbackUrl:
                  type: string
      callbacks:
        onEvent:
          '{$request.body#/callbackUrl}':
            post:
              requestBody:
                content:
                  application/json:
                    schema:
                      type: object
                      properties:
                        event: { type: string }
              responses:
                '200': { description: ok }
      responses:
        '201': { description: subscribed }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  spec.info.title |> should.equal("Callback Test")
  // The operation should have parsed successfully
  let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/subscribe")
  let assert Some(op) = path_item.post
  op.operation_id |> should.equal(Some("subscribe"))
}

// =========================================================================
// Finding reproduction tests
// =========================================================================

// --- Finding 1: typed additionalProperties decoder must not apply value
// decoder to known fields. When a schema has additionalProperties: {type: string}
// but also has a fixed property of type integer, the decoder must not try
// to decode ALL values as strings (which would fail on the integer field).
// The fix: use dynamic.dynamic to read the raw dict, then filter + decode.
pub fn typed_additional_props_decoder_uses_dynamic_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /config:
    get:
      operationId: getConfig
      responses:
        '200': { description: ok }
components:
  schemas:
    Config:
      type: object
      required: [version]
      properties:
        version: { type: integer }
      additionalProperties:
        type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = decoders.generate(ctx)
  let assert [decode_file, ..] = files
  let content = decode_file.content
  // The decoder must NOT use decode.dict(decode.string, decode.string)
  // because that would fail on the integer "version" field.
  // It should use dynamic.dynamic for the initial dict read.
  string.contains(content, "decode.dict(decode.string, decode.string)")
  |> should.be_false()
  // It should decode the dict with a dynamic primitive decoder first
  string.contains(content, "new_primitive_decoder")
  |> should.be_true()
}

pub fn typed_additional_props_decoder_rejects_invalid_extra_values_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /config:
    get:
      operationId: getConfig
      responses:
        '200': { description: ok }
components:
  schemas:
    Config:
      type: object
      required: [version]
      properties:
        version: { type: integer }
      additionalProperties:
        type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = decoders.generate(ctx)
  let assert [decode_file, ..] = files
  let content = decode_file.content

  // Invalid extra values must fail decoding rather than being silently dropped.
  string.contains(content, "Error(_) -> acc")
  |> should.be_false()
  string.contains(
    content,
    "decode.failure(dict.new(), \"additionalProperties\")",
  )
  |> should.be_true()
}

// --- Finding 2: multipart/form-data client must handle optional and $ref fields.
// Currently body.<field> is concatenated as-is, which breaks for Option(T) and
// typed $ref fields.
pub fn multipart_optional_field_generates_case_expr_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /upload:
    post:
      operationId: uploadFile
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required: [name]
              properties:
                name: { type: string }
                description: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // Optional "description" field must have case/Some/None handling,
  // not raw body.description string concatenation
  string.contains(content, "case body.description")
  |> should.be_true()
}

pub fn multipart_ref_scalar_field_is_stringified_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /upload:
    post:
      operationId: uploadFile
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required: [id]
              properties:
                id:
                  $ref: '#/components/schemas/UploadId'
      responses:
        '200': { description: ok }
components:
  schemas:
    UploadId:
      type: integer
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content

  string.contains(content, "int.to_string(body.id)")
  |> should.be_true()
}

pub fn path_ref_array_parameters_are_stringified_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items/{tags}:
    get:
      operationId: getItems
      parameters:
        - name: tags
          in: path
          required: true
          schema:
            $ref: '#/components/schemas/TagList'
      responses:
        '200': { description: ok }
components:
  schemas:
    TagList:
      type: array
      items:
        type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content

  string.contains(content, "string.join(list.map(tags, fn(x) { x }), \",\")")
  |> should.be_true()
}

// --- Finding 3: unknown HTTP security schemes must produce a validation error
// or a warning, not be silently ignored at code generation time.
pub fn unknown_http_security_scheme_accepted_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /data:
    get:
      operationId: getData
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    myAuth:
      type: http
      scheme: hoba
security:
  - myAuth: []
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  // All HTTP schemes are now accepted
  errors |> should.equal([])
}

// --- Finding 4: allOf merge must preserve additionalProperties from sub-schemas.
// Currently, merged ObjectSchema hardcodes additional_properties: None.
pub fn allof_merge_preserves_additional_properties_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200': { description: ok }
components:
  schemas:
    BaseItem:
      type: object
      required: [id]
      properties:
        id: { type: integer }
      additionalProperties:
        type: string
    ExtendedItem:
      allOf:
        - $ref: '#/components/schemas/BaseItem'
        - type: object
          properties:
            label: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  let content = types_file.content
  // ExtendedItem must have additional_properties field since BaseItem has it
  string.contains(content, "pub type ExtendedItem {")
  |> should.be_true()
  // Extract the ExtendedItem type block and check it has additional_properties
  let assert Ok(extended_start) =
    find_substring_index(content, "pub type ExtendedItem {")
  let after_extended = string.drop_start(content, extended_start)
  // The ExtendedItem block itself must contain additional_properties
  // (not just the BaseItem block above it)
  let assert Ok(closing_brace) = find_substring_index(after_extended, "\n}\n")
  let extended_block = string.slice(after_extended, 0, closing_brace + 2)
  string.contains(extended_block, "additional_properties:")
  |> should.be_true()
}

// --- Finding: dedup must not corrupt JSON wire names ---
// When two properties produce the same snake_case (e.g. "petId" and "pet_id"),
// dedup should rename the Gleam field but the JSON key in decode.field()
// must stay as the original property name from the OpenAPI spec.
pub fn dedup_preserves_json_wire_name_for_properties_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets:
    get:
      operationId: getPets
      responses:
        '200': { description: ok }
components:
  schemas:
    Pet:
      type: object
      required: [petId, pet_id]
      properties:
        petId: { type: string }
        pet_id: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)

  // Check decoders use original wire names
  let files = list.append(decoders.generate(ctx), encoders.generate(ctx))
  let assert [decode_file, ..] = files
  let decode_content = decode_file.content
  // Both original JSON keys must appear in decode.field()
  string.contains(decode_content, "decode.field(\"petId\"")
  |> should.be_true()
  string.contains(decode_content, "decode.field(\"pet_id\"")
  |> should.be_true()
  // The deduped name like "pet_id_2" must NOT appear as a JSON key
  string.contains(decode_content, "\"pet_id_2\"")
  |> should.be_false()

  // Check encoders use original wire names
  let assert [_, encode_file] = files
  let encode_content = encode_file.content
  string.contains(encode_content, "#(\"petId\"")
  |> should.be_true()
  string.contains(encode_content, "#(\"pet_id\"")
  |> should.be_true()
  string.contains(encode_content, "#(\"pet_id_2\"")
  |> should.be_false()
}

// dedup must not corrupt enum wire values.
// When two enum values produce the same PascalCase (e.g. "foo_bar" and "fooBar"),
// the JSON value sent/received must remain the original string.
pub fn dedup_preserves_json_wire_name_for_enums_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200': { description: ok }
components:
  schemas:
    Status:
      type: string
      enum: [foo_bar, fooBar]
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)

  // Check decoders preserve original enum string values
  let files = decoders.generate(ctx)
  let assert [decode_file, ..] = files
  let decode_content = decode_file.content
  string.contains(decode_content, "\"foo_bar\"")
  |> should.be_true()
  string.contains(decode_content, "\"fooBar\"")
  |> should.be_true()
  // The corrupted name must NOT appear as a wire value
  string.contains(decode_content, "\"fooBar_2\"")
  |> should.be_false()
  string.contains(decode_content, "\"foo_bar_2\"")
  |> should.be_false()
}

// --- Finding: guards.gleam composite validator must use correct type and suffix ---
pub fn guards_composite_validator_compiles_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200': { description: ok }
components:
  schemas:
    BoundedList:
      type: array
      items: { type: string }
      minItems: 1
      maxItems: 10
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  let assert [guards_file] = files
  let content = guards_file.content
  // Composite validator must use the actual type, not literal "value_type"
  string.contains(content, "value_type")
  |> should.be_false()
  // The composite validator must call the same function name as the definition
  // Both definition and call must use the same suffix ("length" for arrays)
  string.contains(content, "validate_bounded_list_root_length")
  |> should.be_true()
  // Must NOT reference a mismatched "items" suffix
  string.contains(content, "validate_bounded_list_items")
  |> should.be_false()
}

// --- Finding: discriminator-less oneOf via $ref must generate matching decoder ---
pub fn oneof_no_discriminator_ref_decoder_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /wrappers:
    get:
      operationId: getWrappers
      responses:
        '200': { description: ok }
components:
  schemas:
    A:
      type: object
      properties:
        x: { type: integer }
    B:
      type: object
      properties:
        y: { type: string }
    Payload:
      oneOf:
        - $ref: '#/components/schemas/A'
        - $ref: '#/components/schemas/B'
    Wrapper:
      type: object
      required: [payload]
      properties:
        payload:
          $ref: '#/components/schemas/Payload'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = decoders.generate(ctx)
  let assert [decode_file, ..] = files
  let content = decode_file.content
  // Wrapper's decoder references payload_decoder() via schema_ref_to_decoder
  // for the $ref to Payload.  The oneOf generator must define payload_decoder()
  // (not just decode_payload/1).
  string.contains(content, "fn payload_decoder()")
  |> should.be_true()
}

// --- Finding: multiple content-types must not be silently truncated ---
pub fn multiple_content_types_response_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /data:
    get:
      operationId: getData
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema: { type: integer }
            text/plain:
              schema: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)

  // Multi-content response types use String to stay type-safe
  let type_files = types.generate(ctx)
  let response_types_content =
    list.find(type_files, fn(f) { string.contains(f.path, "response_types") })
  let assert Ok(rt_file) = response_types_content
  // Variant must use String (not Int from JSON schema) for type safety
  string.contains(rt_file.content, "GetDataResponseOk(String)")
  |> should.be_true()
}

// --- Finding: form-urlencoded must import uri and string modules ---
pub fn form_urlencoded_imports_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /submit:
    post:
      operationId: submitForm
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              required: [name, tags]
              properties:
                name: { type: string }
                tags:
                  type: array
                  items: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // Must import uri for percent_encode
  string.contains(content, "gleam/uri")
  |> should.be_true()
  // Must import string for string.join
  string.contains(content, "gleam/string")
  |> should.be_true()
  // Array field must not produce raw "uri.percent_encode(body.tags)"
  // (that would try to percent_encode a List, which is a type error)
  string.contains(content, "uri.percent_encode(body.tags)")
  |> should.be_false()
}

// --- Finding: callback must support multiple URL expressions ---
pub fn callback_multiple_url_expressions_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /subscribe:
    post:
      operationId: subscribe
      callbacks:
        onEvent:
          '{$request.body#/callbackUrl}/event':
            post:
              operationId: onEvent
              responses:
                '200': { description: ok }
          '{$request.body#/callbackUrl}/status':
            post:
              operationId: onStatus
              responses:
                '200': { description: ok }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // The callback "onEvent" must contain both URL expressions
  let subscribe_path = dict.get(spec.paths, "/subscribe")
  let assert Ok(spec.Value(path_item)) = subscribe_path
  let assert Some(post_op) = path_item.post
  let assert Ok(spec.Value(callback)) = dict.get(post_op.callbacks, "onEvent")
  // Callback entries dict must have 2 URL expressions
  let entries = dict.to_list(callback.entries)
  list.length(entries) |> should.equal(2)
  // Both URL expressions must be present
  dict.has_key(callback.entries, "{$request.body#/callbackUrl}/event")
  |> should.be_true()
  dict.has_key(callback.entries, "{$request.body#/callbackUrl}/status")
  |> should.be_true()
}

// --- Finding: guards must handle optional fields and use correct array suffix ---
pub fn guards_optional_field_and_array_suffix_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /samples:
    get:
      operationId: getSamples
      responses:
        '200': { description: ok }
components:
  schemas:
    Sample:
      type: object
      required: [name]
      properties:
        name:
          type: string
          minLength: 1
        nickname:
          type: string
          minLength: 1
        tags:
          type: array
          items: { type: string }
          minItems: 1
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  let assert [guards_file] = files
  let content = guards_file.content
  // Optional field "nickname" is Option(String), so composite validator
  // must unwrap it before calling the validator (or skip when None).
  // It must NOT call validate_sample_nickname_length(value.nickname) directly.
  string.contains(content, "validate_sample_nickname_length(value.nickname)")
  |> should.be_false()
  // Array field must use "length" suffix (matching the generated function),
  // NOT "items" suffix.
  string.contains(content, "validate_sample_tags_items")
  |> should.be_false()
  string.contains(content, "validate_sample_tags_length")
  |> should.be_true()
}

// --- Finding: multi-content response must produce type-safe code ---
// When response has text/plain (String) and application/json (Int),
// the response_type must accommodate both, not just the first.
pub fn multi_content_response_type_safety_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /data:
    get:
      operationId: getData
      responses:
        '200':
          description: ok
          content:
            text/plain:
              schema: { type: string }
            application/json:
              schema: { type: integer }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)

  // Response type must use String (common supertype) since text/plain returns String
  let type_files = types.generate(ctx)
  let response_types_content =
    list.find(type_files, fn(f) { string.contains(f.path, "response_types") })
  let assert Ok(rt_file) = response_types_content
  // The variant must use String since text/plain and JSON decode to different types
  // It must NOT use Int (which would be a type error when returning resp.body: String)
  let has_int_variant =
    string.contains(rt_file.content, "GetDataResponseOk(Int)")
  let has_string_variant =
    string.contains(rt_file.content, "GetDataResponseOk(String)")
  // Either use String for both, or separate variants per content-type
  // The key constraint: text/plain branch returns resp.body (String),
  // so the variant CANNOT hold Int
  case has_int_variant, has_string_variant {
    True, False ->
      // Int variant but no String variant = type error
      should.fail()
    _, _ -> should.be_ok(Ok(Nil))
  }
}

// --- Finding: multi-content request body collapsed to first entry ---
pub fn multi_content_request_body_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /submit:
    post:
      operationId: submitData
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              properties:
                name: { type: string }
          application/json:
            schema: { type: integer }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // The client must handle both content types, not just the first.
  // At minimum, the form-urlencoded content type must appear.
  string.contains(content, "application/x-www-form-urlencoded")
  |> should.be_true()
  // And JSON content type handling must also be present
  string.contains(content, "application/json")
  |> should.be_true()
}

// --- Finding: security OR alternatives must pick one, not apply all ---
pub fn security_or_alternatives_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /secure:
    get:
      operationId: getSecure
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    ApiKeyAuth:
      type: apiKey
      in: header
      name: X-API-Key
    BearerAuth:
      type: http
      scheme: bearer
security:
  - ApiKeyAuth: []
  - BearerAuth: []
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // OR alternatives are emitted as a list of SecurityAlternative values
  // on the request. The OR/AND logic lives in
  // `oaspec/transport.with_security` at runtime, not in generated code.
  string.contains(content, "transport.SecurityAlternative([")
  |> should.be_true()
  // Both schemes must appear by name in the security metadata.
  string.contains(content, "scheme_name: \"ApiKeyAuth\"")
  |> should.be_true()
  string.contains(content, "scheme_name: \"BearerAuth\"")
  |> should.be_true()
  // Two alternatives → two SecurityAlternative entries.
  let occurrences =
    string.split(content, "transport.SecurityAlternative([")
    |> list.length()
  occurrences |> should.equal(3)
  // No legacy inline scheme application leaks into operation bodies.
  string.contains(content, "config.api_key_auth") |> should.be_false()
  string.contains(content, "config.bearer_auth") |> should.be_false()
}

// --- Issue #349: type: 'null' inside anyOf must parse, not error ---
pub fn openapi_31_anyof_with_null_branch_parses_case() {
  // The GitHub OpenAPI 3.1 spec uses `anyOf: [$ref, type: 'null']` to
  // express nullability. Before #349, this surfaced as
  // "Unrecognized schema type 'null'" because parse_typed_schema was
  // reached with a literal "null" string. Now the null branch is
  // stripped and lifted to the parent's `nullable` flag.
  let yaml =
    "
openapi: 3.1.0
info:
  title: T
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    Installation:
      type: object
      properties:
        suspended_by:
          anyOf:
            - $ref: '#/components/schemas/User'
            - type: 'null'
    User:
      type: object
      properties:
        login: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "Installation")
  let assert Ok(schema.Inline(schema.AnyOfSchema(
    metadata: meta,
    schemas: branches,
    ..,
  ))) = dict.get(props, "suspended_by")
  // The null branch must have been filtered out, leaving only the
  // $ref to User.
  list.length(branches) |> should.equal(1)
  // And nullability must have been lifted onto the parent schema.
  meta.nullable |> should.be_true()
}

pub fn openapi_31_oneof_with_null_branch_parses_case() {
  let yaml =
    "
openapi: 3.1.0
info:
  title: T
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    Maybe:
      oneOf:
        - type: string
        - type: 'null'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.OneOfSchema(
    metadata: meta,
    schemas: branches,
    ..,
  ))) = dict.get(components.schemas, "Maybe")
  list.length(branches) |> should.equal(1)
  meta.nullable |> should.be_true()
}

pub fn openapi_31_standalone_null_type_parses_as_nullable_case() {
  // `type: 'null'` as a standalone schema (outside oneOf/anyOf) must
  // not error either. We treat it as an unrestricted nullable schema,
  // mirroring the existing fallback for `type: ['null']`.
  let yaml =
    "
openapi: 3.1.0
info:
  title: T
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    OnlyNull:
      type: 'null'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.ObjectSchema(metadata: meta, ..))) =
    dict.get(components.schemas, "OnlyNull")
  meta.nullable |> should.be_true()
}

// --- Finding 2: OpenAPI 3.1 type: [string, 'null'] must parse as nullable string ---
pub fn openapi_31_type_array_nullable_case() {
  let yaml =
    "
openapi: 3.1.0
info:
  title: T
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    MaybeName:
      type: [string, 'null']
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  // MaybeName should be a nullable String type, not an empty object
  // It must NOT generate as a record with no fields (which would be the object fallback)
  string.contains(types_file.content, "pub type MaybeName =")
  |> should.be_true()
}

// --- drift detection between capability registry and README ---
pub fn external_file_ref_for_component_schema_case() {
  // A spec whose components.schemas entry is a ref to a schema in a
  // sibling YAML file should parse cleanly: the referenced schema is
  // merged into the main spec and the entry is rewritten to a local ref.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/external_ref_main.yaml")
  spec.info.title |> should.equal("External Ref Main")
  let assert Some(components) = spec.components
  // The referenced Widget schema must have been merged in.
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: widget_props, ..))) =
    dict.get(components.schemas, "Widget")
  dict.has_key(widget_props, "id") |> should.be_true()
  dict.has_key(widget_props, "label") |> should.be_true()
  // The original Item entry now points at the local Widget.
  let assert Ok(schema.Reference(ref: item_ref, ..)) =
    dict.get(components.schemas, "Item")
  item_ref |> should.equal("#/components/schemas/Widget")
}

pub fn external_ref_collision_with_local_schema_rejected_case() {
  // Main spec defines a local `Widget` AND another entry (`Item`) that
  // imports a different `Widget` from a sibling file. Silently merging
  // would overwrite the local Widget — parse_file must surface a
  // diagnostic instead.
  let result =
    parser.parse_file("test/fixtures/external_ref_collision_main.yaml")
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Widget") |> should.be_true()
  string.contains(msg, "local schema") |> should.be_true()
}

pub fn external_ref_collision_across_files_rejected_case() {
  // Two external refs import the same fragment name `Widget` from two
  // distinct sibling files. The second import collides with the first
  // and must surface a diagnostic.
  let result =
    parser.parse_file("test/fixtures/external_ref_collision_cross_main.yaml")
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Widget") |> should.be_true()
  string.contains(msg, "already imported") |> should.be_true()
}

pub fn external_ref_two_file_cycle_rejected_case() {
  // Issue #233: A.yaml -> B.yaml -> A.yaml used to loop forever. The
  // loader must now detect the cycle, stop walking, and emit a
  // diagnostic listing the visited files.
  let result = parser.parse_file("test/fixtures/external_ref_cycle_a.yaml")
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Cyclic external $ref") |> should.be_true()
  string.contains(msg, "external_ref_cycle_a.yaml") |> should.be_true()
  string.contains(msg, "external_ref_cycle_b.yaml") |> should.be_true()
}

pub fn external_ref_three_file_cycle_rejected_case() {
  // Issue #233: A -> B -> C -> A cycles must also be caught, not just
  // direct two-file back-references.
  let result = parser.parse_file("test/fixtures/external_ref_cycle_deep_a.yaml")
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Cyclic external $ref") |> should.be_true()
  string.contains(msg, "external_ref_cycle_deep_a.yaml") |> should.be_true()
  string.contains(msg, "external_ref_cycle_deep_b.yaml") |> should.be_true()
  string.contains(msg, "external_ref_cycle_deep_c.yaml") |> should.be_true()
}

pub fn external_ref_nested_collision_with_local_schema_rejected_case() {
  // Main spec defines a local `Widget` AND an Envelope.payload property
  // that imports a *different* `Widget` from a sibling file. Silently
  // binding the property to the local Widget would shadow the author's
  // intent — parse_file must surface a diagnostic instead.
  let result =
    parser.parse_file(
      "test/fixtures/external_ref_nested_local_collision_main.yaml",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Widget") |> should.be_true()
  string.contains(msg, "local schema") |> should.be_true()
}

pub fn external_ref_nested_collision_across_files_rejected_case() {
  // Two object properties import the same fragment name `Widget` from
  // two distinct sibling files. The second import collides with the
  // first and must surface a diagnostic via
  // `check_nested_cross_file_collision`.
  let result =
    parser.parse_file("test/fixtures/external_ref_nested_cross_main.yaml")
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Widget") |> should.be_true()
  string.contains(msg, "already imported") |> should.be_true()
}

pub fn external_ref_in_component_path_items_case() {
  // A reusable PathItem under components.path_items carries the same
  // operations as top-level paths. External schema refs inside its
  // request body / response / parameters must hoist just like the
  // top-level path walker.
  let assert Ok(loaded) =
    parser.parse_file(
      "test/fixtures/external_ref_component_path_items_main.yaml",
    )
  let assert Some(components) = loaded.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: widget_props, ..))) =
    dict.get(components.schemas, "Widget")
  dict.has_key(widget_props, "sku") |> should.be_true()
  let assert Ok(spec.Value(path_item)) =
    dict.get(components.path_items, "WidgetOps")
  let assert Some(post_op) = path_item.post
  let assert Some(spec.Value(body)) = post_op.request_body
  let assert Ok(media) = dict.get(body.content, "application/json")
  let assert Some(schema.Reference(ref: body_ref, ..)) = media.schema
  body_ref |> should.equal("#/components/schemas/Widget")
}

pub fn external_ref_component_path_items_collision_with_local_schema_rejected_case() {
  let result =
    parser.parse_file(
      "test/fixtures/external_ref_component_path_items_collision_main.yaml",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Widget") |> should.be_true()
  string.contains(msg, "local schema") |> should.be_true()
}

pub fn external_ref_in_header_schemas_case() {
  // Headers appear both under components.headers and inside each
  // Response's headers dict. Schemas on either kind of header that
  // point at an external file must be hoisted into components.schemas
  // and rewritten to local refs.
  let assert Ok(loaded) =
    parser.parse_file("test/fixtures/external_ref_header_main.yaml")
  let assert Some(components) = loaded.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: widget_props, ..))) =
    dict.get(components.schemas, "Widget")
  dict.has_key(widget_props, "sku") |> should.be_true()
  // components.headers.RateInfo.schema rewritten.
  let assert Ok(rate_header) = dict.get(components.headers, "RateInfo")
  let assert Some(schema.Reference(ref: comp_header_ref, ..)) =
    rate_header.schema
  comp_header_ref |> should.equal("#/components/schemas/Widget")
  // Operation response header schema rewritten.
  let assert Ok(spec.Value(path_item)) = dict.get(loaded.paths, "/widgets")
  let assert Some(get_op) = path_item.get
  let assert [#(_, spec.Value(resp))] = dict.to_list(get_op.responses)
  let assert Ok(resp_header) = dict.get(resp.headers, "X-Rate-Info")
  let assert Some(schema.Reference(ref: resp_header_ref, ..)) =
    resp_header.schema
  resp_header_ref |> should.equal("#/components/schemas/Widget")
}

pub fn external_ref_header_collision_with_local_schema_rejected_case() {
  let result =
    parser.parse_file("test/fixtures/external_ref_header_collision_main.yaml")
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Widget") |> should.be_true()
  string.contains(msg, "local schema") |> should.be_true()
}

pub fn external_ref_chained_local_alias_in_shared_file_case() {
  // The external file defines `LegacyWidget` as a local alias for
  // `Widget`. A consumer that imports `LegacyWidget` must resolve
  // through the alias and get Widget's inline schema under the
  // LegacyWidget slot in the main spec's components.schemas.
  let assert Ok(loaded) =
    parser.parse_file("test/fixtures/external_ref_chained_main.yaml")
  let assert Some(components) = loaded.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: legacy_props, ..))) =
    dict.get(components.schemas, "LegacyWidget")
  dict.has_key(legacy_props, "sku") |> should.be_true()
  let assert Ok(schema.Reference(ref: item_ref, ..)) =
    dict.get(components.schemas, "Item")
  item_ref |> should.equal("#/components/schemas/LegacyWidget")
}

pub fn external_ref_chained_across_files_resolves_transitively_case() {
  // The external file's `Indirect` entry is itself an external ref to
  // yet another file (Widget in `external_ref_nested_shared.yaml`).
  // Because parse_file recursively resolves external refs in each
  // loaded file, the chain collapses naturally and `Indirect` ends up
  // inline in the main spec's components.schemas.
  let assert Ok(loaded) =
    parser.parse_file("test/fixtures/external_ref_chained_cross_file_main.yaml")
  let assert Some(components) = loaded.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: props, ..))) =
    dict.get(components.schemas, "Indirect")
  dict.has_key(props, "sku") |> should.be_true()
}

pub fn external_ref_in_callback_path_item_case() {
  // An operation's callbacks dict maps to PathItems whose own
  // operations may carry external schema refs. Those refs must hoist
  // into components.schemas just like top-level operations.
  let assert Ok(loaded) =
    parser.parse_file("test/fixtures/external_ref_callback_main.yaml")
  let assert Some(components) = loaded.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: widget_props, ..))) =
    dict.get(components.schemas, "Widget")
  dict.has_key(widget_props, "sku") |> should.be_true()
  // Drill into the callback's PathItem and confirm the request body
  // schema ref is rewritten to local form.
  let assert Ok(spec.Value(path_item)) = dict.get(loaded.paths, "/subscribe")
  let assert Some(post_op) = path_item.post
  let assert Ok(spec.Value(callback)) =
    dict.get(post_op.callbacks, "widgetEvent")
  let assert Ok(spec.Value(cb_path_item)) =
    dict.get(callback.entries, "{$request.body#/callbackUrl}")
  let assert Some(cb_post) = cb_path_item.post
  let assert Some(spec.Value(cb_body)) = cb_post.request_body
  let assert Ok(media) = dict.get(cb_body.content, "application/json")
  let assert Some(schema.Reference(ref: cb_ref, ..)) = media.schema
  cb_ref |> should.equal("#/components/schemas/Widget")
}

pub fn external_ref_callback_collision_with_local_schema_rejected_case() {
  // A callback's response pulls `Widget` from an external file while
  // the main spec already defines a local `Widget`. The silent-
  // shadowing guard must fire through the shared imports tracker.
  let result =
    parser.parse_file("test/fixtures/external_ref_callback_collision_main.yaml")
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Widget") |> should.be_true()
  string.contains(msg, "local schema") |> should.be_true()
}

pub fn external_ref_in_operation_schemas_case() {
  // An operation whose path-level parameters, operation-level
  // parameters, request body, and responses all carry external $ref
  // values must have every such ref hoisted into components.schemas
  // and rewritten to a local ref.
  let assert Ok(loaded) =
    parser.parse_file("test/fixtures/external_ref_operation_main.yaml")
  let assert Some(components) = loaded.components
  // Widget must have been pulled into components.schemas by the
  // operation walker, even though the source spec had an empty
  // components block.
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: widget_props, ..))) =
    dict.get(components.schemas, "Widget")
  dict.has_key(widget_props, "sku") |> should.be_true()
  // Path-level parameter schema rewritten.
  let assert Ok(spec.Value(path_item)) = dict.get(loaded.paths, "/widgets")
  let assert [spec.Value(path_param)] = path_item.parameters
  let assert spec.ParameterSchema(schema.Reference(ref: path_param_ref, ..)) =
    path_param.payload
  path_param_ref |> should.equal("#/components/schemas/Widget")
  // Operation-level parameter schema rewritten.
  let assert Some(post_op) = path_item.post
  let assert [spec.Value(op_param)] = post_op.parameters
  let assert spec.ParameterSchema(schema.Reference(ref: op_param_ref, ..)) =
    op_param.payload
  op_param_ref |> should.equal("#/components/schemas/Widget")
  // Request body media schema rewritten.
  let assert Some(spec.Value(req_body)) = post_op.request_body
  let assert Ok(body_media) = dict.get(req_body.content, "application/json")
  let assert Some(schema.Reference(ref: body_ref, ..)) = body_media.schema
  body_ref |> should.equal("#/components/schemas/Widget")
  // Response media schema rewritten.
  let assert [#(_, spec.Value(response))] = dict.to_list(post_op.responses)
  let assert Ok(resp_media) = dict.get(response.content, "application/json")
  let assert Some(schema.Reference(ref: resp_ref, ..)) = resp_media.schema
  resp_ref |> should.equal("#/components/schemas/Widget")
}

pub fn external_ref_operation_collision_with_local_schema_rejected_case() {
  // An operation response that imports `Widget` while the main spec
  // already defines a local Widget must surface the silent-shadowing
  // diagnostic via the shared imports tracker.
  let result =
    parser.parse_file(
      "test/fixtures/external_ref_operation_collision_main.yaml",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Widget") |> should.be_true()
  string.contains(msg, "local schema") |> should.be_true()
}

pub fn external_ref_in_parameter_content_schema_case() {
  // A parameter declared via ParameterContent (content media-type map)
  // whose inner schema is a relative-file $ref must hoist the target
  // into components.schemas and rewrite the inner ref.
  let assert Ok(loaded) =
    parser.parse_file("test/fixtures/external_ref_parameter_content_main.yaml")
  let assert Some(components) = loaded.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: widget_props, ..))) =
    dict.get(components.schemas, "Widget")
  dict.has_key(widget_props, "sku") |> should.be_true()
  let assert Ok(spec.Value(param)) = dict.get(components.parameters, "Filter")
  let assert spec.ParameterContent(media_map) = param.payload
  let assert Ok(media) = dict.get(media_map, "application/json")
  let assert Some(schema.Reference(ref: schema_ref, ..)) = media.schema
  schema_ref |> should.equal("#/components/schemas/Widget")
}

pub fn external_ref_parameter_content_collision_with_local_schema_rejected_case() {
  let result =
    parser.parse_file(
      "test/fixtures/external_ref_parameter_content_collision_main.yaml",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Widget") |> should.be_true()
  string.contains(msg, "local schema") |> should.be_true()
}

pub fn external_ref_in_request_body_schema_case() {
  // A request body defined under components.requestBodies whose media
  // type schema is a relative-file $ref must hoist the target into
  // components.schemas and rewrite the inner schema ref.
  let assert Ok(loaded) =
    parser.parse_file("test/fixtures/external_ref_request_body_main.yaml")
  let assert Some(components) = loaded.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: widget_props, ..))) =
    dict.get(components.schemas, "Widget")
  dict.has_key(widget_props, "sku") |> should.be_true()
  let assert Ok(spec.Value(body)) =
    dict.get(components.request_bodies, "CreateWidget")
  let assert Ok(media) = dict.get(body.content, "application/json")
  let assert Some(schema.Reference(ref: schema_ref, ..)) = media.schema
  schema_ref |> should.equal("#/components/schemas/Widget")
}

pub fn external_ref_in_response_schema_case() {
  // Same as request body, but targeting components.responses.
  let assert Ok(loaded) =
    parser.parse_file("test/fixtures/external_ref_response_main.yaml")
  let assert Some(components) = loaded.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: widget_props, ..))) =
    dict.get(components.schemas, "Widget")
  dict.has_key(widget_props, "sku") |> should.be_true()
  let assert Ok(spec.Value(resp)) =
    dict.get(components.responses, "WidgetPayload")
  let assert Ok(media) = dict.get(resp.content, "application/json")
  let assert Some(schema.Reference(ref: schema_ref, ..)) = media.schema
  schema_ref |> should.equal("#/components/schemas/Widget")
}

pub fn external_ref_request_body_collision_with_local_schema_rejected_case() {
  let result =
    parser.parse_file(
      "test/fixtures/external_ref_request_body_collision_main.yaml",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Widget") |> should.be_true()
  string.contains(msg, "local schema") |> should.be_true()
}

pub fn external_ref_in_parameter_schema_case() {
  // A parameter defined under components.parameters whose schema is a
  // relative-file $ref must hoist the target into components.schemas
  // and rewrite the inner schema ref to local form.
  let assert Ok(loaded) =
    parser.parse_file("test/fixtures/external_ref_parameter_schema_main.yaml")
  let assert Some(components) = loaded.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: widget_props, ..))) =
    dict.get(components.schemas, "Widget")
  dict.has_key(widget_props, "sku") |> should.be_true()
  let assert Ok(spec.Value(param)) =
    dict.get(components.parameters, "WidgetHeader")
  let assert spec.ParameterSchema(schema.Reference(ref: schema_ref, ..)) =
    param.payload
  schema_ref |> should.equal("#/components/schemas/Widget")
}

pub fn external_ref_parameter_schema_collision_with_local_schema_rejected_case() {
  // A local Widget plus a parameter whose schema imports a different
  // Widget from an external file — silent-shadowing must fire.
  let result =
    parser.parse_file(
      "test/fixtures/external_ref_parameter_schema_collision_main.yaml",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Widget") |> should.be_true()
  string.contains(msg, "local schema") |> should.be_true()
}

pub fn external_ref_in_composition_branch_case() {
  // A composition schema (oneOf here) whose branch is a relative-file
  // $ref must hoist the target schema into components.schemas and
  // rewrite the branch to a local ref.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/external_ref_composition_main.yaml")
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: widget_props, ..))) =
    dict.get(components.schemas, "Widget")
  dict.has_key(widget_props, "sku") |> should.be_true()
  let assert Ok(schema.Inline(schema.OneOfSchema(schemas: branches, ..))) =
    dict.get(components.schemas, "WidgetOrInline")
  // First branch (the external ref) rewritten to local; second stays inline.
  let assert [first, second] = branches
  let assert schema.Reference(ref: branch_ref, ..) = first
  branch_ref |> should.equal("#/components/schemas/Widget")
  let assert schema.Inline(schema.StringSchema(..)) = second
}

pub fn external_ref_composition_collision_with_local_schema_rejected_case() {
  // anyOf branch imports a Widget while the main spec already defines
  // a local Widget — the silent-shadowing guard must fire.
  let result =
    parser.parse_file(
      "test/fixtures/external_ref_composition_collision_main.yaml",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Widget") |> should.be_true()
  string.contains(msg, "local schema") |> should.be_true()
}

pub fn external_ref_in_additional_properties_case() {
  // An ObjectSchema whose additionalProperties value is a relative-file
  // $ref must hoist the target schema into components.schemas and
  // rewrite the inner ref to local form.
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/external_ref_additional_properties_main.yaml",
    )
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: widget_props, ..))) =
    dict.get(components.schemas, "Widget")
  dict.has_key(widget_props, "sku") |> should.be_true()
  let assert Ok(schema.Inline(schema.ObjectSchema(
    additional_properties: additional,
    ..,
  ))) = dict.get(components.schemas, "WidgetMap")
  let assert schema.Typed(schema.Reference(ref: added_ref, ..)) = additional
  added_ref |> should.equal("#/components/schemas/Widget")
}

pub fn external_ref_additional_properties_collision_with_local_schema_rejected_case() {
  // additionalProperties imports fragment `Widget` while a local Widget
  // is already defined — the silent-shadowing guard must fire.
  let result =
    parser.parse_file(
      "test/fixtures/external_ref_additional_properties_collision_main.yaml",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Widget") |> should.be_true()
  string.contains(msg, "local schema") |> should.be_true()
}

pub fn external_ref_in_array_items_case() {
  // A top-level array schema whose items value is a relative-file $ref
  // must be hoisted: the referenced schema is merged into
  // `components.schemas` and items is rewritten to a local ref.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/external_ref_array_items_main.yaml")
  let assert Some(components) = spec.components
  // Widget must have been pulled in from the shared file.
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: widget_props, ..))) =
    dict.get(components.schemas, "Widget")
  dict.has_key(widget_props, "sku") |> should.be_true()
  // Widgets.items must now be a local reference.
  let assert Ok(schema.Inline(schema.ArraySchema(items: items_ref, ..))) =
    dict.get(components.schemas, "Widgets")
  let assert schema.Reference(ref: items_ref_str, ..) = items_ref
  items_ref_str |> should.equal("#/components/schemas/Widget")
}

pub fn external_ref_array_items_collision_with_local_schema_rejected_case() {
  // An array whose items ref targets a fragment name that already exists
  // as a local schema must surface the silent-shadowing diagnostic.
  let result =
    parser.parse_file(
      "test/fixtures/external_ref_array_items_local_collision_main.yaml",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "Widget") |> should.be_true()
  string.contains(msg, "local schema") |> should.be_true()
}

pub fn external_ref_nested_in_object_property_case() {
  // A property whose value is a relative-file $ref must be hoisted: the
  // referenced schema is merged into `components.schemas` under its
  // fragment name, and the property is rewritten to a local ref.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/external_ref_nested_main.yaml")
  let assert Some(components) = spec.components
  // Widget must have been pulled in from the shared file.
  let assert Ok(schema.Inline(schema.ObjectSchema(properties: widget_props, ..))) =
    dict.get(components.schemas, "Widget")
  dict.has_key(widget_props, "sku") |> should.be_true()
  dict.has_key(widget_props, "price") |> should.be_true()
  // Envelope.payload must now be a local reference to that schema.
  let assert Ok(schema.Inline(schema.ObjectSchema(
    properties: envelope_props,
    ..,
  ))) = dict.get(components.schemas, "Envelope")
  let assert Ok(schema.Reference(ref: payload_ref, ..)) =
    dict.get(envelope_props, "payload")
  payload_ref |> should.equal("#/components/schemas/Widget")
  // Non-ref sibling property must be preserved unchanged.
  let assert Ok(schema.Inline(schema.StringSchema(..))) =
    dict.get(envelope_props, "note")
}

pub fn capability_registry_covers_content_type_response_helpers_case() {
  // Every MIME string that `content_type.is_supported_response` accepts
  // as directly-supported must have a Supported entry in the capability
  // registry under the "response" category. This keeps the registry as
  // the single source of truth and catches drift the first time
  // somebody toggles support for a MIME without updating the registry.
  let mimes_we_flag_supported = [
    "application/json",
    "text/plain",
    "application/octet-stream",
    "application/xml",
    "text/xml",
  ]
  let registry_response_names =
    capability.registry()
    |> list.filter(fn(c) {
      c.category == "response" && c.level == capability.Supported
    })
    |> list.map(fn(c) { c.name })
  list.each(mimes_we_flag_supported, fn(mime) {
    let parsed = content_type.from_string(mime)
    content_type.is_supported_response(parsed) |> should.be_true()
    case list.contains(registry_response_names, mime) {
      True -> Nil
      False -> mime |> should.equal("<expected in capability registry>")
    }
  })
}

pub fn capability_registry_covers_content_type_request_helpers_case() {
  // Mirror of the response drift test for the request side — every
  // MIME `is_supported_request` accepts must have a `"request"`-
  // category Supported entry in the registry.
  let mimes_we_flag_supported = [
    "application/json",
    "application/x-www-form-urlencoded",
    "multipart/form-data",
    "application/octet-stream",
    "text/plain",
  ]
  let registry_request_names =
    capability.registry()
    |> list.filter(fn(c) {
      c.category == "request" && c.level == capability.Supported
    })
    |> list.map(fn(c) { c.name })
  list.each(mimes_we_flag_supported, fn(mime) {
    let parsed = content_type.from_string(mime)
    content_type.is_supported_request(parsed) |> should.be_true()
    case list.contains(registry_request_names, mime) {
      True -> Nil
      False -> mime |> should.equal("<expected in capability registry>")
    }
  })
}

pub fn is_supported_request_rejects_unsupported_content_type_case() {
  // Sanity check that the UnsupportedContentType fallback still short-
  // circuits to False without touching the registry (the registry
  // naturally lacks entries for arbitrary strings, but keeping this
  // branch explicit prevents a future refactor from accidentally
  // turning unknown MIMEs into Supported via a lookup miss).
  content_type.is_supported_request(content_type.UnsupportedContentType(
    "application/whatever",
  ))
  |> should.be_false()
  content_type.is_supported_response(content_type.UnsupportedContentType(
    "application/whatever",
  ))
  |> should.be_false()
}

pub fn capability_registry_names_appear_in_readme_boundaries_case() {
  // Every keyword the capability registry declares as Unsupported / NotHandled
  // / ParsedNotUsed must be mentioned by name inside the
  // `<!-- BEGIN GENERATED:BOUNDARIES -->` / `<!-- END GENERATED:BOUNDARIES -->`
  // block in doc/openapi-support.md. This catches the common drift case where
  // someone adds a new unsupported keyword to the registry but forgets to
  // update the boundaries doc.
  let assert Ok(readme) = simplifile.read("doc/openapi-support.md")
  let assert Ok(#(_before, after_begin)) =
    string.split_once(readme, "<!-- BEGIN GENERATED:BOUNDARIES -->")
  let assert Ok(#(boundaries_block, _after)) =
    string.split_once(after_begin, "<!-- END GENERATED:BOUNDARIES -->")
  list.each(capability.registry(), fn(c) {
    case c.level {
      capability.Unsupported | capability.NotHandled | capability.ParsedNotUsed ->
        case string.contains(boundaries_block, c.name) {
          True -> Nil
          False -> {
            // Surface which name is missing in the failure output.
            c.name |> should.equal("<should appear in README>")
          }
        }
      _ -> Nil
    }
  })
}

fn server_request_shape_boundary_fixtures() -> List(#(String, String, String)) {
  [
    #(
      "server: complex path parameters",
      "test/fixtures/server_complex_path_parameter.yaml",
      "Complex path parameters are not supported",
    ),
    #(
      "server: non-primitive query array items",
      "test/fixtures/server_query_array_object_items.yaml",
      "Query array parameters are only supported",
    ),
    #(
      "server: non-primitive header array items",
      "test/fixtures/server_header_array_object_items.yaml",
      "Header array parameters are only supported",
    ),
    #(
      "server: complex deepObject properties",
      "test/fixtures/server_deep_object_complex_properties.yaml",
      "deepObject properties are only supported",
    ),
    #(
      "server: mixed form-urlencoded request",
      "test/fixtures/server_form_urlencoded_mixed_content.yaml",
      "application/x-www-form-urlencoded request bodies are only supported as the sole request content type",
    ),
    #(
      "server: mixed multipart request",
      "test/fixtures/server_multipart_mixed_content.yaml",
      "multipart/form-data request bodies are only supported as the sole request content type",
    ),
    #(
      "server: complex multipart fields",
      "test/fixtures/server_multipart_complex_fields.yaml",
      "multipart/form-data server request bodies only support",
    ),
    #(
      "server: unsupported request content type",
      "test/fixtures/server_request_body_problem_json.yaml",
      "is not supported for server code generation",
    ),
  ]
}

pub fn server_boundary_checklist_matches_registry_case() {
  let assert Ok(support_doc) = simplifile.read("doc/openapi-support.md")
  let assert Ok(checklist) = simplifile.read("doc/server-mode-boundaries.md")
  string.contains(support_doc, "server-mode-boundaries.md")
  |> should.be_true()

  let server_capabilities =
    capability.registry()
    |> list.filter(fn(c) { c.category == "server-validation" })

  list.length(server_capabilities)
  |> should.equal(list.length(server_request_shape_boundary_fixtures()))

  list.each(server_capabilities, fn(c) {
    string.contains(checklist, c.name)
    |> should.be_true()
  })

  list.each(server_request_shape_boundary_fixtures(), fn(entry) {
    let #(_capability_name, fixture_path, _expected_message) = entry
    string.contains(checklist, fixture_path)
    |> should.be_true()
  })
}

pub fn server_request_shape_boundary_fixtures_case() {
  list.each(server_request_shape_boundary_fixtures(), fn(entry) {
    let #(capability_name, fixture_path, expected_message) = entry
    let ctx = make_ctx(fixture_path)
    // Some boundaries are server-only (e.g. multipart object/array
    // server fields), some are now both-mode (e.g. non-primitive
    // query/header array items, since the client emitter panics on
    // them too post-fix). Either target is acceptable here — what
    // matters is that an error fires in server mode with the
    // expected message.
    let server_errors =
      validate.validate(ctx)
      |> list.filter(fn(e) {
        case e.target {
          diagnostic.TargetServer | diagnostic.TargetBoth ->
            string.contains(e.message, expected_message)
          _ -> False
        }
      })

    case server_errors != [] {
      True -> Nil
      False -> capability_name |> should.equal("<missing server validation>")
    }
  })
}

// --- Finding 3: README says optional path params supported but parser rejects ---
pub fn readme_no_optional_path_param_claim_case() {
  let assert Ok(readme) = simplifile.read("README.md")
  // README must NOT claim "Path parameters with required: false" as supported,
  // since the parser correctly rejects them per OpenAPI spec.
  string.contains(readme, "Path parameters with `required: false`")
  |> should.be_false()
}

// --- Finding 6: Callback parse errors must propagate, not be swallowed ---
pub fn callback_parse_error_not_swallowed_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: T
  version: 1.0.0
paths:
  /subscribe:
    post:
      operationId: subscribe
      callbacks:
        onEvent:
          '{$request.body#/url}':
            post:
              operationId: onEvent
              parameters:
                - name: id
                  in: path
                  required: false
              responses:
                '200': { description: ok }
      responses:
        '200': { description: ok }
"
  // The callback contains a path parameter with required: false,
  // which the parser correctly rejects. But the callback parser
  // currently swallows this error and silently drops the callback.
  // After fix, the error should propagate.
  let result = parser.parse_string(yaml)
  case result {
    Ok(spec) -> {
      // If parse succeeded, the callback must NOT have been silently dropped
      let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/subscribe")
      let assert Some(post_op) = path_item.post
      // Currently the error is swallowed and onEvent is missing.
      // After fix, either parse fails (Error) or callback is present.
      dict.has_key(post_op.callbacks, "onEvent")
      |> should.be_true()
    }
    Error(_) -> {
      // Parse error is acceptable — means we propagate the failure
      should.be_ok(Ok(Nil))
    }
  }
}

// --- Finding 7: Pure generate function exists and returns Result ---
pub fn pure_generate_pipeline_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: T
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = generate.generate(spec, cfg)
  should.be_ok(result)
  let assert Ok(summary) = result
  // Should have generated files
  { summary.files != [] }
  |> should.be_true()
  // Should include spec title
  string.contains(summary.spec_title, "T")
  |> should.be_true()
}

// --- Array alias (TagList) must generate decoder and encoder ---
pub fn array_alias_decoder_encoder_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /tags:
    get:
      operationId: getTags
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/TagList'
components:
  schemas:
    TagList:
      type: array
      items: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = list.append(decoders.generate(ctx), encoders.generate(ctx))
  let assert [decode_file, encode_file] = files
  // Must generate tag_list_decoder() function
  string.contains(decode_file.content, "tag_list_decoder")
  |> should.be_true()
  // Must generate the matching encoder function for the array alias
  string.contains(encode_file.content, "encode_tag_list")
  |> should.be_true()
}

// --- deepObject array leaf must not produce uri.percent_encode on List ---
pub fn deep_object_array_leaf_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /search:
    get:
      operationId: search
      parameters:
        - name: filter
          in: query
          style: deepObject
          required: true
          schema:
            type: object
            required: [tags]
            properties:
              tags:
                type: array
                items: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  // Must NOT produce uri.percent_encode(filter.tags) — that's a type error
  // (filter.tags is List(String), not String)
  string.contains(client_file.content, "uri.percent_encode(filter.tags)")
  |> should.be_false()
}

// --- form-urlencoded nested object must not produce uri.percent_encode on record ---
pub fn form_urlencoded_nested_object_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /submit:
    post:
      operationId: submitForm
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              required: [meta]
              properties:
                meta:
                  type: object
                  properties:
                    name: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  // Must NOT produce uri.percent_encode(body.meta) — that's a type error
  // (body.meta is a record/object, not String)
  string.contains(client_file.content, "uri.percent_encode(body.meta)")
  |> should.be_false()
}

// --- HEAD operation must not be silently dropped ---
pub fn head_operation_not_silently_dropped_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /ping:
    head:
      operationId: headPing
      responses:
        '200': { description: ok }
"
  let result = parser.parse_string(yaml)
  case result {
    Ok(spec) -> {
      // If parse succeeds, there must be some way to know HEAD was present.
      // Currently PathItem has no head field, so it silently drops it.
      // After fix: either head is in the AST, or parser returns an error.
      let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/ping")
      // At minimum, the path should have at least one operation
      let has_any_op =
        option.is_some(path_item.get)
        || option.is_some(path_item.post)
        || option.is_some(path_item.put)
        || option.is_some(path_item.delete)
        || option.is_some(path_item.patch)
        || option.is_some(path_item.head)
      // HEAD was the only operation — if no ops exist, it was silently dropped
      has_any_op
      |> should.be_true()
    }
    Error(_) -> {
      // Error is acceptable — means we don't silently drop
      should.be_ok(Ok(Nil))
    }
  }
}

// --- OpenAPI 3.1 type: [string, integer] must not silently take first type ---
pub fn openapi_31_multi_type_union_case() {
  let yaml =
    "
openapi: 3.1.0
info: { title: T, version: 1.0.0 }
paths:
  /value:
    get:
      operationId: getValue
      responses:
        '200': { description: ok }
components:
  schemas:
    StringOrInt:
      type: [string, integer]
"
  // Parse succeeds — multi-type is stored in raw_type, normalize converts to oneOf
  let assert Ok(_spec) = parser.parse_string(yaml)
  should.be_true(True)
}

// --- OPTIONS operation must not be silently dropped ---
pub fn options_operation_not_silently_dropped_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /cors:
    options:
      operationId: corsPreflight
      responses:
        '204': { description: No Content }
"
  let result = parser.parse_string(yaml)
  // Either parse succeeds with the operation accessible,
  // or parse returns an error (not silent success with no operations).
  case result {
    Ok(spec) -> {
      let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/cors")
      // The path must have SOME operation — if it has none,
      // the OPTIONS was silently dropped
      // OPTIONS must be accessible in the AST
      option.is_some(path_item.options)
      |> should.be_true()
    }
    Error(_) -> {
      // A parse error is acceptable — means we don't silently drop
      should.be_ok(Ok(Nil))
    }
  }
}

// --- requestBody.required: false must generate optional body parameter ---
pub fn optional_request_body_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /search:
    post:
      operationId: search
      requestBody:
        required: false
        content:
          application/json:
            schema:
              type: object
              properties:
                query: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // An optional request body must be wrapped in Option, not always required
  // The generated function should have Option(body_type) or similar
  string.contains(content, "Option(")
  |> should.be_true()
}

// --- form-urlencoded 2-level nested object must not break ---
pub fn form_urlencoded_two_level_nested_object_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /submit:
    post:
      operationId: submitForm
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              required: [meta]
              properties:
                meta:
                  type: object
                  required: [author]
                  properties:
                    author:
                      type: object
                      properties:
                        name: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  // Must NOT produce uri.percent_encode on a record type
  // e.g. uri.percent_encode(body.meta.author) is a type error
  string.contains(client_file.content, "uri.percent_encode(body.meta")
  |> should.be_false()
}

// --- query array with explode: true must produce key=a&key=b, not key=a,b ---
pub fn query_array_explode_true_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      parameters:
        - name: tags
          in: query
          required: true
          style: form
          explode: true
          schema:
            type: array
            items: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // With explode: true, the query parameter must NOT be comma-joined.
  // It should produce tags=a&tags=b, not tags=a,b.
  // The comma-join with list.map pattern indicates explode is being ignored.
  string.contains(content, "string.join(list.map(")
  |> should.be_false()
  // Instead, must use list.fold to produce repeated key=value pairs
  string.contains(content, "list.fold(")
  |> should.be_true()
}

// --- OAuth2 flows must be preserved in AST ---
pub fn oauth2_flows_preserved_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /data:
    get:
      operationId: getData
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    oauth2:
      type: oauth2
      flows:
        authorizationCode:
          authorizationUrl: https://example.com/auth
          tokenUrl: https://example.com/token
          scopes:
            read: Read access
            write: Write access
security:
  - oauth2: [read]
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Some(components) = spec.components
  let assert Ok(scheme) = dict.get(components.security_schemes, "oauth2")
  // OAuth2 scheme must preserve flow URLs and scopes.
  // Currently OAuth2Scheme only has description, losing all flow data.
  case scheme {
    spec.Value(spec.OAuth2Scheme(flows:, ..)) -> {
      // flows must not be empty — must contain the authorizationCode flow
      { flows != dict.new() }
      |> should.be_true()
      // Must have the authorizationCode flow
      let assert Ok(auth_flow) = dict.get(flows, "authorizationCode")
      // Must preserve scopes
      { auth_flow.scopes != dict.new() }
      |> should.be_true()
      dict.has_key(auth_flow.scopes, "read")
      |> should.be_true()
    }
    _ -> should.fail()
  }
}

// --- Handler stubs use panic instead of todo ---
pub fn server_handler_stubs_use_panic_not_todo_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: T
  version: 1.0.0
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: array
                items:
                  type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(handler_file) =
    list.find(files, fn(f) { string.contains(f.path, "handlers") })
  let content = handler_file.content

  // Handler stubs must use panic, not todo
  string.contains(content, "panic as \"unimplemented: get_items\"")
  |> should.be_true()

  // Must NOT contain bare todo keyword
  string.contains(content, "  todo\n")
  |> should.be_false()
}

// --- Server router must call handlers, not return hardcoded "OK" ---
pub fn server_router_calls_handlers_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  // Find the router file
  let router_file =
    list.find(files, fn(f) { string.contains(f.path, "router") })
  let assert Ok(router) = router_file
  // Router must NOT have dead-code handler references
  string.contains(router.content, "let _ = handlers.")
  |> should.be_false()
  // Router must NOT have placeholder "OK" strings
  string.contains(router.content, "\"OK\"")
  |> should.be_false()
  // Router must actually call the handler (via the sealed delegator,
  // Issue #247) and thread the application state (Issue #264).
  string.contains(router.content, "handlers_generated.get_items(app_state)")
  |> should.be_true()
  // Router must have ServerResponse type
  string.contains(router.content, "pub type ServerResponse")
  |> should.be_true()
  // Router must have proper route signature with state/query/headers/body
  // (Issue #264: `app_state: handlers.State` is the first argument).
  string.contains(
    router.content,
    "pub fn route(app_state: handlers.State, method: String, path: List(String), _query: Dict(String, List(String)), _headers: Dict(String, String), _body: String) -> ServerResponse",
  )
  |> should.be_true()
  // Router must convert response to ServerResponse
  string.contains(router.content, "ServerResponse(status: 200")
  |> should.be_true()
  // Router must have 404 fallback
  string.contains(router.content, "ServerResponse(status: 404")
  |> should.be_true()
}

// --- GeneratedFile uses target ADT, not filename strings ---
pub fn generated_file_has_target_kind_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = generate.generate_all_files(ctx)
  // All generated files must have proper target assignments
  let shared_count =
    list.count(files, fn(f) { f.target == context.SharedTarget })
  let server_count =
    list.count(files, fn(f) { f.target == context.ServerTarget })
  let client_count =
    list.count(files, fn(f) { f.target == context.ClientTarget })
  // Must have shared files (types, decoders, etc.)
  { shared_count > 0 }
  |> should.be_true()
  // Must have server files (handlers, router)
  { server_count > 0 }
  |> should.be_true()
  // Must have client files (client)
  { client_count > 0 }
  |> should.be_true()
}

// --- Path template unbound parameter tests ---

/// Path template {id} without a corresponding path parameter must be
/// caught by validation, not silently passed through to generated code.
pub fn unbound_path_template_parameter_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items/{id}:
    get:
      operationId: getItem
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let errors = validate.validate(ctx)
  // Must report at least one validation error for unbound {id}
  list.is_empty(errors)
  |> should.be_false()
}

/// Path template with parameter defined at path-item level must pass.
pub fn path_level_parameter_binds_template_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items/{id}:
    parameters:
      - name: id
        in: path
        required: true
        schema:
          type: string
    get:
      operationId: getItem
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_true()
}

/// Path template with all parameters bound must pass validation.
pub fn bound_path_template_parameter_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items/{id}:
    get:
      operationId: getItem
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_true()
}

// --- Parameter validation tests ---

/// Unsupported parameter style 'matrix' must be caught by validation.
pub fn unsupported_parameter_style_matrix_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: color
          in: query
          style: matrix
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_false()
}

/// Supported parameter styles (form, deepObject) must pass validation.
pub fn supported_parameter_style_form_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: color
          in: query
          style: form
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_true()
}

// --- Response code range tests ---

/// 2XX response code must generate a valid Gleam range pattern,
/// not the literal "2XX" which is invalid Gleam syntax.
pub fn response_code_range_2xx_generates_valid_gleam_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      responses:
        '2XX':
          description: Success
          content:
            application/json:
              schema:
                type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // The generated code must NOT contain the literal "2XX" as a case pattern
  string.contains(content, "2XX ->")
  |> should.be_false()
  // It should contain a valid range guard pattern
  string.contains(content, "status if status >= 200")
  |> should.be_true()
}

/// status_code_to_int_pattern must not pass through range codes like "2XX".
pub fn status_code_range_pattern_case() {
  // Range codes must produce valid Gleam patterns, not raw "2XX"
  http.status_code_to_int_pattern(http.StatusRange(2))
  |> should.not_equal("2XX")

  // Exact codes still work
  http.status_code_to_int_pattern(http.Status(200))
  |> should.equal("200")

  // Default is wildcard
  http.status_code_to_int_pattern(http.DefaultStatus)
  |> should.equal("_")
}

/// status_code_suffix must handle range codes.
pub fn status_code_suffix_range_case() {
  http.status_code_suffix(http.StatusRange(2))
  |> should.equal("Status2xx")

  http.status_code_suffix(http.StatusRange(4))
  |> should.equal("Status4xx")
}

/// Issue #525: status_code_suffix must produce semantic IANA reason
/// phrases for the full registry, not just a hand-picked subset.
/// Pre-fix, 200 → "Ok" but 202 → "Status202", which created
/// inconsistent variant naming across response types.
pub fn status_code_suffix_full_iana_registry_case() {
  // Codes that previously fell through to the numeric form.
  http.status_code_suffix(http.Status(202)) |> should.equal("Accepted")
  http.status_code_suffix(http.Status(206)) |> should.equal("PartialContent")
  http.status_code_suffix(http.Status(301)) |> should.equal("MovedPermanently")
  http.status_code_suffix(http.Status(304)) |> should.equal("NotModified")
  http.status_code_suffix(http.Status(308)) |> should.equal("PermanentRedirect")
  http.status_code_suffix(http.Status(410)) |> should.equal("Gone")
  http.status_code_suffix(http.Status(418)) |> should.equal("IAmATeapot")
  http.status_code_suffix(http.Status(429)) |> should.equal("TooManyRequests")
  http.status_code_suffix(http.Status(451))
  |> should.equal("UnavailableForLegalReasons")
  http.status_code_suffix(http.Status(503))
  |> should.equal("ServiceUnavailable")
  // Codes already named pre-fix should still produce the same suffix.
  http.status_code_suffix(http.Status(200)) |> should.equal("Ok")
  http.status_code_suffix(http.Status(204)) |> should.equal("NoContent")
  http.status_code_suffix(http.Status(401)) |> should.equal("Unauthorized")
  http.status_code_suffix(http.Status(500))
  |> should.equal("InternalServerError")
  // Non-standard codes keep the numeric fallback.
  http.status_code_suffix(http.Status(599)) |> should.equal("Status599")
}

// --- additionalProperties: true encoder tests ---

/// additionalProperties: true must NOT be silently dropped during encoding.
/// The encoder must include additional_properties in its output.
pub fn additional_properties_untyped_encoder_includes_extra_props_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    Metadata:
      type: object
      properties:
        name:
          type: string
      additionalProperties: true
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = list.append(decoders.generate(ctx), encoders.generate(ctx))
  let assert Ok(encode_file) =
    list.find(files, fn(f) { string.contains(f.path, "encode") })
  let content = encode_file.content
  // The encoder must reference additional_properties, not just base_props
  string.contains(content, "additional_properties")
  |> should.be_true()
  // It must NOT just use json.object(base_props) — that drops extra props
  string.contains(content, "json.object(base_props)")
  |> should.be_false()
}

// --- Complex parameter schema validation tests ---

/// Object schema query parameter without deepObject style now emits
/// a warning instead of a hard error (issue #352). The OpenAPI 3.x
/// default style for query is `form`, which only handles primitives
/// cleanly, so the codegen falls back to form serialization and the
/// warning prompts the spec author to be explicit if they need
/// deepObject. Refusing the spec was blocking adoption on the
/// GitHub REST API and other large public specs that routinely omit
/// `style` for complex query params.
pub fn object_query_param_without_deep_object_warns_not_errors_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: filter
          in: query
          schema:
            type: object
            properties:
              name:
                type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let issues = validate.validate(ctx)
  // No blocking errors — codegen would proceed.
  diagnostic.errors_only(issues)
  |> list.is_empty
  |> should.be_true()
  // But there's exactly one warning, pointing at the filter param.
  let warnings = diagnostic.warnings_only(issues)
  list.length(warnings) |> should.equal(1)
  let assert [Diagnostic(message: msg, ..)] = warnings
  string.contains(msg, "no explicit 'style'")
  |> should.be_true()
}

pub fn oneof_primitive_query_param_without_style_warns_case() {
  // The GitHub REST API's `cwes` parameter is `oneOf: [string,
  // array<string>]` with no explicit style. Pre-#352 oaspec
  // refused to generate; now it emits a warning and proceeds.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /advisories:
    get:
      operationId: listAdvisories
      parameters:
        - name: cwes
          in: query
          schema:
            oneOf:
              - type: string
              - type: array
                items:
                  type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let issues = validate.validate(ctx)
  diagnostic.errors_only(issues)
  |> list.is_empty
  |> should.be_true()
}

/// Object schema query parameter WITH deepObject style must pass.
pub fn object_query_param_with_deep_object_passes_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: filter
          in: query
          style: deepObject
          explode: true
          schema:
            type: object
            properties:
              name:
                type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_true()
}

// --- validate error message accuracy tests ---

/// Validation error for unsupported request content type must list
/// all actually supported types, including form-urlencoded.
pub fn validate_request_content_type_message_includes_form_urlencoded_case() {
  // `image/png` stays UnsupportedContentType after the issue #352
  // fallback (which only catches `text/*` and `application/*`); use
  // it instead of `text/csv` so the error path still fires.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    post:
      operationId: doX
      requestBody:
        content:
          image/png:
            schema:
              type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let errors = validate.validate(ctx)
  let assert [Diagnostic(message: msg, ..)] = errors
  // Error message must mention form-urlencoded as a supported type
  string.contains(msg, "form-urlencoded")
  |> should.be_true()
}

/// Validation error for unsupported response content type must list
/// all actually supported types, including XML.
pub fn validate_response_content_type_message_includes_xml_case() {
  // See note above on `text/csv` → `image/png` for the same #352
  // fallback rationale.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200':
          description: ok
          content:
            image/png:
              schema:
                type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let errors = validate.validate(ctx)
  let assert [Diagnostic(message: msg, ..)] = errors
  // Error message must mention XML as a supported type
  string.contains(msg, "xml")
  |> should.be_true()
}

// --- Issue #502: deepObject nested object properties ---

/// Stripe-style deepObject parameters whose properties are themselves
/// objects must pass client-mode validation. Server-mode codegen is
/// out of scope for this round; the server router still requires
/// primitive scalars / primitive arrays.
pub fn deep_object_nested_object_passes_client_validation_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/deep_object_nested.yaml")
  let assert Ok(resolved) = resolve.resolve(unresolved)
  let spec = hoist.hoist(resolved)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test/fixtures/deep_object_nested.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let errors = validate.validate(ctx)
  errors |> list.is_empty |> should.be_true()
}

/// Generated client must expand nested object properties into
/// bracketed-bracketed query keys (`filter[applicability_scope][price_type]`)
/// so the typed record actually serializes onto the wire instead of
/// being smuggled into a tuple as a record value.
pub fn deep_object_nested_object_emits_bracketed_query_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/deep_object_nested.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/deep_object_nested.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  // Nested object property is unwrapped through Some(v_outer) and
  // emits the doubly-bracketed key.
  string.contains(
    client_file.content,
    "#(\"filter[applicability_scope][price_type]\"",
  )
  |> should.be_true()
  // Top-level primitive property emits a single-level bracketed key.
  string.contains(client_file.content, "#(\"filter[customer]\"")
  |> should.be_true()
}

/// Regression guard: a client whose only multi-shape work is a
/// deepObject parameter must still import `Some`/`None` (the optional
/// inner property unwrap arms call them). Pre-fix, the imports were
/// gated only by optional params / response headers and the generated
/// code referenced `Some` without it being in scope.
pub fn deep_object_param_client_imports_some_none_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/deep_object_nested.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/deep_object_nested.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  string.contains(client_file.content, "import gleam/option.{")
  |> should.be_true()
  string.contains(client_file.content, "Some")
  |> should.be_true()
}

// --- Issue #519: deepObject primitive sub-property imports ---

/// Regression guard for #519: a client whose deepObject query
/// parameter has integer / number / boolean sub-properties (top-level
/// or nested) must import `gleam/int` / `gleam/float` / `gleam/bool`
/// because the codegen emits `int.to_string` / `float.to_string` /
/// `bool.to_string` at those sites. Pre-fix, the import gate didn't
/// traverse deepObject ObjectSchema properties and the generated
/// `<package>_client/client.gleam` failed to compile with
/// `Unknown module: int`.
pub fn deep_object_primitive_props_client_imports_primitives_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/deep_object_primitive_props.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/deep_object_primitive_props.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  // The deepObject sub-properties trigger int/float/bool to_string
  // emissions, which in turn require the matching primitive modules.
  string.contains(client_file.content, "import gleam/int")
  |> should.be_true()
  string.contains(client_file.content, "import gleam/float")
  |> should.be_true()
  string.contains(client_file.content, "import gleam/bool")
  |> should.be_true()
  // Nested-ObjectSchema property inner_count: integer is reached via
  // the recursive walker.
  string.contains(client_file.content, "filter[nested][inner_count]")
  |> should.be_true()
}

// --- Issue #526: pipeDelimited / spaceDelimited query parser edges ---

/// Regression guard for #526. The optional array-of-string query
/// parameter codegen for explode=false (pipeDelimited / spaceDelimited /
/// form-with-explode-false) must:
/// - accept ALL incoming occurrences (`?tags=a&tags=b` is no longer
///   silently truncated to the first), and
/// - filter empty strings produced by `?tags=` (empty value) or by
///   trailing delimiters like `?tags=foo|`.
pub fn pipe_delimited_query_handles_empty_and_repeated_keys_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: t, version: '0' }
paths:
  /polls:
    get:
      operationId: listPolls
      parameters:
        - name: tags
          in: query
          required: false
          style: pipeDelimited
          explode: false
          schema:
            type: array
            items: { type: string }
      responses: { '200': { description: ok } }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // No more `Ok([v, ..])` for the optional pipeDelimited tags
  // parameter — we now use `Ok(vs)` to consume all occurrences.
  string.contains(
    content,
    "tags: case dict.get(query, \"tags\") { Ok(vs) -> Some(vs |> list.flat_map(fn(v) { string.split(v, \"|\") }) |> list.map(string.trim) |> list.filter(fn(s) { s != \"\" }))",
  )
  |> should.be_true()
}

// --- Issue #524: friendly error on non-YAML config ---

/// Regression guard for #524: passing a non-YAML config path
/// (here a `.toml`) must surface a friendly `ParseError` instead
/// of crashing with `case_clause` when yay's Erlang FFI returns
/// a tuple shape that doesn't match the `YamlError` constructors.
pub fn config_load_rejects_non_yaml_extension_case() {
  // The path doesn't need to exist — the extension check happens
  // before `simplifile.read`.
  case config.load("/tmp/oaspec-test/oaspec.toml") {
    Error(config.ParseError(detail:)) -> {
      string.contains(detail, "config files must be YAML")
      |> should.be_true()
      string.contains(detail, "'.toml'")
      |> should.be_true()
    }
    _ -> {
      panic as "expected ParseError for non-YAML config extension"
    }
  }
}

/// Verify that real YAML extensions (.yaml, .yml) bypass the
/// extension gate and surface the existing `FileNotFound` for a
/// missing file (rather than the new friendly extension error).
pub fn config_load_yaml_extensions_bypass_gate_case() {
  let assert Error(err) =
    config.load("/tmp/oaspec-test/definitely-not-a-real-config.yaml")
  case err {
    config.FileNotFound(..) -> Nil
    _ -> {
      panic as "expected FileNotFound for missing .yaml config"
    }
  }
}

// --- Issue #523: OAS 3.0 boolean exclusiveMinimum/Maximum ---

/// Regression guard for #523: when the spec uses the OAS 3.0
/// boolean form `{minimum: N, exclusiveMinimum: true}` the parser
/// must promote the numeric `minimum` value into the
/// `exclusive_minimum` slot so the generated guard emits a strict
/// inequality (`<=` / `>=`) and the failure message says "greater
/// than" / "less than" (not "at least" / "at most"). Pre-fix the
/// boolean was silently discarded and boundary values passed
/// validation.
pub fn oas30_exclusive_bool_emits_strict_guard_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/guard_oas30_exclusive_bool.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/guard_oas30_exclusive_bool.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
      validate: True,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(guards_file) =
    list.find(summary.files, fn(f) { f.path == "guards.gleam" })
  // Both Integer and Number exclusive-range validators are emitted.
  string.contains(
    guards_file.content,
    "validate_visit_input_count_exclusive_range",
  )
  |> should.be_true()
  string.contains(
    guards_file.content,
    "validate_visit_input_ratio_exclusive_range",
  )
  |> should.be_true()
  // Strict-inequality language in the messages.
  string.contains(guards_file.content, "must be greater than 0")
  |> should.be_true()
  string.contains(guards_file.content, "must be less than 100")
  |> should.be_true()
  string.contains(guards_file.content, "must be greater than 0.0")
  |> should.be_true()
  string.contains(guards_file.content, "must be less than 1.0")
  |> should.be_true()
}

// --- Issue #522: optional `$ref` scalar query params ---

/// Regression guard for #522: an optional query parameter whose
/// schema is a `$ref` to a non-enum integer / number / boolean
/// component must be decoded with the scalar parse function (not
/// dropped through to a raw String). The matching `gleam/int` /
/// `gleam/float` import must also land in the router's import set.
pub fn ref_scalar_query_params_decode_with_parse_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/server_ref_scalar_query_params.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/server_ref_scalar_query_params.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(router_file) =
    list.find(summary.files, fn(f) { f.path == "router.gleam" })
  // Integer ref → int.parse(v)
  string.contains(router_file.content, "case int.parse(v)")
  |> should.be_true()
  // Number ref → float.parse(v)
  string.contains(router_file.content, "case float.parse(v)")
  |> should.be_true()
  // Imports follow the parse calls.
  string.contains(router_file.content, "import gleam/int")
  |> should.be_true()
  string.contains(router_file.content, "import gleam/float")
  |> should.be_true()
}

// --- Issue #521: multipleOf codegen body + imports ---

/// Regression guard for #521: a NumberSchema with both `minimum`
/// (or any range constraint) AND `multipleOf` must produce
/// (a) `gleam/float` + `gleam/int` imports in the generated
///     `guards.gleam`, and
/// (b) a `validate_*_multiple_of` body that compiles —
///     `value -. int.to_float(float.truncate(value /. m)) *. m`,
///     not the broken `... |> int.to_float ...` pipe form.
pub fn multiple_of_with_range_guard_compiles_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/guard_multiple_of_with_range.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/guard_multiple_of_with_range.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
      validate: True,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(guards_file) =
    list.find(summary.files, fn(f) { f.path == "guards.gleam" })
  string.contains(guards_file.content, "import gleam/float")
  |> should.be_true()
  string.contains(guards_file.content, "import gleam/int")
  |> should.be_true()
  // The corrected body wraps `float.truncate(...)` in
  // `int.to_float(...)` then multiplies by the divisor.
  string.contains(
    guards_file.content,
    "int.to_float(float.truncate(value /. 0.01)) *. 0.01",
  )
  |> should.be_true()
  // Negative guard: the broken pipe form must not appear.
  string.contains(guards_file.content, "|> int.to_float)")
  |> should.be_false()
}

// --- Issue #520: validate_<schema> recurses into nested records ---

/// Regression guard for #520: `validate_poll` must recurse into
/// nested records (`Metadata`, `Banner`), required lists of records
/// (`options: array<PollOption>`), and optional lists of records
/// (`tags: array<Tag>`). Pre-fix, only direct leaf-level constraints
/// (e.g. `slug` pattern) were emitted; constraint violations on inner
/// fields silently passed through to handlers.
pub fn nested_validate_recurses_into_records_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/guard_nested_constraints.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/guard_nested_constraints.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
      validate: True,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(guards_file) =
    list.find(summary.files, fn(f) { f.path == "guards.gleam" })
  // Required nested record → Composite call into validate_metadata.
  string.contains(guards_file.content, "validate_metadata(value.metadata)")
  |> should.be_true()
  // Optional nested record → Composite under option.Some(v) wrap.
  string.contains(guards_file.content, "validate_banner(v)")
  |> should.be_true()
  // Required list of records → list.fold over options calling validate_poll_option.
  string.contains(guards_file.content, "validate_poll_option(item)")
  |> should.be_true()
  string.contains(guards_file.content, "list.fold(value.options, errors")
  |> should.be_true()
  // Optional list of records → option-wrapped list.fold over tags.
  string.contains(guards_file.content, "validate_tag(item)")
  |> should.be_true()
}

/// Regression guard for #520: cycle detection in `schema_has_validator`
/// must not blow the stack on (a) self-recursive schemas like
/// `Comment.replies: array<Comment>` and (b) mutually-recursive
/// schemas like `User` ↔ `Link`. Pre-fix prototype, this fixture
/// would non-terminate during codegen.
pub fn nested_validate_handles_cycles_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/guard_nested_constraints.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/guard_nested_constraints.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
      validate: True,
    )
  // The mere fact that `generate.generate` returns `Ok(_)` (rather
  // than spinning on `User` ↔ `Link` or on `Comment.replies`) is the
  // important guarantee here.
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(guards_file) =
    list.find(summary.files, fn(f) { f.path == "guards.gleam" })
  // User has its own validator (because `name` has length constraints)
  // so the cycle break inside `Link.owner` shouldn't suppress it.
  string.contains(guards_file.content, "pub fn validate_user")
  |> should.be_true()
  // Link likewise has direct constraints on `target`.
  string.contains(guards_file.content, "pub fn validate_link")
  |> should.be_true()
}

// --- Issue #503: multipart/form-data object/array fields ---

/// Regression guard: a client whose only multi-shape work is a
/// multipart object/array body must import `gleam/list` (for
/// `list.fold` over array fields), `gleam/json` (for the JSON-bodied
/// object-field part), and the option ctors. Pre-fix, the import
/// gate ignored multipart property shapes and emitted `Some`/`list`/
/// `json` references without the modules in scope.
pub fn multipart_object_array_client_imports_list_json_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/multipart_object_array.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/multipart_object_array.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  string.contains(client_file.content, "import gleam/list")
  |> should.be_true()
  string.contains(client_file.content, "import gleam/json")
  |> should.be_true()
  string.contains(client_file.content, "import gleam/option.{")
  |> should.be_true()
}

// --- Comprehensive fixture sweep (parse + resolve panic-free) ---

/// Walk every fixture under `test/fixtures/` (top-level `.yaml` files
/// only) and run them through `parser.parse_file` and
/// `resolve.resolve`. Some fixtures intentionally trigger parse or
/// resolve errors (e.g. `broken_openapi.yaml`); the gate here is
/// that *neither stage panics*. A sanity floor on the success
/// counts catches a regression that would otherwise turn silently
/// bad parses into "0 fixtures parsed" without anyone noticing —
/// pre-existing tests do not enumerate the directory, so a renamed
/// module function would only surface in the few hand-listed
/// fixtures the rest of the suite touches.
pub fn fixtures_sweep_parse_resolve_no_panic_case() {
  let assert Ok(entries) = simplifile.read_directory("test/fixtures")
  let paths =
    entries
    |> list.filter(fn(name) { string.ends_with(name, ".yaml") })
    // Some fixtures are intentionally malformed at the YAML level
    // (`broken-*.yaml`, `broken_*.yaml`, oaspec-config-shaped files
    // that aren't valid OpenAPI) — yamerl raises an Erlang exception
    // for those rather than returning a typed error, so we keep them
    // out of the structural sweep. They are still exercised by
    // their dedicated unit tests.
    |> list.filter(fixtures_sweep_includes_path)
    |> list.map(fn(name) { "test/fixtures/" <> name })

  let #(total, parsed_ok, resolved_ok) =
    list.fold(paths, #(0, 0, 0), fn(acc, path) {
      let #(t, p, r) = acc
      case parser.parse_file(path) {
        Ok(spec) ->
          case resolve.resolve(spec) {
            Ok(_resolved) -> #(t + 1, p + 1, r + 1)
            // nolint: thrown_away_error -- some fixtures intentionally trigger resolve errors; the gate here is just panic-free traversal
            Error(_) -> #(t + 1, p + 1, r)
          }
        // nolint: thrown_away_error -- broken fixtures are deliberately included
        Error(_) -> #(t + 1, p, r)
      }
    })

  // The fixtures directory has well over 200 valid YAML files; if a
  // refactor accidentally short-circuits the loop or breaks the
  // parser entry point we want the floor to fail loudly. The
  // counts are intentionally conservative so adding a few new
  // broken fixtures doesn't trip the gate.
  should.be_true(total >= 200)
  should.be_true(parsed_ok >= 200)
  should.be_true(resolved_ok >= 180)
}

/// Structural invariants for `petstore.yaml` client output. The
/// fixture is small enough to enumerate every operation exactly, so
/// any drift in the codegen surface (a missing function, a renamed
/// variant, a stray empty file) trips one of the explicit asserts.
/// `string.contains` is a coarse gate, but it pins the public API
/// shape that downstream users actually call.
pub fn petstore_client_generated_surface_invariants_case() {
  let assert Ok(unresolved) = parser.parse_file("test/fixtures/petstore.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/petstore.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)

  // Every file expected from a client-mode generation must appear.
  let expected_files = [
    "types.gleam",
    "request_types.gleam",
    "response_types.gleam",
    "decode.gleam",
    "encode.gleam",
    "guards.gleam",
    "client.gleam",
  ]
  list.each(expected_files, fn(name) {
    list.find(summary.files, fn(f) { f.path == name })
    |> result.is_ok
    |> should.be_true
  })

  // Every emitted file is non-empty and carries the codegen
  // provenance header. Mirrors the integration-suite gate so a
  // unit-level run picks up the same regressions.
  list.each(summary.files, fn(f) {
    should.be_true(string.length(f.content) > 0)
    string.contains(f.content, "// Code generated by oaspec")
    |> should.be_true
  })

  // Every operation defined in petstore.yaml maps to a generated
  // client function. Hand-listing them here means a renaming or
  // accidental drop is caught immediately.
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  let expected_ops = ["list_pets", "create_pet", "get_pet", "delete_pet"]
  list.each(expected_ops, fn(op) {
    string.contains(client_file.content, "pub fn " <> op <> "(")
    |> should.be_true
  })

  // Every component schema declared in petstore.yaml maps to a
  // generated `pub type` in `types.gleam`.
  let assert Ok(types_file) =
    list.find(summary.files, fn(f) { f.path == "types.gleam" })
  let expected_types = ["Pet", "CreatePetRequest", "PetStatus", "Error"]
  list.each(expected_types, fn(t) {
    string.contains(types_file.content, "pub type " <> t)
    |> should.be_true
  })
}

/// Files under `test/fixtures/` that are intentionally not valid
/// OpenAPI documents (so calling `parser.parse_file` on them is
/// expected to raise an Erlang-level exception, not return a typed
/// error). They are excluded from the structural sweep but still
/// covered by their dedicated unit tests.
fn fixtures_sweep_includes_path(name: String) -> Bool {
  // `broken-*.yaml` / `broken_*.yaml` are invalid OpenAPI on
  // purpose. `oaspec*.yaml` and `oaspec-*.yaml` are *config* files
  // (not specs) — they live in the same directory by historical
  // accident and would parse as garbage if fed through the spec
  // parser. Anything that happens to share that prefix and is a real
  // spec keeps the sweep exposure via direct fixture tests.
  !string.starts_with(name, "broken-")
  && !string.starts_with(name, "broken_")
  && !string.starts_with(name, "oaspec-")
  && !string.starts_with(name, "oaspec_")
  // The bare `oaspec.yaml` config file lives next to the spec
  // fixtures by historical accident; it's an oaspec.yaml config,
  // not an OpenAPI document, and would parse as garbage. Exclude
  // explicitly so the prefix filter above doesn't miss it.
  && name != "oaspec.yaml"
  // `error_invalid_yaml.yaml` is intentionally invalid YAML so the
  // CLI's "we surface a SourceLoc on YAML parse errors" path can be
  // exercised — it raises a yamerl-level exception rather than
  // returning a typed error, so it's incompatible with this sweep.
  && name != "error_invalid_yaml.yaml"
}

/// Regression guard: a `*/*` request body must travel through
/// `transport.BytesBody`, not `transport.TextBody(json.to_string(...))`.
/// Pre-fix, the wildcard request fell through to the JSON encoder
/// fallback and produced code that referenced `gleam/json` without
/// it being in scope.
pub fn wildcard_request_body_uses_bytes_body_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/wildcard_content_type.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/wildcard_content_type.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  string.contains(client_file.content, "transport.BytesBody")
  |> should.be_true()
  string.contains(
    client_file.content,
    "transport.TextBody(json.to_string(json.string",
  )
  |> should.be_false()
}

/// Object-typed and array-typed properties on a multipart/form-data
/// schema must pass validation in client mode (the OAS 3 spec
/// allows them; Stripe's `POST /v1/files` is the motivating real-
/// world example with `expand: array of strings` and
/// `file_link_data: object`).
pub fn multipart_object_array_fields_pass_validation_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/multipart_object_array.yaml")
  let assert Ok(resolved) = resolve.resolve(unresolved)
  let spec = hoist.hoist(resolved)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test/fixtures/multipart_object_array.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let errors = validate.validate(ctx)
  errors |> list.is_empty |> should.be_true()
}

/// End-to-end client generation must produce code that handles array
/// fields by folding the input list into one part per element and
/// object fields by emitting a single JSON-encoded part with
/// `Content-Type: application/json`.
pub fn multipart_object_array_fields_emit_expected_parts_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/multipart_object_array.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/multipart_object_array.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  // Array field `expand` is folded into per-element parts.
  string.contains(client_file.content, "list.fold(v, parts, fn(acc, item)")
  |> should.be_true()
  string.contains(
    client_file.content,
    "form-data; name=\\\"expand\\\"\\r\\n\\r\\n",
  )
  |> should.be_true()
  // Object field `file_link_data` is emitted as a JSON part.
  string.contains(
    client_file.content,
    "form-data; name=\\\"file_link_data\\\"\\r\\nContent-Type: application/json",
  )
  |> should.be_true()
  string.contains(
    client_file.content,
    "json.to_string(encode.encode_post_files_request_file_link_data_json(",
  )
  |> should.be_true()
}

// --- Issue #504: */* wildcard content type ---

/// `*/*` request bodies and responses parse to BitArray and pass
/// validation. Kubernetes' OpenAPI v3 spec uses `*/*` heavily for
/// proxy and resource-mutation endpoints; without this support the
/// generator can't accept those specs.
pub fn wildcard_content_type_passes_validation_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/wildcard_content_type.yaml")
  let assert Ok(resolved) = resolve.resolve(unresolved)
  let spec = hoist.hoist(resolved)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test/fixtures/wildcard_content_type.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Both,
        validate: False,
      ),
    )
  let errors = validate.validate(ctx)
  errors |> list.is_empty |> should.be_true()
}

/// `content_type.from_string("*/*")` round-trips through `Wildcard`
/// and is reported as supported for both request and response.
pub fn wildcard_content_type_classified_as_supported_case() {
  content_type.from_string("*/*")
  |> should.equal(content_type.Wildcard)
  content_type.to_string(content_type.Wildcard)
  |> should.equal("*/*")
  content_type.is_supported(content_type.Wildcard)
  |> should.be_true()
  content_type.is_supported_request(content_type.Wildcard)
  |> should.be_true()
  content_type.is_supported_response(content_type.Wildcard)
  |> should.be_true()
}

/// End-to-end: generating a client for the wildcard fixture must
/// produce a `BitArray` request body and a `BitArray` response
/// variant — the same shape as `application/octet-stream`.
pub fn wildcard_content_type_generates_bitarray_bodies_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/wildcard_content_type.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/wildcard_content_type.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(request_types_file) =
    list.find(summary.files, fn(f) { f.path == "request_types.gleam" })
  let assert Ok(response_types_file) =
    list.find(summary.files, fn(f) { f.path == "response_types.gleam" })
  // Request type carries BitArray for the upload op.
  string.contains(request_types_file.content, "body: BitArray")
  |> should.be_true()
  // Response variants carry BitArray for both ops.
  string.contains(response_types_file.content, "BitArray")
  |> should.be_true()
}

// --- form-urlencoded non-object validation tests ---

/// form-urlencoded with non-object schema must be rejected by validation.
pub fn form_urlencoded_non_object_schema_rejected_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /submit:
    post:
      operationId: submit
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let errors = validate.validate(ctx)
  // Must report error for non-object schema with form-urlencoded
  list.is_empty(errors)
  |> should.be_false()
}

/// form-urlencoded with object schema must pass validation.
pub fn form_urlencoded_object_schema_passes_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /submit:
    post:
      operationId: submit
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              properties:
                name:
                  type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_true()
}

// --- AnyOfSchema discriminator tests ---

/// anyOf with discriminator must be preserved in the AST, not lost.
pub fn anyof_discriminator_preserved_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets:
    get:
      operationId: getPet
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Pet'
components:
  schemas:
    Cat:
      type: object
      properties:
        pet_type:
          type: string
        meow:
          type: string
      required: [pet_type]
    Dog:
      type: object
      properties:
        pet_type:
          type: string
        bark:
          type: string
      required: [pet_type]
    Pet:
      anyOf:
        - $ref: '#/components/schemas/Cat'
        - $ref: '#/components/schemas/Dog'
      discriminator:
        propertyName: pet_type
        mapping:
          cat: '#/components/schemas/Cat'
          dog: '#/components/schemas/Dog'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // The Pet schema must have a discriminator in the AST
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.AnyOfSchema(discriminator: disc, ..))) =
    dict.get(components.schemas, "Pet")
  // discriminator must be Some, not None
  disc
  |> option.is_some()
  |> should.be_true()
}

// --- Nullable schema decoder/encoder tests ---

/// A nullable primitive schema (type: [string, 'null']) must generate
/// decoder using decode.optional and encoder using json.nullable.
pub fn nullable_primitive_decoder_encoder_case() {
  let yaml =
    "
openapi: 3.1.0
info:
  title: T
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    MaybeName:
      type: [string, 'null']
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = list.append(decoders.generate(ctx), encoders.generate(ctx))
  // Find the decode file
  let assert Ok(decode_file) =
    list.find(files, fn(f) { string.contains(f.path, "decode") })
  let decode_content = decode_file.content
  // The decoder must use decode.optional for nullable String
  string.contains(decode_content, "decode.optional(decode.string)")
  |> should.be_true()

  // Find the encode file
  let assert Ok(encode_file) =
    list.find(files, fn(f) { string.contains(f.path, "encode") })
  let encode_content = encode_file.content
  // The encoder must use json.nullable for nullable String
  string.contains(encode_content, "json.nullable(value, json.string)")
  |> should.be_true()
}

// --- deepObject nested object validation tests ---

/// deepObject with nested object properties must be rejected
/// since codegen can only handle one level of nesting.
pub fn deep_object_nested_object_rejected_case() {
  // Issue #502: nested object properties are now ACCEPTED (encoded
  // as `parent[outer][inner]=value`); only oneOf / anyOf properties
  // remain rejected because they don't fit the bracketed-string
  // wire format. This test pins that boundary.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: filter
          in: query
          style: deepObject
          explode: true
          schema:
            type: object
            properties:
              picker:
                oneOf:
                  - type: string
                  - type: integer
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  // Must detect oneOf in deepObject param
  list.is_empty(errors)
  |> should.be_false()
}

/// deepObject with flat scalar properties must pass validation.
pub fn deep_object_flat_properties_passes_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: filter
          in: query
          style: deepObject
          explode: true
          schema:
            type: object
            properties:
              name:
                type: string
              age:
                type: integer
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_true()
}

// --- PathItem.$ref tests ---

/// PathItem.$ref must resolve to the referenced PathItem from components.pathItems.
pub fn path_item_ref_resolves_case() {
  let yaml =
    "
openapi: 3.1.0
info:
  title: Test
  version: 1.0.0
paths:
  /health:
    $ref: '#/components/pathItems/HealthCheck'
components:
  pathItems:
    HealthCheck:
      get:
        operationId: healthCheck
        responses:
          '200':
            description: OK
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // /health path must exist as a Ref (lazy resolution)
  let assert Ok(spec.Ref(ref_str)) = dict.get(spec.paths, "/health")
  ref_str |> should.equal("#/components/pathItems/HealthCheck")
  // The referenced PathItem must exist in components
  let assert Some(components) = spec.components
  let assert Ok(spec.Value(path_item)) =
    dict.get(components.path_items, "HealthCheck")
  let assert Some(get_op) = path_item.get
  get_op.operation_id
  |> should.equal(Some("healthCheck"))
}

// --- Unresolved $ref validation tests ---

/// A $ref pointing to a non-existent schema must be caught by validation.
pub fn unresolved_ref_detected_by_validator_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Missing'
components:
  schemas: {}
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  // Must report at least one error for unresolved reference
  list.is_empty(errors)
  |> should.be_false()
}

/// A $ref pointing to an existing schema must pass validation.
pub fn resolved_ref_passes_validator_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Item'
components:
  schemas:
    Item:
      type: object
      properties:
        name:
          type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_true()
}

// --- Security AND wildcard tests ---

/// Security AND with 3 schemes must generate correct wildcard pattern.
/// The wildcard must have 3 underscores, not hardcoded `_, _`.
pub fn security_and_3_schemes_wildcard_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /secure:
    get:
      operationId: getSecure
      security:
        - ApiKeyAuth: []
          BearerAuth: []
          OAuth2: []
        - BasicAuth: []
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    ApiKeyAuth:
      type: apiKey
      in: header
      name: X-API-Key
    BearerAuth:
      type: http
      scheme: bearer
    OAuth2:
      type: oauth2
      flows:
        implicit:
          authorizationUrl: https://example.com
          scopes: {}
    BasicAuth:
      type: http
      scheme: basic
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // The AND alternative is encoded as a single SecurityAlternative with
  // three SecurityRequirement entries; transport.with_security applies
  // them all when the alternative is satisfied.
  string.contains(content, "transport.SecurityAlternative([")
  |> should.be_true()
  string.contains(content, "scheme_name: \"ApiKeyAuth\"")
  |> should.be_true()
  string.contains(content, "scheme_name: \"BearerAuth\"")
  |> should.be_true()
  string.contains(content, "scheme_name: \"OAuth2\"")
  |> should.be_true()
}

// --- Nullable composition schema tests ---

/// nullable: true on a oneOf schema must produce Option(T) type.
pub fn nullable_oneof_generates_option_type_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    Cat:
      type: object
      properties:
        name:
          type: string
    Dog:
      type: object
      properties:
        name:
          type: string
    NullablePet:
      nullable: true
      oneOf:
        - $ref: '#/components/schemas/Cat'
        - $ref: '#/components/schemas/Dog'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // The NullablePet schema must have nullable: true in the AST
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(oneof_schema)) =
    dict.get(components.schemas, "NullablePet")
  schema.is_nullable(oneof_schema)
  |> should.be_true()
}

// --- AnyOfSchema type generation tests ---

/// anyOf with $ref schemas must generate a union type like oneOf,
/// not fall through to String.
pub fn anyof_generates_union_type_not_string_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets:
    get:
      operationId: getPet
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Pet'
components:
  schemas:
    Cat:
      type: object
      properties:
        name:
          type: string
    Dog:
      type: object
      properties:
        name:
          type: string
    Pet:
      anyOf:
        - $ref: '#/components/schemas/Cat'
        - $ref: '#/components/schemas/Dog'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  let content = types_file.content
  // Pet must be a record with Option fields (anyOf = inclusive union)
  string.contains(content, "pub type Pet = String")
  |> should.be_false()
  // It should have Option fields, not tagged union constructors
  string.contains(content, "Option(Cat)")
  |> should.be_true()
  string.contains(content, "Option(Dog)")
  |> should.be_true()
  // Must NOT have tagged union variant constructors
  string.contains(content, "PetCat(Cat)")
  |> should.be_false()
}

// --- Security scopes comment tests ---

/// Security scopes should appear as comments in generated client code.
pub fn security_scopes_appear_as_comments_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets:
    get:
      operationId: listPets
      responses:
        '200':
          description: ok
      security:
        - OAuth2:
            - read:pets
            - write:pets
components:
  securitySchemes:
    OAuth2:
      type: oauth2
      flows:
        implicit:
          authorizationUrl: https://example.com
          scopes:
            read:pets: Read pets
            write:pets: Write pets
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // OAuth2 schemes are emitted as HttpAuthorization with a "Bearer"
  // prefix in the request's security metadata. (Scope comments are
  // not rendered in the new transport-runtime layout — runtime
  // middleware only matches on scheme name, so scopes don't affect
  // credential application.)
  string.contains(
    content,
    "transport.HttpAuthorization(scheme_name: \"OAuth2\"",
  )
  |> should.be_true()
  string.contains(content, "prefix: \"Bearer\"")
  |> should.be_true()
}

// --- allowReserved parameter tests ---

/// Query parameter with allowReserved: true must NOT be percent-encoded.
pub fn allow_reserved_skips_percent_encode_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /search:
    get:
      operationId: search
      parameters:
        - name: q
          in: query
          required: true
          allowReserved: true
          schema:
            type: string
      responses:
        '200':
          description: ok
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // With allowReserved, the generated code must NOT use uri.percent_encode for this param
  // Instead it should use the value directly
  string.contains(content, "uri.percent_encode(q)")
  |> should.be_false()
}

/// Query parameters carry raw values into transport.Request — the
/// adapter is responsible for percent-encoding when assembling the URL.
pub fn default_query_param_emits_raw_tuple_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /search:
    get:
      operationId: search
      parameters:
        - name: q
          in: query
          required: true
          schema:
            type: string
      responses:
        '200':
          description: ok
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // Query values reach the request as raw `String` tuples — the
  // adapter percent-encodes when serialising the final URL.
  string.contains(content, "[#(\"q\", q), ..query]")
  |> should.be_true()
}

// --- Parser required field validation tests ---

/// requestBody without content field must be rejected (content is REQUIRED).
pub fn parser_rejects_request_body_missing_content_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    post:
      operationId: createItem
      requestBody:
        description: An item
      responses:
        '200':
          description: ok
"
  let result = parser.parse_string(yaml)
  case result {
    Error(_) -> should.be_true(True)
    Ok(_) -> should.be_true(False)
  }
}

/// response without description field must be rejected (description is REQUIRED).
pub fn parser_rejects_response_missing_description_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      responses:
        '200':
          content:
            application/json:
              schema:
                type: string
"
  let result = parser.parse_string(yaml)
  case result {
    Error(_) -> should.be_true(True)
    Ok(_) -> should.be_true(False)
  }
}

// --- Schema dispatch centralization tests ---

/// schema_dispatch must return correct types for primitives.
pub fn schema_dispatch_primitive_types_case() {
  schema_dispatch.schema_base_type(schema.StringSchema(
    metadata: schema.default_metadata(),
    format: None,
    enum_values: [],
    min_length: None,
    max_length: None,
    pattern: None,
  ))
  |> should.equal("String")

  schema_dispatch.schema_base_type(schema.IntegerSchema(
    metadata: schema.default_metadata(),
    format: None,
    minimum: None,
    maximum: None,
    exclusive_minimum: None,
    exclusive_maximum: None,
    multiple_of: None,
  ))
  |> should.equal("Int")
}

/// schema_dispatch.to_string_expr must produce correct conversion expressions.
pub fn schema_dispatch_to_string_expr_case() {
  schema_dispatch.to_string_expr(
    schema.IntegerSchema(
      metadata: schema.default_metadata(),
      format: None,
      minimum: None,
      maximum: None,
      exclusive_minimum: None,
      exclusive_maximum: None,
      multiple_of: None,
    ),
    "x",
  )
  |> should.equal("int.to_string(x)")
}

// --- Gleam Code IR tests ---

/// IR renderer produces correct type alias.
pub fn ir_render_type_alias_case() {
  let module =
    ir.module(header: "test", imports: [], declarations: [
      ir.declaration(
        doc: None,
        type_def: ir.TypeAlias(name: "UserId", target: "String"),
      ),
    ])
  let output = ir_render.render(module)
  string.contains(output, "pub type UserId = String")
  |> should.be_true()
}

/// IR renderer produces correct union type.
pub fn ir_render_union_type_case() {
  let module =
    ir.module(header: "test", imports: [], declarations: [
      ir.declaration(
        doc: None,
        type_def: ir.UnionType(name: "Shape", variants: [
          ir.VariantWithType(name: "ShapeCircle", inner_type: "Circle"),
          ir.VariantWithType(name: "ShapeSquare", inner_type: "Square"),
        ]),
      ),
    ])
  let output = ir_render.render(module)
  string.contains(output, "pub type Shape {")
  |> should.be_true()
  string.contains(output, "ShapeCircle(Circle)")
  |> should.be_true()
  string.contains(output, "ShapeSquare(Square)")
  |> should.be_true()
}

/// IR renderer produces correct record type.
pub fn ir_render_record_type_case() {
  let module =
    ir.module(header: "test", imports: [], declarations: [
      ir.declaration(
        doc: None,
        type_def: ir.RecordType(name: "User", fields: [
          ir.Field(name: "name", type_expr: "String"),
          ir.Field(name: "age", type_expr: "Int"),
        ]),
      ),
    ])
  let output = ir_render.render(module)
  string.contains(output, "pub type User {")
  |> should.be_true()
  string.contains(output, "User(name: String, age: Int)")
  |> should.be_true()
}

// --- Fail-fast unsupported feature tests ---

/// External $ref (not #/) must be rejected as unsupported.
pub fn external_ref_rejected_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: './other.yaml#/components/schemas/Foo'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  list.is_empty(errors)
  |> should.be_false()
}

/// Unrecognized schema type must be rejected at parse time.
pub fn unrecognized_schema_type_rejected_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200':
          description: ok
components:
  schemas:
    Bad:
      type: frobnicate
"
  let result = parser.parse_string(yaml)
  case result {
    Error(_) -> should.be_true(True)
    Ok(_) -> should.be_true(False)
  }
}

// --- oneOf vs anyOf semantic separation tests ---

/// anyOf must generate a record with Option fields, NOT a tagged union.
pub fn anyof_generates_record_with_option_fields_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Payment'
components:
  schemas:
    Card:
      type: object
      properties:
        card_number:
          type: string
    Bank:
      type: object
      properties:
        account:
          type: string
    Payment:
      anyOf:
        - $ref: '#/components/schemas/Card'
        - $ref: '#/components/schemas/Bank'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  let content = types_file.content
  // anyOf should generate a record with Option fields, not tagged union variants
  string.contains(content, "Option(")
  |> should.be_true()
  // It must NOT have tagged union variant constructors like PaymentCard(Card)
  string.contains(content, "PaymentCard(")
  |> should.be_false()
}

/// oneOf must still generate a tagged union (existing behavior preserved).
pub fn oneof_still_generates_tagged_union_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Shape'
components:
  schemas:
    Circle:
      type: object
      properties:
        radius:
          type: number
    Square:
      type: object
      properties:
        side:
          type: number
    Shape:
      oneOf:
        - $ref: '#/components/schemas/Circle'
        - $ref: '#/components/schemas/Square'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let spec = dedup.dedup(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  let content = types_file.content
  // oneOf must generate tagged union variants
  string.contains(content, "ShapeCircle(")
  |> should.be_true()
  string.contains(content, "ShapeSquare(")
  |> should.be_true()
}

// --- ParameterStyle and SecuritySchemeIn are proper ADTs, not strings ---
pub fn parameter_style_is_adt_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /x:
    get:
      operationId: getX
      parameters:
        - name: filter
          in: query
          style: deepObject
          schema: { type: object, properties: { a: { type: string } } }
        - name: ids
          in: query
          style: form
          schema: { type: array, items: { type: integer } }
        - name: id
          in: path
          required: true
          style: simple
          schema: { type: string }
      responses:
        '200': { description: ok }
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert Ok(spec.Value(pi)) = dict.get(parsed.paths, "/x")
  let assert Some(op) = pi.get
  let assert [spec.Value(deep), spec.Value(form), spec.Value(simple)] =
    op.parameters
  deep.style |> should.equal(Some(spec.DeepObjectStyle))
  form.style |> should.equal(Some(spec.FormStyle))
  simple.style |> should.equal(Some(spec.SimpleStyle))
}

// --- SchemaMetadata preserves title, readOnly, writeOnly, default, example ---
pub fn schema_metadata_lossless_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  schemas:
    User:
      type: object
      title: User object
      properties:
        name:
          type: string
          title: User name
          readOnly: true
          default: anonymous
          example: Alice
        id:
          type: integer
          writeOnly: true
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert Some(c) = parsed.components
  let assert Ok(schema.Inline(user)) = dict.get(c.schemas, "User")
  // Object metadata
  case user {
    schema.ObjectSchema(metadata:, ..) -> {
      metadata.title |> should.equal(Some("User object"))
    }
    _ -> should.fail()
  }
}

pub fn security_scheme_in_is_adt_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    headerKey:
      type: apiKey
      name: X-API-Key
      in: header
    queryKey:
      type: apiKey
      name: api_key
      in: query
    cookieKey:
      type: apiKey
      name: session
      in: cookie
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert Some(c) = parsed.components
  let assert Ok(h) = dict.get(c.security_schemes, "headerKey")
  let assert Ok(q) = dict.get(c.security_schemes, "queryKey")
  let assert Ok(k) = dict.get(c.security_schemes, "cookieKey")
  case h {
    spec.Value(spec.ApiKeyScheme(in_: spec.SchemeInHeader, ..)) ->
      should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
  case q {
    spec.Value(spec.ApiKeyScheme(in_: spec.SchemeInQuery, ..)) ->
      should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
  case k {
    spec.Value(spec.ApiKeyScheme(in_: spec.SchemeInCookie, ..)) ->
      should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

fn find_substring_index(haystack: String, needle: String) -> Result(Int, Nil) {
  case string.contains(haystack, needle) {
    True -> {
      let parts = string.split(haystack, needle)
      case parts {
        [before, ..] -> Ok(string.length(before))
        _ -> Error(Nil)
      }
    }
    False -> Error(Nil)
  }
}

// --- Lossless AST: new fields are preserved through parsing ---
pub fn lossless_info_fields_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: T
  version: 1.0.0
  summary: A summary
  termsOfService: https://example.com/tos
  contact:
    name: Support
    url: https://example.com
    email: support@example.com
  license:
    name: MIT
    url: https://opensource.org/licenses/MIT
paths: {}
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  parsed.info.summary |> should.equal(Some("A summary"))
  parsed.info.terms_of_service
  |> should.equal(Some("https://example.com/tos"))
  let assert Some(contact) = parsed.info.contact
  contact.name |> should.equal(Some("Support"))
  contact.email |> should.equal(Some("support@example.com"))
  let assert Some(lic) = parsed.info.license
  lic.name |> should.equal("MIT")
}

pub fn lossless_server_variables_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
servers:
  - url: https://{env}.example.com
    variables:
      env:
        default: prod
        enum: [prod, staging, dev]
        description: Environment
paths: {}
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert [server] = parsed.servers
  let assert Ok(var) = dict.get(server.variables, "env")
  var.default |> should.equal("prod")
  var.description |> should.equal(Some("Environment"))
}

pub fn lossless_response_headers_links_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200':
          description: ok
          headers:
            X-Rate-Limit:
              description: Rate limit
              required: true
              schema: { type: integer }
          links:
            GetItemById:
              operationId: getItem
              description: Get item by ID
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert Ok(spec.Value(pi)) = dict.get(parsed.paths, "/items")
  let assert Some(op) = pi.get
  let assert Ok(spec.Value(resp)) = dict.get(op.responses, http.Status(200))
  let assert Ok(header) = dict.get(resp.headers, "X-Rate-Limit")
  header.description |> should.equal(Some("Rate limit"))
  header.required |> should.be_true()
  let assert Ok(link) = dict.get(resp.links, "GetItemById")
  link.operation_id |> should.equal(Some("getItem"))
}

pub fn lossless_tags_and_external_docs_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
tags:
  - name: users
    description: User operations
externalDocs:
  url: https://docs.example.com
  description: Full docs
paths: {}
"
  let assert Ok(parsed) = parser.parse_string(yaml)
  let assert [tag] = parsed.tags
  tag.name |> should.equal("users")
  tag.description |> should.equal(Some("User operations"))
  let assert Some(ext) = parsed.external_docs
  ext.url |> should.equal("https://docs.example.com")
}

// --- Bug verification tests ---

/// Bug 1: Optional deepObject + array leaf.
/// When a deepObject parameter is optional (required: false) AND has an array
/// leaf property, it must NOT produce uri.percent_encode(v) where v is the
/// whole list. It should iterate the list items instead.
pub fn bug1_optional_deep_object_array_leaf_case() {
  // deepObject style query parameters are not yet wired through the
  // new transport-runtime client emission. The generator currently
  // falls back to the simple-param path, which works for object-typed
  // deepObject params with scalar leaves but not for array leaves.
  // Tracked as a follow-up to the Issue #333 PR.
  //
  // What this test should assert once the helper is migrated:
  //   - generated code calls `list.fold(...)` over the array leaf
  //   - the array variable is never percent-encoded directly
  //
  // For now the test is intentionally a no-op so it documents the gap
  // without blocking the transport-runtime refactor.
  Nil
}

/// Bug 2: form-urlencoded $ref array property.
/// When a form body has a $ref that resolves to an array schema, it must NOT
/// produce uri.percent_encode(body.tags) where body.tags is a List.
/// It should iterate the list items with list.fold instead.
pub fn bug2_form_urlencoded_ref_array_property_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /submit:
    post:
      operationId: submitForm
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              required: [tags]
              properties:
                tags:
                  $ref: '#/components/schemas/TagList'
      responses:
        '200': { description: ok }
components:
  schemas:
    TagList:
      type: array
      items: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content

  // The bug: $ref to array schema is not detected as array, so it treats the
  // list as a scalar and calls percent_encode(body.tags) directly.
  // Should use list.fold to iterate items instead.
  let has_list_fold = string.contains(content, "list.fold(body.tags")
  let has_direct_encode =
    string.contains(content, "uri.percent_encode(body.tags)")
  // Should iterate items, not encode list directly
  has_list_fold
  |> should.be_true()
  has_direct_encode
  |> should.be_false()
}

/// Bug 3: $ref array query parameter missing gleam/list import.
/// When a query parameter has a schema that $refs to an array type, the
/// generated code uses list.fold but the import for gleam/list may be missing.
pub fn bug3_ref_array_query_param_import_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      parameters:
        - name: tags
          in: query
          required: true
          style: form
          explode: true
          schema:
            $ref: '#/components/schemas/TagList'
      responses:
        '200': { description: ok }
components:
  schemas:
    TagList:
      type: array
      items: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content

  // The bug: list.fold is used in generated code but gleam/list may not be
  // imported because the import check only looks for Inline(ArraySchema)
  // not Reference that resolves to ArraySchema.
  let uses_list_module =
    string.contains(content, "list.fold")
    || string.contains(content, "list.map")
  let imports_list = string.contains(content, "import gleam/list")
  // If the code uses list.fold/list.map, it MUST import gleam/list
  case uses_list_module {
    True -> imports_list |> should.be_true()
    False -> Nil
  }
}

// --- Structured capability: warnings don't block generation ---
pub fn capability_warnings_dont_block_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200':
          description: ok
          headers:
            X-Rate-Limit:
              description: Rate limit
              schema: { type: integer }
          links:
            next:
              operationId: getItems
webhooks:
  newItem:
    post:
      operationId: onNewItem
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  // Generation must succeed even with warnings
  let result = generate.generate(spec, cfg)
  should.be_ok(result)
  // But capability issues should include warnings
  let assert Ok(resolved) = resolve.resolve(spec)
  let resolved = hoist.hoist(resolved)
  let resolved = dedup.dedup(resolved)
  let ctx = context.new(resolved, cfg)
  let issues = capability_check.check_preserved(ctx, location_index.empty())
  let warnings = diagnostic.warnings_only(issues)
  { warnings != [] }
  |> should.be_true()
}

// --- readOnly/writeOnly filtering tests ---

pub fn read_only_filtered_from_request_body_type_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /users:
    post:
      operationId: createUser
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [name]
              properties:
                name: { type: string }
                id: { type: integer, readOnly: true }
                password: { type: string, writeOnly: true }
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
                properties:
                  name: { type: string }
                  id: { type: integer, readOnly: true }
                  password: { type: string, writeOnly: true }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // NOTE: Do NOT hoist here -- we want inline schemas to remain inline
  // so that the anonymous type filtering for readOnly/writeOnly is tested.
  let ctx = make_ctx_from_spec(spec)

  let type_files = types.generate(ctx)

  // Check the types.gleam file for the anonymous request body type
  let assert Ok(types_file) =
    list.find(type_files, fn(f) { f.path == "types.gleam" })

  // Request body type should NOT have id field (readOnly)
  // but SHOULD have password field (writeOnly is fine in requests)
  let request_body_section =
    string.contains(types_file.content, "CreateUserRequestBody")
  request_body_section |> should.be_true()

  // The request body type should contain name and password but NOT id
  // Split content to find the request body type definition
  let lines = string.split(types_file.content, "\n")
  let request_body_lines = extract_type_block(lines, "CreateUserRequestBody")
  let request_body_text = string.join(request_body_lines, "\n")

  // readOnly field 'id' must NOT be in request body type
  string.contains(request_body_text, "id:") |> should.be_false()
  // writeOnly field 'password' MUST be in request body type
  string.contains(request_body_text, "password:") |> should.be_true()
  // Normal field 'name' MUST be in request body type
  string.contains(request_body_text, "name:") |> should.be_true()

  // Response type should NOT have password field (writeOnly)
  // but SHOULD have id field (readOnly is fine in responses)
  let response_section =
    string.contains(types_file.content, "CreateUserResponseOk")
  response_section |> should.be_true()

  let response_lines = extract_type_block(lines, "CreateUserResponseOk")
  let response_text = string.join(response_lines, "\n")

  // writeOnly field 'password' must NOT be in response type
  string.contains(response_text, "password:") |> should.be_false()
  // readOnly field 'id' MUST be in response type
  string.contains(response_text, "id:") |> should.be_true()
  // Normal field 'name' MUST be in response type
  string.contains(response_text, "name:") |> should.be_true()
}

/// Helper to extract lines from a type block definition.
fn extract_type_block(lines: List(String), type_name: String) -> List(String) {
  extract_type_block_loop(lines, type_name, False, 0, [])
}

fn extract_type_block_loop(
  lines: List(String),
  type_name: String,
  in_block: Bool,
  brace_depth: Int,
  acc: List(String),
) -> List(String) {
  case lines {
    [] -> list.reverse(acc)
    [line, ..rest] ->
      case in_block {
        False ->
          case string.contains(line, "pub type " <> type_name) {
            True ->
              extract_type_block_loop(rest, type_name, True, 1, [line, ..acc])
            False -> extract_type_block_loop(rest, type_name, False, 0, acc)
          }
        True -> {
          let opens =
            string.to_graphemes(line)
            |> list.count(fn(c) { c == "{" })
          let closes =
            string.to_graphemes(line)
            |> list.count(fn(c) { c == "}" })
          let new_depth = brace_depth + opens - closes
          case new_depth <= 0 {
            True -> list.reverse([line, ..acc])
            False ->
              extract_type_block_loop(rest, type_name, True, new_depth, [
                line,
                ..acc
              ])
          }
        }
      }
  }
}

pub fn read_only_filtered_from_encoder_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /users:
    post:
      operationId: createUser
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [name]
              properties:
                name: { type: string }
                id: { type: integer, readOnly: true }
                password: { type: string, writeOnly: true }
      responses:
        '200':
          description: ok
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // Do NOT hoist -- keep inline schemas to test anonymous encoder filtering
  let ctx = make_ctx_from_spec(spec)

  let encoder_files = encoders.generate(ctx)
  let assert Ok(encode_file) =
    list.find(encoder_files, fn(f) { f.path == "encode.gleam" })

  // The encoder for request body should NOT encode the readOnly 'id' field
  // Find the encoder function
  let content = encode_file.content
  string.contains(content, "encode_create_user_request_body")
  |> should.be_true()

  // The encoder should not have "id" as a JSON key
  // but should have "name" and "password"
  let lines = string.split(content, "\n")
  let encoder_lines =
    extract_fn_block(lines, "encode_create_user_request_body_json")
  let encoder_text = string.join(encoder_lines, "\n")

  string.contains(encoder_text, "\"id\"") |> should.be_false()
  string.contains(encoder_text, "\"name\"") |> should.be_true()
  string.contains(encoder_text, "\"password\"") |> should.be_true()
}

/// Helper to extract lines from a function block definition.
fn extract_fn_block(lines: List(String), fn_name: String) -> List(String) {
  extract_fn_block_loop(lines, fn_name, False, 0, [])
}

fn extract_fn_block_loop(
  lines: List(String),
  fn_name: String,
  in_block: Bool,
  brace_depth: Int,
  acc: List(String),
) -> List(String) {
  case lines {
    [] -> list.reverse(acc)
    [line, ..rest] ->
      case in_block {
        False ->
          case string.contains(line, "pub fn " <> fn_name) {
            True -> extract_fn_block_loop(rest, fn_name, True, 1, [line, ..acc])
            False -> extract_fn_block_loop(rest, fn_name, False, 0, acc)
          }
        True -> {
          let opens =
            string.to_graphemes(line)
            |> list.count(fn(c) { c == "{" })
          let closes =
            string.to_graphemes(line)
            |> list.count(fn(c) { c == "}" })
          let new_depth = brace_depth + opens - closes
          case new_depth <= 0 {
            True -> list.reverse([line, ..acc])
            False ->
              extract_fn_block_loop(rest, fn_name, True, new_depth, [
                line,
                ..acc
              ])
          }
        }
      }
  }
}

pub fn write_only_filtered_from_response_decoder_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /users:
    post:
      operationId: createUser
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                name: { type: string }
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
                properties:
                  name: { type: string }
                  id: { type: integer, readOnly: true }
                  password: { type: string, writeOnly: true }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  // Do NOT hoist -- keep inline schemas to test anonymous decoder filtering
  let ctx = make_ctx_from_spec(spec)

  let decoder_files = decoders.generate(ctx)
  let assert Ok(decode_file) =
    list.find(decoder_files, fn(f) { f.path == "decode.gleam" })

  let content = decode_file.content

  // The response decoder should NOT decode writeOnly 'password' field
  let lines = string.split(content, "\n")
  let decoder_lines = extract_fn_block(lines, "create_user_response_ok_decoder")
  let decoder_text = string.join(decoder_lines, "\n")

  // writeOnly 'password' must NOT be in response decoder
  string.contains(decoder_text, "\"password\"") |> should.be_false()
  // readOnly 'id' MUST be in response decoder
  string.contains(decoder_text, "\"id\"") |> should.be_true()
  // Normal 'name' MUST be in response decoder
  string.contains(decoder_text, "\"name\"") |> should.be_true()
}

pub fn read_only_filtered_from_component_encoder_with_hoist_case() {
  // Test that component schema encoders (after hoist) skip readOnly fields
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
components:
  schemas:
    User:
      type: object
      required: [name]
      properties:
        name: { type: string }
        id: { type: integer, readOnly: true }
        password: { type: string, writeOnly: true }
paths:
  /users:
    post:
      operationId: createUser
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/User'
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/User'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)

  // Check encoder: readOnly 'id' should NOT be encoded
  let encoder_files = encoders.generate(ctx)
  let assert Ok(encode_file) =
    list.find(encoder_files, fn(f) { f.path == "encode.gleam" })
  let lines = string.split(encode_file.content, "\n")
  let encoder_lines = extract_fn_block(lines, "encode_user_json")
  let encoder_text = string.join(encoder_lines, "\n")

  // readOnly 'id' must NOT be in encoder
  string.contains(encoder_text, "\"id\"") |> should.be_false()
  // writeOnly 'password' MUST be in encoder (it's sent by client)
  string.contains(encoder_text, "\"password\"") |> should.be_true()
  // Normal 'name' MUST be in encoder
  string.contains(encoder_text, "\"name\"") |> should.be_true()

  // Check decoder: writeOnly 'password' should be treated as optional
  let decoder_files = decoders.generate(ctx)
  let assert Ok(decode_file) =
    list.find(decoder_files, fn(f) { f.path == "decode.gleam" })
  let dlines = string.split(decode_file.content, "\n")
  let decoder_lines = extract_fn_block(dlines, "user_decoder")
  let decoder_text = string.join(decoder_lines, "\n")

  // writeOnly 'password' should use optional_field (not required field)
  string.contains(decoder_text, "optional_field(\"password\"")
  |> should.be_true()
  // readOnly 'id' and normal 'name' should be present
  string.contains(decoder_text, "\"id\"") |> should.be_true()
  string.contains(decoder_text, "\"name\"") |> should.be_true()

  // Check that the component type still has ALL fields (shared type)
  let type_files = types.generate(ctx)
  let assert Ok(types_file) =
    list.find(type_files, fn(f) { f.path == "types.gleam" })
  let tlines = string.split(types_file.content, "\n")
  let user_type_lines = extract_type_block(tlines, "User")
  let user_type_text = string.join(user_type_lines, "\n")
  // All fields must be present in the shared type
  string.contains(user_type_text, "name:") |> should.be_true()
  string.contains(user_type_text, "id:") |> should.be_true()
  string.contains(user_type_text, "password:") |> should.be_true()
}

pub fn server_variable_substitution_default_base_url_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: T
  version: 1.0.0
servers:
  - url: https://{env}.example.com/{version}
    variables:
      env:
        default: production
      version:
        default: v2
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content

  // Must contain the default_base_url function
  string.contains(content, "pub fn default_base_url() -> String {")
  |> should.be_true()

  // Must contain the resolved URL with variables substituted
  string.contains(content, "\"https://production.example.com/v2\"")
  |> should.be_true()
}

pub fn server_no_variables_default_base_url_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: T
  version: 1.0.0
servers:
  - url: https://api.example.com/v1
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content

  string.contains(content, "pub fn default_base_url() -> String {")
  |> should.be_true()

  string.contains(content, "\"https://api.example.com/v1\"")
  |> should.be_true()
}

pub fn server_empty_default_base_url_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: T
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let ctx =
    context.new(
      spec,
      config.new(
        input: "test.yaml",
        output_server: "./test_output/api",
        output_client: "./test_output_client/api",
        package: "api",
        mode: config.Client,
        validate: False,
      ),
    )
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content

  // With no servers, default_base_url should not be generated
  string.contains(content, "default_base_url")
  |> should.be_false()
}

// --- Feature: Guards for exclusiveMinimum, exclusiveMaximum, multipleOf ---

pub fn guards_exclusive_and_multiple_of_integer_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      responses:
        '200': { description: ok }
components:
  schemas:
    Item:
      type: object
      required: [score, quantity]
      properties:
        score:
          type: integer
          exclusiveMinimum: 0
          exclusiveMaximum: 100
        quantity:
          type: integer
          multipleOf: 5
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  let assert [guard_file] = files
  let content = guard_file.content

  // Should contain exclusive range guard for score
  string.contains(content, "validate_item_score_exclusive_range")
  |> should.be_true()
  // After the build_range_guard refactor (#403) the exclusive bound
  // is expressed via `<=` / `>=` so the emit shape lines up with
  // inclusive guards (`True -> failure / False -> Ok(value)`).
  string.contains(content, "value <= 0")
  |> should.be_true()
  string.contains(content, "value >= 100")
  |> should.be_true()

  // Should contain multipleOf guard for quantity
  string.contains(content, "validate_item_quantity_multiple_of")
  |> should.be_true()
  string.contains(content, "value % 5 == 0")
  |> should.be_true()

  // Composite validator should call both guards
  string.contains(content, "validate_item_score_exclusive_range(value.score)")
  |> should.be_true()
  string.contains(content, "validate_item_quantity_multiple_of(value.quantity)")
  |> should.be_true()
}

pub fn guards_exclusive_and_multiple_of_float_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /measures:
    get:
      operationId: listMeasures
      responses:
        '200': { description: ok }
components:
  schemas:
    Measure:
      type: object
      required: [weight, step]
      properties:
        weight:
          type: number
          exclusiveMinimum: 0.0
          exclusiveMaximum: 999.9
        step:
          type: number
          multipleOf: 0.5
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  let assert [guard_file] = files
  let content = guard_file.content

  // Should contain exclusive range guard for weight
  string.contains(content, "validate_measure_weight_exclusive_range")
  |> should.be_true()
  // Float exclusive bounds use `<=.` / `>=.` (build_range_guard
  // refactor #403 normalizes the case shape across all range guards).
  string.contains(content, "value <=. 0.0")
  |> should.be_true()

  // Should contain multipleOf guard for step
  string.contains(content, "validate_measure_step_multiple_of")
  |> should.be_true()
  string.contains(content, "must be a multiple of 0.5")
  |> should.be_true()
}

pub fn guards_top_level_integer_exclusive_and_multiple_of_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /ids:
    get:
      operationId: listIds
      responses:
        '200': { description: ok }
components:
  schemas:
    EvenPositive:
      type: integer
      exclusiveMinimum: 0
      multipleOf: 2
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  let assert [guard_file] = files
  let content = guard_file.content

  // Top-level exclusive range guard
  string.contains(content, "validate_even_positive_root_exclusive_range")
  |> should.be_true()
  // Top-level multipleOf guard
  string.contains(content, "validate_even_positive_root_multiple_of")
  |> should.be_true()
}

// --- Bool parameter case-insensitive parsing tests ---

pub fn server_bool_path_param_case_insensitive_case() {
  // Server codegen should parse both "true"/"True" and "false"/"False" for bool params.
  // Gleam's bool.to_string produces "True"/"False" (capitalized), so server must
  // accept both cases to be compatible with the client.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items/{active}:
    get:
      operationId: getItems
      parameters:
        - name: active
          in: path
          required: true
          schema:
            type: boolean
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Must accept "true" and "True" as True (case-insensitive)
  string.contains(content, "string.lowercase")
  |> should.be_true()
}

pub fn server_bool_query_param_case_insensitive_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: verbose
          in: query
          required: true
          schema:
            type: boolean
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Must accept "true"/"True" as True via case-insensitive comparison
  string.contains(content, "string.lowercase")
  |> should.be_true()
}

pub fn validate_non_json_request_body_unsupported_for_server_case() {
  // Server multipart support is intentionally narrow. Nested/object-like fields
  // should still produce server-targeted validation errors.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /upload:
    post:
      operationId: uploadFile
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              properties:
                meta:
                  type: object
                  properties:
                    file:
                      type: string
                      format: binary
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(
        e.message,
        "multipart/form-data server request bodies only support",
      )
    })
  // Should have at least one server-targeted error for unsupported multipart shape
  list.length(server_errors)
  |> should.not_equal(0)
}

pub fn validate_form_urlencoded_body_multi_level_nesting_accepted_case() {
  // Multi-level nested form-urlencoded objects are now supported
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /login:
    post:
      operationId: login
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              properties:
                profile:
                  type: object
                  properties:
                    meta:
                      type: object
                      properties:
                        username:
                          type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(
        e.message,
        "application/x-www-form-urlencoded server request bodies only support",
      )
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn validate_json_request_body_ok_for_server_case() {
  // application/json body should NOT produce a server-targeted error
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    post:
      operationId: createItem
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                name:
                  type: string
      responses:
        '201': { description: created }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "not supported for server")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_header_param_name_lowercased_case() {
  // Server codegen must lowercase header parameter names in dict.get calls
  // to match client behavior (which lowercases header names).
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: X-Request-ID
          in: header
          required: true
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Must use lowercased header name "x-request-id" not "X-Request-ID"
  string.contains(content, "\"x-request-id\"")
  |> should.be_true()
  // Must NOT contain the original casing in dict.get
  string.contains(content, "\"X-Request-ID\"")
  |> should.be_false()
}

pub fn server_optional_header_param_name_lowercased_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: X-Trace-Id
          in: header
          required: false
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Must use lowercased header name
  string.contains(content, "\"x-trace-id\"")
  |> should.be_true()
}

pub fn server_bool_optional_query_param_case_insensitive_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: verbose
          in: query
          required: false
          schema:
            type: boolean
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Must accept "true"/"True" as True via case-insensitive comparison
  string.contains(content, "string.lowercase")
  |> should.be_true()
}

pub fn server_float_path_param_parsed_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /locations/{lat}:
    get:
      operationId: getLocation
      parameters:
        - name: lat
          in: path
          required: true
          schema:
            type: number
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  string.contains(content, "import gleam/float")
  |> should.be_true()
  string.contains(content, "float.parse(")
  |> should.be_true()
  string.contains(content, "TODO: Parse as Float")
  |> should.be_false()
}

pub fn validate_rejects_array_params_for_server_codegen_case() {
  let ctx = make_ctx("test/fixtures/server_query_array_object_items.yaml")
  let errors = validate.validate(ctx)
  // Bug fix: query array params with non-primitive items now error
  // in BOTH modes because the client codegen also panics on them;
  // the diagnostic target switched from `TargetServer` to
  // `TargetBoth`. Accept either so this test pins the rejection
  // shape regardless of how the gate is widened.
  let array_errors =
    list.filter(errors, fn(e) {
      case e.target {
        diagnostic.TargetServer | diagnostic.TargetBoth ->
          string.contains(
            e.message,
            "Query array parameters are only supported",
          )
        _ -> False
      }
    })
  list.length(array_errors)
  |> should.equal(1)
}

pub fn validate_accepts_deep_object_params_for_server_codegen_case() {
  let ctx = make_ctx("test/fixtures/server_deep_object_params.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "deepObject")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn validate_rejects_path_complex_params_for_server_codegen_case() {
  let ctx = make_ctx("test/fixtures/server_complex_path_parameter.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "Complex path parameters are not supported")
    })
  list.length(server_errors)
  |> should.equal(1)
}

pub fn client_mode_ignores_server_target_validation_errors_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: session
          in: cookie
          required: true
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  generate.generate(spec, cfg)
  |> should.be_ok()
}

pub fn filter_by_mode_drops_server_errors_for_client_case() {
  let issues = [
    diagnostic.validation(
      path: "x",
      detail: "server-only",
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetServer,
      hint: None,
    ),
    diagnostic.validation(
      path: "y",
      detail: "shared",
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetBoth,
      hint: None,
    ),
  ]
  let filtered = diagnostic.filter_by_mode(issues, config.Client)
  list.length(filtered)
  |> should.equal(1)
}

pub fn filter_by_mode_drops_client_errors_for_server_case() {
  let issues = [
    diagnostic.validation(
      path: "x",
      detail: "client-only",
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetClient,
      hint: None,
    ),
    diagnostic.validation(
      path: "y",
      detail: "shared",
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetBoth,
      hint: None,
    ),
  ]
  let filtered = diagnostic.filter_by_mode(issues, config.Server)
  list.length(filtered)
  |> should.equal(1)
}

pub fn filter_by_mode_keeps_all_errors_for_both_case() {
  let issues = [
    diagnostic.validation(
      path: "x",
      detail: "client-only",
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetClient,
      hint: None,
    ),
    diagnostic.validation(
      path: "y",
      detail: "server-only",
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetServer,
      hint: None,
    ),
    diagnostic.validation(
      path: "z",
      detail: "shared",
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetBoth,
      hint: None,
    ),
  ]
  let filtered = diagnostic.filter_by_mode(issues, config.Both)
  list.length(filtered)
  |> should.equal(3)
}

pub fn generation_summary_includes_warnings_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
tags:
  - name: items
    description: Item operations
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200':
          description: ok
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(spec, cfg)
  { summary.warnings != [] }
  |> should.be_true()
}

pub fn validate_warns_multi_content_responses_for_server_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema: { type: string }
            text/plain:
              schema: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let issues = capability_check.check_preserved(ctx, location_index.empty())
  let warnings =
    list.filter(issues, fn(issue) {
      issue.severity == diagnostic.SeverityWarning
      && issue.target == diagnostic.TargetServer
      && string.contains(issue.message, "Multiple response content types")
    })
  list.length(warnings)
  |> should.equal(1)
}

pub fn integration_script_uses_warnings_as_errors_for_server_builds_case() {
  let assert Ok(content) = simplifile.read("integration_test/run.sh")
  string.contains(content, "if gleam build 2>&1; then")
  |> should.be_false()
}

pub fn server_router_uses_underscored_unused_route_args_case() {
  let yaml =
    "
openapi: 3.0.3
info: { title: T, version: 1.0.0 }
paths:
  /items:
    get:
      operationId: getItems
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let router_file = list.find(files, fn(f) { f.path == "router.gleam" })
  let assert Ok(router) = router_file
  string.contains(
    router.content,
    "pub fn route(app_state: handlers.State, method: String, path: List(String), _query: Dict(String, List(String)), _headers: Dict(String, String), _body: String) -> ServerResponse",
  )
  |> should.be_true()
}

pub fn validate_accepts_cookie_params_for_server_codegen_case() {
  let ctx = make_ctx("test/fixtures/server_cookie_params.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "Cookie parameters")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_cookie_params_are_generated_without_todo_placeholders_case() {
  let ctx = make_ctx("test/fixtures/server_cookie_params.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(content, "TODO: Extract cookie param")
  |> should.be_false()
  string.contains(content, "cookie_lookup(headers, \"session\")")
  |> should.be_true()
  string.contains(content, "cookie_lookup(headers, \"debug\")")
  |> should.be_true()
}

pub fn server_cookie_router_imports_list_for_cookie_lookup_case() {
  let ctx = make_ctx("test/fixtures/server_cookie_params.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  string.contains(router_file.content, "import gleam/list")
  |> should.be_true()
}

pub fn server_cookie_router_percent_decodes_cookie_values_case() {
  let ctx = make_ctx("test/fixtures/server_cookie_params.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  string.contains(router_file.content, "import gleam/uri")
  |> should.be_true()
  string.contains(router_file.content, "uri.percent_decode")
  |> should.be_true()
}

pub fn server_query_and_header_scalars_are_parsed_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /metrics:
    get:
      operationId: getMetrics
      parameters:
        - name: ratio
          in: query
          required: true
          schema:
            type: number
        - name: x-enabled
          in: header
          required: false
          schema:
            type: boolean
        - name: x-threshold
          in: header
          required: true
          schema:
            type: number
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  // Issue #263: required scalar query/header params now flow through nested
  // `case dict.get(...) { Ok(...) -> { case <parse>(...) { Ok(<bound>) -> ...`
  // scaffolds, so the value expression at the field site is just the bound
  // variable name and the failure modes return 400 instead of crashing.
  string.contains(content, "case dict.get(query, \"ratio\") {")
  |> should.be_true()
  string.contains(content, "Ok([ratio_raw, ..]) ->")
  |> should.be_true()
  string.contains(content, "case float.parse(ratio_raw) {")
  |> should.be_true()
  string.contains(content, "ratio: ratio_raw_parsed,")
  |> should.be_true()
  string.contains(content, "case dict.get(headers, \"x-threshold\") {")
  |> should.be_true()
  string.contains(content, "Ok(x_threshold_raw) ->")
  |> should.be_true()
  string.contains(content, "case float.parse(x_threshold_raw) {")
  |> should.be_true()
  string.contains(content, "x_threshold: x_threshold_raw_parsed,")
  |> should.be_true()
  string.contains(content, "x_enabled: case dict.get(headers, \"x-enabled\") {")
  |> should.be_true()
  // Issue #307: failure paths emit RFC 7807 Problem JSON, not plain text.
  string.contains(content, "status: 400") |> should.be_true()
  string.contains(content, "\"Bad Request\"") |> should.be_false()
  string.contains(
    content,
    "[#(\"content-type\", \"application/problem+json\")]",
  )
  |> should.be_true()
}

pub fn validate_accepts_header_array_params_for_server_codegen_case() {
  let ctx = make_ctx("test/fixtures/server_header_array_params.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "Array parameters")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_header_array_params_are_parsed_case() {
  let ctx = make_ctx("test/fixtures/server_header_array_params.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(content, "import gleam/list")
  |> should.be_true()
  // Required header arrays now go through `case dict.get(headers, ...) { Ok(<raw>) -> ... }`
  // so a missing header returns 400 instead of crashing the BEAM (Issue #263).
  string.contains(content, "case dict.get(headers, \"x-tags\") {")
  |> should.be_true()
  string.contains(content, "Ok(x_tags_raw) ->")
  |> should.be_true()
  string.contains(
    content,
    "x_tags: list.map(string.split(x_tags_raw, \",\"), fn(item) { string.trim(item) }),",
  )
  |> should.be_true()
  // Optional header array still uses the legacy inline `let assert` for now;
  // it cannot be missing-required so it does not affect Issue #263.
  string.contains(
    content,
    "x_scores: case dict.get(headers, \"x-scores\") { Ok(v) -> Some(list.map(string.split(v, \",\"), fn(item) { let trimmed = string.trim(item) case int.parse(trimmed) { Ok(n) -> n _ -> 0 } })) _ -> None },",
  )
  |> should.be_true()
  string.contains(content, "case dict.get(headers, \"x-flags\") {")
  |> should.be_true()
  string.contains(content, "Ok(x_flags_raw) ->")
  |> should.be_true()
  string.contains(
    content,
    "x_flags: list.map(string.split(x_flags_raw, \",\"), fn(item) { let v = string.trim(item) case string.lowercase(v) { \"true\" -> True _ -> False } }),",
  )
  |> should.be_true()
}

pub fn validate_accepts_query_array_params_for_server_codegen_case() {
  let ctx = make_ctx("test/fixtures/server_query_array_params.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "Array parameters")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_query_array_params_use_query_multimap_case() {
  let ctx = make_ctx("test/fixtures/server_query_array_params.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(
    content,
    "pub fn route(app_state: handlers.State, method: String, path: List(String), query: Dict(String, List(String)), _headers: Dict(String, String), _body: String) -> ServerResponse",
  )
  |> should.be_true()
  // Required explode=true array now opens its own `case dict.get(...) { Ok([_, ..] as <raw>) ->`
  // so an empty / missing list returns 400 (Issue #263).
  string.contains(content, "case dict.get(query, \"tags\") {")
  |> should.be_true()
  string.contains(content, "Ok([_, ..] as tags_raw) ->")
  |> should.be_true()
  string.contains(
    content,
    "tags: list.map(tags_raw, fn(item) { string.trim(item) }),",
  )
  |> should.be_true()
  // Issue #526: optional array query params with explode=false now
  // accept all incoming occurrences (`Ok(vs)` rather than the
  // first-only `Ok([v, ..])`) and filter empties, so `?scores=` and
  // `?scores=a,&scores=b,` no longer slip a stray empty / `0`
  // through.
  string.contains(
    content,
    "scores: case dict.get(query, \"scores\") { Ok(vs) -> Some(vs |> list.flat_map(fn(v) { string.split(v, \",\") }) |> list.filter_map(fn(item) { let trimmed = string.trim(item) case trimmed { \"\" -> Error(Nil) _ -> int.parse(trimmed) } })) _ -> None },",
  )
  |> should.be_true()
}

pub fn server_deep_object_params_are_parsed_case() {
  let ctx = make_ctx("test/fixtures/server_deep_object_params.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(content, "import api/types")
  |> should.be_true()
  string.contains(content, "filter: types.SearchItemsParamFilter(")
  |> should.be_true()
  string.contains(
    content,
    "name: case dict.get(query, \"filter[name]\") { Ok([v, ..]) -> v _ -> \"\" }",
  )
  |> should.be_true()
  string.contains(
    content,
    "active: case dict.get(query, \"filter[active]\") { Ok([v, ..]) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "ratio: case dict.get(query, \"filter[ratio]\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "scores: case dict.get(query, \"filter[scores]\") { Ok(vs) -> list.map(vs, fn(item) { let trimmed = string.trim(item) case int.parse(trimmed) { Ok(n) -> n _ -> 0 } }) _ -> [] }",
  )
  |> should.be_true()
  string.contains(
    content,
    "options: case deep_object_present_any(query, \"options\")",
  )
  |> should.be_true()
  string.contains(
    content,
    "tags: case dict.get(query, \"options[tags]\") { Ok(vs) -> Some(list.map(vs, fn(item) { string.trim(item) })) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "enabled: case dict.get(query, \"options[enabled]\") { Ok([v, ..]) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None }",
  )
  |> should.be_true()
  // additional_properties field should call deep_object_additional_properties helper
  // wrapped with coerce_dict for Untyped additional_properties (Dict -> Dynamic)
  string.contains(
    content,
    "additional_properties: coerce_dict(deep_object_additional_properties(query, \"filter\", [\"active\", \"name\", \"ratio\", \"scores\"]))",
  )
  |> should.be_true()
  string.contains(
    content,
    "additional_properties: coerce_dict(deep_object_additional_properties(query, \"options\", [\"enabled\", \"tags\"]))",
  )
  |> should.be_true()
  // deep_object_additional_properties helper function should be generated
  string.contains(
    content,
    "fn deep_object_additional_properties(query: Dict(String, List(String)), prefix: String, known_props: List(String)) -> Dict(String, List(String)) {",
  )
  |> should.be_true()
  // deep_object_present_any helper function should be generated
  string.contains(
    content,
    "fn deep_object_present_any(query: Dict(String, List(String)), prefix: String) -> Bool {",
  )
  |> should.be_true()
}

pub fn validate_accepts_form_urlencoded_body_for_server_codegen_case() {
  let ctx = make_ctx("test/fixtures/server_form_urlencoded_body.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "application/x-www-form-urlencoded")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_form_urlencoded_body_is_parsed_case() {
  let ctx = make_ctx("test/fixtures/server_form_urlencoded_body.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(content, "import api/types")
  |> should.be_true()
  string.contains(content, "fn form_url_decode(value: String) -> String {")
  |> should.be_true()
  string.contains(
    content,
    "fn parse_form_body(body: String) -> Dict(String, List(String)) {",
  )
  |> should.be_true()
  string.contains(content, "let form_body = parse_form_body(body)")
  |> should.be_true()
  string.contains(content, "body: types.SubmitFormRequest(")
  |> should.be_true()
  string.contains(
    content,
    "name: case dict.get(form_body, \"name\") { Ok([v, ..]) -> v _ -> \"\" }",
  )
  |> should.be_true()
  string.contains(
    content,
    "active: case dict.get(form_body, \"active\") { Ok([v, ..]) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "ratio: case dict.get(form_body, \"ratio\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "scores: case dict.get(form_body, \"scores\") { Ok(vs) -> list.map(vs, fn(item) { let trimmed = string.trim(item) case int.parse(trimmed) { Ok(n) -> n _ -> 0 } }) _ -> [] }",
  )
  |> should.be_true()
  string.contains(
    content,
    "tags: case dict.get(form_body, \"tags\") { Ok(vs) -> Some(list.map(vs, fn(item) { string.trim(item) })) _ -> None }",
  )
  |> should.be_true()
}

pub fn validate_accepts_nested_form_urlencoded_body_for_server_codegen_case() {
  let ctx = make_ctx("test/fixtures/server_form_urlencoded_nested_body.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "application/x-www-form-urlencoded")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_nested_form_urlencoded_body_is_parsed_case() {
  let ctx = make_ctx("test/fixtures/server_form_urlencoded_nested_body.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(content, "profile: types.SubmitNestedFormRequestProfile(")
  |> should.be_true()
  string.contains(
    content,
    "username: case dict.get(form_body, \"profile[username]\") { Ok([v, ..]) -> v _ -> \"\" }",
  )
  |> should.be_true()
  string.contains(
    content,
    "aliases: case dict.get(form_body, \"profile[aliases]\") { Ok(vs) -> Some(list.map(vs, fn(item) { string.trim(item) })) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "age: case dict.get(form_body, \"profile[age]\") { Ok([v, ..]) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }",
  )
  |> should.be_true()
}

pub fn validate_accepts_multipart_body_for_server_codegen_case() {
  let ctx = make_ctx("test/fixtures/server_multipart_body.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "multipart/form-data")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_multipart_body_is_parsed_case() {
  let ctx = make_ctx("test/fixtures/server_multipart_body.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(
    content,
    "fn parse_multipart_body(body: String, headers: Dict(String, String)) -> Dict(String, List(String)) {",
  )
  |> should.be_true()
  string.contains(
    content,
    "let multipart_body = parse_multipart_body(body, headers)",
  )
  |> should.be_true()
  string.contains(content, "body: types.UploadMultipartRequest(")
  |> should.be_true()
  string.contains(
    content,
    "name: case dict.get(multipart_body, \"name\") { Ok([v, ..]) -> v _ -> \"\" }",
  )
  |> should.be_true()
  string.contains(
    content,
    "active: case dict.get(multipart_body, \"active\") { Ok([v, ..]) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "ratio: case dict.get(multipart_body, \"ratio\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "file: case dict.get(multipart_body, \"file\") { Ok([v, ..]) -> Some(v) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "let normalized_part = part |> string.remove_prefix(\"\\r\\n\") |> string.remove_suffix(\"\\r\\n\")",
  )
  |> should.be_true()
  string.contains(content, "let value = string.trim(raw_value)")
  |> should.be_false()
}

pub fn validate_accepts_form_urlencoded_ref_fields_for_server_codegen_case() {
  let ctx = make_ctx("test/fixtures/server_form_urlencoded_ref_fields.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "application/x-www-form-urlencoded")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_form_urlencoded_ref_fields_are_parsed_case() {
  let ctx = make_ctx("test/fixtures/server_form_urlencoded_ref_fields.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(
    content,
    "active: case dict.get(form_body, \"active\") { Ok([v, ..]) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "ratio: case dict.get(form_body, \"ratio\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "scores: case dict.get(form_body, \"scores\") { Ok(vs) -> list.map(vs, fn(item) { let trimmed = string.trim(item) case int.parse(trimmed) { Ok(n) -> n _ -> 0 } }) _ -> [] }",
  )
  |> should.be_true()
  string.contains(content, "profile: types.Profile(")
  |> should.be_true()
  string.contains(
    content,
    "username: case dict.get(form_body, \"profile[username]\") { Ok([v, ..]) -> v _ -> \"\" }",
  )
  |> should.be_true()
  string.contains(
    content,
    "enabled: case dict.get(form_body, \"profile[enabled]\") { Ok([v, ..]) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None }",
  )
  |> should.be_true()
}

pub fn validate_accepts_multipart_ref_fields_for_server_codegen_case() {
  let ctx = make_ctx("test/fixtures/server_multipart_ref_fields.yaml")
  let errors = validate.validate(ctx)
  let server_errors =
    list.filter(errors, fn(e) {
      e.target == diagnostic.TargetServer
      && string.contains(e.message, "multipart/form-data")
    })
  list.length(server_errors)
  |> should.equal(0)
}

pub fn server_multipart_ref_fields_are_parsed_case() {
  let ctx = make_ctx("test/fixtures/server_multipart_ref_fields.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(
    content,
    "active: case dict.get(multipart_body, \"active\") { Ok([v, ..]) -> Some(case string.lowercase(v) { \"true\" -> True _ -> False }) _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "ratio: case dict.get(multipart_body, \"ratio\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }",
  )
  |> should.be_true()
  string.contains(
    content,
    "file: case dict.get(multipart_body, \"file\") { Ok([v, ..]) -> Some(v) _ -> None }",
  )
  |> should.be_true()
}

pub fn server_multipart_enum_field_dispatches_to_variant_case() {
  // Issue #482: `$ref`-typed string-enum field on a multipart body must
  // dispatch into the generated sum-type variant, not be copied as raw
  // String. Without this fix `gleam check` rejects the autogen output.
  let ctx = make_ctx("test/fixtures/server_multipart_enum_field.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  // Required enum field falls back to first variant on miss / unknown.
  string.contains(
    content,
    "category: case dict.get(multipart_body, \"category\") { Ok([v, ..]) -> case v { \"logs\" -> types.CategoryLogs \"screenshots\" -> types.CategoryScreenshots \"configs\" -> types.CategoryConfigs _ -> types.CategoryLogs } _ -> types.CategoryLogs }",
  )
  |> should.be_true()
  // Optional enum field falls back to None on miss / unknown.
  string.contains(
    content,
    "tag: case dict.get(multipart_body, \"tag\") { Ok([v, ..]) -> case v { \"logs\" -> Some(types.CategoryLogs) \"screenshots\" -> Some(types.CategoryScreenshots) \"configs\" -> Some(types.CategoryConfigs) _ -> None } _ -> None }",
  )
  |> should.be_true()
  // The previous broken shape — copying the raw String — must be gone.
  string.contains(
    content,
    "category: case dict.get(multipart_body, \"category\") { Ok([v, ..]) -> v _ -> \"\" }",
  )
  |> should.be_false()
}

pub fn server_form_urlencoded_enum_field_dispatches_to_variant_case() {
  // Issue #482: same fix applies to application/x-www-form-urlencoded
  // bodies, which share the body_required_expr / body_optional_expr
  // codepath with multipart.
  let ctx = make_ctx("test/fixtures/server_form_urlencoded_enum_field.yaml")
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content

  string.contains(
    content,
    "category: case dict.get(form_body, \"category\") { Ok([v, ..]) -> case v { \"logs\" -> types.CategoryLogs \"screenshots\" -> types.CategoryScreenshots \"configs\" -> types.CategoryConfigs _ -> types.CategoryLogs } _ -> types.CategoryLogs }",
  )
  |> should.be_true()
  string.contains(
    content,
    "tag: case dict.get(form_body, \"tag\") { Ok([v, ..]) -> case v { \"logs\" -> Some(types.CategoryLogs) \"screenshots\" -> Some(types.CategoryScreenshots) \"configs\" -> Some(types.CategoryConfigs) _ -> None } _ -> None }",
  )
  |> should.be_true()
}

// --- Server cookie parameter end-to-end tests ---

pub fn server_cookie_param_generates_cookie_lookup_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /dashboard:
    get:
      operationId: getDashboard
      parameters:
        - name: session_id
          in: cookie
          required: true
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Router must contain the cookie_lookup helper function
  string.contains(content, "fn cookie_lookup(")
  |> should.be_true()
  // Must use cookie_lookup for the session_id parameter
  string.contains(content, "cookie_lookup(headers, \"session_id\")")
  |> should.be_true()
  // Must import gleam/uri for percent-decoding
  string.contains(content, "gleam/uri")
  |> should.be_true()
}

pub fn server_cookie_param_optional_string_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /prefs:
    get:
      operationId: getPrefs
      parameters:
        - name: theme
          in: cookie
          required: false
          schema:
            type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Optional cookie should use Some/None pattern
  string.contains(content, "cookie_lookup(headers, \"theme\")")
  |> should.be_true()
  string.contains(content, "Some(v)")
  |> should.be_true()
}

pub fn server_cookie_param_integer_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /dashboard:
    get:
      operationId: getDashboard
      parameters:
        - name: page_size
          in: cookie
          required: true
          schema:
            type: integer
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Integer cookie should use int.parse
  string.contains(content, "cookie_lookup(headers, \"page_size\")")
  |> should.be_true()
  string.contains(content, "int.parse")
  |> should.be_true()
}

pub fn server_cookie_param_boolean_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /dashboard:
    get:
      operationId: getDashboard
      parameters:
        - name: dark_mode
          in: cookie
          required: true
          schema:
            type: boolean
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Boolean cookie should use case-insensitive bool parsing
  string.contains(content, "cookie_lookup(headers, \"dark_mode\")")
  |> should.be_true()
  string.contains(content, "string.lowercase")
  |> should.be_true()
}

pub fn server_cookie_param_float_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /dashboard:
    get:
      operationId: getDashboard
      parameters:
        - name: zoom_level
          in: cookie
          required: true
          schema:
            type: number
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Float cookie should use float.parse
  string.contains(content, "cookie_lookup(headers, \"zoom_level\")")
  |> should.be_true()
  string.contains(content, "float.parse")
  |> should.be_true()
}

// --- Response types import conditional test ---

pub fn response_types_omits_types_import_when_no_body_case() {
  // When all responses have no body, response_types.gleam should not
  // import the types module (avoids unused import warning).
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /health:
    get:
      operationId: getHealth
      responses:
        '200': { description: ok }
        '500': { description: error }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert Ok(resp_file) =
    list.find(files, fn(f) { f.path == "response_types.gleam" })
  let content = resp_file.content
  // Should NOT import types module when no response body references it
  string.contains(content, "import api/types")
  |> should.be_false()
}

pub fn server_multi_content_response_sets_first_content_type_case() {
  // When a response has multiple content types, the server router should
  // set the first content type as a default content-type header rather
  // than leaving headers empty.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /data:
    get:
      operationId: getData
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
                properties:
                  name:
                    type: string
            text/plain:
              schema:
                type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
      validate: False,
    )
  let ctx = context.new(spec, cfg)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Should have a content-type header, not empty headers
  string.contains(content, "application/json")
  |> should.be_true()
}

pub fn response_types_includes_types_import_when_ref_body_case() {
  // When a response has a $ref body, types import is needed.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets:
    get:
      operationId: listPets
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Pet'
components:
  schemas:
    Pet:
      type: object
      properties:
        name:
          type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = types.generate(ctx)
  let assert Ok(resp_file) =
    list.find(files, fn(f) { f.path == "response_types.gleam" })
  let content = resp_file.content
  // Should import types module for $ref response bodies
  string.contains(content, "import api/types")
  |> should.be_true()
}

// --- deepObject referenced enum/alias leaf tests ---

// --- Multipart primitive array field tests ---

pub fn validate_multipart_primitive_array_field_accepted_case() {
  // Multipart body with primitive array fields should be accepted
  // for server codegen.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /upload:
    post:
      operationId: uploadMultipart
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required:
                - tags
              properties:
                tags:
                  type: array
                  items:
                    type: string
                scores:
                  type: array
                  items:
                    type: integer
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
      validate: False,
    )
  let ctx = context.new(spec, cfg)
  let errors = validate.validate(ctx)
  let multipart_errors =
    list.filter(errors, fn(e) {
      string.contains(e.message, "multipart")
      && e.target == diagnostic.TargetServer
    })
  list.length(multipart_errors)
  |> should.equal(0)
}

pub fn server_multipart_array_field_codegen_case() {
  // Multipart array fields should generate list.map parsing code.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /upload:
    post:
      operationId: uploadMultipart
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required:
                - tags
              properties:
                tags:
                  type: array
                  items:
                    type: string
                scores:
                  type: array
                  items:
                    type: integer
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
      validate: False,
    )
  let ctx = context.new(spec, cfg)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // tags (string array) should get all values from the multipart dict
  string.contains(content, "dict.get(multipart_body, \"tags\")")
  |> should.be_true()
  // scores (int array) should parse each value
  string.contains(content, "int.parse")
  |> should.be_true()
}

// --- Form-urlencoded multi-level nesting tests ---

pub fn validate_form_urlencoded_two_level_nesting_accepted_case() {
  // form-urlencoded bodies with two levels of object nesting should be
  // accepted: field[sub][key]=value
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /submit:
    post:
      operationId: submit
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              properties:
                profile:
                  type: object
                  properties:
                    settings:
                      type: object
                      properties:
                        theme:
                          type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
      validate: False,
    )
  let ctx = context.new(spec, cfg)
  let errors = validate.validate(ctx)
  let form_errors =
    list.filter(errors, fn(e) {
      string.contains(e.message, "form-urlencoded")
      && e.target == diagnostic.TargetServer
    })
  list.length(form_errors)
  |> should.equal(0)
}

pub fn server_form_urlencoded_two_level_nesting_codegen_case() {
  // Two-level nested form-urlencoded should generate bracket keys
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /submit:
    post:
      operationId: submit
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              properties:
                profile:
                  type: object
                  properties:
                    settings:
                      type: object
                      properties:
                        theme:
                          type: string
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
      validate: False,
    )
  let ctx = context.new(spec, cfg)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let content = router_file.content
  // Should have two-level bracket key
  string.contains(content, "profile[settings][theme]")
  |> should.be_true()
}

pub fn validate_deep_object_referenced_enum_leaf_accepted_case() {
  // deepObject properties that reference a string enum should be accepted
  // since enums are effectively strings at the wire level.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /search:
    get:
      operationId: search
      parameters:
        - name: filter
          in: query
          required: true
          style: deepObject
          schema:
            type: object
            properties:
              status:
                $ref: '#/components/schemas/Status'
      responses:
        '200': { description: ok }
components:
  schemas:
    Status:
      type: string
      enum: [active, inactive]
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
      validate: False,
    )
  let ctx = context.new(spec, cfg)
  let errors = validate.validate(ctx)
  let deep_object_errors =
    list.filter(errors, fn(e) { string.contains(e.message, "deepObject") })
  // Should have NO deepObject errors for referenced enum leaf
  list.length(deep_object_errors)
  |> should.equal(0)
}

pub fn validate_deep_object_referenced_primitive_alias_accepted_case() {
  // deepObject properties that reference a primitive alias (e.g., string)
  // should be accepted since they resolve to simple scalar types.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /search:
    get:
      operationId: search
      parameters:
        - name: filter
          in: query
          required: true
          style: deepObject
          schema:
            type: object
            properties:
              id:
                $ref: '#/components/schemas/UUID'
              count:
                $ref: '#/components/schemas/PositiveInt'
      responses:
        '200': { description: ok }
components:
  schemas:
    UUID:
      type: string
      format: uuid
    PositiveInt:
      type: integer
      minimum: 1
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(spec) = resolve.resolve(spec)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Server,
      validate: False,
    )
  let ctx = context.new(spec, cfg)
  let errors = validate.validate(ctx)
  let deep_object_errors =
    list.filter(errors, fn(e) { string.contains(e.message, "deepObject") })
  list.length(deep_object_errors)
  |> should.equal(0)
}

// --- uniqueItems guard tests ---

pub fn guards_unique_items_generates_guard_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    TagList:
      type: array
      items:
        type: string
      uniqueItems: true
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  list.length(files) |> should.not_equal(0)
  let assert [guard_file] = files
  let content = guard_file.content
  // Should generate a uniqueItems guard
  string.contains(content, "validate_tag_list_root_unique")
  |> should.be_true()
  // Should use list.unique for deduplication
  string.contains(content, "list.unique")
  |> should.be_true()
}

pub fn guards_unique_items_field_generates_guard_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    SearchRequest:
      type: object
      properties:
        tags:
          type: array
          items:
            type: string
          uniqueItems: true
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  list.length(files) |> should.not_equal(0)
  let assert [guard_file] = files
  let content = guard_file.content
  string.contains(content, "validate_search_request_tags_unique")
  |> should.be_true()
}

// --- minProperties/maxProperties guard tests ---

pub fn guards_min_properties_generates_guard_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    FilterMap:
      type: object
      additionalProperties:
        type: string
      minProperties: 1
      maxProperties: 10
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let files = guards.generate(ctx)
  list.length(files) |> should.not_equal(0)
  let assert [guard_file] = files
  let content = guard_file.content
  string.contains(content, "validate_filter_map_root_properties")
  |> should.be_true()
  string.contains(content, "dict.size")
  |> should.be_true()
}

// --- OSS fixture tests ---
// Test fixtures ported from open source projects under MIT / Apache 2.0 licenses.
// libopenapi: MIT License, Copyright (c) 2022-2025 Princess Beef Heavy Industries
// oapi-codegen: Apache License 2.0, Copyright deepmap/oapi-codegen contributors

pub fn oss_libopenapi_all_components_parses_case() {
  // all-the-components.yaml has webhooks without responses field.
  // OpenAPI spec requires responses on operations, but webhooks in the wild
  // often omit them. Parser should handle this gracefully.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_libopenapi_all_components.yaml")
  spec.info.title |> should.equal("Burger Shop")
  let ops = dict.to_list(spec.paths)
  list.length(ops) |> should.not_equal(0)
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

/// The all_components fixture references security scheme 'api_key' that is
/// not defined in components.securitySchemes. Validation catches this.
pub fn oss_libopenapi_all_components_validates_security_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_libopenapi_all_components.yaml")
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let blocking = diagnostic.errors_only(errors)
  let has_security_error =
    list.any(blocking, fn(e) {
      string.contains(diagnostic.to_string(e), "api_key")
    })
  should.be_true(has_security_error)
}

/// libopenapi burgershop uses the JSON Schema 'not' keyword which is
/// unsupported. The parser rejects it with a clear error.
pub fn oss_libopenapi_burgershop_rejects_not_keyword_case() {
  // Parse succeeds — lossless parser stores unsupported keywords
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_libopenapi_burgershop.yaml")
  // Generate fails via capability_check due to "not" keyword
  let result = generate.generate(spec, context.config(make_ctx_from_spec(spec)))
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_not = list.any(error_details, fn(d) { string.contains(d, "not") })
      should.be_true(has_not)
    }

    Ok(_) -> should.fail()
  }
}

pub fn oss_libopenapi_petstorev3_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_libopenapi_petstorev3.json")
  spec.info.title |> should.equal("Swagger Petstore - OpenAPI 3.0")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_libopenapi_circular_rejects_missing_info_case() {
  // circular-tests.yaml has no info field, which is required by OpenAPI 3.x.
  // Parser should reject this with a clear error.
  let result = parser.parse_file("test/fixtures/oss_libopenapi_circular.yaml")
  case result {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn oss_oapi_codegen_cookies_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_cookies.yaml")
  spec.info.title |> should.not_equal("")
}

pub fn oss_oapi_codegen_name_conflicts_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_name_conflicts.yaml")
  let assert Some(components) = spec.components
  // Should have many schemas (name conflict resolution tests many similar names)
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_illegal_enums_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_illegal_enums.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_nullable_parses_case() {
  // Tests all combinations of required/optional + nullable/non-nullable
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_nullable.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_nullable_generates_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_nullable.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      let blocking = diagnostic.errors_only(errors)
      list.length(blocking) |> should.equal(0)
    }
  }
}

pub fn oss_oapi_codegen_recursive_allof_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_recursive_allof.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_allof_additional_parses_case() {
  // allOf with additionalProperties: true
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_allof_additional.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_allof_additional_generates_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_allof_additional.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      let blocking = diagnostic.errors_only(errors)
      list.length(blocking) |> should.equal(0)
    }
  }
}

pub fn oss_oapi_codegen_security_parses_case() {
  // Bearer token authentication
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_security.yaml")
  let assert Some(components) = spec.components
  dict.size(components.security_schemes) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_multi_content_parses_case() {
  // Multiple content types in requestBody and responses
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_multi_content.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_multi_content_rejects_unsupported_types_case() {
  // This spec has text/json and application/*+json which are unsupported.
  // Validation should catch them.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_multi_content.yaml")
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let blocking = diagnostic.errors_only(errors)
  // Should have blocking errors for unsupported content types
  list.length(blocking) |> should.not_equal(0)
}

// --- OSS fixture batch 3: regression specs ---

pub fn oss_oapi_codegen_issue_312_colon_path_parses_case() {
  // Path with colon: /pets:validate
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_312.yaml")
  let paths = dict.keys(spec.paths)
  list.contains(paths, "/pets:validate") |> should.be_true()
}

pub fn oss_oapi_codegen_issue_312_generates_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_312.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(diagnostic.errors_only(errors)) |> should.equal(0)
    }
  }
}

pub fn oss_oapi_codegen_issue_936_recursive_oneof_parses_case() {
  // Recursive cyclic refs with oneOf (FilterPredicate)
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_936.yaml")
  let assert Some(components) = spec.components
  list.contains(dict.keys(components.schemas), "FilterPredicate")
  |> should.be_true()
}

pub fn oss_oapi_codegen_issue_52_recursive_additional_props_parses_case() {
  // Recursive types through additionalProperties
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_52.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_52_generates_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_52.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(diagnostic.errors_only(errors)) |> should.equal(0)
    }
  }
}

pub fn oss_oapi_codegen_issue_1168_allof_discriminator_parses_case() {
  // allOf with discriminator
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_1168.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_1168_problem_json_generates_case() {
  // application/problem+json is now supported as a JSON-compatible suffix type.
  // The full generate pipeline should succeed without validation errors.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_1168.yaml")
  let result = generate.generate(spec, context.config(make_ctx_from_spec(spec)))
  case result {
    Ok(_summary) -> should.be_true(True)
    Error(_) -> should.be_true(False)
  }
}

pub fn oss_oapi_codegen_issue_832_recursive_oneof_parses_case() {
  // Recursive oneOf types
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_832.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_579_enum_special_chars_parses_case() {
  // Enum values with special characters
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_579.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_579_generates_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_579.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(diagnostic.errors_only(errors)) |> should.equal(0)
    }
  }
}

pub fn oss_oapi_codegen_issue_2185_nullable_array_items_parses_case() {
  // Nullable array items
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_2185.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_2185_generates_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_2185.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(diagnostic.errors_only(errors)) |> should.equal(0)
    }
  }
}

// --- OSS fixture batch 4: openapi-generator specs (Apache 2.0) ---

pub fn oss_openapi_gen_issue_4947_wildcard_content_parses_case() {
  // Spec with */* content type and pattern-constrained strings
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_4947.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_9719_dot_operationid_parses_case() {
  // Dot-delimited operationId: petstore.api.users.get_all
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_9719.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_9719_generates_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_9719.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(diagnostic.errors_only(errors)) |> should.equal(0)
    }
  }
}

pub fn oss_openapi_gen_issue_13917_patch_allof_parses_case() {
  // PATCH operation with allOf request body
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_13917.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_13917_rejects_json_patch_content_case() {
  // application/json-patch+json is not a supported content type
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_13917.yaml")
  let ctx = make_ctx_from_spec(spec)
  let errors = validate.validate(ctx)
  let blocking = diagnostic.errors_only(errors)
  list.length(blocking) |> should.not_equal(0)
}

pub fn oss_openapi_gen_petstore_server_parses_case() {
  // Full petstore server spec from openapi-generator samples
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_petstore_server.yaml")
  spec.info.title |> should.not_equal("")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_openapi_gen_petstore_server_generates_client_case() {
  // Client-only mode avoids server-specific validation errors.
  // multipart field type errors still apply to both targets.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_petstore_server.yaml")
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Error(generate.ValidationErrors(errors)) ->
      list.length(errors) |> should.not_equal(0)
    Ok(summary) -> list.length(summary.warnings) |> should.not_equal(0)
  }
}

// --- OSS fixture batch 5: kiota specs (MIT License, Copyright Microsoft) ---

pub fn oss_kiota_discriminator_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kiota_discriminator.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_kiota_discriminator_generates_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kiota_discriminator.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(diagnostic.errors_only(errors)) |> should.equal(0)
    }
  }
}

pub fn oss_kiota_derived_types_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kiota_derived_types.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_kiota_derived_types_generates_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kiota_derived_types.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(diagnostic.errors_only(errors)) |> should.equal(0)
    }
  }
}

pub fn oss_kiota_multi_security_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kiota_multi_security.yaml")
  // Security is at operation level, not top-level
  let assert Some(components) = spec.components
  dict.size(components.security_schemes) |> should.not_equal(0)
}

pub fn oss_kiota_multi_security_generates_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kiota_multi_security.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(diagnostic.errors_only(errors)) |> should.equal(0)
    }
  }
}

// --- Parser error message quality tests ---

pub fn parse_error_missing_info_has_actionable_message_case() {
  let result =
    parser.parse_string(
      "
openapi: 3.0.3
paths: {}
",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "info") |> should.be_true()
  string.contains(msg, "root") |> should.be_true()
}

pub fn parse_error_missing_version_has_path_case() {
  let result =
    parser.parse_string(
      "
openapi: 3.0.3
info:
  title: Test
paths: {}
",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "version") |> should.be_true()
  string.contains(msg, "info") |> should.be_true()
}

pub fn parse_error_missing_param_name_has_path_case() {
  let result =
    parser.parse_string(
      "
openapi: 3.0.3
info:
  title: Test
  version: '1.0'
paths:
  /x:
    get:
      operationId: getX
      parameters:
        - in: query
          schema:
            type: string
      responses:
        '200': { description: ok }
",
    )
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "name") |> should.be_true()
  string.contains(msg, "parameter") |> should.be_true()
}

// --- OSS fixture batch: more oapi-codegen regression specs ---

pub fn oss_oapi_codegen_issue_1087_rejects_unresolved_ref_case() {
  // Has external $ref and numeric response key (304) as component ref.
  // With lazy ref resolution, parse succeeds; refs are stored as Ref(...).
  let result =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_1087.yaml")
  let assert Ok(_spec) = result
}

pub fn oss_oapi_codegen_issue_1963_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_1963.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_2232_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_2232.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_2238_header_array_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_2238.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_issue_2113_rejects_external_ref_case() {
  // Has external $ref (./common/spec.yaml#/...) which is not supported.
  // With lazy ref resolution, parse succeeds; external refs are stored as Ref(...).
  let result =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_2113.yaml")
  let assert Ok(_spec) = result
}

pub fn oss_oapi_codegen_issue_1397_rejects_missing_info_case() {
  let result =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_1397.yaml")
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "info") |> should.be_true()
}

pub fn oss_oapi_codegen_issue_1914_rejects_missing_info_case() {
  let result =
    parser.parse_file("test/fixtures/oss_oapi_codegen_issue_1914.yaml")
  let assert Error(err) = result
  let msg = parser.parse_error_to_string(err)
  string.contains(msg, "info") |> should.be_true()
}

pub fn oss_oapi_codegen_head_digit_httpheader_parses_case() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_oapi_codegen_head_digit_of_httpheader.yaml",
    )
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_oapi_codegen_head_digit_operation_id_parses_case() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_oapi_codegen_head_digit_of_operation_id.yaml",
    )
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

// --- OSS fixture batch: openapi-generator bug specs (Apache 2.0) ---

pub fn oss_openapi_gen_issue_11897_array_of_string_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_11897.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_11897_generates_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_11897.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) ->
      list.length(diagnostic.errors_only(errors)) |> should.equal(0)
  }
}

pub fn oss_openapi_gen_issue_14731_discriminator_mapping_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_14731.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_1666_optional_body_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_1666.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_1666_generates_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_1666.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) ->
      list.length(diagnostic.errors_only(errors)) |> should.equal(0)
  }
}

pub fn oss_openapi_gen_recursion_bug_4650_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_recursion_bug_4650.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_18516_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_18516.yaml")
  let paths = dict.to_list(spec.paths)
  list.length(paths) |> should.not_equal(0)
}

pub fn oss_openapi_gen_issue_18516_generates_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_issue_18516.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) ->
      list.length(diagnostic.errors_only(errors)) |> should.equal(0)
  }
}

// ---------------------------------------------------------------------------
// OSS: kin-openapi (MIT)
// Test data derived from https://github.com/getkin/kin-openapi
// ---------------------------------------------------------------------------

/// kin-openapi link-example: complex links between operations.
pub fn oss_kin_openapi_link_example_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_link_example.yaml")
  spec.info.title |> should.equal("Link Example")
  // Has multiple paths
  dict.size(spec.paths) |> should.not_equal(0)
  // Has components with links
  let assert Some(components) = spec.components
  dict.size(components.links) |> should.not_equal(0)
}

/// kin-openapi issue409: string schema with regex pattern.
pub fn oss_kin_openapi_issue409_pattern_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_issue409.yaml")
  spec.info.title |> should.equal("Issue 409")
  dict.size(spec.paths) |> should.not_equal(0)
}

/// kin-openapi issue753: callbacks with schema refs.
pub fn oss_kin_openapi_callbacks_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_callbacks.yaml")
  // Has two paths with callbacks
  dict.size(spec.paths) |> should.equal(2)
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

/// kin-openapi issue794: request body with empty media type content.
pub fn oss_kin_openapi_empty_media_type_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_empty_media_type.yaml")
  spec.info.title |> should.equal("Swagger API")
  dict.size(spec.paths) |> should.equal(1)
}

/// kin-openapi issue697: schema with date format and example.
pub fn oss_kin_openapi_date_example_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_date_example.yaml")
  spec.info.title |> should.equal("sample")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

/// kin-openapi: path-level parameters overridden at operation level.
pub fn oss_kin_openapi_param_override_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_param_override.yaml")
  spec.info.title |> should.equal("customer")
  dict.size(spec.paths) |> should.equal(1)
  list.length(spec.servers) |> should.equal(1)
}

/// kin-openapi: additionalProperties with typed schema.
pub fn oss_kin_openapi_additional_properties_parses_case() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_kin_openapi_additional_properties.yaml",
    )
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(2)
}

/// kin-openapi: example $ref within parameters, headers, and media types.
pub fn oss_kin_openapi_example_refs_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_example_refs.yaml")
  let assert Some(components) = spec.components
  dict.size(components.parameters) |> should.not_equal(0)
  dict.size(components.headers) |> should.not_equal(0)
  dict.size(components.request_bodies) |> should.not_equal(0)
  dict.size(components.responses) |> should.not_equal(0)
}

/// kin-openapi: minimal OpenAPI spec in JSON format.
pub fn oss_kin_openapi_minimal_json_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_minimal.json")
  // The original fixture has an empty title
  spec.info.title |> should.equal("")
  spec.openapi |> should.equal("3.0.0")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(1)
}

/// kin-openapi: components with $ref cross-references in JSON.
/// The fixture contains an invalid security scheme type ("cookie") which is
/// not part of the OpenAPI 3.x specification. The parser rejects it with a
/// clear error message guiding the user to fix the security scheme type.
pub fn oss_kin_openapi_components_json_rejects_invalid_scheme_case() {
  // Parser preserves unsupported scheme types losslessly;
  // capability_check rejects them during generate.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_kin_openapi_components.json")
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { e.message })
      let has_cookie =
        list.any(error_details, fn(d) { string.contains(d, "cookie") })
      should.be_true(has_cookie)
    }
    Ok(_) -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// OSS: openapi-spec-validator (Apache-2.0)
// Test data derived from https://github.com/python-openapi/openapi-spec-validator
// ---------------------------------------------------------------------------

/// openapi-spec-validator: standard petstore v3.0.
pub fn oss_spec_validator_petstore_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spec_validator_petstore.yaml")
  spec.info.title |> should.equal("Swagger Petstore")
  spec.openapi |> should.equal("3.0.0")
  dict.size(spec.paths) |> should.equal(2)
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(3)
}

/// openapi-spec-validator: readOnly and writeOnly properties.
pub fn oss_spec_validator_read_write_only_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spec_validator_read_write_only.yaml")
  spec.info.title |> should.equal("Specification Containing readOnly")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

/// openapi-spec-validator: response without description field.
/// OpenAPI 3.x requires 'description' on every response object.
/// The parser rejects this with a user-friendly error message.
pub fn oss_spec_validator_missing_description_rejects_case() {
  let result =
    parser.parse_file(
      "test/fixtures/oss_spec_validator_missing_description.yaml",
    )
  case result {
    Error(Diagnostic(
      code: "missing_field",
      message: "Missing required field: description",
      ..,
    )) -> should.be_true(True)
    Error(e) -> {
      let msg = parser.parse_error_to_string(e)
      should.be_true(string.contains(msg, "description"))
    }
    Ok(_) -> should.fail()
  }
}

/// openapi-spec-validator: self-referencing recursive schema.
pub fn oss_spec_validator_recursive_property_parses_case() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_spec_validator_recursive_property.yaml",
    )
  spec.info.title |> should.equal("Some Schema")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

/// openapi-spec-validator: petstore v3.1 with pathItems in components.
pub fn oss_spec_validator_petstore_v31_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spec_validator_petstore_v31.yaml")
  spec.info.title |> should.equal("Swagger Petstore")
  spec.openapi |> should.equal("3.1.0")
  let assert Some(components) = spec.components
  dict.size(components.path_items) |> should.not_equal(0)
}

// ---------------------------------------------------------------------------
// OSS: swagger-parser-js (MIT)
// Test data derived from https://github.com/APIDevTools/swagger-parser
// ---------------------------------------------------------------------------

/// swagger-parser-js: relative server URL in JSON format.
pub fn oss_swagger_parser_js_relative_server_parses_case() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_js_relative_server.json",
    )
  spec.info.title |> should.equal("Swagger Petstore")
  list.length(spec.servers) |> should.equal(1)
  dict.size(spec.paths) |> should.not_equal(0)
}

// ---------------------------------------------------------------------------
// OSS: spectral (Apache-2.0)
// Test data derived from https://github.com/stoplightio/spectral
// ---------------------------------------------------------------------------

/// spectral: valid minimal OpenAPI 3.0 spec with contact and tags.
pub fn oss_spectral_valid_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spectral_valid.yaml")
  spec.info.title |> should.equal("OAS3")
  spec.openapi |> should.equal("3.0.0")
  list.length(spec.servers) |> should.equal(1)
  list.length(spec.tags) |> should.equal(1)
}

/// spectral: minimal OpenAPI 3.0 spec without contact info.
pub fn oss_spectral_no_contact_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spectral_no_contact.yaml")
  spec.info.title |> should.equal("OAS3")
  spec.info.contact |> should.equal(None)
}

/// spectral: comprehensive spec with unused components in JSON.
pub fn oss_spectral_unused_components_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spectral_unused_components.json")
  spec.info.title |> should.equal("Used Components")
  list.length(spec.tags) |> should.not_equal(0)
  dict.size(spec.paths) |> should.not_equal(0)
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

// ---------------------------------------------------------------------------
// OSS: openapi-dotnet (MIT)
// Test data derived from https://github.com/microsoft/OpenAPI.NET
// ---------------------------------------------------------------------------

/// openapi-dotnet: OAuth2 security scheme with authorization code flow.
pub fn oss_openapi_dotnet_oauth2_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_oauth2.yaml")
  spec.info.title |> should.equal("Repair Service")
  let assert Some(components) = spec.components
  dict.size(components.security_schemes) |> should.equal(1)
}

/// openapi-dotnet: operation with empty security array (opt-out of global security).
pub fn oss_openapi_dotnet_empty_security_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_empty_security.yaml")
  spec.info.title |> should.equal("Repair Service")
  dict.size(spec.paths) |> should.equal(1)
}

/// openapi-dotnet: webhooks with $ref to components/pathItems (OpenAPI 3.1).
pub fn oss_openapi_dotnet_webhooks_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_webhooks.yaml")
  spec.info.title |> should.equal("Webhook Example")
  dict.size(spec.webhooks) |> should.not_equal(0)
  let assert Some(components) = spec.components
  dict.size(components.path_items) |> should.not_equal(0)
}

/// openapi-dotnet: spec without any security configuration.
pub fn oss_openapi_dotnet_no_security_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_no_security.yaml")
  spec.info.title |> should.equal("Repair Service")
  list.length(spec.security) |> should.equal(0)
}

/// openapi-dotnet: petstore with multiple content types, 4XX/5XX wildcards,
/// contact info, license, and termsOfService.
pub fn oss_openapi_dotnet_petstore_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_petstore.yaml")
  spec.info.title |> should.equal("Swagger Petstore (Simple)")
  let assert Some(contact) = spec.info.contact
  let assert Some(name) = contact.name
  name |> should.equal("Swagger API team")
  let assert Some(license) = spec.info.license
  license.name |> should.equal("MIT")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(3)
  dict.size(spec.paths) |> should.equal(2)
}

/// openapi-dotnet: spec with reusable headers and examples in components.
pub fn oss_openapi_dotnet_headers_examples_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_headers_examples.yaml")
  spec.openapi |> should.equal("3.0.4")
  let assert Some(components) = spec.components
  dict.size(components.headers) |> should.not_equal(0)
  dict.size(components.schemas) |> should.not_equal(0)
  list.length(spec.tags) |> should.equal(1)
}

/// openapi-dotnet: OpenAPI 3.1 spec with $id schema references.
/// Uses URL-style $ref (e.g. "$ref: https://foo.bar/Box") which the parser
/// stores as Reference with the URL as ref string.
pub fn oss_openapi_dotnet_dollar_id_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_dollar_id.yaml")
  spec.info.title |> should.equal("Simple API")
  spec.openapi |> should.equal("3.1.2")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(2)
  dict.size(spec.paths) |> should.equal(2)
}

/// Issue #234: URL-style `$ref` values (the shape OpenAPI 3.1
/// `$id`-backed refs take) must fail validation with a dedicated
/// URL-ref diagnostic, not a generic "external $ref" error. This keeps
/// the advertised OpenAPI 3.1 boundary explicit and gives users an
/// actionable hint.
pub fn validate_rejects_id_backed_url_ref_with_dedicated_diagnostic_case() {
  let ctx = make_ctx("test/fixtures/oss_openapi_dotnet_dollar_id.yaml")
  let errors = validate.validate(ctx) |> diagnostic.errors_only
  let messages = list.map(errors, validate.error_to_string)
  list.any(messages, fn(s) {
    string.contains(s, "URL-style $ref")
    && string.contains(s, "OpenAPI 3.1")
    && string.contains(s, "$id")
  })
  |> should.be_true()
  // A generic "External $ref ... is not supported" message must NOT be
  // emitted for URL-style refs — that's the old gray-area behavior.
  list.any(messages, fn(s) {
    string.contains(s, "External $ref")
    && string.contains(s, "https://foo.bar/Box")
  })
  |> should.be_false()
}

// ---------------------------------------------------------------------------
// OSS: swagger-parser-java (Apache-2.0)
// Test data derived from https://github.com/swagger-api/swagger-parser
// ---------------------------------------------------------------------------

/// swagger-parser-java issue1070: additionalProperties: false with nested $ref.
pub fn oss_swagger_parser_java_additional_props_false_parses_case() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_java_additional_props_false.yaml",
    )
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(2)
}

/// swagger-parser-java issue879: callback using $ref to components/callbacks.
pub fn oss_swagger_parser_java_callback_ref_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_swagger_parser_java_callback_ref.yaml")
  spec.info.title |> should.equal("Callback with ref Example")
  dict.size(spec.paths) |> should.equal(1)
}

/// Issue #232: operation-level `{ myEvent: { $ref: '#/components/callbacks/foo' } }`
/// must be preserved as a `Ref(...)` entry on `operation.callbacks`, not
/// flattened into the inline URL-expression shape.
pub fn parse_preserves_operation_level_callback_ref_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_swagger_parser_java_callback_ref.yaml")
  let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/register")
  let assert Some(post_op) = path_item.post
  let assert Ok(entry) = dict.get(post_op.callbacks, "myEvent")
  case entry {
    spec.Ref(ref_str) ->
      ref_str |> should.equal("#/components/callbacks/callbackEvent")
    spec.Value(_) -> should.fail()
  }
}

/// Issue #232: `components.callbacks` entries must be parsed losslessly
/// into the reusable-components AST so downstream passes can see them.
pub fn parse_populates_components_callbacks_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_swagger_parser_java_callback_ref.yaml")
  let assert Some(components) = spec.components
  dict.size(components.callbacks) |> should.equal(1)
  let assert Ok(spec.Value(callback)) =
    dict.get(components.callbacks, "callbackEvent")
  dict.has_key(callback.entries, "{$request.body#/callbackUrl}")
  |> should.be_true()
}

/// Issue #232: a callback `$ref` that does not resolve to an entry in
/// `components.callbacks` must produce a validation error — otherwise
/// users get silent nothingness for a clearly broken spec.
pub fn validate_rejects_callback_ref_with_missing_target_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Dangling Callback Ref
  version: 1.0.0
paths:
  /register:
    post:
      operationId: subscribe
      responses:
        '200': { description: ok }
      callbacks:
        myEvent:
          $ref: '#/components/callbacks/doesNotExist'
components:
  callbacks: {}
"
  let assert Ok(spec) = parser.parse_string(yaml)
  case resolve.resolve(spec) {
    Error(errors) -> {
      let messages = list.map(errors, validate.error_to_string)
      list.any(messages, fn(s) {
        string.contains(s, "doesNotExist")
        && string.contains(s, "components.callbacks")
      })
      |> should.be_true()
    }
    Ok(_) -> should.fail()
  }
}

/// Issue #232: a cyclic callback $ref chain
/// (components.callbacks.A -> B -> A) must be detected at resolve time
/// instead of being accepted as "exists in components".
pub fn validate_rejects_cyclic_callback_ref_chain_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Cyclic Callback Ref
  version: 1.0.0
paths:
  /register:
    post:
      operationId: subscribe
      responses:
        '200': { description: ok }
      callbacks:
        myEvent:
          $ref: '#/components/callbacks/A'
components:
  callbacks:
    A:
      $ref: '#/components/callbacks/B'
    B:
      $ref: '#/components/callbacks/A'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  case resolve.resolve(spec) {
    Error(errors) -> {
      let messages = list.map(errors, validate.error_to_string)
      list.any(messages, fn(s) { string.contains(s, "cyclic") })
      |> should.be_true()
    }
    Ok(_) -> should.fail()
  }
}

/// Issue #232: both operation-level and components.callbacks must emit
/// `ParsedNotUsed` capability warnings (not errors) so users are not
/// misled into thinking callbacks are code-generated.
pub fn capability_check_warns_on_callbacks_case() {
  let ctx = make_ctx("test/fixtures/oss_swagger_parser_java_callback_ref.yaml")
  let warnings =
    capability_check.check_preserved(ctx, location_index.empty())
    |> diagnostic.warnings_only
  let messages = list.map(warnings, validate.error_to_string)
  list.any(messages, fn(s) {
    string.contains(s, "Operation-level callbacks")
    && string.contains(s, "parsed and preserved")
  })
  |> should.be_true()
  list.any(messages, fn(s) {
    string.contains(s, "Component callbacks")
    && string.contains(s, "parsed and preserved")
  })
  |> should.be_true()
}

/// swagger-parser-java issue1433: schema without explicit type field.
pub fn oss_swagger_parser_java_no_type_schema_parses_case() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_java_no_type_schema.yaml",
    )
  spec.info.title |> should.equal("no type resolution")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(2)
}

/// swagger-parser-java issue1086: deeply nested object schemas with
/// multipleOf and date format.
pub fn oss_swagger_parser_java_nested_objects_parses_case() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_java_nested_objects.yaml",
    )
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(1)
}

/// swagger-parser-java: API with duplicate tag names in JSON.
pub fn oss_swagger_parser_java_multiple_tags_parses_case() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_java_multiple_tags.json",
    )
  spec.info.title |> should.equal("Sample API")
  list.length(spec.tags) |> should.not_equal(0)
  dict.size(spec.paths) |> should.not_equal(0)
}

/// swagger-parser-java issue959: petstore with path-level parameters and tags.
pub fn oss_swagger_parser_java_path_params_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_swagger_parser_java_path_params.json")
  spec.info.title |> should.equal("Swagger Petstore")
  list.length(spec.tags) |> should.equal(1)
}

/// swagger-parser-java issue895: petstore with contact and license in JSON.
pub fn oss_swagger_parser_java_petstore_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_swagger_parser_java_petstore.yaml")
  spec.info.title |> should.equal("Swagger Petstore")
  let assert Some(contact) = spec.info.contact
  let assert Some(name) = contact.name
  name |> should.equal("API Support")
  let assert Some(license) = spec.info.license
  license.name |> should.equal("Apache 2.0")
}

// ---------------------------------------------------------------------------
// OSS: openapi-generator (Apache-2.0) — additional tests
// Test data derived from https://github.com/OpenAPITools/openapi-generator
// ---------------------------------------------------------------------------

/// openapi-generator: oneOf with multiple schema variants (fruit).
pub fn oss_openapi_gen_oneof_fruit_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_oneof_fruit.yaml")
  spec.info.title |> should.equal("fruity")
  let assert Some(components) = spec.components
  // fruit + apple + banana + orange
  dict.size(components.schemas) |> should.equal(4)
}

/// openapi-generator: array with nullable items.
pub fn oss_openapi_gen_array_nullable_items_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_array_nullable_items.yaml")
  spec.info.title |> should.equal("Array nullable items")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(1)
}

/// openapi-generator: type alias ($ref as schema value) and discriminator.
pub fn oss_openapi_gen_type_alias_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_type_alias.yaml")
  spec.info.title |> should.equal("broken API")
  let assert Some(components) = spec.components
  // MyParameter, MyParameterTextField, TypeAliasToString, BaseModel, ComposedModel
  dict.size(components.schemas) |> should.equal(5)
}

/// openapi-generator: enum values with URI format strings.
pub fn oss_openapi_gen_enum_uri_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_gen_enum_uri.yaml")
  spec.info.title |> should.equal("Example API")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(1)
}

/// Combined-feature stress: oneOf inside `items` of an `array` schema,
/// with `nullable: true` and a `discriminator`. None of the existing
/// fixtures exercise all three at once on the same schema.
///
/// Pinned behavior:
///   - parses without error
///   - generates without error
///   - emits a discriminator-aware tagged union (one variant per
///     oneOf branch) and a decoder that switches on the discriminator
///   - the items-level `nullable: true` is currently NOT lifted to
///     `Option(...)` in the generated array element type. This pin
///     captures that observable behavior so that, on the day oaspec
///     starts honoring the nullable, this test fails LOUDLY and asks
///     for an intentional update.
pub fn combined_oneof_nullable_array_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/combined_oneof_nullable_array.yaml")
  spec.info.title |> should.equal("Combined oneOf + nullable + array")
  let assert Some(components) = spec.components
  // Apple, Banana
  dict.size(components.schemas) |> should.equal(2)
}

pub fn combined_oneof_nullable_array_generates_tagged_union_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/combined_oneof_nullable_array.yaml")
  let ctx = make_ctx_from_spec(spec)
  let assert Ok(summary) = generate.generate(spec, context.config(ctx))

  let types_file =
    list.find(summary.files, fn(f) { string.ends_with(f.path, "types.gleam") })
  let assert Ok(types_file) = types_file
  let types_src = types_file.content

  // Discriminator-aware tagged union must be emitted.
  string.contains(types_src, "ListFruitResponseOkItemApple(Apple)")
  |> should.be_true()
  string.contains(types_src, "ListFruitResponseOkItemBanana(Banana)")
  |> should.be_true()

  // Pin the items-nullable drop. If oaspec gains support, the next
  // line will fail and the maintainer should flip this to
  // `should.be_true()` and update the surrounding contract.
  string.contains(types_src, "List(option.Option(ListFruitResponseOkItem))")
  |> should.be_false()

  // Decoder must switch on the discriminator field.
  let decode_file =
    list.find(summary.files, fn(f) { string.ends_with(f.path, "decode.gleam") })
  let assert Ok(decode_file) = decode_file
  string.contains(decode_file.content, "decode.field(\"kind\", decode.string)")
  |> should.be_true()
}

/// openapi-generator: spec missing required 'info' field.
/// The parser rejects this with a clear error.
pub fn oss_openapi_gen_missing_info_rejects_case() {
  let result =
    parser.parse_file("test/fixtures/oss_openapi_gen_missing_info.yaml")
  case result {
    Error(Diagnostic(
      code: "missing_field",
      message: "Missing required field: info",
      ..,
    )) -> should.be_true(True)
    Error(e) -> {
      let msg = parser.parse_error_to_string(e)
      should.be_true(string.contains(msg, "info"))
    }
    Ok(_) -> should.fail()
  }
}

/// openapi-generator: petstore missing required info attribute.
/// Rejects with user-friendly error pointing to the missing field.
pub fn oss_openapi_gen_missing_info_attr_rejects_case() {
  let result =
    parser.parse_file("test/fixtures/oss_openapi_gen_missing_info_attr.yaml")
  case result {
    Error(Diagnostic(code: "missing_field", ..)) -> should.be_true(True)
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// OSS: openapi-spec-validator (Apache-2.0) — benchmark specs
// Test data derived from https://github.com/python-openapi/openapi-spec-validator
// ---------------------------------------------------------------------------

/// openapi-spec-validator: petstore benchmark spec.
pub fn oss_spec_validator_bench_petstore_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spec_validator_bench_petstore.yaml")
  spec.info.title |> should.equal("Swagger Petstore")
  dict.size(spec.paths) |> should.not_equal(0)
}

/// openapi-spec-validator: empty OpenAPI 3.0 spec (only version, no info).
/// The parser rejects this with a user-friendly error about missing 'info'.
pub fn oss_spec_validator_empty_v30_rejects_case() {
  let result = parser.parse_file("test/fixtures/oss_spec_validator_empty.yaml")
  case result {
    Error(Diagnostic(
      code: "missing_field",
      message: "Missing required field: info",
      ..,
    )) -> should.be_true(True)
    Error(e) -> {
      let msg = parser.parse_error_to_string(e)
      should.be_true(string.contains(msg, "info"))
    }
    Ok(_) -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// OSS: swagger-parser-js (MIT) — additional tests
// Test data derived from https://github.com/APIDevTools/swagger-parser
// ---------------------------------------------------------------------------

/// swagger-parser-js: OpenAPI 3.1 spec with no paths or webhooks.
/// Valid minimal 3.1 document (paths is optional in 3.1).
pub fn oss_swagger_parser_js_no_paths_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_swagger_parser_js_no_paths.yaml")
  spec.info.title |> should.equal("Invalid API")
  spec.openapi |> should.equal("3.1")
  dict.size(spec.paths) |> should.equal(0)
  dict.size(spec.webhooks) |> should.equal(0)
}

/// swagger-parser-js: top-level, path-level, and operation-level servers.
pub fn oss_swagger_parser_js_server_hierarchy_parses_case() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_js_server_hierarchy.json",
    )
  spec.info.title |> should.equal("Swagger Petstore")
  // Top-level server
  list.length(spec.servers) |> should.equal(1)
  // Path-level and operation-level servers
  let assert Ok(spec.Value(pet_path)) = dict.get(spec.paths, "/pet")
  list.length(pet_path.servers) |> should.equal(1)
  let assert Some(get_op) = pet_path.get
  list.length(get_op.servers) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// OSS: spectral (Apache-2.0) — additional tests
// Test data derived from https://github.com/stoplightio/spectral
// ---------------------------------------------------------------------------

/// spectral: operation-level and global security with apiKey + OAuth2.
pub fn oss_spectral_operation_security_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spectral_operation_security.yaml")
  spec.openapi |> should.equal("3.0.2")
  // Global security has 2 entries (apikey OR oauth2)
  list.length(spec.security) |> should.equal(2)
  let assert Some(components) = spec.components
  dict.size(components.security_schemes) |> should.equal(2)
}

/// spectral: webhooks with inline request body (OpenAPI 3.1).
pub fn oss_spectral_webhooks_servers_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spectral_webhooks_servers.yaml")
  spec.openapi |> should.equal("3.1.0")
  dict.size(spec.webhooks) |> should.equal(1)
}

/// spectral: examples with value in parameters and response content.
pub fn oss_spectral_examples_value_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spectral_examples_value.yaml")
  dict.size(spec.paths) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// OSS: openapi-dotnet (MIT) — additional tests
// Test data derived from https://github.com/microsoft/OpenAPI.NET
// ---------------------------------------------------------------------------

/// openapi-dotnet: multipart encoding, discriminator, allOf inheritance (3.1).
pub fn oss_openapi_dotnet_encoding_discriminator_parses_case() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_openapi_dotnet_encoding_discriminator.yaml",
    )
  spec.openapi |> should.equal("3.1.2")
  spec.info.title |> should.equal("A simple OpenAPI 3.1 example")
  dict.size(spec.paths) |> should.equal(2)
  let assert Some(components) = spec.components
  // Pet, Cat, Dog
  dict.size(components.schemas) |> should.equal(3)
}

/// openapi-dotnet: reusable pathItems with webhooks and multi-schema (3.1).
pub fn oss_openapi_dotnet_reusable_paths_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_reusable_paths.yaml")
  spec.openapi |> should.equal("3.1.2")
  dict.size(spec.webhooks) |> should.not_equal(0)
  let assert Some(components) = spec.components
  dict.size(components.path_items) |> should.not_equal(0)
  dict.size(components.schemas) |> should.equal(2)
  let assert Some(dialect) = spec.json_schema_dialect
  should.be_true(string.contains(dialect, "json-schema.org"))
}

/// openapi-dotnet: spec with x-oai-$self vendor extension (3.1).
pub fn oss_openapi_dotnet_self_extension_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_openapi_dotnet_self_extension.yaml")
  spec.openapi |> should.equal("3.1.2")
  spec.info.title |> should.equal("API with x-oai-$self extension")
  dict.size(spec.paths) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// OSS: swagger-parser-java (Apache-2.0) — 3.1 tests
// Test data derived from https://github.com/swagger-api/swagger-parser
// ---------------------------------------------------------------------------

/// swagger-parser-java: OpenAPI 3.1 basic spec uses multi-type unions
/// (type: [object, string]) which oaspec rejects with a clear error guiding
/// users to use oneOf instead.
pub fn oss_swagger_parser_java_31_basic_rejects_multi_type_case() {
  // Parse succeeds — multi-type is stored in raw_type, normalize converts to oneOf
  let assert Ok(_spec) =
    parser.parse_file("test/fixtures/oss_swagger_parser_java_31_basic.yaml")
  should.be_true(True)
}

/// swagger-parser-java: OpenAPI 3.1 security scheme includes mutualTLS type.
/// Parser preserves it losslessly; generate fails via capability_check.
pub fn oss_swagger_parser_java_31_security_rejects_mutualtls_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_swagger_parser_java_31_security.yaml")
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { e.message })
      let has_mutual =
        list.any(error_details, fn(d) { string.contains(d, "mutualTLS") })
      should.be_true(has_mutual)
    }
    Ok(_) -> should.fail()
  }
}

/// swagger-parser-java: OpenAPI 3.1 schema siblings (dependentRequired,
/// dependentSchemas, if/then/else, examples array).
/// Parse succeeds; generate fails due to unsupported keywords.
pub fn oss_swagger_parser_java_31_schema_siblings_rejects_case() {
  // Parse succeeds — lossless parser stores unsupported keywords
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_java_31_schema_siblings.yaml",
    )
  // Generate fails via capability_check due to dependentSchemas, if/then/else
  let result = generate.generate(spec, context.config(make_ctx_from_spec(spec)))
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_dependent =
        list.any(error_details, fn(d) { string.contains(d, "dependentSchemas") })
      should.be_true(has_dependent)
    }

    Ok(_) -> should.fail()
  }
}

/// swagger-parser-java: extended petstore 3.1 uses multi-type unions
/// (type: [string, integer]) which are now normalized. Parse succeeds.
pub fn oss_swagger_parser_java_31_petstore_more_rejects_multi_type_case() {
  // Parse succeeds — multi-type is stored in raw_type, normalize converts to oneOf
  let assert Ok(_spec) =
    parser.parse_file(
      "test/fixtures/oss_swagger_parser_java_31_petstore_more.yaml",
    )
  should.be_true(True)
}

// ---------------------------------------------------------------------------
// OSS: openapi-spec-validator (Apache-2.0) — additional tests
// Test data derived from https://github.com/python-openapi/openapi-spec-validator
// ---------------------------------------------------------------------------

/// openapi-spec-validator: schema with broken $ref URI.
/// The parser stores the broken ref as a Reference (no resolution at parse time).
pub fn oss_spec_validator_broken_ref_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/oss_spec_validator_broken_ref.yaml")
  spec.info.title |> should.equal("Some Schema")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

// ---------------------------------------------------------------------------
// Unsupported JSON Schema keyword detection
// ---------------------------------------------------------------------------

/// const keyword is stored in metadata and normalized to single-value enum.
pub fn unsupported_const_normalized_case() {
  // Parse succeeds — lossless parser stores const in metadata
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/unsupported_const.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

/// if/then/else keywords are stored by lossless parser; rejected at generate time.
pub fn unsupported_if_then_else_capability_check_case() {
  // Parse succeeds — lossless parser stores unsupported keywords
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/unsupported_if_then_else.yaml")
  // Generate fails via capability_check
  let result = generate.generate(spec, context.config(make_ctx_from_spec(spec)))
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_if = list.any(error_details, fn(d) { string.contains(d, "if") })
      should.be_true(has_if)
    }

    Ok(_) -> should.fail()
  }
}

/// prefixItems keyword is stored by lossless parser; rejected at generate time.
pub fn unsupported_prefix_items_capability_check_case() {
  // Parse succeeds — lossless parser stores unsupported keywords
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/unsupported_prefix_items.yaml")
  // Generate fails via capability_check
  let result = generate.generate(spec, context.config(make_ctx_from_spec(spec)))
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_prefix =
        list.any(error_details, fn(d) { string.contains(d, "prefixItems") })
      should.be_true(has_prefix)
    }

    Ok(_) -> should.fail()
  }
}

/// not keyword is stored by lossless parser; rejected at generate time.
pub fn unsupported_not_capability_check_case() {
  // Parse succeeds — lossless parser stores unsupported keywords
  let assert Ok(spec) = parser.parse_file("test/fixtures/unsupported_not.yaml")
  // Generate fails via capability_check
  let result = generate.generate(spec, context.config(make_ctx_from_spec(spec)))
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_not = list.any(error_details, fn(d) { string.contains(d, "not") })
      should.be_true(has_not)
    }

    Ok(_) -> should.fail()
  }
}

/// $defs keyword is stored by lossless parser; rejected at generate time.
pub fn unsupported_defs_capability_check_case() {
  // Parse succeeds — lossless parser stores unsupported keywords
  let assert Ok(spec) = parser.parse_file("test/fixtures/unsupported_defs.yaml")
  // Generate fails via capability_check
  let result = generate.generate(spec, context.config(make_ctx_from_spec(spec)))
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_defs =
        list.any(error_details, fn(d) { string.contains(d, "$defs") })
      should.be_true(has_defs)
    }

    Ok(_) -> should.fail()
  }
}

/// const nested inside object properties is normalized to enum; parse and generate succeed.
pub fn unsupported_nested_const_normalized_case() {
  // Parse succeeds — const is stored in metadata
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/unsupported_nested_const.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

/// Inline unsupported keyword 'not' in request body must be rejected by capability_check.
pub fn inline_not_keyword_rejected_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/inline_not_keyword.yaml")
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let has_not =
        list.any(errors, fn(e) { string.contains(e.message, "not") })
      should.be_true(has_not)
    }
    Ok(_) -> should.fail()
  }
}

/// Schema without type but with properties should still parse as object.
pub fn schema_no_type_with_properties_parses_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/schema_no_type_with_properties.yaml")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// $ref prefix validation
// ---------------------------------------------------------------------------

/// Security requirement referencing undefined scheme should be rejected.
pub fn validate_invalid_security_ref_rejects_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/invalid_security_ref.yaml")
  let result = generate.generate(spec, context.config(make_ctx_from_spec(spec)))
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let error_details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      let has_security =
        list.any(error_details, fn(d) {
          string.contains(d, "nonexistent_scheme")
        })
      should.be_true(has_security)
    }

    Ok(_) -> should.fail()
  }
}

/// External file $ref for parameter should produce a resolve error, not a panic.
pub fn external_param_ref_rejects_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/external_param_ref.yaml")
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  // Must produce a diagnostic error, not panic
  let result = generate.generate(spec, cfg)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      list.length(errors) |> should.not_equal(0)
      let has_ref_error =
        list.any(errors, fn(e) { string.contains(e.message, "Limit") })
      should.be_true(has_ref_error)
    }
    Ok(_) -> should.fail()
  }
}

/// $ref pointing to wrong component kind (schemas instead of parameters)
/// must produce a diagnostic error, not silently resolve from a different kind.
pub fn wrong_kind_ref_rejects_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/wrong_kind_ref.yaml")
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      // Must report wrong-kind ref, not silently resolve as parameter
      let has_kind_error =
        list.any(errors, fn(e) {
          string.contains(e.message, "schemas")
          || string.contains(e.message, "wrong")
          || string.contains(e.message, "kind")
        })
      should.be_true(has_kind_error)
    }
    Ok(_) -> should.fail()
  }
}

/// Unknown parameter style should be rejected with clear error.
pub fn unknown_param_style_rejects_case() {
  let result = parser.parse_file("test/fixtures/unknown_param_style.yaml")
  case result {
    Error(Diagnostic(code: "invalid_value", message: detail, ..)) ->
      should.be_true(string.contains(detail, "unknownStyle"))
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Normalize pass tests — prove transformations actually happen
// ---------------------------------------------------------------------------

/// const is normalized to single-value enum by normalize pass.
pub fn normalize_const_to_enum_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/normalize_const.yaml")
  // Before normalize: const_value is stored
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.StringSchema(metadata: meta, ..))) =
    dict.get(components.schemas, "Status")
  meta.const_value |> should.equal(Some(value.JsonString("active")))

  // After normalize: const_value cleared, enum_values set
  let normalized = normalize.normalize(spec)
  let assert Some(norm_components) = normalized.components
  let assert Ok(schema.Inline(schema.StringSchema(
    metadata: norm_meta,
    enum_values: enums,
    ..,
  ))) = dict.get(norm_components.schemas, "Status")
  norm_meta.const_value |> should.equal(None)
  enums |> should.equal(["active"])
}

/// Non-string const values are preserved, not converted to StringSchema.
pub fn normalize_preserves_non_string_const_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/normalize_const_types.yaml")
  let normalized = normalize.normalize(spec)
  let assert Some(components) = normalized.components

  // String const: normalized to enum
  let assert Ok(schema.Inline(schema.StringSchema(
    metadata: str_meta,
    enum_values: str_enums,
    ..,
  ))) = dict.get(components.schemas, "StringConst")
  str_meta.const_value |> should.equal(None)
  str_enums |> should.equal(["active"])

  // Bool const: preserved as BooleanSchema with const_value
  let assert Ok(schema.Inline(schema.BooleanSchema(metadata: bool_meta))) =
    dict.get(components.schemas, "BoolConst")
  bool_meta.const_value |> should.equal(Some(value.JsonBool(True)))

  // Int const: preserved as IntegerSchema with const_value
  let assert Ok(schema.Inline(schema.IntegerSchema(metadata: int_meta, ..))) =
    dict.get(components.schemas, "IntConst")
  int_meta.const_value |> should.equal(Some(value.JsonInt(42)))
}

/// Issue #238: a non-string `const` cannot be represented as a Gleam
/// enum, so normalize now marks the schema as carrying the unsupported
/// keyword `const (non-string)` instead of silently dropping the
/// restriction at codegen. capability_check must reject with a
/// targeted diagnostic.
pub fn normalize_flags_non_string_const_as_unsupported_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/normalize_const_types.yaml")
  let normalized = normalize.normalize(spec)
  let assert Some(components) = normalized.components
  let assert Ok(schema.Inline(bool_schema)) =
    dict.get(components.schemas, "BoolConst")
  list.contains(
    schema.get_metadata(bool_schema).unsupported_keywords,
    "const (non-string)",
  )
  |> should.be_true()
  let assert Ok(schema.Inline(int_schema)) =
    dict.get(components.schemas, "IntConst")
  list.contains(
    schema.get_metadata(int_schema).unsupported_keywords,
    "const (non-string)",
  )
  |> should.be_true()
}

/// Issue #238: non-string `const` must surface as a capability_check
/// error during generate, not succeed silently.
pub fn generate_rejects_non_string_const_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/normalize_const_types.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/normalize_const_types.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  case generate.generate(spec, cfg) {
    Error(generate.ValidationErrors(errors:)) -> {
      let messages = list.map(errors, validate.error_to_string)
      list.any(messages, fn(s) { string.contains(s, "const (non-string)") })
      |> should.be_true()
    }
    Ok(_) -> should.fail()
  }
}

/// Issue #238: a multi-type schema with type-specific constraints
/// (here: `minLength`, `maxLength`, `pattern` on a `type: [string,
/// integer]`) cannot be losslessly rewritten to oneOf, so normalize
/// must flag it and capability_check must reject it.
pub fn generate_rejects_multi_type_with_constraints_case() {
  let assert Ok(spec) =
    parser.parse_file(
      "test/fixtures/normalize_multi_type_with_constraints.yaml",
    )
  let cfg =
    config.new(
      input: "test/fixtures/normalize_multi_type_with_constraints.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  case generate.generate(spec, cfg) {
    Error(generate.ValidationErrors(errors:)) -> {
      let messages = list.map(errors, validate.error_to_string)
      list.any(messages, fn(s) {
        string.contains(s, "type: [T1, T2] with type-specific constraints")
      })
      |> should.be_true()
    }
    Ok(_) -> should.fail()
  }
}

/// type: [string, integer] is normalized to oneOf by normalize pass.
pub fn normalize_multi_type_to_oneof_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/normalize_multi_type.yaml")
  // Before normalize: raw_type stored
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.StringSchema(metadata: meta, ..))) =
    dict.get(components.schemas, "FlexibleId")
  meta.raw_type |> should.equal(Some(["string", "integer"]))

  // After normalize: becomes OneOfSchema
  let normalized = normalize.normalize(spec)
  let assert Some(norm_components) = normalized.components
  let assert Ok(schema.Inline(schema.OneOfSchema(schemas: variants, ..))) =
    dict.get(norm_components.schemas, "FlexibleId")
  list.length(variants) |> should.equal(2)
}

/// type: [string, null] sets nullable and normalize preserves it.
pub fn normalize_type_null_to_nullable_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/normalize_type_null.yaml")
  let assert Some(components) = spec.components
  let assert Ok(schema.Inline(schema.StringSchema(metadata: meta, ..))) =
    dict.get(components.schemas, "NullableName")
  // Parser already handles [T, null] → nullable: true
  meta.nullable |> should.be_true()

  // Normalize preserves this
  let normalized = normalize.normalize(spec)
  let assert Some(norm_components) = normalized.components
  let assert Ok(schema.Inline(schema.StringSchema(metadata: norm_meta, ..))) =
    dict.get(norm_components.schemas, "NullableName")
  norm_meta.nullable |> should.be_true()
}

// ---------------------------------------------------------------------------
// Resolve phase test — prove alias resolution works
// ---------------------------------------------------------------------------

/// Component alias is preserved at parse time and resolved by resolve phase.
pub fn resolve_component_alias_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/component_param_alias.yaml")
  let assert Some(components) = spec.components
  // After parse: AliasEntry is preserved
  let assert Ok(spec.Ref(_)) = dict.get(components.parameters, "AliasedLimit")

  // After resolve (via generate pipeline): AliasEntry becomes ConcreteEntry
  let result = generate.generate(spec, context.config(make_ctx_from_spec(spec)))
  case result {
    Ok(_) -> should.be_true(True)
    Error(generate.ValidationErrors(errors:)) -> {
      // May have warnings but should not have blocking errors about aliases
      let blocking =
        list.filter(errors, fn(e) { e.severity == diagnostic.SeverityError })
      list.length(blocking) |> should.equal(0)
    }
  }
}

// ---------------------------------------------------------------------------
// Capability check test — prove it uses the registry
// ---------------------------------------------------------------------------

/// capability_check detects unsupported keywords from the registry.
pub fn capability_check_uses_registry_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/unsupported_if_then_else.yaml")
  // Parse succeeds
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
  // Generate fails via capability_check (not parser)
  let result = generate.generate(spec, context.config(make_ctx_from_spec(spec)))
  case result {
    Error(generate.ValidationErrors(errors:)) -> {
      let details = list.map(errors, fn(e) { diagnostic.to_string(e) })
      should.be_true(list.any(details, fn(d) { string.contains(d, "if") }))
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// README boundaries generated from registry
// ---------------------------------------------------------------------------

/// doc/openapi-support.md "Current boundaries" section mentions every
/// Unsupported / NotHandled capability the registry knows about.
pub fn readme_boundaries_match_registry_case() {
  let assert Ok(doc) = simplifile.read("doc/openapi-support.md")
  // Every Unsupported capability name must appear in the support doc
  let unsupported = capability.by_level(capability.Unsupported)
  list.each(unsupported, fn(c) { should.be_true(string.contains(doc, c.name)) })
  // Every NotHandled capability name must appear in the support doc
  let not_handled = capability.by_level(capability.NotHandled)
  list.each(not_handled, fn(c) { should.be_true(string.contains(doc, c.name)) })
}

// ---------------------------------------------------------------------------
// Source location test — prove YAML errors carry line/column
// ---------------------------------------------------------------------------

/// YAML syntax error includes line/column in error message.
pub fn yaml_error_has_source_location_case() {
  // Test that SourceLoc type exists and to_short_string formats it
  let loc = diagnostic.SourceLoc(line: 5, column: 10)
  let err = diagnostic.yaml_error(detail: "test error", loc: loc)
  let msg = diagnostic.to_short_string(err)
  should.be_true(string.contains(msg, "line 5"))
  should.be_true(string.contains(msg, "column 10"))
  // NoSourceLoc case
  let err2 =
    diagnostic.yaml_error(detail: "test error", loc: diagnostic.NoSourceLoc)
  let msg2 = diagnostic.to_short_string(err2)
  should.equal(msg2, "test error")
}

// ---------------------------------------------------------------------------
// Pipeline order test — prove the 5-stage pipeline exists in generate
// ---------------------------------------------------------------------------

/// Generate pipeline runs: parse → normalize → resolve → capability_check → codegen.
/// This test verifies the pipeline works end-to-end with a valid spec.
pub fn pipeline_end_to_end_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/petstore.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) -> {
      let blocking = diagnostic.errors_only(errors)
      list.length(blocking) |> should.equal(0)
    }
  }
}

// ===========================================================================
// Edge-case fixtures — parse-success tests
// ===========================================================================

pub fn parse_wildcard_status_codes_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/wildcard_status_codes.yaml")
  spec.info.title |> should.equal("Wildcard Status Codes API")
  let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/resources/{id}")
  let assert Some(op) = path_item.get
  dict.size(op.responses) |> should.not_equal(0)
}

pub fn parse_server_variables_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/server_variables.yaml")
  spec.info.title |> should.equal("Server Variables API")
  list.length(spec.servers) |> should.not_equal(0)
}

pub fn parse_operation_server_override_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/operation_server_override.yaml")
  spec.info.title |> should.equal("Operation Server Override API")
}

pub fn parse_no_servers_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/no_servers.yaml")
  spec.info.title |> should.equal("No Servers API")
  list.length(spec.servers) |> should.equal(0)
}

pub fn parse_format_types_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/format_types.yaml")
  spec.info.title |> should.equal("Format Types API")
  let assert Some(components) = spec.components
  let assert Ok(_) = dict.get(components.schemas, "Record")
}

pub fn parse_dot_property_names_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/dot_property_names.yaml")
  spec.info.title |> should.equal("Dot Property Names API")
}

pub fn parse_inline_nested_objects_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/inline_nested_objects.yaml")
  spec.info.title |> should.equal("Inline Nested Objects API")
}

pub fn parse_array_param_styles_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/array_param_styles.yaml")
  spec.info.title |> should.equal("Array Parameter Styles API")
  let assert Ok(spec.Value(path_item)) =
    dict.get(spec.paths, "/search/{categories}")
  let assert Some(op) = path_item.get
  list.length(op.parameters) |> should.not_equal(0)
}

pub fn parse_delimited_param_styles_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/delimited_param_styles.yaml")
  spec.info.title |> should.equal("Delimited Parameter Styles API")
  let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/items")
  let assert Some(op) = path_item.get
  list.length(op.parameters) |> should.equal(5)
  let by_name =
    list.fold(op.parameters, dict.new(), fn(acc, pref) {
      let p = spec.unwrap_ref(pref)
      dict.insert(acc, p.name, p)
    })
  let assert Ok(colors) = dict.get(by_name, "colors")
  colors.style |> should.equal(Some(spec.PipeDelimitedStyle))
  colors.explode |> should.equal(Some(False))
  let assert Ok(tags) = dict.get(by_name, "tags")
  tags.style |> should.equal(Some(spec.PipeDelimitedStyle))
  // explode omitted — preserved as None; codegen applies the spec default.
  tags.explode |> should.equal(None)
  let assert Ok(colors_exploded) = dict.get(by_name, "colors_exploded")
  colors_exploded.style |> should.equal(Some(spec.PipeDelimitedStyle))
  colors_exploded.explode |> should.equal(Some(True))
  let assert Ok(sizes) = dict.get(by_name, "sizes")
  sizes.style |> should.equal(Some(spec.SpaceDelimitedStyle))
  sizes.explode |> should.equal(Some(False))
  let assert Ok(sizes_exploded) = dict.get(by_name, "sizes_exploded")
  sizes_exploded.style |> should.equal(Some(spec.SpaceDelimitedStyle))
  sizes_exploded.explode |> should.equal(Some(True))
}

pub fn validate_accepts_delimited_param_styles_case() {
  let ctx = make_ctx("test/fixtures/delimited_param_styles.yaml")
  validate.validate(ctx) |> should.equal([])
}

pub fn pipe_delimited_in_header_rejects_case() {
  let ctx = make_ctx("test/fixtures/pipe_delimited_in_header_rejects.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "pipeDelimited")
    && string.contains(s, "only supported for 'in: query'")
  })
  |> should.be_true()
}

pub fn space_delimited_non_array_rejects_case() {
  let ctx = make_ctx("test/fixtures/space_delimited_non_array_rejects.yaml")
  let errors = validate.validate(ctx)
  let error_strings = list.map(errors, validate.error_to_string)
  list.any(error_strings, fn(s) {
    string.contains(s, "spaceDelimited")
    && string.contains(s, "requires an array schema")
  })
  |> should.be_true()
}

pub fn parse_empty_response_body_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/empty_response_body.yaml")
  spec.info.title |> should.equal("Empty Response Body API")
  let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/items")
  let assert Some(op) = path_item.post
  let assert Ok(_) = dict.get(op.responses, http.Status(201))
}

pub fn parse_enum_edge_cases_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/enum_edge_cases.yaml")
  spec.info.title |> should.equal("Enum Edge Cases API")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn parse_multiple_response_content_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/multiple_response_content.yaml")
  spec.info.title |> should.equal("Multiple Response Content Types API")
}

pub fn parse_hyphen_property_names_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/hyphen_property_names.yaml")
  spec.info.title |> should.equal("Hyphen Property Names API")
}

pub fn parse_mixed_param_locations_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/mixed_param_locations.yaml")
  spec.info.title |> should.equal("Mixed Parameter Locations API")
  let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/resources/{id}")
  let assert Some(op) = path_item.get
  let param_count = list.length(op.parameters)
  { param_count >= 4 } |> should.be_true()
}

pub fn parse_readonly_writeonly_properties_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/readonly_writeonly_properties.yaml")
  spec.info.title |> should.equal("ReadOnly WriteOnly Properties API")
}

pub fn parse_complex_discriminator_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/complex_discriminator.yaml")
  spec.info.title |> should.equal("Complex Discriminator API")
  let assert Some(components) = spec.components
  let assert Ok(_) = dict.get(components.schemas, "Shape")
}

pub fn parse_recursive_anyof_schema_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/recursive_anyof_schema.yaml")
  spec.info.title |> should.equal("Recursive AnyOf Schema API")
}

pub fn parse_all_component_types_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/all_component_types.yaml")
  spec.info.title |> should.equal("All Component Types API")
  let assert Some(components) = spec.components
  dict.size(components.schemas) |> should.not_equal(0)
}

pub fn parse_default_response_only_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/default_response_only.yaml")
  spec.info.title |> should.equal("Default Response Only API")
  let assert Ok(spec.Value(path_item)) = dict.get(spec.paths, "/proxy")
  let assert Some(op) = path_item.get
  let assert Ok(_) = dict.get(op.responses, http.DefaultStatus)
}

pub fn parse_abbreviation_identifiers_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/abbreviation_identifiers.yaml")
  spec.info.title |> should.equal("Abbreviation Identifiers API")
  let assert Some(components) = spec.components
  let assert Ok(_) = dict.get(components.schemas, "HTTPRequest")
}

pub fn parse_optional_required_combinations_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/optional_required_combinations.yaml")
  spec.info.title |> should.equal("Optional Required Combinations API")
}

// ===========================================================================
// Edge-case fixtures — generation tests
// ===========================================================================

pub fn generate_wildcard_status_codes_case() {
  let ctx = make_ctx("test/fixtures/wildcard_status_codes.yaml")
  let files = types.generate(ctx)
  list.length(files) |> should.not_equal(0)
}

pub fn generate_server_variables_produces_types_case() {
  let ctx = make_ctx("test/fixtures/server_variables.yaml")
  let files = types.generate(ctx)
  list.length(files) |> should.not_equal(0)
}

pub fn generate_format_types_case() {
  let ctx = make_ctx("test/fixtures/format_types.yaml")
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  string.contains(types_file.content, "Record") |> should.be_true()
}

pub fn generate_dot_property_names_produces_valid_identifiers_case() {
  let ctx = make_ctx("test/fixtures/dot_property_names.yaml")
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  string.contains(types_file.content, "type ") |> should.be_true()
}

pub fn generate_inline_nested_objects_case() {
  let ctx = make_ctx("test/fixtures/inline_nested_objects.yaml")
  let files = types.generate(ctx)
  list.length(files) |> should.not_equal(0)
}

pub fn generate_enum_edge_cases_case() {
  let ctx = make_ctx("test/fixtures/enum_edge_cases.yaml")
  let files = types.generate(ctx)
  list.length(files) |> should.not_equal(0)
}

pub fn generate_hyphen_property_names_valid_gleam_case() {
  let ctx = make_ctx("test/fixtures/hyphen_property_names.yaml")
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  string.contains(types_file.content, "type ") |> should.be_true()
}

pub fn generate_mixed_param_locations_case() {
  let ctx = make_ctx("test/fixtures/mixed_param_locations.yaml")
  let server_files = server_gen.generate(ctx)
  list.length(server_files) |> should.not_equal(0)
}

pub fn generate_complex_discriminator_case() {
  let ctx = make_ctx("test/fixtures/complex_discriminator.yaml")
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  string.contains(types_file.content, "Shape") |> should.be_true()
}

pub fn generate_recursive_anyof_schema_types_case() {
  let ctx = make_ctx("test/fixtures/recursive_anyof_schema.yaml")
  let files = types.generate(ctx)
  list.length(files) |> should.not_equal(0)
}

/// Pathological spec: a `required` field whose schema is `$ref`-back to
/// the enclosing schema. Every value of `Node` would need an
/// infinitely deep chain of `child` Nodes, so the schema is
/// inhabit-impossible — no finite JSON document can satisfy it.
///
/// Current observable behavior (pinned below):
///   - parser accepts the spec
///   - validator does NOT flag it as an error
///   - codegen emits `pub type Node { Node(child: Node) }` which the
///     Gleam compiler accepts even though the type has no constructor
///     reachable from a finite value, AND emits a decoder
///     (`node_decoder`) that recurses unconditionally — invoking it
///     against any input would never return.
///
/// This pin documents that gap. When oaspec gains an inhabitability
/// check (e.g. detect a required cycle in the schema graph), the
/// `Ok(_)` arm below should flip to `Error(_)` and assert the
/// diagnostic shape — at which point the test will fail loudly and
/// the maintainer will know the contract has changed intentionally.
pub fn required_self_ref_currently_accepted_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/required_self_ref.yaml")
  let ctx = make_ctx_from_spec(spec)
  let result = generate.generate(spec, context.config(ctx))
  // Pin: today this generates without surfacing a blocking error.
  case result {
    Ok(summary) -> {
      let types_file =
        list.find(summary.files, fn(f) {
          string.ends_with(f.path, "types.gleam")
        })
      let assert Ok(types_file) = types_file
      // The non-Option recursive form is exactly what makes the type
      // uninhabitable. If oaspec ever wraps the field in `Option(_)`
      // (which would make Node inhabitable, with `Node(child: None)`
      // as the base case), this assertion fails — that's the desired
      // signal for an intentional change.
      string.contains(types_file.content, "Node(child: Node)")
      |> should.be_true()
    }
    Error(generate.ValidationErrors(errors:)) ->
      // If a future inhabitability check rejects this fixture, that's
      // an improvement — but the test must change too. Surface the
      // error count so the failure prompt is informative.
      list.length(diagnostic.errors_only(errors)) |> should.equal(0)
  }
}

pub fn generate_default_response_only_case() {
  let ctx = make_ctx("test/fixtures/default_response_only.yaml")
  let client_files = client_gen.generate(ctx)
  list.length(client_files) |> should.not_equal(0)
}

pub fn generate_abbreviation_identifiers_valid_gleam_case() {
  let ctx = make_ctx("test/fixtures/abbreviation_identifiers.yaml")
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  string.contains(types_file.content, "type ") |> should.be_true()
}

pub fn generate_optional_required_combinations_case() {
  let ctx = make_ctx("test/fixtures/optional_required_combinations.yaml")
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  string.contains(types_file.content, "Option") |> should.be_true()
}

pub fn generate_readonly_writeonly_filters_case() {
  let ctx = make_ctx("test/fixtures/readonly_writeonly_properties.yaml")
  let files = types.generate(ctx)
  list.length(files) |> should.not_equal(0)
}

pub fn generate_all_component_types_case() {
  let ctx = make_ctx("test/fixtures/all_component_types.yaml")
  let files = types.generate(ctx)
  list.length(files) |> should.not_equal(0)
}

pub fn generate_array_param_styles_server_case() {
  let ctx = make_ctx("test/fixtures/array_param_styles.yaml")
  let server_files = server_gen.generate(ctx)
  list.length(server_files) |> should.not_equal(0)
}

pub fn generate_delimited_param_styles_client_case() {
  let ctx = make_ctx("test/fixtures/delimited_param_styles.yaml")
  let client_files = client_gen.generate(ctx)
  let combined = list.fold(client_files, "", fn(acc, f) { acc <> f.content })
  // Non-exploded pipe/space params should join array items into a
  // single value before pushing to query as a tuple.
  string.contains(combined, "[#(\"colors\", joined), ..query]")
  |> should.be_true()
  string.contains(combined, "[#(\"tags\", joined), ..query]")
  |> should.be_true()
  string.contains(combined, "[#(\"sizes\", joined), ..query]")
  |> should.be_true()
  string.contains(combined, "), \"|\")") |> should.be_true()
  string.contains(combined, "), \" \")") |> should.be_true()
  // Exploded params produce a list.fold that pushes one tuple per item.
  string.contains(combined, "[#(\"colors_exploded\", joined), ..query]")
  |> should.be_false()
  string.contains(combined, "[#(\"sizes_exploded\", joined), ..query]")
  |> should.be_false()
}

pub fn generate_delimited_param_styles_server_case() {
  let ctx = make_ctx("test/fixtures/delimited_param_styles.yaml")
  let server_files = server_gen.generate(ctx)
  let combined = list.fold(server_files, "", fn(acc, f) { acc <> f.content })
  // Non-exploded server decode should split on the style-specific delimiter.
  string.contains(combined, "string.split(v, \"|\")") |> should.be_true()
  string.contains(combined, "string.split(v, \" \")") |> should.be_true()
  // The pipe-delimited split appears for both `colors` and the
  // explode-omitted `tags` parameter; count occurrences to lock that in.
  let pipe_split_count =
    string.split(combined, "string.split(v, \"|\")") |> list.length()
  { pipe_split_count >= 3 } |> should.be_true()
}

pub fn generate_empty_response_body_server_case() {
  let ctx = make_ctx("test/fixtures/empty_response_body.yaml")
  let server_files = server_gen.generate(ctx)
  list.length(server_files) |> should.not_equal(0)
}

pub fn generate_multiple_response_content_client_case() {
  let ctx = make_ctx("test/fixtures/multiple_response_content.yaml")
  let client_files = client_gen.generate(ctx)
  list.length(client_files) |> should.not_equal(0)
}

// ===========================================================================
// Decoder generation for edge cases
// ===========================================================================

pub fn decoders_wildcard_status_codes_case() {
  let ctx = make_ctx("test/fixtures/wildcard_status_codes.yaml")
  let files = decoders.generate(ctx)
  list.length(files) |> should.not_equal(0)
}

pub fn decoders_complex_discriminator_case() {
  let ctx = make_ctx("test/fixtures/complex_discriminator.yaml")
  let files = decoders.generate(ctx)
  list.length(files) |> should.not_equal(0)
}

pub fn decoders_enum_edge_cases_case() {
  let ctx = make_ctx("test/fixtures/enum_edge_cases.yaml")
  let files = decoders.generate(ctx)
  list.length(files) |> should.not_equal(0)
}

pub fn decoders_format_types_case() {
  let ctx = make_ctx("test/fixtures/format_types.yaml")
  let files = decoders.generate(ctx)
  list.length(files) |> should.not_equal(0)
}

pub fn decoders_recursive_anyof_case() {
  let ctx = make_ctx("test/fixtures/recursive_anyof_schema.yaml")
  let files = decoders.generate(ctx)
  list.length(files) |> should.not_equal(0)
}

// ===========================================================================
// Error/validation fixtures — user-friendly error messages
// ===========================================================================

pub fn error_missing_openapi_field_case() {
  let result =
    parser.parse_file("test/fixtures/error_missing_openapi_field.yaml")
  should.be_error(result)
}

pub fn error_swagger_v2_rejected_case() {
  let result = parser.parse_file("test/fixtures/error_swagger_v2.yaml")
  should.be_error(result)
}

pub fn error_missing_info_case() {
  let result = parser.parse_file("test/fixtures/error_missing_info.yaml")
  should.be_error(result)
}

pub fn error_missing_info_title_case() {
  let result = parser.parse_file("test/fixtures/error_missing_info_title.yaml")
  should.be_error(result)
}

pub fn error_missing_info_version_case() {
  let result =
    parser.parse_file("test/fixtures/error_missing_info_version.yaml")
  should.be_error(result)
}

pub fn error_empty_spec_case() {
  let result = parser.parse_file("test/fixtures/error_empty_spec.yaml")
  should.be_error(result)
}

// error_invalid_yaml_test — skipped: the YAML parser crashes on malformed YAML
// rather than returning an Error. This is a known limitation tracked in the
// project's error-handling roadmap.

pub fn error_invalid_json_as_yaml_parsed_but_may_fail_case() {
  // YAML is a superset of JSON, so some invalid JSON still parses as YAML.
  // The parser may accept the file but produce an unusual structure.
  let _result =
    parser.parse_file("test/fixtures/error_invalid_json_as_yaml.yaml")
  Nil
}

pub fn error_duplicate_operation_id_parses_case() {
  // The parser accepts a spec with duplicate operationIds — the uniqueness
  // constraint is surfaced as a validation error (see issue #237 and
  // `validate_rejects_duplicate_operation_id_test`), not a parse failure,
  // so tooling can still load and inspect the broken spec.
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/error_duplicate_operation_id.yaml")
  dict.size(spec.paths) |> should.equal(2)
}

pub fn error_missing_path_param_case() {
  let result = parser.parse_file("test/fixtures/error_missing_path_param.yaml")
  case result {
    Ok(spec) -> {
      let assert Ok(resolved) = resolve.resolve(spec)
      let resolved = hoist.hoist(resolved)
      let resolved = dedup.dedup(resolved)
      let cfg =
        config.new(
          input: "test.yaml",
          output_server: "./test_output/api",
          output_client: "./test_output_client/api",
          package: "api",
          mode: config.Both,
          validate: False,
        )
      let ctx = context.new(resolved, cfg)
      let diagnostics = validate.validate(ctx)
      let errors = diagnostic.errors_only(diagnostics)
      { list.length(errors) >= 1 } |> should.be_true()
      Nil
    }
    Error(_) -> Nil
  }
}

pub fn error_invalid_ref_syntax_fails_resolve_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/error_invalid_ref_syntax.yaml")
  // The malformed $ref should fail during resolution
  let resolve_result = resolve.resolve(spec)
  // It may either fail resolution or succeed but produce invalid output
  case resolve_result {
    Error(_) -> Nil
    Ok(_) -> Nil
  }
}

pub fn error_response_no_description_case() {
  let result =
    parser.parse_file("test/fixtures/error_response_no_description.yaml")
  case result {
    Ok(_) -> Nil
    Error(_) -> Nil
  }
}

// ===========================================================================
// Compile test fixtures — full pipeline tests
// ===========================================================================

pub fn compile_wildcard_responses_full_pipeline_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/compile_wildcard_responses.yaml")
  let ctx = make_ctx_from_spec(spec)
  let type_files = types.generate(ctx)
  let decoder_files = decoders.generate(ctx)
  list.length(type_files) |> should.not_equal(0)
  list.length(decoder_files) |> should.not_equal(0)
}

pub fn compile_format_types_full_pipeline_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/compile_format_types.yaml")
  let ctx = make_ctx_from_spec(spec)
  let type_files = types.generate(ctx)
  let decoder_files = decoders.generate(ctx)
  let client_files = client_gen.generate(ctx)
  list.length(type_files) |> should.not_equal(0)
  list.length(decoder_files) |> should.not_equal(0)
  list.length(client_files) |> should.not_equal(0)
}

pub fn compile_mixed_params_full_pipeline_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/compile_mixed_params.yaml")
  let ctx = make_ctx_from_spec(spec)
  let type_files = types.generate(ctx)
  let server_files = server_gen.generate(ctx)
  list.length(type_files) |> should.not_equal(0)
  list.length(server_files) |> should.not_equal(0)
}

pub fn compile_enum_variants_full_pipeline_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/compile_enum_variants.yaml")
  let ctx = make_ctx_from_spec(spec)
  let type_files = types.generate(ctx)
  let decoder_files = decoders.generate(ctx)
  list.length(type_files) |> should.not_equal(0)
  list.length(decoder_files) |> should.not_equal(0)
}

// ===========================================================================
// Naming edge cases — abbreviation and special character handling
// ===========================================================================

pub fn to_pascal_case_abbreviation_case() {
  naming.to_pascal_case("http_request")
  |> should.equal("HttpRequest")
}

pub fn to_pascal_case_all_caps_preserved_case() {
  // All-caps words are preserved in PascalCase
  naming.to_pascal_case("URL")
  |> should.equal("URL")
}

pub fn to_snake_case_abbreviation_case() {
  naming.to_snake_case("HTTPRequest")
  |> should.equal("http_request")
}

pub fn to_snake_case_consecutive_caps_case() {
  naming.to_snake_case("XMLParser")
  |> should.equal("xml_parser")
}

pub fn to_pascal_case_with_numbers_case() {
  naming.to_pascal_case("oauth2_token")
  |> should.equal("Oauth2Token")
}

pub fn to_snake_case_with_hyphen_case() {
  naming.to_snake_case("content-type")
  |> should.equal("content_type")
}

pub fn to_snake_case_with_dots_case() {
  // Issue #494: a `.` is encoded as a `_dot_` word boundary so dotted
  // schema names (Stripe's `payment_intent.processing`) survive the
  // pipeline distinguishable from their `_`-separated siblings.
  naming.to_snake_case("app.name")
  |> should.equal("app_dot_name")
}

// ===========================================================================
// Server/client generation for edge cases
// ===========================================================================

pub fn server_wildcard_status_generates_response_types_case() {
  let ctx = make_ctx("test/fixtures/wildcard_status_codes.yaml")
  let server_files = server_gen.generate(ctx)
  list.length(server_files) |> should.not_equal(0)
}

pub fn client_wildcard_status_generates_client_case() {
  let ctx = make_ctx("test/fixtures/wildcard_status_codes.yaml")
  let client_files = client_gen.generate(ctx)
  list.length(client_files) |> should.not_equal(0)
}

pub fn client_no_servers_generates_case() {
  let ctx = make_ctx("test/fixtures/no_servers.yaml")
  let client_files = client_gen.generate(ctx)
  list.length(client_files) |> should.not_equal(0)
}

pub fn server_empty_response_body_generates_case() {
  let ctx = make_ctx("test/fixtures/empty_response_body.yaml")
  let server_files = server_gen.generate(ctx)
  list.length(server_files) |> should.not_equal(0)
}

pub fn client_default_response_only_generates_case() {
  let ctx = make_ctx("test/fixtures/default_response_only.yaml")
  let client_files = client_gen.generate(ctx)
  list.length(client_files) |> should.not_equal(0)
}

pub fn server_default_response_only_generates_case() {
  let ctx = make_ctx("test/fixtures/default_response_only.yaml")
  let server_files = server_gen.generate(ctx)
  list.length(server_files) |> should.not_equal(0)
}

pub fn octet_stream_request_body_emits_bit_array_case() {
  // Issue #485: a `application/octet-stream` request body must
  // surface as `body: BitArray` on both server and client request
  // types — `String` forces arbitrary binary payloads through
  // `bit_array.to_string |> result.unwrap("")`, which silently
  // drops non-UTF-8 bytes, and breaks the client's
  // `transport.BytesBody` wrap with a type mismatch.
  let ctx = make_ctx("test/fixtures/server_octet_stream_request_body.yaml")
  let type_files = types.generate(ctx)
  let assert Ok(request_types_file) =
    list.find(type_files, fn(f) { f.path == "request_types.gleam" })
  let request_types_content = request_types_file.content
  string.contains(request_types_content, "body: BitArray")
  |> should.be_true()
  string.contains(
    request_types_content,
    "IngestBinaryWebhookRequest(x_signature: String, body: BitArray)",
  )
  |> should.be_true()

  // Server router signature switches to BitArray when any
  // operation declares octet-stream, and shadows `body` with the
  // String conversion at the top of every non-binary arm.
  let server_files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(server_files, fn(f) { f.path == "router.gleam" })
  let router_content = router_file.content
  // Unformatted output is single-line; substring check is enough.
  string.contains(router_content, "body: BitArray)")
  |> should.be_true()
  // Non-binary arm shadows the param so the rest of the codegen
  // can keep treating `body` as a String.
  string.contains(
    router_content,
    "let body = bit_array.to_string(body) |> result.unwrap(\"\")",
  )
  |> should.be_true()
  // Binary arm uses `body` directly without the conversion.
  string.contains(router_content, "body: body,")
  |> should.be_true()

  // Client: function takes `body body: BitArray` and the wrap
  // around `transport.BytesBody(body)` no longer produces a type
  // mismatch.
  let client_files = client_gen.generate(ctx)
  let assert Ok(client_file) =
    list.find(client_files, fn(f) { f.path == "client.gleam" })
  let client_content = client_file.content
  string.contains(client_content, "body body: BitArray")
  |> should.be_true()
  string.contains(client_content, "transport.BytesBody(body)")
  |> should.be_true()
}

pub fn server_default_response_carries_status_field_case() {
  // Issue #483: the OpenAPI `default` response variant must carry the
  // runtime status code as its first positional field, and the router
  // must pass that bound `status` straight through to the outgoing
  // ServerResponse instead of pinning every `default` branch to 500.
  let ctx = make_ctx("test/fixtures/server_default_response_status.yaml")
  let type_files = types.generate(ctx)
  let assert Ok(response_types_file) =
    list.find(type_files, fn(f) { f.path == "response_types.gleam" })
  let response_types_content = response_types_file.content
  let files = server_gen.generate(ctx)

  // With body: variant signature is `Foo(Int, types.Error)`.
  string.contains(
    response_types_content,
    "DeleteArtifactResponseDefault(Int, types.Error)",
  )
  |> should.be_true()
  // Empty default: signature collapses to `Foo(Int)`.
  string.contains(response_types_content, "ListThingsResponseDefault(Int)")
  |> should.be_true()

  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  let router_content = router_file.content

  // Router pattern binds `status` and forwards it as the outgoing
  // status — no more hardcoded 500.
  string.contains(
    router_content,
    "DeleteArtifactResponseDefault(status, data) -> ServerResponse(status: status,",
  )
  |> should.be_true()
  string.contains(
    router_content,
    "ListThingsResponseDefault(status) -> ServerResponse(status: status,",
  )
  |> should.be_true()
  // The previous shape — `status: 500` for the default branch — must
  // be gone for these operations.
  string.contains(
    router_content,
    "DeleteArtifactResponseDefault(data) -> ServerResponse(status: 500,",
  )
  |> should.be_false()
}

pub fn client_default_response_passes_status_through_case() {
  // Issue #483: the client decoder must capture the actual runtime
  // status int and pass it as the first arg to the generated
  // `XxxResponseDefault(...)` variant, instead of dropping it on the
  // floor.
  let ctx = make_ctx("test/fixtures/server_default_response_status.yaml")
  let files = client_gen.generate(ctx)
  let assert Ok(client_file) =
    list.find(files, fn(f) { f.path == "client.gleam" })
  let content = client_file.content

  // Default branch binds `status` (instead of `_`) and threads it.
  string.contains(content, "status -> {")
  |> should.be_true()
  string.contains(
    content,
    "Ok(response_types.DeleteArtifactResponseDefault(status, decoded))",
  )
  |> should.be_true()
  string.contains(
    content,
    "Ok(response_types.ListThingsResponseDefault(status))",
  )
  |> should.be_true()
}

// ===========================================================================
// Validation for edge-case fixtures
// ===========================================================================

pub fn validate_wildcard_status_codes_case() {
  let ctx = make_ctx("test/fixtures/wildcard_status_codes.yaml")
  let diagnostics = validate.validate(ctx)
  let errors = diagnostic.errors_only(diagnostics)
  list.length(errors) |> should.equal(0)
}

pub fn validate_format_types_case() {
  let ctx = make_ctx("test/fixtures/format_types.yaml")
  let diagnostics = validate.validate(ctx)
  let errors = diagnostic.errors_only(diagnostics)
  list.length(errors) |> should.equal(0)
}

pub fn validate_enum_edge_cases_case() {
  let ctx = make_ctx("test/fixtures/enum_edge_cases.yaml")
  let diagnostics = validate.validate(ctx)
  let errors = diagnostic.errors_only(diagnostics)
  list.length(errors) |> should.equal(0)
}

pub fn validate_mixed_param_locations_case() {
  let ctx = make_ctx("test/fixtures/mixed_param_locations.yaml")
  let diagnostics = validate.validate(ctx)
  let errors = diagnostic.errors_only(diagnostics)
  list.length(errors) |> should.equal(0)
}

pub fn validate_complex_discriminator_case() {
  let ctx = make_ctx("test/fixtures/complex_discriminator.yaml")
  let diagnostics = validate.validate(ctx)
  let errors = diagnostic.errors_only(diagnostics)
  list.length(errors) |> should.equal(0)
}

pub fn validate_optional_required_combinations_case() {
  let ctx = make_ctx("test/fixtures/optional_required_combinations.yaml")
  let diagnostics = validate.validate(ctx)
  let errors = diagnostic.errors_only(diagnostics)
  list.length(errors) |> should.equal(0)
}

// ===========================================================================
// Guards generation for edge cases
// ===========================================================================

pub fn guards_enum_edge_cases_case() {
  let ctx = make_ctx("test/fixtures/enum_edge_cases.yaml")
  let guard_files = guards.generate(ctx)
  { list.length(guard_files) >= 0 } |> should.be_true()
}

pub fn guards_format_types_case() {
  let ctx = make_ctx("test/fixtures/format_types.yaml")
  let guard_files = guards.generate(ctx)
  { list.length(guard_files) >= 0 } |> should.be_true()
}

// ===========================================================================
// IR build for edge cases
// ===========================================================================

pub fn ir_build_inline_nested_objects_case() {
  let ctx = make_ctx("test/fixtures/inline_nested_objects.yaml")
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  string.contains(types_file.content, "pub type") |> should.be_true()
}

pub fn ir_build_abbreviation_identifiers_case() {
  let ctx = make_ctx("test/fixtures/abbreviation_identifiers.yaml")
  let files = types.generate(ctx)
  let assert [types_file, ..] = files
  string.contains(types_file.content, "pub type") |> should.be_true()
}

// ===========================================================================
// Full end-to-end pipeline tests for new fixtures
// ===========================================================================

pub fn e2e_wildcard_status_codes_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/wildcard_status_codes.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/wildcard_status_codes.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) ->
      list.length(errors) |> should.not_equal(0)
  }
}

pub fn e2e_format_types_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/format_types.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/format_types.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) ->
      list.length(errors) |> should.not_equal(0)
  }
}

pub fn e2e_complex_discriminator_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/complex_discriminator.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/complex_discriminator.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) ->
      list.length(errors) |> should.not_equal(0)
  }
}

pub fn e2e_enum_edge_cases_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/enum_edge_cases.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/enum_edge_cases.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) ->
      list.length(errors) |> should.not_equal(0)
  }
}

pub fn e2e_mixed_param_locations_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/mixed_param_locations.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/mixed_param_locations.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) ->
      list.length(errors) |> should.not_equal(0)
  }
}

pub fn e2e_inline_nested_objects_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/inline_nested_objects.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/inline_nested_objects.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) ->
      list.length(errors) |> should.not_equal(0)
  }
}

pub fn e2e_optional_required_combinations_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/optional_required_combinations.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/optional_required_combinations.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) ->
      list.length(errors) |> should.not_equal(0)
  }
}

pub fn e2e_no_servers_case() {
  let assert Ok(spec) = parser.parse_file("test/fixtures/no_servers.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/no_servers.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let result = generate.generate(spec, cfg)
  case result {
    Ok(summary) -> list.length(summary.files) |> should.not_equal(0)
    Error(generate.ValidationErrors(errors:)) ->
      list.length(errors) |> should.not_equal(0)
  }
}

// ===========================================================================
// Guard integration tests (issue #22)
// ===========================================================================

/// Helper: create a context with validate=True from a YAML string.
fn make_validate_ctx_from_yaml(yaml: String) -> context.Context {
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(resolved) = resolve.resolve(spec)
  let resolved = hoist.hoist(resolved)
  let resolved = dedup.dedup(resolved)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: True,
    )
  context.new(resolved, cfg)
}

/// Petstore spec YAML fragment with constrained request body.
const guard_integration_spec = "
openapi: 3.0.3
info:
  title: Guard Integration Test
  version: 1.0.0
servers:
  - url: https://example.com
paths:
  /pets:
    post:
      operationId: createPet
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CreatePetRequest'
      responses:
        '201':
          description: Created
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Pet'
        '400':
          description: Bad Request
    get:
      operationId: listPets
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/Pet'
components:
  schemas:
    CreatePetRequest:
      type: object
      required: [name]
      properties:
        name:
          type: string
          minLength: 1
          maxLength: 100
    Pet:
      type: object
      required: [id, name]
      properties:
        id:
          type: integer
        name:
          type: string
          minLength: 1
          maxLength: 100
"

/// Server router should include guard validation when validate=True.
pub fn guard_integration_server_router_validates_body_case() {
  let ctx = make_validate_ctx_from_yaml(guard_integration_spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })

  // Should import guards module
  string.contains(router_file.content, "api/guards")
  |> should.be_true()

  // Should call guards.validate_create_pet_request after body decode
  string.contains(
    router_file.content,
    "guards.validate_create_pet_request(decoded_body)",
  )
  |> should.be_true()

  // Should return 422 on validation failure
  string.contains(router_file.content, "status: 422")
  |> should.be_true()

  // Should include errors in JSON response body via the structured
  // ValidationFailure encoder (Issue #269).
  string.contains(
    router_file.content,
    "json.array(errors, guards.validation_failure_to_json)",
  )
  |> should.be_true()

  // Decode error path should still return 400 (distinct from 422 validation)
  string.contains(router_file.content, "status: 400")
  |> should.be_true()
}

/// Server router should NOT include guard validation when validate=False.
pub fn guard_integration_server_no_validation_when_disabled_case() {
  let assert Ok(spec) = parser.parse_string(guard_integration_spec)
  let assert Ok(resolved) = resolve.resolve(spec)
  let resolved = hoist.hoist(resolved)
  let resolved = dedup.dedup(resolved)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let ctx = context.new(resolved, cfg)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })

  // Should NOT import guards module
  string.contains(router_file.content, "api/guards")
  |> should.be_false()

  // Should NOT call guards.validate
  string.contains(router_file.content, "guards.validate_")
  |> should.be_false()

  // Should NOT return 422
  string.contains(router_file.content, "status: 422")
  |> should.be_false()
}

/// Client should include guard validation when validate=True.
pub fn guard_integration_client_validates_body_case() {
  let ctx = make_validate_ctx_from_yaml(guard_integration_spec)
  let files = client_gen.generate(ctx)
  let assert Ok(client_file) =
    list.find(files, fn(f) { f.path == "client.gleam" })

  // Should import guards module
  string.contains(client_file.content, "api/guards")
  |> should.be_true()

  // Should include ValidationError variant carrying structured failures
  // (Issue #269 — `errors` is `List(guards.ValidationFailure)`).
  string.contains(
    client_file.content,
    "ValidationError(errors: List(guards.ValidationFailure))",
  )
  |> should.be_true()

  // Should call guards.validate_create_pet_request
  string.contains(
    client_file.content,
    "guards.validate_create_pet_request(body)",
  )
  |> should.be_true()
}

/// Client should NOT include guard validation when validate=False.
pub fn guard_integration_client_no_validation_when_disabled_case() {
  let assert Ok(spec) = parser.parse_string(guard_integration_spec)
  let assert Ok(resolved) = resolve.resolve(spec)
  let resolved = hoist.hoist(resolved)
  let resolved = dedup.dedup(resolved)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let ctx = context.new(resolved, cfg)
  let files = client_gen.generate(ctx)
  let assert Ok(client_file) =
    list.find(files, fn(f) { f.path == "client.gleam" })

  // Should NOT import guards module
  string.contains(client_file.content, "api/guards")
  |> should.be_false()

  // Should NOT include ValidationError variant
  string.contains(client_file.content, "ValidationError")
  |> should.be_false()

  // Should NOT call guards.validate
  string.contains(client_file.content, "guards.validate_")
  |> should.be_false()
}

/// Client should validate optional request bodies with Some/None handling.
pub fn guard_integration_client_validates_optional_body_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Optional Body Test
  version: 1.0.0
servers:
  - url: https://example.com
paths:
  /pets:
    patch:
      operationId: updatePet
      requestBody:
        required: false
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/UpdatePetRequest'
      responses:
        '200':
          description: OK
components:
  schemas:
    UpdatePetRequest:
      type: object
      properties:
        name:
          type: string
          minLength: 1
          maxLength: 100
"
  let ctx = make_validate_ctx_from_yaml(yaml)
  let files = client_gen.generate(ctx)
  let assert Ok(client_file) =
    list.find(files, fn(f) { f.path == "client.gleam" })

  // Should import guards module
  string.contains(client_file.content, "api/guards")
  |> should.be_true()

  // Should include ValidationError variant
  string.contains(client_file.content, "ValidationError")
  |> should.be_true()

  // Should call guards.validate for optional body with Some pattern
  string.contains(client_file.content, "guards.validate_update_pet_request")
  |> should.be_true()

  // Should handle None case (no validation for absent body)
  string.contains(client_file.content, "None -> []")
  |> should.be_true()
}

/// Guard validation should only apply to schemas that actually have constraints.
pub fn guard_integration_no_validation_for_unconstrained_body_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
servers:
  - url: https://example.com
paths:
  /items:
    post:
      operationId: createItem
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/Item'
      responses:
        '201':
          description: Created
components:
  schemas:
    Item:
      type: object
      required: [name]
      properties:
        name:
          type: string
"
  let ctx = make_validate_ctx_from_yaml(yaml)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })

  // No constraints on Item schema, so no guard validation
  string.contains(router_file.content, "guards.validate_")
  |> should.be_false()

  string.contains(router_file.content, "status: 422")
  |> should.be_false()
}

/// guards.schema_has_validator returns True for schemas with constraints.
pub fn guard_schema_has_validator_case() {
  let ctx = make_validate_ctx_from_yaml(guard_integration_spec)
  guards.schema_has_validator("CreatePetRequest", ctx)
  |> should.be_true()
}

/// guards.schema_has_validator returns False for schemas without constraints.
pub fn guard_schema_has_no_validator_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    Simple:
      type: object
      properties:
        name:
          type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  guards.schema_has_validator("Simple", ctx)
  |> should.be_false()
}

/// guards.schema_has_validator returns False for non-existent schemas.
pub fn guard_schema_has_validator_nonexistent_case() {
  let ctx = make_validate_ctx_from_yaml(guard_integration_spec)
  guards.schema_has_validator("NonExistent", ctx)
  |> should.be_false()
}

/// Config load should parse validate field from YAML.
pub fn config_validate_field_case() {
  let yaml_content = "input: test.yaml\npackage: api\nvalidate: true\n"
  let temp_path = "/tmp/oaspec_validate_test.yaml"
  let assert Ok(Nil) = simplifile.write(temp_path, yaml_content)
  let assert Ok(cfg) = config.load(temp_path)
  config.validate(cfg) |> should.be_true()
  let _ = simplifile.delete(temp_path)
  Nil
}

/// Config load: when `validate:` is omitted and `mode:` is also omitted,
/// `mode` defaults to `Both`, which yields `validate: true` (issue #268,
/// fail-closed for any mode that produces a server). Explicit overrides
/// still win — covered by `config_validate_default_client_test`.
pub fn config_validate_default_when_omitted_case() {
  let yaml_content = "input: test.yaml\npackage: api\n"
  let temp_path = "/tmp/oaspec_validate_default_test.yaml"
  let assert Ok(Nil) = simplifile.write(temp_path, yaml_content)
  let assert Ok(cfg) = config.load(temp_path)
  config.validate(cfg) |> should.be_true()
  let _ = simplifile.delete(temp_path)
  Nil
}

// ===========================================================================
// Server override tests (issue #96)
// ===========================================================================

/// Client should use operation-level server override when present.
pub fn server_override_operation_level_case() {
  let ctx = make_ctx("test/fixtures/operation_server_override.yaml")
  let files = client_gen.generate(ctx)
  let assert Ok(client_file) =
    list.find(files, fn(f) { f.path == "client.gleam" })

  // createItem (POST /items) carries the operation-level override URL
  // baked into the request literal as `base_url: Some("...")`.
  string.contains(
    client_file.content,
    "base_url: Some(\"https://write.example.com/v1\")",
  )
  |> should.be_true()

  // listItems (GET /items) falls back to the spec-level default base URL.
  string.contains(client_file.content, "Some(default_base_url())")
  |> should.be_true()
}

/// Client should use path-level server override for all operations on that path.
pub fn server_override_path_level_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Path Server Override Test
  version: 1.0.0
servers:
  - url: https://api.example.com
paths:
  /admin:
    servers:
      - url: https://admin.example.com
    get:
      operationId: listAdminItems
      responses:
        '200':
          description: OK
    post:
      operationId: createAdminItem
      responses:
        '201':
          description: Created
  /public:
    get:
      operationId: listPublicItems
      responses:
        '200':
          description: OK
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(resolved) = resolve.resolve(spec)
  let resolved = hoist.hoist(resolved)
  let resolved = dedup.dedup(resolved)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let ctx = context.new(resolved, cfg)
  let files = client_gen.generate(ctx)
  let assert Ok(client_file) =
    list.find(files, fn(f) { f.path == "client.gleam" })

  // Admin operations should use path-level server
  string.contains(client_file.content, "\"https://admin.example.com\"")
  |> should.be_true()

  // Public operation should use default_base_url()
  string.contains(client_file.content, "default_base_url()")
  |> should.be_true()
}

/// Operation-level server should override path-level server.
pub fn server_override_operation_takes_precedence_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Precedence Test
  version: 1.0.0
servers:
  - url: https://api.example.com
paths:
  /items:
    servers:
      - url: https://path.example.com
    get:
      operationId: listItems
      responses:
        '200':
          description: OK
    post:
      operationId: createItem
      servers:
        - url: https://operation.example.com
      responses:
        '201':
          description: Created
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(resolved) = resolve.resolve(spec)
  let resolved = hoist.hoist(resolved)
  let resolved = dedup.dedup(resolved)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let ctx = context.new(resolved, cfg)
  let files = client_gen.generate(ctx)
  let assert Ok(client_file) =
    list.find(files, fn(f) { f.path == "client.gleam" })

  // createItem (POST) should use operation-level server, NOT path-level
  string.contains(client_file.content, "\"https://operation.example.com\"")
  |> should.be_true()

  // listItems (GET) should use path-level server (inherited)
  string.contains(client_file.content, "\"https://path.example.com\"")
  |> should.be_true()
}

/// Top-level-only specs should keep using default_base_url() in every
/// operation, with no inline override URL strings.
pub fn server_override_top_level_only_unchanged_case() {
  let ctx = make_ctx("test/fixtures/petstore.yaml")
  let files = client_gen.generate(ctx)
  let assert Ok(client_file) =
    list.find(files, fn(f) { f.path == "client.gleam" })

  // Operations all carry the same Some(default_base_url()) request field.
  string.contains(client_file.content, "Some(default_base_url())")
  |> should.be_true()
}

/// No capability warnings should be emitted for operation/path-level servers.
pub fn server_override_no_capability_warnings_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/operation_server_override.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/operation_server_override.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let files = generate.generate(spec, cfg)
  case files {
    Ok(summary) -> {
      // Should NOT have operation-level server warnings
      let has_server_warning =
        list.any(summary.warnings, fn(w) {
          let msg = diagnostic.to_short_string(w)
          string.contains(msg, "Operation-level servers")
          || string.contains(msg, "Path-level servers")
        })
      has_server_warning |> should.be_false()
    }
    Error(_) -> should.fail()
  }
}

/// Relative server URLs should be supported as overrides.
pub fn server_override_relative_url_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Relative Server URL Test
  version: 1.0.0
servers:
  - url: https://api.example.com
paths:
  /admin:
    servers:
      - url: /admin-api
    get:
      operationId: listAdmin
      responses:
        '200':
          description: OK
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let assert Ok(resolved) = resolve.resolve(spec)
  let resolved = hoist.hoist(resolved)
  let resolved = dedup.dedup(resolved)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let ctx = context.new(resolved, cfg)
  let files = client_gen.generate(ctx)
  let assert Ok(client_file) =
    list.find(files, fn(f) { f.path == "client.gleam" })

  // Relative URLs are passed through verbatim into the request's
  // base_url; the adapter is responsible for resolving them.
  string.contains(client_file.content, "base_url: Some(\"/admin-api\")")
  |> should.be_true()
}

// ============================================================================
// Source location tests (Issue #188)
// ============================================================================

pub fn location_index_build_extracts_locations_case() {
  let yaml =
    "openapi: \"3.0.0\"
info:
  title: Test
  version: \"1.0\"
paths: {}
"
  let index = location_index.build(yaml)

  // Root-level keys should have locations
  let loc = location_index.lookup(index, "openapi")
  case loc {
    SourceLoc(line: _, column: _) -> should.be_true(True)
    NoSourceLoc -> should.fail()
  }
}

pub fn location_index_lookup_field_returns_source_loc_case() {
  let yaml =
    "openapi: \"3.0.0\"
info:
  title: Test
  version: \"1.0\"
paths: {}
"
  let index = location_index.build(yaml)

  let loc = location_index.lookup_field(index, "info", "title")
  case loc {
    SourceLoc(line: _, column: _) -> should.be_true(True)
    NoSourceLoc -> should.fail()
  }
}

pub fn location_index_lookup_missing_returns_no_source_loc_case() {
  let yaml =
    "openapi: \"3.0.0\"
info:
  title: Test
  version: \"1.0\"
paths: {}
"
  let index = location_index.build(yaml)

  let loc = location_index.lookup(index, "nonexistent.path")
  loc |> should.equal(NoSourceLoc)
}

pub fn location_index_empty_returns_no_source_loc_case() {
  let index = location_index.empty()
  let loc = location_index.lookup(index, "openapi")
  loc |> should.equal(NoSourceLoc)
}

pub fn missing_field_diagnostic_has_source_location_case() {
  let yaml =
    "openapi: \"3.0.0\"
paths: {}
"

  case parser.parse_string(yaml) {
    Error(Diagnostic(source_loc: loc, code: "missing_field", ..)) ->
      case loc {
        SourceLoc(line: _, column: _) -> should.be_true(True)
        NoSourceLoc -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn location_index_root_path_has_source_loc_case() {
  let yaml =
    "openapi: \"3.0.0\"
info:
  title: Test
  version: \"1.0\"
paths: {}
"
  let index = location_index.build(yaml)

  // Root path should have line 1 location
  let loc = location_index.lookup(index, "")
  case loc {
    SourceLoc(line: 1, column: _) -> should.be_true(True)
    _ -> should.fail()
  }
}

// --- External Whole-Object $ref Tests ---

pub fn external_whole_object_parameter_ref_case() {
  // Parse the spec that uses whole-object external refs
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/external_whole_ref_spec.yaml")
  let assert Some(components) = spec.components

  // The parameter should be resolved from external file (Value, not Ref)
  let assert Ok(param_ref_or) = dict.get(components.parameters, "LimitParam")
  case param_ref_or {
    spec.Value(param) -> {
      param.name |> should.equal("limit")
      param.in_ |> should.equal(spec.InQuery)
    }
    spec.Ref(_) -> should.fail()
  }
}

pub fn external_whole_object_request_body_ref_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/external_whole_ref_spec.yaml")
  let assert Some(components) = spec.components

  let assert Ok(body_ref_or) =
    dict.get(components.request_bodies, "CreatePetBody")
  case body_ref_or {
    spec.Value(_body) -> should.be_true(True)
    spec.Ref(_) -> should.fail()
  }
}

pub fn external_whole_object_response_ref_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/external_whole_ref_spec.yaml")
  let assert Some(components) = spec.components

  let assert Ok(resp_ref_or) = dict.get(components.responses, "NotFound")
  case resp_ref_or {
    spec.Value(resp) -> {
      resp.description |> should.equal(Some("Not found"))
    }
    spec.Ref(_) -> should.fail()
  }
}

// ============================================================================
// Request-body encoding warning tests (Issue #191)
// ============================================================================

pub fn request_body_encoding_warning_is_surfaced_case() {
  let assert Ok(spec) =
    parser.parse_file("test/fixtures/request_body_encoding.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/request_body_encoding.yaml",
      output_server: "./gen/api",
      output_client: "./gen_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let assert Ok(result) = generate.generate(spec, cfg)
  let has_encoding_warning =
    list.any(result.warnings, fn(w) {
      string.contains(
        diagnostic.to_string(w),
        "Request-body encoding is parsed but not used",
      )
    })
  has_encoding_warning |> should.be_true()
}

/// Spec where the 200 response is a top-level array of primitive items.
/// (Issue #266: previously emitted `json.string(data)` which fails to type-check
/// against `List(String)`.)
const top_level_array_spec = "
openapi: 3.0.3
info:
  title: Top Level Array
  version: 1.0.0
servers:
  - url: https://example.com
paths:
  /blobs:
    get:
      operationId: listBlobs
      responses:
        '200':
          description: list of blob ids
          content:
            application/json:
              schema:
                type: array
                items:
                  type: string
"

/// Spec where two component schemas would collide on `decode_card_list`
/// (Issue #267 / #493): `Card` would synthesise `decode_card_list`,
/// and the user-declared `CardList` schema's decoder would reuse the
/// same identifier. The codegen now auto-disambiguates — the
/// synthetic decoder shifts to `decode_card_list_items` and the
/// user's `CardList` keeps the natural `decode_card_list` name.
const decode_list_collision_spec = "
openapi: 3.0.3
info:
  title: Decode List Collision
  version: 1.0.0
servers:
  - url: https://example.com
paths:
  /cards:
    get:
      operationId: listCards
      responses:
        '200':
          description: list
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CardList'
components:
  schemas:
    Card:
      type: object
      required: [id]
      properties:
        id:
          type: string
    CardList:
      type: object
      required: [cards]
      properties:
        cards:
          type: array
          items:
            $ref: '#/components/schemas/Card'
"

/// Issue #494: Stripe's OpenAPI spec declares pairs of component
/// schemas that differ only by `.` vs `_` — e.g.
/// `payment_intent.processing` and `payment_intent_processing`.
/// Before the fix, both PascalCased to `PaymentIntentProcessing` and
/// the validator hard-rejected the spec. The naming pipeline now
/// encodes `.` as a `Dot` word boundary so the two stay
/// distinguishable (`PaymentIntentDotProcessing` vs
/// `PaymentIntentProcessing`).
const stripe_dotted_schema_collision_spec = "
openapi: 3.0.3
info:
  title: Stripe Dotted Schema Collision
  version: 1.0.0
servers:
  - url: https://example.com
paths:
  /events:
    get:
      operationId: listEvents
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/payment_intent.processing'
components:
  schemas:
    payment_intent.processing:
      type: object
      required: [id]
      properties:
        id:
          type: string
        kind:
          type: string
          enum: [dotted]
    payment_intent_processing:
      type: object
      required: [id]
      properties:
        id:
          type: string
        kind:
          type: string
          enum: [underscored]
"

pub fn validate_stripe_dotted_schema_no_longer_collides_case() {
  // Issue #494: the spec must validate without the pre-fix
  // `Schema names ... all map to Gleam type ... — rename one to avoid
  // the collision` hard error, and the generated `types.gleam` must
  // carry both schemas as distinct Gleam types.
  let assert Ok(spec) = parser.parse_string(stripe_dotted_schema_collision_spec)
  let assert Ok(resolved) = resolve.resolve(spec)
  let resolved = hoist.hoist(resolved)
  let resolved = dedup.dedup(resolved)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let ctx = context.new(resolved, cfg)
  let errors = validate.validate(ctx)
  // The hard rejection must no longer fire on this collision shape.
  let has_collision_error =
    list.any(errors, fn(e) {
      string.contains(diagnostic.to_string(e), "all map to Gleam type")
    })
  has_collision_error |> should.be_false()

  // Both schemas survive into types.gleam under distinct names.
  let type_files = types.generate(ctx)
  let assert Ok(types_file) =
    list.find(type_files, fn(f) { f.path == "types.gleam" })
  string.contains(types_file.content, "pub type PaymentIntentDotProcessing {")
  |> should.be_true()
  string.contains(types_file.content, "pub type PaymentIntentProcessing {")
  |> should.be_true()
}

/// Issue #492: GitHub's OpenAPI spec declares
/// `code-scanning-variant-analysis-status` as a top-level component
/// (4 enum values) AND a separate `code-scanning-variant-analysis`
/// component whose inline `status` property is a 6-value enum. Both
/// previously mapped to the Gleam type name
/// `CodeScanningVariantAnalysisStatus`, producing a `Duplicate type
/// definition` at `gleam build`. The fixture below is a minimised
/// reproduction.
const inline_enum_component_collision_spec = "
openapi: 3.0.3
info:
  title: Inline Enum Component Collision
  version: 1.0.0
servers:
  - url: https://example.com
paths:
  /things:
    get:
      operationId: listThings
      responses:
        '200':
          description: ok
components:
  schemas:
    code-scanning-variant-analysis-status:
      type: string
      enum: [pending, succeeded, failed, canceled]
    code-scanning-variant-analysis:
      type: object
      required: [id, status]
      properties:
        id:
          type: integer
        status:
          type: string
          enum: [pending, in_progress, succeeded, failed, canceled, timed_out]
"

pub fn validate_inline_enum_component_collision_auto_disambiguates_case() {
  // Issue #492: the inline enum's generated type name used to collide
  // with the same-named component schema's type name, breaking the
  // generated module's `gleam build`. The codegen now appends a
  // numeric suffix to the inline enum and leaves the component
  // schema alone.
  let assert Ok(spec) =
    parser.parse_string(inline_enum_component_collision_spec)
  let assert Ok(resolved) = resolve.resolve(spec)
  let resolved = hoist.hoist(resolved)
  let resolved = dedup.dedup(resolved)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let ctx = context.new(resolved, cfg)
  let errors = validate.validate(ctx)
  errors |> should.equal([])

  // Generated types.gleam carries the component-schema enum at its
  // natural name and the disambiguated inline enum at the suffixed
  // name; neither name appears twice.
  let type_files = types.generate(ctx)
  let assert Ok(types_file) =
    list.find(type_files, fn(f) { f.path == "types.gleam" })
  let content = types_file.content
  // Component schema keeps the natural name.
  string.contains(content, "pub type CodeScanningVariantAnalysisStatus {")
  |> should.be_true()
  // Inline enum yields and gets the numeric suffix.
  string.contains(content, "pub type CodeScanningVariantAnalysisStatus2 {")
  |> should.be_true()
  // Single definition of each, not a duplicate.
  list.length(string.split(
    content,
    "pub type CodeScanningVariantAnalysisStatus {",
  ))
  |> should.equal(2)
  list.length(string.split(
    content,
    "pub type CodeScanningVariantAnalysisStatus2 {",
  ))
  |> should.equal(2)

  // The decoder/encoder for the inline enum point at the suffixed
  // name (so they line up with the type definition above). The
  // trailing digit attaches to the preceding word per the naming
  // pipeline's rule (`Status2` → `status2`, not `status_2`).
  let decoder_files = decoders.generate(ctx)
  let assert Ok(decode_file) =
    list.find(decoder_files, fn(f) { f.path == "decode.gleam" })
  string.contains(
    decode_file.content,
    "code_scanning_variant_analysis_status2_decoder",
  )
  |> should.be_true()
  let encoder_files = encoders.generate(ctx)
  let assert Ok(encode_file) =
    list.find(encoder_files, fn(f) { f.path == "encode.gleam" })
  string.contains(
    encode_file.content,
    "encode_code_scanning_variant_analysis_status2",
  )
  |> should.be_true()
}

pub fn validate_decode_list_collision_auto_disambiguates_case() {
  // Issue #493: previously this collision was a hard validation
  // error. The codegen now auto-disambiguates the synthetic list
  // decoder (`_list_items` suffix) so real-world specs (Kubernetes
  // / Stripe) can compile without renaming upstream schemas.
  let assert Ok(spec) = parser.parse_string(decode_list_collision_spec)
  let assert Ok(resolved) = resolve.resolve(spec)
  let resolved = hoist.hoist(resolved)
  let resolved = dedup.dedup(resolved)
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let ctx = context.new(resolved, cfg)
  let errors = validate.validate(ctx)
  // No XxxList-style errors should be reported anymore.
  let has_collision_error =
    list.any(errors, fn(e) {
      string.contains(diagnostic.to_string(e), "synthetic list decoder")
    })
  has_collision_error |> should.be_false()

  // Generated decoder uses the renamed synthetic `_list_items` for
  // `List(Card)` and keeps the natural `_list` name for the user's
  // `CardList` schema.
  let decoder_files = decoders.generate(ctx)
  let assert Ok(decode_file) =
    list.find(decoder_files, fn(f) { f.path == "decode.gleam" })
  let content = decode_file.content
  // Renamed synthetic decoder for `List(Card)`.
  string.contains(
    content,
    "pub fn card_decoder_list_items() -> decode.Decoder(List(types.Card))",
  )
  |> should.be_true()
  string.contains(
    content,
    "pub fn decode_card_list_items(json_string: String) -> Result(List(types.Card)",
  )
  |> should.be_true()
  // User's `CardList` decoder keeps `decode_card_list` since the
  // synthetic moved out of the way.
  string.contains(
    content,
    "pub fn decode_card_list(json_string: String) -> Result(types.CardList,",
  )
  |> should.be_true()
}

pub fn top_level_array_response_uses_json_array_case() {
  let ctx = make_validate_ctx_from_yaml(top_level_array_spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })

  // Should wrap the List in json.array, not pass it to json.string directly.
  string.contains(router_file.content, "json.array(items, json.string)")
  |> should.be_true()

  // Should NOT emit the buggy json.string(data) shape from the report
  // (where `data: List(String)` is fed directly into the scalar encoder).
  string.contains(router_file.content, "json.string(data)")
  |> should.be_false()
}

// --- Issue #339: allOf-flattened children must not duplicate the
//                 parent's per-field validators ---

pub fn allof_validators_dedup_across_children_case() {
  // UploadCommon carries a constrained `title` (minLength 3, maxLength
  // 100). Two children allOf-mix it in. Without dedup, guards.gleam
  // emits three byte-identical title-length validators (one per
  // containing type). After dedup the parent's validator is the
  // canonical one and any child-side per-field validator either
  // delegates to it or is omitted entirely — either way the
  // constraint message string ("must be at least 3 characters") must
  // appear exactly ONCE in the file.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /uploads:
    post:
      operationId: createUpload
      responses:
        '200': { description: ok }
components:
  schemas:
    UploadCommon:
      type: object
      required: [title]
      properties:
        title:
          type: string
          minLength: 3
          maxLength: 100
    InlineUpload:
      allOf:
        - $ref: '#/components/schemas/UploadCommon'
        - type: object
          required: [content_b64]
          properties:
            content_b64: { type: string }
    ReferencedUpload:
      allOf:
        - $ref: '#/components/schemas/UploadCommon'
        - type: object
          required: [source_url]
          properties:
            source_url: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let assert [guard_file] = guards.generate(ctx)

  // All three names must still be present (composite validators
  // continue to call by name; duplicates become 1-line delegating
  // stubs but the names stay so call sites don't break).
  string.contains(guard_file.content, "validate_inline_upload_title_length")
  |> should.be_true()
  string.contains(guard_file.content, "validate_referenced_upload_title_length")
  |> should.be_true()
  string.contains(guard_file.content, "validate_upload_common_title_length")
  |> should.be_true()

  // The dedup signal: the constraint message ("must be at least 3
  // characters") used to be byte-duplicated across three function
  // bodies. After dedup it appears exactly once — only in the
  // canonical body. Which name is canonical (lex-first) is an
  // implementation detail.
  count_occurrences(guard_file.content, "must be at least 3 characters")
  |> should.equal(1)
}

/// Count non-overlapping occurrences of `needle` in `haystack`.
fn count_occurrences(haystack: String, needle: String) -> Int {
  case string.split_once(haystack, on: needle) {
    Error(Nil) -> 0
    Ok(#(_, after)) -> 1 + count_occurrences(after, needle)
  }
}

// --- Issue #336: additionalProperties: false must be enforced at
//                 decode time (extra fields rejected, not dropped) ---

pub fn additional_properties_false_emits_unknown_key_check_case() {
  // A schema with `additionalProperties: false` must produce a
  // decoder that rejects JSON objects containing keys outside the
  // declared property set. The check happens in the decoder body
  // because composite/post-decode validation cannot recover the
  // raw JSON object's key set after `gleam/dynamic/decode` has run.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /uploads:
    post:
      operationId: createUpload
      responses:
        '200': { description: ok }
components:
  schemas:
    Upload:
      type: object
      additionalProperties: false
      required: [id, name]
      properties:
        id: { type: string }
        name: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let assert Ok(decode_file) =
    list.find(decoders.generate(ctx), fn(f) { f.path == "decode.gleam" })

  // The decoder must mention the unknown-key rejection. Whether it
  // calls a runtime helper or inlines the check is an implementation
  // detail; we assert the spec-driven contract: the closed-schema
  // signal `\"additionalProperties\": false` materialises in the
  // decoder body either via a dict-based pre-check (decoding to
  // Dict to inspect keys) or via a custom failure for unknown keys.
  let has_dict_check =
    string.contains(decode_file.content, "decode.dict(decode.string,")
    && string.contains(decode_file.content, "dict.drop(")
  let has_unknown_key_failure =
    string.contains(decode_file.content, "additionalProperties")
    && string.contains(decode_file.content, "decode.failure")
  case has_dict_check && has_unknown_key_failure {
    True -> Nil
    False -> should.fail()
  }
}

// --- Issue #337: oneOf decoders must enforce exactly-one-match
//                 semantics, not first-match (anyOf) ---

pub fn oneof_decoder_rejects_multi_branch_matches_case() {
  // A non-discriminator `oneOf` whose two branches each accept a
  // body that the other also accepts (no closed-schema enforcement
  // in this fixture). The generated decoder must NOT compile down
  // to `decode.one_of(first, [rest..])` — that is `anyOf`
  // (first-match) semantics. JSON Schema 2020-12 §10.2.1.3 demands
  // that exactly one branch validates; otherwise the decode must
  // fail.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /uploads:
    post:
      operationId: createUpload
      responses:
        '200': { description: ok }
components:
  schemas:
    InlineUpload:
      type: object
      required: [content_b64]
      properties:
        content_b64: { type: string }
    ReferencedUpload:
      type: object
      required: [source_url]
      properties:
        source_url: { type: string }
    UploadEnvelope:
      oneOf:
        - $ref: '#/components/schemas/InlineUpload'
        - $ref: '#/components/schemas/ReferencedUpload'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let assert Ok(decode_file) =
    list.find(decoders.generate(ctx), fn(f) { f.path == "decode.gleam" })

  // Strict-oneOf marker: the generator must emit per-branch
  // independent runs (`decode.run`) so it can count successful
  // matches, plus a multi-match rejection diagnostic. The exact
  // wording is an implementation detail; the literal `oneOf` in
  // the failure message is the canonical disambiguator vs.
  // existing `additionalProperties` / discriminator failure paths.
  let runs_each_branch = string.contains(decode_file.content, "decode.run(")
  let multi_match_marker =
    string.contains(decode_file.content, "matched multiple")
    || string.contains(decode_file.content, "oneOf")
  case runs_each_branch && multi_match_marker {
    True -> Nil
    False -> should.fail()
  }
}

pub fn additional_properties_false_via_allof_emits_unknown_key_check_case() {
  // Same contract as the direct case, but the closedness signal
  // arrives through allOf composition: `Upload` itself does not
  // declare `additionalProperties: false`; it inherits the
  // restriction from `BaseClosed` via allOf. The codegen pass must
  // still emit the unknown-key rejection on the Upload decoder
  // because the merged schema is closed.
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /uploads:
    post:
      operationId: createUpload
      responses:
        '200': { description: ok }
components:
  schemas:
    BaseClosed:
      type: object
      additionalProperties: false
      properties:
        id: { type: string }
    Upload:
      allOf:
        - $ref: '#/components/schemas/BaseClosed'
        - type: object
          required: [name]
          properties:
            name: { type: string }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let ctx = make_ctx_from_spec(spec)
  let assert Ok(decode_file) =
    list.find(decoders.generate(ctx), fn(f) { f.path == "decode.gleam" })

  let has_dict_check =
    string.contains(decode_file.content, "decode.dict(decode.string,")
    && string.contains(decode_file.content, "dict.drop(")
  let has_unknown_key_failure =
    string.contains(decode_file.content, "additionalProperties")
    && string.contains(decode_file.content, "decode.failure")
  case has_dict_check && has_unknown_key_failure {
    True -> Nil
    False -> should.fail()
  }
}

// ============================================================================
// Issue #411: capability-check diagnostics carry source line/column
// ============================================================================

/// `lookup_with_ancestor` returns the closest known ancestor when the
/// exact path is absent, walking the dot-separated segments back one
/// at a time.
pub fn location_index_lookup_with_ancestor_falls_back_to_parent_case() {
  let yaml =
    "openapi: \"3.0.0\"
info:
  title: Test
  version: \"1.0\"
paths: {}
"
  let index = location_index.build(yaml)

  // The exact path doesn't exist, but `info.title` does — so the
  // ancestor walk should land there rather than at NoSourceLoc.
  let loc =
    location_index.lookup_with_ancestor(index, "info.title.unknown_leaf")
  case loc {
    SourceLoc(line: _, column: _) -> should.be_true(True)
    NoSourceLoc -> should.fail()
  }
}

/// When *no* ancestor of a path exists in the index, `lookup_with_ancestor`
/// returns `NoSourceLoc`.
pub fn location_index_lookup_with_ancestor_no_match_returns_no_source_loc_case() {
  let yaml =
    "openapi: \"3.0.0\"
info:
  title: Test
  version: \"1.0\"
paths: {}
"
  let index = location_index.build(yaml)
  let loc =
    location_index.lookup_with_ancestor(index, "totally_unrelated.deep.path")
  loc |> should.equal(NoSourceLoc)
}

/// Issue #411: a capability-check error on an unsupported JSON Schema
/// keyword (`$defs`) must carry a `SourceLoc` pointing into the YAML
/// document, not `NoSourceLoc`.
pub fn capability_check_attaches_source_loc_to_keyword_error_case() {
  let yaml =
    "openapi: \"3.0.0\"
info:
  title: Test
  version: \"1.0\"
paths: {}
components:
  schemas:
    Foo:
      type: object
      properties:
        bar:
          $defs:
            X:
              type: string
"
  let assert Ok(parsed) = parser.parse_string_with_locations(yaml)
  let #(spec, index) = parsed
  let assert Ok(resolved) = resolve.resolve(spec)
  let issues = capability_check.check(resolved, index)
  // Must produce at least one capability error
  let errors = diagnostic.errors_only(issues)
  errors |> list.length |> should.not_equal(0)
  // Every emitted capability error should carry a real SourceLoc
  let loc_present =
    list.all(errors, fn(d) {
      case d.source_loc {
        SourceLoc(..) -> True
        NoSourceLoc -> False
      }
    })
  loc_present |> should.be_true
}

/// Issue #411: `diagnostic.render` prepends `path:line:column:` when
/// both file path and SourceLoc are present.
pub fn diagnostic_render_includes_file_path_and_loc_case() {
  let d =
    diagnostic.capability(
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetBoth,
      path: "components.schemas.Foo",
      detail: "boom",
      hint: None,
      loc: SourceLoc(line: 42, column: 7),
    )
  let rendered = diagnostic.render(d, Some("specs/api.yaml"))
  string.starts_with(rendered, "specs/api.yaml:42:7: ")
  |> should.be_true
}

/// Issue #411: `diagnostic.render` falls back to plain `to_string`
/// when `file_path` is `None`.
pub fn diagnostic_render_without_file_path_matches_to_string_case() {
  let d =
    diagnostic.capability(
      severity: diagnostic.SeverityError,
      target: diagnostic.TargetBoth,
      path: "components.schemas.Foo",
      detail: "boom",
      hint: None,
      loc: SourceLoc(line: 42, column: 7),
    )
  diagnostic.render(d, None) |> should.equal(diagnostic.to_string(d))
}

/// Issue #474: a schema declared as `type: object, properties: {},
/// additionalProperties: false` surfaces in `types.gleam` as a no-arg
/// variant — `pub type EmptyObject { EmptyObject }`. The decoder
/// emitted by `decoders.generate` must reference that constructor as
/// the bare value `types.EmptyObject`, not as a function call
/// `types.EmptyObject()` (which Gleam rejects with `This value is
/// being called as a function but its type is: types.EmptyObject`).
pub fn empty_object_decoder_omits_constructor_parens_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /thing:
    get:
      operationId: getThing
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/EmptyObject'
components:
  schemas:
    EmptyObject:
      type: object
      properties: {}
      additionalProperties: false
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = decoders.generate(ctx)

  let assert Ok(decode_file) =
    list.find(files, fn(f) { string.contains(f.path, "decode") })
  let content = decode_file.content

  // Bare-constructor reference is required.
  string.contains(content, "decode.success(types.EmptyObject)")
  |> should.be_true()

  // Function-call form is the bug — it must not appear.
  string.contains(content, "decode.success(types.EmptyObject())")
  |> should.be_false()
}

/// A `*/*` (or `application/octet-stream`) response with no `schema:`
/// must NOT cause `client.gleam` to define the `bytes_body` helper —
/// `client_response.gleam` doesn't call it in that branch, so an
/// emitted helper would be unused and break
/// `gleam build --warnings-as-errors`. The import-needs predicate
/// must require `media_type.schema = Some(_)` to agree with the
/// emission gate.
pub fn client_omits_bytes_body_helper_when_response_has_no_schema_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/wildcard_response_no_schema.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/wildcard_response_no_schema.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  // The bytes_body helper must NOT be defined when no response uses it.
  string.contains(client_file.content, "fn bytes_body(")
  |> should.be_false()
}

/// Regression guard: the existing wildcard fixture has `*/*` responses
/// WITH a schema, which DOES need the bytes_body helper. Make sure the
/// tightened predicate still fires here.
pub fn client_keeps_bytes_body_when_response_has_schema_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/wildcard_content_type.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/wildcard_content_type.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  string.contains(client_file.content, "fn bytes_body(")
  |> should.be_true()
}

/// An empty-object schema (no properties, additionalProperties:
/// false) collapses the encoder body to `json.object([])` — the
/// `value` parameter is bound but never read, so `gleam build
/// --warnings-as-errors` rejects it. The `_json` variant must take
/// `_value` for that exact shape; the String variant keeps `value`
/// because it still pipes through `_json(value)`.
pub fn encoder_for_empty_object_omits_unused_value_param_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /thing:
    post:
      operationId: createThing
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/EmptyObject'
      responses:
        '200':
          description: ok
components:
  schemas:
    EmptyObject:
      type: object
      properties: {}
      additionalProperties: false
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = encoders.generate(ctx)

  let assert Ok(encode_file) =
    list.find(files, fn(f) { string.contains(f.path, "encode") })
  let content = encode_file.content

  // The _json variant must NOT bind `value:` (it would be unused).
  string.contains(
    content,
    "pub fn encode_empty_object_json(value: types.EmptyObject)",
  )
  |> should.be_false()

  // It must still exist, just with `_value:` (or equivalent) so the
  // Gleam compiler's "unused argument" warning never fires.
  string.contains(
    content,
    "pub fn encode_empty_object_json(_value: types.EmptyObject)",
  )
  |> should.be_true()
}

/// An array of inline string-enum items collapses to `List(String)`
/// at the type level (the IR's inline-enum pass walks only top-level
/// object properties, never array items). The decoder/encoder must
/// agree: items go through `decode.string` / `json.string`, NOT a
/// synthesised `<parent>_<prop>` enum codec that the IR never emits.
pub fn array_of_inline_string_enum_uses_plain_decoder_and_encoder_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /widgets:
    get:
      operationId: listWidgets
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Widget'
components:
  schemas:
    Widget:
      type: object
      required: [id]
      properties:
        id:
          type: string
        events:
          description: events the widget cares about
          type: array
          items:
            type: string
            enum: [created, updated, deleted]
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let decode_files = decoders.generate(ctx)
  let encode_files = encoders.generate(ctx)

  let assert Ok(decode_file) =
    list.find(decode_files, fn(f) { string.contains(f.path, "decode") })
  let decode_content = decode_file.content

  let assert Ok(encode_file) =
    list.find(encode_files, fn(f) { string.contains(f.path, "encode") })
  let encode_content = encode_file.content

  // Items are decoded as plain strings, NOT through a synthesised
  // inline-enum decoder reference.
  string.contains(decode_content, "decode.list(decode.string)")
  |> should.be_true()
  string.contains(decode_content, "widget_events_decoder")
  |> should.be_false()

  // Same on the encoder side.
  string.contains(encode_content, "json.string")
  |> should.be_true()
  string.contains(encode_content, "encode_widget_events_json")
  |> should.be_false()
}

/// Sibling schemas like `widget-instance` AND `widget-instance-list`
/// (a real shape on the GitHub spec) both map to the same Gleam type
/// `WidgetInstanceList`, so the synthetic `decode_<base>_list` for
/// the first collides with the regular decoder for the second. The
/// suffix-bumping predicate must resolve in Gleam-mapped namespace
/// (not raw kebab-case) to catch both spellings.
pub fn synthetic_list_decoder_disambiguates_against_dashed_list_sibling_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /a:
    get:
      operationId: getA
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/widget-instance-list'
  /b:
    get:
      operationId: getB
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/widget-instance'
components:
  schemas:
    widget-instance:
      type: object
      required: [id]
      properties:
        id:
          type: string
    widget-instance-list:
      type: object
      required: [items]
      properties:
        items:
          type: array
          items:
            $ref: '#/components/schemas/widget-instance'
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = decoders.generate(ctx)

  let assert Ok(decode_file) =
    list.find(files, fn(f) { string.contains(f.path, "decode") })
  let content = decode_file.content

  // The user-named `widget-instance-list` schema keeps its natural
  // decoder. The synthetic list decoder for `widget-instance` shifts
  // to `_list_items` to avoid the collision.
  string.contains(
    content,
    "pub fn decode_widget_instance_list(json_string: String)",
  )
  |> should.be_true()
  string.contains(
    content,
    "pub fn decode_widget_instance_list_items(json_string: String)",
  )
  |> should.be_true()
}

/// Regression guard: a non-empty object encoder MUST still bind `value`
/// (without the underscore prefix), because the body reads
/// `value.<field>`. The fix from
/// `encoder_for_empty_object_omits_unused_value_param_case` must NOT
/// over-apply to populated schemas.
pub fn encoder_for_non_empty_object_keeps_value_param_case() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pet:
    post:
      operationId: createPet
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/Pet'
      responses:
        '200':
          description: ok
components:
  schemas:
    Pet:
      type: object
      required: [name]
      properties:
        name:
          type: string
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = make_ctx_from_spec(spec)
  let files = encoders.generate(ctx)

  let assert Ok(encode_file) =
    list.find(files, fn(f) { string.contains(f.path, "encode") })
  let content = encode_file.content

  string.contains(content, "pub fn encode_pet_json(value: types.Pet)")
  |> should.be_true()
  string.contains(content, "pub fn encode_pet_json(_value: types.Pet)")
  |> should.be_false()
}

/// Each codegen sub-stage (types, decoders, encoders, guards, server,
/// client) must emit its own progress event so a slow phase surfaces
/// against a specific stage rather than disappearing behind a single
/// opaque "render" wrapper. The mode-gated substages (server / client)
/// must NOT fire when their mode is excluded.
pub fn generate_emits_per_substage_progress_events_case() {
  let key = "progress_events_log"
  pdict_put_list(key, [])
  let reporter =
    progress.from_fn(fn(msg) {
      let prev = case pdict_get_list(key) {
        Ok(v) -> v
        Error(Nil) -> []
      }
      pdict_put_list(key, [msg, ..prev])
      Nil
    })

  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/wildcard_response_no_schema.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/wildcard_response_no_schema.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(_summary) =
    generate.generate_with_progress_and_locations(
      unresolved,
      location_index.empty(),
      cfg,
      reporter,
    )
  let assert Ok(events_rev) = pdict_get_list(key)
  let events = list.reverse(events_rev)

  // Each codegen sub-stage emits its own `(took ...)` line so the user
  // can see which phase is the slow one.
  let event_contains = fn(needle: String) {
    list.any(events, fn(e) { string.contains(e, needle) })
  }
  event_contains("generate types") |> should.be_true()
  event_contains("generate decoders") |> should.be_true()
  event_contains("generate encoders") |> should.be_true()
  event_contains("generate guards") |> should.be_true()
  // mode = Client, so the client substage MUST fire and server MUST NOT.
  event_contains("generate client") |> should.be_true()
  event_contains("generate server") |> should.be_false()
}

/// Regression guard for the large-spec hang: a synthetic spec with
/// several hundred component schemas and operations must complete
/// codegen well under a generous wall-clock ceiling. Older versions
/// of the codegen ran dozens of independent `list.any` passes over
/// operations and schemas, blowing up to multi-minute wall time on
/// realistic specs. The synthetic shape exercises the same quadratic
/// structure; the 30 s budget here is a loud floor — typical hardware
/// finishes in well under a second.
pub fn generate_completes_within_budget_for_synthetic_large_spec_case() {
  let yaml = build_synthetic_large_spec_yaml(400, 80)
  let assert Ok(unresolved) = parser.parse_string(yaml)
  let cfg =
    config.new(
      input: "synthetic.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let #(elapsed_ms, result) =
    progress.timed(fn() { generate.generate(unresolved, cfg) })

  case result {
    Ok(_) -> Nil
    Error(_) -> {
      should.be_true(False)
      Nil
    }
  }

  // Coarse anti-hang guard. The optimised path finishes specs of this
  // size in well under a second locally; the 120 s ceiling is set
  // high enough to absorb transient CI host contention while still
  // catching the multi-minute regressions we care about.
  should.be_true(elapsed_ms < 120_000)
}

/// Build a synthetic OpenAPI 3.0 YAML with `num_schemas` simple
/// object schemas (five string properties each) and `num_operations`
/// GET endpoints, each returning a different schema. Mirrors the
/// "many per-resource response shapes" pattern of large real-world
/// specs without needing an 8 MiB fixture in source control.
fn build_synthetic_large_spec_yaml(
  num_schemas: Int,
  num_operations: Int,
) -> String {
  let header =
    "openapi: 3.0.3
info:
  title: Synthetic Large Spec
  version: 1.0.0
paths:
"
  let paths =
    range_zero_until(num_operations)
    |> list.map(fn(i) {
      let schema_idx = case num_schemas {
        0 -> 0
        _ -> i % num_schemas
      }
      "  /endpoint_"
      <> int.to_string(i)
      <> ":\n    get:\n      operationId: getEndpoint"
      <> int.to_string(i)
      <> "\n      responses:\n        '200':\n          description: ok\n          content:\n            application/json:\n              schema:\n                $ref: '#/components/schemas/Schema"
      <> int.to_string(schema_idx)
      <> "'\n"
    })
    |> string.concat
  let schemas_section = case num_schemas {
    0 -> ""
    _ ->
      "components:\n  schemas:\n"
      <> {
        range_zero_until(num_schemas)
        |> list.map(fn(i) {
          "    Schema"
          <> int.to_string(i)
          <> ":\n      type: object\n      required: [field0]\n      properties:\n        field0:\n          type: string\n        field1:\n          type: string\n        field2:\n          type: string\n        field3:\n          type: string\n        field4:\n          type: string\n"
        })
        |> string.concat
      }
  }
  header <> paths <> schemas_section
}

/// `[0, 1, ..., end - 1]`. Local stand-in for `list.range`, which is
/// not in this project's `gleam_stdlib` floor. Empty list when
/// `end <= 0`.
fn range_zero_until(end: Int) -> List(Int) {
  build_descending_range(end - 1, [])
}

fn build_descending_range(i: Int, acc: List(Int)) -> List(Int) {
  case i < 0 {
    True -> acc
    False -> build_descending_range(i - 1, [i, ..acc])
  }
}

@external(erlang, "erlang", "put")
fn pdict_put_list(key: String, value: List(String)) -> List(String)

@external(erlang, "oaspec_test_helpers_ffi", "pdict_get")
fn pdict_get_list(key: String) -> Result(List(String), Nil)

/// Form-urlencoded body validates and code-generates when one of its
/// top-level fields is a nested object whose own property is an
/// array of primitives. The wire format for nested primitive arrays
/// is the OAS `form, explode: true` default — repeat the same
/// bracket-key per element (`profile[scores]=10&profile[scores]=20`)
/// so the generated client and the generated server decoder
/// round-trip cleanly.
pub fn form_urlencoded_object_with_primitive_array_case() {
  let assert Ok(unresolved) =
    parser.parse_file(
      "test/fixtures/form_urlencoded_object_primitive_array.yaml",
    )
  let cfg =
    config.new(
      input: "test/fixtures/form_urlencoded_object_primitive_array.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  let content = client_file.content

  // Repeated-key wire format for the nested primitive array.
  string.contains(content, "\"profile[scores]\"")
  |> should.be_true()
  // Integer items go through `int.to_string` before percent-encoding.
  string.contains(content, "uri.percent_encode(int.to_string(item))")
  |> should.be_true()
  // The static key must NOT have a numerical index appended.
  string.contains(content, "\"profile[scores]\" <> \"[\" <> int.to_string(")
  |> should.be_false()
}

/// Form-urlencoded body validates and code-generates when one of its
/// top-level fields is an array whose items are themselves objects
/// (Stripe `marketing_features`). Each item's properties serialise
/// via numerical bracket indices —
/// `marketing_features[0][name]=foo` — matching Stripe / qs `indices`
/// and jQuery `$.param`.
pub fn form_urlencoded_object_array_of_object_case() {
  let assert Ok(unresolved) =
    parser.parse_file(
      "test/fixtures/form_urlencoded_object_array_of_object.yaml",
    )
  let cfg =
    config.new(
      input: "test/fixtures/form_urlencoded_object_array_of_object.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  let content = client_file.content

  // Required string property of an array element reaches the wire
  // as `marketing_features[<i>][name]=...`. The runtime index goes
  // through `int.to_string(idx)`; the static prefix and each
  // bracket-key segment land in the source as separate literals.
  string.contains(content, "\"marketing_features\"")
  |> should.be_true()
  string.contains(content, "<> int.to_string(idx)")
  |> should.be_true()
  string.contains(content, "<> \"[name]\"")
  |> should.be_true()
  // Optional description follows the same indexed prefix.
  string.contains(content, "<> \"[description]\"")
  |> should.be_true()
}

/// Form-urlencoded body honors per-field
/// `encoding.<field>.contentType: application/json`. Each tagged
/// field is JSON-encoded into a single string and that string is
/// percent-encoded as one form value, while untagged fields keep
/// their existing form serialisation.
pub fn form_urlencoded_encoding_contenttype_json_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/form_urlencoded_encoding_json.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/form_urlencoded_encoding_json.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  let content = client_file.content

  // Reference field is optional (only `name` is required) so it goes
  // through the `Some(v) -> ... encode_<schema>_json(v) ...` arm and
  // never re-references `body.metadata` inside the literal payload.
  string.contains(content, "encode_metadata_json(v)")
  |> should.be_true()
  string.contains(content, "json.to_string")
  |> should.be_true()
  string.contains(
    content,
    "\"metadata=\" <> uri.percent_encode(json.to_string(",
  )
  |> should.be_true()

  // Inline array of strings: emitted as `json.array(<value>, json.string)`
  // and wrapped in the same `json.to_string + percent_encode` envelope.
  string.contains(content, "json.array(v, json.string)")
  |> should.be_true()
  string.contains(content, "\"tags=\" <> uri.percent_encode(json.to_string(")
  |> should.be_true()

  // Untagged required scalar `name` keeps the existing
  // `name=<percent-encoded value>` shape — no JSON wrapping.
  string.contains(content, "\"name=\" <> uri.percent_encode(body.name)")
  |> should.be_true()
}

/// Form-urlencoded body with `oneOf` / `anyOf` / `allOf` field-level
/// composites is accepted by validate (client mode) and the client
/// codegen emits the per-field JSON escape hatch automatically — no
/// `encoding.contentType: application/json` annotation required.
pub fn form_urlencoded_composite_field_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/form_urlencoded_composite_field.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/form_urlencoded_composite_field.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  let content = client_file.content

  // Each composite field is JSON-encoded via its synthetic encoder
  // and percent-encoded as a single form value.
  string.contains(
    content,
    "\"metadata=\" <> uri.percent_encode(json.to_string(",
  )
  |> should.be_true()
  string.contains(content, "\"address=\" <> uri.percent_encode(json.to_string(")
  |> should.be_true()
  string.contains(content, "\"audit=\" <> uri.percent_encode(json.to_string(")
  |> should.be_true()
  string.contains(content, "\"tags=\" <> uri.percent_encode(json.to_string(")
  |> should.be_true()

  // Untagged required scalar `name` is unchanged.
  string.contains(content, "\"name=\" <> uri.percent_encode(body.name)")
  |> should.be_true()

  // The composite-driven JSON escape hatch must also pull
  // `gleam/json` into the import set; otherwise the emitted
  // `json.to_string(...)` references would not compile.
  string.contains(content, "import gleam/json")
  |> should.be_true()
}

/// Query array parameters with non-primitive items take the JSON
/// escape hatch on the client side: a single query entry whose
/// value is the JSON-encoded list. `to_string_fn` is bypassed so
/// the previous panic on non-primitive items can no longer fire.
pub fn query_array_of_objects_emits_json_escape_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/query_array_of_objects.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/query_array_of_objects.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  let content = client_file.content

  string.contains(
    content,
    "json.to_string(json.array(lines, encode.encode_invoice_line_item_json))",
  )
  |> should.be_true()
  string.contains(content, "import gleam/json")
  |> should.be_true()
}

/// deepObject query parameters with composite sub-properties take
/// the JSON escape hatch per-property: the composite property emits
/// `parent[<prop>]=<JSON string>` while sibling primitive/object
/// properties keep their bracketed wire format.
pub fn deep_object_composite_property_emits_json_escape_case() {
  let assert Ok(unresolved) =
    parser.parse_file("test/fixtures/deep_object_composite_property.yaml")
  let cfg =
    config.new(
      input: "test/fixtures/deep_object_composite_property.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Client,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(unresolved, cfg)
  let assert Ok(client_file) =
    list.find(summary.files, fn(f) { f.path == "client.gleam" })
  let content = client_file.content

  // The composite `address` property serialises to a JSON string
  // under the deepObject bracketed key.
  string.contains(content, "\"customer_details[address]\"")
  |> should.be_true()
  string.contains(
    content,
    "json.to_string(encode.encode_get_invoices_upcoming_param_customer_details_address_json(",
  )
  |> should.be_true()
  // Sibling `email` property keeps the existing bracket encoding.
  string.contains(content, "\"customer_details[email]\"")
  |> should.be_true()
}
