import gleam/dict.{type Dict}
import gleam/option.{type Option}
import gleam_oas/openapi/schema.{type SchemaRef}

/// Top-level OpenAPI 3.x specification.
pub type OpenApiSpec {
  OpenApiSpec(
    openapi: String,
    info: Info,
    paths: Dict(String, PathItem),
    components: Option(Components),
    servers: List(Server),
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
  )
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
