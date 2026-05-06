//// Tests for the `oaspec/internal/progress` reporter.
////
//// The reporter wraps long-running pipeline stages so the CLI can
//// emit `[+elapsed] message` lines on the GitHub REST OpenAPI spec
//// (~12 MB) without callers having to plumb timing through every
//// internal module. These tests pin the contract:
////
////   - `noop()` swallows every event so library callers pay nothing
////   - `from_fn(...)` round-trips messages to the supplied callback
////   - `format_ms` renders three regimes (sub-second / sub-minute /
////     minute-and-up) consistently so progress lines stay aligned
////   - `timed(...)` returns the same value the body produced
////
//// `monotonic_ms` is an FFI shim and is exercised indirectly by
//// `timed`; we don't pin its absolute value here because that
//// depends on uptime.

import gleam/list
import gleeunit/should
import oaspec/internal/progress

pub fn noop_swallows_events_test() {
  let reporter = progress.noop()
  // The reporter must be safe to call even though no callback is
  // wired up — `report` should not panic or raise.
  progress.report(reporter, "any string")
  progress.report(reporter, "")
  // Reaching here without an exception is the assertion.
  Nil
}

pub fn from_fn_dispatches_each_call_test() {
  // Build a reporter that pushes each message into a process
  // dictionary entry so we can assert the order and count after
  // the fact. Process dictionary is acceptable here: each test
  // process gets its own.
  let key = "progress_test_from_fn_log"
  pdict_put(key, [])
  let reporter =
    progress.from_fn(fn(msg) {
      let prev = case pdict_get(key) {
        Ok(v) -> v
        Error(Nil) -> []
      }
      pdict_put(key, [msg, ..prev])
      Nil
    })
  progress.report(reporter, "first")
  progress.report(reporter, "second")
  progress.report(reporter, "third")
  let assert Ok(events_rev) = pdict_get(key)
  list.reverse(events_rev)
  |> should.equal(["first", "second", "third"])
}

pub fn timed_returns_body_value_test() {
  // The elapsed half is non-deterministic; the body half must be
  // exactly what the closure returned.
  let #(_elapsed, value) = progress.timed(fn() { 42 })
  value |> should.equal(42)
}

pub fn timed_runs_body_exactly_once_test() {
  let key = "progress_test_timed_runs"
  pdict_put(key, 0)
  let #(_elapsed, _value) =
    progress.timed(fn() {
      let assert Ok(prev) = pdict_get(key)
      pdict_put(key, prev + 1)
      Nil
    })
  let assert Ok(count) = pdict_get(key)
  count |> should.equal(1)
}

pub fn format_ms_sub_second_test() {
  progress.format_ms(0) |> should.equal("0ms")
  progress.format_ms(1) |> should.equal("1ms")
  progress.format_ms(999) |> should.equal("999ms")
}

pub fn format_ms_sub_minute_test() {
  // The "X.Ys" form keeps a single tenth so progress lines stay
  // narrow enough to align under a 7-character `[+...]` prefix.
  progress.format_ms(1000) |> should.equal("1.0s")
  progress.format_ms(1234) |> should.equal("1.2s")
  progress.format_ms(59_900) |> should.equal("59.9s")
}

pub fn format_ms_minute_and_up_test() {
  progress.format_ms(60_000) |> should.equal("1m0.0s")
  progress.format_ms(125_400) |> should.equal("2m5.4s")
}

pub fn timed_stage_returns_body_value_test() {
  // The body's value must round-trip through `timed_stage` unchanged.
  let value =
    progress.timed_stage(
      reporter: progress.noop(),
      label: "anything",
      body: fn() { 7 },
    )
  value |> should.equal(7)
}

pub fn timed_stage_emits_starting_and_completed_events_test() {
  // Two events: one BEFORE the body runs (so a slow or hung body is
  // attributable to a specific stage in real time) and one AFTER it
  // completes (so users see the elapsed-time figure).
  let key = "progress_test_timed_stage_msg"
  pdict_put(key, [])
  let reporter =
    progress.from_fn(fn(msg) {
      let prev = case pdict_get(key) {
        Ok(v) -> v
        Error(Nil) -> []
      }
      pdict_put(key, [msg, ..prev])
      Nil
    })
  let Nil =
    progress.timed_stage(reporter: reporter, label: "demo stage", body: fn() {
      Nil
    })
  let assert Ok(events_rev) = pdict_get(key)
  let events: List(String) = list.reverse(events_rev)
  case events {
    [first, second] -> {
      let first_ok = case first {
        "demo stage ..." -> True
        _ -> False
      }
      let second_ok = case second {
        "demo stage (took " <> _ -> True
        _ -> False
      }
      first_ok |> should.be_true()
      second_ok |> should.be_true()
    }
    _ -> {
      // Anything other than two events is a contract violation.
      should.be_true(False)
      Nil
    }
  }
}

@external(erlang, "erlang", "put")
fn pdict_put(key: String, value: a) -> a

@external(erlang, "oaspec_test_helpers_ffi", "pdict_get")
fn pdict_get(key: String) -> Result(a, Nil)
