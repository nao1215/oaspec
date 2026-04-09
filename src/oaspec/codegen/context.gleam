import oaspec/config.{type Config}
import oaspec/openapi/spec.{type OpenApiSpec}

/// The version of oaspec used for generated code headers.
pub const version = "0.6.1"

/// Context for code generation, carrying all needed state.
pub type Context {
  Context(spec: OpenApiSpec, config: Config)
}

/// Create a new generation context.
pub fn new(spec: OpenApiSpec, config: Config) -> Context {
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
