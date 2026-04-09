import gleam/int
import gleam/list

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
    "1XX" | "1xx" -> "Status1xx"
    "2XX" | "2xx" -> "Status2xx"
    "3XX" | "3xx" -> "Status3xx"
    "4XX" | "4xx" -> "Status4xx"
    "5XX" | "5xx" -> "Status5xx"
    other -> "Status" <> other
  }
}

/// Convert a status code string to a valid Gleam case pattern.
/// Exact codes become integer literals, range codes become guard expressions,
/// and "default" becomes "_" (catch-all).
pub fn status_code_to_int_pattern(code: String) -> String {
  case code {
    "default" -> "_"
    "1XX" | "1xx" -> "status if status >= 100 && status <= 199"
    "2XX" | "2xx" -> "status if status >= 200 && status <= 299"
    "3XX" | "3xx" -> "status if status >= 300 && status <= 399"
    "4XX" | "4xx" -> "status if status >= 400 && status <= 499"
    "5XX" | "5xx" -> "status if status >= 500 && status <= 599"
    _ -> code
  }
}

/// Sort response entries so that exact codes come before ranges,
/// and ranges come before the default catch-all. This ensures
/// correct pattern matching order in generated case expressions.
pub fn sort_response_entries(entries: List(#(String, a))) -> List(#(String, a)) {
  list.sort(entries, fn(a, b) {
    int.compare(status_sort_priority(a.0), status_sort_priority(b.0))
  })
}

/// Convert a status code string to an integer string for use in ServerResponse.
/// Range codes and "default" map to a representative status code.
pub fn status_code_to_int(code: String) -> String {
  case code {
    "default" -> "500"
    "1XX" | "1xx" -> "100"
    "2XX" | "2xx" -> "200"
    "3XX" | "3xx" -> "300"
    "4XX" | "4xx" -> "400"
    "5XX" | "5xx" -> "500"
    _ -> code
  }
}

fn status_sort_priority(code: String) -> Int {
  case code {
    "default" -> 9999
    "1XX" | "1xx" -> 1100
    "2XX" | "2xx" -> 1200
    "3XX" | "3xx" -> 1300
    "4XX" | "4xx" -> 1400
    "5XX" | "5xx" -> 1500
    _ -> {
      case int.parse(code) {
        Ok(n) -> n
        Error(_) -> 9998
      }
    }
  }
}
