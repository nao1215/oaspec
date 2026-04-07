import oas_gleam/config.{type Config}
import oas_gleam/openapi/spec.{type OpenApiSpec}

/// The version of oas-gleam used for generated code headers.
pub const version = "0.1.1"

/// Context for code generation, carrying all needed state.
pub type Context {
  Context(spec: OpenApiSpec, config: Config)
}

/// Create a new generation context.
pub fn new(spec: OpenApiSpec, config: Config) -> Context {
  Context(spec:, config:)
}

/// A generated file with its path and content.
pub type GeneratedFile {
  GeneratedFile(path: String, content: String)
}
