import gleam/list
import gleeunit/should
import oaspec/config
import oaspec/internal/codegen/client_ir
import oaspec/internal/codegen/context
import oaspec/internal/codegen/guards
import oaspec/internal/codegen/router_ir
import oaspec/internal/openapi/dedup
import oaspec/internal/openapi/hoist
import oaspec/internal/openapi/resolve
import oaspec/openapi/parser

const guard_integration_spec =
  "
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
"

const duplicate_guard_spec =
  "
openapi: 3.0.3
info:
  title: Guard Dedup Test
  version: 1.0.0
paths:
  /uploads:
    post:
      operationId: createUpload
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/InlineUpload'
      responses:
        '200':
          description: ok
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

fn make_ctx_from_yaml(yaml: String, validate: Bool) -> context.Context {
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
      validate: validate,
    )
  context.new(resolved, cfg)
}

pub fn client_ir_tracks_guard_import_requirements_test() {
  let ctx = make_ctx_from_yaml(guard_integration_spec, True)
  let requirements = client_ir.analyze(ctx)

  requirements.needs_guards |> should.be_true()
  client_ir.imports(requirements, ctx)
  |> list.contains("api/guards")
  |> should.be_true()
}

pub fn router_ir_tracks_guard_import_requirements_test() {
  let ctx = make_ctx_from_yaml(guard_integration_spec, True)
  let requirements = router_ir.analyze(ctx)
  let imports = router_ir.imports(requirements, ctx)

  requirements.needs_guards |> should.be_true()
  requirements.needs_json_for_guards |> should.be_true()
  imports |> list.contains("gleam/json") |> should.be_true()
  imports |> list.contains("api/guards") |> should.be_true()
}

pub fn guards_build_module_dedupes_structurally_test() {
  let ctx = make_ctx_from_yaml(duplicate_guard_spec, False)
  let module = guards.build_module(ctx)
  let target_names = [
    "validate_inline_upload_title_length",
    "validate_referenced_upload_title_length",
    "validate_upload_common_title_length",
  ]
  let matching =
    list.filter(module.functions, fn(function) {
      list.contains(target_names, function.name)
    })
  let delegators =
    list.filter(matching, fn(function) {
      case function.kind {
        guards.DelegatingFieldValidator(_) -> True
        _ -> False
      }
    })
  let canonical =
    list.filter(matching, fn(function) {
      case function.kind {
        guards.FieldValidator -> True
        _ -> False
      }
    })

  list.length(matching) |> should.equal(3)
  list.length(delegators) |> should.equal(2)
  list.length(canonical) |> should.equal(1)
}
