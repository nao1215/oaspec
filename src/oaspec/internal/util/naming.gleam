import gleam/dict
import gleam/int
import gleam/list
import gleam/regexp.{type Regexp}
import gleam/string

/// Pre-compiled regexes used by naming functions.
/// Compiled once per public function call instead of on every internal call.
type Regexes {
  Regexes(
    word_separator: Regexp,
    camel_case: Regexp,
    underscore_before_caps: Regexp,
  )
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
pub fn to_pascal_case(input: String) -> String {
  let re = compile_regexes()
  input
  |> split_words(re)
  |> list.map(capitalize)
  |> string.join("")
}

/// Convert a string to snake_case for Gleam function/variable names.
/// Examples: "PetStore" -> "pet_store", "getUserById" -> "get_user_by_id"
/// Gleam keywords are suffixed with _ to avoid syntax errors.
pub fn to_snake_case(input: String) -> String {
  let re = compile_regexes()
  let result =
    input
    |> insert_underscores_before_caps(re)
    |> split_words(re)
    |> list.map(string.lowercase)
    |> string.join("_")
  escape_keyword(result)
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
