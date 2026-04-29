import gleeunit
import gleeunit/should
import oaspec/internal/openapi/diagnostic_format

pub fn main() {
  gleeunit.main()
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
