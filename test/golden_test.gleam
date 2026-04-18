import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import oaspec/codegen/context
import oaspec/config
import oaspec/formatter
import oaspec/generate
import oaspec/openapi/parser
import oaspec/openapi/resolve
import oaspec/openapi/spec
import oaspec/util/http
import simplifile

pub fn main() {
  gleeunit.main()
}

// --- Golden file (snapshot) tests ---
// These tests verify that generated code output matches committed golden files
// byte-for-byte. If a codegen change intentionally alters output, update golden
// files with: just update-golden

/// Helper: generate code from a spec file and return the files list.
fn golden_generate(spec_path: String) -> List(context.GeneratedFile) {
  let assert Ok(spec) = parser.parse_file(spec_path)
  let cfg =
    config.Config(
      input: spec_path,
      output_server: "./golden_unused/api",
      output_client: "./golden_unused/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  let assert Ok(summary) = generate.generate(spec, cfg)
  summary.files
}

/// Helper: compare a generated file's content against the golden file on disk.
/// Panics with a diff-friendly message on mismatch.
fn assert_matches_golden(file: context.GeneratedFile, golden_dir: String) -> Nil {
  let golden_path = golden_dir <> "/" <> file.path
  let assert Ok(expected) = simplifile.read(golden_path)
  case file.content == expected {
    True -> Nil
    False -> {
      // Find first differing line for a useful error message
      let gen_lines = string.split(file.content, "\n")
      let exp_lines = string.split(expected, "\n")
      let diff_info = find_first_diff(gen_lines, exp_lines, 1)
      panic as {
        "Golden file mismatch: "
        <> file.path
        <> "\n"
        <> diff_info
        <> "\nRun `just update-golden` to update snapshots."
      }
    }
  }
}

fn find_first_diff(
  gen: List(String),
  exp: List(String),
  line_num: Int,
) -> String {
  case gen, exp {
    [], [] -> "Files differ in length"
    [], [e, ..] ->
      "Line "
      <> string.inspect(line_num)
      <> ": generated file ends, expected: "
      <> e
    [g, ..], [] ->
      "Line "
      <> string.inspect(line_num)
      <> ": golden file ends, generated has: "
      <> g
    [g, ..g_rest], [e, ..e_rest] ->
      case g == e {
        True -> find_first_diff(g_rest, e_rest, line_num + 1)
        False ->
          "Line "
          <> string.inspect(line_num)
          <> ":\n  expected: "
          <> e
          <> "\n  got:      "
          <> g
      }
  }
}

/// Helper: run golden comparison for all files from a spec.
/// Formats generated content via temp files before comparison to match
/// the formatted golden files on disk.
fn assert_all_golden(spec_path: String, golden_dir: String) -> Nil {
  let files = golden_generate(spec_path)
  let formatted_files = format_generated_files(files)
  list.each(formatted_files, fn(file) {
    assert_matches_golden(file, golden_dir)
  })
}

/// Format generated files by writing to temp, running gleam format, and reading back.
fn format_generated_files(
  files: List(context.GeneratedFile),
) -> List(context.GeneratedFile) {
  let temp_dir = "/tmp/oaspec_golden_test"
  let _ = simplifile.delete(temp_dir)
  let assert Ok(Nil) = simplifile.create_directory_all(temp_dir)

  // Write each file to temp with indexed names
  let entries =
    list.index_map(files, fn(file, idx) {
      let temp_path = temp_dir <> "/" <> string.inspect(idx) <> ".gleam"
      let assert Ok(Nil) = simplifile.write(temp_path, file.content)
      #(file, temp_path)
    })

  // Format all temp files
  let temp_paths = list.map(entries, fn(e) { e.1 })
  let assert Ok(Nil) = formatter.format_files(temp_paths)

  // Read back formatted content
  let formatted =
    list.map(entries, fn(entry) {
      let #(file, temp_path) = entry
      let assert Ok(content) = simplifile.read(temp_path)
      context.GeneratedFile(..file, content: content)
    })

  // Clean up
  let _ = simplifile.delete(temp_dir)
  formatted
}

pub fn golden_petstore_test() {
  assert_all_golden("test/fixtures/petstore.yaml", "golden/petstore/api")
}

pub fn golden_complex_supported_test() {
  assert_all_golden(
    "test/fixtures/complex_supported_openapi.yaml",
    "golden/complex_supported/api",
  )
}

/// Verify golden files exist for petstore (all 9 expected files).
pub fn golden_petstore_file_count_test() {
  let files = golden_generate("test/fixtures/petstore.yaml")
  // Shared(6, no middleware after #116) + Server(2) + Client(1) = 9 files
  list.length(files) |> should.equal(9)
}

/// Verify golden files exist for complex_supported spec.
pub fn golden_complex_supported_file_count_test() {
  let files = golden_generate("test/fixtures/complex_supported_openapi.yaml")
  // Shared(5, no guards, no middleware after #116) + Server(2) + Client(1) = 8 files
  list.length(files) |> should.equal(8)
}

/// Verify idempotency: generating twice produces identical output.
pub fn golden_idempotency_test() {
  let files1 = golden_generate("test/fixtures/petstore.yaml")
  let files2 = golden_generate("test/fixtures/petstore.yaml")
  list.length(files1) |> should.equal(list.length(files2))
  list.map2(files1, files2, fn(f1, f2) {
    f1.path |> should.equal(f2.path)
    f1.content |> should.equal(f2.content)
  })
  Nil
}

// ===========================================================================
// Resolve error path tests (issue #60)
// ===========================================================================

/// Circular component alias chain (A → B → A) should produce a resolve error.
pub fn resolve_circular_component_alias_error_test() {
  let components =
    spec.Components(
      schemas: dict.new(),
      parameters: dict.from_list([
        #("A", spec.Ref("#/components/parameters/B")),
        #("B", spec.Ref("#/components/parameters/A")),
      ]),
      request_bodies: dict.new(),
      responses: dict.new(),
      security_schemes: dict.new(),
      path_items: dict.new(),
      headers: dict.new(),
      examples: dict.new(),
      links: dict.new(),
    )
  let test_spec =
    spec.OpenApiSpec(
      openapi: "3.0.3",
      info: spec.Info(
        title: "Test",
        description: None,
        version: "1.0.0",
        summary: None,
        terms_of_service: None,
        contact: None,
        license: None,
      ),
      paths: dict.new(),
      components: Some(components),
      servers: [],
      security: [],
      webhooks: dict.new(),
      tags: [],
      external_docs: None,
      json_schema_dialect: None,
    )
  let result = resolve.resolve(test_spec)
  case result {
    Error(errors) -> {
      list.length(errors) |> should.not_equal(0)
      let has_circular =
        list.any(errors, fn(e) {
          string.contains(e.message, "Circular component alias")
        })
      should.be_true(has_circular)
    }
    Ok(_) -> should.fail()
  }
}

/// Unresolved $ref target in components should produce a resolve error.
pub fn resolve_unresolved_ref_target_error_test() {
  let components =
    spec.Components(
      schemas: dict.new(),
      parameters: dict.from_list([
        #("Missing", spec.Ref("#/components/parameters/DoesNotExist")),
      ]),
      request_bodies: dict.new(),
      responses: dict.new(),
      security_schemes: dict.new(),
      path_items: dict.new(),
      headers: dict.new(),
      examples: dict.new(),
      links: dict.new(),
    )
  let test_spec =
    spec.OpenApiSpec(
      openapi: "3.0.3",
      info: spec.Info(
        title: "Test",
        description: None,
        version: "1.0.0",
        summary: None,
        terms_of_service: None,
        contact: None,
        license: None,
      ),
      paths: dict.new(),
      components: Some(components),
      servers: [],
      security: [],
      webhooks: dict.new(),
      tags: [],
      external_docs: None,
      json_schema_dialect: None,
    )
  let result = resolve.resolve(test_spec)
  case result {
    Error(errors) -> {
      list.length(errors) |> should.not_equal(0)
      let has_unresolved =
        list.any(errors, fn(e) {
          string.contains(e.message, "Unresolved component alias")
          && string.contains(e.message, "DoesNotExist")
        })
      should.be_true(has_unresolved)
    }
    Ok(_) -> should.fail()
  }
}

/// Wrong-kind $ref (e.g., schema ref in parameter position) should produce a
/// resolve error when resolving inline refs in operations.
pub fn resolve_wrong_kind_ref_in_parameter_position_error_test() {
  let components =
    spec.Components(
      schemas: dict.new(),
      parameters: dict.new(),
      request_bodies: dict.new(),
      responses: dict.new(),
      security_schemes: dict.new(),
      path_items: dict.new(),
      headers: dict.new(),
      examples: dict.new(),
      links: dict.new(),
    )
  let operation =
    spec.Operation(
      operation_id: Some("getUser"),
      summary: None,
      description: None,
      tags: [],
      parameters: [spec.Ref("#/components/schemas/SomeSchema")],
      request_body: None,
      responses: dict.new(),
      deprecated: False,
      security: None,
      callbacks: dict.new(),
      servers: [],
      external_docs: None,
    )
  let path_item =
    spec.PathItem(
      summary: None,
      description: None,
      get: Some(operation),
      post: None,
      put: None,
      delete: None,
      patch: None,
      head: None,
      options: None,
      trace: None,
      parameters: [],
      servers: [],
    )
  let test_spec =
    spec.OpenApiSpec(
      openapi: "3.0.3",
      info: spec.Info(
        title: "Test",
        description: None,
        version: "1.0.0",
        summary: None,
        terms_of_service: None,
        contact: None,
        license: None,
      ),
      paths: dict.from_list([#("/users", spec.Value(path_item))]),
      components: Some(components),
      servers: [],
      security: [],
      webhooks: dict.new(),
      tags: [],
      external_docs: None,
      json_schema_dialect: None,
    )
  let result = resolve.resolve(test_spec)
  case result {
    Error(errors) -> {
      list.length(errors) |> should.not_equal(0)
      let has_wrong_kind =
        list.any(errors, fn(e) {
          string.contains(e.message, "wrong component kind")
        })
      should.be_true(has_wrong_kind)
    }
    Ok(_) -> should.fail()
  }
}

/// Wrong-kind $ref for request body (e.g., response ref in requestBody position)
/// should produce a resolve error.
pub fn resolve_wrong_kind_ref_in_request_body_position_error_test() {
  let components =
    spec.Components(
      schemas: dict.new(),
      parameters: dict.new(),
      request_bodies: dict.new(),
      responses: dict.new(),
      security_schemes: dict.new(),
      path_items: dict.new(),
      headers: dict.new(),
      examples: dict.new(),
      links: dict.new(),
    )
  let operation =
    spec.Operation(
      operation_id: Some("createUser"),
      summary: None,
      description: None,
      tags: [],
      parameters: [],
      request_body: Some(spec.Ref("#/components/responses/SomeResponse")),
      responses: dict.new(),
      deprecated: False,
      security: None,
      callbacks: dict.new(),
      servers: [],
      external_docs: None,
    )
  let path_item =
    spec.PathItem(
      summary: None,
      description: None,
      get: None,
      post: Some(operation),
      put: None,
      delete: None,
      patch: None,
      head: None,
      options: None,
      trace: None,
      parameters: [],
      servers: [],
    )
  let test_spec =
    spec.OpenApiSpec(
      openapi: "3.0.3",
      info: spec.Info(
        title: "Test",
        description: None,
        version: "1.0.0",
        summary: None,
        terms_of_service: None,
        contact: None,
        license: None,
      ),
      paths: dict.from_list([#("/users", spec.Value(path_item))]),
      components: Some(components),
      servers: [],
      security: [],
      webhooks: dict.new(),
      tags: [],
      external_docs: None,
      json_schema_dialect: None,
    )
  let result = resolve.resolve(test_spec)
  case result {
    Error(errors) -> {
      list.length(errors) |> should.not_equal(0)
      let has_wrong_kind =
        list.any(errors, fn(e) {
          string.contains(e.message, "wrong component kind")
        })
      should.be_true(has_wrong_kind)
    }
    Ok(_) -> should.fail()
  }
}

/// Unresolved $ref in inline path operation response should produce an error.
pub fn resolve_unresolved_inline_response_ref_error_test() {
  let components =
    spec.Components(
      schemas: dict.new(),
      parameters: dict.new(),
      request_bodies: dict.new(),
      responses: dict.new(),
      security_schemes: dict.new(),
      path_items: dict.new(),
      headers: dict.new(),
      examples: dict.new(),
      links: dict.new(),
    )
  let operation =
    spec.Operation(
      operation_id: Some("getUser"),
      summary: None,
      description: None,
      tags: [],
      parameters: [],
      request_body: None,
      responses: dict.from_list([
        #(
          http.Status(200),
          spec.Ref("#/components/responses/NonExistentResponse"),
        ),
      ]),
      deprecated: False,
      security: None,
      callbacks: dict.new(),
      servers: [],
      external_docs: None,
    )
  let path_item =
    spec.PathItem(
      summary: None,
      description: None,
      get: Some(operation),
      post: None,
      put: None,
      delete: None,
      patch: None,
      head: None,
      options: None,
      trace: None,
      parameters: [],
      servers: [],
    )
  let test_spec =
    spec.OpenApiSpec(
      openapi: "3.0.3",
      info: spec.Info(
        title: "Test",
        description: None,
        version: "1.0.0",
        summary: None,
        terms_of_service: None,
        contact: None,
        license: None,
      ),
      paths: dict.from_list([#("/users", spec.Value(path_item))]),
      components: Some(components),
      servers: [],
      security: [],
      webhooks: dict.new(),
      tags: [],
      external_docs: None,
      json_schema_dialect: None,
    )
  let result = resolve.resolve(test_spec)
  case result {
    Error(errors) -> {
      list.length(errors) |> should.not_equal(0)
      let has_unresolved =
        list.any(errors, fn(e) {
          string.contains(e.message, "Unresolved $ref")
          && string.contains(e.message, "NonExistentResponse")
        })
      should.be_true(has_unresolved)
    }
    Ok(_) -> should.fail()
  }
}

/// Unresolved path-level $ref pointing to missing pathItem should produce error.
pub fn resolve_unresolved_path_item_ref_error_test() {
  let components =
    spec.Components(
      schemas: dict.new(),
      parameters: dict.new(),
      request_bodies: dict.new(),
      responses: dict.new(),
      security_schemes: dict.new(),
      path_items: dict.new(),
      headers: dict.new(),
      examples: dict.new(),
      links: dict.new(),
    )
  let test_spec =
    spec.OpenApiSpec(
      openapi: "3.0.3",
      info: spec.Info(
        title: "Test",
        description: None,
        version: "1.0.0",
        summary: None,
        terms_of_service: None,
        contact: None,
        license: None,
      ),
      paths: dict.from_list([
        #("/users", spec.Ref("#/components/pathItems/MissingPathItem")),
      ]),
      components: Some(components),
      servers: [],
      security: [],
      webhooks: dict.new(),
      tags: [],
      external_docs: None,
      json_schema_dialect: None,
    )
  let result = resolve.resolve(test_spec)
  case result {
    Error(errors) -> {
      list.length(errors) |> should.not_equal(0)
      let has_unresolved =
        list.any(errors, fn(e) { string.contains(e.message, "Unresolved $ref") })
      should.be_true(has_unresolved)
    }
    Ok(_) -> should.fail()
  }
}

/// Wrong-kind $ref at path level (e.g., schemas ref instead of pathItems)
/// should produce a resolve error.
pub fn resolve_wrong_kind_path_item_ref_error_test() {
  let components =
    spec.Components(
      schemas: dict.new(),
      parameters: dict.new(),
      request_bodies: dict.new(),
      responses: dict.new(),
      security_schemes: dict.new(),
      path_items: dict.new(),
      headers: dict.new(),
      examples: dict.new(),
      links: dict.new(),
    )
  let test_spec =
    spec.OpenApiSpec(
      openapi: "3.0.3",
      info: spec.Info(
        title: "Test",
        description: None,
        version: "1.0.0",
        summary: None,
        terms_of_service: None,
        contact: None,
        license: None,
      ),
      paths: dict.from_list([
        #("/users", spec.Ref("#/components/schemas/SomeSchema")),
      ]),
      components: Some(components),
      servers: [],
      security: [],
      webhooks: dict.new(),
      tags: [],
      external_docs: None,
      json_schema_dialect: None,
    )
  let result = resolve.resolve(test_spec)
  case result {
    Error(errors) -> {
      list.length(errors) |> should.not_equal(0)
      let has_wrong_kind =
        list.any(errors, fn(e) {
          string.contains(e.message, "wrong component kind")
        })
      should.be_true(has_wrong_kind)
    }
    Ok(_) -> should.fail()
  }
}

/// Three-way circular alias chain (A → B → C → A) should produce a resolve error.
pub fn resolve_three_way_circular_alias_error_test() {
  let components =
    spec.Components(
      schemas: dict.new(),
      parameters: dict.new(),
      request_bodies: dict.new(),
      responses: dict.from_list([
        #("A", spec.Ref("#/components/responses/B")),
        #("B", spec.Ref("#/components/responses/C")),
        #("C", spec.Ref("#/components/responses/A")),
      ]),
      security_schemes: dict.new(),
      path_items: dict.new(),
      headers: dict.new(),
      examples: dict.new(),
      links: dict.new(),
    )
  let test_spec =
    spec.OpenApiSpec(
      openapi: "3.0.3",
      info: spec.Info(
        title: "Test",
        description: None,
        version: "1.0.0",
        summary: None,
        terms_of_service: None,
        contact: None,
        license: None,
      ),
      paths: dict.new(),
      components: Some(components),
      servers: [],
      security: [],
      webhooks: dict.new(),
      tags: [],
      external_docs: None,
      json_schema_dialect: None,
    )
  let result = resolve.resolve(test_spec)
  case result {
    Error(errors) -> {
      list.length(errors) |> should.not_equal(0)
      let has_circular =
        list.any(errors, fn(e) {
          string.contains(e.message, "Circular component alias")
        })
      should.be_true(has_circular)
    }
    Ok(_) -> should.fail()
  }
}
