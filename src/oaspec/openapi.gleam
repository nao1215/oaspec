//// The OpenAPI document as oaspec reads it, and the diagnostics oaspec
//// reports about it.
////
//// `oaspec.parse_file` and `oaspec.parse_string` return an
//// `OpenApiSpec(Unresolved)`; `oaspec.resolve` turns it into an
//// `OpenApiSpec(Resolved)` in which every `RefOr` is a `Value`. Every
//// failure and warning is a `Diagnostic`.

import gleam/dict.{type Dict}
import gleam/int
import gleam/option.{type Option, None, Some}

// ---------------------------------------------------------------------------
// Document
// ---------------------------------------------------------------------------

/// Marks a document whose `RefOr` values may still be `Ref`.
pub type Unresolved {
  Unresolved
}

/// Marks a document returned by `oaspec.resolve`, whose `RefOr` values are
/// all `Value`.
pub type Resolved {
  Resolved
}

/// A definition given inline (`Value`) or by `$ref` (`Ref`).
pub type RefOr(a) {
  Ref(String)
  Value(a)
}

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
    callbacks: Dict(String, RefOr(Callback(stage))),
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
  /// A scheme type oaspec cannot generate code for. Parsing produces it
  /// only for OAS 3.1 `mutualTLS`; other unknown types fail to parse, and
  /// `oaspec.generate` rejects this variant.
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
    responses: Dict(HttpStatusCode, RefOr(Response(stage))),
    deprecated: Bool,
    security: Option(List(SecurityRequirement)),
    callbacks: Dict(String, RefOr(Callback(stage))),
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

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------

/// Where a schema came from. Schemas read from the document are
/// `UserAuthored`; the other variants mark schemas oaspec lifted out of an
/// inline definition while generating code, and say where they were.
pub type OriginKind {
  UserAuthored
  HoistedProperty(parent: String, property: String)
  HoistedArrayItem(parent: String)
  HoistedOneOfVariant(parent: String, index: Int)
  HoistedAnyOfVariant(parent: String, index: Int)
  HoistedAllOfPart(parent: String, index: Int)
  HoistedRequestBody(operation_id: String)
  HoistedResponse(operation_id: String, status: String)
  HoistedParameter(operation_id: String, name: String)
  HoistedAdditionalProperties(parent: String)
}

/// The keywords every schema can carry. Every `SchemaObject` variant has it
/// as its `metadata` field, so `schema.metadata` works on any variant.
pub type SchemaMetadata {
  SchemaMetadata(
    description: Option(String),
    nullable: Bool,
    deprecated: Bool,
    title: Option(String),
    read_only: Bool,
    write_only: Bool,
    default: Option(JsonValue),
    example: Option(JsonValue),
    const_value: Option(JsonValue),
    raw_type: Option(List(String)),
    unsupported_keywords: List(String),
    internal: Bool,
    provenance: OriginKind,
  )
}

/// How additionalProperties is modeled in the AST.
pub type AdditionalProperties {
  /// additionalProperties: false (extra keys rejected)
  Forbidden
  /// additionalProperties: true (accept any JSON value, surfaced in
  /// generated types as `Dict(String, Dynamic)`)
  Untyped
  /// additionalProperties: { schema } (typed dict in generated types)
  Typed(SchemaRef)
  /// additionalProperties key absent from the spec. Per JSON Schema
  /// any extra keys are still permitted at runtime, but the generated
  /// record does not surface them — users opt in by writing `true` or
  /// a schema explicitly.
  Unspecified
}

/// Represents a JSON Schema object within OpenAPI 3.x.
/// This is the core building block for all type generation.
/// All variants carry shared `metadata` for description, nullable, deprecated.
pub type SchemaObject {
  StringSchema(
    metadata: SchemaMetadata,
    format: Option(String),
    enum_values: List(String),
    min_length: Option(Int),
    max_length: Option(Int),
    pattern: Option(String),
  )
  IntegerSchema(
    metadata: SchemaMetadata,
    format: Option(String),
    minimum: Option(Int),
    maximum: Option(Int),
    exclusive_minimum: Option(Int),
    exclusive_maximum: Option(Int),
    multiple_of: Option(Int),
  )
  NumberSchema(
    metadata: SchemaMetadata,
    format: Option(String),
    minimum: Option(Float),
    maximum: Option(Float),
    exclusive_minimum: Option(Float),
    exclusive_maximum: Option(Float),
    multiple_of: Option(Float),
  )
  BooleanSchema(metadata: SchemaMetadata)
  ArraySchema(
    metadata: SchemaMetadata,
    items: SchemaRef,
    min_items: Option(Int),
    max_items: Option(Int),
    unique_items: Bool,
  )
  ObjectSchema(
    metadata: SchemaMetadata,
    properties: Dict(String, SchemaRef),
    required: List(String),
    additional_properties: AdditionalProperties,
    min_properties: Option(Int),
    max_properties: Option(Int),
  )
  AllOfSchema(metadata: SchemaMetadata, schemas: List(SchemaRef))
  OneOfSchema(
    metadata: SchemaMetadata,
    schemas: List(SchemaRef),
    discriminator: Option(Discriminator),
  )
  AnyOfSchema(
    metadata: SchemaMetadata,
    schemas: List(SchemaRef),
    discriminator: Option(Discriminator),
  )
}

