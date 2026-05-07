import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/regexp.{type Regexp}
import gleam/string

/// Pre-compiled regexes used by naming functions.
///
/// Issue #405: previously these were compiled on every public-call
/// entry (`to_pascal_case` / `to_snake_case`). On a 10k-schema spec
/// that's 30k+ regex compiles per `oaspec generate`. The FFI helper
/// `memoize_regexes` below stashes the first-ever computed value in
/// `persistent_term` so subsequent calls are O(1) lookups with no GC
/// pressure.
type Regexes {
  Regexes(
    word_separator: Regexp,
    camel_case: Regexp,
    underscore_before_caps: Regexp,
  )
}

/// Cache key for the persistent_term store. Zero-arg constructors map
/// to atoms in Erlang; we only need the type to be unique to oaspec
/// so the key cannot collide with anything else stored in
/// persistent_term by other applications.
type RegexCacheKey {
  OaspecNamingRegexes
}

@external(erlang, "oaspec_naming_ffi", "memoize")
fn memoize_regexes(key: RegexCacheKey, compute: fn() -> Regexes) -> Regexes

fn cached_regexes() -> Regexes {
  memoize_regexes(OaspecNamingRegexes, compile_regexes)
}

fn compile_regexes() -> Regexes {
  // nolint: assert_ok_pattern -- regex literal cannot fail
  let assert Ok(word_separator) = regexp.from_string("[_\\-\\s./]+")
  // Word-split rule for camelCase / PascalCase / mixed input. The four
  // alternatives, in priority order:
  //
  //   1. `[A-Z]+(?=[A-Z][a-z])` — split before the trailing capital of
  //      an ALLCAPS run that's followed by a lower run (XMLParser →
  //      XML, Parser).
  //   2. `[A-Z]?[a-z]+[0-9]*` — a lower-cased word with an optional
  //      leading capital and an OPTIONAL trailing digit run (sha256 →
  //      sha256, getV2 → getV2's "v2" piece). The trailing-digit
  //      attachment (Issue #283) keeps `rev_b58` / `sha256` / `utf8` /
  //      `base64` / `oauth2` / `md5` as a single word in generated
  //      Gleam, matching the convention sqlode landed on in #480 and
  //      avoiding the `rev_b_58` / `sha_256` shapes that read like a
  //      division.
  //   3. `[A-Z]+[0-9]*` — an ALLCAPS word with the same optional
  //      trailing digit run (USER, ID2, UUID).
  //   4. `[0-9]+` — a leading or otherwise-unattached digit run
  //      (256sha → "256", "sha"). Only digits not absorbed by the
  //      preceding letter run land here; this preserves the
  //      digit→letter split (the standard convention is asymmetric).
  // nolint: assert_ok_pattern -- regex literal cannot fail
  let assert Ok(camel_case) =
    regexp.from_string(
      "([A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+[0-9]*|[A-Z]+[0-9]*|[0-9]+)",
    )
  // nolint: assert_ok_pattern -- regex literal cannot fail
  let assert Ok(underscore_before_caps) =
    regexp.from_string("([a-z0-9])([A-Z])")
  Regexes(word_separator:, camel_case:, underscore_before_caps:)
}

/// Convert a string to PascalCase for Gleam type names.
/// Examples: "pet_store" -> "PetStore", "get-user" -> "GetUser"
///
/// As with `to_snake_case`, leading `+`/`-` and digit-led results
/// are normalised (issue #352) so OpenAPI enum values like `+1`,
/// `-1`, or `404` produce valid Gleam variant names (`Plus1`,
/// `Minus1`, `N404`) instead of `1`, `1`, `404` — the latter would
/// be rejected by the parser at the type-constructor position.
///
/// Issue #494: `.` is rewritten to a `Dot` word boundary so that
/// real-world specs (Stripe) which declare `payment_intent.processing`
/// alongside `payment_intent_processing` produce distinct Gleam type
/// names (`PaymentIntentDotProcessing` vs `PaymentIntentProcessing`)
/// instead of colliding on `PaymentIntentProcessing`.
pub fn to_pascal_case(input: String) -> String {
  let re = cached_regexes()
  input
  |> rewrite_dot_segments
  |> rewrite_leading_signs
  |> split_words(re)
  |> list.map(capitalize)
  |> string.join("")
  |> ensure_letter_start_pascal
}

