import gleam/list
import gleeunit
import gleeunit/should
import oaspec/internal/util/naming

pub fn main() {
  gleeunit.main()
}

/// The complete list of Gleam reserved keywords that naming.escape_keyword
/// must protect against. Kept in sync with the `case` branch in
/// src/oaspec/internal/util/naming.gleam. When a new keyword is added there, add
/// it here too — the whole-list assertions below depend on this being
/// exhaustive, not hand-picked.
const gleam_keywords: List(String) = [
  "as", "assert", "auto", "case", "const", "external", "fn", "if", "import",
  "let", "opaque", "panic", "pub", "test", "todo", "type", "use",
]

// naming.to_snake_case tests
// ===================================================================

pub fn naming_to_snake_case_all_keywords_escaped_test() {
  list.each(gleam_keywords, fn(kw) {
    naming.to_snake_case(kw)
    |> should.equal(kw <> "_")
  })
}

pub fn naming_to_snake_case_compound_with_keyword_not_escaped_test() {
  // A compound identifier that merely contains a keyword is already a
  // valid Gleam identifier, so it must NOT get a stray underscore.
  naming.to_snake_case("useItem")
  |> should.equal("use_item")
}

pub fn naming_to_snake_case_compound_producing_keyword_escaped_test() {
  // When normalization collapses to a single keyword, escape must kick
  // in. "Type" -> "type" -> "type_".
  naming.to_snake_case("Type")
  |> should.equal("type_")
}

pub fn naming_to_snake_case_non_keyword_unaffected_test() {
  naming.to_snake_case("listPets")
  |> should.equal("list_pets")
}

// Issue #283: letter+digit identifiers stay together in generated
// Gleam, matching the convention sqlode landed on in nao1215/sqlode#480.
// `rev_b58` keeps its trailing digits attached to the preceding letter
// run; the digit→letter direction (`256sha`) still splits because the
// rule is asymmetric.
pub fn naming_to_snake_case_keeps_letter_digit_suffix_attached_test() {
  naming.to_snake_case("rev_b58") |> should.equal("rev_b58")
  naming.to_snake_case("sha256") |> should.equal("sha256")
  naming.to_snake_case("utf8") |> should.equal("utf8")
  naming.to_snake_case("base64") |> should.equal("base64")
  naming.to_snake_case("oauth2") |> should.equal("oauth2")
  naming.to_snake_case("md5") |> should.equal("md5")
  naming.to_snake_case("ipv4") |> should.equal("ipv4")
  naming.to_snake_case("port_8080") |> should.equal("port_8080")
  naming.to_snake_case("iso8601") |> should.equal("iso8601")
}

pub fn naming_to_snake_case_pascal_with_letter_digit_suffix_test() {
  naming.to_snake_case("Sha256Hash") |> should.equal("sha256_hash")
  naming.to_snake_case("GetV2Author") |> should.equal("get_v2_author")
  naming.to_snake_case("OAuth2Token") |> should.equal("o_auth2_token")
}

pub fn naming_to_snake_case_digit_letter_still_splits_test() {
  // Digit→letter remains a split point — only letter→digit is glued.
  // The leading-digit guard then prepends `n_` so the result is a
  // valid Gleam identifier (issue #352).
  naming.to_snake_case("256sha") |> should.equal("n_256_sha")
}

pub fn naming_to_snake_case_leading_plus_becomes_plus_prefix_test() {
  // GitHub's `+1` reaction key would otherwise collapse to `"1"`,
  // colliding with `-1` and producing invalid identifiers — see #352.
  naming.to_snake_case("+1") |> should.equal("plus_1")
  naming.to_snake_case("+up_vote") |> should.equal("plus_up_vote")
}

pub fn naming_to_snake_case_leading_minus_becomes_minus_prefix_test() {
  // The mirror of the `+` case so `+1` and `-1` end up at distinct
  // identifiers (`plus_1` vs `minus_1`) instead of both collapsing
  // to `1` and getting deduped to `1` / `1_2`.
  naming.to_snake_case("-1") |> should.equal("minus_1")
}

pub fn naming_to_snake_case_leading_digit_gets_n_prefix_test() {
  // Pure-numeric property names are valid in JSON but invalid as
  // Gleam record fields. The pipeline prepends `n_` so they
  // round-trip cleanly. `2fa` lands at `n_2_fa` because the camel-
  // splitter treats the digit run as its own token and `fa` as a
  // separate lower-case word — the prefix only cares about the
  // first grapheme being a digit.
  naming.to_snake_case("404") |> should.equal("n_404")
  naming.to_snake_case("2fa") |> should.equal("n_2_fa")
}

pub fn naming_to_pascal_case_leading_plus_becomes_plus_prefix_test() {
  naming.to_pascal_case("+1") |> should.equal("Plus1")
}

pub fn naming_to_pascal_case_leading_minus_becomes_minus_prefix_test() {
  naming.to_pascal_case("-1") |> should.equal("Minus1")
}

