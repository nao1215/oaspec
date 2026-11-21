//// Helpers over the `oaspec/openapi` document types.

import gleam/http.{type Method}
import gleam/option.{type Option}
import gleam/string
import oaspec/openapi.{
  type Parameter, type RefOr, type SchemaRef, ParameterContent, ParameterSchema,
  Ref, Value,
}

/// Unwrap a RefOr assuming it has been resolved. Panics on Ref.
///
/// Callers are expected to hold a `RefOr(a)` from an `OpenApiSpec(Resolved)`
/// subtree; the resolve phase statically eliminates `Ref(_)` before this
/// runs, so reaching the `Ref` branch would indicate an internal invariant
/// violation rather than a user-facing error.
pub fn unwrap_ref(ref_or: RefOr(a)) -> a {
  case ref_or {
    Value(v) -> v
    // nolint: avoid_panic -- invariant: resolve phase eliminates Ref(_) in Resolved subtrees; reaching this branch is a compiler/internal bug
    Ref(r) -> panic as { "unwrap_ref on unresolved $ref: " <> r }
  }
}

/// Extract the schema from a parameter's payload, if it uses schema encoding.
pub fn parameter_schema(param: Parameter(stage)) -> Option(SchemaRef) {
  case param.payload {
    ParameterSchema(s) -> option.Some(s)
    ParameterContent(_) -> option.None
  }
}

/// The method name in upper case, such as `GET`.
pub fn method_to_string(method: Method) -> String {
  http.method_to_string(method)
}

/// The method name in lower case, such as `get`, as used for path item keys.
pub fn method_to_lower(method: Method) -> String {
  string.lowercase(http.method_to_string(method))
}
