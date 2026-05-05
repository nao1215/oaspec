import api/decode
import api/encode
import api/guards
import api/handlers
import api/request_types
import api/response_types
import api/router
import api/types
import gleam/dict
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// ===================================================================
// Type Construction Tests
// ===================================================================

pub fn pet_construction_test() {
  let pet =
    types.Pet(
      id: 1,
      name: "Fido",
      status: types.PetStatusAvailable,
      tag: Some("dog"),
    )
  pet.id |> should.equal(1)
  pet.name |> should.equal("Fido")
  pet.tag |> should.equal(Some("dog"))
}

pub fn pet_status_enum_test() {
  // Ensure all enum variants exist and are distinct
  let available = types.PetStatusAvailable
  let pending = types.PetStatusPending
  let sold = types.PetStatusSold
  should.not_equal(available, pending)
  should.not_equal(pending, sold)
  should.not_equal(available, sold)
}

pub fn create_pet_request_type_test() {
  let req =
    types.CreatePetRequest(
      name: "Rex",
      status: Some(types.PetStatusAvailable),
      tag: None,
    )
  req.name |> should.equal("Rex")
}

pub fn error_type_test() {
  let err = types.Error(code: 404, message: "Not found")
  err.code |> should.equal(404)
  err.message |> should.equal("Not found")
}

// ===================================================================
// Request Type Tests
// ===================================================================

pub fn list_pets_request_test() {
  let req = request_types.ListPetsRequest(limit: Some(10), offset: Some(0))
  req.limit |> should.equal(Some(10))
  req.offset |> should.equal(Some(0))
}

pub fn get_pet_request_test() {
  let req = request_types.GetPetRequest(pet_id: 42)
  req.pet_id |> should.equal(42)
}

pub fn delete_pet_request_test() {
  let req = request_types.DeletePetRequest(pet_id: 1)
  req.pet_id |> should.equal(1)
}

// ===================================================================
// Response Type Tests
// ===================================================================

pub fn list_pets_response_ok_variant_test() {
  let response_types.ListPetsResponseOk(pets) =
    response_types.ListPetsResponseOk([])
  pets |> should.equal([])
}

pub fn list_pets_response_unauthorized_variant_test() {
  let resp = response_types.ListPetsResponseUnauthorized
  resp |> should.equal(response_types.ListPetsResponseUnauthorized)
}

pub fn create_pet_response_created_variant_test() {
  let pet =
    types.Pet(id: 1, name: "Rex", status: types.PetStatusAvailable, tag: None)
  let response_types.CreatePetResponseCreated(p) =
    response_types.CreatePetResponseCreated(pet)
  p.name |> should.equal("Rex")
}

pub fn get_pet_response_not_found_variant_test() {
  let resp = response_types.GetPetResponseNotFound
  resp |> should.equal(response_types.GetPetResponseNotFound)
}

pub fn delete_pet_response_no_content_variant_test() {
  let resp = response_types.DeletePetResponseNoContent
  resp |> should.equal(response_types.DeletePetResponseNoContent)
}

// ===================================================================
// JSON Decoder Tests
// ===================================================================

pub fn decode_pet_test() {
  let json_str =
    "{\"id\": 1, \"name\": \"Fido\", \"status\": \"available\", \"tag\": \"dog\"}"
  let result = decode.decode_pet(json_str)
  should.be_ok(result)
  let assert Ok(pet) = result
  pet.id |> should.equal(1)
  pet.name |> should.equal("Fido")
  pet.tag |> should.equal(Some("dog"))
}

pub fn decode_pet_without_optional_fields_test() {
  let json_str = "{\"id\": 2, \"name\": \"Whiskers\", \"status\": \"pending\"}"
  let result = decode.decode_pet(json_str)
  should.be_ok(result)
  let assert Ok(pet) = result
  pet.id |> should.equal(2)
  pet.name |> should.equal("Whiskers")
  pet.tag |> should.equal(None)
}

pub fn decode_error_type_test() {
  let json_str = "{\"code\": 404, \"message\": \"Not found\"}"
  let result = decode.decode_error(json_str)
  should.be_ok(result)
  let assert Ok(err) = result
  err.code |> should.equal(404)
  err.message |> should.equal("Not found")
}

