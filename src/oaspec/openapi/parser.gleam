import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import oaspec/internal/openapi/external_loader
import oaspec/internal/openapi/external_loader_planner
import oaspec/internal/openapi/location_index.{type LocationIndex}
import oaspec/internal/openapi/parser_schema
import oaspec/internal/openapi/parser_value
import oaspec/internal/openapi/parser_yay_error
import oaspec/internal/openapi/schema.{type SchemaRef}
import oaspec/internal/openapi/spec.{
  type Callback, type Components, type Contact, type Encoding, type ExternalDoc,
  type Header, type Info, type License, type Link, type MediaType,
  type OpenApiSpec, type Operation, type Parameter, type ParameterIn,
  type PathItem, type RefOr, type RequestBody, type Response,
  type SecurityRequirement, type Server, type ServerVariable, type Tag,
  type Unresolved, Callback, Components, Contact, Encoding, ExternalDoc, Header,
  Info, License, Link, MediaType, OpenApiSpec, Operation, Parameter, PathItem,
  Ref, RequestBody, Response, SecurityRequirement, Server, ServerVariable, Tag,
  Value,
}
import oaspec/internal/progress.{type Reporter}
import oaspec/internal/util/http
import oaspec/openapi/diagnostic.{type Diagnostic, NoSourceLoc, SourceLoc}
import simplifile
import yay

/// Parse an OpenAPI spec from a file path.
/// Supports both YAML (.yaml, .yml) and JSON (.json) files.
/// After parsing, resolves relative-file `$ref` values across schemas,
/// parameters, request bodies, responses, and path items — including
/// nested object/array properties and composition branches — by loading
/// the referenced files from disk and merging their definitions into the
/// main spec. Cyclic external ref graphs (`A.yaml → B.yaml → A.yaml`)
/// fail fast with a dedicated diagnostic. HTTP/HTTPS URLs are not
/// followed.
pub fn parse_file(path: String) -> Result(OpenApiSpec(Unresolved), Diagnostic) {
  parse_file_internal(path, [], progress.noop())
  |> result.map(fn(pair) { pair.0 })
}

/// Combined `parse_file` entry point that accepts a `Reporter` and
/// also returns the top-level YAML `LocationIndex`. Issue #411 +
/// #352. The CLI uses this so capability-check diagnostics surface
/// `path:line:column:` and progress lines on big specs at the same
/// time. Library callers that don't need progress should pass
/// `progress.noop()`; callers that don't need locations can discard
/// the second tuple element.
pub fn parse_file_with_progress_and_locations(
  path: String,
  reporter: Reporter,
) -> Result(#(OpenApiSpec(Unresolved), LocationIndex), Diagnostic) {
  parse_file_internal(path, [], reporter)
}

