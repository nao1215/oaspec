import gleam/list
import gleam/string

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
    // Security
    Capability("apiKey", "security", Supported, "Header, query, cookie"),
    Capability("http", "security", Supported, "Bearer and basic auth"),
    Capability("oauth2", "security", Supported, "OAuth2 flows with scopes"),
    Capability("openIdConnect", "security", Supported, "OpenID Connect"),
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
    // Responses
    Capability("application/json", "response", Supported, "JSON responses"),
    Capability("text/plain", "response", Supported, "Text passthrough"),
    Capability(
      "application/octet-stream",
      "response",
      Supported,
      "Binary passthrough",
    ),
    // Codegen scope
    Capability("webhooks", "scope", ParsedNotUsed, "Parsed but no codegen"),
    Capability("externalDocs", "scope", ParsedNotUsed, "Parsed but no codegen"),
    Capability("tags", "scope", ParsedNotUsed, "Parsed but no codegen"),
    Capability("examples", "scope", ParsedNotUsed, "Parsed but no codegen"),
    Capability("links", "scope", ParsedNotUsed, "Parsed but no codegen"),
    Capability("xml", "scope", NotHandled, "XML annotations ignored"),
    Capability(
      "operation servers",
      "scope",
      ParsedNotUsed,
      "Client uses top-level only",
    ),
    Capability(
      "path servers",
      "scope",
      ParsedNotUsed,
      "Client uses top-level only",
    ),
    Capability(
      "response headers",
      "scope",
      ParsedNotUsed,
      "Parsed but no codegen",
    ),
    Capability("encoding", "scope", ParsedNotUsed, "Parsed but no codegen"),
  ]
}

/// Get the list of unsupported schema keywords from the registry.
pub fn unsupported_schema_keywords() -> List(String) {
  registry()
  |> list.filter(fn(c) { c.category == "schema" && c.level == Unsupported })
  |> list.map(fn(c) { c.name })
}

/// Check if a security scheme type is unsupported.
pub fn is_unsupported_security_type(type_name: String) -> Bool {
  registry()
  |> list.any(fn(c) {
    c.category == "security" && c.name == type_name && c.level == Unsupported
  })
}

/// Get capabilities by level.
pub fn by_level(level: SupportLevel) -> List(Capability) {
  list.filter(registry(), fn(c) { c.level == level })
}

/// Generate the "Current Boundaries" markdown section from the registry.
pub fn generate_boundaries_markdown() -> String {
  let unsupported = by_level(Unsupported)
  let unsupported_names =
    list.map(unsupported, fn(c) { "`" <> c.name <> "`" })
    |> string.join(", ")
  let not_handled = by_level(NotHandled)
  let not_handled_names =
    list.map(not_handled, fn(c) { "`" <> c.name <> "`" })
    |> string.join(", ")
  let parsed_not_used = by_level(ParsedNotUsed)
  let parsed_not_used_names =
    list.map(parsed_not_used, fn(c) { c.name })
    |> string.join(", ")
  let normalizable = by_level(Normalizable)
  let normalizable_lines =
    list.map(normalizable, fn(c) { "- `" <> c.name <> "`: " <> c.note })
    |> string.join("\n")

  "## Current Boundaries

These are the most important limitations today:

- The following keywords are detected and rejected: " <> unsupported_names <> "
- " <> not_handled_names <> " annotations are not handled by the parser
- Some fields are parsed and preserved but not yet used by codegen: " <> parsed_not_used_names <> "
- The following are normalized to supported equivalents:
" <> normalizable_lines
}
