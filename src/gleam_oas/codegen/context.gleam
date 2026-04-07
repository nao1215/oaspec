import gleam_oas/config.{type Config}
import gleam_oas/openapi/spec.{type OpenApiSpec}

/// The version of gleam-oas used for generated code headers.
pub const version = "0.1.0"

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
