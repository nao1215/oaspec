//// Hand-written handler implementations for the server_adapter example.
//// These replace the generated panic stubs and return canned test data.

import api/request_types
import api/response_types
import api/types
import gleam/dict
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
      additional_properties: dict.new(),
    ),
    types.Pet(
      id: 2,
      name: "Whiskers",
      status: types.PetStatusPending,
      tag: None,
      additional_properties: dict.new(),
    ),
  ])
}

pub fn create_pet(
  req: request_types.CreatePetRequest,
) -> response_types.CreatePetResponse {
  response_types.CreatePetResponseCreated(types.Pet(
    id: 100,
    name: req.body.name,
    status: types.PetStatusAvailable,
    tag: req.body.tag,
    additional_properties: dict.new(),
  ))
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
        additional_properties: dict.new(),
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
