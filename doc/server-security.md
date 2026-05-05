# Server security model

Spec authors who declare `security:` on an operation expect "this endpoint
requires auth". The current `oaspec` server codegen does not enforce that
requirement: it parses the security declaration during validation (so a
typo in a scheme name or a reference to an undefined `securityScheme` is
still caught at generation time) but emits no auth check in the generated
router. A request that omits the declared `Authorization` / `X-Api-Key` /
session cookie reaches the handler unchanged.

This is intentional in this release — picking a single auth enforcement
model would prescribe more policy than the rest of the codegen does — but
it is also a sharp edge worth calling out. Until the generator gains a
verifier hook, server users have two options.

## Option 1: enforce in the handler

The router already passes the full `headers` and (for cookie-based schemes)
the path / query / body pieces it receives, so the handler can read
`dict.get(headers, "authorization")` etc. and short-circuit with a 401
response variant before touching domain logic. Generated `XxxResponse`
types include any explicit `"401":` variants, and the `default` response
variant carries a runtime `Int` so a single `Default(401, ...)` arm can
cover the catch-all 401 case for any operation.

## Option 2: enforce in an outer adapter layer

Wrap the generated `router.route/6` in a thin auth-checking function that
runs before dispatch — typically the same place where the framework
adapter (`mist`, `wisp`, …) lives. This keeps the per-operation handlers
focused on domain logic and centralises the auth policy in one place.

## Tracking issue

[#484](https://github.com/nao1215/oaspec/issues/484) tracks the path to an
opt-in verifier signature on the generated `State` (e.g.
`verify_security: fn(scheme, value) -> Result(...)`) so the router can
emit the 401 itself; that direction is not yet committed to.

## Client-side security

On the client side, the generated client attaches credentials per the
`security:` declaration on each operation, walking OR-of-AND alternatives
and applying the first satisfied one. For OAuth2 and OpenID Connect, the
generated client attaches a bearer token to requests; token acquisition,
refresh, and flow execution are outside the generated code.

```gleam
import api/client
import oaspec/httpc
import oaspec/transport

let send =
  httpc.send
  |> transport.with_base_url(client.default_base_url())
  |> transport.with_security(
    transport.credentials()
    |> transport.with_bearer_token("BearerAuth", token),
  )

let result = client.list_pets(send, limit: option.Some(10), offset: option.None)
```
