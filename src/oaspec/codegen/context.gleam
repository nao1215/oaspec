import oaspec/config.{type Config}
import oaspec/openapi/spec.{type OpenApiSpec, type Resolved}

/// The version of oaspec used for generated code headers.
pub const version = "0.12.0"

/// Context for code generation, carrying all needed state.
/// Only accepts a resolved spec — codegen must not operate on unresolved ASTs.
pub type Context {
  Context(spec: OpenApiSpec(Resolved), config: Config)
}

/// Create a new generation context from a resolved spec.
pub fn new(spec: OpenApiSpec(Resolved), config: Config) -> Context {
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
