//// metamon property tests for `oaspec/internal/util/naming`. Pin
//// the algebraic invariants the public naming helpers
//// (`to_pascal_case`, `to_snake_case`, `capitalize`,
//// `schema_to_type_name`,
//// `operation_to_function_name`) are documented to hold so a future
//// refactor of the regex-driven word splitter surfaces a regression
//// here instead of being caught by the codegen golden tests.

import gleam/string
import metamon
import metamon/generator
import oaspec/internal/util/naming

// ASCII letters, `lo` to `hi` of them.
fn alpha(lo: Int, hi: Int) -> generator.Generator(String) {
  generator.string(
    of: generator.Alphabetic,
    length: generator.range(from: lo, to: hi),
  )
}

// ASCII letters and digits, `lo` to `hi` of them.
fn alphanumeric(lo: Int, hi: Int) -> generator.Generator(String) {
  generator.string(
    of: generator.Alphanumeric,
    length: generator.range(from: lo, to: hi),
  )
}

// A "word-shaped" string with a leading letter so the camelCase
// splitter sees a recognisable token. Restricted to ASCII letters
// and digits so the case-folding round-trips work portably.
fn word_generator() -> generator.Generator(String) {
  alphanumeric(1, 8)
}

// The first grapheme of `result` is uppercase, or `result` is empty.
fn assert_starts_uppercase_or_empty(result: String) -> Nil {
  case string.pop_grapheme(result) {
    Ok(#(first, _)) -> {
      assert first == string.uppercase(first)
    }
    Error(Nil) -> {
      assert result == ""
    }
  }
}

// ---------- to_pascal_case ----------

pub fn to_pascal_case_is_idempotent_test() {
  metamon.forall(word_generator(), fn(input) {
    let once = naming.to_pascal_case(input)
    let twice = naming.to_pascal_case(once)
    assert once == twice
  })
}

pub fn to_pascal_case_starts_with_uppercase_for_alpha_input_test() {
  // Pascal case starts every word with a capital letter, so the
  // first character of a non-empty alpha input must be uppercase.
  metamon.forall(alpha(1, 8), fn(input) {
    assert_starts_uppercase_or_empty(naming.to_pascal_case(input))
  })
}

pub fn to_pascal_case_drops_separators_test() {
  // Snake / kebab / dot / slash separators must not survive into
  // the pascal-case output — they are the word-split signal.
  metamon.forall(
    generator.list_of(word_generator(), length: generator.range(from: 1, to: 4)),
    fn(words) {
      let snake = naming.to_pascal_case(string.join(words, "_"))
      let kebab = naming.to_pascal_case(string.join(words, "-"))
      let dot = naming.to_pascal_case(string.join(words, "."))
      assert !string.contains(snake, "_")
      assert !string.contains(kebab, "-")
      assert !string.contains(dot, ".")
    },
  )
}

// ---------- to_snake_case ----------

pub fn to_snake_case_is_idempotent_test() {
  metamon.forall(word_generator(), fn(input) {
    let once = naming.to_snake_case(input)
    let twice = naming.to_snake_case(once)
    assert once == twice
  })
}

pub fn to_snake_case_has_no_uppercase_test() {
  metamon.forall(alpha(0, 8), fn(input) {
    let result = naming.to_snake_case(input)
    assert result == string.lowercase(result)
  })
}

pub fn to_snake_case_drops_kebab_and_dot_separators_test() {
  metamon.forall(
    generator.list_of(alpha(1, 6), length: generator.range(from: 1, to: 3)),
    fn(words) {
      let kebab = naming.to_snake_case(string.join(words, "-"))
      let dot = naming.to_snake_case(string.join(words, "."))
      assert !string.contains(kebab, "-")
      assert !string.contains(dot, ".")
    },
  )
}

// ---------- capitalize ----------

pub fn capitalize_preserves_length_test() {
  metamon.forall(alphanumeric(0, 8), fn(input) {
    assert string.length(naming.capitalize(input)) == string.length(input)
  })
}

pub fn capitalize_first_grapheme_is_uppercase_test() {
  metamon.forall(alpha(1, 8), fn(input) {
    let assert Ok(#(first, _)) = string.pop_grapheme(naming.capitalize(input))
    assert first == string.uppercase(first)
  })
}

pub fn capitalize_empty_string_test() {
  assert naming.capitalize("") == ""
}

pub fn capitalize_is_idempotent_test() {
  metamon.forall(alpha(0, 8), fn(input) {
    assert naming.capitalize(naming.capitalize(input))
      == naming.capitalize(input)
  })
}

// ---------- schema_to_type_name / operation_to_function_name ----------

pub fn schema_to_type_name_is_pascal_case_test() {
  // Generated Gleam type names start with a capital letter.
  metamon.forall(alpha(1, 8), fn(name) {
    assert_starts_uppercase_or_empty(naming.schema_to_type_name(name))
  })
}

pub fn operation_to_function_name_is_snake_case_test() {
  metamon.forall(alphanumeric(1, 8), fn(operation_id) {
    let result = naming.operation_to_function_name(operation_id)
    // Gleam function names never contain uppercase letters.
    assert result == string.lowercase(result)
  })
}
