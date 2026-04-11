import gleam/int
import gleam/list

/// Type-safe HTTP status code representation.
/// Replaces raw String status codes throughout the codebase.
pub type HttpStatusCode {
  /// An exact HTTP status code, e.g. 200, 404, 500.
  Status(Int)
  /// A wildcard range, e.g. 2XX is StatusRange(2), 4XX is StatusRange(4).
  StatusRange(Int)
  /// The OpenAPI "default" catch-all response.
  DefaultStatus
}

/// Parse a raw status code string from an OpenAPI spec into an HttpStatusCode.
/// Returns Error(Nil) for unrecognisable strings.
pub fn parse_status_code(code: String) -> Result(HttpStatusCode, Nil) {
  case code {
    "default" -> Ok(DefaultStatus)
    "1XX" | "1xx" -> Ok(StatusRange(1))
    "2XX" | "2xx" -> Ok(StatusRange(2))
    "3XX" | "3xx" -> Ok(StatusRange(3))
    "4XX" | "4xx" -> Ok(StatusRange(4))
    "5XX" | "5xx" -> Ok(StatusRange(5))
    _ ->
      case int.parse(code) {
        Ok(n) -> Ok(Status(n))
        Error(_) -> Error(Nil)
      }
  }
}

/// Convert an HttpStatusCode back to its canonical string form.
pub fn status_code_to_string(code: HttpStatusCode) -> String {
  case code {
    Status(n) -> int.to_string(n)
    StatusRange(n) -> int.to_string(n) <> "XX"
    DefaultStatus -> "default"
  }
}

/// Shared HTTP status code utilities for code generation.
/// Get a human-readable suffix for a given HTTP status code.
/// Used to build anonymous type names like "ListPetsResponseOk".
pub fn status_code_suffix(code: HttpStatusCode) -> String {
  case code {
    Status(200) -> "Ok"
    Status(201) -> "Created"
    Status(204) -> "NoContent"
    Status(400) -> "BadRequest"
    Status(401) -> "Unauthorized"
    Status(403) -> "Forbidden"
    Status(404) -> "NotFound"
    Status(409) -> "Conflict"
    Status(422) -> "UnprocessableEntity"
    Status(500) -> "InternalServerError"
    Status(n) -> "Status" <> int.to_string(n)
    StatusRange(1) -> "Status1xx"
    StatusRange(2) -> "Status2xx"
    StatusRange(3) -> "Status3xx"
    StatusRange(4) -> "Status4xx"
    StatusRange(5) -> "Status5xx"
    StatusRange(n) -> "Status" <> int.to_string(n) <> "xx"
    DefaultStatus -> "Default"
  }
}

/// Convert an HttpStatusCode to a valid Gleam case pattern.
/// Exact codes become integer literals, range codes become guard expressions,
/// and DefaultStatus becomes "_" (catch-all).
pub fn status_code_to_int_pattern(code: HttpStatusCode) -> String {
  case code {
    DefaultStatus -> "_"
    StatusRange(n) -> {
      let low = int.to_string(n * 100)
      let high = int.to_string(n * 100 + 99)
      "status if status >= " <> low <> " && status <= " <> high
    }
    Status(n) -> int.to_string(n)
  }
}

/// Sort response entries so that exact codes come before ranges,
/// and ranges come before the default catch-all. This ensures
/// correct pattern matching order in generated case expressions.
pub fn sort_response_entries(
  entries: List(#(HttpStatusCode, a)),
) -> List(#(HttpStatusCode, a)) {
  list.sort(entries, fn(a, b) {
    int.compare(status_sort_priority(a.0), status_sort_priority(b.0))
  })
}

/// Convert an HttpStatusCode to an integer string for use in ServerResponse.
/// Range codes and DefaultStatus map to a representative status code.
pub fn status_code_to_int(code: HttpStatusCode) -> String {
  case code {
    DefaultStatus -> "500"
    StatusRange(n) -> int.to_string(n * 100)
    Status(n) -> int.to_string(n)
  }
}

fn status_sort_priority(code: HttpStatusCode) -> Int {
  case code {
    DefaultStatus -> 9999
    StatusRange(n) -> n * 100 + 1000
    Status(n) -> n
  }
}
