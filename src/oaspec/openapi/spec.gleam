import gleam/dict.{type Dict}
import gleam/option.{type Option}
import oaspec/openapi/schema.{type SchemaRef}

/// Top-level OpenAPI 3.x specification.
pub type OpenApiSpec {
  OpenApiSpec(
    openapi: String,
    info: Info,
    paths: Dict(String, PathItem),
    components: Option(Components),
    servers: List(Server),
    security: List(SecurityRequirement),
    webhooks: Dict(String, PathItem),
    tags: List(Tag),
    external_docs: Option(ExternalDoc),
    json_schema_dialect: Option(String),
  )
}

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

/// Components section containing reusable schemas, parameters, etc.
pub type Components {
  Components(
    schemas: Dict(String, SchemaRef),
    parameters: Dict(String, Parameter),
    request_bodies: Dict(String, RequestBody),
    responses: Dict(String, Response),
    security_schemes: Dict(String, SecurityScheme),
    path_items: Dict(String, PathItem),
    headers: Dict(String, Header),
    examples: Dict(String, String),
    links: Dict(String, Link),
  )
}

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

/// A security requirement: all schemes in the list must be satisfied (AND).
/// The outer list in operation/top-level security is OR — any one
/// SecurityRequirement suffices.
pub type SecurityRequirement {
  SecurityRequirement(schemes: List(SecuritySchemeRef))
}

/// A path item containing operations for each HTTP method.
pub type PathItem {
  PathItem(
    summary: Option(String),
    description: Option(String),
    get: Option(Operation),
    post: Option(Operation),
    put: Option(Operation),
    delete: Option(Operation),
    patch: Option(Operation),
    head: Option(Operation),
    options: Option(Operation),
    trace: Option(Operation),
    parameters: List(Parameter),
    servers: List(Server),
  )
}

/// An API operation (endpoint).
pub type Operation {
  Operation(
    operation_id: Option(String),
    summary: Option(String),
    description: Option(String),
    tags: List(String),
    parameters: List(Parameter),
    request_body: Option(RequestBody),
    responses: Dict(String, Response),
    deprecated: Bool,
    security: Option(List(SecurityRequirement)),
    callbacks: Dict(String, Callback),
    servers: List(Server),
    external_docs: Option(ExternalDoc),
  )
}

/// A callback object: maps URL expressions to PathItems.
/// An OpenAPI callback can have multiple URL expressions.
pub type Callback {
  Callback(entries: Dict(String, PathItem))
}

/// Parameter location.
pub type ParameterIn {
  InPath
  InQuery
  InHeader
  InCookie
}

/// An API parameter.
pub type Parameter {
  Parameter(
    name: String,
    in_: ParameterIn,
    description: Option(String),
    required: Bool,
    schema: Option(SchemaRef),
    style: Option(ParameterStyle),
    explode: Option(Bool),
    deprecated: Bool,
    allow_reserved: Bool,
    content: Dict(String, MediaType),
    examples: Dict(String, String),
  )
}

/// A request body definition.
pub type RequestBody {
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
    example: Option(String),
    examples: Dict(String, String),
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

/// A response definition.
pub type Response {
  Response(
    description: Option(String),
    content: Dict(String, MediaType),
    headers: Dict(String, Header),
    links: Dict(String, Link),
  )
}

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
