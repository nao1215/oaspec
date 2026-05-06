import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import oaspec/config.{type Config}
import oaspec/internal/openapi/operations
import oaspec/internal/openapi/resolver
import oaspec/internal/openapi/schema.{
  type SchemaMetadata, type SchemaObject, type SchemaRef, Inline, Reference,
}
import oaspec/internal/openapi/spec.{
  type HttpMethod, type OpenApiSpec, type Operation, type Resolved,
}
import oaspec/internal/util/naming

/// The version of oaspec used for generated code headers.
pub const version = "0.58.1"

/// One analyzed operation: its `operationId` (synthesized when missing),
/// the operation record with path-level parameters, security, and servers
/// already merged in, the URL path it lives under, and the HTTP method.
pub type AnalyzedOperation =
  #(String, Operation(Resolved), String, HttpMethod)

/// Context for code generation, carrying all needed state.
/// Only accepts a resolved spec — codegen must not operate on unresolved ASTs.
///
/// Opaque: external callers construct via `new/2` and read fields via
/// the accessors `spec/1` / `config/1` / `operations/1`. The shape is
/// free to evolve (e.g. add more derived caches) without rippling into
/// every pattern match across the codebase.
pub opaque type Context {
  Context(
    spec: OpenApiSpec(Resolved),
    config: Config,
    operations: List(AnalyzedOperation),
    schema_cache: dict.Dict(String, Result(SchemaObject, resolver.ResolveError)),
    component_type_names: dict.Dict(String, Nil),
  )
}

/// Create a new generation context from a resolved spec. The list of
/// analyzed operations (with merged path-level params, effective security,
/// effective servers, and synthesized operationIds) plus the component
/// schema-resolution cache are computed once here so every codegen pass can
/// read them via `operations/1` / `resolve_schema_ref/2` instead of
/// rebuilding the same analysis at unrelated call sites (issue #371).
pub fn new(spec: OpenApiSpec(Resolved), config: Config) -> Context {
  Context(
    spec:,
    config:,
    operations: operations.collect_operations(spec),
    schema_cache: build_schema_cache(spec),
    component_type_names: build_component_type_names(spec),
  )
}

/// The resolved OpenAPI spec this context wraps.
pub fn spec(ctx: Context) -> OpenApiSpec(Resolved) {
  ctx.spec
}

/// The generation config this context wraps.
pub fn config(ctx: Context) -> Config {
  ctx.config
}

/// The shared analyzed operations list, precomputed at context construction.
/// Every codegen pass should read this rather than recompute via
/// `operations.collect_operations` directly.
pub fn operations(ctx: Context) -> List(AnalyzedOperation) {
  ctx.operations
}

/// Resolve a schema ref through the shared analyzed cache.
///
/// Inline schemas are returned directly. Canonical component refs are served
/// from the cache; anything else falls back to the resolver to preserve the
/// original error shape for unexpected refs.
pub fn resolve_schema_ref(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Result(SchemaObject, resolver.ResolveError) {
  case schema_ref {
    Inline(schema_obj) -> Ok(schema_obj)
    Reference(ref:, ..) ->
      case dict.get(ctx.schema_cache, ref) {
        Ok(resolved) -> resolved
        // nolint: thrown_away_error -- cache miss falls back to the resolver so non-canonical refs still get the right error/result
        Error(_) -> resolver.resolve_schema_ref(schema_ref, ctx.spec)
      }
  }
}

/// Read metadata for any schema ref through the shared analyzed query layer.
pub fn schema_metadata(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Option(SchemaMetadata) {
  case resolve_schema_ref(schema_ref, ctx) {
    Ok(schema_obj) -> Some(schema.get_metadata(schema_obj))
    // nolint: thrown_away_error -- unresolved refs have no metadata; callers treat this as absence and the validator reports the underlying ref error separately
    Error(_) -> None
  }
}

/// Pre-computed set of every component schema name mapped through
/// `naming.schema_to_type_name`, exposed as a `Dict(String, Nil)` so
/// `dict.has_key` is the collision-check primitive. Without this,
/// every inline-enum / synthetic-list-suffix collision check would
/// rebuild the full mapped list, blowing up to O(N_schemas²) on
/// large specs.
pub fn component_type_names(ctx: Context) -> dict.Dict(String, Nil) {
  ctx.component_type_names
}

fn build_component_type_names(
  spec: OpenApiSpec(Resolved),
) -> dict.Dict(String, Nil) {
  case spec.components {
    Some(components) ->
      list.fold(dict.keys(components.schemas), dict.new(), fn(acc, name) {
        dict.insert(acc, naming.schema_to_type_name(name), Nil)
      })
    None -> dict.new()
  }
}

fn build_schema_cache(
  spec: OpenApiSpec(Resolved),
) -> dict.Dict(String, Result(SchemaObject, resolver.ResolveError)) {
  case spec.components {
    Some(components) ->
      list.fold(dict.to_list(components.schemas), dict.new(), fn(acc, entry) {
        let #(name, _schema_ref) = entry
        let ref = component_schema_ref(name)
        dict.insert(
          acc,
          ref,
          resolver.resolve_schema_ref(Reference(ref:, name:), spec),
        )
      })
    None -> dict.new()
  }
}

fn component_schema_ref(name: String) -> String {
  "#/components/schemas/" <> name
}

/// Target for a generated file, indicating where it should be written.
pub type FileTarget {
  SharedTarget
  ServerTarget
  ClientTarget
}

/// How the writer should treat a `GeneratedFile` that already exists on
/// disk. Most generated files are sealed (`Overwrite`) — the user is
/// expected not to touch them and the generator clobbers any local
/// changes on every run. `SkipIfExists` is for files the generator
/// emits ONCE as a starting point, then leaves alone so the user can
/// own the contents (Issue #247: `handlers.gleam` panic stubs).
pub type WriteMode {
  Overwrite
  SkipIfExists
}

/// A generated file with its path, content, output target, and write
/// mode. `write_mode` defaults to `Overwrite` for every file the
/// generator owns end-to-end.
pub type GeneratedFile {
  GeneratedFile(
    path: String,
    content: String,
    target: FileTarget,
    write_mode: WriteMode,
  )
}
