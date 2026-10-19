//// Implement this handler. This file is emitted once by
//// `oaspec generate` and skipped on subsequent runs, so your
//// edits survive regeneration.

import api/handlers.{type State}
import api/request_types
import api/response_types

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