/// Internal parse entry that threads the `visited` stack through every
/// external-ref recursion so `A.yaml -> B.yaml -> A.yaml` cycles fail
/// fast with a dedicated diagnostic instead of spinning forever.
///
/// Returns both the parsed spec and the YAML `LocationIndex` built from
/// the file's content. Recursive external-ref resolution discards
/// nested files' indices — only the top-level file's index is surfaced
/// (capability-check needs *one* canonical index, and external refs
/// land back at their `$ref` site in the main file anyway).
fn parse_file_internal(
  path: String,
  visited: List(String),
  reporter: Reporter,
) -> Result(#(OpenApiSpec(Unresolved), LocationIndex), Diagnostic) {
  let canonical = canonicalize_ref_path(path)
  use <- bool.guard(
    list.contains(visited, canonical),
    Error(cyclic_external_ref_diagnostic(canonical, visited)),
  )

  let #(elapsed, read_result) = progress.timed(fn() { simplifile.read(path) })
  use content <- result.try(
    read_result
    |> result.map_error(fn(err) {
      diagnostic.file_error(
        detail: "Cannot read file: "
        <> path
        <> " ("
        <> simplifile.describe_error(err)
        <> ")",
      )
    }),
  )
  progress.report(
    reporter,
    "read "
      <> path
      <> " ("
      <> format_size(string.byte_size(content))
      <> ", took "
      <> progress.format_ms(elapsed)
      <> ")",
  )

  let is_json = looks_like_json_path(path)
  let #(elapsed, parsed) =
    progress.timed(fn() {
      case is_json {
        True -> parse_json_string_with_locations(content)
        False -> parse_string_with_locations(content)
      }
    })
  progress.report(reporter, case is_json {
    True ->
      "parse JSON document via OTP json (took "
      <> progress.format_ms(elapsed)
      <> ")"
    False ->
      "parse YAML document via yamerl (took "
      <> progress.format_ms(elapsed)
      <> ")"
  })
  use #(spec, index) <- result.try(parsed)
  let new_visited = [canonical, ..visited]
  let #(elapsed, resolved) =
    progress.timed(fn() {
      external_loader.resolve_external_component_refs(
        spec,
        external_loader_planner.base_dir_of(path),
        fn(sub_path) {
          parse_file_internal(sub_path, new_visited, reporter)
          |> result.map(fn(pair) { pair.0 })
        },
      )
    })
  progress.report(
    reporter,
    "resolve relative-file $ref components (took "
      <> progress.format_ms(elapsed)
      <> ")",
  )
  resolved
  |> result.map(fn(s) { #(s, index) })
}

fn format_size(bytes: Int) -> String {
  case bytes < 1024 {
    True -> int.to_string(bytes) <> " B"
    False ->
      case bytes < 1024 * 1024 {
        True -> int.to_string(bytes / 1024) <> " KiB"
        False -> int.to_string(bytes / { 1024 * 1024 }) <> " MiB"
      }
  }
}

/// Normalize a path string for cycle detection. This is not a full
/// canonicalization (no symlink resolution, no realpath call); it just
/// collapses the `./` and duplicate-slash noise that `filepath.join`
/// can leave behind so the same file reached via two equivalent
/// relative paths compares equal.
fn canonicalize_ref_path(path: String) -> String {
  let segments =
    path
    |> string.split("/")
    |> list.filter(fn(seg) { seg != "" && seg != "." })
  case string.starts_with(path, "/") {
    True -> "/" <> string.join(segments, "/")
    False -> string.join(segments, "/")
  }
}

fn cyclic_external_ref_diagnostic(
  current: String,
  visited: List(String),
) -> Diagnostic {
  let chain = list.reverse([current, ..visited])
  diagnostic.invalid_value(
    path: "external_ref",
    detail: "Cyclic external $ref graph detected: "
      <> string.join(chain, " -> ")
      <> ". oaspec requires external ref graphs to be acyclic.",
    loc: NoSourceLoc,
  )
}

/// Configuration for `parse_string_with_limits`.
///
/// Each field caps a parser-side resource that an attacker-controlled
/// or accidentally-pathological spec could exhaust. The defaults
/// returned by `default_limits` are sized for real-world specs
/// (Stripe / GitHub / AsyncAPI all fit comfortably) and are tight
/// enough that a CI runner targeting an attacker-supplied spec is
/// not a denial-of-service surface.
///
/// Currently enforced:
///
/// - `max_input_bytes`: the size of `content` in bytes. Checked
///   before any parser work begins, so a 100 MB pathological input
///   is rejected before yamerl or `json:decode/3` allocates a tree.
///
/// Documented but **not yet enforced** (future work — issue #553
/// tracks the rest):
///
/// - `max_schema_depth`, `max_allof_chain`, `max_external_ref_hops`,
///   `max_paths`, `max_parameters_per_op`. Constructing these limits
///   in the type today lets callers pin the contract; the parser
///   will start enforcing them in follow-up PRs.
pub type ParseLimits {
  ParseLimits(
    max_input_bytes: Int,
    max_schema_depth: Int,
    max_allof_chain: Int,
    max_external_ref_hops: Int,
    max_paths: Int,
    max_parameters_per_op: Int,
  )
}

/// Project-default limits sized for real-world specs.
///
/// - `max_input_bytes`: 16 MiB — Stripe's full OpenAPI is ~6 MB,
///   GitHub's REST API is ~12 MB; 16 MiB clears both with headroom.
/// - `max_schema_depth`: 100. Real specs rarely nest beyond ~12.
/// - `max_allof_chain`: 32.
/// - `max_external_ref_hops`: 16.
/// - `max_paths`: 4096. Stripe (~1k operations), GitHub (~1k), and
///   AsyncAPI (~50) all fit comfortably.
/// - `max_parameters_per_op`: 64. The largest real-world operation
///   the audit found has ~20 parameters.
pub fn default_limits() -> ParseLimits {
  ParseLimits(
    max_input_bytes: 16 * 1024 * 1024,
    max_schema_depth: 100,
    max_allof_chain: 32,
    max_external_ref_hops: 16,
    max_paths: 4096,
    max_parameters_per_op: 64,
  )
}

/// Parse an OpenAPI spec from a YAML/JSON string. The default path
/// runs the input through yamerl, which preserves YAML semantics and
/// source locations but is too slow on large JSON specs (the GitHub
/// REST OpenAPI is ~12 MB and yamerl effectively hangs — see issue
/// #352). Use `parse_json_string` directly when the content is known
/// to be JSON.
///
/// `parse_string` does **not** apply the DoS limits documented in
/// `ParseLimits`. Reach for `parse_string_with_limits` when the input
/// is attacker-controlled or sourced from an untrusted file system
/// (admin-uploaded specs, contract-validation pipelines, CI runners
/// over user-supplied specs) — see issue #553.
///
/// **YAML 1.1 type coercion: parse_string vs parse_json_string.**
/// yamerl applies YAML 1.1 implicit-type rules to scalars before they
/// reach metamon's tree walker. The OTP `json:decode/3` frontend used
/// by `parse_json_string` does not. The two parsers therefore diverge
/// on the same JSON bytes whenever a value matches a YAML 1.1
/// implicit-type pattern:
///
/// | JSON literal | `parse_string` (yamerl, YAML 1.1) | `parse_json_string` (OTP) |
/// | --- | --- | --- |
/// | `"version": "Yes"` | bool `True` | string `"Yes"` |
/// | `"role": "No"` | bool `False` | string `"No"` |
/// | `"flag": "On"` / `"Off"` | bool `True` / `False` | string `"On"` / `"Off"` |
/// | `"version": 1.10` | float `1.1` (trailing zero lost) | float `1.10` |
/// | `"hex": 0x10` | int `16` (yamerl extension) | parse error (not valid JSON) |
///
/// For JSON OpenAPI documents — Stripe, GitHub, AsyncAPI, etc. — prefer
/// `parse_json_string` (or `parse_string_or_json_with_locations`,
/// which auto-routes by inspecting the first non-whitespace byte).
/// `parse_string` remains correct for YAML input and for JSON inputs
/// whose values do not collide with YAML 1.1 implicit-type patterns.
pub fn parse_string(
  content: String,
) -> Result(OpenApiSpec(Unresolved), Diagnostic) {
  parse_string_with_locations(content)
  |> result.map(fn(pair) { pair.0 })
}

/// Same as `parse_string` but also returns the YAML `LocationIndex`
/// built from the input. Caller-side companion to
/// `parse_file_with_locations` (Issue #411).
pub fn parse_string_with_locations(
  content: String,
) -> Result(#(OpenApiSpec(Unresolved), LocationIndex), Diagnostic) {
  use #(root, index) <- result.try(parse_to_node(content))
  use spec <- result.map(parse_root(root, index))
  #(spec, index)
}

/// Parse an OpenAPI spec with DoS-aware resource limits. Currently
/// enforces `limits.max_input_bytes` before parsing begins; the other
/// fields on `ParseLimits` are reserved for future enforcement (see
/// issue #553).
///
/// The byte cap is checked via `string.byte_size` so the function
/// returns immediately on oversized input rather than handing it to
/// yamerl / `json:decode/3` (both of which allocate proportional
/// tree memory before the size could be discovered downstream).
///
/// Returns the same `Diagnostic`-bearing `Result` as `parse_string`
/// when the limit is satisfied; returns a structured
/// `parse_limit_exceeded` diagnostic when the limit is exceeded.
pub fn parse_string_with_limits(
  content: String,
  limits: ParseLimits,
) -> Result(OpenApiSpec(Unresolved), Diagnostic) {
  case enforce_input_byte_limit(content, limits) {
    Error(d) -> Error(d)
    Ok(_) -> parse_string(content)
  }
}

fn enforce_input_byte_limit(
  content: String,
  limits: ParseLimits,
) -> Result(Nil, Diagnostic) {
  let actual = string.byte_size(content)
  case actual > limits.max_input_bytes {
    False -> Ok(Nil)
    True ->
      Error(diagnostic.parse_limit_exceeded(
        limit: "max_input_bytes",
        configured: limits.max_input_bytes,
        actual: actual,
      ))
  }
}

/// Parse an OpenAPI spec from a JSON string using OTP's native JSON
/// decoder instead of yamerl. Roughly two orders of magnitude faster
/// than `parse_string` on large specs because the YAML pre-processing
/// and constructor passes are skipped (issue #352). Behaves like
/// `parse_string` once the tree is built — same `OpenApiSpec` shape,
/// same downstream pipeline. Diagnostics from this path do not carry
/// source line/column info because OTP `json:decode/3` does not
/// expose decoder positions; the caller still gets the path-prefixed
/// error message that downstream tooling relies on.
pub fn parse_json_string(
  content: String,
) -> Result(OpenApiSpec(Unresolved), Diagnostic) {
  parse_json_string_with_locations(content)
  |> result.map(fn(pair) { pair.0 })
}

/// JSON variant of `parse_string_with_locations`.
///
/// OTP's `json:decode/3` does not expose token positions, so the
/// returned `LocationIndex` is **always empty** (`location_index.empty()`).
/// Capability-check diagnostics from a JSON-only spec therefore carry
/// `NoSourceLoc`, while diagnostics from the YAML path can carry
/// line/column info via the index. Downstream tooling that wants to
/// dispatch over both formats with one signature should reach for
/// `parse_string_or_json_with_locations`, which inspects the first
/// non-whitespace byte to pick between the two parsers.
///
/// Returning the empty index instead of an `Option(LocationIndex)` keeps
/// the type identical to `parse_string_with_locations`, so callers do
/// not need a separate code path — they only lose location-aware
/// diagnostics on the JSON branch.
pub fn parse_json_string_with_locations(
  content: String,
) -> Result(#(OpenApiSpec(Unresolved), LocationIndex), Diagnostic) {
  use root <- result.try(decode_json_to_node(content))
  use spec <- result.map(parse_root(root, location_index.empty()))
  #(spec, location_index.empty())
}

/// Auto-dispatch over `parse_string_with_locations` (YAML) and
/// `parse_json_string_with_locations` (JSON) based on the first
/// non-whitespace byte of `content`.
///
/// `{` and `[` route to the JSON parser (orders of magnitude faster on
/// large specs — see `parse_json_string`); anything else routes to
/// the YAML parser. The dispatch covers the conventional OpenAPI
/// document shapes (object root for full specs, array root for the
/// rare top-level component lists). Whitespace prefixes (BOM, leading
/// spaces, blank lines) are skipped before the discriminator byte
/// is inspected.
///
/// Use this when downstream tooling needs a single entry point for
/// both formats — LSP-style features, error-hint generators,
/// source-map producers — without writing the dispatch wrapper at
/// every call site.
pub fn parse_string_or_json_with_locations(
  content: String,
) -> Result(#(OpenApiSpec(Unresolved), LocationIndex), Diagnostic) {
  case looks_like_json(content) {
    True -> parse_json_string_with_locations(content)
    False -> parse_string_with_locations(content)
  }
}

fn looks_like_json(content: String) -> Bool {
  case string.trim_start(content) {
    "{" <> _ -> True
    "[" <> _ -> True
    _ -> False
  }
}

/// Run yamerl on `content` and return the root node plus a
/// location index built from the same content. Both pieces are
/// consumed by `parse_root` to produce the OpenApiSpec.
@external(erlang, "oaspec_yaml_safe_ffi", "parse_string")
fn ffi_parse_yaml_safe(
  content: String,
) -> Result(List(yay.Document), yay.YamlError)

fn parse_to_node(
  content: String,
) -> Result(#(yay.Node, LocationIndex), Diagnostic) {
  use docs <- result.try(
    // `oaspec_yaml_safe_ffi.parse_string` is a thin adapter over
    // `yay:parse_string/1` that normalises yay v2.0.x's raw
    // `{yaml_error, Msg, {Line, Col}}` FFI tuple into the Gleam
    // encoding `yay.YamlError` is documented to carry. Calling
    // `yay.parse_string` directly here would crash the BEAM with a
    // `case_clause` for any input that triggers the alias /
    // anchor resolution path (Issue #576) — a one-line malformed
    // YAML payload can DoS a server-side spec validator. The
    // adapter is local to this module; the rest of the parser
    // keeps consuming the documented `yay.YamlError` surface.
    ffi_parse_yaml_safe(content)
    |> result.map_error(fn(e) {
      case e {
        yay.ParsingError(msg:, loc:) ->
          diagnostic.yaml_error(
            detail: msg,
            loc: SourceLoc(line: loc.line, column: loc.column),
          )
        yay.UnexpectedParsingError ->
          diagnostic.yaml_error(
            detail: "Unexpected parsing error",
            loc: NoSourceLoc,
          )
      }
    }),
  )

  use doc <- result.try(case docs {
    [first, ..] -> Ok(first)
    [] ->
      Error(diagnostic.yaml_error(detail: "Empty document", loc: NoSourceLoc))
  })

  let root = yay.document_root(doc)
  let index = location_index.build(content)
  Ok(#(root, index))
}

@external(erlang, "oaspec_json_ffi", "parse_string")
fn ffi_parse_json(content: String) -> Result(List(yay.Document), yay.YamlError)

/// Decode a JSON string into a yay.Node via the OTP `json` module.
/// Wraps the FFI's `Result(List(Document), YamlError)` shape into a
/// `Diagnostic` so it lines up with `parse_to_node`'s contract.
fn decode_json_to_node(content: String) -> Result(yay.Node, Diagnostic) {
  use docs <- result.try(
    ffi_parse_json(content)
    |> result.map_error(fn(e) {
      case e {
        yay.ParsingError(msg:, loc:) ->
          diagnostic.yaml_error(detail: msg, loc: case loc.line, loc.column {
            0, 0 -> NoSourceLoc
            _, _ -> SourceLoc(line: loc.line, column: loc.column)
          })
        yay.UnexpectedParsingError ->
          diagnostic.yaml_error(
            detail: "Unexpected JSON parsing error",
            loc: NoSourceLoc,
          )
      }
    }),
  )

  case docs {
    [first, ..] -> Ok(yay.document_root(first))
    [] ->
      Error(diagnostic.yaml_error(detail: "Empty document", loc: NoSourceLoc))
  }
}

fn looks_like_json_path(path: String) -> Bool {
  let lower = string.lowercase(path)
  string.ends_with(lower, ".json")
}

/// Parse the root OpenAPI object.
fn parse_root(
  node: yay.Node,
  index: LocationIndex,
) -> Result(OpenApiSpec(Unresolved), Diagnostic) {
  use openapi <- result.try(extract_openapi_field(node, index))

  use _ <- result.try(validate_openapi_version(
    openapi,
    location_index.lookup_field(index, "", "openapi"),
  ))

  use info <- result.try(parse_info(node, index))

  // OAS 3.0 marks `paths` as required at the document root; OAS 3.1
  // makes it optional (the spec may consist of `webhooks` /
  // `components` only). Enforce the 3.0 contract here so the
  // `validate` subcommand and downstream codegen do not silently
  // accept a 3.0 document with no operations. Run after `parse_info`
  // so a spec missing both reports the info-missing error first
  // (matches existing diagnostic priority). (#580 case A)
  use _ <- result.try(case is_openapi_3_0(openapi) {
    True -> require_paths_present(node, index)
    False -> Ok(Nil)
  })

  // Parse components FIRST so we can resolve $ref during path parsing.
  // Components section is optional, but if present it must parse correctly.
  use components <- result.try(parse_optional_components(node, index))

  use paths <- result.try(parse_paths(node, components, index))
  use servers <- result.try(parse_servers(node, index))
  use security <- result.try(parse_security_requirements(node, "", index))
  use webhooks <- result.try(parse_webhooks(node, components, index))
  let tags = parse_tags(node)
  let external_docs = parse_optional_external_docs(node)
  let json_schema_dialect =
    parser_value.optional_string(node, "jsonSchemaDialect")

  Ok(OpenApiSpec(
    openapi:,
    info:,
    paths:,
    components:,
    servers:,
    security:,
    webhooks:,
    tags:,
    external_docs:,
    json_schema_dialect:,
  ))
}

/// Reject spec files whose `openapi` field is not in the supported 3.0.x /
/// 3.1.x range. OpenAPI 3.x is what oaspec claims to generate from, so
/// accepting 2.0 or 4.0.0 would let users feed specs that are either
/// subtly or grossly incompatible with the generator.
fn validate_openapi_version(
  version: String,
  loc: diagnostic.SourceLoc,
) -> Result(Nil, Diagnostic) {
  use <- bool.guard(is_supported_openapi_version(version), Ok(Nil))
  Error(diagnostic.invalid_value(
    path: "openapi",
    detail: "Unsupported OpenAPI version: '"
      <> version
      <> "'. oaspec only supports OpenAPI 3.0.x and 3.1.x.",
    loc: loc,
  ))
}

fn is_supported_openapi_version(version: String) -> Bool {
  case string.split(version, ".") {
    // Three-segment form: major.minor.patch. The patch must be a
    // non-negative integer — `3.0.foo`, `3.0.-1`, and `3.0.0.1` must all
    // fail so the "exact accepted range" guarantee holds.
    ["3", "0", patch] | ["3", "1", patch] ->
      case int.parse(patch) {
        Ok(n) if n >= 0 -> True
        _ -> False
      }
    // Two-segment "3.0" / "3.1" is tolerated for authors who quote the
    // short form intentionally (`openapi: '3.0'`). The unquoted YAML
    // float path that this branch originally served was removed in #583.
    ["3", "0"] | ["3", "1"] -> True
    _ -> False
  }
}

/// Extract the root `openapi` field. The OAS 3.0 / 3.1 schema requires
/// this field to be a string, and both parsers enforce that contract
/// uniformly. The YAML caller used to fall back to `extract_float` so
/// an unquoted `openapi: 3.0` (which yamerl resolves as a float) would
/// coerce back to `"3.0"`; that lenient path was the YAML-side of the
/// #580 asymmetry and #583 closes it. Authors who relied on unquoted
/// version numbers must quote them (`openapi: '3.0'`).
fn extract_openapi_field(
  node: yay.Node,
  index: LocationIndex,
) -> Result(String, Diagnostic) {
  let loc = location_index.lookup_field(index, "", "openapi")
  yay.extract_string(node, "openapi")
  |> result.map_error(parser_yay_error.missing_field_from_extraction(
    _,
    path: "",
    field: "openapi",
    loc: loc,
  ))
}

/// Mirror of yay's private `node_type_name` for the diagnostic
/// detail line. Kept local because yay does not export the helper
/// and the alternative (re-pattern-matching at every call site) is
/// noisier than a four-line wrapper.
fn node_kind_name(node: yay.Node) -> String {
  case node {
    yay.NodeNil -> "nil"
    yay.NodeStr(_) -> "string"
    yay.NodeBool(_) -> "bool"
    yay.NodeInt(_) -> "int"
    yay.NodeFloat(_) -> "float"
    yay.NodeSeq(_) -> "list"
    yay.NodeMap(_) -> "map"
  }
}

/// Whether the validated version string belongs to the OAS 3.0.x
/// branch (where `paths` is required at the document root). Accepts
/// both the three-segment `3.0.x` form and the two-segment `3.0`
/// form that `is_supported_openapi_version` tolerates for
/// yamerl-coerced floats.
fn is_openapi_3_0(version: String) -> Bool {
  case string.split(version, ".") {
    ["3", "0", _] | ["3", "0"] -> True
    _ -> False
  }
}

/// Verify the `paths` field exists at the document root. Used only
/// for OAS 3.0; `parse_paths` itself stays lenient on the missing
/// case so 3.1 documents continue to parse without `paths`.
fn require_paths_present(
  root: yay.Node,
  index: LocationIndex,
) -> Result(Nil, Diagnostic) {
  case yay.select_sugar(from: root, selector: "paths") {
    Ok(_) -> Ok(Nil)
    Error(_) ->
      Error(diagnostic.missing_field(
        path: "",
        field: "paths",
        loc: location_index.lookup_field(index, "", "paths"),
      ))
  }
}

/// Parse optional components section.
/// Returns Ok(None) if not present, Ok(Some(..)) if valid, Error if malformed.
fn parse_optional_components(
  root: yay.Node,
  index: LocationIndex,
) -> Result(Option(Components(Unresolved)), Diagnostic) {
  let present =
    result.is_ok(yay.select_sugar(from: root, selector: "components"))
  use <- bool.guard(!present, Ok(None))
  use comps <- result.try(parse_components(root, index))
  Ok(Some(comps))
}

/// Parse the info object.
fn parse_info(root: yay.Node, index: LocationIndex) -> Result(Info, Diagnostic) {
  use info_node <- result.try(
    yay.select_sugar(from: root, selector: "info")
    |> result.map_error(parser_yay_error.missing_field_from_selector(
      _,
      path: "",
      field: "info",
      loc: location_index.lookup_field(index, "", "info"),
    )),
  )

  use title <- result.try(
    yay.extract_string(info_node, "title")
    |> result.map_error(parser_yay_error.missing_field_from_extraction(
      _,
      path: "info",
      field: "title",
      loc: location_index.lookup_field(index, "info", "title"),
    )),
  )

  use version <- result.try(
    yay.extract_string(info_node, "version")
    |> result.map_error(parser_yay_error.missing_field_from_extraction(
      _,
      path: "info",
      field: "version",
      loc: location_index.lookup_field(index, "info", "version"),
    )),
  )

  let description = parser_value.optional_string(info_node, "description")

  let summary = parser_value.optional_string(info_node, "summary")

  let terms_of_service =
    parser_value.optional_string(info_node, "termsOfService")

  let contact = parse_optional_contact(info_node)
  let license = parse_optional_license(info_node)

  Ok(Info(
    title:,
    description:,
    version:,
    summary:,
    terms_of_service:,
    contact:,
    license:,
  ))
}

/// Parse servers array.
fn parse_servers(
  root: yay.Node,
  index: LocationIndex,
) -> Result(List(Server), Diagnostic) {
  case yay.select_sugar(from: root, selector: "servers") {
    Ok(yay.NodeSeq(items)) ->
      list.try_map(items, fn(item) { parse_server(item, index) })
    _ -> Ok([])
  }
}

/// Parse a single server object.
fn parse_server(
  node: yay.Node,
  index: LocationIndex,
) -> Result(Server, Diagnostic) {
  use url <- result.try(
    yay.extract_string(node, "url")
    |> result.map_error(parser_yay_error.missing_field_from_extraction(
      _,
      path: "servers",
      field: "url",
      loc: location_index.lookup_field(index, "servers", "url"),
    )),
  )

  let description = parser_value.optional_string(node, "description")

  let variables = parse_server_variables(node)

  Ok(Server(url:, description:, variables:))
}

/// Parse the paths object.
fn parse_paths(
  root: yay.Node,
  components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(Dict(String, RefOr(PathItem(Unresolved))), Diagnostic) {
  case yay.select_sugar(from: root, selector: "paths") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(path) ->
            case string.starts_with(path, "x-") {
              True -> Ok(acc)
              False -> {
                use _ <- result.try(validate_path_template_key(path, index))
                // Check for $ref first — resolve from components.pathItems
                use ref_or_path_item <- result.try(
                  case parser_value.optional_string(value_node, "$ref") {
                    Some(ref_str) -> Ok(Ref(ref_str))
                    None -> {
                      use pi <- result.try(parse_path_item(
                        value_node,
                        path,
                        components,
                        index,
                      ))
                      Ok(Value(pi))
                    }
                  },
                )
                Ok(dict.insert(acc, path, ref_or_path_item))
              }
            }
          _ -> Ok(acc)
        }
      })
    }
    // `paths` is present but not a map. The OAS 3.0 / 3.1 schema
    // marks Paths Object as `"type": "object"`, so a list / scalar /
    // null value here is a spec violation. Reject loudly so the
    // `validate` subcommand and downstream codegen do not silently
    // produce empty output. (#580 case C)
    Ok(other) ->
      Error(diagnostic.invalid_value(
        path: "paths",
        detail: "paths must be a Paths Object (map), got "
          <> node_kind_name(other),
        loc: location_index.lookup_field(index, "", "paths"),
      ))
    // `paths` is absent. Stay lenient here: the 3.0-required check is
    // enforced earlier in `parse_root` via `require_paths_present`,
    // and 3.1 documents may legitimately omit `paths`.
    _ -> Ok(dict.new())
  }
}

