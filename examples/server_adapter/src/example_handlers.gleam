//// Hand-written handler implementations for the server_adapter example.
////
//// This file lives OUTSIDE the `api/` directory, so `oaspec generate`
//// does not touch it. Domain logic — anything an application author
//// actually writes — belongs here. `api/handlers.gleam` is then a thin
//// delegator owned by the generator; after a regeneration it is
//// enough to restore the two-line body of each stub below.

import api/guards
import api/request_types
import api/response_types
import api/types
import gleam/option.{None, Some}

pub fn list_pets(
  req: request_types.ListPetsRequest,
) -> response_types.ListPetsResponse {
  let _ = req
  response_types.ListPetsResponseOk([
    types.Pet(
      id: 1,
      name: "Fido",
      status: types.PetStatusAvailable,
      tag: Some("dog"),
    ),
    types.Pet(
      id: 2,
      name: "Whiskers",
      status: types.PetStatusPending,
      tag: None,
    ),
  ])
}

pub fn create_pet(
  req: request_types.CreatePetRequest,
) -> response_types.CreatePetResponse {
  // Run the generated validation guard before constructing the response.
  // A well-formed OpenAPI spec will reject out-of-range values at the
  // guard layer; returning 400 is the idiomatic mapping.
  case guards.validate_create_pet_request(req.body) {
    Error(_) -> response_types.CreatePetResponseBadRequest
    Ok(_) ->
      response_types.CreatePetResponseCreated(types.Pet(
        id: 100,
        name: req.body.name,
        status: types.PetStatusAvailable,
        tag: req.body.tag,
      ))
  }
}

pub fn get_pet(
  req: request_types.GetPetRequest,
) -> response_types.GetPetResponse {
  case req.pet_id {
    1 ->
      response_types.GetPetResponseOk(types.Pet(
        id: 1,
        name: "Fido",
        status: types.PetStatusAvailable,
        tag: Some("dog"),
      ))
    _ -> response_types.GetPetResponseNotFound
  }
}

pub fn delete_pet(
  req: request_types.DeletePetRequest,
) -> response_types.DeletePetResponse {
  case req.pet_id {
    1 -> response_types.DeletePetResponseNoContent
    _ -> response_types.DeletePetResponseNotFound
  }
}
