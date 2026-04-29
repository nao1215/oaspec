import oaspec/internal/codegen/allof_merge
import oaspec/internal/codegen/context.{
  type Context, type GeneratedFile, GeneratedFile,
}
import oaspec/internal/codegen/ir_build
import oaspec/internal/codegen/ir_render
import oaspec/internal/codegen/schema_dispatch
import oaspec/internal/codegen/schema_utils
import oaspec/internal/openapi/operations
import oaspec/internal/openapi/schema.{type SchemaObject, type SchemaRef}
import oaspec/internal/openapi/spec.{type Resolved}

/// Generate type definitions from OpenAPI schemas.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let operations = operations.collect_operations(ctx)
  let types_content = generate_types(ctx)
  let request_types_content = generate_request_types(ctx, operations)
  let response_types_content = generate_response_types(ctx, operations)

  [
    GeneratedFile(
      path: "types.gleam",
      content: types_content,
      target: context.SharedTarget,
      write_mode: context.Overwrite,
    ),
    GeneratedFile(
      path: "request_types.gleam",
      content: request_types_content,
      target: context.SharedTarget,
      write_mode: context.Overwrite,
    ),
    GeneratedFile(
      path: "response_types.gleam",
      content: response_types_content,
      target: context.SharedTarget,
      write_mode: context.Overwrite,
    ),
  ]
}

/// Generate types from component schemas and anonymous types from operations.
/// Delegates to the IR pipeline: build IR declarations, then render to source.
fn generate_types(ctx: Context) -> String {
  ir_build.build_types_module(ctx)
  |> ir_render.render()
}

/// Convert a schema object to a Gleam type string.
/// Delegates to schema_dispatch for the centralized type mapping.
pub fn schema_to_gleam_type(schema: SchemaObject, _ctx: Context) -> String {
  schema_dispatch.schema_type(schema)
}

/// Generate request types for all operations via the IR pipeline.
/// Shape of each RecordType matches the former string-builder output;
/// `gleam format` normalizes whitespace either way so the final on-disk
/// content is unchanged.
fn generate_request_types(
  ctx: Context,
  _operations: List(
    #(String, spec.Operation(Resolved), String, spec.HttpMethod),
  ),
) -> String {
  ir_build.build_request_types_module(ctx)
  |> ir_render.render()
}

/// Generate response types for all operations via the IR pipeline.
/// Each operation becomes one `UnionType` with status-code-named
/// variants. Payload rules (empty / String / qualified schema type) are
/// preserved from the former string-builder output.
fn generate_response_types(
  ctx: Context,
  _operations: List(
    #(String, spec.Operation(Resolved), String, spec.HttpMethod),
  ),
) -> String {
  ir_build.build_response_types_module(ctx)
  |> ir_render.render()
}

/// Result of merging allOf sub-schemas.
/// Re-export from allof_merge for backward compatibility.
pub type MergedAllOf =
  allof_merge.MergedAllOf

/// Re-export merge_allof_schemas.
pub fn merge_allof_schemas(
  schemas: List(SchemaRef),
  ctx: Context,
) -> MergedAllOf {
  allof_merge.merge_allof_schemas(schemas, ctx)
}

/// Check if a schema has typed or untyped additionalProperties that would need Dict.
pub fn schema_has_additional_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  schema_utils.schema_has_additional_properties(schema_ref, ctx)
}

/// Check if a schema has `additionalProperties: false` (needs Dict for the
/// closed-schema unknown-key check at decode time).
pub fn schema_has_forbidden_additional_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  schema_utils.schema_has_forbidden_additional_properties(schema_ref, ctx)
}

/// Check if a schema has any optional or nullable fields that would need Option.
pub fn schema_has_optional_fields(schema_ref: SchemaRef, ctx: Context) -> Bool {
  schema_utils.schema_has_optional_fields(schema_ref, ctx)
}

/// Check if a SchemaRef has readOnly metadata, resolving $ref if needed.
pub fn schema_ref_is_read_only(ref: SchemaRef, ctx: Context) -> Bool {
  schema_utils.schema_ref_is_read_only(ref, ctx)
}

/// Check if a SchemaRef has writeOnly metadata, resolving $ref if needed.
pub fn schema_ref_is_write_only(ref: SchemaRef, ctx: Context) -> Bool {
  schema_utils.schema_ref_is_write_only(ref, ctx)
}

/// Filter readOnly properties from an ObjectSchema for request body context.
/// Returns a new schema with readOnly properties removed.
pub fn filter_read_only_properties(
  schema_obj: SchemaObject,
  ctx: Context,
) -> SchemaObject {
  schema_utils.filter_read_only_properties(schema_obj, ctx)
}

/// Filter writeOnly properties from an ObjectSchema for response body context.
/// Returns a new schema with writeOnly properties removed.
pub fn filter_write_only_properties(
  schema_obj: SchemaObject,
  ctx: Context,
) -> SchemaObject {
  schema_utils.filter_write_only_properties(schema_obj, ctx)
}
