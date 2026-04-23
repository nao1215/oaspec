import gleam/bool
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oaspec/openapi/diagnostic.{type Diagnostic, NoSourceLoc, SourceLoc}
import oaspec/openapi/external_loader
import oaspec/openapi/location_index.{type LocationIndex}
import oaspec/openapi/parser_error
import oaspec/openapi/parser_schema
import oaspec/openapi/schema.{type SchemaRef}
import oaspec/openapi/spec.{
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
import oaspec/openapi/value
import oaspec/util/http
import simplifile
import yay

/// Parse an OpenAPI spec from a file path.
/// Supports both YAML (.yaml, .yml) and JSON (.json) files.
/// After parsing, resolves relative-file `$ref` values in
/// `components.schemas` by loading the referenced files from disk and
/// merging their schemas. Nested or parameter/response external refs are
/// left to downstream validation.
pub fn parse_file(path: String) -> Result(OpenApiSpec(Unresolved), Diagnostic) {
  parse_file_internal(path, [])
}

/// Internal parse entry that threads the `visited` stack through every
/// external-ref recursion so `A.yaml -> B.yaml -> A.yaml` cycles fail
/// fast with a dedicated diagnostic instead of spinning forever.
fn parse_file_internal(
  path: String,
  visited: List(String),
) -> Result(OpenApiSpec(Unresolved), Diagnostic) {
  let canonical = canonicalize_ref_path(path)
  use <- bool.guard(
    list.contains(visited, canonical),
    Error(cyclic_external_ref_diagnostic(canonical, visited)),
  )

  use content <- result.try(
    simplifile.read(path)
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

  use spec <- result.try(parse_string(content))
  let new_visited = [canonical, ..visited]
  external_loader.resolve_external_component_refs(
    spec,
    external_loader.base_dir_of(path),
    fn(sub_path) { parse_file_internal(sub_path, new_visited) },
  )
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

/// Parse an OpenAPI spec from a YAML/JSON string.
pub fn parse_string(
  content: String,
) -> Result(OpenApiSpec(Unresolved), Diagnostic) {
  use docs <- result.try(
    yay.parse_string(content)
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
  parse_root(root, index)
}

/// Parse the root OpenAPI object.
fn parse_root(
  node: yay.Node,
  index: LocationIndex,
) -> Result(OpenApiSpec(Unresolved), Diagnostic) {
  // openapi field may be a string ("3.0.3") or a YAML number (3.0 parsed as float)
  use openapi <- result.try(
    yay.extract_string(node, "openapi")
    |> result.lazy_or(fn() {
      yay.extract_float(node, "openapi")
      |> result.map(fn(f) {
        case f == int.to_float(float.truncate(f)) {
          True -> int.to_string(float.truncate(f)) <> ".0"
          False -> float.to_string(f)
        }
      })
    })
    |> result.map_error(parser_error.missing_field_from_extraction(
      _,
      path: "",
      field: "openapi",
      loc: location_index.lookup_field(index, "", "openapi"),
    )),
  )

  use _ <- result.try(validate_openapi_version(
    openapi,
    location_index.lookup_field(index, "", "openapi"),
  ))

  use info <- result.try(parse_info(node, index))

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
    yay.extract_optional_string(node, "jsonSchemaDialect")
    |> result.unwrap(None)

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
    // Two-segment "3.0" / "3.1" is tolerated: float-parsed YAML numbers
    // like `openapi: 3.0` arrive as "3.0" after normalization.
    ["3", "0"] | ["3", "1"] -> True
    _ -> False
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
    |> result.map_error(parser_error.missing_field_from_selector(
      _,
      path: "",
      field: "info",
      loc: location_index.lookup_field(index, "", "info"),
    )),
  )

  use title <- result.try(
    yay.extract_string(info_node, "title")
    |> result.map_error(parser_error.missing_field_from_extraction(
      _,
      path: "info",
      field: "title",
      loc: location_index.lookup_field(index, "info", "title"),
    )),
  )

  use version <- result.try(
    yay.extract_string(info_node, "version")
    |> result.map_error(parser_error.missing_field_from_extraction(
      _,
      path: "info",
      field: "version",
      loc: location_index.lookup_field(index, "info", "version"),
    )),
  )

  let description =
    yay.extract_optional_string(info_node, "description")
    |> result.unwrap(None)

  let summary =
    yay.extract_optional_string(info_node, "summary")
    |> result.unwrap(None)

  let terms_of_service =
    yay.extract_optional_string(info_node, "termsOfService")
    |> result.unwrap(None)

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
    |> result.map_error(parser_error.missing_field_from_extraction(
      _,
      path: "servers",
      field: "url",
      loc: location_index.lookup_field(index, "servers", "url"),
    )),
  )

  let description =
    yay.extract_optional_string(node, "description")
    |> result.unwrap(None)

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
                // Check for $ref first — resolve from components.pathItems
                use ref_or_path_item <- result.try(
                  case
                    yay.extract_optional_string(value_node, "$ref")
                    |> result.unwrap(None)
                  {
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
    _ -> Ok(dict.new())
  }
}

/// Parse a single path item.
fn parse_path_item(
  node: yay.Node,
  path: String,
  components: Option(Components(Unresolved)),
  index: LocationIndex,
) -> Result(PathItem(Unresolved), Diagnostic) {
  let summary =
    yay.extract_optional_string(node, "summary")
    |> result.unwrap(None)

  let description =
    yay.extract_optional_string(node, "description")
    |> result.unwrap(None)

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
    |> result.map_error(parser_error.missing_field_from_selector(
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
  let operation_id =
    yay.extract_optional_string(node, "operationId")
    |> result.unwrap(None)

  let summary =
    yay.extract_optional_string(node, "summary")
    |> result.unwrap(None)

  let description =
    yay.extract_optional_string(node, "description")
    |> result.unwrap(None)

  let tags = case yay.extract_string_list(node, "tags") {
    Ok(t) -> t
    _ -> []
  }

  let deprecated =
    yay.extract_optional_bool(node, "deprecated")
    |> result.unwrap(None)
    |> option.unwrap(False)

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
        |> result.map_error(parser_error.missing_field_from_extraction(
          _,
          path: "parameter",
          field: "name",
          loc: location_index.lookup_field(index, "parameter", "name"),
        )),
      )

      use in_str <- result.try(
        yay.extract_string(node, "in")
        |> result.map_error(parser_error.missing_field_from_extraction(
          _,
          path: "parameter." <> name,
          field: "in",
          loc: location_index.lookup_field(index, "parameter." <> name, "in"),
        )),
      )

      use in_ <- result.try(parse_parameter_in(in_str, index))

      let description =
        yay.extract_optional_string(node, "description")
        |> result.unwrap(None)

      let explicit_required =
        yay.extract_optional_bool(node, "required")
        |> result.unwrap(None)

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

      let deprecated =
        yay.extract_optional_bool(node, "deprecated")
        |> result.unwrap(None)
        |> option.unwrap(False)

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

      use style <- result.try(
        case
          yay.extract_optional_string(node, "style")
          |> result.unwrap(None)
        {
          Some(s) -> {
            use parsed <- result.try(parse_parameter_style(s, index))
            Ok(Some(parsed))
          }
          None -> Ok(None)
        },
      )

      let explode =
        yay.extract_optional_bool(node, "explode")
        |> result.unwrap(None)

      let allow_reserved =
        yay.extract_optional_bool(node, "allowReserved")
        |> result.unwrap(None)
        |> option.unwrap(False)

      use content <- result.try(parse_content_map(node, index))
      let examples = value.extract_map(node, "examples")

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
    |> result.map_error(parser_error.missing_field_from_selector(
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
  let description =
    yay.extract_optional_string(node, "description")
    |> result.unwrap(None)

  let required =
    yay.extract_optional_bool(node, "required")
    |> result.unwrap(None)
    |> option.unwrap(False)

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
            let mt_example = value.extract_optional(value_node, "example")
            let mt_examples = value.extract_map(value_node, "examples")
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
            let mt_example = value.extract_optional(value_node, "example")
            let mt_examples = value.extract_map(value_node, "examples")
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
                  // nolint: thrown_away_error -- tolerant parse; unparsable status codes (including "default") are handled elsewhere
                  Error(_) -> Ok(acc)
                }
            }
          yay.NodeInt(code) -> {
            use resp <- result.try(parse_response(value_node, components, index))
            Ok(dict.insert(acc, http.Status(code), resp))
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
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
        |> result.map_error(parser_error.missing_field_from_extraction(
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
    |> result.map_error(parser_error.missing_field_from_selector(
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
  let examples = value.extract_map(components_node, "examples")
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
    |> result.map_error(parser_error.missing_field_from_extraction(
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
        |> result.map_error(parser_error.missing_field_from_extraction(
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
        |> result.map_error(parser_error.missing_field_from_extraction(
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
        |> result.map_error(parser_error.missing_field_from_extraction(
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
      let bearer_format =
        yay.extract_optional_string(node, "bearerFormat")
        |> result.unwrap(None)
      Ok(spec.HttpScheme(scheme:, bearer_format:))
    }
    "oauth2" -> {
      let description =
        yay.extract_optional_string(node, "description")
        |> result.unwrap(None)
      let flows = parse_oauth2_flows(node)
      Ok(spec.OAuth2Scheme(description:, flows:))
    }
    "openIdConnect" -> {
      let description =
        yay.extract_optional_string(node, "description")
        |> result.unwrap(None)
      use open_id_connect_url <- result.try(
        yay.extract_string(node, "openIdConnectUrl")
        |> result.map_error(parser_error.missing_field_from_extraction(
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
              yay.extract_optional_string(flow_node, "authorizationUrl")
              |> result.unwrap(None)
            let token_url =
              yay.extract_optional_string(flow_node, "tokenUrl")
              |> result.unwrap(None)
            let refresh_url =
              yay.extract_optional_string(flow_node, "refreshUrl")
              |> result.unwrap(None)
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
              case
                yay.extract_optional_string(path_item_node, "$ref")
                |> result.unwrap(None)
              {
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
      let name =
        yay.extract_optional_string(contact_node, "name")
        |> result.unwrap(None)
      let url =
        yay.extract_optional_string(contact_node, "url")
        |> result.unwrap(None)
      let email =
        yay.extract_optional_string(contact_node, "email")
        |> result.unwrap(None)
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
          let url =
            yay.extract_optional_string(license_node, "url")
            |> result.unwrap(None)
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
            let default =
              yay.extract_optional_string(value_node, "default")
              |> result.unwrap(None)
              |> option.unwrap("")
            let enum_values = case yay.extract_string_list(value_node, "enum") {
              Ok(values) -> values
              _ -> []
            }
            let description =
              yay.extract_optional_string(value_node, "description")
              |> result.unwrap(None)
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
            yay.extract_optional_string(doc_node, "description")
            |> result.unwrap(None)
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
              yay.extract_optional_string(tag_node, "description")
              |> result.unwrap(None)
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
            case
              yay.extract_optional_string(value_node, "$ref")
              |> result.unwrap(None)
            {
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
            let mt_example = value.extract_optional(value_node, "example")
            let mt_examples = value.extract_map(value_node, "examples")
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
              yay.extract_optional_string(value_node, "contentType")
              |> result.unwrap(None)
            use style <- result.try(
              case
                yay.extract_optional_string(value_node, "style")
                |> result.unwrap(None)
              {
                Some(s) -> {
                  use parsed <- result.try(parse_parameter_style(s, index))
                  Ok(Some(parsed))
                }
                None -> Ok(None)
              },
            )
            let explode =
              yay.extract_optional_bool(value_node, "explode")
              |> result.unwrap(None)
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
              yay.extract_optional_string(value_node, "description")
              |> result.unwrap(None)
            let required =
              yay.extract_optional_bool(value_node, "required")
              |> result.unwrap(None)
              |> option.unwrap(False)
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
              yay.extract_optional_string(value_node, "operationId")
              |> result.unwrap(None)
            let description =
              yay.extract_optional_string(value_node, "description")
              |> result.unwrap(None)
            Ok(dict.insert(acc, link_name, Link(operation_id:, description:)))
          }
          _ -> Ok(acc)
        }
      })
    _ -> Ok(dict.new())
  }
}