pub fn decode_pet_status_test() {
  let result = decode.decode_pet_status("\"available\"")
  should.be_ok(result)
  let assert Ok(status) = result
  status |> should.equal(types.PetStatusAvailable)
}

pub fn decode_pet_status_pending_test() {
  let result = decode.decode_pet_status("\"pending\"")
  should.be_ok(result)
  let assert Ok(status) = result
  status |> should.equal(types.PetStatusPending)
}

pub fn decode_pet_status_sold_test() {
  let result = decode.decode_pet_status("\"sold\"")
  should.be_ok(result)
  let assert Ok(status) = result
  status |> should.equal(types.PetStatusSold)
}

pub fn decode_invalid_json_test() {
  let result = decode.decode_pet("not json")
  should.be_error(result)
}

// ===================================================================
// JSON Encoder Tests
// ===================================================================

pub fn encode_pet_status_test() {
  let result = encode.encode_pet_status(types.PetStatusAvailable)
  result |> should.equal("\"available\"")
}

pub fn encode_pet_status_pending_test() {
  let result = encode.encode_pet_status(types.PetStatusPending)
  result |> should.equal("\"pending\"")
}

pub fn encode_pet_status_sold_test() {
  let result = encode.encode_pet_status(types.PetStatusSold)
  result |> should.equal("\"sold\"")
}

// ===================================================================
// Roundtrip Tests (encode -> decode preserves values)
// ===================================================================

pub fn roundtrip_pet_status_available_test() {
  let original = types.PetStatusAvailable
  let encoded = encode.encode_pet_status(original)
  let assert Ok(decoded) = decode.decode_pet_status(encoded)
  decoded |> should.equal(original)
}

pub fn roundtrip_pet_status_sold_test() {
  let original = types.PetStatusSold
  let encoded = encode.encode_pet_status(original)
  let assert Ok(decoded) = decode.decode_pet_status(encoded)
  decoded |> should.equal(original)
}

pub fn roundtrip_pet_test() {
  let original =
    types.Pet(
      id: 42,
      name: "Buddy",
      status: types.PetStatusSold,
      tag: Some("golden"),
    )
  let encoded = encode.encode_pet(original)
  let assert Ok(decoded) = decode.decode_pet(encoded)
  decoded |> should.equal(original)
}

pub fn roundtrip_pet_without_tag_test() {
  let original =
    types.Pet(id: 1, name: "Rex", status: types.PetStatusPending, tag: None)
  let encoded = encode.encode_pet(original)
  let assert Ok(decoded) = decode.decode_pet(encoded)
  decoded |> should.equal(original)
}

pub fn unknown_enum_returns_error_test() {
  let result = decode.decode_pet_status("\"extinct\"")
  should.be_error(result)
}

// ===================================================================
// Handler Tests (simulated server/client communication)
// ===================================================================

pub fn handler_list_pets_test() {
  let req = request_types.ListPetsRequest(limit: Some(10), offset: None)
  let resp = handlers.list_pets(handlers.State, req)
  case resp {
    response_types.ListPetsResponseOk(pets) -> {
      should.be_true(list_length(pets) > 0)
      let assert [first, ..] = pets
      first.name |> should.equal("Fido")
    }
    _ -> should.fail()
  }
}

pub fn handler_create_pet_test() {
  let body = types.CreatePetRequest(name: "NewPet", status: None, tag: None)
  let req = request_types.CreatePetRequest(body:)
  let resp = handlers.create_pet(handlers.State, req)
  case resp {
    response_types.CreatePetResponseCreated(pet) -> {
      pet.id |> should.equal(100)
      pet.name |> should.equal("NewPet")
    }
    _ -> should.fail()
  }
}

pub fn handler_get_pet_found_test() {
  let req = request_types.GetPetRequest(pet_id: 1)
  let resp = handlers.get_pet(handlers.State, req)
  case resp {
    response_types.GetPetResponseOk(pet) -> pet.name |> should.equal("Fido")
    _ -> should.fail()
  }
}

