// JavaScript-target counterparts for the helpers in oaspec_ffi.erl that
// cross-target Gleam modules call. The BEAM-only CLI helpers have no JS
// @external and so no JS version here.

export function monotonic_ms() {
  // performance.now() is monotonic (unaffected by system clock changes)
  // and available in modern Node (>= 16) and all browsers. Fall back to
  // Date.now() if performance is somehow unavailable; the elapsed-time
  // semantics tolerate the slight loss of monotonicity for the brief
  // intervals oaspec actually measures.
  const ms =
    typeof performance !== "undefined" &&
    typeof performance.now === "function"
      ? performance.now()
      : Date.now();
  return Math.trunc(ms);
}
