# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **`text/plain` is now a supported request body content type** in both
  client and server modes. Specs that declare a `text/plain` request
  body (e.g. GitHub REST `markdown.render-raw`) previously tripped the
  "unsupported request content type" diagnostic; they now generate
  working code. Client codegen wraps the body in `transport.TextBody`
  as a raw string (no JSON quoting), and the server router passes the
  request body through to handlers as `String`. (#352)

## [0.30.0] - 2026-04-30

### Fixed

- **`type: 'null'` inside `oneOf` / `anyOf`** is now accepted as the
  OpenAPI 3.1 nullable-via-union form. Previously the parser rejected
  it with `Unrecognized schema type 'null'`, which blocked specs like
  the GitHub REST OpenAPI from being generated. The null branch is
  filtered out and `nullable: true` is lifted onto the parent schema's
  metadata, matching the existing behaviour for the array form
  `type: [T, 'null']`. A standalone `type: 'null'` schema (outside any
  composition) is also accepted now and represented as an unrestricted
  nullable schema, mirroring the existing fallback for
  `type: ['null']`. (#349)

## [0.29.0] - 2026-04-29

### Fixed

- **`oneOf` decoders now enforce exactly-one-match semantics**, per
  JSON Schema 2020-12 §10.2.1.3. Generated non-discriminator
  `oneOf` decoders previously emitted `decode.one_of(first,
  [rest..])`, which is first-match (i.e. `anyOf`) semantics — a
  body that validated against multiple branches was silently
  accepted as the first-listed variant, with the other branches'
  fields dropped. The generator now emits a body that runs every
  branch independently against the raw `Dynamic` (via
  `decode.run`), counts successes, and:
  - succeeds with the matched variant when exactly one branch
    matched,
  - fails with `"<TypeName>: matched multiple oneOf branches;
    expected exactly one"` when 2+ branches matched (the new
    rejection — previously accepted),
  - fails with `"<TypeName>: no oneOf branch matched"` when zero
    branches matched (same as before, just with a clearer
    message).
  This adds `gleam/list` and `gleam/result` to the imports of any
  generated `decode.gleam` that surfaces a non-discriminator
  `oneOf`. Discriminator-based `oneOf` decoders are unchanged
  (the discriminator already picks a single variant, so multi-
  match is structurally impossible). Behavioral change for
  clients sending bodies that match multiple branches: their
  previously-passing JSON now rejects, which is the spec's
  intended behavior. (#337)

- **`additionalProperties: false` is now enforced at decode time.**
  Generated decoders for closed object schemas previously accepted
  JSON bodies containing unknown fields and silently dropped them —
  the strictest opt-in OpenAPI validation knob was a no-op. The
  decoder now reads the raw JSON object as `Dict(String, Dynamic)`,
  drops the declared property keys, and fails the decode with the
  reason `"additionalProperties"` if any extras remain. The check
  happens in the decoder body because `gleam/dynamic/decode`
  consumes only declared fields, so a post-decode validator could
  not recover the raw key set. Behavioral change for clients
  already mishandling extras: their previously-passing JSON now
  rejects, surfacing the spec violation. The `additionalProperties: true` and `additionalProperties: { schema }`
  variants are unchanged. (#336)

### Changed

- **`guards.gleam` codegen** no longer emits byte-identical per-field
  validator function bodies for the same property repeated across
  `allOf` children. The generator now post-processes the emitted
  source: when several `validate_<schema>_<field>_<kind>` functions
  share an identical body, the lex-first name keeps the canonical
  body and the others are rewritten as 1-line delegating stubs that
  forward to it. Composite validators are unchanged — they continue
  to call per-field validators by their original names, so
  call-site code stays the same. Net effect on a typical spec with
  one `allOf` reuse: ~16 lines saved per redundant validator. (#339)

### Documentation

- README "OpenAPI Support" now has an explicit section on
  `format: byte` / `format: binary` documenting the current
  pass-through-as-String behaviour and the implications for callers
  (manual base64 decode required for `format: byte`, no validation
  on invalid base64 input). Materialising `format: byte` as
  `BitArray` automatically remains a future enhancement tracked on
  #338. (#338)

### Added

- New pure runtime modules `oaspec/transport` and `oaspec/mock`. Generated
  client code depends on these instead of `gleam/http/request`. `transport`
  defines `Method` / `Body` / `Request` / `Response` / `TransportError` /
  `Send`, plus middleware for base URL override (`with_base_url`), default
  headers (`with_default_header(s)`), and OpenAPI security
  (`credentials() |> with_bearer_token / with_api_key / ... |>
  with_security(send, _)`). `mock` provides one-liner test helpers
  (`mock.text`, `mock.bytes`, `mock.empty`, `mock.timeout`, `mock.fail`,
  `mock.from`).
- New sibling Gleam package `adapters/httpc/` exporting `oaspec/httpc`,
  a thin BEAM adapter backed by `gleam_httpc`. Root `oaspec` does not
  depend on `gleam_httpc`; the adapter packaging keeps the runtime
  concern isolated. The simplest usage is just `httpc.send` (a function
  reference matching `transport.Send`); a `config() |> with_timeout(_)
  |> build` builder is available for tuned configurations.
- Generated clients now expose three public functions per operation —
  `<op>(send, ...)`, `build_<op>_request(...)`, and
  `decode_<op>_response(resp)` — so request building and response
  decoding can be driven independently for testing or middleware.

### Changed

- **BREAKING**: Generated client API has been rebuilt around
  `oaspec/transport`. (#333)
  - `ClientConfig`, `ClientResponse`, and the per-scheme `with_*` helpers
    are removed. Operations take `send: transport.Send` directly. Auth
    flows through `transport.with_security` middleware on the user side.
  - `ClientError` no longer carries `ConnectionError` / `TimeoutError` /
    `DecodeError` / `InvalidUrl`. Their roles are covered by
    `TransportError(transport.TransportError)` (runtime/network failure),
    `DecodeFailure(detail:)` (body shape decode error),
    `InvalidResponse(detail:)` (body-shape mismatch with the spec), and
    a new `UnexpectedStatus { status: Int, headers: List(#(String,
    String)), body: transport.Body }` (carries headers + body so callers
    can drill into the unexpected response).
  - Security requirements now flow through the request as a
    `List(SecurityAlternative)` metadata list rather than being inlined
    into operation bodies. `transport.with_security` evaluates the
    OpenAPI OR-of-AND alternatives and applies the first one whose
    required schemes have credentials.
  - Body bytes flow as `transport.Body` (`TextBody` / `BytesBody` /
    `EmptyBody`) end to end, matching the existing server-side
    `BytesBody(BitArray)` contract for binary payloads.
- `examples/petstore_client` rewritten to use the new send-first API
  with `oaspec/mock` for its stub transport.

### Migration

Before:

```gleam
let config =
  client.new(client.default_base_url(), my_send)
  |> client.with_bearer_auth(token)

client.get_pet(config, 1)
```

After:

```gleam
import oaspec/httpc
import oaspec/transport

let send =
  httpc.send
  |> transport.with_base_url(client.default_base_url())
  |> transport.with_security(
    transport.credentials()
    |> transport.with_bearer_token("BearerAuth", token),
  )

client.get_pet(send, pet_id: 1)
```

## [0.27.0] - 2026-04-28

### Changed

- **internal modules**: The codegen IR, OpenAPI traversal helpers
  (resolve, normalize, hoist, dedup, capability check, location
  index, schema and spec ASTs, parser_error, parser_schema,
  diagnostic_format, external_loader, operations, provenance,
  resolver, value), capability detection, formatter, CLI dispatch,
  and util helpers all moved under `src/oaspec/internal/` and the
  directory tree is now registered as `internal_modules` in
  `gleam.toml`. The published Library API surface — the
  `oaspec/openapi/parser`, `oaspec/openapi/diagnostic`,
  `oaspec/config`, `oaspec/generate`, and `oaspec/codegen/writer`
  modules — is unchanged. The Hex docs no longer publish the
  internal modules, and downstream pins to the now-internal
  identifiers will need to migrate to the curated facade. With
  most of the IR / parser implementation behind an `internal/`
  boundary, internal renames no longer require a major bump. (#328)

### Fixed

- **codegen/server_request_decode**: The deep-object query parameter
  decoder no longer emits `let assert Ok([v, ..]) = dict.get(...)`
  for required fields. The generator now emits a `case` expression
  that falls back to a per-type zero default (`""` / `0` / `0.0` /
  `False` / `[]` / `dynamic.nil()`) when the deep-object key is
  absent, mirroring the existing optional-field policy. The same
  rewrite applies to the required-body extractor: the body decoder
  is no longer wrapped in `let assert Ok(_) = decode_fn` — the
  generated handler now matches on the `Result` and falls back to a
  zero-valued body if decoding fails. Generated server code can no
  longer crash the BEAM process on adversarial query strings or
  body payloads. Completes the partial fix from v0.26.0. (#327)

## [0.26.0] - 2026-04-28

### Fixed

- **codegen/encoders**: the `encode_dynamic` helper emitted by the
  encoder generator no longer uses `let assert Ok(_) = decode.run(...)`
  inside its `dynamic.classify` branches. The String / Int / Float /
  Bool branches now pattern-match the `Result` and fall back to
  `json.null()` on `Error(_)`, matching the existing catch-all
  policy. Adversarial Dynamic values (e.g. a value whose runtime
  classification disagrees with the typed extractor) no longer
  crash the BEAM process inside the generated encoder. Golden
  tests (`golden/petstore`, `golden/complex_supported`) are
  unaffected because neither schema requires the helper. Partial
  fix toward #327 — the deep-object decoder rewrite in
  `server_request_decode.gleam` is its own follow-up. (#327)

## [0.25.0] - 2026-04-28

### Fixed

- **codegen**: An optional + `nullable: true` property whose schema
  type is a `$ref` (which `hoist` produces for any non-trivial inline
  shape — for example, an object with `additionalProperties: ...`) is
  now wrapped in `Option(...)` in the generated types module. Previously
  the types module declared the field as the bare ref name (e.g.
  `attributes: EventAttributes`) while the decoder emitted
  `decode.optional_field(..., decode.optional(...))` and the encoder
  pattern-matched `case value.field { None -> [] Some(x) -> ... }` —
  both of those treat the field as `Option(EventAttributes)`. The
  resulting type-level disagreement caused 6 compile errors in the
  generated module. With the fix the three modules agree. Closes #321.

- **codegen**: The encoder for an object schema with `additionalProperties:
  { type: <T> }` no longer emits a `;`-separated lambda body. The previous
  output (`fn(entry) { let #(k, v) = entry; #(k, ...) }`) was a deprecated
  pre-1.0 syntax that the current Gleam parser rejects with `Semicolons used
  to be whitespace and did nothing`. `oaspec generate` would then run
  `gleam format` over the freshly written file and exit with `Error: gleam
  format failed with exit code 1` — masking the real cause. The replacement
  emits a multi-line lambda body that the parser accepts and `gleam format`
  is free to re-fold. Closes #320.

- **config**: oaspec now refuses an `output.dir` value that places the
  package directory underneath a `src/` subdirectory (e.g.
  `./src/gen`). The previous behaviour silently emitted files at
  `src/gen/<pkg>/types.gleam` while imports inside those files said
  `import <pkg>/types` — paths the Gleam compiler can't resolve, so
  `gleam build` failed with a wall of `Unknown module ...` errors and
  no diagnostic from oaspec. The check accepts both `./src` (generated
  modules live directly under the project's `src/`) and any path
  outside an existing `src/` tree (treated as a standalone Gleam
  project root). Closes #319.

- **codegen**: Generated `router.gleam` now imports the package's
  `types` module when an OpenAPI operation has an `$ref`-based string
  enum query, header, or cookie parameter. Previously the router body
  emitted `types.<EnumType><Variant>` references in the inline match
  expressions for those parameters but the import was gated only on
  deep object / form / multipart bodies, so a spec like `parameters: [{
  in: query, name: status, schema: { $ref:
  '#/components/schemas/BookStatus' } }]` produced a router that
  failed to compile (`Unknown module types`). Closes #318.

## [0.24.0] - 2026-04-28

### Changed

- **codegen (BREAKING)**: A required, inline `type: string, enum:
  [<single-value>]` property is now treated as a constant. The generated
  Gleam record drops the field, no tautological one-variant `*Kind` enum
  is emitted, the encoder inlines `json.string("<value>")` without
  reading a record field, and the decoder validates the wire value
  matches and discards it. Optional single-value enums (the
  `Some(theOnlyVariant) | None` case) are unchanged because the
  presence/absence distinction is still meaningful. Multi-value enums,
  `$ref`'d enum components, and standalone enum schemas are also
  unchanged. Constructors that previously had to restate
  `kind: TextPostRequestKindText` lose that argument; spec violations
  on the wire (`kind: "media"` where only `kind: "text"` is legal) now
  surface as decode errors instead of silently passing through. (#309)
- **codegen (BREAKING)**: Spec-declared response headers now reach the
  wire. When a response declares `headers:`, the generated
  `response_types.<Op>Response<Status>` constructor grows a typed
  headers slot (e.g. `ListPostsResponseOk(types.PostPage,
  ListPostsResponseOkHeaders)`) so handlers must supply the values, and
  the router's dispatch arm pattern-matches `(data, hdrs)` and merges
  the typed values into `ServerResponse.headers` alongside the implicit
  `content-type` tuple via `list.flatten([...])`. Required headers emit
  `[#("Header-Name", value)]`; optional ones contribute `[]` when None.
  Primitive non-string types (`Int`, `Float`, `Bool`) are stringified
  via `int.to_string` / `float.to_string` / `bool.to_string` (with the
  matching `gleam/<type>` import added automatically). The
  `*Headers` types previously generated as dead code are now wired
  through end-to-end. (#306)
- **codegen (BREAKING)**: The generated `router.ServerResponse.body`
  field is now a `ResponseBody` sum type — `TextBody(String)`,
  `BytesBody(BitArray)`, or `EmptyBody` — instead of a fixed `String`.
  Specs that declare `application/octet-stream` (or other binary)
  responses now round-trip real bytes end-to-end via
  `BytesBody(BitArray)`; the matching `response_types.<Op>ResponseOk`
  variant carries `BitArray` instead of `String`. Text responses move
  from raw `body: data` to `body: TextBody(data)`, JSON responses move
  from `body: json.to_string(...)` to `body: TextBody(json.to_string(...))`,
  and no-content responses dispatch to `EmptyBody`. RFC 7807 problem
  bodies are wrapped in `TextBody(...)`. Framework adapters must
  pattern-match on `response.body` to call their text- or bytes-shaped
  response constructor instead of treating it as a `String`. (#304)

### Fixed

- **codegen**: Generated routers now respond with RFC 7807-shaped
  `application/problem+json` JSON for every error path (request body
  decode failure, path/query/header parameter parse failure, missing
  required parameter, unmatched route) instead of the previous plain
  `Bad Request` / `Not Found` text without a `Content-Type` header.
  Status codes are unchanged. Bodies follow the form
  `{"type":"about:blank","title":"<reason>"}`. (#307)
- **codegen**: Optional non-nullable schema properties are now omitted
  from the encoded JSON object when their `Option` field is `None`.
  Previously the generator emitted `"<key>": null` via `json.nullable`,
  producing schema-invalid output (per OpenAPI 3.0/3.1 only fields
  marked `nullable: true` may carry `null` on the wire). When at least
  one property in a schema falls into this bucket, encoders now emit
  `json.object(list.flatten([...]))` with each optional-non-nullable
  field contributing either `[]` (None) or `[#(<key>, encode(x))]`
  (Some). Required and nullable properties are unchanged. (#303)
- **codegen**: Query parameters whose schema `$ref`s a string-enum
  component now generate compilable Gleam. Previously the router tried
  to assign the raw `String` from `dict.get(query, key)` directly into
  the enum-typed field, producing a type mismatch. Optional enum query
  params now emit an inline `String → Some(<Variant>) | None` match;
  required ones get the same `Result`-based open/close scaffold as
  numeric params (unknown values yield 400 Bad Request). (#305)
- **codegen**: Discriminated `oneOf` decoders no longer surface a misleading
  inner-variant decode error when the discriminator value is unknown. The
  catch-all branch now short-circuits with a discriminator-specific
  message (`<TypeName>: unknown discriminator '<value>' (expected
  <valid|values>)`) before the first variant's decoder runs. (#308)

## [0.23.0] - 2026-04-27

### Fixed

- **codegen**: Inline complex schemas (object, allOf, oneOf, anyOf) in
  decoder/encoder dispatch now panic with a clear message instead of
  silently generating `decode.string` (runtime crash). (#290, #298)
- **codegen**: Optional integer/float array query parameters and body
  fields no longer crash the server on malformed input — `let assert`
  replaced with safe `case` fallback. (#291, #301)
- **codegen**: oneOf/anyOf encoders now panic clearly when any variant
  is inline instead of silently skipping generation. (#295, #301)
- **codegen**: Required nullable properties now encode with
  `json.nullable` instead of generating a type mismatch. (#296, #301)
- **codegen**: Circular schema `$ref` chains no longer cause infinite
  recursion — cycle detection added to constraint traversal. (#297, #301)
- **codegen**: Response header `$ref` schemas now resolve to the
  correct type instead of falling back to `String`. (#294, #299)
- **validate**: Schema names that differ only in case (e.g. `Foo` and
  `foo`) are now detected at generation time with a clear diagnostic
  instead of causing a post-codegen compile failure. (#293, #300)

### Documentation

- Guard validation currently only fires for `$ref` body schemas;
  inline schema limitation documented as a tracked follow-up. (#292)

## [0.22.0] - 2026-04-27

### Fixed

- Generated record fields no longer split letter+digit identifiers, so
  `rev_b58`, `sha256`, `port_8080`, `iso8601`, etc. survive codegen
  unchanged instead of becoming `rev_b_58` / `sha_256` / `port_8_080`.
  Matches the convention sqlode landed on in nao1215/sqlode#480; the
  digit→letter direction (`256sha` → `256_sha`) still splits because
  that asymmetry is the standard reading. (#283)

### Added

- `oaspec generate` now prints a `Note:` line at the end of generation
  reminding the user to `gleam add gleam_regexp` when the generated
  code imports `gleam/regexp` for pattern validation. Without the
  direct dep, `gleam build` warns about the transitive import (and a
  future Gleam release turns this into a hard error). The hint is only
  printed when at least one generated file actually imports
  `gleam/regexp`. (#284)

## [0.21.0] - 2026-04-26

### Changed

- **BREAKING**: generated handlers now thread an application `State`
  value. `handlers.gleam` (user-owned) gains a `pub type State { State }`
  placeholder at the top of the file, and every handler signature
  becomes `pub fn <op>(state: State, req: ...) -> ...`. The sealed
  `handlers_generated.gleam` and `router.gleam` are updated to match,
  and `pub fn route` now takes `app_state: handlers.State` as its first
  argument: `route(app_state, method, path, query, headers, body)`.
  Construct a `handlers.State` value once in your `main` (extending the
  type with DB connections, configuration, loggers, etc. as you go) and
  pass it to `route`. Migration for projects with existing
  `handlers.gleam`: add `pub type State { State }` near the top, add
  `state: State,` as the first parameter to each handler, and
  `let _ = state` if the handler doesn't yet use it. The route argument
  is named `app_state` (not `state`) so OpenAPI specs that have a
  parameter literally called `state` (OAuth2 flows, etc.) do not shadow
  it. (#264)
- **BREAKING**: generated `guards.gleam` validators now return
  structured `ValidationFailure(field, code, message)` values instead of
  bare strings. Helper signatures change from `Result(_, String)` to
  `Result(_, ValidationFailure)`, and composite `validate_*` functions
  change from `Result(_, List(String))` to
  `Result(_, List(ValidationFailure))`. `code` is the JSON Schema
  keyword that failed (`minLength` / `maximum` / `pattern` /
  `multipleOf` / `uniqueItems` / `minProperties` / etc., plus
  `invalidPattern` for regex compile errors), `field` is the OpenAPI
  property name (empty for top-level constraints), and `message` keeps
  the previous human-readable text. Server `router.gleam` now serialises
  the 422 body via `guards.validation_failure_to_json` so each failure
  is its own JSON object instead of a string. Generated client
  `ClientError.ValidationError` carries
  `errors: List(guards.ValidationFailure)`. To migrate, replace
  `Error(msg) -> ...` arms with
  `Error(failure) -> ...` and read `failure.field`, `failure.code`,
  `failure.message`; the previous prose is still available as
  `failure.message`. (#269)

### Fixed

- Generated `router.gleam` no longer crashes the BEAM process when a
  required query, header, or cookie parameter is missing or a required
  integer/number parameter fails to parse. The router now returns
  `ServerResponse(status: 400, body: "Bad Request", headers: [])`
  instead of triggering supervisor restarts via `let assert`. Deep
  object parameters retain the previous behaviour pending a separate
  follow-up. (#263)

## [0.20.0] - 2026-04-26

### Fixed

- Client-only mode (`mode: client`) now writes generated files to
  `<output.dir>/<package>/` instead of `<output.dir>/<package>_client/`,
  so the directory matches the `import <package>/...` lines emitted in
  the generated code. Previously a fresh `gleam new` + `gleam add
  oaspec` + `gleam run -m oaspec -- generate` pipeline failed
  immediately with `Unknown module: <package>/decode` and friends. The
  `_client` suffix is preserved in `Both` mode (where server and
  client need distinct basenames inside one `<dir>`). (#262)

### Added

- `application/octet-stream` is now accepted as a request-body content
  type. Binary upload endpoints (S3 PutObject-style, image upload, PDF
  upload, log shipping, sensor data) can be described in OpenAPI specs
  and pass through codegen. The body parameter is currently `String`
  (binary-safe on the Erlang target); a `BitArray`-typed body is
  tracked as future work. (#265)

## [0.19.0] - 2026-04-26

### Changed

- **BREAKING (default)**: when `validate:` is omitted from
  `oaspec.yaml`, the default is now mode-dependent rather than always
  `false`: `mode: server` and `mode: both` default to `true`, while
  `mode: client` defaults to `false`. Previously the silent default
  was `false` for every mode, which let schema-invalid input
  (`minimum`, `maximum`, `pattern`, `minLength`, `maxLength`
  violations) flow straight into user handlers — security-adjacent
  because handlers can do real work (SRS / scoring algorithms,
  length-bounded fields with downstream compute, pattern-bounded
  fields used for SQL parameter generation, etc.) on input they
  assumed was constraint-checked. Server-side codegen is now
  fail-closed by default. Explicit `validate: true` / `validate:
  false` keeps overriding regardless of mode. Migration: if you
  generated server code and relied on the no-validation default,
  add `validate: false` explicitly to opt out, or remove handler
  code that handled out-of-range input. The CLI flag
  `--validate=true` (which only adds, never removes, validation)
  is unchanged. (#268)

### Added

- `application/x-ndjson` (newline-delimited JSON) is now accepted as
  a response content type. NDJSON is widely deployed for streaming
  JSON Lines responses (Elasticsearch bulk API, Loki, OpenAI
  streaming endpoints, log shippers) and the previous "unsupported
  response content type" rejection blocked any spec that used it.
  For codegen purposes the body is a `String` and no per-line
  decoding happens at the SDK layer, so the implementation aliases
  to the existing `text/plain` branch in `content_type.from_string`.
  The original `application/x-ndjson` string is still embedded
  verbatim into the generated server's `Content-Type` response
  header (the codegen pulls the media-type name from the spec, not
  from the alias). Same behaviour applies to validate-only runs
  via `oaspec validate`. (#261)

### Fixed

- A spec that defines both `Foo` and `FooList` component schemas
  (or any `<Name>` + `<Name>List` pair) used to fail at `gleam build`
  time with `Duplicate definition: decode_<name>_list` rather than
  during validation. The synthetic list decoder for `Foo` and the
  user-named decoder for `FooList` collided on the same identifier
  in `decode.gleam`. The validator now detects the pair before
  codegen and emits a spec-level diagnostic naming both schemas and
  the offending identifier, with rename suggestions
  (`<Name>Collection`, `<Name>Page`, `<Name>Items`). Specs that only
  define one of the pair are unaffected. (#267)
- A 2xx response whose schema is a top-level array of primitive items
  (`type: array, items: { type: string }` etc.) used to generate
  `body: json.to_string(json.string(data))` in the server router,
  which fails to type-check because `data: List(String)` is fed into
  the scalar `json.string` encoder. The codegen now emits
  `fn(items) { json.array(items, json.<primitive>) }` for inline
  primitive-item arrays (`string` / `integer` / `number` / `boolean`)
  and falls back to `json.array(items, json.string)` for inline
  non-primitive items rather than the previous `json.string`
  fallback that produced uncompilable code. Top-level array of `$ref`
  items already worked through the existing `Reference` branch and
  is unaffected. (#266)
- `oaspec generate --config oaspec.yaml` (GNU long-option form with a
  space between flag and value) is now accepted in addition to the
  existing `--config=oaspec.yaml`. Previously the space-separated form
  failed with the misleading `invalid flag 'config'`, because the
  underlying CLI parser (glint 1.x) only recognises the `=`-joined
  form. `oaspec.main` now normalises the argv before handing it to
  glint, translating `--name value` into `--name=value` for the
  value-bearing long options listed in `oaspec/cli.value_flag_names`
  (`--config`, `--mode`, `--output`). Equals-form, boolean-flag,
  positional, and unknown-flag callers are unaffected. Same behaviour
  for `validate` and `init`. (#260)

## [0.18.0] - 2026-04-25

This release is a UX overhaul of the generated server / client surface.
The generator now distinguishes user-owned files from sealed wrappers,
the default output layout is `gleam build`-friendly, closed-object
schemas no longer drag a `Dict(String, Dynamic)` field through every
constructor call, and the CLI honours POSIX/CLIG conventions for stderr,
`NO_COLOR`, and version reporting. Most entries below are breaking
changes — see each entry for migration steps.

### Changed

- **Generated handlers split into a sealed delegator and a user-owned stub (#247) — breaking for code that imports `<package>/handlers` outside of `handlers.gleam` itself**: previously `oaspec generate` emitted a single `handlers.gleam` with a `// DO NOT EDIT` banner *and* `panic as "unimplemented: ..."` stubs the user had to replace, and re-running the generator clobbered the user's implementation. The handler surface is now two files. `handlers_generated.gleam` is sealed (`// DO NOT EDIT`, always overwritten) — each operation forwards to `handlers.<op_name>(req)` — and `router.gleam` imports it. `handlers.gleam` is now user-owned: the generator writes panic stubs on the first run and skips the file on every subsequent run, so user implementations survive regeneration. The codegen IR gained a `WriteMode` field (`Overwrite` / `SkipIfExists`); the writer honours it and `--check` ignores `SkipIfExists` files so user edits do not show up as drift. **Migration**: code that previously imported `<package>/handlers` from anywhere except `handlers.gleam` itself (e.g. a custom `router.gleam` users hand-wrote on top of the old single-file shape) now needs to import `<package>/handlers_generated`. The bundled router and the integration suite are updated automatically.
- **`output.dir` default client path moved inside the base directory (#248) — breaking for configs that omit `output.client`**: when `oaspec.yaml` set only `output.dir: ./src` (no explicit `output.server` / `output.client`), the generator used to write client artifacts to a sibling `./src_client/<package>/` — outside any Gleam `src/` root, so `gleam build` did not see them. The default derivation is now `<dir>/<package>` for the server and `<dir>/<package>_client` for the client, both under `<dir>`. A single `gleam build` rooted at `<dir>` (e.g. when `<dir>` is the project's `src/`) picks up both. The CLI `--output=<dir>` override applies the same new derivation. **Migration**: configs that explicitly set `output.server` and `output.client` are unaffected. Configs that relied on the implicit `<dir>_client/<package>` derivation either need to add `output.client: <old-path>` to keep the previous location, or move existing client output from `<dir>_client/<package>/` to `<dir>/<package>_client/`.
- **Closed-object schemas no longer emit `additional_properties` (#249) — breaking for downstream consumers**: previously the parser folded "key absent in source" and `additionalProperties: true` into the same `Untyped` variant, so every generated object record carried a noisy `additional_properties: Dict(String, Dynamic)` field that constructor calls had to populate with `dict.new()`. The AST now distinguishes `Unspecified` (key absent) from `Untyped` (explicit `true`); only the latter (and `Typed(...)`) emits the field. Closed-object record types — by far the common case — drop the field entirely. **Migration**: callers who relied on the implicit Dict on a closed schema must either remove the `additional_properties: dict.new()` argument from their constructor calls, or add `additionalProperties: true` to the spec to keep the field. allOf merge, dedup, deepObject collection, and form-urlencoded constructors are all updated to honour the new variant.

### Added

- **`--version` flag and `version` subcommand (#252)**: both `oaspec --version` and `oaspec version` now print `oaspec v<X.Y.Z>` (sourced from `context.version`) and exit 0. The flag is intercepted by `main()` before glint is invoked so it does not need to be wired through every subcommand; the subcommand is registered through glint so it appears in `--help` and supports `oaspec version --help`. Both forms answer the "what version of oaspec wrote this generated code?" question without requiring users to inspect package metadata.

### Fixed

- **CLI diagnostics now route to stderr (#251)**: error messages, warnings, and `--check` mismatch reports are written via `io.println_error` instead of `io.println`, and the top-level entry point uses `glint.execute` so glint's own usage/error text goes to stderr with exit code 1. Help text requested explicitly via `--help` still goes to stdout. Pipelines like `oaspec | jq` no longer receive diagnostic noise on stdin, and `2>&1` redirection produces the expected ordering.
- **Suppress ANSI colour codes when stdout is not a TTY or `NO_COLOR` is set (#250)**: `pretty_help` was being applied unconditionally, so `oaspec --help > help.txt`, `oaspec --help | less`, and `NO_COLOR=1 oaspec --help` all leaked ANSI escape sequences into the captured output. `app()` now checks `io:getopts(standard_io)` for an interactive terminal and consults the `NO_COLOR` environment variable (per <https://no-color.org/>) before installing glint's pretty-help colours. The detection helpers live in `oaspec_ffi` next to the existing executable lookup helpers.

## [0.17.0] - 2026-04-23

This release tightens the OpenAPI 3.0/3.1 support boundary: every shape
that used to succeed parsing but silently lose semantics at codegen now
fails fast with a dedicated diagnostic, and the two remaining reliability
gaps (request-type field collisions, external-ref cycles) are fixed.

### Added

- **Callbacks: lossless `$ref` preservation and consistent warnings (#232)**: `Components` gained a `callbacks: Dict(String, RefOr(Callback(stage)))` field and the parser now populates `components.callbacks`. Operation-level `{ myEvent: { $ref: '#/components/callbacks/foo' } }` is kept as `Ref(...)` instead of being silently re-interpreted as an inline URL-expression map. `resolve` walks ref-alias chains (rejecting dangling targets and cycles), and `capability_check` emits `Warning` diagnostics for both operation-level and component-level callbacks so `validate` on callback-heavy specs no longer prints a bare `Validation passed.`
- **Cyclic external-ref detection (#233)**: `parser.parse_file` threads a visited-file stack through every recursive external-ref load (top-level schemas, nested property / array / composition / parameter / requestBody / response / callback rewrites). Re-entering a file that is already on the stack returns an `invalid_value` diagnostic that shows the full `A → B → A` chain instead of looping forever.

### Changed

- **Reject non-3.x OpenAPI versions (#235)**: the root `openapi` field is now validated up front. Only `3.0.x` and `3.1.x` (plus the two-segment `3.0` / `3.1` forms for YAML-float compatibility) are accepted. Bare `3`, `2.0`, `4.0.0`, and malformed forms like `3.0.foo` / `3.0.0.1` fail with an `invalid_value` diagnostic; previously these all silently produced meaningless output.
- **Reject duplicate `operationId` (#237)**: the dedup pass no longer rewrites duplicate operationIds to `foo_2` / `foo_3`. `validate` now emits a hard `invalid_value` diagnostic that lists every `METHOD /path` site claiming a colliding name, catching both literal duplicates and case-only collisions (`listItems` and `list_items` both normalize to the same generated `list_items` function).
- **OpenAPI 3.1 `$id`-backed URL refs are an explicit boundary (#234)**: URL-style `$ref` values (`$ref: https://...`), the shape same-document `$id` refs take, now produce a dedicated `URL-style $ref ... is not supported` diagnostic with a hint to rewrite to a local `#/components/schemas/...` ref. Previously they slipped through parsing and failed validation with a generic external-ref error.
- **Reject non-string `const` and lossy multi-type schemas (#238)**: `normalize` now flags non-string `const` (bool, int, number, object, array, null) as `const (non-string)` in `unsupported_keywords`, and multi-type schemas (`type: [T1, T2]`) that carry type-specific constraints (`pattern`, `minLength`, `minimum`, etc.) as `type: [T1, T2] with type-specific constraints`. Both are rejected by `capability_check` at generate time so the previous silent `pub type BoolConst = Bool` (const dropped) and silent constraint loss during the multi-type → `oneOf` rewrite never slip into generated code. Unconstrained multi-type schemas still normalize to `oneOf` unchanged.

### Fixed

- **Request-type field names collide when a parameter name is reused across locations (#236)**: the request record generated for an operation with path `id` AND query `id` would emit `GetUserRequest(id: String, id: Option(String))` and fail `gleam check` with "Duplicate label `id`". Parameter field names are now deduped with the same `_2` / `_3` suffix rule used for property names, and the dedup is collision-aware so a later literal `foo_2` keeps its label while an earlier duplicate `foo` advances to `foo_3`. Server dispatch, request-type declarations, and client builders all agree on the renamed field, and the `body` label is reserved up front so a parameter literally named `body` cannot clash with the request type's request-body field.

### Tooling

- **`just` recipes run without requiring `mise activate` (#231)**: every recipe re-sources the `scripts/lib/mise_bootstrap.sh` helper up front so fresh shells pick up the mise-managed Erlang / Gleam / rebar toolchain automatically.

### Test / tooling

- 704 → 729 unit tests (+25 across the eight Issues above).
- 223 → 229 test fixtures (+6: `collision.yaml` reshaped, `error_duplicate_operation_id.yaml` (existing) now covers rejection, 2 two-file cycle fixtures, 3 three-file cycle fixtures, 1 constrained-multi-type fixture).

## [0.16.0] - 2026-04-22

### Added

- **Human-readable diagnostic locations (#208)**: `Diagnostic.to_short_string` now translates pointer strings like `paths.~1pets.get.parameters.0` into `GET /pets, parameter #0` before printing. Recognises the common shapes for operations (parameters, requestBody, responses), schema components, parameters, responses, and requestBody components, and falls back to the escape-decoded pointer for anything unknown. The structured `Diagnostic.pointer` field itself is unchanged so a future `--format json` output can still emit the raw pointer.

### Changed

- **`parser.gleam` split along spec / schema / error concerns (#213)**: the 2,299-line monolith is now three modules with a clean dependency chain: `parser_error.gleam` (shared `missing_field_from_extraction` / `missing_field_from_selector`) → `parser_schema.gleam` (`parse_schema_ref` + its recursive internals — `parse_schema_object`, `parse_typed_schema`, `parse_properties`, `parse_discriminator`, `detect_unsupported_keywords`) → `parser.gleam` (top-level flow: file I/O, root / paths / operations). Public API (`parse_file`, `parse_string`, `parse_error_to_string`) is unchanged; generated output is byte-identical.
- **Encoder generation split out of `decoders.gleam` (#212)**: encoder emission now lives in `src/oaspec/codegen/encoders.gleam` with its own `pub fn generate/1`. `decoders.gleam` is decoder-only (~1,135 lines, down from ~1,870). `generate_shared` in `generate.gleam` now calls both sides. Shared traversal helpers (`list_at_or`, `qualified_schema_ref_type`) are duplicated rather than lifted into a third module; a `codegen/codec_dispatch.gleam` extraction stays on the follow-up list.
- **`examples/server_adapter/` restructured around a regeneration-safe handler layout (#209)**: domain logic moved into `src/example_handlers.gleam`, which the generator never touches. The checked-in `src/api/handlers.gleam` is now a one-line-per-operation delegator whose body is trivial to restore after `gleam run -- generate` overwrites it. The README's "back up your handlers before regenerating" warning is replaced with a "Recommended handler layout" section that explains the pattern.

### Test / tooling

- 684 → 704 unit tests (+20 for `diagnostic_format`).
- 3 new source modules: `openapi/parser_error.gleam`, `openapi/parser_schema.gleam`, `openapi/diagnostic_format.gleam`. 1 new codegen module: `codegen/encoders.gleam`.

## [0.15.0] - 2026-04-22

### Added

- **Reserved-keyword escaping regression guard (#215)**: new unit suite iterates every Gleam reserved keyword through `naming.to_snake_case`, `naming.operation_to_function_name`, and `naming.schema_to_type_name`, plus a `reserved_keywords` fixture that exercises keyword identifiers in record fields, `operationId`, and parameter names with `gleam build --warnings-as-errors` in server and client modes.
- **End-to-end guard rejection tests (#214)**: new `guard_constraints_api` fixture + integration steps call every emitted guard function directly against valid and invalid values (string length / pattern, integer range / exclusive range / multipleOf, float range, array length / uniqueItems, composite validator), and confirm that the `validate: true` opt-in actually embeds `guards.validate_<schema>(...)` into the generated router while the default (unset) path does not.
- **Top-level `--help` subcommand index (#206)**: `oaspec --help` now lists every registered subcommand with a one-line description, so new users can discover `init` / `generate` / `validate` without running each command individually.
- **README value-prop section (#204)**: new "Why oaspec?" section above the Quickstart with a short comparison table against hand-rolling decoders, OpenAPI Generator for other languages, and other Gleam generators.
- **README scope qualifier (#205)**: one-minute "Is oaspec right for your spec?" callout above the Quickstart so readers can self-select before going deeper.
- **Configuration path-resolution documentation (#207)**: the Configuration section of the README now describes how `oaspec.yaml` paths are resolved (relative to the config file, not the CWD), and the "file not found" error now includes a CWD hint to help users debug mis-placed configs.
- **Example cross-link (#211)**: the petstore client example's README now links to the shipped `server_adapter` example for readers who want to see both halves of the generated API.

### Changed

- **Stricter lint baseline (#203)**: glinter is now part of the default toolchain with the strictest practical configuration — every rule set to `error`, per-file suppressions only where a global refactor would be required, and `test/oaspec_test.gleam` excluded because the current glinter (2.14.0) analysis is quadratic in module size and would not complete on a ~12k-line test file.

### Fixed

- **README "Current Boundaries" drift (#210)**: response headers are now listed under the Supported narrative instead of under Current Boundaries, matching the reality of #192 which promoted that capability to Supported in v0.14.0.

### Test / tooling

- 677 → 684 unit tests (+7 from #215), 221 → 223 test fixtures (+2: `reserved_keywords.yaml`, `guard_constraints_api.yaml`).
- Integration suite grows from 13 to 16 steps covering reserved-keyword server + client compile, guard direct-call E2E, and the `validate: true` opt-in wiring check.

## [0.14.0] - 2026-04-19

### Added

- **Typed response headers (#192)**: declared response headers are now generated as typed record types in `response_types.gleam` (e.g., `ListPetsResponseOkHeaders(x_rate_limit: Option(Int))`). Header schemas map to Gleam types (String/Int/Float/Bool), and optional headers are wrapped in `Option(Type)`. Capability registry upgraded from ParsedNotUsed to Supported.
- **Whole-object external `$ref` support (#189)**: relative-file external refs now work for `components.parameters`, `components.requestBodies`, `components.responses`, and `components.pathItems` — not just schemas. A generic `resolve_ref_or_dict` helper handles all four component kinds through a shared finder pattern.
- **Source locations for semantic parse diagnostics (#188)**: missing-field and invalid-value parse errors now report line/column positions via a new `LocationIndex` backed by a yamerl FFI that preserves node locations. Diagnostic constructors accept a `SourceLoc` parameter instead of hardcoding `NoSourceLoc`.
- **Shared operation IR (#190)**: extracted `effective_explode`, `delimiter_for_style`, and `is_deep_object_param` into a shared `operation_ir` module consumed by both `client_request` and `server_request_decode`, eliminating duplicated transport-rule logic.
- **Request-body encoding warnings (#191)**: `capability_check` now surfaces warnings when `MediaType.encoding` metadata is present on request bodies, matching the existing response-side encoding warnings.
- **CI: example projects in CI (#186)**: both README-promoted examples (petstore client, server adapter) are now exercised in CI, with petstore client code regenerated to match v0.13.0 output.
- **CI: README library example compile check (#185)**: a new `scripts/check_readme_examples.sh` generates a temporary Gleam file mirroring the README's Library API examples and type-checks it against the public API.
- **README: validate documentation (#184)**: added `validate` config field to the configuration table, `--validate` flag to the generate flag table, and a new "Guard validation" subsection.
- 9 new unit tests and 3 new test fixtures (667 → 677 unit tests, 218 → 221 test fixtures)

### Fixed

- **Sync-check messaging (#187)**: `scripts/check_sync.sh` header, success, and failure messages now accurately reflect what the script validates (version + test counts only). Removed broken reference to nonexistent `scripts/update_sync.sh`. Added ShellSpec regression tests for both success and failure paths.
- **README library example (#185)**: replaced `config.Config(...)` direct construction with `config.new(...)` public constructor and added missing `validate` parameter.

### Changed

- `diagnostic.missing_field`, `diagnostic.invalid_value`, and `diagnostic.resolve_error` constructors now require a `loc: SourceLoc` parameter
- `response headers` capability upgraded from `ParsedNotUsed` to `Supported`
- Response header "parsed but not used" capability warning removed

## [0.13.0] - 2026-04-18

### Added

- **External `$ref` support across the full spec surface (#98)**: the parser now resolves relative-file external refs in every schema-bearing location — top-level `components.schemas` (#145), nested inside `ObjectSchema` properties (#149), `ArraySchema.items` (#151), `additionalProperties` (#153), `allOf`/`oneOf`/`anyOf` branches (#155), plus `components.parameters` schemas and `content` maps (#157, #161), `components.request_bodies` / `components.responses` content (#159), header schemas (#169), `components.path_items` (#171), and operation-level parameters / bodies / responses / callbacks under `paths.*` (#163, #165). A single shared imports tracker surfaces silent-shadowing and cross-file name collisions as `Diagnostic` errors (#147). One-hop alias chains inside the same external file resolve transparently (#167).
- **`style: pipeDelimited` / `style: spaceDelimited` query array parameters**: generated clients encode non-exploded arrays as `name=a|b|c` or `name=a%20b%20c`; generated servers split on the matching delimiter (#97)
- **Provenance metadata on hoisted schemas**: every hoisted component schema carries an `OriginKind` explaining whether it came from a property, array item, oneOf/anyOf/allOf position, parameter, request body, response, or additional-properties context. New `oaspec/openapi/provenance` module exposes `hoisted_schema_summary/1` so tooling and diagnostics can distinguish user-authored from synthetic schemas (#30)
- Generated clients now emit a `<operation>_with_request` wrapper for every operation. The wrapper accepts the matching `request_types.*Request` record and delegates to the existing flat function — either API is valid. Operations that take a multi-content request body skip the wrapper because the flat API needs an extra `content_type` argument the request type does not carry (#31)
- **Drift-detection test between the capability registry and the README `## Current Boundaries` block** (#143). Fixes stale `operation servers` / `path servers` entries the registry had carried since #96 promoted them to Supported.
- Capability registry now lists `application/xml` and `text/xml` under the `response` category as Supported (#173) and `content_type.is_supported_request` / `is_supported_response` consult the registry directly with mirrored drift tests (#175). Nine `server-validation` entries document the mode-specific restrictions `validate.gleam` enforces, so README, diagnostics, and rejection rules share a single source of truth (#181).
- **IR-based pipeline for request and response type files**: `generate_request_types` (#177) and `generate_response_types` (#179) both delegate to `ir_build.build_*_module |> ir_render.render` now, replacing ~260 lines of direct string-builder logic with reusable IR shapes.
- `examples/petstore_client`: first runnable example of an oaspec-generated client, driven by a stub `send` function; wired to `just example-petstore` (#26)
- `examples/server_adapter`: framework-free runnable example that bridges `router.route/5` to a canned request/response pair; wired to `just example-server-adapter` (#35)
- 10 new tests covering delimited styles, provenance tracking, summary grouping, and guard pluralization (615 → 667 unit tests across the release)
- 3 fixtures covering delimited styles and their rejection cases, plus 34 new external-ref fixtures (179 → 218 fixtures)

### Changed

- `oaspec/codegen/context.Context` is now declared `pub opaque type`. External callers must use `context.new/2` to construct and `context.spec/1` / `context.config/1` to read fields instead of pattern-matching on the record (#136). Same treatment applied to `oaspec/config.Config` via `config.new/6` / `config.load/1` + accessors (#138), and to `oaspec/codegen/ir.Module` / `oaspec/codegen/ir.Declaration` via `ir.module/3` / `ir.declaration/2` + accessors (#140). Closes parent issue #41.
- Validator now rejects `pipeDelimited` / `spaceDelimited` only when applied outside `in: query` or to non-array schemas; previous outright rejection is removed
- README: delimited array styles added to parameter support list and mode-specific support matrix, plus explicit listing of server-mode validation restrictions
- `SchemaMetadata` gains a `provenance: OriginKind` field, defaulted to `UserAuthored`

### Fixed

- Generated `minLength` / `maxLength` guard messages now pluralize correctly — `1 character` (singular) vs. `N characters` (plural) (#121)
- Generated client query strings now preserve the declared OpenAPI parameter order; previously the prepending loop reversed it (#123)
- Generated enum decoders now include the rejected string in their failure message (e.g. `"PetStatus: unknown variant adopted"`) instead of dropping it (#125)
- Generated clients distinguish unexpected HTTP statuses from decode failures via a new `UnexpectedStatus(status: Int, body: String)` variant on `ClientError`; previously an unknown status was reported as `DecodeError` and indistinguishable from JSON decode failures (#127)
- `encode_dynamic` fallback now emits `json.null()` for unsupported classifications instead of the classified type name (e.g. `"Dict"`), which silently corrupted outgoing payloads (#129)
- Generated clients no longer panic on malformed `base_url` or path: URL parse failures are reported via a new `ClientError.InvalidUrl(detail)` variant instead of crashing the caller (#131)

### Removed

- Callback handler stubs (`fn <op>_callback_<name>_<suffix>() -> String`) are no longer emitted. They carried no request type, no response type, and no execution path, so they were more misleading than useful. Callbacks are still parsed and resolved; treat them as parsed-but-not-codegen until typed support is added (#117)
- `middleware.gleam` is no longer part of the default generated surface. Its `Handler(req, res) = fn(req) -> Result(res, _)` shape did not compose with the generated client or server APIs, so it was a standalone demo module rather than a reusable artifact. The `oaspec/codegen/middleware` source module stays in the tree as a library-level helper for anyone assembling their own chain (#116)

## [0.12.0] - 2026-04-12

### Added

- **Guard integration in server/client flows**: generated routers validate decoded request bodies against schema constraints and return 422 on failure; generated clients validate request bodies before sending (#22)
- `validate` config option and `--validate` CLI flag to enable guard validation in generated code
- `ValidationError(errors: List(String))` variant in generated `ClientError` type (when validation enabled)
- `guards.schema_has_validator/2` public function for checking if a schema has constraint-based validators
- **Operation-level and path-level server overrides**: generated clients now respect OpenAPI server precedence (operation > path > top-level) (#96)
- Server variable substitution applied to operation/path-level server URLs
- **JSON/XML structured syntax suffix media types**: content types like `application/vnd.api+json` now treated as JSON-compatible (#108)
- **Auth configuration helpers**: generated `with_*` functions for setting security credentials on `ClientConfig` (#106)
- **Packaged escript smoke tests**: smoke test the built escript artifact, not just `gleam run` (#103)
- **String pattern validation guards**: generate regex-based pattern validation for string schemas with `pattern` constraint (#95)
- **Version and test count consistency check**: `scripts/check_sync.sh` detects drift between gleam.toml, context.gleam, CHANGELOG.md, and README test counts (#111)
- 6 new server override tests, 11 guard integration tests, and additional unit tests (598 → 615)

### Fixed

- **Server router 400 on invalid input**: return 400 instead of crashing on invalid path params and request body decode failures (#110)
- Guard generation correctly traverses constrained object properties and surfaces regex compile errors (#95)

### Changed

- Capability warnings for operation/path-level servers removed (now supported)
- `Config` type includes `validate: Bool` field (default: `false`)
- Operations collector inherits path-level servers to operations following OpenAPI server precedence
- README: updated support boundaries and test counts
- Split monolithic test file into focused modules (#109)
- Release CI pipeline now matches main CI checks (#107)

## [0.11.0] - 2026-04-11

### Added

- **deepObject additional_properties collection**: generated server routers now collect unmatched `{param}[{key}]` query keys into the `additional_properties` dict instead of always passing an empty dict (#92)
- `deep_object_additional_properties` helper function generated in router for collecting unknown keys from query parameters
- `deep_object_present_any` helper function for broader presence detection on optional deepObject parameters with Untyped additionalProperties
- `coerce_dict` Erlang FFI helper for safely converting `Dict(String, List(String))` to `Dict(String, Dynamic)` in generated routers
- Integration tests for callbacks, cookies, and deepObject parameters (#46)
- Unit tests for `generate_security_or_chain` in `client_security.gleam` (#83)
- Expanded unit test coverage for codegen modules: `client_request`, `server_request_decode`, `decoders`, `client_response`, `client_security`, `ir_build`, `allof_merge` (#45)
- Unit tests for `resolve.gleam` error paths: circular refs, unresolved refs, wrong-kind refs (#60)
- Unit tests for `writer.gleam` public functions: `resolve_paths`, `output_dirs`, `error_to_string` (#61)

### Fixed

- **deepObject additional_properties**: generated router no longer passes `dict.new()` for deepObject parameters with additionalProperties; unknown query keys are now collected (#92)
- Presence check for optional deepObject parameters with Typed additionalProperties uses `deep_object_present` (known keys only), keeping it consistent with the `dict.new()` fallback for Typed AP
- CLI diagnostic output uses `to_short_string` by default, removing verbose `[Phase]` prefix (#63)
- Removed dead code: unused `_method` parameter in `parser.gleam` and unused `indent_offset` in `client.gleam` (#65)
- Resolved regex recompilation and quadratic list operations in naming utilities (#54)
- Corrected `decode.one_of` call signature in anyOf decoder generation

### Changed

- Extracted duplicated schema helper functions into shared `schema_utils.gleam` module (#53)
- Consolidated duplicated parameter parsing generators in `server_request_decode.gleam` (#56)
- Extracted shared import-needs analysis into `import_analysis.gleam` (#57)
- Unified three separate allOf property merging implementations into `allof_merge.merge_allof_schemas` (#58)
- Split `generate_decoder` god function (560+ lines) into per-schema-type functions (#59)
- Reduced deep nesting in `cli.gleam` and extracted shared pipeline in `generate.gleam` (#55)
- README: added library API usage section (#27), mode-specific support matrix (#28), clarified OAuth2/OpenID Connect scope (#23), documented validate command and CLI flags (#52), added platform install guidance (#62)
- CONTRIBUTING.md: recommend `just all` instead of `just ci` (#64)

## [0.10.0] - 2026-04-11

### Added

- **`gleam format` post-processing**: generated code now passes `gleam format --check` out of the box (#24)
- **Erlang FFI for subprocess execution**: `oaspec_ffi.erl` with `find_executable/1` and `run_executable/2` using `open_port` + `spawn_executable` for safe, injection-free process invocation
- **`oaspec/formatter` module**: wraps `gleam format` invocation with error handling and `gleam` binary detection
- **`--check` mode formatting**: generated content is formatted via temp files before comparison with existing on-disk files
- **Golden file format verification**: `scripts/update_golden.sh` now verifies `gleam format --check` compliance after regeneration

### Changed

- Golden test helper formats generated content before comparison to match formatted golden files on disk
- All golden files updated to reflect `gleam format` output

## [0.9.0] - 2026-04-11

### Added

- **`validate` subcommand**: run spec validation without code generation (#42)
- **Actionable validation hints**: all validation and capability diagnostics include fix suggestions (#43)
- **`--check` flag**: verify generated code matches existing files without writing (`generate --check`) (#32)
- **`--fail-on-warnings` flag**: treat warnings as errors in CI
- **Type-safe `HttpStatusCode` enum**: replace raw String status codes with an ADT for compile-time safety (#40)
- **Deterministic output ordering**: all `dict.to_list` calls in codegen sorted for reproducible output (#47)
- **Golden file (snapshot) testing**: byte-for-byte comparison of generated output against committed golden files (#44)
- 40 edge-case test fixtures and 89 additional unit tests for parsing, validation, and codegen

### Fixed

- `default_base_url()` no longer generated when spec has no `servers` defined (#34)
- allOf `PartN` helper types excluded from generated public API (#21)
- Generated handler stubs use `panic` instead of `todo` for clearer unimplemented markers (#20)
- `additionalProperties` absent now defaults to Untyped per JSON Schema spec (was incorrectly Forbidden)
- `$ref` path prefix validated to prevent wrong-kind resolution
- Unsupported keywords checked in inline operation schemas, not just components
- Panic on unresolved `$ref` when spec has no components section

### Changed

- allOf merge logic unified into single `allof_merge.gleam` module
- README test counts and feature notes updated

## [0.8.0] - 2026-04-11

### Added

- **Stage-typed AST**: `OpenApiSpec(stage)` with phantom type parameter distinguishing `Unresolved` (parse output) from `Resolved` (codegen input)
- **RefOr(a)** ADT replacing `ComponentEntry`: `Ref(String)` preserves `$ref` strings losslessly in the AST, `Value(a)` holds concrete definitions
- **Lossless parsing**: `const`, `$defs`, `prefixItems`, `if/then/else`, `dependentSchemas`, `not`, and multi-type unions (`type: [T1, T2]`) are now parsed into the AST instead of being rejected at parse time
- **Real normalize pass**: `const` is converted to single-value enum, `type: [T1, T2]` to `oneOf`, `type: [T, null]` to `nullable` — no longer a no-op
- **Resolve phase**: dedicated `resolve.gleam` resolves component `$ref` aliases with chain following and cycle detection, separate from parsing
- **Capability registry**: `capability.gleam` defines 49 feature support levels (Supported, Normalizable, Unsupported, ParsedNotUsed, NotHandled) as single source of truth
- **Independent capability_check phase**: `capability_check.gleam` walks the resolved spec using the registry to detect unsupported schema keywords, security types, and parsed-but-unused features
- **Source location in errors**: `ParseError.YamlError` carries `SourceLoc(line, column)` from the YAML parser, formatted as `(line N, column M)` in error messages
- **SchemaMetadata extensions**: `const_value`, `raw_type`, and `unsupported_keywords` fields preserve OAS 3.1 data for downstream processing

### Changed

- **Pipeline order**: `parse → normalize → resolve → capability_check → hoist → dedup → validate → codegen` — each stage has a distinct responsibility
- **Parser no longer resolves `$ref`**: `resolve_parameter_ref`, `resolve_request_body_ref`, `resolve_response_ref`, `resolve_path_item_ref`, and `validate_ref_prefix` are deleted from the parser
- **Media parsers return Result**: `parse_content_map`, `parse_encoding_map`, `parse_headers_map`, `parse_links_map` now propagate errors instead of silently dropping them to `None`
- All codegen modules updated to handle `RefOr` wrappers via `Value`/`Ref` pattern matching

### Removed

- `ComponentEntry(a)`, `ConcreteEntry(a)`, `AliasEntry(ref: String)` — replaced by `RefOr(a)`
- Parse-time `$ref` resolution functions (5 functions, ~200 lines)
- `check_unsupported_schema_keywords` — replaced by lossless parsing + `capability_check`

## [0.7.0] - 2026-04-10

### Added

- 41 OSS-derived test fixtures from kin-openapi (MIT), openapi-spec-validator (Apache-2.0), swagger-parser-js (MIT), spectral (Apache-2.0), OpenAPI.NET (MIT), swagger-parser-java (Apache-2.0), and openapi-generator (Apache-2.0), covering links, callbacks, encoding, discriminator, webhooks, reusable pathItems, OAuth2 flows, server hierarchy, schema siblings, and more
- Validation for missing `responses` on operations (OpenAPI 3.x requires at least one response)
- Validation that security scheme references in `security` requirements point to schemes defined in `components.securitySchemes`
- Warnings for parsed-but-unused features: `externalDocs`, top-level `tags`, operation/path-level `servers`, component `headers`/`examples`/`links`
- Doc comments on public API entry points (`oaspec.gleam`, `string_extra.gleam`)
- Schema path context in parse error messages (e.g. `components.schemas.Pet.items` instead of `schema`)

### Fixed

- **Critical:** Unsupported JSON Schema 2020-12 keywords (`const`, `$defs`, `prefixItems`, `if`/`then`/`else`, `dependentSchemas`, `not`, `unevaluatedProperties`, `unevaluatedItems`, `contentEncoding`, `contentMediaType`, `contentSchema`) are now detected and rejected instead of silently generating broken decoders
- Non-schema `$ref` resolution now validates the reference prefix (e.g. `#/components/parameters/`) instead of resolving by last path segment only; external refs and wrong-kind refs are rejected
- Component-level `$ref` aliases in parameters, requestBodies, responses, and securitySchemes are now skipped gracefully instead of failing with "No components to resolve reference"
- CLI now uses `parser.parse_error_to_string` instead of a less helpful duplicate formatter
- Unknown parameter `style` values are now rejected with a clear error instead of silently defaulting to `form`
- README client output example now includes `guards.gleam`
- README test counts and unsupported keyword list aligned with implementation

## [0.6.3] - 2026-04-09

### Added

- 14 more OSS test fixtures from oapi-codegen (Apache 2.0), openapi-generator (Apache 2.0), and kiota (MIT):
  - oapi-codegen: colon-in-path, recursive oneOf, recursive additionalProperties, allOf with discriminator, recursive oneOf variants, enum special characters, nullable array items
  - openapi-generator: wildcard `*/*` content type, dot-delimited operationId, json-patch+json content type, comprehensive petstore server spec
  - kiota: discriminator with mapping, derived types via allOf, multi-security with OAuth2

## [0.6.2] - 2026-04-09

_No code changes. Re-tagged release._

## [0.6.1] - 2026-04-09

### Added

- OSS test fixtures from libopenapi (MIT) and oapi-codegen (Apache 2.0) covering real-world specs: burgershop, all-the-components, petstore v3, circular refs, nullable combinations, recursive allOf, allOf with additionalProperties, bearer auth, multi-content types, cookies, name conflicts, illegal enum names

### Fixed

- Parser now skips `x-` vendor extension keys in paths and responses maps instead of trying to parse them as paths/status codes
- Parser accepts `openapi` version field as YAML float (e.g. `openapi: 3.0` parsed as number instead of string)
- Operation `responses` field is now optional at parse time (webhook operations often omit it); validation can catch missing responses separately

## [0.6.0] - 2026-04-09

### Added

#### Server Codegen Improvements
- Bool parameter parsing is now case-insensitive (`"True"`, `"true"`, `"TRUE"` all accepted), matching `bool.to_string` output from client
- Header parameter names lowercased in server router to match client behavior (HTTP headers are case-insensitive per RFC 7230)
- Non-JSON request body content types (`multipart/form-data`, `application/x-www-form-urlencoded`) rejected for server mode with targeted validation error
- Float path parameter parsing via `float.parse` (previously TODO placeholder)
- Cookie parameter support with `cookie_lookup` helper, percent-decoding, and all scalar types (string, integer, float, boolean)
- Server query parameters use `Dict(String, List(String))` multimap for repeated keys
- Primitive array parameters in query and header positions
- `style: deepObject` query parameters with inline primitive and inline primitive-array leaves
- deepObject now supports `$ref` enum and primitive alias leaves by resolving references
- `application/x-www-form-urlencoded` server request bodies with bracket encoding
- Form-urlencoded multi-level object nesting up to 5 levels deep (`field[sub][key]=value`)
- Form-urlencoded support for referenced primitive field schemas
- `multipart/form-data` server request bodies with primitive scalar and primitive array fields
- Multipart support for referenced primitive scalar fields
- Multi-content-type server responses set first content type as default `content-type` header
- Validation targets respected during generation: client-only errors skip server mode and vice versa
- CLI displays validation warnings alongside blocking errors
- `--warnings-as-errors` enforced in server integration builds

#### Guard Generation
- `uniqueItems` validation guard using `list.unique` length comparison
- `minProperties` / `maxProperties` validation guards using `dict.size`
- Guards work at both top-level schema and field-level within object properties

### Fixed

- `response_types.gleam` conditionally imports `types` module only when response variants reference component schemas (avoids unused import warning)
- Complex path parameters rejected for server generation (previously silently accepted)
- Structured parameters (array, deepObject, referenced object/array) rejected for server when unsupported
- Unreachable `ObjectSchema` pattern matches removed from guards codegen

### Changed

- README support table updated to reflect all new capabilities
- `uniqueItems`, `minProperties`, `maxProperties` moved from "Not yet supported" to "Supported"
- `doc/reference/` tracking files removed from version control

## [0.5.0] - 2026-04-09

### Added

#### Lossless AST (Phase 1)
- **8 new types**: `Contact`, `License`, `ServerVariable`, `ExternalDoc`, `Tag`, `Header`, `Link`, `Encoding`
- **Lossless parsing**: all standard OpenAPI 3.x fields preserved through parsing (info contact/license/summary/termsOfService, server variables, webhooks, tags, externalDocs, jsonSchemaDialect, pathItem servers, operation servers/externalDocs, parameter content/examples, mediaType example/examples/encoding, response headers/links, components headers/examples/links)
- `ParameterStyle` ADT: `FormStyle`, `SimpleStyle`, `DeepObjectStyle`, `MatrixStyle`, `LabelStyle`, `SpaceDelimitedStyle`, `PipeDelimitedStyle` — replaces stringly-typed `Option(String)`
- `SecuritySchemeIn` ADT: `SchemeInHeader`, `SchemeInQuery`, `SchemeInCookie` — replaces stringly-typed `String`
- `SchemaMetadata` expanded with `title`, `readOnly`, `writeOnly`, `default`, `example`
- Schema constraint fields: `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf` (Integer/Number), `uniqueItems` (Array), `minProperties`, `maxProperties` (Object)
- OAuth2 `flows` with `authorization_url`, `token_url`, `refresh_url`, and `scopes` preserved in AST
- OpenAPI 3.1 `type: [string, 'null']` parsed as nullable type
- OpenAPI 3.1 `type: [string, integer]` multi-type unions rejected with clear error (use `oneOf` instead)
- HEAD, OPTIONS, TRACE operations parsed and supported in AST and codegen

#### Structured Validation (Phase 2)
- `ValidationError` with `Severity` (Error/Warning) and `Target` (Both/Client/Server) — replaces flat `UnsupportedFeature`
- Warnings for parsed-but-unused AST fields (webhooks, response headers/links, mediaType encoding) — do not block generation
- `errors_only()` and `warnings_only()` helper functions

#### IR-Based Codegen (Phase 3)
- `ir_build.gleam`: converts component schemas to IR declarations
- Component schema types generated via `ir_build → ir_render` pipeline
- `schema_dispatch.gleam`: centralized schema-to-type mapping

#### OpenAPI Feature Implementation (Phase 5)
- `readOnly` properties filtered from request types and encoders
- `writeOnly` properties treated as optional in response decoders
- Validation guards for `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf` (Integer and Number)
- Server router: typed request construction, handler dispatch, response encoding with status codes
- `ServerResponse` type with status, body, and headers
- `default_base_url()` generated from server URL templates with variable substitution
- `requestBody.required: false` generates `Option(T)` body parameter with case unwrapping
- `explode: true` query arrays produce repeated `key=a&key=b` (OpenAPI default for `style: form`)
- Array alias component schemas (e.g. `TagList: type: array`) generate decoder and encoder

### Fixed

- Optional deepObject + array leaf: no longer passes `List` to `uri.percent_encode`
- form-urlencoded `$ref` array property: resolved to detect arrays, generates proper iteration
- `$ref` array query parameter: `gleam/list` import now included when needed
- form-urlencoded nested objects: recursive bracket encoding (`field[sub][key]=value`) for 2+ level nesting
- Server router tuple syntax: uses `#()` not `()` for Gleam tuples
- Server router: uses `_json` encoder variants for `json.to_string` compatibility
- Server router: uses operation-specific decoders instead of nonexistent `decode_body`
- Server router: always imports `gleam/dict` for route signature, `gleam/option` for optional bodies
- Callback parse errors propagated instead of silently swallowed
- `FileTarget` ADT in writer: routes files by target kind, not filename string matching
- Config `FileReadError` distinguishes ENOENT from other errors

### Changed

- `Parameter.style` type: `Option(String)` → `Option(ParameterStyle)` (ADT)
- `ApiKeyScheme.in_` type: `String` → `SecuritySchemeIn` (ADT)
- `OAuth2Scheme` now carries `flows: Dict(String, OAuth2Flow)`
- `GeneratedFile` has `target: FileTarget` field (SharedTarget/ServerTarget/ClientTarget)
- `ValidationError` restructured with severity and target scope
- CLI `run_generate` refactored to pure `generate(spec, cfg) -> Result` pipeline
- Types generation delegated to IR build → render pipeline

## [0.4.0] - 2026-04-08

### Added

- `ContentType` type abstraction for extensible content type handling
- Schema hoisting pre-processing pass: inline complex schemas auto-extracted to `components.schemas` with `$ref` references
- Percent-encoding for all path/query/cookie parameter values via `uri.percent_encode`
- `text/plain` response content type: body returned as `String` directly without JSON decoding
- Typed `additionalProperties`: generates `Dict(String, T)` fields with dict decoder/encoder (known keys excluded from dict)
- Untyped `additionalProperties: true`: generates `Dict(String, Dynamic)` (decode-only, known keys excluded)
- `multipart/form-data` request bodies with boundary-based multipart encoding
- `apiKey` in cookie position: generates cookie headers (appends, does not overwrite)
- HTTP Basic and Digest authentication support
- Validation constraint guard functions (minLength, maxLength, minimum, maximum, minItems, maxItems)
- Validation for unsupported HTTP security schemes (e.g. hoba, negotiate) and OAuth2

### Fixed

- Guard generation: missing `gleam/list` import, incomplete min+max checks, float validation stub
- Typed `additionalProperties` decoder no longer forces value decoder on known fields with incompatible types
- Typed `additionalProperties` decoder now fails on invalid extra values instead of silently dropping them
- `multipart/form-data` client handles optional fields and scalar `$ref` fields instead of raw concatenation
- `multipart/form-data` validation rejects unstringifiable object-like fields before code generation
- `allOf` merge now preserves `additionalProperties` from sub-schemas
- Cookie `apiKey` auth appends to existing cookie header instead of overwriting
- `text/plain` response types always use `String` regardless of schema type
- Referenced unsupported parameter schemas are rejected during validation
- Hoisted schema names avoid collisions after case normalization
- `text/plain` request bodies are rejected during validation
- `just all` no longer emits `BASH_ENV` shell warnings or integration `todo` warnings

### Changed

- Extract duplicated `status_code_suffix` and `status_code_to_int_pattern` into shared `oaspec/util/http` module
- Replace hand-rolled `list_last` and `list_length` helpers with `gleam/list` stdlib equivalents
- Simplify CLI flag parsing with `result.unwrap` instead of verbose case expressions

## [0.3.0] - 2026-04-08

### Changed

- Code generation output order is now deterministic: component schemas, paths, properties, and responses are sorted by key before rendering
- writer.generate_all takes an on_write callback instead of calling io.println directly, separating file generation from IO
- Removed stale "Code generated by oaspec v0.1.0" header from naming.gleam

## [0.2.0] - 2026-04-08

### Added

#### Parser
- Top-level `security` field parsed and inherited by operations
- Operation-level `security: []` explicitly opts out of inherited security
- Security schemes: `apiKey` (header/query), HTTP `bearer` token
- Security requirement OR/AND semantics preserved in AST (`SecurityRequirement` contains AND-ed `SecuritySchemeRef` list; outer list is OR)
- Primitive component schema (string, integer, number, boolean) decoder/encoder generation
- Gleam keyword escaping for generated field names (e.g. `type` → `type_`)

#### Validation
- Recursive validation across all schema positions (requestBody, response, nested properties, array items, allOf/oneOf/anyOf sub-schemas)
- Reject `style: deepObject`, `multipart/form-data`, `additionalProperties: true`, typed `additionalProperties`
- Reject all inline oneOf/anyOf variants (not just primitives; all must be `$ref`)
- Reject nested inline object/allOf in property positions
- Reject array parameters and complex schema parameters (object/allOf/oneOf/anyOf)
- Reject inline complex array items
- Reject non-JSON content types in both requestBody and response
- Reject `apiKey` in cookie, HTTP Basic/Digest, OAuth2/OpenID Connect at parse time
- Reject path parameters with `required: false`
- Duplicate operationId detection
- Function name collision after snake_case, type name collision after PascalCase
- Property name collision after snake_case, enum variant collision after PascalCase
- Config validation: output directory basename must match package name

#### Client
- Typed request body parameters (auto-encoded via generated encoders)
- Typed response variants (auto-decoded via generated decoders with status code matching)
- Parameter serialization for Bool, Float, Int, String, `$ref` enum types
- `$ref` parameters resolved to determine correct string conversion (not blind `encode_X_to_string`)
- Cookie parameters combined into single header (`"a=1; b=2"`)
- Security schemes applied to client functions (first OR alternative, all AND-ed schemes)
- `default` response handling without duplicate catch-all branches
- Inline primitive requestBody/response uses raw types directly
- Inline array response with non-`$ref` items decoded correctly
- Conditional imports: `gleam/bool`, `gleam/float`, `gleam/string`, `gleam/option`, `gleam/json`, `gleam/dynamic/decode`, `api/types`, `api/encode` only imported when needed (generated code passes `--warnings-as-errors`)

#### Decoders/Encoders
- allOf decoder/encoder by merging sub-schema properties
- oneOf/anyOf decoder with discriminator support (dispatches by field value)
- oneOf/anyOf encoder wrapping each variant
- anyOf try-each decoder (no discriminator)
- Discriminator mapping lookup corrected (key = payload value, not schema name)
- Discriminator unknown branch uses `decode.then` instead of `todo`
- Inline enum decoders/encoders generated for properties in object and allOf schemas
- Nullable fields always wrapped in `decode.optional()`
- Optional array property encoder uses lambda for `json.nullable`
- List decoder (`decode_X_list`) for typed client array responses
- Primitive schema decoder/encoder wrappers for `$ref` to primitives
- Inline enum `encode_X_to_string` for URL/header serialization

#### Testing
- 45 unit tests (parser fail-fast, validator recursion, naming, config validation, collision detection, security parsing)
- 55 ShellSpec CLI tests
- Integration tests: petstore server (40 tests), petstore client compile, complex spec compile, security client compile, primitive API client compile
- Client compile tests use `--warnings-as-errors`
- Test fixtures: secure_api.yaml, primitive_api.yaml, global_security_api.yaml, deep_unsupported.yaml, collision.yaml, missing_responses.yaml, invalid_param_location.yaml

### Changed

- Parser propagates errors instead of silent fallback via `option.from_result` / `result.unwrap`
- `responses` field required per OpenAPI 3.x (missing → parse error)
- `items` field required for array schemas
- Path-level parameter merge key changed from name-only to `(name, in)`
- Client output default path changed from `<dir>/<package>_client` to `<dir>_client/<package>` (basename must match package)
- Security requirement AST changed from flat list to two-level OR/AND structure

### Fixed

- Query apiKey security no longer rebuilds the request (preserves body/headers/cookies)
- Discriminator mapping lookup direction (was reversed: looked up by schema name instead of payload value)
- `default` response no longer generates duplicate `_` catch-all branch
- Nullable `$ref` now resolved to check target schema's nullable flag (prevents `Option(Option(T))`)

## [0.1.2] - 2026-04-08

### Changed

- Rename package from `gleam_oas` to `oaspec` to avoid Hex `gleam_` prefix restriction
- Rename CLI binary from `gleam_oas` to `oaspec`
- Rename config file from `oaspec.yaml` to `oaspec.yaml`

## [0.1.1] - 2026-04-08

### Fixed

- Add Hex publish job to release workflow (was removed during refactor)

### Changed

- Bump version to 0.1.1

## [0.1.0] - 2026-04-07

### Added

#### CLI
- `oaspec generate` command with `--config`, `--mode`, `--output` flags
- `oaspec init` command to scaffold `oaspec.yaml` config template
- Config file support with `input`, `package`, `mode`, and `output.dir`/`output.server`/`output.client`
- escript binary distribution via gleescript
- GitHub Actions release workflow: tag push builds escript and attaches to GitHub Release

#### Parser
- OpenAPI 3.x YAML and JSON parsing via yay
- Component schemas: string, integer, number, boolean, array, object
- Composition: allOf (property merging), oneOf, anyOf with discriminator
- Enums, nullable fields, arrays (including array of `$ref`)
- Full `components` support: `schemas`, `parameters`, `requestBodies`, `responses`
- `$ref` resolution for parameters, requestBodies, and responses via components lookup
- Components parsed before paths to enable immediate `$ref` resolution
- Fail-fast parser: missing required fields and unknown parameter locations return Error
- `style` field parsed for parameters (used for deepObject detection)
- `additionalProperties: true` detection (boolean vs schema)

#### Code Generation — Types
- Custom types for every component schema (no generic maps)
- Request types with typed `$ref` body fields
- Response types with operation-prefixed status code variants
- Inline enums in properties auto-generate named enum types (e.g. `UserType`, `FilterOp`)
- Inline objects in response/requestBody auto-generate anonymous types
- oneOf/anyOf with `$ref` variants generate sum types
- allOf in requestBody merges properties from `$ref` + inline objects
- optional+nullable fields avoid `Option(Option(T))` double-wrapping
- Path-level parameters merged into operations (operation takes precedence by name)

#### Code Generation — Decoders/Encoders
- JSON decoders using `gleam/dynamic/decode` pipeline API (`field`, `optional_field`, `success`)
- Reusable `_decoder()` functions for `$ref` schema composition
- `decode.failure` for unknown enum values (not silent fallback to first variant)
- array of `$ref` uses recursive `decode.list(x_decoder())`, not `decode.list(decode.string)`
- JSON encoders with separate `_json` (returns `json.Json`) and string variants
- `$ref` fields use `encode_x_json()` directly (no double-encoding via `json.string` wrapper)
- Encode/decode roundtrip safety: `decode(encode(value)) == Ok(value)`

#### Code Generation — Server
- Handler stub generation with TODO placeholders
- Router with strict path matching (no trailing wildcard)
- OpenAPI description propagation as Gleam doc comments
- Auto-generation header in every generated file

#### Code Generation — Client
- HTTP client functions with configurable `send` transport
- Path parameter substitution with `int.to_string` (not `string.inspect`)
- Query parameter URL serialization (handles optional with `Some`/`None`)
- Header and cookie parameter serialization via `request.set_header`
- `content-type: application/json` set only when body is present

#### Code Generation — Middleware
- Composable `Handler(req, res)` and `Middleware(req, res)` types
- Built-in: `identity`, `compose`, `apply`, `logging`, `retry`

#### Validation
- Pre-generation validation pass detects unsupported patterns and exits non-zero:
  - `style: deepObject` query parameters
  - `multipart/form-data` request bodies
  - `additionalProperties: true` (untyped map)
  - Inline oneOf/anyOf with primitive types
- Circular `$ref` detection with seen-set in resolver

#### Testing
- Unit tests: parser, naming, config, resolver, validation (24 tests)
- ShellSpec CLI tests: behavior, file generation, content verification, unsupported error detection, complex pattern generation (55 tests)
- Integration tests: generated code compilation, type construction, JSON roundtrip, handler invocation, middleware chain, unknown enum rejection (40 tests)
- Client compile test: `--mode=client` standalone `gleam build` verification
- Test fixtures: petstore, complex supported, broken (unsupported patterns)

#### CI/CD
- GitHub Actions: CI (format, lint, build, test), integration (ShellSpec + compile roundtrip), release (escript on tag)
- `just all` command for full verification