/// A schema given inline or by `$ref`. `Reference` keeps the whole `$ref`
/// string and its last segment as `name`, such as `"Pet"` for
/// `"#/components/schemas/Pet"`.
pub type SchemaRef {
  Inline(SchemaObject)
  Reference(ref: String, name: String)
}

/// OpenAPI discriminator for oneOf/anyOf.
pub type Discriminator {
  Discriminator(property_name: String, mapping: Dict(String, String))
}

/// A JSON-compatible value type for preserving arbitrary data from OpenAPI specs.
/// Used for example, default, const, and other values that aren't necessarily strings.
pub type JsonValue {
  JsonNull
  JsonBool(Bool)
  JsonInt(Int)
  JsonFloat(Float)
  JsonString(String)
  JsonArray(List(JsonValue))
  JsonObject(Dict(String, JsonValue))
}

/// Type-safe HTTP status code representation.
/// Replaces raw String status codes throughout the codebase.
pub type HttpStatusCode {
  /// An exact HTTP status code, e.g. 200, 404, 500.
  Status(Int)
  /// A wildcard range, e.g. 2XX is StatusRange(2), 4XX is StatusRange(4).
  StatusRange(Int)
  /// The OpenAPI "default" catch-all response.
  DefaultStatus
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

/// The step of parsing or generation that reported a diagnostic.
pub type Phase {
  PhaseParse
  PhaseNormalize
  PhaseResolve
  PhaseCapabilityCheck
  PhaseValidate
  PhaseCodegen
}

/// Whether a diagnostic stops generation (`SeverityError`) or is only
/// reported (`SeverityWarning`).
pub type Severity {
  SeverityError
  SeverityWarning
}

/// Which generated side a diagnostic applies to. Diagnostics for the side
/// a config does not generate are dropped.
pub type Target {
  TargetBoth
  TargetClient
  TargetServer
}

/// The line and column in the YAML document a diagnostic points at. JSON
/// documents and checks that run after parsing give `NoSourceLoc`.
pub type SourceLoc {
  SourceLoc(line: Int, column: Int)
  NoSourceLoc
}

/// An error or warning about a document. `code` is a stable identifier
/// such as `"missing_field"`, `pointer` is the JSON pointer of the node
/// (empty when there is none), and `hint` suggests a fix.
pub type Diagnostic {
  Diagnostic(
    code: String,
    phase: Phase,
    severity: Severity,
    target: Target,
    pointer: String,
    source_loc: SourceLoc,
    message: String,
    hint: Option(String),
  )
}

/// Returns a one-line description of a diagnostic, with its phase,
/// severity, pointer, location and hint.
///
/// ## Examples
///
/// ```gleam
/// openapi.Diagnostic(
///   code: "missing_field",
///   phase: openapi.PhaseParse,
///   severity: openapi.SeverityError,
///   target: openapi.TargetBoth,
///   pointer: "info",
///   source_loc: openapi.SourceLoc(line: 3, column: 3),
///   message: "Missing required field: title",
///   hint: None,
/// )
/// |> openapi.diagnostic_to_string
/// // -> "[Parse] Error at info: Missing required field: title (line 3, column 3)"
/// ```
///
pub fn diagnostic_to_string(d: Diagnostic) -> String {
  let phase_str = case d.phase {
    PhaseParse -> "Parse"
    PhaseNormalize -> "Normalize"
    PhaseResolve -> "Resolve"
    PhaseCapabilityCheck -> "CapabilityCheck"
    PhaseValidate -> "Validate"
    PhaseCodegen -> "Codegen"
  }
  let severity_str = case d.severity {
    SeverityError -> "Error"
    SeverityWarning -> "Warning"
  }
  let loc_str = case d.source_loc {
    SourceLoc(line:, column:) ->
      " (line "
      <> int.to_string(line)
      <> ", column "
      <> int.to_string(column)
      <> ")"
    NoSourceLoc -> ""
  }
  let pointer_str = case d.pointer {
    "" -> ""
    p -> " at " <> p
  }
  let hint_str = case d.hint {
    Some(h) -> " " <> h
    None -> ""
  }
  "["
  <> phase_str
  <> "] "
  <> severity_str
  <> pointer_str
  <> ": "
  <> d.message
  <> loc_str
  <> hint_str
}
