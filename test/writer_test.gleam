import gleam/dict
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import oaspec/codegen/context
import oaspec/codegen/import_analysis
import oaspec/codegen/writer
import oaspec/config
import oaspec/openapi/schema
import oaspec/openapi/spec

pub fn main() {
  gleeunit.main()
}

// --- Writer Tests ---

fn test_config(mode: config.GenerateMode) -> config.Config {
  config.Config(
    input: "test.yaml",
    output_server: "./gen/api",
    output_client: "./gen_client/api",
    package: "api",
    mode: mode,
  )
}

fn test_files() -> List(context.GeneratedFile) {
  [
    context.GeneratedFile(
      path: "types.gleam",
      content: "// types",
      target: context.SharedTarget,
    ),
    context.GeneratedFile(
      path: "server.gleam",
      content: "// server",
      target: context.ServerTarget,
    ),
    context.GeneratedFile(
      path: "client.gleam",
      content: "// client",
      target: context.ClientTarget,
    ),
  ]
}

pub fn resolve_paths_server_mode_test() {
  let result = writer.resolve_paths(test_files(), test_config(config.Server))
  // Server mode: shared + server files under server path
  result
  |> should.equal([
    #("./gen/api/types.gleam", "// types"),
    #("./gen/api/server.gleam", "// server"),
  ])
}

pub fn resolve_paths_client_mode_test() {
  let result = writer.resolve_paths(test_files(), test_config(config.Client))
  // Client mode: shared + client files under client path
  result
  |> should.equal([
    #("./gen_client/api/types.gleam", "// types"),
    #("./gen_client/api/client.gleam", "// client"),
  ])
}

pub fn resolve_paths_both_mode_test() {
  let result = writer.resolve_paths(test_files(), test_config(config.Both))
  // Both mode: server entries first, then client entries
  result
  |> should.equal([
    #("./gen/api/types.gleam", "// types"),
    #("./gen/api/server.gleam", "// server"),
    #("./gen_client/api/types.gleam", "// types"),
    #("./gen_client/api/client.gleam", "// client"),
  ])
}

pub fn resolve_paths_empty_files_test() {
  let result = writer.resolve_paths([], test_config(config.Both))
  result |> should.equal([])
}

pub fn output_dirs_server_mode_test() {
  writer.output_dirs(test_config(config.Server))
  |> should.equal(["./gen/api"])
}

pub fn output_dirs_client_mode_test() {
  writer.output_dirs(test_config(config.Client))
  |> should.equal(["./gen_client/api"])
}

pub fn output_dirs_both_mode_test() {
  writer.output_dirs(test_config(config.Both))
  |> should.equal(["./gen/api", "./gen_client/api"])
}

pub fn error_to_string_directory_create_error_test() {
  writer.error_to_string(writer.DirectoryCreateError(
    path: "/tmp/out",
    detail: "permission denied",
  ))
  |> should.equal("Failed to create directory /tmp/out: permission denied")
}

pub fn error_to_string_file_write_error_test() {
  writer.error_to_string(writer.FileWriteError(
    path: "/tmp/out/types.gleam",
    detail: "disk full",
  ))
  |> should.equal("Failed to write file /tmp/out/types.gleam: disk full")
}

// ===================================================================
// import_analysis tests
// ===================================================================

fn make_operation(
  parameters: List(spec.RefOr(spec.Parameter(spec.Resolved))),
  request_body: option.Option(spec.RefOr(spec.RequestBody(spec.Resolved))),
) -> #(String, spec.Operation(spec.Resolved), String, spec.HttpMethod) {
  #(
    "testOp",
    spec.Operation(
      operation_id: Some("testOp"),
      summary: None,
      description: None,
      tags: [],
      parameters: parameters,
      request_body: request_body,
      responses: dict.new(),
      deprecated: False,
      security: None,
      callbacks: dict.new(),
      servers: [],
      external_docs: None,
    ),
    "/test",
    spec.Get,
  )
}

fn make_param(
  name: String,
  required: Bool,
  payload: spec.ParameterPayload,
) -> spec.Parameter(spec.Resolved) {
  spec.Parameter(
    name: name,
    in_: spec.InQuery,
    description: None,
    required: required,
    payload: payload,
    style: None,
    explode: None,
    deprecated: False,
    allow_reserved: False,
    examples: dict.new(),
  )
}

pub fn import_analysis_empty_operations_test() {
  import_analysis.operations_need_typed_schemas([])
  |> should.equal(False)
  import_analysis.operations_have_optional_params([])
  |> should.equal(False)
  import_analysis.operations_have_optional_body([])
  |> should.equal(False)
}

pub fn import_analysis_operations_need_typed_schemas_with_ref_param_test() {
  let param =
    make_param(
      "id",
      True,
      spec.ParameterSchema(schema.Reference(
        ref: "#/components/schemas/UserId",
        name: "UserId",
      )),
    )
  let op = make_operation([spec.Value(param)], None)
  import_analysis.operations_need_typed_schemas([op])
  |> should.equal(True)
}

pub fn import_analysis_operations_need_typed_schemas_with_inline_param_test() {
  let param =
    make_param(
      "name",
      True,
      spec.ParameterSchema(
        schema.Inline(schema.StringSchema(
          metadata: schema.default_metadata(),
          format: None,
          enum_values: [],
          min_length: None,
          max_length: None,
          pattern: None,
        )),
      ),
    )
  let op = make_operation([spec.Value(param)], None)
  import_analysis.operations_need_typed_schemas([op])
  |> should.equal(False)
}

