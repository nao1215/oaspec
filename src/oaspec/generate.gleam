import gleam/list
import oaspec/codegen/client
import oaspec/codegen/context.{type Context, type GeneratedFile}
import oaspec/codegen/decoders
import oaspec/codegen/guards
import oaspec/codegen/middleware
import oaspec/codegen/server
import oaspec/codegen/types
import oaspec/codegen/validate
import oaspec/config.{type Config, Both, Client, Server}
import oaspec/openapi/dedup
import oaspec/openapi/hoist
import oaspec/openapi/spec.{type OpenApiSpec}

/// Result of a successful code generation run.
pub type GenerationSummary {
  GenerationSummary(files: List(GeneratedFile), spec_title: String)
}

/// Errors from the pure generation pipeline.
pub type GenerateError {
  ValidationErrors(errors: List(validate.ValidationError))
}

/// Pure generation pipeline: hoist → dedup → validate → generate files.
/// Takes an already-parsed spec and config; returns generated files or errors.
/// Does not perform IO — callers handle writing files and printing output.
pub fn generate(
  spec: OpenApiSpec,
  cfg: Config,
) -> Result(GenerationSummary, GenerateError) {
  let spec_title = spec.info.title <> " v" <> spec.info.version

  // Hoist inline complex schemas into components.schemas
  let spec = hoist.hoist(spec)

  // Deduplicate names to avoid collisions in generated code
  let spec = dedup.dedup(spec)

  // Create generation context
  let ctx = context.new(spec, cfg)

  // Validate spec for unsupported features
  let validation_issues = validate.validate(ctx)
  let blocking_errors = validate.errors_only(validation_issues)
  case list.is_empty(blocking_errors) {
    False -> Error(ValidationErrors(errors: blocking_errors))
    True -> {
      let files = generate_all_files(ctx)
      Ok(GenerationSummary(files:, spec_title:))
    }
  }
}

/// Pure file generation: produce all GeneratedFile values without any IO.
pub fn generate_all_files(ctx: Context) -> List(GeneratedFile) {
  let shared = generate_shared(ctx)
  let server_files = case ctx.config.mode {
    Server | Both -> server.generate(ctx)
    Client -> []
  }
  let client_files = case ctx.config.mode {
    Client | Both -> client.generate(ctx)
    Server -> []
  }
  list.flatten([shared, server_files, client_files])
}

/// Generate shared files (types, decoders, encoders, middleware, guards).
fn generate_shared(ctx: Context) -> List(GeneratedFile) {
  let type_files = types.generate(ctx)
  let decoder_files = decoders.generate(ctx)
  let middleware_files = middleware.generate(ctx)
  let guard_files = guards.generate(ctx)
  list.flatten([type_files, decoder_files, middleware_files, guard_files])
}
