//// Human-readable rendering of diagnostic pointer strings. The machine
//// layer — `Diagnostic.pointer` itself — is left untouched so future
//// `--format json` output or any consumer that wants the raw
//// JSON Pointer / dotted path can still read it verbatim. This module
//// only owns the CLI presentation transform.
////
//// The function is deliberately spec-context free: it never looks a
//// path up in a parsed spec. That is a larger follow-up; here the goal
//// is simply to turn `paths.~1pets.get.parameters.0` into
//// `GET /pets, parameter #0` so a reader does not need to know about
//// JSON Pointer escape rules.

import gleam/list
import gleam/string

/// Translate a diagnostic pointer into a human-readable location string.
///
/// Recognised shapes:
/// - `paths.<escaped>.<method>.parameters.<idx>[...]`
///   → `METHOD /path, parameter #idx[...]`
/// - `paths.<escaped>.<method>.requestBody[...]`
///   → `METHOD /path, requestBody[...]`
/// - `paths.<escaped>.<method>.responses.<status>[...]`
///   → `METHOD /path, response <status>[...]`
/// - `paths.<escaped>.<method>[...]`
///   → `METHOD /path[...]`
/// - `components.<kind>.<name>[...]`
///   → `<kind>.<name>[...]`
///
/// Falls back to the escape-decoded pointer if no pattern matches, so
/// callers always get *something* intelligible.
pub fn pointer_to_human(pointer: String) -> String {
  case pointer {
    "" -> "root"
    _ -> format_segments(split_pointer(pointer), pointer)
  }
}

fn split_pointer(pointer: String) -> List(String) {
  // Known limitation: this splits on `.` unconditionally, so a pointer whose
  // path contains a literal dot (e.g. `/v1.0/pets`) will fragment. Every
  // pointer constructed inside this repo is dot-free today. If that changes,
  // switch to splitting on `/` first and only normalising `.` where the
  // segment is known not to be a user-supplied path.
  pointer
  |> string.replace("#/", "")
  |> string.replace("/", ".")
  |> string.split(".")
  |> list.filter(fn(s) { s != "" })
  |> list.map(unescape_segment)
}

/// JSON Pointer unescaping per RFC 6901: `~1` → `/`, `~0` → `~`.
/// Order matters: `~1` must be decoded first so `~01` ends up as `~1`,
/// not `/`.
fn unescape_segment(s: String) -> String {
  s
  |> string.replace("~1", "/")
  |> string.replace("~0", "~")
}

fn format_segments(segments: List(String), original: String) -> String {
  case segments {
    ["paths", path, method, "parameters", idx, ..rest] ->
      with_tail(
        string.uppercase(method) <> " " <> path <> ", parameter #" <> idx,
        rest,
      )
    ["paths", path, method, "requestBody", ..rest] ->
      with_tail(
        string.uppercase(method) <> " " <> path <> ", requestBody",
        rest,
      )
    ["paths", path, method, "responses", status, ..rest] ->
      with_tail(
        string.uppercase(method) <> " " <> path <> ", response " <> status,
        rest,
      )
    ["paths", path, method, ..rest] ->
      with_tail(string.uppercase(method) <> " " <> path, rest)
    ["components", "schemas", name, ..rest] ->
      with_tail("schemas." <> name, rest)
    ["components", "parameters", name, ..rest] ->
      with_tail("parameters." <> name, rest)
    ["components", "responses", name, ..rest] ->
      with_tail("responses." <> name, rest)
    ["components", "requestBodies", name, ..rest] ->
      with_tail("requestBodies." <> name, rest)
    ["components", kind, name, ..rest] -> with_tail(kind <> "." <> name, rest)
    _ -> default_format(segments, original)
  }
}

fn with_tail(base: String, rest: List(String)) -> String {
  case rest {
    [] -> base
    _ -> base <> " (" <> string.join(rest, ".") <> ")"
  }
}

fn default_format(segments: List(String), original: String) -> String {
  case segments {
    [] -> original
    _ -> string.join(segments, ".")
  }
}
