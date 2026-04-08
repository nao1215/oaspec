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
  )
}

/// API metadata.
pub type Info {
  Info(title: String, description: Option(String), version: String)
}

/// Server object.
pub type Server {
  Server(url: String, description: Option(String))
}

/// Components section containing reusable schemas, parameters, etc.
pub type Components {
  Components(
    schemas: Dict(String, SchemaRef),
    parameters: Dict(String, Parameter),
    request_bodies: Dict(String, RequestBody),
    responses: Dict(String, Response),
    security_schemes: Dict(String, SecurityScheme),
  )
}

/// Security scheme definition.
pub type SecurityScheme {
  ApiKeyScheme(name: String, in_: String)
  HttpScheme(scheme: String, bearer_format: Option(String))
  OAuth2Scheme(description: Option(String))
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
    parameters: List(Parameter),
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
  )
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
    style: Option(String),
    deprecated: Bool,
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
  MediaType(schema: Option(SchemaRef))
}

/// A response definition.
pub type Response {
  Response(description: Option(String), content: Dict(String, MediaType))
}

/// HTTP method enumeration.
pub type HttpMethod {
  Get
  Post
  Put
  Delete
  Patch
}

/// Convert HTTP method to string.
pub fn method_to_string(method: HttpMethod) -> String {
  case method {
    Get -> "GET"
    Post -> "POST"
    Put -> "PUT"
    Delete -> "DELETE"
    Patch -> "PATCH"
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
  }
}
