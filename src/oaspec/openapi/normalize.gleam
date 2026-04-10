import oaspec/openapi/spec.{type OpenApiSpec}

/// Normalize an OpenAPI spec after parsing.
/// Applies OAS 3.1 -> 3.0-compatible transformations so that
/// downstream codegen can work with a consistent representation.
///
/// Currently a pass-through. Future normalizations will include:
/// - type: [T, U] -> oneOf conversion
/// - const -> single-value enum
/// - $defs flattening
pub fn normalize(spec: OpenApiSpec) -> OpenApiSpec {
  spec
}
