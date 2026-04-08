import oaspec/config.{type Config}
import oaspec/openapi/spec.{type OpenApiSpec}

/// The version of oaspec used for generated code headers.
pub const version = "0.4.0"

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
