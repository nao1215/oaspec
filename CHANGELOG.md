# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).
Going forward, breaking changes are listed under a dedicated `Breaking`
section per release (issue #434). Older entries inline `BREAKING:` prefixes
within `Changed` / `Fixed` and stay as-is.

## [Unreleased]

## [0.61.0] - 2026-05-08

### Changed
- **Default output directory is now `./src` instead of `./gen`.** A
  freshly-generated project (`oaspec init` + `oaspec generate` with no
  `output:` block) now writes to `./src/<package>` and
  `./src/<package>_client`, the standard Gleam project layout that
  `gleam build` picks up without further config. Previously the default
  was `./gen/<package>`, outside `./src`, which produced the worst-of-
  both first-contact friction: the generator reported success but the
  freshly-built project couldn't see the modules. Callers who set
  `output.dir` / `output.server` / `output.client` explicitly are
  unaffected. The `init` template's commented-out `output:` block is
  refreshed with the new defaults; `doc/configuration.md` and
  `doc/library-api.md` updated. (#568)

## [0.60.0] - 2026-05-07

### Breaking

- **`oaspec/transport.Method` gains an `Other(String)` variant.**
  External callers that exhaustively pattern-match on `Method`
  (without a catch-all `_ ->`) will fail to compile until they add
  an arm for `Other(_)`. The new variant is required to express
  WebDAV (`PROPFIND`, `PROPPATCH`, `MKCOL`, …), CalDAV / CardDAV
  (`REPORT`, `MKCALENDAR`), and vendor extensions (`PURGE`, `BAN`,
  `LINK`, `UNLINK`) — the previous closed sum could not represent
  any of these. The bundled `httpc` and `fetch` adapters route
  `Other(s) → http.Other(s)` so the wire path is unchanged for
  callers that use them. New helpers `transport.method_to_wire/1`
  and `transport.method_from_string/1` (case-insensitive routing
  for the nine RFC 9110 §9 verbs, `tchar`-validated `Other`
  passthrough for everything else) keep the construction surface
  consistent. (#554)

### Added

- `oaspec/openapi/parser.parse_string_with_limits(content, limits)`
  is a DoS-aware variant of `parse_string`. The new `ParseLimits`
  config caps parser-side resources that an attacker-controlled or
  accidentally-pathological spec could exhaust on a CI runner or in
  a service that accepts user-supplied specs (admin uploads,
  contract-validation pipelines). `parse_string` is unchanged and
  remains the right entry point for trusted local files; reach for
  `parse_string_with_limits` (and `default_limits()` as a starting
  point) when the input is untrusted. The first enforced cap is
  `max_input_bytes` (default 16 MiB — Stripe's full OpenAPI is
  ~6 MB and GitHub's REST API is ~12 MB, both well under the cap),
  rejected with a structured `parse_limit_exceeded` Diagnostic
  before yamerl or `json:decode/3` allocate any tree memory. The
  `ParseLimits` type also declares `max_schema_depth`,
  `max_allof_chain`, `max_external_ref_hops`, `max_paths`, and
  `max_parameters_per_op` fields that future PRs will start
  enforcing — listing them in the type now lets callers pin the
  contract surface up front. (#553)
- `oaspec/openapi/parser.parse_json_string_with_locations` is now
  public, mirroring `parse_string_with_locations` (the YAML variant).
  OTP's `json:decode/3` does not expose token positions, so the
  returned `LocationIndex` is always `location_index.empty()` — the
  type signature still matches the YAML path so downstream tooling
  (LSP-style features, error-hint generators, source-map producers)
  can dispatch over both formats with one signature, only losing
  location-aware diagnostics on the JSON branch. New
  `parse_string_or_json_with_locations` auto-routes by inspecting
  the first non-whitespace byte (`{` or `[` → JSON, else YAML), so
  callers do not have to write the dispatch wrapper themselves. (#550)

### Fixed

- `oaspec generate` no longer panics on a response header whose
  schema is a `$ref` or any composite shape (object, array, allOf,
  oneOf, anyOf). The codegen path used to crash with a stack trace
  on any such spec — perfectly valid OpenAPI 3.x — taking the whole
  CLI process down. `validate.validate_response_headers` now catches
  these shapes during the existing validate phase and surfaces a
  structured `Diagnostic` ("Response header 'X-Foo' has an
  unsupported schema for the client extractor: …") with the
  offending header name and a hint pointing at the supported
  inline-primitive shapes (issue #387 tracks the typed-extraction
  work for composite shapes). The codegen-time panics in
  `client_response.classify_header_schema` are now defensive
  unreachable markers; reaching them indicates the validator was
  bypassed or regressed. (#552)
- `oaspec/codegen/writer.write_all` no longer writes shared files
  twice when `mode = Both` and `output_server` resolves to the same
  directory as `output_client`. The previous behaviour wrote every
  shared file to the server path then again to the client path; with
  identical paths, the second write silently overwrote the first,
  fired `on_write` twice, and returned the path twice in the result
  list. Each unique destination path now triggers one
  `simplifile.write` call, one `on_write` callback, and one entry in
  the returned list. The overlap check normalises trailing slashes
  (`"out"` and `"out/"` are treated as the same directory). Distinct
  server / client paths preserve the existing dual-output behaviour
  — the regression boundary is pinned by a new test. The matching
  fix lands in `resolve_paths` and `expected_paths` so `--check`
  does not double-count drift on shared files when paths overlap.
  (#548)
- **Security:** `oaspec/transport.with_default_header` and
  `with_default_headers` now reject CR (`\r`), LF (`\n`), and NUL
  (`\u{0000}`) bytes in any header name or value at construction
  time. Those bytes are the gateway to HTTP response-splitting and
  header-injection attacks (RFC 9112 §2.2): a credential-derived or
  environment-derived value flowing into a default header without
  pre-sanitisation could previously smuggle a forged header on the
  wire. The validator panics with a structured message naming the
  offending byte ("CR (\r)" / "LF (\n)" / "NUL (\u{0000})") and the
  recommendation to pre-encode binary values via Base64 or RFC 8187.
  The check fires at the outer call (when the wrapper is built), so
  static misconfiguration surfaces immediately at startup rather
  than per-request. Tab (`\t`) inside values remains allowed (it is
  RFC-permitted). The `oaspec_ffi.{erl,mjs}` modules gain a
  `capture_panic` helper used by the new tests; the helper is also
  available to future tests that need to assert on panic messages.
  Same audit lens as multipartkit#28 (CRLF in part headers); the
  generated client middleware path was the missing companion. (#546)

### Documentation

- `oaspec/openapi/parser.parse_string` docstring now documents the
  YAML 1.1 type-coercion rules that yamerl applies to scalars but
  OTP's JSON decoder does not. The two parsers diverge on the same
  JSON bytes whenever a scalar matches a YAML 1.1 implicit-type
  pattern: `"Yes"` / `"No"` / `"On"` / `"Off"` get coerced to
  booleans, `1.10` loses its trailing zero, hex-prefixed integers
  and sexagesimal numerals are recognised by yamerl but rejected by
  the JSON decoder. For JSON OpenAPI documents (Stripe, GitHub,
  AsyncAPI), prefer `parse_json_string` or
  `parse_string_or_json_with_locations` (auto-routes by first
  non-whitespace byte). New regression tests pin
  `parse_json_string`'s verbatim handling of `"Yes"` and `"1.10"`
  so a future regression that breaks the JSON path surfaces here.
  (#549)
- `oaspec/transport.with_default_headers` and
  `with_default_header` docstrings now spell out the dedup contracts
  explicitly. The list form is **first-occurrence-wins** (e.g.
  `[#("X-Env", "staging"), #("X-Env", "prod")]` keeps `staging` and
  silently drops `prod`); the wrapper form is
  **outermost-wrapper-wins** when piping the same name through
  multiple `with_default_header` calls. Pick one shape per code path
  to avoid surprises. New tests pin the list-form rule for duplicate
  names (case-insensitive dedup, order preserved between distinct
  names). The wrapper-form composition rule is documented but tested
  separately in #555. (#547)
- The transport module gains a "Header middleware composition" comment
  block above the `with_default_header*` family that summarises both
  rules side-by-side, and the wrapper-form composition rule
  (`with_default_header` outermost wins) is now pinned by three new
  tests: same name → outermost wrapper wins, same rule under
  case-insensitive name comparison, and an explicit request header
  beats every stacked wrapper layer. The two rules are inverse to
  each other; the docs and tests now make that explicit so users do
  not mistake one for the other when mixing the two shapes. (#555)

### Tests

- `test/normalize_argv_property_test.gleam` adds metamon
  property-based tests pinning `oaspec.normalize_argv`'s algebraic
  invariants: idempotency (a second pass is a no-op), length
  non-increasing (pair-collapse can only shrink the list), bit-for-bit
  pass-through when the argv contains no value-bearing long flags,
  equivalence between `--name value` and `--name=value` for the
  flags listed in `cli.value_flag_names`, the absence of any bare
  `--name <value>` pair in the output, and commutation with
  appending an unrelated bool flag. The generators draw from
  `cli.value_flag_names` directly rather than duplicating the list,
  so adding a new value flag automatically extends the property's
  input space. metamon is added to `[dev-dependencies]`. (#551)

## [0.59.0] - 2026-05-07

This release lifts oaspec's `application/x-www-form-urlencoded`,
deepObject, and array-query coverage from "small fixtures" to
"real-world specs": the unmodified upstream Stripe OpenAPI document
(~1k operations, heavy on form bodies, deepObject queries, composite
fields, and inline enums nested several levels deep) now generates
and compiles end-to-end, validated by a new CI integration job that
runs alongside the existing `Full GitHub OpenAPI` job.

### Added

- **`encoding.<field>.contentType: application/json` escape hatch
  for `application/x-www-form-urlencoded` bodies (#541).** A property
  flagged with this annotation is JSON-encoded into a single string
  and that string is percent-encoded as one form value. Stripe and
  similar specs use this for `metadata`-shaped open hashes; the
  generator now honors the spec instead of forcing the
  bracket-index encoding.
- **Composite (`oneOf` / `anyOf` / `allOf`) field support for
  form-urlencoded bodies (#542).** Composite fields and any field
  that *transitively* contains a composite (object → array → items
  : composite) automatically take the same JSON escape hatch — no
  spec changes needed.
- **Nested arrays inside form-body objects (#540).** Primitive
  nested arrays serialise as repeated keys
  (`profile[scores]=10&profile[scores]=20`) for round-trip
  compatibility with the existing server decoder; nested arrays of
  objects use Stripe / qs `indices` style
  (`features[0][name]=foo`). The artificial 5-level depth cap is
  removed.
- **Query-array parameters with non-primitive items + deepObject
  parameters with composite or array-of-object sub-properties
  (#543).** Both routes now use the JSON escape hatch on the client
  side. Server mode still rejects with a server-only diagnostic.
- **`Full Stripe OpenAPI` GitHub Actions job (#544).** A new
  `integration_test/stripe_full.sh` script downloads the upstream
  `stripe/openapi` spec (cached weekly under `/tmp`, soft-skips
  with `OASPEC_SKIP_STRIPE_TEST=1` for offline contributors), runs
  `oaspec generate` with `validate: true`, checks file headers and
  formatting, and builds the generated package. The job runs in
  parallel with `Full GitHub OpenAPI`.

### Fixed

- **`schema_dispatch` no longer panics on inline composites that
  slip past the hoist contract (#543).** `decoder_expr`,
  `json_encoder_expr`, `json_encoder_fn`, and `to_string_fn` now
  fall back to permissive shapes (`dyn_decode.dynamic`,
  `json.null()`, `fn(_) { json.null() }`, `fn(_) { "" }`) so a
  hoist gap surfaces as a runtime null/empty payload instead of a
  build-time crash.
- **Optional form-urlencoded request bodies (#544).** An optional
  body is now unwrapped via `case body { Some(b) -> ... None ->
  transport.EmptyBody }` before any `body.<field>` access. The
  `None` branch produces `transport.EmptyBody`, so the downstream
  content-type-suppression rule actually drops the form
  `content-type` for absent bodies.
- **Inline-enum encoder resolution under deeply nested form / multipart
  / deepObject paths (#544).** Recursive emitters (nested objects,
  bracket fields, array-of-object items, indexed arrays, deepObject
  sub-properties, multipart simple fields) all carry a `parent_path`
  so an inline enum at any depth resolves to the matching
  `encode.encode_<...>_to_string` helper. `generate_inline_enum_encoders`
  recurses into nested object / allOf properties so the helpers it
  mints align with the same path.
- **Constant-property fields land on the wire as a literal value
  (#544).** Required single-value string-enums dropped from the
  generated record (Issue #309) now emit
  `<key>=<constant>` parts on every form path — top-level,
  nested-object, indexed-array, and bracket-fields — instead of
  triggering an `Unknown record field` for the hoisted-out field.
- **`gleam/float` / `gleam/int` / `gleam/bool` imports for
  form-urlencoded bodies (#544).** The import-needs analyser now
  walks form-body property trees recursively and pulls each
  `<gleam>.to_string` module in whenever the matching primitive
  surfaces at any nesting depth.
- **Inline enum constructor collisions with same-named record types
  (#544).** Stripe's `source.type` enum's variants
  (`SourceTypeThreeDSecure`, …) collide with the constructor names
  of records like `SourceTypeThreeDSecure` (generated from
  `source_type_three_d_secure`). Variant names now run through a
  global dedup against the component-type-name set, suffixing with
  `Variant` (and a numeric tail if needed).
- **`dedup_enum_variants` numeric suffix is now Gleam-valid for
  PascalCase outputs (#544).** Stripe's `Etc/GMT-0`, `Etc/GMT+0`,
  `Etc/GMT-1` collisions used to render as `EtcGMT0_2` / `EtcGMT0_3`,
  rejected by the parser. PascalCase dedup now uses a bare numeric
  suffix (`EtcGMT02`); snake_case dedup keeps `_<n>`.
- **String length / pattern guards skip enum-valued schemas (#544).**
  The generated record carries the enum type, not `String`, so a
  `validate_<field>_length(value.field)` call would not type-check.
  Guards for the enum field are now skipped end-to-end (constraint
  collection, top-level functions, composite validators).
- **Query array parameter types render with the `types.` prefix
  (#544).** `resolve_param_type` now resolves array items through
  `schema_ref_qualified_type_recursive` so nested `$ref` items
  show up as `Option(List(types.<Item>))` in the generated client.

### Documentation

- `doc/openapi-support.md` updates the deepObject / array-query /
  form-urlencoded rows to reflect the JSON-escape-hatch coverage on
  the client side.

## [0.58.1] - 2026-05-06

### Fixed

- **Issue #537: `oaspec generate` no longer hangs on the full GitHub
  OpenAPI document, and the generated client compiles cleanly under
  `gleam build --warnings-as-errors`.** The `types` phase of
  `ir_build.build_types_module` rebuilt the full component-schema
  list and re-mapped every entry through `naming.schema_to_type_name`
  on each inline-enum collision check. With ~10k component schemas
  this collapsed to multi-minute wall time. The mapped set is now
  precomputed once on the `Context` and queried via `dict.has_key`,
  bringing the types phase from minutes back to milliseconds.
  Companion fixes that surface only once the hang is gone:
  `bytes_body` and `encode_<empty>_json(value)` no longer leave
  unused-warning code in the generated module; array items of inline
  string-enums dispatch through the plain primitive codec; sibling
  `<base>-list` component schemas no longer trip
  `Duplicate definition: decode_<base>_list`; `client_response.gleam`
  routes `decode.list` calls through `dyn_decode.list`; complex /
  nullable query parameters serialise correctly; `path` / `query` /
  `headers` are reserved parameter names; `nullable + enum:[single]`
  is no longer treated as a constant property; the guards module
  qualifies inner refs, unwraps double-Option fields, gates the
  `properties` constraint to dict-backed schemas, and only imports
  `{type Option}` when a composite signature actually needs it.

### Added

- **Per-substage progress events during code generation.**
  `oaspec generate` now emits a `<phase> ...` line before each
  codegen substage (types / decoders / encoders / guards / server /
  client) and a `(took ...)` line after, so a slow phase surfaces
  against a specific stage rather than disappearing behind the
  opaque outer render wrapper. New helper `progress.timed_stage`
  factors the bracketing for downstream callers.

- **Full GitHub OpenAPI integration test job.** A new
  `integration_test/github_full.sh` script downloads the upstream
  `github/rest-api-description` document (cached weekly under
  `/tmp`), runs `oaspec generate` with `validate: true`, then checks
  that every generated file is non-empty, carries the codegen
  provenance header, round-trips through `gleam format --check`, and
  builds with `--warnings-as-errors`. A new `github-openapi`
  GitHub Actions job runs it in parallel with the existing test job
  so total CI wall-clock caps at `max(integration, github_full)`
  instead of the sum.

## [0.58.0] - 2026-05-05

### Fixed

- **Issue #519: deepObject query with primitive sub-properties no longer
  emits unimported `int.to_string` / `float.to_string` /
  `bool.to_string` calls.** The client-side import-needs analyser in
  `client_ir.gleam` now traverses every deepObject parameter's
  ObjectSchema property tree (including nested objects) and pulls
  `gleam/int` / `gleam/float` / `gleam/bool` into
  `<package>_client/client.gleam` whenever a leaf is integer, number,
  or boolean. Pre-fix, freshly-generated clients for
  `?page[size]=10&page[after]=...`-style cursors failed `gleam build`
  with `Unknown module: int`.

- **Issue #520: `validate_<schema>` now recurses into nested-record
  properties.** Previously the aggregator only walked fields with
  constraints directly on the leaf type; a `$ref` to another record
  (or an `array<$ref>`) was silently skipped, so an out-of-range value
  on `Poll.options[i].weight` slipped past `validate_poll`. New
  `Composite` and `CompositeList` guard-call kinds emit
  `validate_<inner>(value.field)` and `list.fold(value.list, ...,
  validate_<inner>)` shapes, with cycle detection so self- and
  mutually-recursive schemas terminate.

- **Issue #521: `multipleOf` validator codegen now compiles.** Two
  defects in `<package>/guards.gleam` (and the parallel client file):
  (1) the import-needs analyser's `NumberSchema` arm-order put the
  range arm before the `multiple_of` arm, so a schema with both
  `minimum` and `multipleOf` set lost the `gleam/float` / `gleam/int`
  imports; (2) the body expression chained `value /. m |>
  int.to_float` (passing a Float into an Int-expecting function) and
  multiplied an Int by `0.01` with `*.`. Both are corrected; the body
  is now `value -. int.to_float(float.truncate(value /. m)) *. m`.

- **Issue #522: server router decodes `$ref`'d integer / number /
  boolean optional query parameters with their scalar parser.**
  Previously, when a query parameter's schema was a `$ref` to a
  non-string-enum component (e.g. `EntryType: { type: integer, enum:
  [1, 2] }`), the codegen fell through to `Some(v)` (raw String) into
  a slot the request record had typed as `Option(Int|Float|Bool)`,
  breaking `gleam build`. The optional-query path now resolves the
  ref and emits `int.parse(v)` / `float.parse(v)` / `bool_parse_expr`
  to match the inline-scalar arms, and `query_schema_needs_int` /
  `query_schema_needs_float` resolve refs so the matching imports
  reach `router.gleam`.

- **Issue #523: OAS 3.0 boolean form of `exclusiveMinimum` /
  `exclusiveMaximum` is honoured.** The schema parser previously read
  these keys only as numeric (OAS 3.1) values; the boolean companion
  used by OAS 3.0 (`{minimum: N, exclusiveMinimum: true}` for strict
  `> N`) was silently discarded, leaving the inclusive guard in place
  and accepting boundary values that the spec required to fail. The
  parser now falls back to the boolean form when no numeric value is
  present and promotes the matching `minimum` / `maximum` into the
  exclusive slot, so the existing strict-inequality guard fires
  correctly.

- **Issue #524: passing a non-YAML file to `--config` returns a
  friendly diagnostic instead of crashing.** Previously
  `oaspec.toml`-style mistakes triggered an Erlang `case_clause`
  runtime error because yay's FFI returned a `{yaml_error, ...}`
  tuple shape that the Gleam-side mapping didn't pattern-match.
  `config.load_all` now inspects the path's extension up front and,
  for clearly-non-YAML extensions, returns
  `ParseError(detail: "config files must be YAML; got '.<ext>'
  extension. Try renaming to '.yaml' (or '.yml').")` before yay sees
  the file. `.yaml` / `.yml` / extensionless paths are unchanged.

- **Issue #525: response variant suffixes use the IANA reason phrase
  for every standard HTTP status.** Pre-fix, `status_code_suffix/1`
  named only a handful of common codes (200 → `Ok`, 201 → `Created`,
  204 → `NoContent`, 401 → `Unauthorized`, 422 → `UnprocessableEntity`,
  500 → `InternalServerError`, …) and everything else fell through to
  the numeric `Status<N>` form. An operation declaring 200 + 202 thus
  produced `…ResponseOk` and `…ResponseStatus202` in the same union.
  The table now covers the full RFC 9110 / IANA registry —
  202 → `Accepted`, 206 → `PartialContent`, 301 → `MovedPermanently`,
  410 → `Gone`, 418 → `IAmATeapot`, 429 → `TooManyRequests`,
  503 → `ServiceUnavailable`, etc. Pre-existing entries keep their
  exact spelling so generated type names don't shift for already-
  shipped specs; non-standard codes still fall back to `Status<N>`.

- **Issue #526: pipeDelimited / spaceDelimited / form-explode-false
  query parsers no longer drop or emit empty-string items.** The
  `explode: false` array-of-string / int / number / boolean codegen
  used `Ok([v, ..])` (taking only the first occurrence) and
  `list.map(string.split(...))` (leaving empty splits in place). Two
  consequences: `?tags=` produced `Some([""])` instead of `Some([])`,
  and `?tags=a&tags=b` silently dropped `b`. The new shape
  `Ok(vs) -> Some(vs |> list.flat_map(string.split(_, delim)) |>
  list.map(string.trim) |> list.filter(_ != ""))` (with
  `list.filter_map` for Int / Float items) accepts all incoming
  occurrences and filters empty splits.

## [0.57.0] - 2026-05-05

### Tests

- **semantic invariants for the generated petstore client** — three
  new integration tests pin gaps that `decode(encode(x)) == x`
  alone cannot detect: `pet_encode_is_idempotent_test` asserts
  `encode(decode(encode(x)))` is byte-equal to `encode(x)`;
  `pet_optional_none_omits_key_test` asserts that an `Option`
  field with `None` produces JSON without that key (and without a
  literal `null`); `pet_optional_some_includes_key_test` covers
  the symmetric case.
- **deterministic 100-seed fuzz roundtrip** —
  `pet_roundtrip_property_test` exercises every `PetStatus` variant
  combined with both `None`/`Some(tag)` configurations across 100
  reproducible Pet values; failures print the exact seed so the
  case can be replayed via a single direct call to `pet_for_seed`.
- **multi-error aggregation contract for `validate.validate`** —
  new fixture `error_multiple_issues.yaml` pairs an unresolved
  global security $ref with a duplicate `operationId` across two
  paths, and `validate_aggregates_multiple_errors_in_one_pass_case`
  asserts that the validator surfaces all such issues in a single
  call rather than bailing on the first one.
- **deep JSON-pointer fidelity** — two new cases in
  `diagnostic_format_test.gleam` pin `pointer_to_human` against 6+
  segment pointers under `components.schemas.<X>.properties...`
  and `paths.<...>.requestBody.content.application/json.schema...`
  so a future "shorten long tails" change cannot silently drop the
  segment naming the actual broken field.
- **combined oneOf + nullable + array stress fixture** —
  `combined_oneof_nullable_array.yaml` exercises a oneOf inside
  an array `items` schema with both `nullable: true` and a
  `discriminator` mapping. Two cases pin the discriminator-aware
  tagged union shape and document the current observable behavior
  that items-level `nullable: true` is silently dropped, so
  introducing items-nullable support fails this gate loudly.
- **uninhabitable required self-ref pathological fixture** —
  `required_self_ref.yaml` declares a `required` field that
  $ref-references its enclosing schema. Today the generator emits
  `Node(child: Node)` (no `Option` wrapper) and an unconditionally
  recursive decoder; `required_self_ref_currently_accepted_case`
  pins this gap so a future inhabitability check at the validate
  phase will surface as an intentional contract change.

### Changed

- **golden snapshot comparison masks the auto-generated version
  header** — `// Code generated by oaspec vX.Y.Z.` is normalized
  on both sides of `assert_matches_golden` so a release bump no
  longer churns every committed golden file. Three unit tests
  guard the mask against over-matching (real version-like strings
  in body content) and under-matching (a tightened regex that
  stops matching the canonical header).
- **CI workflow split into four parallel pipelines with build
  cache** — the previous monolithic `ci.yml` (one runner, fully
  serial: setup → format → typecheck → lint → build → unit →
  shellspec → integration → escript → 4 examples → 2 adapters →
  readme → sync) is replaced by `ci-quick.yml` (format / typecheck
  / lint / sync), `ci-tests.yml` (build / unit / shellspec /
  integration / escript / readme), `ci-examples.yml` (matrix over
  petstore-client, petstore-client-fetch, server-adapter,
  js-smoke), and `ci-adapters.yml` (matrix over httpc, fetch).
  Each workflow caches `build/packages` keyed on `manifest.toml`
  so deps stop re-downloading on every run, and rebar3 is now
  installed via `setup-beam`'s `rebar3-version` instead of a
  separate wget step. README badges point at the four new
  workflow files.

## [0.56.0] - 2026-05-05

### Fixed

- **codegen(non-primitive query/header/cookie array items)**: query,
  header, and cookie parameters whose `items` resolved to a
  non-primitive schema (e.g. `tags: array of object`) panicked the
  client generator with `oaspec: inline composite schema reached
  to_string_fn after hoist`. The validator only blocked the shape
  in server mode, so `mode: client` codegen ran unimpeded into the
  panic; even the existing server gate let `Reference(_, hoisted)`
  through unconditionally even though hoist may have promoted a
  composite into the component. The rejection now follows hoisted
  `Reference`s through to their resolved shape and fires in BOTH
  modes for query, header, and cookie array params (cookies share
  the exploded-array codegen path so they're covered too).
  Surfaced by a new fixture-sweep regression test.
- **codegen(form-urlencoded nested arrays)**: an
  `application/x-www-form-urlencoded` request body whose nested
  object property contained an array (`profile.aliases: array of
  string`) panicked the client generator the same way —
  `generate_form_nested_object` routed the array through
  `multipart_field_to_string_fn`, which has no path for inline
  composite items. The form-urlencoded body validator now runs
  in both modes and forbids arrays-within-objects regardless of
  item type, so the spec is rejected with a clear diagnostic
  before the generator can crash.

### Tests

- **fixture-sweep parse + resolve smoke test**: a new unit case
  in `test/oaspec_support.gleam` enumerates every top-level
  `.yaml` under `test/fixtures/` and runs each through
  `parser.parse_file` and `resolve.resolve`, asserting the
  pipeline never panics on the suite's 200+ specs. Intentionally
  malformed fixtures (`broken*.yaml`, `error_invalid_yaml.yaml`,
  `oaspec*.yaml` config files) are excluded by name. A regression
  that breaks the parser entry point or the resolver on real-
  world specs surfaces immediately, instead of waiting for a
  hand-listed integration test to happen to cover the failing
  shape.
- **petstore client surface invariants**: a second unit case
  enumerates the public API the petstore client exposes —
  expected files (`client.gleam`, `decode.gleam`, …), one
  generated `pub fn` per declared operation, one `pub type` per
  declared component schema, plus the per-file non-empty +
  provenance smoke checks. Catches a renaming or accidental drop
  in the client codegen surface without needing a full
  integration build.

## [0.55.0] - 2026-05-05

### Tests

- **integration: format / non-empty / provenance smoke checks for
  generated code** — every per-fixture integration test now passes
  the generator's output through a shared `verify_generated_format`
  gate before its `gleam build --warnings-as-errors` step. The gate
  runs three regression checks on each emitted `.gleam` file (under
  `src/api`, excluding the `handlers.gleam` stub that some tests
  overwrite hand-written): the file is non-empty (catches a renderer
  that silently produces zero-length output), the file carries the
  `// Code generated by oaspec` provenance header (catches missing
  `se.file_header`), and `gleam format --check` is a no-op (catches
  a regression in the formatter step that runs during emission).
  Previously only the build was re-checked, and several codegen
  bugs were already in flight before any of those three gates would
  have caught them.
- **unit: import-gating regression guards for #502 / #503 / #504** —
  three new test cases in `test/oaspec_support.gleam` pin the import
  decisions for the just-shipped fixes: a deepObject-only client
  imports `gleam/option.{Some, None}`; a multipart-object/array
  client imports `gleam/list`, `gleam/json`, and the option ctors;
  a `*/*` request body routes through `transport.BytesBody` and
  *not* through `transport.TextBody(json.to_string(...))`. These
  catch a regression to the import gate without needing to run the
  full integration pipeline.

## [0.54.0] - 2026-05-05

### Fixed

- **codegen(client imports)**: client modules generated for specs
  that use multipart object/array fields (#503) or deepObject query
  parameters (#502) now include `gleam/option.{None, Some}`,
  `gleam/list`, and `gleam/json` whenever the emission path
  references those modules. The previous import gate only counted
  optional params / response headers, so multipart `Some(v) -> ...`
  arms and deepObject `Some(v_outer) -> ...` arms compiled with
  "constructor `Some` is not in scope" errors against
  `--warnings-as-errors`.
- **codegen(`*/*` request body)**: client request bodies declared
  with `*/*` content type now travel through `transport.BytesBody`
  instead of being routed through the JSON encoder fallback. The
  previous emission tried `transport.TextBody(json.to_string(...))`
  and failed because `gleam/json` was not in scope and the body type
  was `BitArray` rather than a JSON-encodable value.

### Tests

- **integration coverage for #502 / #503 / #504**: each fixture is
  now generated, gleam-formatted (no-op `gleam format --check`), and
  compiled with `gleam build --warnings-as-errors` in
  `integration_test/run.sh`. A new `verify_format` helper makes it a
  one-liner to extend the same format gate to the rest of the
  integration suite as a follow-up.

## [0.53.0] - 2026-05-05

### Added

- **codegen(deepObject nested objects)**: `style: deepObject` query
  parameters with nested object properties (e.g. Stripe's
  `filter.applicability_scope` and `status_transitions.posted_at`)
  now pass client-mode validation and generate working client code.
  The generator emits one bracketed-bracketed query entry per inner
  primitive property
  (`filter[applicability_scope][price_type]=value`), wrapping
  optional outer / inner fields in matching `Some(_)` / `None` arms
  so the typed record actually serialises onto the wire instead of
  being smuggled into the query tuple as a record value (a latent
  bug previously masked by the validator's hard rejection). oneOf /
  anyOf properties on a deepObject parameter remain rejected because
  they don't fit the bracketed-string wire format. Server-mode
  routing still requires primitive scalars / primitive arrays for
  deepObject properties; lifting that constraint requires a router
  decoder rewrite and is tracked separately. Issue #502.

- **codegen(multipart object/array fields)**: `multipart/form-data`
  request bodies whose individual fields are arrays or objects now
  pass client-mode validation and produce working client code. The
  generator emits one part per element for array fields (`expand[]`
  shaped, but with the literal field name repeated as the OAS 3
  multipart serialization rules prescribe) and a single part with
  `Content-Type: application/json` carrying the JSON-encoded value
  for object fields. Stripe's `POST /v1/files` is the motivating
  real-world endpoint — `expand: array of strings` and
  `file_link_data: object` were previously rejected with
  "multipart/form-data fields must be string, integer, number,
  boolean, binary, or string enums." Server-mode multipart fields
  are still restricted to primitive scalars / primitive arrays;
  lifting that restriction is tracked separately. Issue #503.

- **codegen(`*/*` content type)**: OpenAPI's `*/*` catch-all media type
  is now recognised as a supported request and response content type.
  Specs like Kubernetes' OpenAPI v3 use `*/*` heavily for proxy
  endpoints and resource-mutation handlers (`replace`, `delete`,
  `create`) that accept or emit arbitrary bytes; previously each
  `*/*` declaration produced a hard validation error and the spec was
  un-generatable. oaspec now treats `*/*` as a synonym for
  `application/octet-stream` for codegen purposes — the request body
  is `BitArray`, the response body is `BitArray` — which matches the
  "any bytes" semantics without committing the SDK to a specific
  parser. Both client and server modes accept the new shape; the
  server router exposes the body as raw `BitArray` and the response
  emitter wraps it in `BytesBody`. Issue #504.

## [0.52.0] - 2026-05-05

### Fixed

- **codegen(path filter)**: `targets[].include.paths` previously dropped
  unwanted operations from `spec.paths` but left every component schema
  in `spec.components.schemas` intact, so the generated `decode.gleam`,
  `encode.gleam`, `types.gleam`, and `guards.gleam` still emitted code
  for every schema in the spec. A one-path filter against GitHub's REST
  OpenAPI produced an 11 MB `decode.gleam` instead of the ~22 KB the
  filter implied. Generation now runs a reachability pass after hoist
  and before dedup that walks every operation surviving the filter
  (parameters, request bodies, response bodies, response headers,
  callbacks, and webhooks) into the schema graph
  (`properties` / `items` / `additionalProperties.Typed` /
  `allOf` / `oneOf` / `anyOf` / `discriminator.mapping`) and prunes
  `components.schemas` to the reachable set. The pass only runs when an
  include filter is configured; without a filter the spec is presented
  as-authored. Issue #501.

## [0.51.0] - 2026-05-05

### Fixed

- **codegen(`XxxList` decoder)**: when a spec declared both `Foo` and
  `FooList` as component schemas, the synthetic
  `decode_foo_list` helper collided with the user-named decoder
  for `FooList` and the validator hard-rejected the spec with
  `decode_foo_list ... collides with the synthetic list decoder`.
  Real-world specs (Kubernetes hits this 30+ times in `api/v1`,
  Stripe once) cannot be renamed. The synthetic decoder now shifts
  to `decode_foo_list_items` when `<Schema>List` is also declared
  and stays at `decode_foo_list` otherwise; the user-named
  `FooList` decoder keeps the natural name. Issue #493 (PR #497).
- **codegen(array-of-`$ref` responses)**: a response schema typed as
  `array` with `items: $ref` decoded through a missing
  `decode_<name>_list(text)` wrapper for any non-object item
  schema (enum, primitive, oneOf, anyOf). It now parses with
  `json.parse(text, dyn_decode.list(decode.<name>_decoder()))`
  which is emitted unconditionally for every schema kind, fixing
  a pre-existing bug surfaced during the issue #493 review (PR #497).
- **codegen(inline-enum vs component collision)**: GitHub's spec
  declares `code-scanning-variant-analysis-status` as a top-level
  component (4-value enum) AND a separate
  `code-scanning-variant-analysis` whose inline `status` property
  is a 6-value enum. Both previously generated `pub type
  CodeScanningVariantAnalysisStatus { ... }` and `gleam build`
  rejected the output as a duplicate type definition. The codegen
  now disambiguates the inline enum's name with a numeric suffix
  (`CodeScanningVariantAnalysisStatus2`) when a component schema
  already claims the bare name; the component schema keeps its
  natural name. Issue #492 (PR #498).
- **naming(dotted schema names)**: Stripe's spec declares pairs of
  schemas that differ only by `.` vs `_` — e.g.
  `payment_intent.processing` and `payment_intent_processing` —
  and the validator hard-rejected them with `Schema names ... all
  map to Gleam type ... — rename one to avoid the collision`. The
  naming pipeline now encodes `.` as a `_dot_` word boundary so
  the dot survives both PascalCase (`PaymentIntentDotProcessing`)
  and snake_case (`payment_intent_dot_processing`) output, keeping
  Stripe-style dotted-vs-underscored siblings distinguishable. A
  literal `_dot_` already in the input is escaped to
  `_dot_literal_` first so authors using both forms still produce
  distinct names. Issue #494 (PR #499).

## [0.50.0] - 2026-05-05

### Breaking

- **codegen(octet-stream)**: an `application/octet-stream` request
  body field now surfaces as `body: BitArray` on both server and
  client request types instead of `body: String`. The README's
  Mode-Specific Support table promised `BitArray`, the client
  wraps it in `transport.BytesBody` (which expects `BitArray`),
  and forcing it through `String` meant arbitrary binary payloads
  could not round-trip without going through
  `bit_array.to_string |> result.unwrap("")`, which silently
  drops non-UTF-8 bytes. The client autogen `let body =
  transport.BytesBody(body)` previously failed `gleam check` with
  a type mismatch. Specs that declare octet-stream on any
  operation also see the server router signature change from
  `body: String` to `body: BitArray`; non-binary arms shadow the
  parameter with the String conversion at the top of each arm so
  the rest of the codegen template is unchanged. Specs without
  any binary request body keep the existing `body: String`
  signature. **Migration**: server adapters for specs with
  octet-stream pass `mist.read_body(...).body` (a `BitArray`)
  straight to `oas_router.route(...)` without the lossy
  `bit_array.to_string` step; client callers pass
  `BitArray` instead of `String` for binary bodies. (#485)

- **codegen(default-response)**: the generated `XxxResponseDefault`
  variant now carries a runtime `Int` status code as its first
  positional field, so handlers can pick any 4xx/5xx for the
  catch-all branch instead of being pinned to 500. Concretely:

      // before
      DeleteArtifactResponseDefault(types.Error)
      // after
      DeleteArtifactResponseDefault(Int, types.Error)

  Variants without a body collapse to `Default(Int)`; variants with
  declared response headers append the headers record as the last
  positional field exactly as the other response variants do. The
  router's `ServerResponse.status` is now sourced from the bound
  `status` rather than the previous hardcoded `500`, and the client
  decoder captures the actual response `Int` and threads it back
  through the variant. **Migration**: every handler that constructs
  a `Default` variant must be updated to supply the status code
  (`401`, `404`, …) as the first argument; every caller pattern-
  matching the variant must add the `status` binding. (#483)

### Fixed

- **server-codegen(multipart)**: a `multipart/form-data` request body
  field whose schema is a `$ref` to a string-enum schema is now
  decoded into the generated sum-type variant rather than copied as
  raw `String` into the enum-typed slot of the request type. The
  previous shape (`category: case dict.get(multipart_body,
  "category") { Ok([v, ..]) -> v _ -> "" }`) failed `gleam check`
  with a type mismatch (`Expected: types.Category, Found: String`),
  putting a perfectly normal OpenAPI shape (enum field on a
  multipart upload) outside the "autogen compiles unmodified"
  promise. The same fix also covers
  `application/x-www-form-urlencoded` bodies, which share the
  underlying `body_required_expr` / `body_optional_expr` codepath.
  Required enum fields fall back to the first declared variant on
  miss / unknown (mirroring the type-zero fallback already used for
  primitive required body fields per #327); optional enum fields
  fall back to `None` (mirroring the permissive behaviour of #305
  for `$ref`-typed enum query parameters). (#482)

- **cli(config)**: `validate_no_target_overlap` no longer rejects
  a single-target config with `mode: both` whose `output.server`
  and `output.client` resolve to the same directory. The check
  was added in #387 to catch cross-config (multi-target) collisions
  where two `targets:` entries clobber each other on disk; for a
  single config the case is intentionally allowed because the
  codegen writes shared files (`types`, `decode`, `encode`,
  `guards`, `request_types`, `response_types`) with identical
  content for both modes, plus disjoint server-only files
  (`router`, `handlers`, `handlers_generated`) and one client-only
  file (`client`). Previously `gleam run -- generate
  --config=golden/petstore.oaspec.yaml` (and therefore
  `just update-golden`) failed with `two targets resolve to the
  same output directory`. `active_output_paths` now dedupes
  intra-config when `output.server == output.client`, leaving the
  cross-config rejection path unchanged. Added a positive
  shellspec test under `single-target shared output` alongside the
  existing rejection test for multi-target overlap.

### Added

- **docs(README)**: clarify that server-side OpenAPI `security:`
  declarations are parsed but **not enforced** by the generated
  router. The previous Mode-Specific Support table listed
  `Security` as `yes` for the server, which spec authors
  reasonably read as "the router emits a 401 when the request
  lacks the declared credentials" — the router does no such
  check; handlers must verify auth themselves. The table entry
  now reads `parsed (not enforced)`, the prose support list and
  the OpenAPI Support coverage paragraph distinguish client vs.
  server behaviour explicitly, and a new `Server security model`
  subsection documents the two practical options (enforce in the
  handler, or wrap `router.route/6` in an outer auth-checking
  adapter). No source code change in this entry; the underlying
  router behaviour is unchanged. (#484)

- **docs(README)**: the main README now ships an inline canonical
  `mist` server-adapter snippet (mirroring the existing inline
  Client transport snippet) so server users can reach a runnable
  shape without first drilling into `examples/server_adapter`. Stale
  references to `router.route/5` were corrected to `route/6` (the
  app_state parameter has been emitted for several releases). (#480)

- **adapters**: README files for `adapters/httpc/` and `adapters/fetch/`.
  `gleam publish` requires every package to have a README, and the
  first attempt to push `oaspec_httpc-v0.1.0` failed with `Cannot
  publish with no README`. Each adapter README describes what the
  package is, how to install it once published, the quick-start
  example from the root README's Client transport section, and a
  pointer to `oaspec/mock` for unit tests. No source-code change.

## [0.49.0] - 2026-05-04

### Fixed

- **codegen(decoders)**: a schema declared as
  `type: object, properties: {}, additionalProperties: false`
  surfaces in `types.gleam` as a no-arg variant
  (`pub type EmptyObject { EmptyObject }`), but the matching
  decoder emitted `decode.success(types.EmptyObject())` —
  invalid Gleam, since the constructor is a value not a
  function. The compile failure surfaced on real-world specs
  (notably the GitHub OpenAPI subset, where multiple endpoints
  return Empty Object). The decoder generator now special-cases
  the empty-`param_names` branch and emits the bare reference
  `decode.success(types.EmptyObject)`. A regression test in
  `oaspec_support.empty_object_decoder_omits_constructor_parens_case`
  locks the behaviour in. Closes #474.

### Changed

- **docs(readme)**: install snippet now adds `gleam_json` alongside
  `oaspec` (`gleam add oaspec gleam_json`) and explains why — the
  generated `decode.gleam`, `encode.gleam`, `guards.gleam`, and
  `router.gleam` modules `import gleam/json` directly, so consumers
  must list `gleam_json` as a direct dependency to avoid a
  "Transitive dependency imported" warning on every `gleam check`
  (and a hard compile error in a future Gleam release). Closes #469.
- **docs(readme)**: dropped the broken `git = "...", subpath = "..."`
  alternative from the `oaspec_httpc` / `oaspec_fetch` adapter
  install note. Gleam's `gleam.toml` parser does not accept a
  `subpath` field on git dependencies as of Gleam 1.16, so the
  recommended snippet failed with `data did not match any variant
  of untagged enum Requirement` before any build started. The
  surviving `path = "../oaspec/adapters/fetch"` form is the only
  working approach until the adapters are published to Hex (tracked
  in #471), and the note now explains why a pure git dependency
  also does not work (each adapter is in a subdirectory of the
  oaspec repo). Closes #470.

### Added

- **release(adapters)**: dedicated tag-driven publishing
  workflows for `oaspec_httpc` and `oaspec_fetch`. Tag patterns
  `oaspec_httpc-v*` and `oaspec_fetch-v*` trigger
  `.github/workflows/release-adapter-httpc.yml` and
  `.github/workflows/release-adapter-fetch.yml` respectively;
  each rewrites the adapter's parent `oaspec = { path = "../.." }`
  dep to a Hex version constraint floored at the current
  root-`gleam.toml` version (`>= X.Y.Z and < 1.0.0`) before
  invoking `gleam publish`, so consumers can `gleam add
  oaspec_httpc` / `gleam add oaspec_fetch` after any successful
  adapter release. Decoupling the adapter tag pattern from the
  main `v*` tag means oaspec releases and adapter releases can
  cut on independent cadences and avoid `gleam publish` rejecting
  a re-published version. The README's adapter section now
  describes the new flow and keeps the path-dep workaround for the
  interim before the first adapter tag is pushed. Closes #471.

## [0.48.0] - 2026-05-04

### Added

- **diagnostics**: capability-check errors now carry a YAML
  `SourceLoc` and the CLI prefixes each rendered diagnostic with
  `path:line:column:` so editors can jump straight to the offending
  spec line. Public-API plumbing:
  `parser.parse_file_with_progress_and_locations` returns the spec
  *and* a `LocationIndex`, and `generate.generate_with_progress_and_locations`
  / `validate_only_with_progress_and_locations` thread the index
  through to capability checks. `diagnostic.capability` gains a
  required `loc:` parameter (breaking; 0.x) and a new
  `diagnostic.render(d, file_path)` helper produces the
  editor-clickable prefix. `location_index.lookup_with_ancestor`
  walks up dot-separated paths so capability paths that don't
  exactly match the YAML index still surface the closest known
  ancestor (e.g. the parent schema's line). Closes #411.

### Changed

- BREAKING: `parser.parse_file_with_progress`,
  `generate.generate_with_progress`, and
  `generate.validate_only_with_progress` are removed in favour of the
  combined `*_with_progress_and_locations` variants. Library callers
  that relied on the progress-only overloads should migrate to the
  combined entry point and pass `location_index.empty()` if they
  don't have a YAML location index. (#411)

## [0.47.0] - 2026-05-04

### Changed

- **codegen**: lifted the static runtime helper blobs that
  `internal/codegen/server` (`deep_object_present`,
  `deep_object_present_any`, `deep_object_additional_properties`,
  `coerce_dict`, `form_url_decode` / `parse_form_body`,
  multipart helpers, `form_object_present`, `cookie_lookup`),
  `internal/codegen/encoders` (`encode_dynamic`), and
  `internal/codegen/client` (`text_body` / `bytes_body` /
  `await_response`) splice into generated code into a new
  `internal/codegen/runtime_snippets` module. Each helper is now a
  `pub const` string spliced via the new `string_extra.raw`
  appender; the gating `case requirements.<flag>` shape stays put
  but the snippet body is no longer interleaved with `se.line` /
  `se.indent` calls. `server.gleam` shrinks by ~210 lines and the
  snippets become trivially diff-able. Closes #417.

## [0.46.0] - 2026-05-04

### Changed

- **codegen**: introduced three severity / target shortcut builders
  on `oaspec/openapi/diagnostic` —
  `validation_error_both`, `validation_error_server`,
  `validation_warning_both` — and migrated every
  `diagnostic.validation(...)` call site in
  `internal/codegen/validate` (28 sites) onto them. Each call site
  now focuses on the variable bits (`path` / `detail` / `hint`)
  instead of restating the same `severity:` / `target:` pair. The
  `Severity*` / `Target*` re-exports in validate.gleam's import
  block become unused as a result and are dropped. Closes #416.

## [0.45.0] - 2026-05-04

### Documentation

- **codegen**: clarified the four `panic as { ... }` sites in
  `internal/codegen/schema_dispatch` (`decoder_expr` /
  `json_encoder_expr` / `json_encoder_fn` / `to_string_fn`) as
  hoist-contract tripwires rather than user-facing errors. Each panic
  now points at `oaspec/internal/openapi/hoist` as the post-hoist
  invariant owner and asks users who hit them to file an issue with
  the offending spec. The `Result`-based dispatch suggested in #390
  was investigated but deferred — it would have rippled through 9+
  caller sites in `decoders` / `encoders` / `client_request` and
  would have masked the contract that hoist is responsible for. (#390)

### Performance

- naming: `to_pascal_case` / `to_snake_case` no longer recompile the
  three internal regexes on every call. The compiled `Regexes`
  record is cached in the BEAM `persistent_term` table via a tiny
  `oaspec_naming_ffi:memoize/2` Erlang helper — first caller wins,
  every subsequent call is an O(1) lookup with no GC pressure. On a
  10k-schema spec this collapses 30k+ regex compiles to 3. The new
  file is the only FFI in the project; an `ffi_usage` lint
  exception is added only for `internal/util/naming.gleam`. (#405)

## [0.44.0] - 2026-05-04

### Changed

- **codegen**: collapsed the seven near-identical
  `build_*_guard_function` range builders in `internal/codegen/guards`
  (string length, integer range, integer exclusive range, float range,
  float exclusive range, list length, property count) onto a single
  `build_range_guard` helper plus a small `RangeGuardSpec` record. The
  exclusive-bound emit shape is now `True -> failure / False -> Ok(value)`
  via `<=` / `>=` instead of the prior `False -> failure / True -> Ok(value)`
  via `>` / `<`; the generated guards are equivalent at runtime but
  the test suite's three exclusive-range substring assertions are
  updated to match the new operators. Adding a new range-shaped
  validator keyword now changes one helper instead of duplicating a
  ~70-line skeleton. (#403)

### Added

- tests: real-filesystem coverage for `writer.write_all` against a
  temp directory under `/tmp/oaspec_writer_test/`. Pins the
  Overwrite path (creates dirs + writes content), the SkipIfExists
  contract for user-owned `handlers.gleam` (Issue #247), and the
  `on_write` callback's per-file invocation. The pure
  `resolve_paths` / `output_dirs` / `error_to_string` cases that
  pre-existed continue to cover the IO-free side of the module.
  (#401)
- tests: a new `Describe 'oaspec init'` block was already added in
  v0.42.0; this round adds gleeunit coverage for the generated
  `api/router.route/5` happy paths (`GET /pets`, `GET /pets/{id}`),
  the 404 fallback for unknown paths and unknown methods, query-
  parameter parsing, and `api/guards.validate_pet_name_length` /
  `validate_pet` accept-and-reject paths against the committed
  `integration_test/` petstore project. The pre-existing committed
  gleeunit suite never imported `api/router` or `api/guards`; a
  regression that broke router happy-path matching or guard
  rejection would only have surfaced via `integration_test/run.sh`
  before. (#422)

### Changed

- `scripts/check_readme_examples.sh` now extracts the README's two
  Library API gleam fences at runtime via awk instead of carrying a
  hardcoded copy of the snippets. Closes the drift hazard flagged
  in #410. The README's example case arms are also tightened to be
  legal Gleam (`Nil` / `_summary` / `_errors`) so the smoke compile
  is warning-free. (#410)

## [0.43.0] - 2026-05-04

### Performance

- parser: finished migrating `openapi/parser.gleam` (~40 sites) onto the
  `parser_value.{optional_*, *_default}` helpers. The lingering
  `result.unwrap(None) |> option.unwrap(default)` chains across path /
  operation / parameter / requestBody / response / securityScheme /
  serverVariable / mediaType / encoding / link parsing are gone; intent
  now reads off the call site instead of needing a two-line decode.
  Closes the follow-up tracked under #423.
- codegen: `decoders.gleam::generate_decoders` now computes the
  sorted+filtered component-schema list once and shares it across the
  import-detection `list.any` passes and the emission folds. The
  previous shape sorted the dict twice and filtered separately at the
  second site, which both wasted work and risked the import header
  disagreeing with the emission on internal schemas. (#435)

## [0.42.0] - 2026-05-04

### Added

- tests: complementary `try_await` (Ok-Ok chaining) and `map_try`
  (error short-circuit) coverage on `oaspec/transport`, plus async-send
  variants of `with_default_header`, `with_default_headers`, and
  `with_security` so the polymorphic-transport contract is exercised
  on `transport.AsyncSend`, not just the sync `Send` surface. (#427, #428)
- tests: a new `config_error_formatting_test` group asserting the
  user-facing string produced by `config.error_to_string` for each
  `ConfigError` variant (FileNotFound, FileReadError, ParseError,
  MissingField, InvalidValue), plus a regression case pinning that an
  empty / non-conforming config surfaces as `MissingField` /
  `InvalidValue` rather than a generic parse failure. (#413)
- tests: `diagnostic.to_short_string` and `diagnostic.to_string` now
  have direct shape assertions for the `file_error`, `yaml_error`
  (with and without source loc), `missing_field`, and `invalid_value`
  branches. The pointer-to-human stack is already covered by
  `diagnostic_format_test`; this fills the surrounding format gap. (#414)
- tests: ShellSpec coverage for `oaspec generate --output=DIR` /
  `--output DIR` (space form), parse-failure exit codes on
  `error_missing_info.yaml`, the same parse-failure path through
  `oaspec validate`, and `--mode=client` override on the validator.
  (#398, #399, #433)
- tests: a dedicated `oaspec init` ShellSpec block covering default
  output (`./oaspec.yaml`), `--output=PATH` override, and the
  overwrite-refusal exit-status / stderr contract. (#400)
- tests: `parse_json_string_malformed_has_diagnostic_shape_case`
  pins the parse-phase diagnostic shape (severity, phase, non-empty
  code/message) so a regression that returned a bare-`String` error
  or dropped the structured fields surfaces immediately. (#431)
- community files: a Contributor Covenant `CODE_OF_CONDUCT.md`, plus
  minimal issue templates (bug report, feature request) and a pull
  request template under `.github/`. The templates only ask for what
  is genuinely useful (version info, what was tried, what happened) —
  no checklists or boilerplate. (#415)

### Documentation

- examples: `petstore_client` is now scoped (in title, README header,
  and program preamble) as a generated-client / decoder roundtrip demo
  against a stub transport, not a real-HTTP example. Adds a "Hooking
  up real HTTP" section showing the one-liner swap to the
  `oaspec_httpc` adapter so the BEAM HTTP path is documented in code
  even though no sibling runnable example ships yet. The top-level
  README's examples list reflects the same scoping. (#425)
- changelog: adopted a dedicated `Breaking` subsection convention for
  future releases — older `BREAKING:`-prefixed entries within
  `Changed` / `Fixed` stay as historical record. The README pointer
  to the latest breaking section is added once the first such release
  ships. (#434)
- examples: every example README (`petstore_client`,
  `petstore_client_fetch`, `server_adapter`) now includes a
  "What the generator produces" section with a short signature
  excerpt of the generated `client.gleam` / `router.gleam` /
  `response_types.gleam`, so a reader can preview the shape before
  cloning. (#424)
- readme: dropped the inline logo `<img>` from the top-of-README
  rewrite, collapsed the centered badge block back to inline shields,
  and removed gratuitous bold-text emphasis to match the project's
  plain-prose voice.
- **readme**: top-of-README rewrite — Hex / HexDocs / license / CI
  badges, a 30-second pitch with a runnable 5-line client example,
  and a HexDocs link near the install section. (#397)
- **readme**: install section now leads with the Hex library install
  (`gleam add oaspec`) for consumers of the runtime / generator API,
  and the GitHub-release / build-from-source paths are scoped to the
  CLI use case. (#391)
- **readme**: Quickstart adds a "fetch a sample spec" step so first-time
  users can run `oaspec generate` end-to-end, and rephrases step 2 to
  match what `oaspec init` actually writes (a fully-commented template
  with only `package: api` uncommented). (#396)
- **readme**: Supported input list and the Mode-Specific Support table
  document `text/plain` and `application/octet-stream` request bodies,
  matching what the validator and capability registry already accept.
  (#407)
- **readme**: multipart/form-data server restriction is now described
  as "primitive scalar fields or arrays of primitive scalars", matching
  the validator and the diagnostic hint. (#408)
- **readme**: added a "Public modules at a glance" table to the
  Library API section that covers all seven public modules
  (`oaspec/transport`, `oaspec/mock`, `oaspec/config`,
  `oaspec/generate`, `oaspec/openapi/parser`, `oaspec/openapi/diagnostic`,
  `oaspec/codegen/writer`) so library users can pick the right entry
  point at a glance. (#412)
- **readme**: explicit "not yet on Hex" note next to the `oaspec_httpc`
  / `oaspec_fetch` adapter mentions, with a path / git dependency
  snippet pointing at the bundled examples' `gleam.toml`. (#392)

### Removed

- **codegen**: dropped the unused `context.analyzed_schemas/1` accessor
  and its backing `AnalyzedSchema` type. Production codegen consumes
  the schema cache through `resolve_schema_ref/2`, and the snapshot
  test that backed `analyzed_schemas/1` was the only reader. The
  internal `build_schema_cache` is now a one-shot fold over the spec's
  components dict instead of going through an intermediary list. (#429)
- **codegen**: dropped the `validate.errors_only` /
  `validate.warnings_only` / `validate.filter_by_mode` pass-through
  wrappers. Callers (`generate.gleam` and the test suite) now import
  `oaspec/openapi/diagnostic` and call those functions directly, which
  removes the prior two-name confusion (`generate.gleam` had been
  mixing both forms). (#430)

### Changed

- **codegen**: extracted shared codec helpers
  (`escape_for_string_literal`, `list_at_or`, `qualified_schema_ref_type`,
  `schema_ref_has_bare_option_type`) into a new
  `oaspec/internal/codegen/codec_helpers` module. Both `encoders.gleam`
  and `decoders.gleam` import from there now; the prior copy-pasted
  duplicates (and the divergent `schema_ref_has_bare_option_*_type`
  pair) are gone. Closes the follow-up flagged in #212. (#402)
- **codegen**: `oaspec/internal/codegen/types` is now a thin module
  that owns only `generate/1` and its private rendering helpers. The
  dozen passthrough re-exports (`schema_to_gleam_type`,
  `schema_has_*`, `filter_*_properties`, `merge_allof_schemas`, …) are
  removed; callers (`encoders`, `decoders`, `guards`, `codec_helpers`)
  now import `schema_utils` / `schema_dispatch` / `allof_merge`
  directly. (#419)
- **codegen**: function signatures across `decoders`, `encoders`,
  `ir_build`, `router_ir`, `server`, `server_request_decode`, and
  `validate` standardise on `List(context.AnalyzedOperation)` instead
  of the inline 4-tuple shape `List(#(String, spec.Operation(Resolved),
  String, spec.HttpMethod))`. The `AnalyzedOperation` alias already
  existed; this PR finishes wiring callers through it so future field
  additions on the alias don't ripple across 19 signatures. (#421)

### Performance

- **transport**: `with_default_headers` no longer rebuilds `req.headers`
  with `list.append(acc, [...])` on every fold step — the merge now uses
  prepend + final reverse, dropping the O(N²) shape that showed up on
  requests with many default headers. Iteration order on the wire is
  preserved. (#404)
- **codegen**: `hoist.hoist_parameters` and `validate.group_operations_by_id`
  switch their inner accumulators from `list.append(acc, [x])` to
  prepend-and-reverse-once, so traversal of large specs scales linearly
  with parameter / duplicate-site counts instead of quadratically. (#426)
- **parser**: new `parser_value.{optional_bool, optional_string,
  optional_int, optional_float, bool_default, string_default,
  int_default}` helpers replace the brittle
  `result.unwrap(None) |> option.unwrap(default)` chains. Migrated the
  schema-object parser and `config.gleam` over to the helpers; the
  remaining ~40 mechanical migration sites in `openapi/parser.gleam`
  are tracked as a follow-up under the same Issue. (#423)

### Added

- first-party JavaScript fetch adapter and an explicit async client transport contract. Document and cover the new JS execution path with a runnable example and CI updates. Closes #347.

### Changed

- **Internal: add shared schema queries to `Context` and route codegen /
  validation through them.** `Context` now precomputes an inspectable
  `analyzed_schemas` view plus a cached component-schema resolver, exposed
  through `context.resolve_schema_ref/2` and `context.schema_metadata/2`.
  The repeated ad hoc `$ref` resolution logic in `schema_dispatch`,
  `schema_utils`, `client_request`, `server_request_decode`, `guards`,
  `validate`, and related helpers now goes through that shared query layer
  instead of each module resolving component refs independently. Adds
  context-level tests for analyzed schema snapshots and nested property
  metadata flags, completing the deferred schema-query follow-up for #371.

## [0.40.0] - 2026-05-01

### Changed

- **Internal: split the monolithic `oaspec_test` suite into stage-specific
  entrypoint modules.** The legacy catch-all suite is now driven by a
  minimal runner plus dedicated wrapper modules for the core, parse,
  normalize, resolve, validate, codegen, server-codegen, guard-integration,
  and OSS fixture stages. The original case bodies were preserved
  verbatim in `test/oaspec_support.gleam` so behaviour is unchanged, but
  failures now point at the offending pipeline stage instead of one giant
  module. Also adds an analyzed-operations snapshot assertion in
  `test/context_test.gleam` so regressions can fail at the shared
  intermediate cache rather than only at end-to-end generation. Closes #374.
- **Internal: move client, router, and guard generation onto structured
  IR.** `client_ir` and `router_ir` now compute structured generation
  requirements (option/result usage, transport flags, import sets) which
  `client.gleam` and `server.gleam` consume in place of large local
  boolean blocks. `guards.gleam` builds structured validator definitions,
  dedupes field validators before rendering, and exposes
  `build_module/1` so the generated validator surface can be asserted
  semantically without reparsing source text. New unit tests cover the
  structured requirements and dedupe behaviour directly. Closes #373.

## [0.39.0] - 2026-05-01

### Changed

- **Internal: precompute the analyzed-operations list once per generation
  context.** `Context` now holds the result of
  `operations.collect_operations` (with merged path-level params, effective
  security, effective servers, and synthesized operationIds) and exposes it
  through a new `context.operations/1` accessor. Every codegen and
  validation pass — `client`, `decoders`, `encoders`, `ir_build`, `server`,
  `types`, `validate`, and `capability_check` — now reads this shared list
  instead of rebuilding it at unrelated call sites. Step 1 toward #371; the
  schema-query consolidation called out in that issue is left for a
  follow-up PR.
- **Internal: split the external `$ref` loader into an IO shell and a pure
  rewrite planner.** The new `oaspec/internal/openapi/external_loader_planner`
  module now owns ref-string parsing, schema/parameter/requestBody/response/
  pathItem lookups inside parsed external documents, alias resolution, and
  collision diagnostics. `external_loader` is now ~530 lines smaller and
  delegates every pure decision to the planner, so each external-ref
  diagnostic — local collision, cross-file collision, missing component,
  alias chain, chained external ref — can be unit tested without staging
  fixture files on disk. Closes #372.

## [0.38.0] - 2026-05-01

### Added

- **`examples/js_smoke` and a CI step that builds + runs it on
  `target = "javascript"`.** This is the first executable proof
  that oaspec's documented pure subgraph compiles and runs on a
  non-BEAM target: the example imports `oaspec/transport` and
  `oaspec/mock`, builds with Gleam's JS backend, and runs to
  completion on Node. Any future change that re-couples those
  modules to BEAM-only code will fail the CI job. Closes #344.

### Changed

- **`ARCHITECTURE.md` updated to distinguish "source-level pure"
  from "actually JS-runnable today".** Many modules listed under
  "Pure" still pull in `oaspec/config` (and through it `yay`) via
  transitive imports, so a JS-target build of those modules works
  but module-load on Node fails because `yay`'s JS FFI requires the
  `js-yaml` npm package. The doc now states that explicitly and
  identifies decoupling that transitive chain as the largest piece
  of remaining cross-target work.

## [0.37.0] - 2026-04-30

### Changed

- **Internal: make `oaspec/internal/progress` cross-target.** The
  `monotonic_ms` clock helper now declares both an Erlang
  `@external` (existing `oaspec_ffi:monotonic_ms/0`) and a
  JavaScript `@external` backed by a new `src/oaspec_ffi.mjs` that
  uses `performance.now()` for monotonic semantics, falling back to
  `Date.now()` if `performance` is unavailable. Behavior on the
  Erlang target is unchanged; this brings the BEAM-coupled module
  count down by one and lets `progress.gleam` actually compile on
  any Gleam target. (#344)

## [0.36.0] - 2026-04-30

### Changed

- **Internal: split the `yay` error bridge out of
  `oaspec/internal/openapi/parser_error`.** The diagnostic-assembly
  helper now lives in a pure Gleam module (`missing_field_with_hint`,
  no `yay` import), and the BEAM-coupled `yay.ExtractionError` /
  `yay.SelectorError` adapters that wrap it have moved to a new
  `parser_yay_error` sibling module. Behavior is unchanged; this is
  a relocation rather than a net reduction in BEAM-coupled modules,
  but `parser_error.gleam` itself now compiles on any Gleam target,
  in line with the boundary documented in `ARCHITECTURE.md`. (#344)

## [0.35.0] - 2026-04-30

### Changed

- **Internal: make `oaspec/internal/openapi/resolve` cross-target.**
  The `coerce_stage` phantom-type cast now declares both an Erlang
  and a JavaScript `@external` so it is a runtime no-op on either
  Gleam target. The function is unchanged at runtime — `OpenApiSpec`
  is byte-for-byte identical before and after the cast — but the
  module no longer counts as BEAM-coupled in `ARCHITECTURE.md`.
  (#344)

## [0.34.0] - 2026-04-30

### Changed

- **Internal: split the BEAM-only `yay` bridge out of
  `oaspec/internal/openapi/value`.** The `JsonValue` type now lives
  in a pure Gleam module with no `yay` dependency, and the
  `extract_optional` / `extract_map` helpers that walk `yay` nodes
  have moved to a new `parser_value` sibling module. Behavior is
  unchanged; this shrinks the BEAM-coupled module count by one and
  makes `value.gleam` actually compile on any Gleam target, in line
  with the boundary documented in `ARCHITECTURE.md`. (#344)

## [0.33.0] - 2026-04-30

### Added

- **`ARCHITECTURE.md`** documenting the boundary between the pure
  Gleam analysis/codegen core and the BEAM-only shell (CLI, file IO,
  YAML parsing, formatter subprocess, FFI). Classifies every module
  in `src/` as pure, BEAM-coupled, or adapter, and identifies the
  minimum pure surface that could in principle compile to other
  Gleam targets. Adds a coding-standards rule to `CONTRIBUTING.md`
  asking pull requests to preserve the boundary. (#344)

## [0.32.0] - 2026-04-30

### Changed

- **Unrecognized `text/*` and `application/*` content types now fall
  back to passthrough aliases instead of failing validation.** Real-
  world specs (the GitHub REST OpenAPI is the canonical example)
  routinely declare `text/html`, `application/vnd.github.diff`,
  `application/octocat-stream`, and similar vendor-prefixed media
  types. The parser now folds any unrecognized `text/*` to
  `TextPlain` (raw String body) and any unrecognized `application/*`
  to `ApplicationOctetStream` (raw bytes); other top-level types
  (`image/*`, `audio/*`, `video/*`) still fail with the existing
  unsupported-content-type diagnostic. The original media-type
  string is preserved verbatim in the generated server's
  `Content-Type` response header so the wire-level contract is
  unchanged. (#352)
- **Complex query / header / cookie parameters without an explicit
  `style` now warn instead of erroring.** The OpenAPI 3.x default
  style for query is `form`, which only handles primitives cleanly,
  but real-world specs (the GitHub REST API's `cwes`, `affects`,
  `has`, `fields` parameters all declared as
  `oneOf: [string, array<string>]` with no `style`) routinely omit
  the declaration. The generator now falls back to form-style
  serialization (which round-trips correctly for `oneOf` of
  primitives and shallow objects) and emits a warning prompting
  the spec author to be explicit if true `deepObject` semantics are
  required. Path parameters with complex schemas continue to be a
  hard error for server codegen. (#352)

### Fixed

- **Property and enum names starting with `+`, `-`, or a digit are
  now mapped to valid Gleam identifiers.** GitHub's reaction-count
  schema uses `+1` and `-1` keys; both previously collapsed to a
  bare `1`, colliding with each other and producing
  `DiscussionReactions(1: Int, 1_2: Int, ...)` — invalid Gleam.
  `to_snake_case` and `to_pascal_case` now rewrite a leading `+` /
  `-` to `plus_` / `minus_` (so `+1` → `plus_1`, `-1` → `minus_1`)
  and prepend `n_` / `N` when the result still starts with a digit
  (so `404` → `n_404` for fields and `N404` for variants). (#352)

### Added

- **JSON specs are now parsed via OTP's native `json:decode/3`** instead
  of yamerl, restoring usability on large public OpenAPI documents.
  Routing every input through yamerl was effectively hanging on real-
  world specs — the GitHub REST OpenAPI (~12 MB JSON) was processed in
  >10 minutes before this change and now finishes parse + validate in
  ~4 seconds. Parser dispatch is by file extension: `.json` takes the
  fast path, `.yaml`/`.yml` keeps the existing yamerl path so any spec
  that depends on YAML semantics is unaffected. JSON object key order
  is preserved with custom decoders so codegen output ordering stays
  deterministic. A new public entry point `parser.parse_json_string`
  is available for callers that have JSON content in memory. (#352)
- **Pipeline progress reporter** that emits one `[+elapsed] stage`
  line per phase (read, parse, normalize, resolve, capability check,
  hoist, dedup, validate, render) when the CLI runs `oaspec generate`
  or `oaspec validate`. Large public specs spent enough time in each
  phase that "stuck or working?" was unanswerable; the new reporter
  surfaces real-time stage timing. The pure library API
  (`generate.generate`, `generate.validate_only`,
  `parser.parse_file`) is unchanged; opt in via the new
  `*_with_progress` variants and `progress.from_fn` /
  `progress.stdout_with_elapsed`. (#352)
- **4 OAI-derived test fixtures** (`oss_oai_petstore_expanded.yaml`,
  `oss_oai_petstore_expanded.json`, `oss_oai_webhook_example.yaml`,
  `oss_oai_webhook_example.json`) from the OpenAPI Initiative's
  examples (Apache-2.0, sourced from the `OAI/OpenAPI-Specification`
  repository at tag `3.1.1`). Each fixture is vendored in both YAML
  and JSON to drive new YAML/JSON parser parity tests covering OAS
  3.0 components and OAS 3.1 webhooks.

## [0.31.0] - 2026-04-30

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
