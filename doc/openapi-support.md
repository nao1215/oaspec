# OpenAPI support

`oaspec` supports OpenAPI 3.0.x and a practical subset of OpenAPI 3.1.x in
YAML or JSON. The parser also accepts the two-segment forms `3.0` / `3.1`,
including YAML numeric values such as `openapi: 3.0` that arrive as the
float `3.0`. Any other `openapi` value — for example `2.0`, `4.0.0`, a
bare `3`, or a malformed `3.0.foo` — is rejected with an `invalid_value`
diagnostic so unsupported versions fail fast instead of producing
plausible-looking but meaningless output.

## What is supported

- Schemas: `object`, primitives, arrays, enums, nullable, `allOf`,
  `oneOf`, `anyOf`, typed `additionalProperties`
- Local `$ref` and relative-file external `$ref` across schemas,
  parameters, request bodies, responses, and path items. External ref
  graphs must be acyclic — cycles such as `A.yaml → B.yaml → A.yaml`
  fail fast with a dedicated diagnostic that shows the visited chain.
- Parameters: path, query, header, cookie, plus array styles (`form`,
  `pipeDelimited`, `spaceDelimited`) and objects via `deepObject`
- Request bodies: `application/json`, `text/plain`,
  `application/octet-stream`, `application/x-www-form-urlencoded`,
  `multipart/form-data`
- Typed response variants, typed response headers, and `$ref` /
  `default` responses
- Security: `apiKey`, HTTP (bearer/basic/digest), OAuth2, OpenID Connect
  (bearer token attachment on the client; parsed but not enforced on
  the server — see [server-security.md](./server-security.md))

## operationId uniqueness

Every operation must carry a unique `operationId`. `oaspec` validates this
as a hard error with the offending `METHOD /path` sites listed, because
silently renaming the second occurrence (as some generators do) would
mutate the generated function/type names without telling the user. The
check also catches IDs that only differ in casing — `listItems` and
`list_items` both collapse to the same generated `list_items` function,
so the spec is rejected.

## `format: byte` and `format: binary`

The OpenAPI `format` keyword on a `string` schema is passed through as
metadata only. Generated fields keep the Gleam type `String`; the encoded
contract (`format: byte` = base64 per OAS 3.0 §4.7.4 / OAS 3.1 alignment
with JSON Schema, `format: binary` = raw bytes) is not enforced or
materialised by the generator.

- `format: byte`: the field is decoded and emitted as the literal base64
  character string. Callers that need the underlying bytes must
  base64-decode themselves (e.g. with `yabase/facade.decode_base64`).
  Invalid base64 input is not rejected at decode time.
- `format: binary`: the field is decoded and emitted as a plain `String`.
  For `multipart/form-data` request bodies, the higher-level body codepath
  (`client_request`) already handles binary bodies correctly via
  `BytesBody`; this caveat only applies when `binary` appears as a
  field-level format on a string schema outside that context.

