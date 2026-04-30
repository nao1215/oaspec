import oaspec/config.{type Config}
import oaspec/internal/openapi/spec.{type OpenApiSpec, type Resolved}

/// The version of oaspec used for generated code headers.
pub const version = "0.33.0"

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

/// How the writer should treat a `GeneratedFile` that already exists on
/// disk. Most generated files are sealed (`Overwrite`) — the user is
/// expected not to touch them and the generator clobbers any local
/// changes on every run. `SkipIfExists` is for files the generator
/// emits ONCE as a starting point, then leaves alone so the user can
/// own the contents (Issue #247: `handlers.gleam` panic stubs).
pub type WriteMode {
  Overwrite
  SkipIfExists
}

/// A generated file with its path, content, output target, and write
/// mode. `write_mode` defaults to `Overwrite` for every file the
/// generator owns end-to-end.
pub type GeneratedFile {
  GeneratedFile(
    path: String,
    content: String,
    target: FileTarget,
    write_mode: WriteMode,
  )
}
