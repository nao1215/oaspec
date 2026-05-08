# Configuration

Generated server code is written to `<dir>/<package>` and generated client
code is written to `<dir>/<package>_client`. Both default paths land
inside the same `<dir>`, so a single `gleam build` rooted at `<dir>`
(e.g. when `<dir>` is the project's `src/`) picks up both. The basename
of each output directory must match the package name so imports such as
`import my_api/types` (server) and `import my_api_client/types` (client)
resolve correctly. To split server and client into separate Gleam
projects, set `output.server` and/or `output.client` explicitly.

## Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `input` | yes | - | Path to an OpenAPI 3.x spec in YAML or JSON |
| `package` | no | `api` | Gleam module namespace prefix |
| `mode` | no | `both` | `server`, `client`, or `both` |
| `validate` | no | mode-dependent (`true` for `server` / `both`, `false` for `client`) | Enable guard validation in generated server/client code |
| `output.dir` | no | `./src` | Base output directory (defaults inside `./src` so generated modules drop into the standard Gleam project layout — #568) |
| `output.server` | no | `<dir>/<package>` | Server output path |
| `output.client` | no | `<dir>/<package>_client` | Client output path |
| `include.tags` | no | `[]` | Operation tag allowlist (filter) |
| `include.paths` | no | `[]` | Operation path allowlist (filter, supports `/foo/**` glob) |
| `targets` | no | - | Array of per-target overrides (multi-target codegen) |

## Filtering operations with `include:`

To generate code for a subset of a large spec without modifying the spec
file, set `include.tags` and / or `include.paths`:

```yaml
input: github.yaml
package: github
mode: client
include:
  tags: [issues, repos]
  paths:
    - "/users/{username}"
    - "/repos/**"
```

Both lists are optional; omitting one means there is no constraint on
that axis, and omitting both leaves the filter inactive. An operation is
kept when its tag list intersects `include.tags` or its path matches one
of `include.paths`; the two lists are unioned rather than intersected, so
adding entries to either list widens the result.

Path patterns ending in `/**` match any path that extends the prefix with
a `/<rest>` segment, so `"/repos/**"` matches `/repos/foo` and
`/repos/foo/bar` but does not match the bare `/repos` — list `/repos`
explicitly when you also need it. Other patterns are compared by exact
equality.

## Splitting one spec into multiple packages with `targets:`

`targets:` is an array of per-target overrides. The same input spec is
generated once per entry, each with its own `package`, `output`, and
`include`. The top-level `input`, `mode`, and `validate` are shared
across every target.

```yaml
input: github.yaml
mode: client
targets:
  - package: dco_check/github/issues
    output: { dir: ./src }
    include:
      tags: [issues]
  - package: dco_check/github/repos
    output: { dir: ./src }
    include:
      paths: ["/repos/**"]
```

The example above produces two packages from one `oaspec generate` run,
at `./src/dco_check/github/issues/...` and
`./src/dco_check/github/repos/...`. Callers consume them as
`import dco_check/github/issues/client` and
`import dco_check/github/repos/client`.

Each target must declare its own `package`; there is no fallback default
for multi-target configs because two targets sharing the same default
would overwrite each other. The CLI rejects configs whose targets resolve
to overlapping output directories before writing any file. The `--output`
CLI flag is also rejected with multi-target configs because each target
already declares its own per-package output directory; use per-target
`output:` blocks instead.

## Configuration paths

All path-valued fields — `input`, `output.dir`, `output.server`,
`output.client` — are resolved relative to the current working directory
when `oaspec` runs, not the directory the config file lives in.

A config at the repo root that refers to a sibling spec works with no
prefix:

```text
myproject/
├── oaspec.yaml   # input: openapi.yaml
└── openapi.yaml
```

```sh
cd myproject
oaspec generate --config=oaspec.yaml   # resolves ./openapi.yaml
```

If the config lives in a subdirectory, its `input` must be reachable from
where the command is run, so either use a path relative to that CWD or
keep invoking `oaspec` from the config's own directory:

```text
myproject/
├── api/
│   ├── oaspec.yaml    # input: openapi.yaml
│   └── openapi.yaml
└── (other code)
```

```sh
cd myproject/api
oaspec generate --config=oaspec.yaml   # resolves ./openapi.yaml

# or, from the repo root:
oaspec generate --config=api/oaspec.yaml   # needs input: api/openapi.yaml
```

Output directories (`output.dir`, `output.server`, `output.client`) are
created automatically if they do not exist; existing files in the target
directories are overwritten by the newly generated code.

If the input spec or the config file itself cannot be opened, `oaspec`
exits with a `Config file not found` / `parse_file` diagnostic that
includes the path it attempted to read.

## CLI commands

| Command | Description |
|---------|-------------|
| `oaspec generate` | Generate Gleam code from an OpenAPI specification |
| `oaspec validate` | Validate an OpenAPI specification without generating code |
| `oaspec init` | Create a default `oaspec.yaml` config file |
| `oaspec version` | Print the installed `oaspec` version (also available as `--version`) |

### CLI options for `init`

| Flag | Default | Description |
|------|---------|-------------|
| `--output=<path>` | `./oaspec.yaml` | Output path for the generated config file |

### CLI options for `generate`

| Flag | Default | Description |
|------|---------|-------------|
| `--config=<path>` | `./oaspec.yaml` | Path to config file |
| `--mode=<mode>` | `both` | `server`, `client`, or `both` (overrides config) |
| `--output=<path>` | - | Override output base directory |
| `--check` | `false` | Check that generated code matches existing files without writing |
| `--fail-on-warnings` | `false` | Treat warnings as errors |
| `--validate` | `false` | Force-enable guard validation in generated server/client code. One-way override — passing this flag turns validation on, but it cannot turn it off. To disable validation when the config sets `validate: true` (the default for `server` / `both` modes), edit `validate: false` in `oaspec.yaml`. |

### CLI options for `validate`

| Flag | Default | Description |
|------|---------|-------------|
| `--config=<path>` | `./oaspec.yaml` | Path to config file |
| `--mode=<mode>` | `both` | `server`, `client`, or `both` (overrides config) |

## Validate

Check a spec for unsupported patterns without generating code:

```sh
oaspec validate --config=oaspec.yaml
```

## Guard validation

By default, generated code does not validate request bodies at runtime.
Enable `validate` in the config file or pass `--validate` to `generate`
to add schema-constraint checks:

```yaml
validate: true
```

```sh
oaspec generate --config=oaspec.yaml --validate
```

When enabled, generated routers validate request bodies against schema
constraints and return 422 on failure. Generated clients validate request
bodies before sending.

The 422 response body is a JSON array of `ValidationFailure` objects with
the violating field, the JSON Schema keyword that failed, and a
human-readable message:

```json
[
  {"field": "name", "code": "minLength", "message": "must be at least 1 character"},
  {"field": "age", "code": "maximum", "message": "must be at most 150"}
]
```

Generated clients surface the same failures via
`ClientError.ValidationError(errors: List(guards.ValidationFailure))`.

## CI integration

Use `--check` and `--fail-on-warnings` to verify generated code stays in
sync:

```sh
# Fail if generated code would differ from what's committed
oaspec generate --config=oaspec.yaml --check --fail-on-warnings
```
