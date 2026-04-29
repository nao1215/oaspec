import gleam/int
import gleam/list
import gleam/result

/// Errors from formatting operations.
pub type FormatError {
  GleamNotFound
  FormatFailed(exit_code: Int)
}

/// Format generated Gleam files in the given directories using `gleam format`.
pub fn format_files(dirs: List(String)) -> Result(Nil, FormatError) {
  use gleam_path <- result.try(
    find_executable("gleam")
    |> result.replace_error(GleamNotFound),
  )
  let args = list.prepend(dirs, "format")
  let exit_code = run_executable(gleam_path, args)
  case exit_code {
    0 -> Ok(Nil)
    code -> Error(FormatFailed(exit_code: code))
  }
}

/// Convert a format error to a human-readable string.
pub fn error_to_string(error: FormatError) -> String {
  case error {
    GleamNotFound ->
      "gleam command not found in PATH. Install Gleam to format generated code."
    FormatFailed(code) ->
      "gleam format failed with exit code " <> int.to_string(code)
  }
}

@external(erlang, "oaspec_ffi", "find_executable")
fn find_executable(name: String) -> Result(String, Nil)

@external(erlang, "oaspec_ffi", "run_executable")
fn run_executable(executable: String, args: List(String)) -> Int
