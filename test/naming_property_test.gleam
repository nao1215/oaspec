//// metamon property tests for `oaspec/internal/util/naming`. Pin
//// the algebraic invariants the public naming helpers
//// (`to_pascal_case`, `to_snake_case`, `capitalize`,
//// `deduplicate_names`, `schema_to_type_name`,
//// `operation_to_function_name`) are documented to hold so a future
//// refactor of the regex-driven word splitter surfaces a regression
//// here instead of being caught by the codegen golden tests.

import gleam/list
import gleam/set
import gleam/string
import metamon
import metamon/generator
import metamon/generator/range
import oaspec/internal/util/naming

// A "word-shaped" string with a leading letter so the camelCase
// splitter sees a recognisable token. Restricted to ASCII letters
// and digits so the case-folding round-trips work portably.
fn word_generator() -> generator.Generator(String) {
  generator.string_alphanumeric(range.constant(1, 8))
}

// ---------- to_pascal_case ----------

pub fn to_pascal_case_is_idempotent_test() {
  metamon.forall(word_generator(), fn(input) {
    let once = naming.to_pascal_case(input)
    let twice = naming.to_pascal_case(once)
    once == twice
  })
}

pub fn to_pascal_case_starts_with_uppercase_for_alpha_input_test() {
  // Pascal case starts every word with a capital letter, so the
  // first character of a non-empty alpha input must be uppercase.
  metamon.forall(generator.string_alpha(range.constant(1, 8)), fn(input) {
    let result = naming.to_pascal_case(input)
    case string.pop_grapheme(result) {
      Ok(#(first, _)) -> first == string.uppercase(first)
      Error(Nil) -> result == ""
    }
  })
}

pub fn to_pascal_case_drops_separators_test() {
  // Snake / kebab / dot / slash separators must not survive into
  // the pascal-case output — they are the word-split signal.
  metamon.forall(
    generator.list_of(word_generator(), range.constant(1, 4)),
    fn(words) {
      let snake_input = string.join(words, "_")
      let kebab_input = string.join(words, "-")
      let dot_input = string.join(words, ".")
      let snake = naming.to_pascal_case(snake_input)
      let kebab = naming.to_pascal_case(kebab_input)
      let dot = naming.to_pascal_case(dot_input)
      !string.contains(snake, "_")
      && !string.contains(kebab, "-")
      && !string.contains(dot, ".")
    },
  )
}

// ---------- to_snake_case ----------

pub fn to_snake_case_is_idempotent_test() {
  metamon.forall(word_generator(), fn(input) {
    let once = naming.to_snake_case(input)
    let twice = naming.to_snake_case(once)
    once == twice
  })
}

pub fn to_snake_case_has_no_uppercase_test() {
  metamon.forall(generator.string_alpha(range.constant(0, 8)), fn(input) {
    let result = naming.to_snake_case(input)
    result == string.lowercase(result)
  })
}

pub fn to_snake_case_drops_kebab_and_dot_separators_test() {
  metamon.forall(
    generator.list_of(
      generator.string_alpha(range.constant(1, 6)),
      range.constant(1, 3),
    ),
    fn(words) {
      let kebab_input = string.join(words, "-")
      let dot_input = string.join(words, ".")
      let kebab = naming.to_snake_case(kebab_input)
      let dot = naming.to_snake_case(dot_input)
      !string.contains(kebab, "-") && !string.contains(dot, ".")
    },
  )
}

// ---------- capitalize ----------

pub fn capitalize_preserves_length_test() {
  metamon.forall(generator.string_alphanumeric(range.constant(0, 8)), fn(input) {
    string.length(naming.capitalize(input)) == string.length(input)
  })
}

pub fn capitalize_first_grapheme_is_uppercase_test() {
  metamon.forall(generator.string_alpha(range.constant(1, 8)), fn(input) {
    case string.pop_grapheme(naming.capitalize(input)) {
      Ok(#(first, _)) -> first == string.uppercase(first)
      Error(Nil) -> False
    }
  })
}

pub fn capitalize_empty_string_test() {
  assert naming.capitalize("") == ""
}

pub fn capitalize_is_idempotent_test() {
  metamon.forall(generator.string_alpha(range.constant(0, 8)), fn(input) {
    naming.capitalize(naming.capitalize(input)) == naming.capitalize(input)
  })
}

// ---------- deduplicate_names ----------

pub fn deduplicate_names_preserves_length_test() {
  metamon.forall(
    generator.list_of(word_generator(), range.constant(0, 8)),
    fn(names) {
      list.length(naming.deduplicate_names(names)) == list.length(names)
    },
  )
}

pub fn deduplicate_names_yields_unique_names_test() {
  metamon.forall(
    generator.list_of(word_generator(), range.constant(0, 6)),
    fn(names) {
      let result = naming.deduplicate_names(names)
      list.length(result) == set.size(set.from_list(result))
    },
  )
}

pub fn deduplicate_names_first_occurrence_unchanged_test() {
  // The doc-comment promises "first occurrence keeps original name".
  metamon.forall(
    generator.list_of(word_generator(), range.constant(1, 6)),
    fn(names) {
      let unique_first = list.unique(names)
      let result = naming.deduplicate_names(names)
      // Every original name still appears in the deduped output (as
      // the first occurrence).
      list.all(unique_first, fn(name) { list.contains(result, name) })
    },
  )
}

pub fn deduplicate_names_already_unique_is_identity_test() {
  metamon.forall(
    generator.list_of(word_generator(), range.constant(0, 6)),
    fn(names) {
      let unique = list.unique(names)
      naming.deduplicate_names(unique) == unique
    },
  )
}

pub fn deduplicate_names_empty_is_empty_test() {
  assert naming.deduplicate_names([]) == []
}

// ---------- schema_to_type_name / operation_to_function_name ----------

pub fn schema_to_type_name_is_pascal_case_test() {
  // Generated Gleam type names start with a capital letter.
  metamon.forall(generator.string_alpha(range.constant(1, 8)), fn(name) {
    let result = naming.schema_to_type_name(name)
    case string.pop_grapheme(result) {
      Ok(#(first, _)) -> first == string.uppercase(first)
      Error(Nil) -> result == ""
    }
  })
}

pub fn operation_to_function_name_is_snake_case_test() {
  metamon.forall(
    generator.string_alphanumeric(range.constant(1, 8)),
    fn(operation_id) {
      let result = naming.operation_to_function_name(operation_id)
      // Gleam function names never contain uppercase letters.
      result == string.lowercase(result)
    },
  )
}
