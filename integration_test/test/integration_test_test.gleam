import api/decode
import api/encode
import api/handlers
import api/middleware
import api/request_types
import api/response_types
import api/types
import gleam/dict
import gleam/option.{None, Some}
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
      additional_properties: dict.new(),
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
      additional_properties: dict.new(),
    )
  req.name |> should.equal("Rex")
}

pub fn error_type_test() {
  let err =
    types.Error(
      code: 404,
      message: "Not found",
      additional_properties: dict.new(),
    )
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
    types.Pet(
      id: 1,
      name: "Rex",
      status: types.PetStatusAvailable,
      tag: None,
      additional_properties: dict.new(),
    )
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
      additional_properties: dict.new(),
    )
  let encoded = encode.encode_pet(original)
  let assert Ok(decoded) = decode.decode_pet(encoded)
  decoded |> should.equal(original)
}

pub fn roundtrip_pet_without_tag_test() {
  let original =
    types.Pet(
      id: 1,
      name: "Rex",
      status: types.PetStatusPending,
      tag: None,
      additional_properties: dict.new(),
    )
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
  let resp = handlers.list_pets(req)
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
  let body =
    types.CreatePetRequest(
      name: "NewPet",
      status: None,
      tag: None,
      additional_properties: dict.new(),
    )
  let req = request_types.CreatePetRequest(body:)
  let resp = handlers.create_pet(req)
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
  let resp = handlers.get_pet(req)
  case resp {
    response_types.GetPetResponseOk(pet) -> pet.name |> should.equal("Fido")
    _ -> should.fail()
  }
}

pub fn handler_get_pet_not_found_test() {
  let req = request_types.GetPetRequest(pet_id: 999)
  let resp = handlers.get_pet(req)
  case resp {
    response_types.GetPetResponseNotFound -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn handler_delete_pet_found_test() {
  let req = request_types.DeletePetRequest(pet_id: 1)
  let resp = handlers.delete_pet(req)
  case resp {
    response_types.DeletePetResponseNoContent -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn handler_delete_pet_not_found_test() {
  let req = request_types.DeletePetRequest(pet_id: 999)
  let resp = handlers.delete_pet(req)
  case resp {
    response_types.DeletePetResponseNotFound -> should.be_true(True)
    _ -> should.fail()
  }
}

// ===================================================================
// Middleware Tests
// ===================================================================

pub fn middleware_identity_test() {
  let handler = fn(req: Int) -> Result(Int, middleware.MiddlewareError) {
    Ok(req * 2)
  }
  let wrapped = middleware.identity()(handler)
  wrapped(5) |> should.equal(Ok(10))
}

pub fn middleware_compose_test() {
  // Two identity middlewares composed should still be identity
  let handler = fn(req: Int) -> Result(Int, middleware.MiddlewareError) {
    Ok(req + 1)
  }
  let composed =
    middleware.compose(middleware.identity(), middleware.identity())
  let wrapped = composed(handler)
  wrapped(5) |> should.equal(Ok(6))
}

pub fn middleware_apply_empty_test() {
  let handler = fn(req: String) -> Result(String, middleware.MiddlewareError) {
    Ok("hello " <> req)
  }
  let wrapped = middleware.apply([], handler)
  wrapped("world") |> should.equal(Ok("hello world"))
}

pub fn middleware_retry_success_test() {
  let handler = fn(_req: Int) -> Result(Int, middleware.MiddlewareError) {
    Ok(42)
  }
  let retry_mw = middleware.retry(3)
  let wrapped = retry_mw(handler)
  wrapped(0) |> should.equal(Ok(42))
}

pub fn middleware_retry_failure_test() {
  // Handler always fails - retry should exhaust retries and return error
  let handler = fn(_req: Int) -> Result(Int, middleware.MiddlewareError) {
    Error(middleware.InternalError(detail: "always fails"))
  }
  let retry_mw = middleware.retry(2)
  let wrapped = retry_mw(handler)
  let result = wrapped(0)
  should.be_error(result)
}

// ===================================================================
// End-to-End: Simulated Server/Client Communication
// ===================================================================

pub fn e2e_request_response_cycle_test() {
  // Simulate a full request -> handler -> response -> encode cycle
  // 1. Build request
  let req = request_types.GetPetRequest(pet_id: 1)

  // 2. Call handler (simulating server)
  let resp = handlers.get_pet(req)

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

pub fn e2e_middleware_handler_chain_test() {
  // Wrap a handler with middleware and verify the full chain works
  let handler = fn(req: request_types.GetPetRequest) -> Result(
    response_types.GetPetResponse,
    middleware.MiddlewareError,
  ) {
    Ok(handlers.get_pet(req))
  }

  // Apply identity + logging middleware
  let mw_chain = [middleware.identity(), middleware.logging()]
  let wrapped = middleware.apply(mw_chain, handler)

  // Call through the middleware chain
  let req = request_types.GetPetRequest(pet_id: 1)
  let result = wrapped(req)
  should.be_ok(result)
  let assert Ok(resp) = result
  case resp {
    response_types.GetPetResponseOk(pet) -> pet.name |> should.equal("Fido")
    _ -> should.fail()
  }
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
