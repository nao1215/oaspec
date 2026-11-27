//// Metamorphic relations over whole OpenAPI documents. Each relation
//// rewrites a fixture in a way that must not change what oaspec
//// generates, and checks that every generated file (path and content)
//// stays the same:
////
//// - the YAML document written as JSON. The two formats go through
////   different parsers (yay for YAML, OTP's `json` module for JSON), so
////   this is also a differential test of the two front ends,
//// - the top-level keys (`openapi`, `info`, `paths`, `components`, ...)
////   in a random order,
//// - `x-` extension keys added to the root and to `info`, which the
////   specification says tools may ignore.
////
//// The fixtures are every `test/fixtures/*.yaml` that oaspec generates
//// code for from the string alone (no external `$ref` files). Fixtures
//// that are rejected on the YAML path are error cases and are skipped;
//// the test fails if fewer than 50 fixtures are left, so a broken
//// filter cannot make it pass vacuously.

import gleam/dict
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import metamon
import metamon/generator
import oaspec/config
import oaspec/internal/generate
import oaspec/internal/openapi/parser
import simplifile
import yay

const fixture_dir = "test/fixtures"

type Case {
  Case(name: String, root: yay.Node, files: List(#(String, String)))
}

fn generated(
  parsed: Result(a, b),
  generate_from: fn(a) -> Result(List(#(String, String)), Nil),
) -> Result(List(#(String, String)), Nil) {
  case parsed {
    Ok(spec) -> generate_from(spec)
    Error(_) -> Error(Nil)
  }
}

fn generate_files(spec) -> Result(List(#(String, String)), Nil) {
  let cfg =
    config.Config(
      input: "spec.yaml",
      output_server: "./out/api",
      output_client: "./out/api",
      package: "api",
      mode: config.Both,
      validate: True,
      include: config.Include(tags: [], paths: []),
      handler_layout: config.SingleFile,
    )
  case generate.generate(spec, cfg) {
    Ok(summary) ->
      summary.files
      |> list.map(fn(file) { #(file.path, file.content) })
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> Ok
    Error(_) -> Error(Nil)
  }
}

fn from_yaml(text: String) -> Result(List(#(String, String)), Nil) {
  generated(parser.parse_string(text), generate_files)
}

fn from_json(text: String) -> Result(List(#(String, String)), Nil) {
  generated(parser.parse_json_string(text), generate_files)
}

fn load_cases() -> List(Case) {
  let assert Ok(names) = simplifile.read_directory(fixture_dir)
  names
  |> list.filter(fn(name) {
    string.ends_with(name, ".yaml") || string.ends_with(name, ".yml")
  })
  |> list.sort(string.compare)
  |> list.filter_map(fn(name) {
    let assert Ok(text) = simplifile.read(fixture_dir <> "/" <> name)
    use files <- result.try(from_yaml(text))
    use documents <- result.try(
      yay.parse_string(text) |> result.replace_error(Nil),
    )
    case documents, string.contains(text, "$ref: ./") {
      [yay.Document(root: yay.NodeMap(_) as root)], False ->
        Ok(Case(name:, root:, files:))
      _, _ -> Error(Nil)
    }
  })
}

fn cases() -> List(Case) {
  let found = load_cases()
  assert list.length(found) >= 50
  found
}

/// Mapping keys as JSON object keys. YAML reads `200:` as an integer
/// and `true:` as a boolean; a JSON key is always the string.
fn key_to_string(key: yay.Node) -> String {
  case key {
    yay.NodeStr(s) -> s
    yay.NodeInt(i) -> int.to_string(i)
    yay.NodeBool(True) -> "true"
    yay.NodeBool(False) -> "false"
    yay.NodeFloat(f) -> float.to_string(f)
    yay.NodeNil -> "null"
    yay.NodeSeq(_) | yay.NodeMap(_) -> panic as "collection as a mapping key"
  }
}

fn to_json(node: yay.Node) -> json.Json {
  case node {
    yay.NodeNil -> json.null()
    yay.NodeStr(s) -> json.string(s)
    yay.NodeBool(b) -> json.bool(b)
    yay.NodeInt(i) -> json.int(i)
    yay.NodeFloat(f) -> json.float(f)
    yay.NodeSeq(items) -> json.array(items, to_json)
    yay.NodeMap(pairs) ->
      json.object(
        list.map(pairs, fn(pair) { #(key_to_string(pair.0), to_json(pair.1)) }),
      )
  }
}

/// Assert that the rewritten document generates the same files. On a
/// difference the assertion message names the fixture and the files.
fn assert_same_output(
  c: Case,
  rewritten: Result(List(#(String, String)), Nil),
) -> Nil {
  let assert Ok(files) = rewritten
    as { c.name <> ": the rewritten document is rejected" }
  let before = dict.from_list(c.files)
  let changed =
    files
    |> list.filter(fn(file) { dict.get(before, file.0) != Ok(file.1) })
    |> list.map(fn(file) { file.0 })
  let assert [] = changed
    as {
      c.name
      <> ": generated files differ after the rewrite: "
      <> string.join(changed, ", ")
    }
  assert list.length(files) == list.length(c.files)
    as { c.name <> ": the rewrite changes the number of generated files" }
}

pub fn json_form_generates_the_same_code_test() -> Nil {
  list.each(cases(), fn(c) {
    assert_same_output(c, from_json(json.to_string(to_json(c.root))))
  })
}

pub fn top_level_key_order_does_not_change_the_code_test() -> Nil {
  let all = cases()
  metamon.forall_with(
    metamon.Config(..metamon.default_config(), runs: 5),
    generator.int(generator.range(from: 0, to: 1000)),
    fn(seed) {
      list.each(all, fn(c) {
        let assert yay.NodeMap(pairs) = c.root
        let shuffled =
          pairs
          |> list.index_map(fn(pair, i) { #({ i * 7919 + seed } % 1009, pair) })
          |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
          |> list.map(fn(pair) { pair.1 })
        assert_same_output(
          c,
          from_json(json.to_string(to_json(yay.NodeMap(shuffled)))),
        )
      })
    },
  )
}

pub fn extension_keys_do_not_change_the_code_test() -> Nil {
  let extension =
    yay.NodeMap([
      #(yay.NodeStr("owner"), yay.NodeStr("metamorphic test")),
      #(yay.NodeStr("tags"), yay.NodeSeq([yay.NodeStr("a"), yay.NodeInt(1)])),
    ])
  list.each(cases(), fn(c) {
    let assert yay.NodeMap(pairs) = c.root
    let with_extensions =
      pairs
      |> list.map(fn(pair) {
        case pair {
          #(yay.NodeStr("info"), yay.NodeMap(info)) -> #(
            pair.0,
            yay.NodeMap(
              list.append(info, [#(yay.NodeStr("x-oaspec-test"), extension)]),
            ),
          )
          _ -> pair
        }
      })
      |> list.append([#(yay.NodeStr("x-oaspec-test"), extension)])
    assert_same_output(
      c,
      from_json(json.to_string(to_json(yay.NodeMap(with_extensions)))),
    )
  })
}
