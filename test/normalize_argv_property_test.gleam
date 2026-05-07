//// metamon property tests for `oaspec.normalize_argv`. Pin the
//// algebraic invariants the function is documented to hold so a
//// future refactor (or a new value-flag added to `cli.value_flag_names`)
//// surfaces a regression here instead of breaking the CLI for end
//// users. Issue #551.

import gleam/list
import gleam/string
import metamon
import metamon/generator
import metamon/generator/range
import metamon/relation
import oaspec
import oaspec/internal/cli

// ---------- argv generators ----------

// A long-form value flag drawn from the project's actual list. The
// test imports `cli.value_flag_names` rather than duplicating the
// constant, so adding `--strict` (or any future flag) extends the
// property's input space automatically.
fn value_flag_gen() -> generator.Generator(String) {
  let flag_name_gen = generator.element_of(cli.value_flag_names)
  generator.map(flag_name_gen, fn(name) { "--" <> name })
}

// A bool-style long flag (no value). These are NOT in the value-flag
// list, so normalize_argv must pass them through untouched.
fn bool_flag_gen() -> generator.Generator(String) {
  generator.element_of([
    "--help", "--version", "--check", "--fail-on-warnings", "--list-targets",
    "--verbose",
  ])
}

// A value-shaped argv token: starts with a non-`-` byte (so
// normalize_argv treats it as a value rather than a flag).
fn value_token_gen() -> generator.Generator(String) {
  // string_alpha guarantees the first character is alphabetic — never
  // `-` — so the token always satisfies value_is_value internally.
  generator.string_alpha(range.constant(1, 8))
}

// A short-form `-X` flag — nothing in the value-flag list starts with
// a single dash, so these are pass-through. Mixing them in shakes out
// "is_value_long_flag should reject single-dash" regressions.
fn short_flag_gen() -> generator.Generator(String) {
  generator.element_of(["-h", "-v", "-V", "-x", "-y"])
}

// A free-form positional argument — alphanumeric, no leading `-`.
fn positional_gen() -> generator.Generator(String) {
  generator.string_alphanumeric(range.constant(1, 8))
}

// An argv element drawn from any of the four shapes above. The
// resulting list is the property's primary fuzz surface.
fn argv_token_gen() -> generator.Generator(String) {
  generator.one_of([
    value_flag_gen(),
    bool_flag_gen(),
    short_flag_gen(),
    positional_gen(),
    value_token_gen(),
  ])
}

fn argv_gen() -> generator.Generator(List(String)) {
  generator.list_of(argv_token_gen(), range.constant(0, 8))
}

// An argv that contains no value-bearing long flags. normalize_argv
// is documented to pass these through untouched.
fn argv_without_value_flags_gen() -> generator.Generator(List(String)) {
  let token =
    generator.one_of([
      bool_flag_gen(),
      short_flag_gen(),
      positional_gen(),
      value_token_gen(),
    ])
  generator.list_of(token, range.constant(0, 8))
}

// ---------- properties ----------

// 1. Idempotent: normalising an already-normalised argv is a no-op.
//    A second pass cannot collapse new pairs because `--name=value`
//    has the `=` baked in and is not in the value-flag list anymore.
pub fn normalize_argv_idempotent_test() {
  let mr =
    metamon.idempotency_of(
      name: "normalize_argv_idempotent",
      of: oaspec.normalize_argv,
    )
  metamon.forall_morph(argv_gen(), mr, oaspec.normalize_argv)
}

// 2. Length non-increasing: each pair-collapse turns two argv elements
//    into one, and no other shape grows the list.
pub fn normalize_argv_length_non_increasing_test() {
  metamon.forall(argv_gen(), fn(args) {
    list.length(oaspec.normalize_argv(args)) <= list.length(args)
  })
}

// 3. Pass-through for argv with no value-flags. The function must
//    return the input bit-for-bit when there is nothing to collapse.
pub fn normalize_argv_passthrough_when_no_value_flags_test() {
  metamon.forall(argv_without_value_flags_gen(), fn(args) {
    oaspec.normalize_argv(args) == args
  })
}

// 4. `--name value` and `--name=value` are equivalent on the output
//    side — that is the whole point of the function.
pub fn normalize_argv_value_flag_equivalence_test() {
  metamon.forall(
    generator.tuple2(value_flag_gen(), value_token_gen()),
    fn(pair) {
      let #(flag, value) = pair
      oaspec.normalize_argv([flag, value])
      == oaspec.normalize_argv([flag <> "=" <> value])
    },
  )
}

// 5. Output should never contain a value-bearing long flag in the
//    bare `--name` form (without `=`) followed by a value-shaped
//    token. If it did, the user would still see glint's "invalid
//    flag" error. This is the round-trip end of property 4.
pub fn normalize_argv_output_has_no_unjoined_value_flag_pairs_test() {
  metamon.forall(argv_gen(), fn(args) {
    let normalised = oaspec.normalize_argv(args)
    !contains_unjoined_value_flag_pair(normalised)
  })
}

// Helper: scan a normalised argv for a `--name` token (where `name` is
// a value-bearing flag without `=`) followed by a value-shaped token.
fn contains_unjoined_value_flag_pair(args: List(String)) -> Bool {
  case args {
    [] -> False
    [_] -> False
    [first, second, ..rest] ->
      case is_bare_value_flag(first), is_value_token(second) {
        True, True -> True
        _, _ -> contains_unjoined_value_flag_pair([second, ..rest])
      }
  }
}

fn is_bare_value_flag(arg: String) -> Bool {
  // "--config" matches; "--config=foo" does not (the second branch
  // here intentionally excludes `=`-bearing forms via element_of).
  list.any(cli.value_flag_names, fn(name) { arg == "--" <> name })
}

fn is_value_token(arg: String) -> Bool {
  case arg {
    "" -> False
    _ -> !string.starts_with(arg, "-")
  }
}

// 6. forall_morph: the list-as-multiset of normalised tokens does
//    NOT need to equal the input multiset (pair-collapse changes
//    elements), but appending an unrelated bool flag commutes with
//    normalisation — adding it before or after normalising should not
//    change the result.
pub fn normalize_argv_appending_bool_flag_commutes_test() {
  metamon.forall(generator.tuple2(argv_gen(), bool_flag_gen()), fn(pair) {
    let #(args, bool_flag) = pair
    oaspec.normalize_argv(list.append(args, [bool_flag]))
    == list.append(oaspec.normalize_argv(args), [bool_flag])
  })
}

// Sanity: the all_equal relation is satisfied trivially when both
// branches return the same shape — used here so `relation` has a
// referenced symbol to keep the import alive even if the file is
// pruned to a single property in the future.
pub fn normalize_argv_pure_smoke_test() {
  let all_equal = relation.all_equal()
  let assert True = all_equal.holds([1, 1, 1])
  Nil
}
