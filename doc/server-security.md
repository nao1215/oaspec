# Server security model

The generated router reads `security:` declarations but does not enforce them. Validation still catches a scheme name that is not in `components.securitySchemes`, but a request without the declared `Authorization` header, API key or cookie reaches the handler.

Handlers receive only the parameters the operation declares, not the raw headers. There are two ways to check credentials.

## Check in front of the router

Wrap `router.route/6` in a function that reads the credential from `headers` and returns a 401 before calling the router. This usually sits next to the `mist` or `wisp` adapter, and keeps the policy in one place.

## Declare the credential as a parameter

Declare the header or cookie as a parameter of the operation (`in: header` or `in: cookie`). The router then decodes it into the request record, and the handler can answer with the operation's `401` response, or with `Default(401, ...)` when the spec only has a `default` response.

## Client side

Generated clients attach credentials according to each operation's `security:`, using the first alternative whose schemes all have a credential. For OAuth2 and OpenID Connect the client sends a bearer token; getting and refreshing the token is up to you.

```gleam
import api_client/client
import gleam/option.{None, Some}
import oaspec/httpc
import oaspec/transport

let send =
  httpc.send
  |> transport.with_base_url(client.default_base_url())
  |> transport.with_security([transport.BearerToken("BearerAuth", token)])

let result = client.list_pets(send, limit: Some(10), offset: None)
```
