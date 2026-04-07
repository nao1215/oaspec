# Contributing Guide

## Introduction

Thank you for considering contributing to the gleam-oas project! This document explains how to contribute. We welcome all forms of contributions, including code contributions, documentation improvements, bug reports, and feature suggestions.

## Setting Up Development Environment

### Prerequisites

- [Gleam](https://gleam.run/) 1.15 or later
- [Erlang/OTP](https://www.erlang.org/) 27 or later
- [rebar3](https://rebar3.org/) (required for yamerl YAML parser)
- [just](https://just.systems/) (task runner)
- [mise](https://mise.jdx.dev/) (recommended for managing Gleam and Erlang versions)
- [ShellSpec](https://shellspec.info/) (for CLI integration tests)

### Cloning the Project

```bash
git clone https://github.com/nao1215/gleam-oas.git
cd gleam-oas
```

### Installing Tools

```bash
mise install       # install Gleam, Erlang, rebar3
gleam deps download
```

### Verification

```bash
just ci
```

## Development Workflow

### Branch Strategy

- `main` branch is the latest stable version
- Create new branches from `main` for new features or bug fixes
- Branch naming examples:
  - `feature/support-allof-merging` -- New feature
  - `fix/issue-123` -- Bug fix
  - `docs/update-readme` -- Documentation update

### Coding Standards

This project follows these standards:

1. **Follow the [Gleam language guide](https://gleam.run/)**
2. **Generated code must compile** -- always run `just integration` after changing code generation logic
3. **Strong typing over flexibility** -- use custom types, not generic maps
4. **Separate concerns** -- types, decoding, transport, and business logic in separate modules
5. **Add doc comments to all public functions and types**
6. **No runtime reflection** -- compile-time safety is prioritized

### Writing Tests

Tests are organized in three layers:

| Layer | Tool | Location | What to test |
|-------|------|----------|-------------|
| Unit | gleeunit | `test/` | Parser, naming, config, resolver |
| CLI | ShellSpec | `spec/` | CLI behaviour, file generation, content verification |
| Integration | gleeunit | `integration_test/` | Generated code compiles, types/decoders/encoders/handlers/middleware work |

```bash
just test         # unit tests only
just shellspec    # CLI integration tests
just integration  # generated code compile + roundtrip tests
just check        # format check, typecheck, build, unit tests
```

### Modifying Code Generation

When changing how code is generated:

1. Make your changes in `src/gleam_oas/codegen/`
2. Run `just check` to verify the generator compiles
3. Run `just shellspec` to verify generated file structure and content
4. Run `just integration` to verify generated code compiles and works correctly
5. Update ShellSpec expectations in `spec/generate_spec.sh` if output format changed

### Adding OpenAPI Feature Support

When adding support for a new OpenAPI feature:

1. Add types to `src/gleam_oas/openapi/spec.gleam` or `schema.gleam`
2. Add parsing logic in `src/gleam_oas/openapi/parser.gleam`
3. Add resolution logic in `src/gleam_oas/openapi/resolver.gleam` if needed
4. Update code generation in the relevant `src/gleam_oas/codegen/` module
5. Add a test case to the petstore fixture (`test/fixtures/petstore.yaml`)
6. Add unit tests, ShellSpec checks, and integration tests

## Using AI Assistants (LLMs)

We actively encourage the use of AI coding assistants to improve productivity and code quality. Tools like Claude Code, GitHub Copilot, and Cursor are welcome for:

- Writing boilerplate code
- Generating comprehensive test cases
- Improving documentation
- Refactoring existing code

### Guidelines for AI-Assisted Development

1. **Review all generated code**: Always review and understand AI-generated code before committing
2. **Maintain consistency**: Ensure AI-generated code follows the coding standards described in this document and the project's conventions
3. **Test thoroughly**: AI-generated code must pass `just ci`

## Creating Pull Requests

### Preparation

1. **Check or Create Issues**
   - Check if there are existing issues
   - For major changes, discuss the approach in an issue first

2. **Write Tests**
   - Always add tests for new features
   - For bug fixes, create tests that reproduce the bug

3. **Quality Check**
   ```bash
   just check
   just shellspec
   just integration
   ```

### Submitting Pull Request

1. Create a Pull Request from your forked repository to the main repository
2. PR title should briefly describe the changes
3. Include the following in PR description:
   - Purpose and content of changes
   - Related issue number (if any)
   - Test method

### About CI/CD

GitHub Actions automatically checks the following items:

- **Format check**: `gleam format --check`
- **Lint**: `gleam build --warnings-as-errors`
- **Build**: `gleam build`
- **Unit tests**: `gleam test`
- **ShellSpec**: CLI integration tests
- **Integration**: Generated code compilation and roundtrip tests

Merging is not possible unless all checks pass.

## Bug Reports

When you find a bug, please create an issue with the following information:

1. **Environment Information**
   - OS and version
   - Gleam version
   - Erlang/OTP version
   - gleam-oas version

2. **Reproduction Steps**
   - Minimal OpenAPI spec that triggers the bug
   - Config file used
   - Command executed

3. **Expected and Actual Behavior**

4. **Error Messages or Generated Code** (if applicable)

## Contributing Outside of Coding

The following activities are also greatly welcomed:

- **Give a GitHub Star**: Show your interest in the project
- **Promote the Project**: Introduce it in blogs, social media, study groups, etc.
- **Become a GitHub Sponsor**: Support available at [https://github.com/sponsors/nao1215](https://github.com/sponsors/nao1215)
- **Documentation Improvements**: Fix typos, improve clarity of explanations
- **Feature Suggestions**: Share new OpenAPI feature support ideas in issues

## License

Contributions to this project are considered to be released under the project's license (MIT License).

---

Thank you again for considering contributing! We sincerely look forward to your participation.
