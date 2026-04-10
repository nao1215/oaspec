import oaspec/config.{type Config}
import oaspec/openapi/spec.{type OpenApiSpec, type SpecStage}

/// The version of oaspec used for generated code headers.
pub const version = "0.8.0"

/// Context for code generation, carrying all needed state.
/// Accepts a spec at any stage so the pipeline can create context
/// before full resolution (hoist/dedup operate on Unresolved).
pub type Context {
  Context(spec: OpenApiSpec(SpecStage), config: Config)
}

/// Create a new generation context.
pub fn new(spec: OpenApiSpec(SpecStage), config: Config) -> Context {
  Context(spec:, config:)
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
