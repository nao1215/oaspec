import gleam/list
import gleam/result
import oaspec/config.{type Config, Both, Client, Server}
import oaspec/internal/codegen/client
import oaspec/internal/codegen/context.{type Context, type GeneratedFile}
import oaspec/internal/codegen/decoders
import oaspec/internal/codegen/encoders
import oaspec/internal/codegen/guards
import oaspec/internal/codegen/server
import oaspec/internal/codegen/types
import oaspec/internal/codegen/validate
import oaspec/internal/openapi/capability_check
import oaspec/internal/openapi/dedup
import oaspec/internal/openapi/hoist
import oaspec/internal/openapi/normalize
import oaspec/internal/openapi/resolve
import oaspec/internal/openapi/spec.{type OpenApiSpec, type Unresolved}
import oaspec/openapi/diagnostic.{type Diagnostic}

/// Result of a successful code generation run.
pub type GenerationSummary {
  GenerationSummary(
    files: List(GeneratedFile),
    spec_title: String,
    warnings: List(Diagnostic),
  )
}

/// Result of a successful validation-only run.
pub type ValidationSummary {
  ValidationSummary(spec_title: String, warnings: List(Diagnostic))
}

/// Errors from the pure generation pipeline.
pub type GenerateError {
  ValidationErrors(errors: List(Diagnostic))
}

/// Intermediate result from the shared pipeline.
/// Contains the validated context and accumulated warnings.
type PreparedContext {
  PreparedContext(ctx: Context, spec_title: String, warnings: List(Diagnostic))
}

/// Shared pipeline: normalize → resolve → capability_check → hoist → dedup → validate.
/// Returns a validated context with accumulated warnings, or errors.
fn prepare_context(
  spec: OpenApiSpec(Unresolved),
  cfg: Config,
) -> Result(PreparedContext, GenerateError) {
  let spec_title = spec.info.title <> " v" <> spec.info.version

  // Normalize OAS 3.1 patterns to 3.0-compatible form
  let spec = normalize.normalize(spec)

  // Resolve component entry aliases ($ref within components)
  use spec <- result.try(
    resolve.resolve(spec)
    |> result.map_error(fn(errors) { ValidationErrors(errors:) }),
  )

  // Check for unsupported features using capability registry
  let capability_issues =
    capability_check.check(spec)
    |> validate.filter_by_mode(config.mode(cfg))
  let capability_errors = validate.errors_only(capability_issues)
  let capability_warnings = validate.warnings_only(capability_issues)
  use _ <- result.try(case list.is_empty(capability_errors) {
    False -> Error(ValidationErrors(errors: capability_errors))
    True -> Ok(Nil)
  })

  // Hoist inline complex schemas into components.schemas
  let spec = hoist.hoist(spec)

  // Deduplicate names to avoid collisions in generated code
  let spec = dedup.dedup(spec)

  // Create generation context
  let ctx = context.new(spec, cfg)

  // Check for parsed-but-unused features (capability warnings)
  let preserved_warnings =
    capability_check.check_preserved(ctx)
    |> diagnostic.filter_by_mode(config.mode(cfg))

  // Validate spec for unsupported features
  let validation_issues =
    validate.validate(ctx)
    |> validate.filter_by_mode(config.mode(cfg))
  let blocking_errors = validate.errors_only(validation_issues)
  let validation_warnings = validate.warnings_only(validation_issues)
  use _ <- result.try(case list.is_empty(blocking_errors) {
    False -> Error(ValidationErrors(errors: blocking_errors))
    True -> Ok(Nil)
  })

  let warnings =
    list.flatten([capability_warnings, preserved_warnings, validation_warnings])
  Ok(PreparedContext(ctx:, spec_title:, warnings:))
}

/// Pure generation pipeline: parse → normalize → resolve → capability_check → hoist → dedup → validate → codegen.
/// Takes an already-parsed spec and config; returns generated files or errors.
/// Does not perform IO — callers handle writing files and printing output.
pub fn generate(
  spec: OpenApiSpec(Unresolved),
  cfg: Config,
) -> Result(GenerationSummary, GenerateError) {
  use prepared <- result.try(prepare_context(spec, cfg))
  let files = generate_all_files(prepared.ctx)
  Ok(GenerationSummary(
    files:,
    spec_title: prepared.spec_title,
    warnings: prepared.warnings,
  ))
}

/// Validation-only pipeline: parse → normalize → resolve → capability_check → hoist → dedup → validate.
/// Runs the same checks as generate() but skips code generation and file writing.
pub fn validate_only(
  spec: OpenApiSpec(Unresolved),
  cfg: Config,
) -> Result(ValidationSummary, GenerateError) {
  use prepared <- result.try(prepare_context(spec, cfg))
  Ok(ValidationSummary(
    spec_title: prepared.spec_title,
    warnings: prepared.warnings,
  ))
}

/// Pure file generation: produce all GeneratedFile values without any IO.
pub fn generate_all_files(ctx: Context) -> List(GeneratedFile) {
  let shared = generate_shared(ctx)
  let server_files = case config.mode(context.config(ctx)) {
    Server | Both -> server.generate(ctx)
    Client -> []
  }
  let client_files = case config.mode(context.config(ctx)) {
    Client | Both -> client.generate(ctx)
    Server -> []
  }
  list.flatten([shared, server_files, client_files])
}

/// Generate shared files (types, decoders, encoders, guards).
///
/// `middleware.gleam` used to be emitted here too, but its `Handler` shape
/// did not actually compose with the generated client or server APIs (see
/// issue #116). It is no longer part of the default generated surface;
/// the `oaspec/internal/codegen/middleware` module is kept only as a library-level
/// helper for consumers who want to assemble their own middleware chain.
fn generate_shared(ctx: Context) -> List(GeneratedFile) {
  let type_files = types.generate(ctx)
  let decoder_files = decoders.generate(ctx)
  let encoder_files = encoders.generate(ctx)
  let guard_files = guards.generate(ctx)
  list.flatten([type_files, decoder_files, encoder_files, guard_files])
}
