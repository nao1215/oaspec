//// Implement these handler functions. This file is emitted once
//// by `oaspec generate` and skipped on subsequent runs, so your
//// edits survive regeneration. Router wiring lives in
//// `handlers_generated.gleam`, which delegates here.

import api/request_types
import api/response_types

/// Application state passed to every handler.
/// Add fields here for DB connections, config, loggers, etc. Construct a value of this type in your `main` and pass it to `router.route` as the first argument.
pub type State {
  State
}

/// List all pets
/// Returns all pets from the system
pub fn list_pets(
  state: State,
  req: request_types.ListPetsRequest,
) -> response_types.ListPetsResponse {
  let _ = state
  let _ = req
  panic as "unimplemented: list_pets"
}

/// Create a pet
/// Creates a new pet in the store
pub fn create_pet(
  state: State,
  req: request_types.CreatePetRequest,
) -> response_types.CreatePetResponse {
  let _ = state
  let _ = req
  panic as "unimplemented: create_pet"
}

/// Get a pet by ID
/// Returns a single pet by its ID
pub fn get_pet(
  state: State,
  req: request_types.GetPetRequest,
) -> response_types.GetPetResponse {
  let _ = state
  let _ = req
  panic as "unimplemented: get_pet"
}

/// Delete a pet
/// Deletes a pet by its ID
pub fn delete_pet(
  state: State,
  req: request_types.DeletePetRequest,
) -> response_types.DeletePetResponse {
  let _ = state
  let _ = req
  panic as "unimplemented: delete_pet"
}
