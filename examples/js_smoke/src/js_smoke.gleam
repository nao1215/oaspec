//// JS-target smoke test for oaspec's pure subgraph.
////
//// The point of this example is not to demonstrate end-user usage —
//// for that, see `examples/petstore_client`. The point is to keep the
//// public target-neutral runtime surface honest: this project is
//// built and run with `target = "javascript"` in CI, so any future
//// change that re-couples one of the touched modules to BEAM-only
//// code (yay, simplifile, glint, BEAM-only FFI) will fail this build.
////
//// Today the demonstrably JS-runnable surface is the public client
//// runtime: `oaspec/transport` and `oaspec/mock`. Other modules
//// nominally listed as "Pure" still pull in BEAM-only transitive
//// imports (`oaspec/openapi/diagnostic` → `oaspec/config` → `yay`),
//// which runs but fails at module-load time because `yay`'s JS FFI
//// requires the `js-yaml` npm package. Decoupling those is follow-up
//// work tracked in #344's parser-layer cleanup.

import gleam/io
import oaspec/mock
import oaspec/transport

pub fn main() -> Nil {
  // Public client runtime: build a credentials value and a fake
  // `transport.Send`. These are the public types JS-side users of
  // generated clients would reach for first.
  let _credentials =
    transport.credentials()
    |> transport.with_bearer_token("BearerAuth", "test-token")
  let _send = mock.text(200, "{}")

  io.println("oaspec js_smoke: ok")
}
