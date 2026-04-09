# OpenAPI 3.x Full Support Plan

This document is the working plan for closing the gap between the current
`oaspec` implementation and practical full OpenAPI 3.x support for both client
and server generation.

## Scope

The goal is not only to parse OpenAPI 3.x losslessly, but to make generated
code behave correctly for the supported feature set across:

- parser
- validation
- hoisting / dedup / IR
- type generation
- encoder / decoder generation
- client generation
- server generation
- CLI / reporting
- integration tests
- README support matrix

## Reference Material

Local references checked into `doc/reference`:

- `doc/reference/oapi-codegen/README.md`
  - strict server section shows practical support targets for
    request/response media types, multipart, form-urlencoded, and automatic
    content-type/status handling
- `doc/reference/libopenapi/datamodel/schemas/oas3-schema.json`
  - parameter style defaults and legal values for `path`, `query`, `header`,
    and `cookie`
- `doc/reference/openapi-generator/`
  - broad sample matrix for request/response combinations and schema features
- `doc/reference/kiota/`
  - client-focused reference for request builders, serialization, and
    discriminated response handling

## Current Reality

The repository already parses and preserves much more of OpenAPI 3.x than the
current README claims. Some gaps are codegen gaps, some are validation gaps,
and some are documentation drift.

Examples of drift already visible in the tree:

- `PathItem.$ref` is implemented in `src/oaspec/openapi/parser.gleam`, but
  `README.md` still lists it as unsupported.
- The README currently claims support for some server features that validation
  now rejects until router parsing is upgraded.

## Workstreams

### 1. Truthful support matrix

Needed work:

- align `README.md` with real behavior
- keep validation, tests, and generated code expectations consistent
- record target scope for each feature: `client`, `server`, or `both`

Definition of done:

- no feature is simultaneously documented as supported and rejected at runtime
- ShellSpec and unit tests assert the same behavior

### 2. Server request parsing parity

Needed work:

- cookie parameter parsing
- query parameter arrays
- deepObject parsing
- header/query scalar parsing consistency
- request-body parsing beyond JSON:
  - `application/x-www-form-urlencoded`
  - `multipart/form-data`
- request parsing API that can represent repeated query keys and parsed cookies

Definition of done:

- server router can construct typed request values for supported OpenAPI
  parameter/body shapes without placeholder code or validation escapes

### 3. Response emission parity

Needed work:

- multiple response content types on server
- response header emission
- preserving / selecting response content-type in generated server code

Definition of done:

- handler return types can express the chosen payload and headers without
  silent loss of metadata

### 4. Schema / JSON Schema coverage

Needed work:

- OpenAPI 3.1 specific JSON Schema features currently called out as missing
- `xml` metadata handling
- more object/array constraints in guards
- verification for `readOnly`, `writeOnly`, and discriminator edge cases

Definition of done:

- parser, IR, and codegen agree on the 3.1 features intentionally supported

### 5. Preserved-but-unused fields

Needed work:

- top-level `webhooks`, `externalDocs`, `tags`
- `Parameter.content`, `examples`
- `MediaType.encoding`, `examples`
- `Response.headers`, `links`
- `components.headers`, `examples`, `links`
- `servers` metadata on path/operation level

Definition of done:

- either codegen uses the field or validation emits a precise warning and the
  README says so

## Priority Order

1. Fix support-matrix drift and missing coverage around already-partial server
   features.
2. Build a reusable server request parsing layer.
3. Remove server-target validation rejections as each parser capability lands.
4. Expand response generation to carry content-type and headers.
5. Revisit advanced OpenAPI 3.1 / XML metadata once request/response basics are
   reliable.

## Incremental Delivery Plan

### Phase A: correctness and drift

- [x] roadmap and handoff docs committed
- [ ] README support table corrected
- [x] server cookie parameters supported
- [ ] tests cover server cookie parsing end-to-end

### Phase B: server structured parameters

- [x] repeated query key representation added to server route API
- [x] query array parsing implemented
- [x] deepObject parsing implemented for flat object params with inline primitive
  and inline primitive-array leaves
- [x] server validation updated to allow implemented structured query features
- [ ] deepObject leaf support expanded beyond inline primitives when request type
  generation can safely represent referenced enums / aliases

### Phase C: server non-JSON request bodies

- [ ] form-urlencoded request parsing
- [ ] multipart request parsing
- [ ] integration fixtures for both content types
- [ ] server validation relaxed for implemented content types

### Phase D: response fidelity

- [ ] multi-content response handling on server
- [ ] response headers in generated server output
- [ ] warnings removed where support becomes real

### Phase E: remaining 3.x / 3.1 surface

- [ ] README unsupported list audited against code
- [ ] XML metadata decision made and implemented or explicitly deferred
- [ ] advanced 3.1 keywords triaged individually

## Notes For Future Sessions

- Prefer adding an OpenAPI fixture plus a failing unit test before changing
  validation or codegen.
- If server parsing is expanded, update integration tests to compile generated
  code with `--warnings-as-errors`.
- When a feature is implemented for only one target, keep capability filtering
  target-aware instead of widening `Both` support prematurely.
- The generated server route signature is now
  `Dict(String, List(String))` for query values; new parsing features should
  build on that multimap rather than collapsing back to a single string.
