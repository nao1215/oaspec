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

/// Demonstrate required query / header / cookie params
pub fn get_required_params(
  state: State,
  req: request_types.GetRequiredParamsRequest,
) -> response_types.GetRequiredParamsResponse {
  let _ = state
  let _ = req
  panic as "unimplemented: get_required_params"
}

/// Complex search
pub fn post_search(
  state: State,
  req: request_types.PostSearchRequest,
) -> response_types.PostSearchResponse {
  let _ = state
  let _ = req
  panic as "unimplemented: post_search"
}

/// Get user with polymorphic response
pub fn get_user(
  state: State,
  req: request_types.GetUserRequest,
) -> response_types.GetUserResponse {
  let _ = state
  let _ = req
  panic as "unimplemented: get_user"
}

/// Receive webhook
pub fn post_webhook(
  state: State,
  req: request_types.PostWebhookRequest,
) -> response_types.PostWebhookResponse {
  let _ = state
  let _ = req
  panic as "unimplemented: post_webhook"
}
