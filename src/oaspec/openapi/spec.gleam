import gleam/dict.{type Dict}
import gleam/option.{type Option}
import oaspec/openapi/schema.{type SchemaRef}
import oaspec/openapi/value.{type JsonValue}
import oaspec/util/http

// ============================================================================
// Stage and RefOr: core of the stage-typed AST
// ============================================================================

/// Phantom type: spec has not yet been through the resolve phase.
/// RefOr values may still contain Ref(String).
pub type Unresolved {
  Unresolved
}

/// Phantom type: spec has been through the resolve phase.
/// All RefOr values are guaranteed to be Value, not Ref.
pub type Resolved {
  Resolved
}

/// A value that may be a $ref string or a concrete definition.
/// At Unresolved stage, both Ref and Value may appear.
/// At Resolved stage, only Value is present (enforced by resolve).
pub type RefOr(a) {
  Ref(String)
  Value(a)
}

/// Unwrap a RefOr assuming it has been resolved. Panics on Ref.
///
/// Callers are expected to hold a `RefOr(a)` from an `OpenApiSpec(Resolved)`
/// subtree; the resolve phase statically eliminates `Ref(_)` before this
/// runs, so reaching the `Ref` branch would indicate an internal invariant
/// violation rather than a user-facing error.
pub fn unwrap_ref(ref_or: RefOr(a)) -> a {
  case ref_or {
    Value(v) -> v
    // nolint: avoid_panic -- invariant: resolve phase eliminates Ref(_) in Resolved subtrees; reaching this branch is a compiler/internal bug
    Ref(r) -> panic as { "unwrap_ref on unresolved $ref: " <> r }
  }
}

// ============================================================================
// Top-level spec
// ============================================================================

/// Top-level OpenAPI 3.x specification.
pub type OpenApiSpec(stage) {
  OpenApiSpec(
    openapi: String,
    info: Info,
    paths: Dict(String, RefOr(PathItem(stage))),
    components: Option(Components(stage)),
    servers: List(Server),
    security: List(SecurityRequirement),
    webhooks: Dict(String, RefOr(PathItem(stage))),
    tags: List(Tag),
    external_docs: Option(ExternalDoc),
    json_schema_dialect: Option(String),
  )
}

// ============================================================================
// Metadata types (no stage parameter)
// ============================================================================

/// API metadata.
pub type Info {
  Info(
    title: String,
    description: Option(String),
    version: String,
    summary: Option(String),
    terms_of_service: Option(String),
    contact: Option(Contact),
    license: Option(License),
  )
}

/// Contact information for the API.
pub type Contact {
  Contact(name: Option(String), url: Option(String), email: Option(String))
}

/// License information for the API.
pub type License {
  License(name: String, url: Option(String))
}

/// Server object.
pub type Server {
  Server(
    url: String,
    description: Option(String),
    variables: Dict(String, ServerVariable),
  )
}

/// A server variable for server URL template substitution.
pub type ServerVariable {
  ServerVariable(
    default: String,
    enum_values: List(String),
    description: Option(String),
  )
}

/// An external documentation reference.
pub type ExternalDoc {
  ExternalDoc(url: String, description: Option(String))
}

/// A tag for API documentation control.
pub type Tag {
  Tag(
    name: String,
    description: Option(String),
    external_docs: Option(ExternalDoc),
  )
}

// ============================================================================
// Components (stage-typed)
// ============================================================================

/// Components section containing reusable schemas, parameters, etc.
pub type Components(stage) {
  Components(
    schemas: Dict(String, SchemaRef),
    parameters: Dict(String, RefOr(Parameter(stage))),
    request_bodies: Dict(String, RefOr(RequestBody(stage))),
    responses: Dict(String, RefOr(Response(stage))),
    security_schemes: Dict(String, RefOr(SecurityScheme)),
    path_items: Dict(String, RefOr(PathItem(stage))),
    headers: Dict(String, Header),
    examples: Dict(String, JsonValue),
    links: Dict(String, Link),
  )
}

// ============================================================================
// Security types (no stage parameter)
// ============================================================================

/// Location for apiKey security scheme.
pub type SecuritySchemeIn {
  SchemeInHeader
  SchemeInQuery
  SchemeInCookie
}

/// Parameter serialization style (OpenAPI 3.x).
pub type ParameterStyle {
  FormStyle
  SimpleStyle
  DeepObjectStyle
  MatrixStyle
  LabelStyle
  SpaceDelimitedStyle
  PipeDelimitedStyle
}

/// Security scheme definition.
pub type SecurityScheme {
  ApiKeyScheme(name: String, in_: SecuritySchemeIn)
  HttpScheme(scheme: String, bearer_format: Option(String))
  OAuth2Scheme(description: Option(String), flows: Dict(String, OAuth2Flow))
  OpenIdConnectScheme(open_id_connect_url: String, description: Option(String))
  /// Parsed but unsupported scheme type (e.g. mutualTLS).
  /// Preserved losslessly; capability_check will reject it.
  UnsupportedScheme(scheme_type: String)
}

