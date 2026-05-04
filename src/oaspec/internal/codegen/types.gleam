//// Type-module generation entry point.
////
//// Issue #419: previously this module also re-exported a dozen
//// `schema_utils` / `schema_dispatch` / `allof_merge` helpers as
//// passthrough wrappers, which made "where does this helper live?" a
//// guessing game (`schema_ref_is_read_only` was exported from both
//// `schema_utils` and `types`, etc.). Callers now import the
//// underlying modules directly; only `generate/1` lives here.

import oaspec/internal/codegen/context.{
  type Context, type GeneratedFile, GeneratedFile,
}
import oaspec/internal/codegen/ir_build
import oaspec/internal/codegen/ir_render

/// Generate type definitions from OpenAPI schemas.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let types_content = generate_types(ctx)
  let request_types_content = generate_request_types(ctx)
  let response_types_content = generate_response_types(ctx)

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

/// Generate request types for all operations via the IR pipeline.
fn generate_request_types(ctx: Context) -> String {
  ir_build.build_request_types_module(ctx)
  |> ir_render.render()
}

/// Generate response types for all operations via the IR pipeline.
/// Each operation becomes one `UnionType` with status-code-named
/// variants.
fn generate_response_types(ctx: Context) -> String {
  ir_build.build_response_types_module(ctx)
  |> ir_render.render()
}
