//// Implement this handler. This file is emitted once by
//// `oaspec generate` and skipped on subsequent runs, so your
//// edits survive regeneration.

import api/handlers.{type State}
import api/request_types
import api/response_types

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
