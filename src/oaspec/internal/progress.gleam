//// Progress reporter used by the long-running pipeline phases (parse,
//// normalize, resolve, codegen, ...) to emit human-readable status
//// lines without forcing the pure pipeline to depend on `io`. The
//// pure entry points all accept a `Reporter`; library callers that
//// don't need progress hand in `noop()` and pay no cost, while the
//// CLI passes a reporter that prints `[mm:ss.mmm] message` lines.
////
//// Stages on the GitHub REST OpenAPI spec (~12 MB JSON, ~10k schemas)
//// take long enough that without progress lines the user can't tell
//// whether the process is hung or working — see issue #352.

import gleam/int
import gleam/io
import gleam/string

@external(erlang, "oaspec_ffi", "monotonic_ms")
@external(javascript, "../../oaspec_ffi.mjs", "monotonic_ms")
fn monotonic_ms() -> Int

/// A progress reporter. The `emit` callback receives a one-line
/// human-readable status message and decides where to send it (CLI
/// writes to stdout, library callers pass `noop()`).
pub opaque type Reporter {
  Reporter(emit: fn(String) -> Nil)
}

/// A reporter that drops every event. Used by the pure library API
/// when the caller does not want progress output.
pub fn noop() -> Reporter {
  Reporter(emit: fn(_) { Nil })
}

/// Build a reporter from a side-effecting callback. The CLI uses
/// `from_fn` with a stdout-printing callback; tests can use it to
/// capture events into a list ref.
pub fn from_fn(emit: fn(String) -> Nil) -> Reporter {
  Reporter(emit:)
}

/// Emit a single progress event. Cheap when the reporter is `noop()`.
pub fn report(reporter reporter: Reporter, message message: String) -> Nil {
  reporter.emit(message)
}

/// Time `body` in milliseconds and return both the elapsed time and
/// the body's result. Callers wrap each pipeline stage so the
/// reporter line includes "(took 1.23s)".
pub fn timed(body: fn() -> a) -> #(Int, a) {
  let start = monotonic_ms()
  let result = body()
  let end = monotonic_ms()
  #(end - start, result)
}

/// Run `body`, time it, and emit two events to `reporter`:
///
///   1. `<label> ...` BEFORE the body runs, so the user can see WHICH
///      stage is currently in flight if the body is slow or hangs;
///   2. `<label> (took <elapsed>)` AFTER it completes.
///
/// Returns `body`'s value unchanged.
///
/// Issue #537: `oaspec/generate.generate_all_files` used to emit a
/// single opaque `render generated source files` event covering
/// types/decoders/encoders/guards/server/client all at once. On large
/// specs (~10k schemas) the substage that was actually slow stayed
/// invisible until the entire render finished — minutes later, or
/// never. The "before" event guarantees the user sees which substage
/// has started even when the "after" event would never fire.
pub fn timed_stage(
  reporter reporter: Reporter,
  label label: String,
  body body: fn() -> a,
) -> a {
  report(reporter: reporter, message: label <> " ...")
  let #(elapsed, value) = timed(body)
  report(
    reporter: reporter,
    message: label <> " (took " <> format_ms(elapsed) <> ")",
  )
  value
}

/// Format a millisecond duration as a compact human string, e.g.
/// `"123ms"`, `"4.56s"`, `"1m23.4s"`. Used in progress lines so the
/// user can tell at a glance which stage is the slow one.
pub fn format_ms(ms: Int) -> String {
  case ms < 1000 {
    True -> int.to_string(ms) <> "ms"
    False -> {
      let total_seconds = ms / 1000
      let tenths = { ms - total_seconds * 1000 } / 100
      case total_seconds >= 60 {
        True -> {
          let minutes = total_seconds / 60
          let seconds = total_seconds - minutes * 60
          int.to_string(minutes)
          <> "m"
          <> int.to_string(seconds)
          <> "."
          <> int.to_string(tenths)
          <> "s"
        }
        False -> {
          int.to_string(total_seconds) <> "." <> int.to_string(tenths) <> "s"
        }
      }
    }
  }
}

/// Build a reporter that prints `[+elapsed] message` lines to stdout,
/// where `elapsed` is the time since the reporter was created. Used
/// by the CLI so the user can see which phase is currently running
/// and how long each phase took.
pub fn stdout_with_elapsed() -> Reporter {
  let started_at = monotonic_ms()
  from_fn(fn(message) {
    let elapsed = monotonic_ms() - started_at
    io.println("[+" <> pad_left(format_ms(elapsed), 7) <> "] " <> message)
  })
}

fn pad_left(value: String, width: Int) -> String {
  let len = string.length(value)
  case len >= width {
    True -> value
    False -> string.repeat(" ", width - len) <> value
  }
}