pub fn import_analysis_operations_need_typed_schemas_with_ref_body_test() {
  let rb =
    spec.RequestBody(
      description: None,
      content: dict.from_list([
        #(
          "application/json",
          spec.MediaType(
            schema: Some(schema.Reference(
              ref: "#/components/schemas/User",
              name: "User",
            )),
            example: None,
            examples: dict.new(),
            encoding: dict.new(),
          ),
        ),
      ]),
      required: True,
    )
  let op = make_operation([], Some(spec.Value(rb)))
  import_analysis.operations_need_typed_schemas([op])
  |> should.equal(True)
}

pub fn import_analysis_operations_have_optional_params_test() {
  let required_param =
    make_param(
      "id",
      True,
      spec.ParameterSchema(
        schema.Inline(schema.StringSchema(
          metadata: schema.default_metadata(),
          format: None,
          enum_values: [],
          min_length: None,
          max_length: None,
          pattern: None,
        )),
      ),
    )
  let optional_param =
    make_param(
      "filter",
      False,
      spec.ParameterSchema(
        schema.Inline(schema.StringSchema(
          metadata: schema.default_metadata(),
          format: None,
          enum_values: [],
          min_length: None,
          max_length: None,
          pattern: None,
        )),
      ),
    )

  // Only required params
  let op1 = make_operation([spec.Value(required_param)], None)
  import_analysis.operations_have_optional_params([op1])
  |> should.equal(False)

  // Has optional param
  let op2 = make_operation([spec.Value(optional_param)], None)
  import_analysis.operations_have_optional_params([op2])
  |> should.equal(True)
}

pub fn import_analysis_operations_have_optional_body_test() {
  let required_body =
    spec.RequestBody(description: None, content: dict.new(), required: True)
  let optional_body =
    spec.RequestBody(description: None, content: dict.new(), required: False)

  // Required body
  let op1 = make_operation([], Some(spec.Value(required_body)))
  import_analysis.operations_have_optional_body([op1])
  |> should.equal(False)

  // Optional body
  let op2 = make_operation([], Some(spec.Value(optional_body)))
  import_analysis.operations_have_optional_body([op2])
  |> should.equal(True)

  // No body
  let op3 = make_operation([], None)
  import_analysis.operations_have_optional_body([op3])
  |> should.equal(False)
}

pub fn import_analysis_operations_need_typed_schemas_with_object_body_test() {
  let rb =
    spec.RequestBody(
      description: None,
      content: dict.from_list([
        #(
          "application/json",
          spec.MediaType(
            schema: Some(
              schema.Inline(schema.ObjectSchema(
                metadata: schema.default_metadata(),
                properties: dict.new(),
                required: [],
                additional_properties: schema.Forbidden,
                min_properties: None,
                max_properties: None,
              )),
            ),
            example: None,
            examples: dict.new(),
            encoding: dict.new(),
          ),
        ),
      ]),
      required: True,
    )
  let op = make_operation([], Some(spec.Value(rb)))
  import_analysis.operations_need_typed_schemas([op])
  |> should.equal(True)
}

pub fn import_analysis_operations_need_typed_schemas_with_allof_body_test() {
  let rb =
    spec.RequestBody(
      description: None,
      content: dict.from_list([
        #(
          "application/json",
          spec.MediaType(
            schema: Some(
              schema.Inline(
                schema.AllOfSchema(
                  metadata: schema.default_metadata(),
                  schemas: [],
                ),
              ),
            ),
            example: None,
            examples: dict.new(),
            encoding: dict.new(),
          ),
        ),
      ]),
      required: True,
    )
  let op = make_operation([], Some(spec.Value(rb)))
  import_analysis.operations_need_typed_schemas([op])
  |> should.equal(True)
}

pub fn import_analysis_ref_params_return_false_test() {
  // Ref (unresolved) parameters should return False for all checks
  let op = make_operation([spec.Ref("#/components/parameters/SomeParam")], None)
  import_analysis.operations_need_typed_schemas([op])
  |> should.equal(False)
  import_analysis.operations_have_optional_params([op])
  |> should.equal(False)
}

pub fn import_analysis_ref_body_returns_false_test() {
  // Ref (unresolved) request body should return False
  let op =
    make_operation([], Some(spec.Ref("#/components/requestBodies/SomeBody")))
  import_analysis.operations_need_typed_schemas([op])
  |> should.equal(False)
  import_analysis.operations_have_optional_body([op])
  |> should.equal(False)
}

pub fn import_analysis_multiple_operations_any_match_test() {
  let inline_param =
    make_param(
      "name",
      True,
      spec.ParameterSchema(
        schema.Inline(schema.StringSchema(
          metadata: schema.default_metadata(),
          format: None,
          enum_values: [],
          min_length: None,
          max_length: None,
          pattern: None,
        )),
      ),
    )
  let ref_param =
    make_param(
      "id",
      True,
      spec.ParameterSchema(schema.Reference(
        ref: "#/components/schemas/UserId",
        name: "UserId",
      )),
    )
  let op_no_typed = make_operation([spec.Value(inline_param)], None)
  let op_typed = make_operation([spec.Value(ref_param)], None)

  // With multiple operations, list.any returns True if any match
  import_analysis.operations_need_typed_schemas([op_no_typed, op_typed])
  |> should.equal(True)

  // All operations without typed schemas
  import_analysis.operations_need_typed_schemas([op_no_typed])
  |> should.equal(False)
}
// ===================================================================
// Test helper: flexible parameter constructor
// ===================================================================