pub fn handler_get_pet_not_found_test() {
  let req = request_types.GetPetRequest(pet_id: 999)
  let resp = handlers.get_pet(handlers.State, req)
  case resp {
    response_types.GetPetResponseNotFound -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn handler_delete_pet_found_test() {
  let req = request_types.DeletePetRequest(pet_id: 1)
  let resp = handlers.delete_pet(handlers.State, req)
  case resp {
    response_types.DeletePetResponseNoContent -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn handler_delete_pet_not_found_test() {
  let req = request_types.DeletePetRequest(pet_id: 999)
  let resp = handlers.delete_pet(handlers.State, req)
  case resp {
    response_types.DeletePetResponseNotFound -> should.be_true(True)
    _ -> should.fail()
  }
}

// ===================================================================
// End-to-End: Simulated Server/Client Communication
// ===================================================================

pub fn e2e_request_response_cycle_test() {
  // Simulate a full request -> handler -> response -> encode cycle
  // 1. Build request
  let req = request_types.GetPetRequest(pet_id: 1)

  // 2. Call handler (simulating server)
  let resp = handlers.get_pet(handlers.State, req)

  // 3. Verify response type
  case resp {
    response_types.GetPetResponseOk(pet) -> {
      // 4. Encode the response
      let encoded = encode.encode_pet(pet)
      // 5. Verify the encoded JSON is valid by decoding it back
      let decoded = decode.decode_pet(encoded)
      should.be_ok(decoded)
      let assert Ok(decoded_pet) = decoded
      decoded_pet.id |> should.equal(1)
      decoded_pet.name |> should.equal("Fido")
    }
    _ -> should.fail()
  }
}

// ===================================================================
// Issue #422: exercise the generated router and guards from gleeunit
// rather than only through run.sh. Without these, a regression that
// broke router.route's happy path or a guard's reject path on the
// committed petstore project wouldn't show up in `gleam test` —
// only in the bash-driven `integration_test/run.sh`.
// ===================================================================

fn empty_dict() -> dict.Dict(String, List(String)) {
  dict.new()
}

fn empty_headers() -> dict.Dict(String, String) {
  dict.new()
}

pub fn router_get_pets_happy_path_test() {
  let resp =
    router.route(
      handlers.State,
      "GET",
      ["pets"],
      empty_dict(),
      empty_headers(),
      "",
    )
  resp.status |> should.equal(200)
  case resp.body {
    router.TextBody(body) -> {
      // The stub handler returns at least one pet; the JSON should
      // mention "Fido" or be a JSON array prefix.
      body |> string.contains("\"name\"") |> should.be_true()
    }
    _ -> should.fail()
  }
}

pub fn router_get_pet_by_id_happy_path_test() {
  let resp =
    router.route(
      handlers.State,
      "GET",
      ["pets", "1"],
      empty_dict(),
      empty_headers(),
      "",
    )
  resp.status |> should.equal(200)
}

pub fn router_get_pet_by_id_not_found_test() {
  let resp =
    router.route(
      handlers.State,
      "GET",
      ["pets", "999"],
      empty_dict(),
      empty_headers(),
      "",
    )
  resp.status |> should.equal(404)
}

pub fn router_unknown_path_returns_404_test() {
  let resp =
    router.route(
      handlers.State,
      "GET",
      ["unknown", "path"],
      empty_dict(),
      empty_headers(),
      "",
    )
  resp.status |> should.equal(404)
  case resp.body {
    router.TextBody(body) -> {
      body |> string.contains("not found") |> should.be_true()
    }
    _ -> should.fail()
  }
}

pub fn router_unknown_method_returns_404_test() {
  // The generated router collapses unknown method+path into the
  // 404 fallback (single `_, _ -> 404` arm). 405 is not surfaced.
  let resp =
    router.route(
      handlers.State,
      "PATCH",
      ["pets"],
      empty_dict(),
      empty_headers(),
      "",
    )
  resp.status |> should.equal(404)
}

pub fn router_query_param_parsing_test() {
  let query =
    dict.from_list([
      #("limit", ["5"]),
      #("offset", ["10"]),
    ])
  let resp =
    router.route(handlers.State, "GET", ["pets"], query, empty_headers(), "")
  resp.status |> should.equal(200)
}

pub fn guards_validate_pet_name_accepts_valid_test() {
  let result = guards.validate_pet_name_length("Fido")
  result |> should.equal(Ok("Fido"))
}

pub fn guards_validate_pet_name_rejects_empty_test() {
  let result = guards.validate_pet_name_length("")
  case result {
    Error(failure) -> {
      failure.field |> should.equal("name")
      failure.code |> should.equal("minLength")
    }
    Ok(_) -> should.fail()
  }
}

pub fn guards_validate_pet_name_rejects_too_long_test() {
  let too_long = string.repeat("x", 101)
  let result = guards.validate_pet_name_length(too_long)
  case result {
    Error(failure) -> {
      failure.field |> should.equal("name")
      failure.code |> should.equal("maxLength")
    }
    Ok(_) -> should.fail()
  }
}

pub fn guards_validate_pet_aggregates_failures_test() {
  // Whole-record validator collects failures and returns Result(_, List(ValidationFailure)).
  let bad_pet =
    types.Pet(
      id: 1,
      name: "",
      // empty: triggers minLength
      status: types.PetStatusAvailable,
      tag: None,
    )
  case guards.validate_pet(bad_pet) {
    Error(failures) ->
      // At least one failure surfaced.
      case failures {
        [] -> should.fail()
        _ -> Nil
      }
    Ok(_) -> should.fail()
  }
}

// ===================================================================
// QA expansion: encoder idempotency, optional-None invariant, fuzz
//
// These tests cover gaps that `decode(encode(x)) == x` alone cannot
// catch:
//   1. encode(decode(encode(x))) string-equal encode(x): protects against
//      encoders that silently drop or reorder keys on a re-encode.
//   2. Optional fields that are None must NOT appear as keys in the
//      output JSON (and especially must not encode as `null`). A
//      regression here breaks API compatibility but slips past the
//      Some/None roundtrip tests.
//   3. Seeded-fuzz roundtrip across 100 deterministic Pets — exercises
//      enum variant cycling and Some/None on `tag` together rather
//      than one configuration at a time.
// ===================================================================

pub fn pet_encode_is_idempotent_test() {
  let original =
    types.Pet(
      id: 7,
      name: "Buddy",
      status: types.PetStatusSold,
      tag: Some("golden"),
    )
  let once = encode.encode_pet(original)
  let assert Ok(decoded) = decode.decode_pet(once)
  let twice = encode.encode_pet(decoded)
  twice |> should.equal(once)
}

pub fn pet_optional_none_omits_key_test() {
  let pet =
    types.Pet(id: 1, name: "x", status: types.PetStatusAvailable, tag: None)
  let json = encode.encode_pet(pet)
  string.contains(json, "\"tag\"") |> should.be_false()
  string.contains(json, "null") |> should.be_false()
}

pub fn pet_optional_some_includes_key_test() {
  let pet =
    types.Pet(
      id: 1,
      name: "x",
      status: types.PetStatusAvailable,
      tag: Some("dog"),
    )
  let json = encode.encode_pet(pet)
  string.contains(json, "\"tag\"") |> should.be_true()
  string.contains(json, "\"dog\"") |> should.be_true()
}

fn pet_for_seed(seed: Int) -> types.Pet {
  let status = case seed % 3 {
    0 -> types.PetStatusAvailable
    1 -> types.PetStatusPending
    _ -> types.PetStatusSold
  }
  let tag = case seed % 5 == 0 {
    True -> None
    False -> Some("tag-" <> int.to_string(seed))
  }
  types.Pet(
    id: seed,
    name: "pet-" <> int.to_string(seed),
    status: status,
    tag: tag,
  )
}

fn check_pet_roundtrip(seed: Int) -> Nil {
  let pet = pet_for_seed(seed)
  let encoded = encode.encode_pet(pet)
  case decode.decode_pet(encoded) {
    Ok(decoded) ->
      case decoded == pet {
        True -> Nil
        False ->
          // nolint: avoid_panic -- diagnostic abort for seed reproduction
          panic as { "roundtrip mismatch for seed " <> int.to_string(seed) }
      }
    Error(_) ->
      // nolint: avoid_panic -- diagnostic abort for seed reproduction
      panic as { "decode failed for seed " <> int.to_string(seed) }
  }
}

fn run_seeds(current: Int, stop: Int) -> Nil {
  case current >= stop {
    True -> Nil
    False -> {
      check_pet_roundtrip(current)
      run_seeds(current + 1, stop)
    }
  }
}

pub fn pet_roundtrip_property_test() {
  // Deterministic 100-seed fuzz: covers every PetStatus variant and both
  // None/Some(tag) configurations. Failure prints the seed so the case
  // reproduces with a single direct call to `pet_for_seed`.
  run_seeds(0, 100)
}

// ===================================================================
// Helpers
// ===================================================================

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}
