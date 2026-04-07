# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-04-07

### Added

- CLI tool: `gleam-oas generate` with `--config`, `--mode`, `--output` options
- Config file support (`gleam-oas.yaml`) with input, output, and package settings
- OpenAPI 3.x YAML and JSON parsing via yay
- Component schema parsing: string, integer, number, boolean, array, object
- Composition keywords: allOf (property merging), oneOf, anyOf
- Enum support with discriminated union generation
- Nullable fields mapped to `Option(T)`
- `$ref` resolution for component schemas
- Discriminator support for oneOf/anyOf
- Parameter parsing: path, query, header, cookie
- Request body and response parsing with media type support
- Type generation: custom types for every schema, request types, response types
- Response types with operation-prefixed status code variants
- JSON decoder generation using `gleam/dynamic/decode` pipeline API
- JSON encoder generation using `gleam/json`
- Reusable `_decoder()` functions for `$ref` schema composition
- Server handler stub generation with TODO placeholders
- Server router generation with HTTP method and path pattern matching
- Client SDK generation with configurable HTTP transport
- Client functions with path parameter substitution and body support
- Composable middleware system: `Handler`, `Middleware` types
- Built-in middleware: `identity`, `compose`, `apply`, `logging`, `retry`
- OpenAPI description propagation as Gleam doc comments
- Auto-generation header in every generated file
- ShellSpec CLI integration tests (39 tests)
- Integration tests: generated code compilation, type construction, JSON roundtrip, handler invocation, middleware chain (35 tests)
- Unit tests: parser, naming, config, resolver (15 tests)
- GitHub Actions: CI (format, lint, build, test), integration (ShellSpec + compile roundtrip)
- Petstore sample OpenAPI spec as test fixture