/// Validate that a `paths:` key conforms to the OAS 3.0 §4.7.9.1 path
/// templating grammar. The parser used to forward any string to the
/// codegen pipeline, which then emitted routes the HTTP layer cannot
/// serve (no leading slash, embedded `?` / `#`, whitespace, malformed
/// `{var}` placeholders, ...). The checks here cover the deviations
/// listed in #588:
///
/// - non-empty,
/// - starts with `/`,
/// - no consecutive `//`,
/// - no `?` (query) or `#` (fragment),
/// - no unencoded whitespace (the OAS path grammar inherits URL path
///   character rules and excludes space / tab in the literal segment),
/// - balanced `{` / `}` with each placeholder matching `[A-Za-z0-9_-]+`,
/// - each placeholder name unique within the path.
fn validate_path_template_key(
  path: String,
  index: LocationIndex,
) -> Result(Nil, Diagnostic) {
  let reject = fn(detail: String) -> Result(Nil, Diagnostic) {
    Error(diagnostic.invalid_value(
      path: "paths",
      detail: "Invalid path key '" <> path <> "': " <> detail,
      loc: location_index.lookup_field(index, "", "paths"),
    ))
  }
  use <- bool.guard(when: path == "", return: reject("must not be empty"))
  use <- bool.guard(
    when: !string.starts_with(path, "/"),
    return: reject("must start with '/'"),
  )
  use <- bool.guard(
    when: string.contains(path, "//"),
    return: reject("must not contain '//'"),
  )
  use <- bool.guard(
    when: string.contains(path, "?"),
    return: reject("must not contain a query string"),
  )
  use <- bool.guard(
    when: string.contains(path, "#"),
    return: reject("must not contain a URL fragment"),
  )
  use <- bool.guard(
    when: string.contains(path, " "),
    return: reject("must not contain spaces"),
  )
  use <- bool.guard(
    when: string.contains(path, "\t"),
    return: reject("must not contain tab characters"),
  )
  validate_path_placeholders(path, reject)
}

