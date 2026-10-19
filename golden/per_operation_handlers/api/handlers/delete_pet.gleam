//// Implement this handler. This file is emitted once by
//// `oaspec generate` and skipped on subsequent runs, so your
//// edits survive regeneration.

import api/handlers.{type State}
import api/request_types
import api/response_types

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
