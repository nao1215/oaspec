import gleam/string
import gleeunit
import gleeunit/should
import oaspec/internal/openapi/diagnostic_format
import oaspec/openapi/diagnostic

pub fn main() {
  gleeunit.main()
}

// ====================================================================
// Issue #414: pin diagnostic.to_short_string and diagnostic.to_string
// shape per code variant. These strings leak to the CLI and a format
// regression was previously invisible to the test suite.
// ====================================================================

pub fn to_short_string_file_error_test() {
  let diag = diagnostic.file_error(detail: "file not found: spec.yaml")
  diagnostic.to_short_string(diag)
  |> should.equal("file not found: spec.yaml")
}

pub fn to_short_string_yaml_error_with_loc_test() {
  let diag =
    diagnostic.yaml_error(
      detail: "unexpected token",
      loc: diagnostic.SourceLoc(line: 4, column: 7),
    )
  diagnostic.to_short_string(diag)
  |> should.equal("unexpected token (line 4, column 7)")
}

pub fn to_short_string_yaml_error_no_loc_test() {
  let diag =
    diagnostic.yaml_error(detail: "empty document", loc: diagnostic.NoSourceLoc)
  diagnostic.to_short_string(diag)
  |> should.equal("empty document")
}

pub fn to_short_string_missing_field_test() {
  let diag =
    diagnostic.missing_field(
      path: "paths.~1pets.get",
      field: "responses",
      loc: diagnostic.NoSourceLoc,
    )
  let rendered = diagnostic.to_short_string(diag)
  rendered
  |> should.equal(
    "Missing required field 'responses' at GET /pets. Check your OpenAPI spec structure.",
  )
}

pub fn to_short_string_invalid_value_test() {
  let diag =
    diagnostic.invalid_value(
      path: "paths.~1pets.post.requestBody",
      detail: "content type must be a string",
      loc: diagnostic.NoSourceLoc,
    )
  let rendered = diagnostic.to_short_string(diag)
  rendered
  |> should.equal(
    "Invalid value at POST /pets, requestBody: content type must be a string",
  )
}

pub fn to_string_yaml_error_full_format_test() {
  // Full to_string should include phase prefix, severity, message, and
  // SourceLoc trailer. yaml_error has no pointer so the "at ..." chunk
  // is absent.
  let diag =
    diagnostic.yaml_error(
      detail: "boom",
      loc: diagnostic.SourceLoc(line: 1, column: 2),
    )
  diagnostic.to_string(diag)
  |> should.equal("[Parse] Error: boom (line 1, column 2)")
}

pub fn to_string_missing_field_includes_pointer_and_hint_test() {
  let diag =
    diagnostic.missing_field(
      path: "components.schemas.Pet",
      field: "type",
      loc: diagnostic.NoSourceLoc,
    )
  let rendered = diagnostic.to_string(diag)
  // Phase + severity + pointer + message + hint must all appear.
  rendered |> string.contains("[Parse] Error") |> should.be_true()
  rendered |> string.contains("at components.schemas.Pet") |> should.be_true()
  rendered
  |> string.contains("Missing required field: type")
  |> should.be_true()
  rendered
  |> string.contains("Check your OpenAPI spec structure.")
  |> should.be_true()
}

// --- empty / root ---------------------------------------------------

pub fn empty_pointer_renders_root_test() {
  diagnostic_format.pointer_to_human("")
  |> should.equal("root")
}

// --- paths: parameters ---------------------------------------------

pub fn path_parameter_dotted_test() {
  diagnostic_format.pointer_to_human("paths.~1pets.get.parameters.0")
  |> should.equal("GET /pets, parameter #0")
}

pub fn path_parameter_json_pointer_test() {
  diagnostic_format.pointer_to_human("#/paths/~1pets/get/parameters/0")
  |> should.equal("GET /pets, parameter #0")
}

pub fn path_parameter_with_tail_test() {
  diagnostic_format.pointer_to_human("paths.~1pets.get.parameters.0.schema")
  |> should.equal("GET /pets, parameter #0 (schema)")
}

// --- paths: requestBody --------------------------------------------

pub fn path_request_body_test() {
  diagnostic_format.pointer_to_human("paths.~1pets.post.requestBody")
  |> should.equal("POST /pets, requestBody")
}

