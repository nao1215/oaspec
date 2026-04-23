import gleam/list

/// Support level for an OpenAPI feature.
pub type SupportLevel {
  /// Fully supported in parsing and code generation
  Supported
  /// Parsed, normalized to supported form by normalize pass
  Normalizable
  /// Parsed and preserved but not used by codegen (warning emitted)
  ParsedNotUsed
  /// Parsed but not supported for codegen (error emitted)
  Unsupported
  /// Not handled by parser
  NotHandled
}

/// A capability entry.
pub type Capability {
  Capability(name: String, category: String, level: SupportLevel, note: String)
}

/// The single source of truth for feature support.
pub fn registry() -> List(Capability) {
  [
    // Schema — supported
    Capability("object", "schema", Supported, "Object schemas with properties"),
    Capability(
      "string",
      "schema",
      Supported,
      "String schemas with enum, format, pattern",
    ),
    Capability("integer", "schema", Supported, "Integer schemas"),
    Capability("number", "schema", Supported, "Number schemas"),
    Capability("boolean", "schema", Supported, "Boolean schemas"),
    Capability("array", "schema", Supported, "Array schemas with items"),
    Capability("allOf", "schema", Supported, "Schema composition"),
    Capability(
      "oneOf",
      "schema",
      Supported,
      "Schema composition with discriminator",
    ),
    Capability(
      "anyOf",
      "schema",
      Supported,
      "Schema composition with discriminator",
    ),
    Capability("nullable", "schema", Supported, "Nullable fields"),
    Capability(
      "additionalProperties",
      "schema",
      Supported,
      "Typed, untyped, forbidden",
    ),
    Capability("$ref", "schema", Supported, "Local $ref resolution"),
    Capability("enum", "schema", Supported, "String enum values"),
    Capability(
      "discriminator",
      "schema",
      Supported,
      "With propertyName and mapping",
    ),
    // Schema — normalizable
    Capability(
      "const",
      "schema",
      Normalizable,
      "Normalized to single-value enum",
    ),
    Capability(
      "type: [T, null]",
      "schema",
      Normalizable,
      "Normalized to nullable",
    ),
    Capability("type: [T1, T2]", "schema", Normalizable, "Normalized to oneOf"),
    // Schema — unsupported (rejected at capability_check)
    Capability(
      "$defs",
      "schema",
      Unsupported,
      "Move definitions to components/schemas",
    ),
    Capability(
      "prefixItems",
      "schema",
      Unsupported,
      "Tuple types not supported",
    ),
    Capability("if", "schema", Unsupported, "Use oneOf/anyOf instead"),
    Capability("then", "schema", Unsupported, "Use oneOf/anyOf instead"),
    Capability("else", "schema", Unsupported, "Use oneOf/anyOf instead"),
    Capability("dependentSchemas", "schema", Unsupported, "Not supported"),
    Capability("not", "schema", Unsupported, "Negation not supported"),
    Capability("unevaluatedProperties", "schema", Unsupported, "Not supported"),
    Capability("unevaluatedItems", "schema", Unsupported, "Not supported"),
    Capability("contentEncoding", "schema", Unsupported, "Not supported"),
    Capability("contentMediaType", "schema", Unsupported, "Not supported"),
    Capability("contentSchema", "schema", Unsupported, "Not supported"),
    Capability(
      "$id",
      "schema",
      Unsupported,
      "OpenAPI 3.1 JSON Schema `$id`-backed URL refs are not resolved; use local `#/components/schemas/...` refs instead",
    ),
    Capability(
      "const (non-string)",
      "schema",
      Unsupported,
      "Only string `const` is lowered to a single-value enum; non-string `const` (bool, int, number, object, array, null) cannot be represented in generated code",
    ),
    Capability(
      "type: [T1, T2] with type-specific constraints",
      "schema",
      Unsupported,
      "Multi-type schemas are rewritten to `oneOf`, which would silently drop type-specific constraints (pattern, minLength, minimum, etc.). Split the schema into separate variants or drop the constraints",
    ),
    // Security
    Capability("apiKey", "security", Supported, "Header, query, cookie"),
    Capability("http", "security", Supported, "Bearer, basic, and digest auth"),
    Capability(
      "oauth2",
      "security",
      Supported,
      "Bearer token attachment only; token acquisition and refresh are not generated",
    ),
    Capability(
      "openIdConnect",
      "security",
      Supported,
      "Bearer token attachment only; discovery and token acquisition are not generated",
    ),
    Capability("mutualTLS", "security", Unsupported, "Not supported"),
    // Parameters
    Capability(
      "path parameters",
      "parameter",
      Supported,
      "With schema validation",
    ),
    Capability(
      "query parameters",
      "parameter",
      Supported,
      "Including deepObject",
    ),
    Capability(
      "header parameters",
      "parameter",
      Supported,
      "String, int, float, bool",
    ),
    Capability(
      "cookie parameters",
      "parameter",
      Supported,
      "With percent-decoding",
    ),
    Capability(
      "allowReserved",
      "parameter",
      Supported,
      "Skips percent-encoding",
    ),
    // Request bodies
    Capability("application/json", "request", Supported, "JSON request bodies"),
    Capability(
      "application/x-www-form-urlencoded",
      "request",
      Supported,
      "Form bodies",
    ),
    Capability("multipart/form-data", "request", Supported, "Multipart upload"),
    Capability(
      "+json/+xml suffix",
      "content-type",
      Supported,
      "Structured syntax suffix media types (e.g. application/problem+json)",
    ),
    // Responses
    Capability("application/json", "response", Supported, "JSON responses"),
    Capability("text/plain", "response", Supported, "Text passthrough"),
    Capability(
      "application/octet-stream",
      "response",
      Supported,
      "Binary passthrough",
    ),
    Capability(
      "application/xml",
      "response",
      Supported,
      "XML passthrough; no structural decoding yet",
    ),
    Capability(
      "text/xml",
      "response",
      Supported,
      "XML passthrough; no structural decoding yet",
    ),
    // Server-mode validation restrictions — features the parser accepts
    // but the server-code generator rejects. Names match the phrasing
    // used in the corresponding `validate.gleam` diagnostic details so
    // the README drift test keeps docs honest.
    Capability(
      "server: complex path parameters",
      "server-validation",
      Unsupported,
      "Path parameters must be scalar (string, integer, number, boolean)",
    ),
    Capability(
      "server: non-primitive query array items",
      "server-validation",
      Unsupported,
      "Query array parameters require inline primitive items",
    ),
    Capability(
      "server: non-primitive header array items",
      "server-validation",
      Unsupported,
      "Header array parameters require inline primitive items",
    ),
    Capability(
      "server: complex deepObject properties",
      "server-validation",
      Unsupported,
      "deepObject properties must be primitive scalars or primitive array leaves",
    ),
    Capability(
      "server: mixed form-urlencoded request",
      "server-validation",
      Unsupported,
      "application/x-www-form-urlencoded must be the sole request content type",
    ),
    Capability(
      "server: complex form-urlencoded fields",
      "server-validation",
      Unsupported,
      "Form fields must be primitive scalars, primitive arrays, or shallow nested objects (max 5 levels)",
    ),
    Capability(
      "server: mixed multipart request",
      "server-validation",
      Unsupported,
      "multipart/form-data must be the sole request content type",
    ),
    Capability(
      "server: complex multipart fields",
      "server-validation",
      Unsupported,
      "Multipart fields must be primitive scalars (or arrays of them)",
    ),
    Capability(
      "server: unsupported request content type",
      "server-validation",
      Unsupported,
      "Server router only supports application/json, application/x-www-form-urlencoded, and multipart/form-data",
    ),
    // Codegen scope
    Capability("webhooks", "scope", ParsedNotUsed, "Parsed but no codegen"),
    Capability("externalDocs", "scope", ParsedNotUsed, "Parsed but no codegen"),
    Capability("tags", "scope", ParsedNotUsed, "Parsed but no codegen"),
    Capability("examples", "scope", ParsedNotUsed, "Parsed but no codegen"),
    Capability("links", "scope", ParsedNotUsed, "Parsed but no codegen"),
    Capability(
      "callbacks",
      "scope",
      ParsedNotUsed,
      "Operation-level and components.callbacks are parsed and preserved (including `$ref` to `#/components/callbacks/...`) but no code is generated for callback endpoints",
    ),
    Capability("xml", "scope", NotHandled, "XML annotations ignored"),
    // operation-level and path-level server overrides are supported as of #96
    // (generated clients resolve operation > path > top-level). They are no
    // longer listed here — absence from the registry means Supported.
    Capability(
      "response headers",
      "scope",
      Supported,
      "Response header types generated",
    ),
    Capability("encoding", "scope", ParsedNotUsed, "Parsed but no codegen"),
  ]
}

/// Get capabilities by level.
pub fn by_level(level: SupportLevel) -> List(Capability) {
  list.filter(registry(), fn(c) { c.level == level })
}