/// Errors the placeholder scanner can surface. Kept as an ADT so the
/// caller does not have to inspect raw strings — the user-facing
/// diagnostic detail is rebuilt from the variant in
/// `placeholder_error_detail`.
type PlaceholderError {
  Unclosed
  NestedBrace
  UnmatchedClose
  InvalidName(name: String)
}

/// Walk the path string and verify that every `{...}` placeholder
/// matches `[A-Za-z0-9_-]+` and that no placeholder name repeats.
/// Returns the same `Result(Nil, Diagnostic)` as the caller's
/// `reject` continuation so the diagnostic path / location stays
/// consistent.
fn validate_path_placeholders(
  path: String,
  reject: fn(String) -> Result(Nil, Diagnostic),
) -> Result(Nil, Diagnostic) {
  case extract_placeholder_names(path, "", False, []) {
    Error(err) -> reject(placeholder_error_detail(err))
    Ok(names) ->
      case has_duplicate_name(names, []) {
        Some(dup) ->
          reject("placeholder '{" <> dup <> "}' appears more than once")
        None -> Ok(Nil)
      }
  }
}

fn placeholder_error_detail(err: PlaceholderError) -> String {
  case err {
    Unclosed -> "unclosed '{' placeholder"
    NestedBrace -> "'{' nested inside another placeholder"
    UnmatchedClose -> "'}' without a matching '{'"
    InvalidName(name) ->
      "placeholder name '" <> name <> "' must match [A-Za-z0-9_-]+"
  }
}