pub fn naming_to_pascal_case_leading_digit_gets_n_prefix_test() {
  naming.to_pascal_case("404") |> should.equal("N404")
}

// naming.operation_to_function_name tests
// ===================================================================

pub fn naming_operation_to_function_name_all_keywords_escaped_test() {
  list.each(gleam_keywords, fn(kw) {
    naming.operation_to_function_name(kw)
    |> should.equal(kw <> "_")
  })
}

pub fn naming_operation_to_function_name_mixed_case_keyword_escaped_test() {
  // operationId: "Let" should still resolve to `let_`.
  naming.operation_to_function_name("Let")
  |> should.equal("let_")
}

// naming.schema_to_type_name tests
// ===================================================================
// Gleam reserves only lowercase words, so PascalCase type names never
// collide. These assertions lock that invariant in place so a future
// refactor cannot silently start over-escaping type names.

pub fn naming_schema_to_type_name_keyword_becomes_pascal_test() {
  // Every keyword is a single lowercase word, so the expected PascalCase
  // is just the keyword with its first character capitalized. Asserting
  // exact equality (rather than "not empty / not the escape suffix")
  // catches silent regressions where the pipeline starts mangling type
  // names — e.g. accidentally emitting `Type_` or `TYPE`.
  list.each(gleam_keywords, fn(kw) {
    let expected = naming.capitalize(kw)
    naming.schema_to_type_name(kw)
    |> should.equal(expected)
  })
}

// Issue #494: a `.` in the schema name is encoded as a `Dot` word
// boundary so the dot survives the snake/Pascal pipelines. Stripe's
// `payment_intent.processing` and `payment_intent_processing` would
// otherwise both map to `PaymentIntentProcessing` and trigger the
// `validate_unique_schema_names` hard error.

pub fn naming_to_pascal_case_dot_becomes_dot_word_boundary_test() {
  naming.to_pascal_case("payment_intent.processing")
  |> should.equal("PaymentIntentDotProcessing")
  naming.to_pascal_case("payment_intent_processing")
  |> should.equal("PaymentIntentProcessing")
  naming.to_pascal_case("billing.alert.triggered")
  |> should.equal("BillingDotAlertDotTriggered")
  naming.to_pascal_case("billing.alert_triggered")
  |> should.equal("BillingDotAlertTriggered")
}

pub fn naming_to_snake_case_dot_becomes_dot_word_boundary_test() {
  naming.to_snake_case("payment_intent.processing")
  |> should.equal("payment_intent_dot_processing")
  naming.to_snake_case("payment_intent_processing")
  |> should.equal("payment_intent_processing")
}

// Edge cases for the `.` → `_dot_` encoding (CodeRabbit on PR #499).
// Behavior chosen for predictability; documenting it locks in the
// shape so future refactors can't silently drift.

pub fn naming_dot_encoding_consecutive_dots_test() {
  // `foo..bar` becomes two consecutive `_dot_` segments. The
  // word_separator regex collapses runs of `_`/`.`/etc. so the
  // PascalCase output reads as `FooDotDotBar`.
  naming.to_pascal_case("foo..bar") |> should.equal("FooDotDotBar")
  naming.to_snake_case("foo..bar") |> should.equal("foo_dot_dot_bar")
}

pub fn naming_dot_encoding_leading_and_trailing_dot_test() {
  // A leading `.` produces a leading `Dot` word; a trailing `.`
  // produces a trailing `Dot` word. Both still PascalCase and
  // snake_case to valid Gleam identifiers.
  naming.to_pascal_case(".foo") |> should.equal("DotFoo")
  naming.to_snake_case(".foo") |> should.equal("dot_foo")
  naming.to_pascal_case("foo.") |> should.equal("FooDot")
  naming.to_snake_case("foo.") |> should.equal("foo_dot")
}

pub fn naming_dot_encoding_literal_underscore_dot_underscore_test() {
  // A literal `_dot_` already in the input is escaped to
  // `_dot_literal_` so a spec that authored `a_dot_b` and a sibling
  // `a.b` produce distinct Gleam type names.
  naming.to_pascal_case("a_dot_b") |> should.equal("ADotLiteralB")
  naming.to_pascal_case("a.b") |> should.equal("ADotB")
  naming.to_snake_case("a_dot_b") |> should.equal("a_dot_literal_b")
  naming.to_snake_case("a.b") |> should.equal("a_dot_b")
}

// Issue #492: inline-enum disambiguation against component schema names.

pub fn naming_inline_enum_type_name_no_collision_returns_base_test() {
  naming.inline_enum_type_name("foo", "status", ["bar", "baz"])
  |> should.equal("FooStatus")
}

pub fn naming_inline_enum_type_name_collision_appends_numeric_suffix_test() {
  naming.inline_enum_type_name("foo", "status", ["foo_status"])
  |> should.equal("FooStatus2")
}

pub fn naming_inline_enum_type_name_chained_collision_bumps_suffix_test() {
  naming.inline_enum_type_name("foo", "status", ["foo_status", "foo_status_2"])
  |> should.equal("FooStatus3")
}
