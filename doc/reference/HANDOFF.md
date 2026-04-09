# Handoff Notes

This file is intended for cross-LLM continuation. Update it whenever a
meaningful slice of work lands.

## Branch

- `nchika/fix-many-bugs`

## Recent Commits

- `6099b65` `Format validation mode filtering changes`
- `eba31f8` `Underscore unused server route arguments`
- `236ea0d` `Update shellspec for client-only broken spec generation`
- `0b0d273` `Enforce warnings as errors in server integration builds`

## Current Focus

- Make the full-support effort explicit and handoffable.
- Close high-priority server codegen gaps with tests first.
- Keep commits small and logically isolated.

## Important Current Findings

- `PathItem.$ref` parsing already exists in
  `src/oaspec/openapi/parser.gleam`, but `README.md` still lists it as
  unsupported.
- Server cookie parameters are still rejected by validation and emitted as TODO
  placeholders in `src/oaspec/codegen/server.gleam`.
- Structured server parameters and non-JSON server request bodies still need a
  larger request parsing refactor.

## Next Concrete Tasks

1. Add failing tests for server cookie parameter support.
2. Implement cookie parsing in generated server router code.
3. Remove the server-only validation rejection for cookie parameters.
4. Update README support claims to match reality after each slice.

## Verification Commands

Use the repo-local toolchain path when running Gleam directly:

```sh
env PATH="/home/nao/.local/share/mise/installs/gleam/1.15.2:/home/nao/.local/share/mise/installs/erlang/28.4.1/bin:$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH" gleam test
```

For the full local workflow:

```sh
env PATH="$HOME/.local/share/mise/shims:/home/nao/.local/share/mise/installs/gleam/1.15.2:/home/nao/.local/share/mise/installs/erlang/28.4.1/bin:$HOME/.local/bin:$PATH" just all
```

## Constraints

- Tests first for behavior changes.
- English commit messages.
- No Co-Author trailers.
- Keep progress documented so another model can continue from git history plus
  this file.
