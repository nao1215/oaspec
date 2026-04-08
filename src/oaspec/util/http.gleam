/// Shared HTTP status code utilities for code generation.
/// Get a human-readable suffix for a given HTTP status code.
/// Used to build anonymous type names like "ListPetsResponseOk".
pub fn status_code_suffix(code: String) -> String {
  case code {
    "200" -> "Ok"
    "201" -> "Created"
    "204" -> "NoContent"
    "400" -> "BadRequest"
    "401" -> "Unauthorized"
    "403" -> "Forbidden"
    "404" -> "NotFound"
    "409" -> "Conflict"
    "422" -> "UnprocessableEntity"
    "500" -> "InternalServerError"
    "default" -> "Default"
    other -> "Status" <> other
  }
}

/// Convert a status code string to an integer pattern for case matching.
/// The "default" status maps to "_" (catch-all).
pub fn status_code_to_int_pattern(code: String) -> String {
  case code {
    "default" -> "_"
    _ -> code
  }
}