pub fn path_request_body_with_tail_test() {
  diagnostic_format.pointer_to_human(
    "paths.~1pets.post.requestBody.content.application~1json",
  )
  |> should.equal("POST /pets, requestBody (content.application/json)")
}

// --- paths: responses -----------------------------------------------

pub fn path_response_test() {
  diagnostic_format.pointer_to_human("paths.~1pets.get.responses.200")
  |> should.equal("GET /pets, response 200")
}

pub fn path_response_with_tail_test() {
  diagnostic_format.pointer_to_human(
    "paths.~1pets.get.responses.404.content.application~1json.schema",
  )
  |> should.equal("GET /pets, response 404 (content.application/json.schema)")
}

// --- paths: bare method ---------------------------------------------

pub fn path_method_only_test() {
  diagnostic_format.pointer_to_human("paths.~1pets.get")
  |> should.equal("GET /pets")
}

pub fn path_method_with_tail_test() {
  diagnostic_format.pointer_to_human("paths.~1pets.get.summary")
  |> should.equal("GET /pets (summary)")
}

// --- components -----------------------------------------------------

pub fn components_schemas_test() {
  diagnostic_format.pointer_to_human("components.schemas.Pet")
  |> should.equal("schemas.Pet")
}

pub fn components_schemas_with_tail_test() {
  diagnostic_format.pointer_to_human("components.schemas.Pet.properties.name")
  |> should.equal("schemas.Pet (properties.name)")
}

pub fn components_parameters_test() {
  diagnostic_format.pointer_to_human("components.parameters.PetId")
  |> should.equal("parameters.PetId")
}

pub fn components_responses_test() {
  diagnostic_format.pointer_to_human("components.responses.ErrorResponse")
  |> should.equal("responses.ErrorResponse")
}

pub fn components_request_bodies_test() {
  diagnostic_format.pointer_to_human("components.requestBodies.CreatePetBody")
  |> should.equal("requestBodies.CreatePetBody")
}

pub fn components_other_kind_test() {
  // Unrecognised component kinds still render as "<kind>.<name>"
  diagnostic_format.pointer_to_human("components.headers.XRateLimit")
  |> should.equal("headers.XRateLimit")
}

// --- escape decoding ------------------------------------------------

pub fn tilde_zero_unescaped_test() {
  // `~0` decodes to `~`
  diagnostic_format.pointer_to_human("paths.~1a~0b.get")
  |> should.equal("GET /a~b")
}

pub fn escape_order_preserves_tilde_one_test() {
  // `~01` must decode to `~1`, NOT `/1` — `~1` is processed before `~0`.
  diagnostic_format.pointer_to_human("components.schemas.a~01b")
  |> should.equal("schemas.a~1b")
}

// --- fallback -------------------------------------------------------

pub fn unknown_shape_falls_back_to_decoded_pointer_test() {
  diagnostic_format.pointer_to_human("foo.bar.baz")
  |> should.equal("foo.bar.baz")
}

pub fn slash_form_unknown_shape_test() {
  diagnostic_format.pointer_to_human("#/foo/bar")
  |> should.equal("foo.bar")
}

// --- deep-nest fidelity --------------------------------------------
// `with_tail` joins every segment past the recognised prefix with `.`
// — verbatim, no truncation, no info loss. These tests pin that
// invariant so a future "shorten long tails" change does not silently
// drop the segment that points at the actual broken field. Without
// these, a regression that prints "schemas.Order (properties...)"
// instead of the full path would slip past the suite.

pub fn components_schemas_deep_nested_tail_preserved_test() {
  diagnostic_format.pointer_to_human(
    "components.schemas.Order.properties.items.items.properties.product.properties.tags.items",
  )
  |> should.equal(
    "schemas.Order (properties.items.items.properties.product.properties.tags.items)",
  )
}

pub fn paths_deep_nested_request_body_tail_preserved_test() {
  diagnostic_format.pointer_to_human(
    "paths.~1pets.post.requestBody.content.application~1json.schema.properties.children.items.properties.id",
  )
  |> should.equal(
    "POST /pets, requestBody (content.application/json.schema.properties.children.items.properties.id)",
  )
}
