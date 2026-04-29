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
  naming.to_snake_case("256sha") |> should.equal("256_sha")
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
