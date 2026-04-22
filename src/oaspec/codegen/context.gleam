import oaspec/config.{type Config}
import oaspec/openapi/spec.{type OpenApiSpec, type Resolved}

/// The version of oaspec used for generated code headers.
pub const version = "0.16.0"

/// Context for code generation, carrying all needed state.
/// Only accepts a resolved spec — codegen must not operate on unresolved ASTs.
///
/// Opaque: external callers construct via `new/2` and read fields via
/// the accessors `spec/1` / `config/1`. This keeps the internal shape
/// free to evolve (e.g. add derived caches) without rippling into every
/// pattern match across the codebase.
pub opaque type Context {
  Context(spec: OpenApiSpec(Resolved), config: Config)
}

/// Create a new generation context from a resolved spec.
pub fn new(spec: OpenApiSpec(Resolved), config: Config) -> Context {
  Context(spec:, config:)
}

/// The resolved OpenAPI spec this context wraps.
pub fn spec(ctx: Context) -> OpenApiSpec(Resolved) {
  ctx.spec
}

/// The generation config this context wraps.
pub fn config(ctx: Context) -> Config {
  ctx.config
}

/// Target for a generated file, indicating where it should be written.
pub type FileTarget {
  SharedTarget
  ServerTarget
  ClientTarget
}

/// A generated file with its path, content, and output target.
pub type GeneratedFile {
  GeneratedFile(path: String, content: String, target: FileTarget)
}