fn extract_placeholder_names(
  remaining: String,
  current: String,
  inside: Bool,
  acc: List(String),
) -> Result(List(String), PlaceholderError) {
  case string.pop_grapheme(remaining) {
    Error(Nil) ->
      case inside {
        True -> Error(Unclosed)
        False -> Ok(list.reverse(acc))
      }
    Ok(#("{", rest)) ->
      case inside {
        True -> Error(NestedBrace)
        False -> extract_placeholder_names(rest, "", True, acc)
      }
    Ok(#("}", rest)) ->
      case inside {
        False -> Error(UnmatchedClose)
        True ->
          case is_valid_placeholder_name(current) {
            False -> Error(InvalidName(current))
            True -> extract_placeholder_names(rest, "", False, [current, ..acc])
          }
      }
    Ok(#(ch, rest)) ->
      case inside {
        True -> extract_placeholder_names(rest, current <> ch, True, acc)
        False -> extract_placeholder_names(rest, current, False, acc)
      }
  }
}

fn is_valid_placeholder_name(name: String) -> Bool {
  // nolint: assert_ok_pattern -- the placeholder grammar regex is a fixed, known-valid literal
  let assert Ok(re) = regexp.from_string("^[A-Za-z0-9_-]+$")
  regexp.check(with: re, content: name)
}

fn has_duplicate_name(names: List(String), seen: List(String)) -> Option(String) {
  case names {
    [] -> None
    [head, ..rest] ->
      case list.contains(seen, head) {
        True -> Some(head)
        False -> has_duplicate_name(rest, [head, ..seen])
      }
  }
}

/// Parse a single path item.
fn parse_path_item(
  node: yay.Node,
  path: String,
  components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(PathItem(Unresolved), Diagnostic) {
  let summary = parser_value.optional_string(node, "summary")

  let description = parser_value.optional_string(node, "description")

  // Operations are optional, but if present must parse correctly.
  use get <- result.try(parse_optional_operation(
    node,
    "get",
    path,
    components,
    index,
  ))
  use post <- result.try(parse_optional_operation(
    node,
    "post",
    path,
    components,
    index,
  ))
  use put <- result.try(parse_optional_operation(
    node,
    "put",
    path,
    components,
    index,
  ))
  use delete <- result.try(parse_optional_operation(
    node,
    "delete",
    path,
    components,
    index,
  ))
  use patch <- result.try(parse_optional_operation(
    node,
    "patch",
    path,
    components,
    index,
  ))
  use head <- result.try(parse_optional_operation(
    node,
    "head",
    path,
    components,
    index,
  ))
  use options <- result.try(parse_optional_operation(
    node,
    "options",
    path,
    components,
    index,
  ))
  use trace <- result.try(parse_optional_operation(
    node,
    "trace",
    path,
    components,
    index,
  ))

  use parameters <- result.try(parse_parameters_list(node, components, index))
  use servers <- result.try(parse_servers(node, index))

  Ok(PathItem(
    summary:,
    description:,
    get:,
    post:,
    put:,
    delete:,
    patch:,
    head:,
    options:,
    trace:,
    parameters:,
    servers:,
  ))
}

/// Parse an optional operation: Ok(None) if key absent, Ok(Some(..)) if valid,
/// Error if present but malformed.
fn parse_optional_operation(
  node: yay.Node,
  method_key: String,
  path: String,
  components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(Option(Operation(Unresolved)), Diagnostic) {
  let present = result.is_ok(yay.select_sugar(from: node, selector: method_key))
  use <- bool.guard(!present, Ok(None))
  use op <- result.try(parse_operation_at(
    node,
    method_key,
    path,
    components,
    index,
  ))
  Ok(Some(op))
}

/// Parse an operation at a specific HTTP method key.
fn parse_operation_at(
  node: yay.Node,
  method_key: String,
  path: String,
  components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(Operation(Unresolved), Diagnostic) {
  use op_node <- result.try(
    yay.select_sugar(from: node, selector: method_key)
    |> result.map_error(parser_yay_error.missing_field_from_selector(
      _,
      path:,
      field: method_key,
      loc: location_index.lookup_field(index, path, method_key),
    )),
  )

  parse_operation(op_node, path <> "." <> method_key, components, index)
}

/// Parse a single operation.
fn parse_operation(
  node: yay.Node,
  context: String,
  components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(Operation(Unresolved), Diagnostic) {
  let operation_id = parser_value.optional_string(node, "operationId")

  let summary = parser_value.optional_string(node, "summary")

  let description = parser_value.optional_string(node, "description")

  let tags = case yay.extract_string_list(node, "tags") {
    Ok(t) -> t
    _ -> []
  }

  let deprecated = parser_value.bool_default(node, "deprecated", False)

  use parameters <- result.try(parse_parameters_list(node, components, index))

  // requestBody is optional; absent is Ok(None), present-but-broken is Error.
  use request_body <- result.try(parse_optional_request_body(
    node,
    context,
    components,
    index,
  ))

  // responses is REQUIRED per OpenAPI 3.x
  use responses <- result.try(parse_responses_required(
    node,
    context,
    components,
    index,
  ))

  use security <- result.try(parse_optional_security_requirements(
    node,
    context,
    index,
  ))

  use callbacks <- result.try(parse_callbacks(node, context, components, index))
  use op_servers <- result.try(parse_servers(node, index))
  let external_docs = parse_optional_external_docs(node)

  Ok(Operation(
    operation_id:,
    summary:,
    description:,
    tags:,
    parameters:,
    request_body:,
    responses:,
    deprecated:,
    security:,
    callbacks:,
    servers: op_servers,
    external_docs:,
  ))
}

/// Parse optional requestBody: Ok(None) if absent, Ok(Some(..)) if valid,
/// Error if present but malformed.
fn parse_optional_request_body(
  node: yay.Node,
  context: String,
  components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(Option(RefOr(RequestBody(Unresolved))), Diagnostic) {
  let present =
    result.is_ok(yay.select_sugar(from: node, selector: "requestBody"))
  use <- bool.guard(!present, Ok(None))
  use rb <- result.try(parse_request_body_at(node, context, components, index))
  Ok(Some(rb))
}

/// Parse responses, treating the field as optional.
/// OpenAPI 3.x requires responses on operations, but webhook operations
/// in the wild often omit them. Validation can catch missing responses.
fn parse_responses_required(
  node: yay.Node,
  context: String,
  components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(
  dict.Dict(http.HttpStatusCode, RefOr(Response(Unresolved))),
  Diagnostic,
) {
  parse_responses(node, context, components, index)
}

/// Parse parameters list from a node.
fn parse_parameters_list(
  node: yay.Node,
  components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(List(RefOr(Parameter(Unresolved))), Diagnostic) {
  case yay.select_sugar(from: node, selector: "parameters") {
    Ok(yay.NodeSeq(items)) ->
      list.try_map(items, fn(item) { parse_parameter(item, components, index) })
    _ -> Ok([])
  }
}

/// Parse a single parameter.
fn parse_parameter(
  node: yay.Node,
  _components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(RefOr(Parameter(Unresolved)), Diagnostic) {
  // Check for $ref first
  case yay.extract_optional_string(node, "$ref") {
    Ok(Some(ref_str)) -> {
      Ok(Ref(ref_str))
    }
    _ -> {
      use name <- result.try(
        yay.extract_string(node, "name")
        |> result.map_error(parser_yay_error.missing_field_from_extraction(
          _,
          path: "parameter",
          field: "name",
          loc: location_index.lookup_field(index, "parameter", "name"),
        )),
      )

      use in_str <- result.try(
        yay.extract_string(node, "in")
        |> result.map_error(parser_yay_error.missing_field_from_extraction(
          _,
          path: "parameter." <> name,
          field: "in",
          loc: location_index.lookup_field(index, "parameter." <> name, "in"),
        )),
      )

      use in_ <- result.try(parse_parameter_in(in_str, index))

      let description = parser_value.optional_string(node, "description")

      let explicit_required = parser_value.optional_bool(node, "required")

      // OpenAPI 3.x: path parameters MUST have required: true
      use required <- result.try(case in_, explicit_required {
        spec.InPath, Some(False) ->
          Error(diagnostic.invalid_value(
            path: "parameter." <> name,
            detail: "Path parameters must have required: true",
            loc: location_index.lookup(index, "parameter." <> name),
          ))
        spec.InPath, _ -> Ok(True)
        _, Some(v) -> Ok(v)
        _, None -> Ok(False)
      })

      let deprecated = parser_value.bool_default(node, "deprecated", False)

      use param_schema <- result.try(
        case yay.select_sugar(from: node, selector: "schema") {
          Ok(schema_node) -> {
            use sr <- result.try(parser_schema.parse_schema_ref(
              schema_node,
              "parameter.schema",
              index,
            ))
            Ok(Ok(sr))
          }
          _ -> Ok(Error(Nil))
        },
      )

      use style <- result.try(case parser_value.optional_string(node, "style") {
        Some(s) -> {
          use parsed <- result.try(parse_parameter_style(s, index))
          Ok(Some(parsed))
        }
        None -> Ok(None)
      })

      let explode = parser_value.optional_bool(node, "explode")

      let allow_reserved =
        parser_value.bool_default(node, "allowReserved", False)

      use content <- result.try(parse_content_map(node, index))
      let examples = parser_value.extract_map(node, "examples")

      let payload = case param_schema {
        Ok(sr) -> spec.ParameterSchema(sr)
        // nolint: thrown_away_error -- Nil error merely signals absence of parameter.schema; content fallback is intentional
        Error(_) -> spec.ParameterContent(content)
      }

      Ok(
        Value(Parameter(
          name:,
          in_:,
          description:,
          required:,
          payload:,
          style:,
          explode:,
          deprecated:,
          allow_reserved:,
          examples:,
        )),
      )
    }
  }
}

/// Parse parameter location string.
fn parse_parameter_in(
  value: String,
  index: LocationIndex,
) -> Result(ParameterIn, Diagnostic) {
  case value {
    "path" -> Ok(spec.InPath)
    "query" -> Ok(spec.InQuery)
    "header" -> Ok(spec.InHeader)
    "cookie" -> Ok(spec.InCookie)
    _ ->
      Error(diagnostic.invalid_value(
        path: "parameter.in",
        detail: "Unknown parameter location: "
          <> value
          <> ". Must be one of: path, query, header, cookie",
        loc: location_index.lookup(index, "parameter.in"),
      ))
  }
}

/// Map a style string to a ParameterStyle ADT value.
fn parse_parameter_style(
  value: String,
  index: LocationIndex,
) -> Result(spec.ParameterStyle, Diagnostic) {
  case value {
    "form" -> Ok(spec.FormStyle)
    "simple" -> Ok(spec.SimpleStyle)
    "deepObject" -> Ok(spec.DeepObjectStyle)
    "matrix" -> Ok(spec.MatrixStyle)
    "label" -> Ok(spec.LabelStyle)
    "spaceDelimited" -> Ok(spec.SpaceDelimitedStyle)
    "pipeDelimited" -> Ok(spec.PipeDelimitedStyle)
    _ ->
      Error(diagnostic.invalid_value(
        path: "parameter.style",
        detail: "Unknown parameter style: '"
          <> value
          <> "'. Must be one of: form, simple, deepObject, matrix, label, spaceDelimited, pipeDelimited",
        loc: location_index.lookup(index, "parameter.style"),
      ))
  }
}

/// Map an apiKey "in" string to a SecuritySchemeIn ADT value.
fn parse_security_scheme_in(
  value: String,
  index: LocationIndex,
) -> Result(spec.SecuritySchemeIn, Diagnostic) {
  case value {
    "header" -> Ok(spec.SchemeInHeader)
    "query" -> Ok(spec.SchemeInQuery)
    "cookie" -> Ok(spec.SchemeInCookie)
    _ ->
      Error(diagnostic.invalid_value(
        path: "securityScheme.in",
        detail: "Unknown apiKey location: "
          <> value
          <> ". Must be one of: header, query, cookie",
        loc: location_index.lookup(index, "securityScheme.in"),
      ))
  }
}

/// Parse requestBody from a node.
fn parse_request_body_at(
  node: yay.Node,
  context: String,
  _components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(RefOr(RequestBody(Unresolved)), Diagnostic) {
  use rb_node <- result.try(
    yay.select_sugar(from: node, selector: "requestBody")
    |> result.map_error(parser_yay_error.missing_field_from_selector(
      _,
      path: context,
      field: "requestBody",
      loc: location_index.lookup_field(index, context, "requestBody"),
    )),
  )

  // Check for $ref first
  case yay.extract_optional_string(rb_node, "$ref") {
    Ok(Some(ref_str)) -> Ok(Ref(ref_str))
    _ -> {
      use rb <- result.try(parse_request_body(rb_node, context, index))
      Ok(Value(rb))
    }
  }
}

/// Parse a request body object.
fn parse_request_body(
  node: yay.Node,
  context: String,
  index: LocationIndex,
) -> Result(RequestBody(Unresolved), Diagnostic) {
  let description = parser_value.optional_string(node, "description")

  let required = parser_value.bool_default(node, "required", False)

  // content is REQUIRED per OpenAPI spec
  use content <- result.try(parse_required_content(node, context, index))

  Ok(RequestBody(description:, content:, required:))
}

/// Parse content map, requiring at least one entry for request bodies.
fn parse_required_content(
  node: yay.Node,
  context: String,
  index: LocationIndex,
) -> Result(Dict(String, MediaType), Diagnostic) {
  case yay.select_sugar(from: node, selector: "content") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(media_type_name) -> {
            use mt_schema <- result.try(
              case yay.select_sugar(from: value_node, selector: "schema") {
                Ok(schema_node) -> {
                  use sr <- result.try(parser_schema.parse_schema_ref(
                    schema_node,
                    context <> ".schema",
                    index,
                  ))
                  Ok(Some(sr))
                }
                _ -> Ok(None)
              },
            )
            let mt_example =
              parser_value.extract_optional(value_node, "example")
            let mt_examples = parser_value.extract_map(value_node, "examples")
            use mt_encoding <- result.try(parse_encoding_map(value_node, index))
            Ok(dict.insert(
              acc,
              media_type_name,
              MediaType(
                schema: mt_schema,
                example: mt_example,
                examples: mt_examples,
                encoding: mt_encoding,
              ),
            ))
          }
          _ -> Ok(acc)
        }
      })
    }
    _ ->
      Error(diagnostic.missing_field(
        path: context <> ".requestBody",
        field: "content",
        loc: location_index.lookup_field(
          index,
          context <> ".requestBody",
          "content",
        ),
      ))
  }
}

/// Parse content map (media type -> schema).
fn parse_content(
  node: yay.Node,
  context: String,
  index: LocationIndex,
) -> Result(Dict(String, MediaType), Diagnostic) {
  case yay.select_sugar(from: node, selector: "content") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(media_type_name) -> {
            use mt_schema <- result.try(
              case yay.select_sugar(from: value_node, selector: "schema") {
                Ok(schema_node) -> {
                  use sr <- result.try(parser_schema.parse_schema_ref(
                    schema_node,
                    context <> ".schema",
                    index,
                  ))
                  Ok(Some(sr))
                }
                _ -> Ok(None)
              },
            )
            let mt_example =
              parser_value.extract_optional(value_node, "example")
            let mt_examples = parser_value.extract_map(value_node, "examples")
            use mt_encoding <- result.try(parse_encoding_map(value_node, index))
            Ok(dict.insert(
              acc,
              media_type_name,
              MediaType(
                schema: mt_schema,
                example: mt_example,
                examples: mt_examples,
                encoding: mt_encoding,
              ),
            ))
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse responses object.
fn parse_responses(
  node: yay.Node,
  _context: String,
  components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(Dict(http.HttpStatusCode, RefOr(Response(Unresolved))), Diagnostic) {
  case yay.select_sugar(from: node, selector: "responses") {
    Ok(yay.NodeMap(entries)) -> {
      // Issue #573: yamerl tolerates duplicate mapping keys, so two
      // `'200':` entries on the same operation would silently overwrite
      // (later wins). Reject duplicates explicitly before the
      // dict.insert loop so users see a parse-time error.
      use _ <- result.try(check_unique_yaml_keys(
        entries: entries,
        path: "responses",
        index: index,
      ))
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(status_code) ->
            case string.starts_with(status_code, "x-") {
              True -> Ok(acc)
              False ->
                case http.parse_status_code(status_code) {
                  Ok(code) -> {
                    use resp <- result.try(parse_response(
                      value_node,
                      components,
                      index,
                    ))
                    Ok(dict.insert(acc, code, resp))
                  }
                  Error(_) ->
                    Error(invalid_response_status_diagnostic(status_code, index))
                }
            }
          yay.NodeInt(code) ->
            case http.http_status_from_int(code) {
              Ok(status) -> {
                use resp <- result.try(parse_response(
                  value_node,
                  components,
                  index,
                ))
                Ok(dict.insert(acc, status, resp))
              }
              Error(_) ->
                Error(invalid_response_status_diagnostic(
                  int.to_string(code),
                  index,
                ))
            }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Build the parse-time diagnostic for a response status-code key that
/// is outside the OAS-allowed grammar (#587). Listed at module scope so
/// the YAML-string path and the YAML-int path emit the same message.
fn invalid_response_status_diagnostic(
  key: String,
  index: LocationIndex,
) -> Diagnostic {
  diagnostic.invalid_value(
    path: "responses",
    detail: "Invalid response status code key '"
      <> key
      <> "'. OpenAPI accepts 100-599 (canonical 3-digit), the wildcards "
      <> "1XX-5XX, or 'default'.",
    loc: location_index.lookup_field(index, "", "responses"),
  )
}

/// Issue #573: detect duplicate keys in a YAML mapping before consuming
/// it into a `Dict`. yamerl preserves the original `entries` list with
/// both occurrences of a duplicate key, but `dict.insert` silently
/// overwrites — so without this check, duplicates disappear into
/// undefined behavior (whichever entry happens to be inserted last
/// wins). Returns the *first* duplicate as a `Diagnostic`; we don't
/// accumulate every duplicate to keep the parse-phase contract
/// (one error stops parsing).
///
/// The `index` argument is reserved for a future source-location
/// lookup (so the diagnostic can name the line of the second
/// occurrence). For now the location index does not retain per-key
/// positions inside arbitrary maps, so the diagnostic carries
/// `NoSourceLoc` and the user-facing message names the path
/// (`responses`, `components.responses`) instead.
fn check_unique_yaml_keys(
  entries entries: List(#(yay.Node, yay.Node)),
  path path: String,
  index index: LocationIndex,
) -> Result(Nil, Diagnostic) {
  let loc = location_index.lookup(index, path)
  list.try_fold(entries, [], fn(seen, entry) {
    let #(key_node, _) = entry
    case key_node_to_string(key_node) {
      Some(key) ->
        case list.contains(seen, key) {
          True ->
            Error(diagnostic.duplicate_key(path: path, key: key, loc: loc))
          False -> Ok([key, ..seen])
        }
      None -> Ok(seen)
    }
  })
  |> result.map(fn(_) { Nil })
}

/// Render a `yay` key node as a comparable string for duplicate
/// detection. Returns `None` for node types that cannot occur as
/// OpenAPI map keys (lists, maps, etc.); those positions are handled
/// elsewhere as `invalid_value` errors and do not need duplicate
/// checking.
fn key_node_to_string(node: yay.Node) -> Option(String) {
  case node {
    yay.NodeStr(s) -> Some(s)
    yay.NodeInt(n) -> Some(int.to_string(n))
    yay.NodeBool(True) -> Some("true")
    yay.NodeBool(False) -> Some("false")
    _ -> None
  }
}

/// Parse a single response object.
fn parse_response(
  node: yay.Node,
  _components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(RefOr(Response(Unresolved)), Diagnostic) {
  // Check for $ref first
  case yay.extract_optional_string(node, "$ref") {
    Ok(Some(ref_str)) -> Ok(Ref(ref_str))
    _ -> {
      // description is REQUIRED per OpenAPI spec
      use description <- result.try(
        yay.extract_string(node, "description")
        |> result.map(Some)
        |> result.map_error(parser_yay_error.missing_field_from_extraction(
          _,
          path: "response",
          field: "description",
          loc: location_index.lookup_field(index, "response", "description"),
        )),
      )

      use content <- result.try(parse_content(node, "response", index))
      use headers <- result.try(parse_headers_map(node, index))
      use links <- result.try(parse_links_map(node))

      Ok(Value(Response(description:, content:, headers:, links:)))
    }
  }
}

/// Parse the components section.
fn parse_components(
  root: yay.Node,
  index: LocationIndex,
) -> Result(Components(Unresolved), Diagnostic) {
  use components_node <- result.try(
    yay.select_sugar(from: root, selector: "components")
    |> result.map_error(parser_yay_error.missing_field_from_selector(
      _,
      path: "",
      field: "components",
      loc: location_index.lookup_field(index, "", "components"),
    )),
  )

  use schemas <- result.try(parse_schemas_map(components_node, index))
  use parameters <- result.try(parse_parameters_map(components_node, index))
  use request_bodies <- result.try(parse_request_bodies_map(
    components_node,
    index,
  ))
  use responses <- result.try(parse_responses_map(components_node, index))
  use security_schemes <- result.try(parse_security_schemes_map(
    components_node,
    index,
  ))
  use path_items <- result.try(parse_path_items_map(components_node, index))
  use headers <- result.try(parse_headers_map(components_node, index))
  let examples = parser_value.extract_map(components_node, "examples")
  use links <- result.try(parse_links_map(components_node))
  use callbacks <- result.try(parse_components_callbacks_map(
    components_node,
    index,
  ))

  Ok(Components(
    schemas:,
    parameters:,
    request_bodies:,
    responses:,
    security_schemes:,
    path_items:,
    headers:,
    examples:,
    links:,
    callbacks:,
  ))
}

/// Parse `components.callbacks`: each entry is a named reusable callback
/// object. Returns an empty dict if the section is missing. `$ref` values
/// are preserved so chains like `components.callbacks.foo.$ref: ...`
/// stay as references.
fn parse_components_callbacks_map(
  components_node: yay.Node,
  index: LocationIndex,
) -> Result(Dict(String, RefOr(Callback(Unresolved))), Diagnostic) {
  case yay.select_sugar(from: components_node, selector: "callbacks") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            case yay.extract_optional_string(value_node, "$ref") {
              Ok(Some(ref_str)) -> Ok(dict.insert(acc, name, Ref(ref_str)))
              Ok(None) -> {
                use callback <- result.try(parse_callback_object(
                  value_node,
                  "components.callbacks." <> name,
                  None,
                  index,
                ))
                Ok(dict.insert(acc, name, Value(callback)))
              }
              Error(_) ->
                Error(diagnostic.invalid_value(
                  path: "components.callbacks." <> name <> ".$ref",
                  detail: "`$ref` under a reusable callback must be a string pointing at '#/components/callbacks/...'.",
                  loc: location_index.lookup_field(
                    index,
                    "components.callbacks." <> name,
                    "$ref",
                  ),
                ))
            }
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse the schemas map from components.
fn parse_schemas_map(
  components_node: yay.Node,
  index: LocationIndex,
) -> Result(Dict(String, SchemaRef), Diagnostic) {
  case yay.select_sugar(from: components_node, selector: "schemas") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            use schema_ref <- result.try(parser_schema.parse_schema_ref(
              value_node,
              "components.schemas." <> name,
              index,
            ))
            Ok(dict.insert(acc, name, schema_ref))
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse the parameters map from components.
fn parse_parameters_map(
  components_node: yay.Node,
  index: LocationIndex,
) -> Result(Dict(String, RefOr(Parameter(Unresolved))), Diagnostic) {
  case yay.select_sugar(from: components_node, selector: "parameters") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            case yay.extract_optional_string(value_node, "$ref") {
              Ok(Some(ref_str)) -> Ok(dict.insert(acc, name, Ref(ref_str)))
              _ -> {
                use param <- result.try(parse_parameter(value_node, None, index))
                Ok(dict.insert(acc, name, param))
              }
            }
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse the requestBodies map from components.
fn parse_request_bodies_map(
  components_node: yay.Node,
  index: LocationIndex,
) -> Result(Dict(String, RefOr(RequestBody(Unresolved))), Diagnostic) {
  case yay.select_sugar(from: components_node, selector: "requestBodies") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            case yay.extract_optional_string(value_node, "$ref") {
              Ok(Some(ref_str)) -> Ok(dict.insert(acc, name, Ref(ref_str)))
              _ -> {
                use rb <- result.try(parse_request_body(
                  value_node,
                  "components.requestBodies." <> name,
                  index,
                ))
                Ok(dict.insert(acc, name, Value(rb)))
              }
            }
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse the responses map from components.
fn parse_responses_map(
  components_node: yay.Node,
  index: LocationIndex,
) -> Result(Dict(String, RefOr(Response(Unresolved))), Diagnostic) {
  case yay.select_sugar(from: components_node, selector: "responses") {
    Ok(yay.NodeMap(entries)) -> {
      // Issue #573: same duplicate-key concern as `parse_responses` —
      // duplicate component names would silently overwrite without this
      // check.
      use _ <- result.try(check_unique_yaml_keys(
        entries: entries,
        path: "components.responses",
        index: index,
      ))
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            case yay.extract_optional_string(value_node, "$ref") {
              Ok(Some(ref_str)) -> Ok(dict.insert(acc, name, Ref(ref_str)))
              _ -> {
                use resp <- result.try(parse_response(value_node, None, index))
                Ok(dict.insert(acc, name, resp))
              }
            }
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse a schema reference (either $ref or inline schema).
/// Convert a parse error to a human-readable string.
pub fn parse_error_to_string(error: Diagnostic) -> String {
  diagnostic.to_short_string(error)
}

/// Parse security schemes from components.
/// Returns Ok(empty dict) if the section is absent, Error if present but
/// malformed.
fn parse_security_schemes_map(
  components_node: yay.Node,
  index: LocationIndex,
) -> Result(Dict(String, RefOr(spec.SecurityScheme)), Diagnostic) {
  case yay.select_sugar(from: components_node, selector: "securitySchemes") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            case yay.extract_optional_string(value_node, "$ref") {
              Ok(Some(ref_str)) -> Ok(dict.insert(acc, name, Ref(ref_str)))
              _ -> {
                use scheme <- result.try(parse_security_scheme(
                  value_node,
                  index,
                ))
                Ok(dict.insert(acc, name, Value(scheme)))
              }
            }
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse the pathItems map from components.
fn parse_path_items_map(
  components_node: yay.Node,
  index: LocationIndex,
) -> Result(Dict(String, RefOr(PathItem(Unresolved))), Diagnostic) {
  case yay.select_sugar(from: components_node, selector: "pathItems") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            case yay.extract_optional_string(value_node, "$ref") {
              Ok(Some(ref_str)) -> Ok(dict.insert(acc, name, Ref(ref_str)))
              _ -> {
                use path_item <- result.try(parse_path_item(
                  value_node,
                  "components.pathItems." <> name,
                  None,
                  index,
                ))
                Ok(dict.insert(acc, name, Value(path_item)))
              }
            }
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse a single security scheme.
fn parse_security_scheme(
  node: yay.Node,
  index: LocationIndex,
) -> Result(spec.SecurityScheme, Diagnostic) {
  use type_str <- result.try(
    yay.extract_string(node, "type")
    |> result.map_error(parser_yay_error.missing_field_from_extraction(
      _,
      path: "securityScheme",
      field: "type",
      loc: location_index.lookup_field(index, "securityScheme", "type"),
    )),
  )

  case type_str {
    "apiKey" -> {
      use name <- result.try(
        yay.extract_string(node, "name")
        |> result.map_error(parser_yay_error.missing_field_from_extraction(
          _,
          path: "securityScheme.apiKey",
          field: "name",
          loc: location_index.lookup_field(
            index,
            "securityScheme.apiKey",
            "name",
          ),
        )),
      )
      use in_str <- result.try(
        yay.extract_string(node, "in")
        |> result.map_error(parser_yay_error.missing_field_from_extraction(
          _,
          path: "securityScheme.apiKey",
          field: "in",
          loc: location_index.lookup_field(index, "securityScheme.apiKey", "in"),
        )),
      )
      case parse_security_scheme_in(in_str, index) {
        Ok(in_) -> Ok(spec.ApiKeyScheme(name:, in_:))
        Error(_) ->
          Error(diagnostic.invalid_value(
            path: "securityScheme.apiKey.in",
            detail: "Only 'header', 'query' and 'cookie' are supported for apiKey. Got: '"
              <> in_str
              <> "'",
            loc: location_index.lookup(index, "securityScheme.apiKey.in"),
          ))
      }
    }
    "http" -> {
      use scheme <- result.try(
        yay.extract_string(node, "scheme")
        |> result.map_error(parser_yay_error.missing_field_from_extraction(
          _,
          path: "securityScheme.http",
          field: "scheme",
          loc: location_index.lookup_field(
            index,
            "securityScheme.http",
            "scheme",
          ),
        )),
      )
      let bearer_format = parser_value.optional_string(node, "bearerFormat")
      Ok(spec.HttpScheme(scheme:, bearer_format:))
    }
    "oauth2" -> {
      let description = parser_value.optional_string(node, "description")
      let flows = parse_oauth2_flows(node)
      Ok(spec.OAuth2Scheme(description:, flows:))
    }
    "openIdConnect" -> {
      let description = parser_value.optional_string(node, "description")
      use open_id_connect_url <- result.try(
        yay.extract_string(node, "openIdConnectUrl")
        |> result.map_error(parser_yay_error.missing_field_from_extraction(
          _,
          path: "securityScheme.openIdConnect",
          field: "openIdConnectUrl",
          loc: location_index.lookup_field(
            index,
            "securityScheme.openIdConnect",
            "openIdConnectUrl",
          ),
        )),
      )
      Ok(spec.OpenIdConnectScheme(open_id_connect_url:, description:))
    }
    _ ->
      // Preserve unsupported scheme types losslessly;
      // capability_check will reject them.
      Ok(spec.UnsupportedScheme(scheme_type: type_str))
  }
}

/// Parse OAuth2 flows from a security scheme node.
fn parse_oauth2_flows(node: yay.Node) -> dict.Dict(String, spec.OAuth2Flow) {
  case yay.select_sugar(from: node, selector: "flows") {
    Ok(yay.NodeMap(flow_entries)) ->
      list.fold(flow_entries, dict.new(), fn(acc, entry) {
        let #(key_node, flow_node) = entry
        case key_node {
          yay.NodeStr(flow_name) -> {
            let authorization_url =
              parser_value.optional_string(flow_node, "authorizationUrl")
            let token_url = parser_value.optional_string(flow_node, "tokenUrl")
            let refresh_url =
              parser_value.optional_string(flow_node, "refreshUrl")
            let scopes = case
              yay.select_sugar(from: flow_node, selector: "scopes")
            {
              Ok(yay.NodeMap(scope_entries)) ->
                list.fold(scope_entries, dict.new(), fn(sacc, sentry) {
                  let #(sk, sv) = sentry
                  case sk, sv {
                    yay.NodeStr(scope_name), yay.NodeStr(scope_desc) ->
                      dict.insert(sacc, scope_name, scope_desc)
                    _, _ -> sacc
                  }
                })
              _ -> dict.new()
            }
            dict.insert(
              acc,
              flow_name,
              spec.OAuth2Flow(
                authorization_url:,
                token_url:,
                refresh_url:,
                scopes:,
              ),
            )
          }
          _ -> acc
        }
      })
    _ -> dict.new()
  }
}

/// Parse top-level security requirements.
/// Returns Ok([]) if absent, Error if present but malformed.
fn parse_security_requirements(
  node: yay.Node,
  context: String,
  index: LocationIndex,
) -> Result(List(SecurityRequirement), Diagnostic) {
  case yay.select_sugar(from: node, selector: "security") {
    Ok(yay.NodeSeq(items)) ->
      list.try_map(items, fn(item) {
        parse_security_requirement_object(item, context, index)
      })
    _ -> Ok([])
  }
}

/// Parse operation-level security requirements.
/// Returns Ok(None) if absent (inherits top-level), Ok(Some([])) if explicitly
/// empty (opts out), Ok(Some([...])) if specified.
fn parse_optional_security_requirements(
  node: yay.Node,
  context: String,
  index: LocationIndex,
) -> Result(Option(List(SecurityRequirement)), Diagnostic) {
  case yay.select_sugar(from: node, selector: "security") {
    Ok(yay.NodeSeq(items)) -> {
      use reqs <- result.try(
        list.try_map(items, fn(item) {
          parse_security_requirement_object(item, context, index)
        }),
      )
      Ok(Some(reqs))
    }
    _ -> Ok(None)
  }
}

/// Parse a single security requirement object.
/// Returns one SecurityRequirement whose schemes list contains all AND-ed
/// scheme refs. The outer list (caller) represents OR alternatives.
fn parse_security_requirement_object(
  node: yay.Node,
  context: String,
  index: LocationIndex,
) -> Result(SecurityRequirement, Diagnostic) {
  case node {
    yay.NodeMap(entries) -> {
      use scheme_refs <- result.try(
        list.try_map(entries, fn(entry) {
          let #(key_node, scopes_node) = entry
          case key_node {
            yay.NodeStr(scheme_name) -> {
              use scopes <- result.try(case scopes_node {
                yay.NodeSeq(scope_items) ->
                  list.try_map(scope_items, fn(s) {
                    case s {
                      yay.NodeStr(v) -> Ok(v)
                      _ ->
                        Error(diagnostic.invalid_value(
                          path: context <> ".security." <> scheme_name,
                          detail: "Scope must be a string",
                          loc: location_index.lookup(
                            index,
                            context <> ".security." <> scheme_name,
                          ),
                        ))
                    }
                  })
                yay.NodeNil -> Ok([])
                _ ->
                  Error(diagnostic.invalid_value(
                    path: context <> ".security." <> scheme_name,
                    detail: "Scopes must be an array of strings",
                    loc: location_index.lookup(
                      index,
                      context <> ".security." <> scheme_name,
                    ),
                  ))
              })
              Ok(spec.SecuritySchemeRef(scheme_name:, scopes:))
            }
            _ ->
              Error(diagnostic.invalid_value(
                path: context <> ".security",
                detail: "Security requirement key must be a string",
                loc: location_index.lookup(index, context <> ".security"),
              ))
          }
        }),
      )
      Ok(SecurityRequirement(schemes: scheme_refs))
    }
    _ ->
      Error(diagnostic.invalid_value(
        path: context <> ".security",
        detail: "Security requirement must be an object",
        loc: location_index.lookup(index, context <> ".security"),
      ))
  }
}

/// Parse callbacks from an operation node.
/// Returns an empty dict if no callbacks are present.
/// Each entry is a `RefOr(Callback)`: a top-level `$ref` pointing at
/// `#/components/callbacks/foo` is preserved as-is (so the reusable
/// callback reference survives into the resolved AST), while inline
/// definitions are parsed into their URL-expression→PathItem shape.
fn parse_callbacks(
  node: yay.Node,
  context: String,
  components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(dict.Dict(String, RefOr(Callback(Unresolved))), Diagnostic) {
  case yay.select_sugar(from: node, selector: "callbacks") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(callback_name) -> {
            // A top-level `$ref` here means the operation is pointing
            // at a reusable callback object — keep it as Ref.
            case yay.extract_optional_string(value_node, "$ref") {
              Ok(Some(ref_str)) ->
                Ok(dict.insert(acc, callback_name, Ref(ref_str)))
              Ok(None) -> {
                use callback <- result.try(parse_callback_object(
                  value_node,
                  context,
                  components,
                  index,
                ))
                Ok(dict.insert(acc, callback_name, Value(callback)))
              }
              Error(_) ->
                Error(diagnostic.invalid_value(
                  path: context <> ".callbacks." <> callback_name <> ".$ref",
                  detail: "`$ref` under a callback entry must be a string pointing at '#/components/callbacks/...'.",
                  loc: location_index.lookup_field(
                    index,
                    context <> ".callbacks." <> callback_name,
                    "$ref",
                  ),
                ))
            }
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse a single callback object (maps URL expressions -> PathItems).
/// Propagates parse errors from individual URL expression path items.
fn parse_callback_object(
  node: yay.Node,
  context: String,
  components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(Callback(Unresolved), Diagnostic) {
  case node {
    yay.NodeMap(entries) -> {
      use parsed_entries <- result.try(
        list.try_fold(entries, [], fn(acc, entry) {
          let #(key_node, path_item_node) = entry
          case key_node {
            yay.NodeStr(url_expression) -> {
              // Check for $ref first — preserve as Ref for resolve phase
              case parser_value.optional_string(path_item_node, "$ref") {
                Some(ref_str) -> Ok([#(url_expression, Ref(ref_str)), ..acc])
                None -> {
                  use path_item <- result.try(parse_path_item(
                    path_item_node,
                    context <> ".callbacks." <> url_expression,
                    components,
                    index,
                  ))
                  Ok([#(url_expression, Value(path_item)), ..acc])
                }
              }
            }
            _ -> Ok(acc)
          }
        }),
      )
      case parsed_entries {
        [] ->
          Error(diagnostic.missing_field(
            path: context <> ".callbacks",
            field: "url expression",
            loc: location_index.lookup_field(
              index,
              context <> ".callbacks",
              "url expression",
            ),
          ))
        _ -> Ok(Callback(entries: dict.from_list(parsed_entries)))
      }
    }
    _ ->
      Error(diagnostic.missing_field(
        path: context <> ".callbacks",
        field: "url expression",
        loc: location_index.lookup_field(
          index,
          context <> ".callbacks",
          "url expression",
        ),
      ))
  }
}

/// Parse optional contact from an info node.
fn parse_optional_contact(info_node: yay.Node) -> Option(Contact) {
  case yay.select_sugar(from: info_node, selector: "contact") {
    Ok(contact_node) -> {
      let name = parser_value.optional_string(contact_node, "name")
      let url = parser_value.optional_string(contact_node, "url")
      let email = parser_value.optional_string(contact_node, "email")
      Some(Contact(name:, url:, email:))
    }
    _ -> None
  }
}

/// Parse optional license from an info node.
fn parse_optional_license(info_node: yay.Node) -> Option(License) {
  case yay.select_sugar(from: info_node, selector: "license") {
    Ok(license_node) -> {
      case yay.extract_string(license_node, "name") {
        Ok(name) -> {
          let url = parser_value.optional_string(license_node, "url")
          Some(License(name:, url:))
        }
        _ -> None
      }
    }
    _ -> None
  }
}

/// Parse server variables from a server node.
fn parse_server_variables(node: yay.Node) -> Dict(String, ServerVariable) {
  case yay.select_sugar(from: node, selector: "variables") {
    Ok(yay.NodeMap(entries)) ->
      list.fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(var_name) -> {
            let default = parser_value.string_default(value_node, "default", "")
            let enum_values = case yay.extract_string_list(value_node, "enum") {
              Ok(values) -> values
              _ -> []
            }
            let description =
              parser_value.optional_string(value_node, "description")
            dict.insert(
              acc,
              var_name,
              ServerVariable(default:, enum_values:, description:),
            )
          }
          _ -> acc
        }
      })
    _ -> dict.new()
  }
}

/// Parse optional external docs from a node.
fn parse_optional_external_docs(node: yay.Node) -> Option(ExternalDoc) {
  case yay.select_sugar(from: node, selector: "externalDocs") {
    Ok(doc_node) -> {
      case yay.extract_string(doc_node, "url") {
        Ok(url) -> {
          let description =
            parser_value.optional_string(doc_node, "description")
          Some(ExternalDoc(url:, description:))
        }
        _ -> None
      }
    }
    _ -> None
  }
}

/// Parse tags array from root.
fn parse_tags(node: yay.Node) -> List(Tag) {
  case yay.select_sugar(from: node, selector: "tags") {
    Ok(yay.NodeSeq(items)) ->
      list.filter_map(items, fn(tag_node) {
        case yay.extract_string(tag_node, "name") {
          Ok(name) -> {
            let description =
              parser_value.optional_string(tag_node, "description")
            let external_docs = parse_optional_external_docs(tag_node)
            Ok(Tag(name:, description:, external_docs:))
          }
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

/// Parse webhooks from root.
fn parse_webhooks(
  node: yay.Node,
  components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(Dict(String, RefOr(PathItem(Unresolved))), Diagnostic) {
  case yay.select_sugar(from: node, selector: "webhooks") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            // Check for $ref first — preserve as Ref for resolve phase
            case parser_value.optional_string(value_node, "$ref") {
              Some(ref_str) -> Ok(dict.insert(acc, name, Ref(ref_str)))
              None -> {
                use path_item <- result.try(parse_path_item(
                  value_node,
                  "webhooks." <> name,
                  components,
                  index,
                ))
                Ok(dict.insert(acc, name, Value(path_item)))
              }
            }
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse a content map (non-result version for use in Parameter).
fn parse_content_map(
  node: yay.Node,
  index: LocationIndex,
) -> Result(Dict(String, MediaType), Diagnostic) {
  case yay.select_sugar(from: node, selector: "content") {
    Ok(yay.NodeMap(entries)) ->
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(media_type_name) -> {
            use mt_schema <- result.try(
              case yay.select_sugar(from: value_node, selector: "schema") {
                Ok(schema_node) -> {
                  use sr <- result.try(parser_schema.parse_schema_ref(
                    schema_node,
                    "content.schema",
                    index,
                  ))
                  Ok(Some(sr))
                }
                _ -> Ok(None)
              },
            )
            let mt_example =
              parser_value.extract_optional(value_node, "example")
            let mt_examples = parser_value.extract_map(value_node, "examples")
            use mt_encoding <- result.try(parse_encoding_map(value_node, index))
            Ok(dict.insert(
              acc,
              media_type_name,
              MediaType(
                schema: mt_schema,
                example: mt_example,
                examples: mt_examples,
                encoding: mt_encoding,
              ),
            ))
          }
          _ -> Ok(acc)
        }
      })
    _ -> Ok(dict.new())
  }
}

/// Parse encoding map from a media type node.
fn parse_encoding_map(
  node: yay.Node,
  index: LocationIndex,
) -> Result(Dict(String, Encoding), Diagnostic) {
  case yay.select_sugar(from: node, selector: "encoding") {
    Ok(yay.NodeMap(entries)) ->
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(prop_name) -> {
            let content_type =
              parser_value.optional_string(value_node, "contentType")
            use style <- result.try(
              case parser_value.optional_string(value_node, "style") {
                Some(s) -> {
                  use parsed <- result.try(parse_parameter_style(s, index))
                  Ok(Some(parsed))
                }
                None -> Ok(None)
              },
            )
            let explode = parser_value.optional_bool(value_node, "explode")
            Ok(dict.insert(
              acc,
              prop_name,
              Encoding(content_type:, style:, explode:),
            ))
          }
          _ -> Ok(acc)
        }
      })
    _ -> Ok(dict.new())
  }
}

/// Parse headers map from a node.
fn parse_headers_map(
  node: yay.Node,
  index: LocationIndex,
) -> Result(Dict(String, Header), Diagnostic) {
  case yay.select_sugar(from: node, selector: "headers") {
    Ok(yay.NodeMap(entries)) ->
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(header_name) -> {
            let description =
              parser_value.optional_string(value_node, "description")
            let required =
              parser_value.bool_default(value_node, "required", False)
            use hdr_schema <- result.try(
              case yay.select_sugar(from: value_node, selector: "schema") {
                Ok(schema_node) -> {
                  use sr <- result.try(parser_schema.parse_schema_ref(
                    schema_node,
                    "header." <> header_name <> ".schema",
                    index,
                  ))
                  Ok(Some(sr))
                }
                _ -> Ok(None)
              },
            )
            Ok(dict.insert(
              acc,
              header_name,
              Header(description:, required:, schema: hdr_schema),
            ))
          }
          _ -> Ok(acc)
        }
      })
    _ -> Ok(dict.new())
  }
}

/// Parse links map from a node.
fn parse_links_map(node: yay.Node) -> Result(Dict(String, Link), Diagnostic) {
  case yay.select_sugar(from: node, selector: "links") {
    Ok(yay.NodeMap(entries)) ->
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(link_name) -> {
            let operation_id =
              parser_value.optional_string(value_node, "operationId")
            let description =
              parser_value.optional_string(value_node, "description")
            Ok(dict.insert(acc, link_name, Link(operation_id:, description:)))
          }
          _ -> Ok(acc)
        }
      })
    _ -> Ok(dict.new())
  }
}