/// An OAuth2 flow definition.
pub type OAuth2Flow {
  OAuth2Flow(
    authorization_url: Option(String),
    token_url: Option(String),
    refresh_url: Option(String),
    scopes: Dict(String, String),
  )
}

/// A single scheme reference within a security requirement (AND element).
pub type SecuritySchemeRef {
  SecuritySchemeRef(scheme_name: String, scopes: List(String))
}

/// A security requirement.
pub type SecurityRequirement {
  SecurityRequirement(schemes: List(SecuritySchemeRef))
}

// ============================================================================
// Path and Operation types (stage-typed)
// ============================================================================

/// A path item containing operations for each HTTP method.
pub type PathItem(stage) {
  PathItem(
    summary: Option(String),
    description: Option(String),
    get: Option(Operation(stage)),
    post: Option(Operation(stage)),
    put: Option(Operation(stage)),
    delete: Option(Operation(stage)),
    patch: Option(Operation(stage)),
    head: Option(Operation(stage)),
    options: Option(Operation(stage)),
    trace: Option(Operation(stage)),
    parameters: List(RefOr(Parameter(stage))),
    servers: List(Server),
  )
}

/// An API operation (endpoint).
pub type Operation(stage) {
  Operation(
    operation_id: Option(String),
    summary: Option(String),
    description: Option(String),
    tags: List(String),
    parameters: List(RefOr(Parameter(stage))),
    request_body: Option(RefOr(RequestBody(stage))),
    responses: Dict(http.HttpStatusCode, RefOr(Response(stage))),
    deprecated: Bool,
    security: Option(List(SecurityRequirement)),
    callbacks: Dict(String, Callback(stage)),
    servers: List(Server),
    external_docs: Option(ExternalDoc),
  )
}

/// A callback object: maps URL expressions to PathItems.
pub type Callback(stage) {
  Callback(entries: Dict(String, RefOr(PathItem(stage))))
}

/// Parameter location.
pub type ParameterIn {
  InPath
  InQuery
  InHeader
  InCookie
}

/// How a parameter carries its type information.
pub type ParameterPayload {
  /// Parameter defined via a JSON Schema.
  ParameterSchema(SchemaRef)
  /// Parameter defined via content media type map (mutually exclusive with schema).
  ParameterContent(Dict(String, MediaType))
}

/// An API parameter. Stage parameter is phantom.
pub type Parameter(stage) {
  Parameter(
    name: String,
    in_: ParameterIn,
    description: Option(String),
    required: Bool,
    payload: ParameterPayload,
    style: Option(ParameterStyle),
    explode: Option(Bool),
    deprecated: Bool,
    allow_reserved: Bool,
    examples: Dict(String, JsonValue),
  )
}

/// Extract the schema from a parameter's payload, if it uses schema encoding.
pub fn parameter_schema(param: Parameter(stage)) -> Option(SchemaRef) {
  case param.payload {
    ParameterSchema(s) -> option.Some(s)
    ParameterContent(_) -> option.None
  }
}

/// A request body definition. Stage parameter is phantom.
pub type RequestBody(stage) {
  RequestBody(
    description: Option(String),
    content: Dict(String, MediaType),
    required: Bool,
  )
}

/// Media type definition.
pub type MediaType {
  MediaType(
    schema: Option(SchemaRef),
    example: Option(JsonValue),
    examples: Dict(String, JsonValue),
    encoding: Dict(String, Encoding),
  )
}

/// Encoding definition for a media type property.
pub type Encoding {
  Encoding(
    content_type: Option(String),
    style: Option(ParameterStyle),
    explode: Option(Bool),
  )
}

/// Header definition for responses or components.
pub type Header {
  Header(description: Option(String), required: Bool, schema: Option(SchemaRef))
}

/// Link definition for responses or components.
pub type Link {
  Link(operation_id: Option(String), description: Option(String))
}

/// A response definition. Stage parameter is phantom.
pub type Response(stage) {
  Response(
    description: Option(String),
    content: Dict(String, MediaType),
    headers: Dict(String, Header),
    links: Dict(String, Link),
  )
}

// ============================================================================
// HTTP method
// ============================================================================

/// HTTP method enumeration.
pub type HttpMethod {
  Get
  Post
  Put
  Delete
  Patch
  Head
  Options
  Trace
}

/// Convert HTTP method to string.
pub fn method_to_string(method: HttpMethod) -> String {
  case method {
    Get -> "GET"
    Post -> "POST"
    Put -> "PUT"
    Delete -> "DELETE"
    Patch -> "PATCH"
    Head -> "HEAD"
    Options -> "OPTIONS"
    Trace -> "TRACE"
  }
}

/// Convert HTTP method to lowercase string.
pub fn method_to_lower(method: HttpMethod) -> String {
  case method {
    Get -> "get"
    Post -> "post"
    Put -> "put"
    Delete -> "delete"
    Patch -> "patch"
    Head -> "head"
    Options -> "options"
    Trace -> "trace"
  }
}