A future release may auto-decode `format: byte` to `BitArray` or emit a
`format` docstring on the generated field; tracking issue
[#338](https://github.com/nao1215/oaspec/issues/338).

## Mode-specific support

`oaspec` generates different files depending on the `--mode` flag. Some
features have mode-specific restrictions enforced at validation time.

### Generated files

| File | server | client |
|------|--------|--------|
| `types.gleam` | yes | yes |
| `decode.gleam` | yes | yes |
| `encode.gleam` | yes | yes |
| `request_types.gleam` | yes | yes |
| `response_types.gleam` | yes | yes |
| `guards.gleam` | yes | yes |
| `handlers.gleam` | yes (once) | - |
| `handlers_generated.gleam` | yes | - |
| `router.gleam` | yes | - |
| `client.gleam` | - | yes |

`handlers.gleam` is user-owned. The generator writes panic stubs on the
first run and skips the file on every subsequent run, so your
implementations survive regeneration. `handlers_generated.gleam` is the
sealed delegator the router imports, and each operation forwards to
`handlers.<op_name>(req)`.

### Feature restrictions by mode

| Feature | server | client | Notes |
|---------|--------|--------|-------|
| JSON request/response bodies | yes | yes | |
| Path / query / header / cookie parameters | yes | yes | |
| `style: deepObject` parameters | restricted | yes | Server: only primitive scalars and primitive arrays. Client: composite (`oneOf`/`anyOf`/`allOf`) sub-properties take the JSON escape hatch (`parent[<prop>]=<JSON string>`). |
| Array query parameters | restricted | yes | Server: only inline primitive item schemas. Client: non-primitive items (object / composite) are JSON-encoded into a single `<param>=<JSON array>` value. |
| `style: pipeDelimited` / `style: spaceDelimited` query arrays | yes | yes | Query array parameters only; primitive item types. Non-exploded joins with `\|` / `%20`, exploded degenerates to form-style `name=a&name=b`. |
| `application/x-www-form-urlencoded` | restricted | yes | Server: must be sole content type; only primitive fields and shallow nested objects. Client: composite fields and `encoding[<f>].contentType: application/json` opt fields into the JSON escape hatch (`<field>=<percent-encoded JSON string>`). |
| `multipart/form-data` | restricted | yes | Server: must be sole content type; only primitive scalar fields or arrays of primitive scalars |
| `text/plain` request body | yes | yes | Treated as a single `String` field on the request |
| `application/octet-stream` request body | yes | yes | Treated as raw `BitArray`/binary on the request |
| Security (apiKey, HTTP, OAuth2, OpenID Connect) | parsed (not enforced) | yes | Client attaches credentials via config; OAuth2/OpenID Connect: bearer token only. Server-side: see [server-security.md](./server-security.md) — the spec's `security:` requirement is parsed but the generated router does not emit a 401 for missing/invalid credentials. Handlers must enforce auth themselves. |

## What is rejected

Generation stops with a diagnostic for these JSON Schema 2020 keywords
and OpenAPI features that have no faithful Gleam translation today:

- `$defs`, `prefixItems`, `if/then/else`, `dependentSchemas`, `not`,
  `unevaluatedProperties`, `unevaluatedItems`, `contentEncoding`,
  `contentMediaType`, `contentSchema`
- XML request/response bodies with structural decoding, `xml`
  annotations, and `mutualTLS` security

Parsed but not yet turned into code: callbacks, webhooks, `externalDocs`,
tags, examples, links, and `encoding` metadata.

<!-- BEGIN GENERATED:BOUNDARIES -->
## Current boundaries

This section stays in sync with `src/oaspec/internal/capability.gleam`.

- Detected and rejected keywords: `$defs`, `prefixItems`, `if/then/else`, `dependentSchemas`, `not`, `unevaluatedProperties`, `unevaluatedItems`, `contentEncoding`, `contentMediaType`, `contentSchema`, `mutualTLS`, `$id`, `const (non-string)`, `type: [T1, T2] with type-specific constraints`
- OpenAPI 3.1 `$id`-backed URL refs are still rejected during validation. Rewrite them to local `#/components/schemas/...` refs.
- `const` is only supported on string schemas. Non-string `const` values and multi-type schemas with type-specific constraints are rejected explicitly.
- Parsed but not used by codegen: callbacks, webhooks, externalDocs, tags, examples, links, encoding
- `xml` annotations are ignored by the parser
- Remaining server-mode request-shape boundaries: `server: complex path parameters`, `server: non-primitive query array items`, `server: non-primitive header array items`, `server: complex deepObject properties`, `server: mixed form-urlencoded request`, `server: mixed multipart request`, `server: complex multipart fields`, `server: unsupported request content type`
- Detailed server-mode decisions and fixture coverage live in [server-mode-boundaries.md](./server-mode-boundaries.md)
- Normalized to supported equivalents: `const` string values become single-value enums, `type: [T, null]` becomes nullable, and `type: [T1, T2]` becomes `oneOf`
<!-- END GENERATED:BOUNDARIES -->
