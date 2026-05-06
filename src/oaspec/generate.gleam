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
import oaspec/internal/openapi/filter
import oaspec/internal/openapi/hoist
import oaspec/internal/openapi/location_index.{type LocationIndex}
import oaspec/internal/openapi/normalize
import oaspec/internal/openapi/reachability
import oaspec/internal/openapi/resolve
import oaspec/internal/openapi/spec.{type OpenApiSpec, type Unresolved}
import oaspec/internal/progress.{type Reporter}
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
///
/// Each stage is wrapped with `progress.timed` so `reporter` sees a
/// "stage: X took Yms" line per phase. The GitHub REST OpenAPI is
/// large enough that without these lines callers can't tell whether
/// the process is hung or working — see issue #352.
fn prepare_context(
  spec: OpenApiSpec(Unresolved),
  cfg: Config,
  reporter: Reporter,
  index: LocationIndex,
) -> Result(PreparedContext, GenerateError) {
  let spec_title = spec.info.title <> " v" <> spec.info.version

  // Normalize OAS 3.1 patterns to 3.0-compatible form
  let #(elapsed, spec) = progress.timed(fn() { normalize.normalize(spec) })
  progress.report(
    reporter,
    "normalize OAS 3.1 → 3.0 patterns (took "
      <> progress.format_ms(elapsed)
      <> ")",
  )

  // Resolve component entry aliases ($ref within components)
  let #(elapsed, resolved) = progress.timed(fn() { resolve.resolve(spec) })
  progress.report(
    reporter,
    "resolve component $ref aliases (took "
      <> progress.format_ms(elapsed)
      <> ")",
  )
  use spec <- result.try(
    resolved
    |> result.map_error(fn(errors) { ValidationErrors(errors:) }),
  )

  // Issue #387: apply the include filter (if any) before capability
  // check / hoist / validate so every downstream stage sees only the
  // operations the user asked for. Empty filter is a no-op.
  let #(elapsed, spec) =
    progress.timed(fn() { filter.apply(spec, config.include(cfg)) })
  progress.report(
    reporter,
    "apply include filter (took " <> progress.format_ms(elapsed) <> ")",
  )

  // Check for unsupported features using capability registry
  let #(elapsed, capability_issues) =
    progress.timed(fn() {
      capability_check.check(spec, index)
      |> diagnostic.filter_by_mode(config.mode(cfg))
    })
  progress.report(
    reporter,
    "capability check (took " <> progress.format_ms(elapsed) <> ")",
  )
  let capability_errors = diagnostic.errors_only(capability_issues)
  let capability_warnings = diagnostic.warnings_only(capability_issues)
  use _ <- result.try(case list.is_empty(capability_errors) {
    False -> Error(ValidationErrors(errors: capability_errors))
    True -> Ok(Nil)
  })

  // Hoist inline complex schemas into components.schemas
  let #(elapsed, spec) = progress.timed(fn() { hoist.hoist(spec) })
  progress.report(
    reporter,
    "hoist inline complex schemas (took " <> progress.format_ms(elapsed) <> ")",
  )

  // Issue #501: when an include filter is active, drop component
  // schemas no surviving operation transitively references. Runs
  // after hoist (so synthetic schemas hoisting introduces are still
  // considered) and before dedup (so dedup operates on the smaller
  // surviving set). Skipped when no filter is configured: the user
  // didn't ask to subset the API, so we present the spec as-authored
  // — dead component schemas left in the spec stay in the output.
  let include_active = !config.include_is_empty(config.include(cfg))
  let #(elapsed, spec) =
    progress.timed(fn() {
      case include_active {
        True -> reachability.prune(spec)
        False -> spec
      }
    })
  progress.report(
    reporter,
    "prune unreachable component schemas (took "
      <> progress.format_ms(elapsed)
      <> ")",
  )

  // Deduplicate names to avoid collisions in generated code
  let #(elapsed, spec) = progress.timed(fn() { dedup.dedup(spec) })
  progress.report(
    reporter,
    "deduplicate generated names (took " <> progress.format_ms(elapsed) <> ")",
  )

  // Create generation context
  let ctx = context.new(spec, cfg)

  // Check for parsed-but-unused features (capability warnings)
  let #(elapsed, preserved_warnings) =
    progress.timed(fn() {
      capability_check.check_preserved(ctx, index)
      |> diagnostic.filter_by_mode(config.mode(cfg))
    })
  progress.report(
    reporter,
    "preserved-feature warnings (took " <> progress.format_ms(elapsed) <> ")",
  )

  // Validate spec for unsupported features
  let #(elapsed, validation_issues) =
    progress.timed(fn() {
      validate.validate(ctx)
      |> diagnostic.filter_by_mode(config.mode(cfg))
    })
  progress.report(
    reporter,
    "validate spec for unsupported features (took "
      <> progress.format_ms(elapsed)
      <> ")",
  )
  let blocking_errors = diagnostic.errors_only(validation_issues)
  let validation_warnings = diagnostic.warnings_only(validation_issues)
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
///
/// Capability-check diagnostics from this entry point carry no source
/// location information. Callers that already have a YAML
/// `LocationIndex` (e.g. via `parser.parse_file_with_locations`)
/// should prefer `generate_with_locations` so capability-check errors
/// surface line/column for the offending spec node (Issue #411).
pub fn generate(
  spec: OpenApiSpec(Unresolved),
  cfg: Config,
) -> Result(GenerationSummary, GenerateError) {
  generate_with_progress_and_locations(
    spec,
    location_index.empty(),
    cfg,
    progress.noop(),
  )
}

/// Combined entry point that accepts both a `LocationIndex` and a
/// `Reporter`. Issue #411 + #352. The CLI uses this so it can show
/// per-stage progress AND surface `path:line:column:` in capability
/// errors at the same time. Library callers that need only one of the
/// two can pass `location_index.empty()` or `progress.noop()`.
pub fn generate_with_progress_and_locations(
  spec: OpenApiSpec(Unresolved),
  index: LocationIndex,
  cfg: Config,
  reporter: Reporter,
) -> Result(GenerationSummary, GenerateError) {
  use prepared <- result.try(prepare_context(spec, cfg, reporter, index))
  let files = generate_all_files_with_progress(prepared.ctx, reporter)
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
  validate_only_with_progress_and_locations(
    spec,
    location_index.empty(),
    cfg,
    progress.noop(),
  )
}

/// Combined `validate_only` entry point that accepts both a
/// `LocationIndex` and a `Reporter`. Issue #411 + #352.
pub fn validate_only_with_progress_and_locations(
  spec: OpenApiSpec(Unresolved),
  index: LocationIndex,
  cfg: Config,
  reporter: Reporter,
) -> Result(ValidationSummary, GenerateError) {
  use prepared <- result.try(prepare_context(spec, cfg, reporter, index))
  Ok(ValidationSummary(
    spec_title: prepared.spec_title,
    warnings: prepared.warnings,
  ))
}

/// Pure file generation: produce all GeneratedFile values without any IO.
///
/// The `Reporter` plumbing lives in `generate_all_files_with_progress`;
/// callers that want progress events (the CLI) go through the
/// progress-aware wrapper. Library callers that need the values
/// without progress noise pay nothing — `progress.noop()` is cheap.
pub fn generate_all_files(ctx: Context) -> List(GeneratedFile) {
  generate_all_files_with_progress(ctx, progress.noop())
}

/// Pure file generation with per-substage progress events.
///
/// Issue #537: a single `render generated source files (took ...)`
/// event covered types/decoders/encoders/guards/server/client all at
/// once. On large specs the slow phase stayed invisible behind that
/// outer line. Each substage now emits its own `<phase> (took ...)`
/// line via `progress.timed_stage`, so a hang surfaces against a
/// specific phase rather than the opaque outer wrapper.
///
/// `middleware.gleam` used to be emitted here too, but its `Handler`
/// shape did not actually compose with the generated client or server
/// APIs (see issue #116). The internal `middleware` module is kept
/// only as a library-level helper for consumers who want to assemble
/// their own middleware chain.
fn generate_all_files_with_progress(
  ctx: Context,
  reporter: Reporter,
) -> List(GeneratedFile) {
  let type_files =
    progress.timed_stage(
      reporter: reporter,
      label: "generate types",
      body: fn() { types.generate(ctx) },
    )
  let decoder_files =
    progress.timed_stage(
      reporter: reporter,
      label: "generate decoders",
      body: fn() { decoders.generate(ctx) },
    )
  let encoder_files =
    progress.timed_stage(
      reporter: reporter,
      label: "generate encoders",
      body: fn() { encoders.generate(ctx) },
    )
  let guard_files =
    progress.timed_stage(
      reporter: reporter,
      label: "generate guards",
      body: fn() { guards.generate(ctx) },
    )
  let server_files = case config.mode(context.config(ctx)) {
    Server | Both ->
      progress.timed_stage(
        reporter: reporter,
        label: "generate server",
        body: fn() { server.generate(ctx) },
      )
    Client -> []
  }
  let client_files = case config.mode(context.config(ctx)) {
    Client | Both ->
      progress.timed_stage(
        reporter: reporter,
        label: "generate client",
        body: fn() { client.generate(ctx) },
      )
    Server -> []
  }
  list.flatten([
    type_files,
    decoder_files,
    encoder_files,
    guard_files,
    server_files,
    client_files,
  ])
}
