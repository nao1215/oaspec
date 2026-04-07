# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-04-07

### Added

#### CLI
- `gleam_oas generate` command with `--config`, `--mode`, `--output` flags
- `gleam_oas init` command to scaffold `gleam-oas.yaml` config template
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
