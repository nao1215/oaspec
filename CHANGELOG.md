# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
