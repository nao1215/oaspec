//// Thin delegator. `oaspec generate` emits `panic` stubs into this
//// file; the example replaces each stub with a one-line call into
//// `example_handlers` so real domain logic can live outside the
//// regeneration-affected `api/` directory.
////
//// After regenerating the server, restore this file by replacing the
//// generated `panic` body of each function with the matching
//// `example_handlers.<fn>(state, req)` call. That restoration is
//// mechanical and version-control-diffable.

import api/request_types
import api/response_types
import example_handlers

/// Application state passed to every handler. The example does not
/// need any DB connection or configuration, so this is an empty
/// constructor — extend with fields when wiring real dependencies.
pub type State {
  State
}

pub fn list_pets(
  state: State,
  req: request_types.ListPetsRequest,
) -> response_types.ListPetsResponse {
  example_handlers.list_pets(state, req)
}

pub fn create_pet(
  state: State,
  req: request_types.CreatePetRequest,
) -> response_types.CreatePetResponse {
  example_handlers.create_pet(state, req)
}

pub fn get_pet(
  state: State,
  req: request_types.GetPetRequest,
) -> response_types.GetPetResponse {
  example_handlers.get_pet(state, req)
}

pub fn delete_pet(
  state: State,
  req: request_types.DeletePetRequest,
) -> response_types.DeletePetResponse {
  example_handlers.delete_pet(state, req)
}
