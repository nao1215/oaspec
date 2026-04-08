import gleam/dict
import gleam/int
import gleam/list
import gleam/regexp
import gleam/string

/// Convert a string to PascalCase for Gleam type names.
/// Examples: "pet_store" -> "PetStore", "get-user" -> "GetUser"
pub fn to_pascal_case(input: String) -> String {
  input
  |> split_words
  |> list.map(capitalize)
  |> string.join("")
}

/// Convert a string to snake_case for Gleam function/variable names.
/// Examples: "PetStore" -> "pet_store", "getUserById" -> "get_user_by_id"
/// Gleam keywords are suffixed with _ to avoid syntax errors.
pub fn to_snake_case(input: String) -> String {
  let result =
    input
    |> insert_underscores_before_caps
    |> split_words
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

/// Convert an OpenAPI schema name to a valid Gleam module name.
pub fn to_module_name(name: String) -> String {
  name
  |> to_snake_case
}

/// Capitalize the first letter of a string.
pub fn capitalize(input: String) -> String {
  case string.pop_grapheme(input) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    Error(_) -> input
  }
}

/// Split a string into words by common separators.
fn split_words(input: String) -> List(String) {
  let assert Ok(re) = regexp.from_string("[_\\-\\s./]+")
  let parts = regexp.split(re, input)
  parts
  |> list.flat_map(split_camel_case)
  |> list.filter(fn(s) { s != "" })
}

/// Split camelCase/PascalCase into separate words.
fn split_camel_case(input: String) -> List(String) {
  let assert Ok(re) =
    regexp.from_string("([A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|[0-9]+)")
  let matches = regexp.scan(re, input)
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
fn insert_underscores_before_caps(input: String) -> String {
  let assert Ok(re) = regexp.from_string("([a-z0-9])([A-Z])")
  regexp.replace(re, input, "\\1_\\2")
}

/// Deduplicate a list of names by appending _2, _3, etc. to duplicates.
/// Preserves order. First occurrence keeps original name.
pub fn deduplicate_names(names: List(String)) -> List(String) {
  let #(result_rev, _) =
    list.fold(names, #([], dict.new()), fn(acc, name) {
      let #(result, counts) = acc
      case dict.get(counts, name) {
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