/// Pascal-case equivalent of `ensure_letter_start`: digit-led
/// results get an `N` prefix (instead of `n_`) so the result still
/// reads as a single PascalCase token (`404` → `N404`, not
/// `n_404` which would round-trip incorrectly through the snake/
/// pascal converters).
fn ensure_letter_start_pascal(input: String) -> String {
  case string.pop_grapheme(input) {
    Ok(#(first, _rest)) ->
      case is_digit(first) {
        True -> "N" <> input
        False -> input
      }
    // nolint: thrown_away_error -- pop_grapheme only fails on empty input; passing it through unchanged is correct here
    Error(_) -> input
  }
}

/// Convert a string to snake_case for Gleam function/variable names.
/// Examples: "PetStore" -> "pet_store", "getUserById" -> "get_user_by_id"
/// Gleam keywords are suffixed with _ to avoid syntax errors.
///
/// OpenAPI property names like `+1`, `-1` (GitHub's reaction counts)
/// or `404` (numeric keys) are not valid Gleam record field
/// identifiers — Gleam fields must start with `a-z`. The naming
/// pipeline therefore:
///   - rewrites a leading `+` to `plus_` and a leading `-` to
///     `minus_` so the sign is preserved as a readable prefix; and
///   - prepends `n_` when the result still starts with a digit
///     (e.g. `404` → `n_404`, `+1` → `plus_1`).
/// Without these the generator produced syntactically invalid Gleam
/// like `DiscussionReactions(1: Int, 1_2: Int, ...)` on the GitHub
/// REST API spec, where `+1` and `-1` both collapsed to `1` (issue
/// #352).
pub fn to_snake_case(input: String) -> String {
  let re = cached_regexes()
  let result =
    input
    |> rewrite_dot_segments
    |> rewrite_leading_signs
    |> insert_underscores_before_caps(re)
    |> split_words(re)
    |> list.map(string.lowercase)
    |> string.join("_")
    |> ensure_letter_start
  escape_keyword(result)
}

/// Suffix for the synthetic list decoder/function emitted alongside
/// every component schema (`decode_<schema>_list`, `<schema>_list`).
/// Returns the bare `_list` suffix when no collision exists, or the
/// disambiguated `_list_items` suffix when the spec also declares a
/// `<Schema>List` component schema (whose own decoder would otherwise
/// emit the same identifier and trip
/// `Duplicate definition: decode_<schema>_list` at `gleam build`
/// time). Issue #493 — the rename keeps the user-named `XxxList`
/// schema's natural decoder name and shifts the synthetic one,
/// since the user does not own upstream specs like Kubernetes /
/// Stripe and cannot rename.
/// Like `synthetic_list_suffix`, but compares in the Gleam-mapped
/// `<Schema>List` namespace via the precomputed component-type-names
/// set on the `Context`. Catches dashed / otherwise-spelled siblings
/// (e.g. `<base>-list`) that the raw-schema-name form misses, and
/// avoids rebuilding the mapped list per call.
pub fn synthetic_list_suffix_with_set(
  base_name: String,
  component_type_names: dict.Dict(String, Nil),
) -> String {
  let base_type_name = schema_to_type_name(base_name)
  use <- bool.guard(
    dict.has_key(component_type_names, base_type_name <> "List"),
    "_list_items",
  )
  "_list"
}

/// Compute the Gleam type name for an inline string-enum property,
/// disambiguating against existing component schema names so the
/// generated `pub type` does not collide with a same-named component
/// schema. Issue #492 — GitHub's OpenAPI spec declares
/// `code-scanning-variant-analysis` (with an inline `status` enum) AND
/// a separate `code-scanning-variant-analysis-status` component. Both
/// previously mapped to the Gleam type `CodeScanningVariantAnalysisStatus`,
/// producing a `Duplicate type definition` at `gleam build`.
///
/// Disambiguation appends a numeric suffix (`2`, `3`, ...) to the
/// inline enum's name when a component schema already claims the bare
/// name. The component schema keeps its natural name; the inline
/// enum yields, since the user does not own upstream specs and cannot
/// rename the component.
pub fn inline_enum_type_name(
  parent_name: String,
  prop_name: String,
  component_schema_names: List(String),
) -> String {
  let base = schema_to_type_name(parent_name) <> schema_to_type_name(prop_name)
  let component_type_names =
    list.map(component_schema_names, schema_to_type_name)
  case list.contains(component_type_names, base) {
    False -> base
    True -> bump_inline_enum_suffix(base, 2, component_type_names)
  }
}

/// Like `inline_enum_type_name`, but takes an already-mapped
/// component-type-name set as a `Dict(String, Nil)`. Collision check
/// is O(log N) per call and the per-name `schema_to_type_name` work
/// happens once at `Context` construction instead of being repeated
/// per inline-enum property — essential on specs with thousands of
/// component schemas.
pub fn inline_enum_type_name_with_set(
  parent_name: String,
  prop_name: String,
  component_type_names: dict.Dict(String, Nil),
) -> String {
  let base = schema_to_type_name(parent_name) <> schema_to_type_name(prop_name)
  case dict.has_key(component_type_names, base) {
    False -> base
    True -> bump_inline_enum_suffix_set(base, 2, component_type_names)
  }
}

fn bump_inline_enum_suffix(
  base: String,
  suffix: Int,
  taken: List(String),
) -> String {
  let candidate = base <> int.to_string(suffix)
  case list.contains(taken, candidate) {
    False -> candidate
    True -> bump_inline_enum_suffix(base, suffix + 1, taken)
  }
}

/// Disambiguate an enum constructor name against the set of
/// already-allocated component type names. Stripe's spec declares a
/// `source.type` enum whose values (`three_d_secure`, `wechat`, …)
/// each also appear as `source_type_<value>` component schemas, so
/// the naive `<EnumType><Value>` constructor name (e.g.
/// `SourceTypeThreeDSecure`) collides with the constructor of the
/// `SourceTypeThreeDSecure` record that `source_type_three_d_secure`
/// generates. When a collision is detected we suffix the variant
/// with `Variant`, then bump a numeric tail until the result is
/// unique. Returning the un-suffixed name when there is no collision
/// keeps the generated API stable for the common case.
pub fn dedup_enum_variant_name(
  base: String,
  component_type_names: dict.Dict(String, Nil),
) -> String {
  use <- bool.guard(!dict.has_key(component_type_names, base), base)
  bump_enum_variant_suffix(base <> "Variant", 0, component_type_names)
}

fn bump_enum_variant_suffix(
  candidate: String,
  suffix: Int,
  taken: dict.Dict(String, Nil),
) -> String {
  let next = case suffix {
    0 -> candidate
    n -> candidate <> int.to_string(n)
  }
  case dict.has_key(taken, next) {
    False -> next
    True -> bump_enum_variant_suffix(candidate, suffix + 1, taken)
  }
}

fn bump_inline_enum_suffix_set(
  base: String,
  suffix: Int,
  taken: dict.Dict(String, Nil),
) -> String {
  let candidate = base <> int.to_string(suffix)
  case dict.has_key(taken, candidate) {
    False -> candidate
    True -> bump_inline_enum_suffix_set(base, suffix + 1, taken)
  }
}

/// Replace `.` with `_dot_` so the dot survives the snake/Pascal
/// pipelines as a `Dot` word boundary instead of being treated as
/// the same separator class as `_` and `-`. Issue #494 — Stripe's
/// spec declares `payment_intent.processing` alongside
/// `payment_intent_processing`, and treating `.` as plain whitespace
/// (the prior behavior) collapsed both onto the same Gleam type
/// name. Encoding the dot keeps the two distinguishable while still
/// producing readable identifiers (`PaymentIntentDotProcessing`).
///
/// A literal `_dot_` already in the input is first escaped to
/// `_dot_literal_` so spec authors who happen to use `_dot_` in a
/// schema name still produce a name distinct from a sibling that
/// uses `.` at the same position (`a_dot_b` → `ADotLiteralB`,
/// `a.b` → `ADotB`).
fn rewrite_dot_segments(input: String) -> String {
  input
  |> string.replace("_dot_", "_dot_literal_")
  |> string.replace(".", "_dot_")
}

/// Map a leading `+` to `plus_` and a leading `-` to `minus_` so
/// `+1` / `-1` style property names survive the snake_case pipeline
/// as `plus_1` / `minus_1` instead of colliding on a bare `1`.
/// The body of the input is left untouched, so existing kebab-case
/// inputs (`kebab-case`) keep splitting on `-` as before.
fn rewrite_leading_signs(input: String) -> String {
  case string.pop_grapheme(input) {
    Ok(#("+", rest)) -> "plus_" <> rest
    Ok(#("-", rest)) -> "minus_" <> rest
    _ -> input
  }
}

/// Prepend `n_` if the first grapheme is a digit, so a numeric-led
/// result (`404`, `1_2` from a deduped `+1`/`-1`) becomes a valid
/// Gleam identifier (`n_404`, `n_1_2`). Empty strings are left
/// alone — that path is impossible from `to_snake_case` after
/// non-empty input, but the guard keeps the helper composable.
fn ensure_letter_start(input: String) -> String {
  case string.pop_grapheme(input) {
    Ok(#(first, _rest)) ->
      case is_digit(first) {
        True -> "n_" <> input
        False -> input
      }
    // nolint: thrown_away_error -- pop_grapheme only fails on empty input; passing it through unchanged is correct here
    Error(_) -> input
  }
}

/// True for the ten ASCII digit graphemes. We avoid `int.parse` here
/// because it accepts `+1`/`-1` and the goal is the bare digit test.
fn is_digit(grapheme: String) -> Bool {
  case grapheme {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

/// Gleam reserved keywords that cannot be used as identifiers.
fn escape_keyword(name: String) -> String {
  case name {
    "as"
    | "assert"
    | "auto"
    | "case"
    | "const"
    | "external"
    | "fn"
    | "if"
    | "import"
    | "let"
    | "opaque"
    | "panic"
    | "pub"
    | "test"
    | "todo"
    | "type"
    | "use" -> name <> "_"
    _ -> name
  }
}

/// Convert an OpenAPI operation ID to a valid Gleam function name.
pub fn operation_to_function_name(operation_id: String) -> String {
  operation_id
  |> to_snake_case
}

/// Convert an OpenAPI schema name to a valid Gleam type name.
pub fn schema_to_type_name(schema_name: String) -> String {
  schema_name
  |> to_pascal_case
}

/// Capitalize the first letter of a string.
pub fn capitalize(input: String) -> String {
  case string.pop_grapheme(input) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    // nolint: thrown_away_error -- pop_grapheme only fails on empty strings, in which case the input is already the correct result
    Error(_) -> input
  }
}

/// Split a string into words by common separators.
fn split_words(input: String, re: Regexes) -> List(String) {
  let parts = regexp.split(re.word_separator, input)
  parts
  |> list.flat_map(split_camel_case(_, re))
  |> list.filter(fn(s) { s != "" })
}

/// Split camelCase/PascalCase into separate words.
fn split_camel_case(input: String, re: Regexes) -> List(String) {
  let matches = regexp.scan(re.camel_case, input)
  case matches {
    [] -> [input]
    _ ->
      list.map(matches, fn(m) {
        let regexp.Match(content, ..) = m
        content
      })
  }
}

/// Insert underscores before capital letters in camelCase strings.
fn insert_underscores_before_caps(input: String, re: Regexes) -> String {
  regexp.replace(re.underscore_before_caps, input, "\\1_\\2")
}

/// Deduplicate a list of names by appending _2, _3, etc. to duplicates.
/// Preserves order. First occurrence keeps original name.
pub fn deduplicate_names(names: List(String)) -> List(String) {
  let #(result_rev, _) =
    list.fold(names, #([], dict.new()), fn(acc, name) {
      let #(result, counts) = acc
      case dict.get(counts, name) {
        // nolint: thrown_away_error -- dict.get Error simply means first occurrence; we register count 1 and keep the original name
        Error(_) -> {
          let counts = dict.insert(counts, name, 1)
          #([name, ..result], counts)
        }
        Ok(count) -> {
          let new_count = count + 1
          let unique_name = name <> "_" <> int.to_string(new_count)
          let counts = dict.insert(counts, name, new_count)
          #([unique_name, ..result], counts)
        }
      }
    })
  list.reverse(result_rev)
}
