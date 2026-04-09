import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oaspec/openapi/schema.{
  type Discriminator, type SchemaObject, type SchemaRef, AllOfSchema,
  AnyOfSchema, ArraySchema, BooleanSchema, Discriminator, Inline, IntegerSchema,
  NumberSchema, ObjectSchema, OneOfSchema, StringSchema,
}
import oaspec/openapi/spec.{
  type Callback, type Components, type Contact, type Encoding, type ExternalDoc,
  type Header, type HttpMethod, type Info, type License, type Link,
  type MediaType, type OpenApiSpec, type Operation, type Parameter,
  type ParameterIn, type PathItem, type RequestBody, type Response,
  type SecurityRequirement, type Server, type ServerVariable, type Tag, Callback,
  Components, Contact, Delete, Encoding, ExternalDoc, Get, Head, Header, Info,
  License, Link, MediaType, OpenApiSpec, Operation, Options, Parameter, Patch,
  PathItem, Post, Put, RequestBody, Response, SecurityRequirement, Server,
  ServerVariable, Tag, Trace,
}
import simplifile
import yay

/// Errors that can occur during OpenAPI spec parsing.
pub type ParseError {
  FileError(detail: String)
  YamlError(detail: String)
  MissingField(path: String, field: String)
  InvalidValue(path: String, detail: String)
}

/// Parse an OpenAPI spec from a file path.
/// Supports both YAML (.yaml, .yml) and JSON (.json) files.
pub fn parse_file(path: String) -> Result(OpenApiSpec, ParseError) {
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) {
      FileError(detail: "Cannot read file: " <> path)
    }),
  )

  parse_string(content)
}

/// Parse an OpenAPI spec from a YAML/JSON string.
pub fn parse_string(content: String) -> Result(OpenApiSpec, ParseError) {
  use docs <- result.try(
    yay.parse_string(content)
    |> result.map_error(fn(e) { YamlError(detail: yaml_error_to_string(e)) }),
  )

  use doc <- result.try(case docs {
    [first, ..] -> Ok(first)
    [] -> Error(YamlError(detail: "Empty document"))
  })

  let root = yay.document_root(doc)
  parse_root(root)
}

/// Parse the root OpenAPI object.
fn parse_root(node: yay.Node) -> Result(OpenApiSpec, ParseError) {
  use openapi <- result.try(
    yay.extract_string(node, "openapi")
    |> result.map_error(fn(_) { MissingField(path: "", field: "openapi") }),
  )

  use info <- result.try(parse_info(node))

  // Parse components FIRST so we can resolve $ref during path parsing.
  // Components section is optional, but if present it must parse correctly.
  use components <- result.try(parse_optional_components(node))

  use paths <- result.try(parse_paths(node, components))
  use servers <- result.try(parse_servers(node))
  use security <- result.try(parse_security_requirements(node, ""))
  use webhooks <- result.try(parse_webhooks(node, components))
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

/// Parse optional components section.
/// Returns Ok(None) if not present, Ok(Some(..)) if valid, Error if malformed.
fn parse_optional_components(
  root: yay.Node,
) -> Result(Option(Components), ParseError) {
  case yay.select_sugar(from: root, selector: "components") {
    Ok(_) -> {
      use comps <- result.try(parse_components(root))
      Ok(Some(comps))
    }
    Error(_) -> Ok(None)
  }
}

/// Parse the info object.
fn parse_info(root: yay.Node) -> Result(Info, ParseError) {
  use info_node <- result.try(
    yay.select_sugar(from: root, selector: "info")
    |> result.map_error(fn(_) { MissingField(path: "", field: "info") }),
  )

  use title <- result.try(
    yay.extract_string(info_node, "title")
    |> result.map_error(fn(_) { MissingField(path: "info", field: "title") }),
  )

  use version <- result.try(
    yay.extract_string(info_node, "version")
    |> result.map_error(fn(_) { MissingField(path: "info", field: "version") }),
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
fn parse_servers(root: yay.Node) -> Result(List(Server), ParseError) {
  case yay.select_sugar(from: root, selector: "servers") {
    Ok(yay.NodeSeq(items)) -> list.try_map(items, parse_server)
    _ -> Ok([])
  }
}

/// Parse a single server object.
fn parse_server(node: yay.Node) -> Result(Server, ParseError) {
  use url <- result.try(
    yay.extract_string(node, "url")
    |> result.map_error(fn(_) { MissingField(path: "servers", field: "url") }),
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
  components: Option(Components),
) -> Result(Dict(String, PathItem), ParseError) {
  case yay.select_sugar(from: root, selector: "paths") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(path) -> {
            // Check for $ref first — resolve from components.pathItems
            use path_item <- result.try(
              case
                yay.extract_optional_string(value_node, "$ref")
                |> result.unwrap(None)
              {
                Some(ref_str) -> resolve_path_item_ref(ref_str, components)
                None -> parse_path_item(value_node, path, components)
              },
            )
            Ok(dict.insert(acc, path, path_item))
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
  components: Option(Components),
) -> Result(PathItem, ParseError) {
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
    Get,
    components,
  ))
  use post <- result.try(parse_optional_operation(
    node,
    "post",
    path,
    Post,
    components,
  ))
  use put <- result.try(parse_optional_operation(
    node,
    "put",
    path,
    Put,
    components,
  ))
  use delete <- result.try(parse_optional_operation(
    node,
    "delete",
    path,
    Delete,
    components,
  ))
  use patch <- result.try(parse_optional_operation(
    node,
    "patch",
    path,
    Patch,
    components,
  ))
  use head <- result.try(parse_optional_operation(
    node,
    "head",
    path,
    Head,
    components,
  ))
  use options <- result.try(parse_optional_operation(
    node,
    "options",
    path,
    Options,
    components,
  ))
  use trace <- result.try(parse_optional_operation(
    node,
    "trace",
    path,
    Trace,
    components,
  ))

  use parameters <- result.try(parse_parameters_list(node, components))
  use servers <- result.try(parse_servers(node))

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
  method: HttpMethod,
  components: Option(Components),
) -> Result(Option(Operation), ParseError) {
  case yay.select_sugar(from: node, selector: method_key) {
    Ok(_) -> {
      use op <- result.try(parse_operation_at(
        node,
        method_key,
        path,
        method,
        components,
      ))
      Ok(Some(op))
    }
    Error(_) -> Ok(None)
  }
}

/// Parse an operation at a specific HTTP method key.
fn parse_operation_at(
  node: yay.Node,
  method_key: String,
  path: String,
  _method: HttpMethod,
  components: Option(Components),
) -> Result(Operation, ParseError) {
  use op_node <- result.try(
    yay.select_sugar(from: node, selector: method_key)
    |> result.map_error(fn(_) { MissingField(path:, field: method_key) }),
  )

  parse_operation(op_node, path <> "." <> method_key, components)
}

/// Parse a single operation.
fn parse_operation(
  node: yay.Node,
  context: String,
  components: Option(Components),
) -> Result(Operation, ParseError) {
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

  use parameters <- result.try(parse_parameters_list(node, components))

  // requestBody is optional; absent is Ok(None), present-but-broken is Error.
  use request_body <- result.try(parse_optional_request_body(
    node,
    context,
    components,
  ))

  // responses is REQUIRED per OpenAPI 3.x
  use responses <- result.try(parse_responses_required(
    node,
    context,
    components,
  ))

  use security <- result.try(parse_optional_security_requirements(node, context))

  use callbacks <- result.try(parse_callbacks(node, context, components))
  use op_servers <- result.try(parse_servers(node))
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
  components: Option(Components),
) -> Result(Option(RequestBody), ParseError) {
  case yay.select_sugar(from: node, selector: "requestBody") {
    Ok(_) -> {
      use rb <- result.try(parse_request_body_at(node, context, components))
      Ok(Some(rb))
    }
    Error(_) -> Ok(None)
  }
}

/// Parse responses, requiring the field to be present.
fn parse_responses_required(
  node: yay.Node,
  context: String,
  components: Option(Components),
) -> Result(dict.Dict(String, Response), ParseError) {
  case yay.select_sugar(from: node, selector: "responses") {
    Ok(_) -> parse_responses(node, context, components)
    Error(_) -> Error(MissingField(path: context, field: "responses"))
  }
}

/// Parse parameters list from a node.
fn parse_parameters_list(
  node: yay.Node,
  components: Option(Components),
) -> Result(List(Parameter), ParseError) {
  case yay.select_sugar(from: node, selector: "parameters") {
    Ok(yay.NodeSeq(items)) ->
      list.try_map(items, fn(item) { parse_parameter(item, components) })
    _ -> Ok([])
  }
}

/// Parse a single parameter.
fn parse_parameter(
  node: yay.Node,
  components: Option(Components),
) -> Result(Parameter, ParseError) {
  // Check for $ref first
  case yay.extract_optional_string(node, "$ref") {
    Ok(Some(ref_str)) -> {
      resolve_parameter_ref(ref_str, components)
    }
    _ -> {
      use name <- result.try(
        yay.extract_string(node, "name")
        |> result.map_error(fn(_) {
          MissingField(path: "parameter", field: "name")
        }),
      )

      use in_str <- result.try(
        yay.extract_string(node, "in")
        |> result.map_error(fn(_) {
          MissingField(path: "parameter." <> name, field: "in")
        }),
      )

      use in_ <- result.try(parse_parameter_in(in_str))

      let description =
        yay.extract_optional_string(node, "description")
        |> result.unwrap(None)

      let explicit_required =
        yay.extract_optional_bool(node, "required")
        |> result.unwrap(None)

      // OpenAPI 3.x: path parameters MUST have required: true
      use required <- result.try(case in_, explicit_required {
        spec.InPath, Some(False) ->
          Error(InvalidValue(
            path: "parameter." <> name,
            detail: "Path parameters must have required: true",
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
            use sr <- result.try(parse_schema_ref(schema_node))
            Ok(Some(sr))
          }
          _ -> Ok(None)
        },
      )

      let style =
        yay.extract_optional_string(node, "style")
        |> result.unwrap(None)
        |> option.map(parse_parameter_style)

      let explode =
        yay.extract_optional_bool(node, "explode")
        |> result.unwrap(None)

      let allow_reserved =
        yay.extract_optional_bool(node, "allowReserved")
        |> result.unwrap(None)
        |> option.unwrap(False)

      let content = parse_content_map(node)
      let examples = parse_string_map(node, "examples")

      Ok(Parameter(
        name:,
        in_:,
        description:,
        required:,
        schema: param_schema,
        style:,
        explode:,
        deprecated:,
        allow_reserved:,
        content:,
        examples:,
      ))
    }
  }
}

/// Resolve a $ref for a parameter by looking it up in components.
fn resolve_parameter_ref(
  ref_str: String,
  components: Option(Components),
) -> Result(Parameter, ParseError) {
  let ref_name =
    ref_str
    |> string.split("/")
    |> list.last
    |> result.unwrap("unknown")

  case components {
    Some(comps) ->
      case dict.get(comps.parameters, ref_name) {
        Ok(param) -> Ok(param)
        Error(_) ->
          Error(InvalidValue(
            path: "parameter.$ref",
            detail: "Unresolved parameter reference: " <> ref_str,
          ))
      }
    None ->
      Error(InvalidValue(
        path: "parameter.$ref",
        detail: "No components to resolve reference: " <> ref_str,
      ))
  }
}

/// Resolve a $ref for a request body by looking it up in components.
fn resolve_request_body_ref(
  ref_str: String,
  components: Option(Components),
) -> Result(RequestBody, ParseError) {
  let ref_name =
    ref_str
    |> string.split("/")
    |> list.last
    |> result.unwrap("unknown")

  case components {
    Some(comps) ->
      case dict.get(comps.request_bodies, ref_name) {
        Ok(rb) -> Ok(rb)
        Error(_) ->
          Error(InvalidValue(
            path: "requestBody.$ref",
            detail: "Unresolved requestBody reference: " <> ref_str,
          ))
      }
    None ->
      Error(InvalidValue(
        path: "requestBody.$ref",
        detail: "No components to resolve reference: " <> ref_str,
      ))
  }
}

/// Resolve a $ref for a response by looking it up in components.
fn resolve_response_ref(
  ref_str: String,
  components: Option(Components),
) -> Result(Response, ParseError) {
  let ref_name =
    ref_str
    |> string.split("/")
    |> list.last
    |> result.unwrap("unknown")

  case components {
    Some(comps) ->
      case dict.get(comps.responses, ref_name) {
        Ok(resp) -> Ok(resp)
        Error(_) ->
          Error(InvalidValue(
            path: "response.$ref",
            detail: "Unresolved response reference: " <> ref_str,
          ))
      }
    None ->
      Error(InvalidValue(
        path: "response.$ref",
        detail: "No components to resolve reference: " <> ref_str,
      ))
  }
}

/// Parse parameter location string.
fn parse_parameter_in(value: String) -> Result(ParameterIn, ParseError) {
  case value {
    "path" -> Ok(spec.InPath)
    "query" -> Ok(spec.InQuery)
    "header" -> Ok(spec.InHeader)
    "cookie" -> Ok(spec.InCookie)
    _ ->
      Error(InvalidValue(
        path: "parameter.in",
        detail: "Unknown parameter location: "
          <> value
          <> ". Must be one of: path, query, header, cookie",
      ))
  }
}

/// Map a style string to a ParameterStyle ADT value.
fn parse_parameter_style(value: String) -> spec.ParameterStyle {
  case value {
    "form" -> spec.FormStyle
    "simple" -> spec.SimpleStyle
    "deepObject" -> spec.DeepObjectStyle
    "matrix" -> spec.MatrixStyle
    "label" -> spec.LabelStyle
    "spaceDelimited" -> spec.SpaceDelimitedStyle
    "pipeDelimited" -> spec.PipeDelimitedStyle
    // Unknown styles default to form (OpenAPI default for query)
    _ -> spec.FormStyle
  }
}

/// Map an apiKey "in" string to a SecuritySchemeIn ADT value.
fn parse_security_scheme_in(
  value: String,
) -> Result(spec.SecuritySchemeIn, ParseError) {
  case value {
    "header" -> Ok(spec.SchemeInHeader)
    "query" -> Ok(spec.SchemeInQuery)
    "cookie" -> Ok(spec.SchemeInCookie)
    _ ->
      Error(InvalidValue(
        path: "securityScheme.in",
        detail: "Unknown apiKey location: "
          <> value
          <> ". Must be one of: header, query, cookie",
      ))
  }
}

/// Parse requestBody from a node.
fn parse_request_body_at(
  node: yay.Node,
  context: String,
  components: Option(Components),
) -> Result(RequestBody, ParseError) {
  use rb_node <- result.try(
    yay.select_sugar(from: node, selector: "requestBody")
    |> result.map_error(fn(_) {
      MissingField(path: context, field: "requestBody")
    }),
  )

  // Check for $ref first
  case yay.extract_optional_string(rb_node, "$ref") {
    Ok(Some(ref_str)) -> resolve_request_body_ref(ref_str, components)
    _ -> parse_request_body(rb_node, context)
  }
}

/// Parse a request body object.
fn parse_request_body(
  node: yay.Node,
  context: String,
) -> Result(RequestBody, ParseError) {
  let description =
    yay.extract_optional_string(node, "description")
    |> result.unwrap(None)

  let required =
    yay.extract_optional_bool(node, "required")
    |> result.unwrap(None)
    |> option.unwrap(False)

  // content is REQUIRED per OpenAPI spec
  use content <- result.try(parse_required_content(node, context))

  Ok(RequestBody(description:, content:, required:))
}

/// Parse content map, requiring at least one entry for request bodies.
fn parse_required_content(
  node: yay.Node,
  context: String,
) -> Result(Dict(String, MediaType), ParseError) {
  case yay.select_sugar(from: node, selector: "content") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(media_type_name) -> {
            use mt_schema <- result.try(
              case yay.select_sugar(from: value_node, selector: "schema") {
                Ok(schema_node) -> {
                  use sr <- result.try(parse_schema_ref(schema_node))
                  Ok(Some(sr))
                }
                _ -> Ok(None)
              },
            )
            let mt_example =
              yay.extract_optional_string(value_node, "example")
              |> result.unwrap(None)
            let mt_examples = parse_string_map(value_node, "examples")
            let mt_encoding = parse_encoding_map(value_node)
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
    _ -> Error(MissingField(path: context <> ".requestBody", field: "content"))
  }
}

/// Parse content map (media type -> schema).
fn parse_content(
  node: yay.Node,
  _context: String,
) -> Result(Dict(String, MediaType), ParseError) {
  case yay.select_sugar(from: node, selector: "content") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(media_type_name) -> {
            use mt_schema <- result.try(
              case yay.select_sugar(from: value_node, selector: "schema") {
                Ok(schema_node) -> {
                  use sr <- result.try(parse_schema_ref(schema_node))
                  Ok(Some(sr))
                }
                _ -> Ok(None)
              },
            )
            let mt_example =
              yay.extract_optional_string(value_node, "example")
              |> result.unwrap(None)
            let mt_examples = parse_string_map(value_node, "examples")
            let mt_encoding = parse_encoding_map(value_node)
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
  components: Option(Components),
) -> Result(Dict(String, Response), ParseError) {
  case yay.select_sugar(from: node, selector: "responses") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(status_code) -> {
            use resp <- result.try(parse_response(value_node, components))
            Ok(dict.insert(acc, status_code, resp))
          }
          yay.NodeInt(code) -> {
            use resp <- result.try(parse_response(value_node, components))
            let code_str = string.inspect(code)
            Ok(dict.insert(acc, code_str, resp))
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
  components: Option(Components),
) -> Result(Response, ParseError) {
  // Check for $ref first
  case yay.extract_optional_string(node, "$ref") {
    Ok(Some(ref_str)) -> resolve_response_ref(ref_str, components)
    _ -> {
      // description is REQUIRED per OpenAPI spec
      use description <- result.try(
        yay.extract_string(node, "description")
        |> result.map(Some)
        |> result.map_error(fn(_) {
          MissingField(path: "response", field: "description")
        }),
      )

      use content <- result.try(parse_content(node, "response"))
      let headers = parse_headers_map(node)
      let links = parse_links_map(node)

      Ok(Response(description:, content:, headers:, links:))
    }
  }
}

/// Parse the components section.
fn parse_components(root: yay.Node) -> Result(Components, ParseError) {
  use components_node <- result.try(
    yay.select_sugar(from: root, selector: "components")
    |> result.map_error(fn(_) { MissingField(path: "", field: "components") }),
  )

  use schemas <- result.try(parse_schemas_map(components_node))
  use parameters <- result.try(parse_parameters_map(components_node))
  use request_bodies <- result.try(parse_request_bodies_map(components_node))
  use responses <- result.try(parse_responses_map(components_node))
  use security_schemes <- result.try(parse_security_schemes_map(components_node))
  use path_items <- result.try(parse_path_items_map(components_node))
  let headers = parse_headers_map(components_node)
  let examples = parse_string_map(components_node, "examples")
  let links = parse_links_map(components_node)

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
  ))
}

/// Parse the schemas map from components.
fn parse_schemas_map(
  components_node: yay.Node,
) -> Result(Dict(String, SchemaRef), ParseError) {
  case yay.select_sugar(from: components_node, selector: "schemas") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            use schema_ref <- result.try(parse_schema_ref(value_node))
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
) -> Result(Dict(String, Parameter), ParseError) {
  case yay.select_sugar(from: components_node, selector: "parameters") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            // Parse inline parameter (no $ref resolution needed at component level)
            use param <- result.try(parse_parameter(value_node, None))
            Ok(dict.insert(acc, name, param))
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
) -> Result(Dict(String, RequestBody), ParseError) {
  case yay.select_sugar(from: components_node, selector: "requestBodies") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            use rb <- result.try(parse_request_body(
              value_node,
              "components.requestBodies." <> name,
            ))
            Ok(dict.insert(acc, name, rb))
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
) -> Result(Dict(String, Response), ParseError) {
  case yay.select_sugar(from: components_node, selector: "responses") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            // Parse inline response (no $ref resolution at component level)
            use resp <- result.try(parse_response(value_node, None))
            Ok(dict.insert(acc, name, resp))
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse a schema reference (either $ref or inline schema).
pub fn parse_schema_ref(node: yay.Node) -> Result(SchemaRef, ParseError) {
  case yay.extract_optional_string(node, "$ref") {
    Ok(Some(ref)) -> Ok(schema.make_reference(ref))
    _ -> {
      use schema_obj <- result.try(parse_schema_object(node))
      Ok(Inline(schema_obj))
    }
  }
}

/// Parse a schema object.
pub fn parse_schema_object(node: yay.Node) -> Result(SchemaObject, ParseError) {
  let nullable =
    yay.extract_optional_bool(node, "nullable")
    |> result.unwrap(None)
    |> option.unwrap(False)

  let description =
    yay.extract_optional_string(node, "description")
    |> result.unwrap(None)

  let deprecated =
    yay.extract_optional_bool(node, "deprecated")
    |> result.unwrap(None)
    |> option.unwrap(False)

  let title =
    yay.extract_optional_string(node, "title")
    |> result.unwrap(None)

  let read_only =
    yay.extract_optional_bool(node, "readOnly")
    |> result.unwrap(None)
    |> option.unwrap(False)

  let write_only =
    yay.extract_optional_bool(node, "writeOnly")
    |> result.unwrap(None)
    |> option.unwrap(False)

  let default =
    yay.extract_optional_string(node, "default")
    |> result.unwrap(None)

  let example =
    yay.extract_optional_string(node, "example")
    |> result.unwrap(None)

  let metadata =
    schema.SchemaMetadata(
      description:,
      nullable:,
      deprecated:,
      title:,
      read_only:,
      write_only:,
      default:,
      example:,
    )

  // Check for composition keywords first
  case yay.select_sugar(from: node, selector: "allOf") {
    Ok(yay.NodeSeq(items)) -> {
      use schemas <- result.try(list.try_map(items, parse_schema_ref))
      Ok(AllOfSchema(metadata:, schemas:))
    }
    _ ->
      case yay.select_sugar(from: node, selector: "oneOf") {
        Ok(yay.NodeSeq(items)) -> {
          use schemas <- result.try(list.try_map(items, parse_schema_ref))
          use discriminator <- result.try(
            case yay.select_sugar(from: node, selector: "discriminator") {
              Ok(_) -> {
                use d <- result.try(parse_discriminator(node))
                Ok(Some(d))
              }
              Error(_) -> Ok(None)
            },
          )
          Ok(OneOfSchema(metadata:, schemas:, discriminator:))
        }
        _ ->
          case yay.select_sugar(from: node, selector: "anyOf") {
            Ok(yay.NodeSeq(items)) -> {
              use schemas <- result.try(list.try_map(items, parse_schema_ref))
              use discriminator <- result.try(
                case yay.select_sugar(from: node, selector: "discriminator") {
                  Ok(_) -> {
                    use d <- result.try(parse_discriminator(node))
                    Ok(Some(d))
                  }
                  Error(_) -> Ok(None)
                },
              )
              Ok(AnyOfSchema(metadata:, schemas:, discriminator:))
            }
            _ -> parse_typed_schema(node, metadata)
          }
      }
  }
}

/// Parse a typed schema (string, integer, number, boolean, array, object).
fn parse_typed_schema(
  node: yay.Node,
  metadata: schema.SchemaMetadata,
) -> Result(SchemaObject, ParseError) {
  // OpenAPI 3.1 allows type to be an array, e.g. type: [string, 'null'].
  // Extract the primary type and detect nullable from the array form.
  // Multi-type unions (e.g. [string, integer]) are not supported.
  use #(type_str, metadata) <- result.try(
    case yay.select_sugar(from: node, selector: "type") {
      Ok(yay.NodeSeq(type_nodes)) -> {
        let type_strs =
          list.filter_map(type_nodes, fn(n) {
            case n {
              yay.NodeStr(s) -> Ok(s)
              _ -> Error(Nil)
            }
          })
        let has_null = list.contains(type_strs, "null")
        let non_null_types = list.filter(type_strs, fn(s) { s != "null" })
        case non_null_types {
          [single] ->
            Ok(#(
              single,
              schema.SchemaMetadata(
                ..metadata,
                nullable: metadata.nullable || has_null,
              ),
            ))
          [] ->
            Ok(#(
              "object",
              schema.SchemaMetadata(
                ..metadata,
                nullable: metadata.nullable || has_null,
              ),
            ))
          _ ->
            Error(InvalidValue(
              path: "schema.type",
              detail: "Multi-type unions (type: ["
                <> string.join(non_null_types, ", ")
                <> "]) are not supported; use oneOf instead",
            ))
        }
      }
      Ok(yay.NodeStr(s)) -> Ok(#(s, metadata))
      _ -> {
        let s =
          yay.extract_optional_string(node, "type")
          |> result.unwrap(None)
          |> option.unwrap("object")
        Ok(#(s, metadata))
      }
    },
  )

  let format =
    yay.extract_optional_string(node, "format")
    |> result.unwrap(None)

  case type_str {
    "string" -> {
      let enum_values = case yay.extract_string_list(node, "enum") {
        Ok(values) -> values
        _ -> []
      }
      let min_length =
        yay.extract_optional_int(node, "minLength") |> result.unwrap(None)
      let max_length =
        yay.extract_optional_int(node, "maxLength") |> result.unwrap(None)
      let pattern =
        yay.extract_optional_string(node, "pattern") |> result.unwrap(None)
      Ok(StringSchema(
        metadata:,
        format:,
        enum_values:,
        min_length:,
        max_length:,
        pattern:,
      ))
    }

    "integer" -> {
      let minimum =
        yay.extract_optional_int(node, "minimum") |> result.unwrap(None)
      let maximum =
        yay.extract_optional_int(node, "maximum") |> result.unwrap(None)
      let exclusive_minimum =
        yay.extract_optional_int(node, "exclusiveMinimum")
        |> result.unwrap(None)
      let exclusive_maximum =
        yay.extract_optional_int(node, "exclusiveMaximum")
        |> result.unwrap(None)
      let multiple_of =
        yay.extract_optional_int(node, "multipleOf") |> result.unwrap(None)
      Ok(IntegerSchema(
        metadata:,
        format:,
        minimum:,
        maximum:,
        exclusive_minimum:,
        exclusive_maximum:,
        multiple_of:,
      ))
    }

    "number" -> {
      let minimum =
        yay.extract_optional_float(node, "minimum") |> result.unwrap(None)
      let maximum =
        yay.extract_optional_float(node, "maximum") |> result.unwrap(None)
      let exclusive_minimum =
        yay.extract_optional_float(node, "exclusiveMinimum")
        |> result.unwrap(None)
      let exclusive_maximum =
        yay.extract_optional_float(node, "exclusiveMaximum")
        |> result.unwrap(None)
      let multiple_of =
        yay.extract_optional_float(node, "multipleOf")
        |> result.unwrap(None)
      Ok(NumberSchema(
        metadata:,
        format:,
        minimum:,
        maximum:,
        exclusive_minimum:,
        exclusive_maximum:,
        multiple_of:,
      ))
    }

    "boolean" -> Ok(BooleanSchema(metadata:))

    "array" -> {
      use items <- result.try(
        case yay.select_sugar(from: node, selector: "items") {
          Ok(items_node) -> parse_schema_ref(items_node)
          _ -> Error(MissingField(path: "schema(type=array)", field: "items"))
        },
      )
      let min_items =
        yay.extract_optional_int(node, "minItems") |> result.unwrap(None)
      let max_items =
        yay.extract_optional_int(node, "maxItems") |> result.unwrap(None)
      let unique_items =
        yay.extract_optional_bool(node, "uniqueItems")
        |> result.unwrap(None)
        |> option.unwrap(False)
      Ok(ArraySchema(metadata:, items:, min_items:, max_items:, unique_items:))
    }

    "object" -> {
      use properties <- result.try(parse_properties(node))
      let required = case yay.extract_string_list(node, "required") {
        Ok(r) -> r
        _ -> []
      }
      use #(additional_properties, additional_properties_untyped) <- result.try(
        case yay.select_sugar(from: node, selector: "additionalProperties") {
          Ok(yay.NodeBool(True)) -> Ok(#(None, True))
          Ok(yay.NodeBool(False)) -> Ok(#(None, False))
          Ok(ap_node) -> {
            use sr <- result.try(parse_schema_ref(ap_node))
            Ok(#(Some(sr), False))
          }
          _ -> Ok(#(None, False))
        },
      )
      let min_properties =
        yay.extract_optional_int(node, "minProperties")
        |> result.unwrap(None)
      let max_properties =
        yay.extract_optional_int(node, "maxProperties")
        |> result.unwrap(None)
      Ok(ObjectSchema(
        metadata:,
        properties:,
        required:,
        additional_properties:,
        additional_properties_untyped:,
        min_properties:,
        max_properties:,
      ))
    }

    unrecognized ->
      Error(InvalidValue(
        path: "schema.type",
        detail: "Unrecognized schema type '"
          <> unrecognized
          <> "'. Supported types: string, integer, number, boolean, array, object.",
      ))
  }
}

/// Parse properties map from an object schema.
fn parse_properties(
  node: yay.Node,
) -> Result(Dict(String, SchemaRef), ParseError) {
  case yay.select_sugar(from: node, selector: "properties") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            use schema_ref <- result.try(parse_schema_ref(value_node))
            Ok(dict.insert(acc, name, schema_ref))
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse discriminator from a node.
fn parse_discriminator(node: yay.Node) -> Result(Discriminator, ParseError) {
  use disc_node <- result.try(
    yay.select_sugar(from: node, selector: "discriminator")
    |> result.map_error(fn(_) {
      MissingField(path: "schema", field: "discriminator")
    }),
  )

  use property_name <- result.try(
    yay.extract_string(disc_node, "propertyName")
    |> result.map_error(fn(_) {
      MissingField(path: "discriminator", field: "propertyName")
    }),
  )

  let mapping = case yay.extract_string_map(disc_node, "mapping") {
    Ok(m) -> m
    _ -> dict.new()
  }

  Ok(Discriminator(property_name:, mapping:))
}

/// Convert a parse error to a human-readable string.
pub fn parse_error_to_string(error: ParseError) -> String {
  case error {
    FileError(detail:) -> detail
    YamlError(detail:) -> detail
    MissingField(path:, field:) -> "Missing field '" <> field <> "' at " <> path
    InvalidValue(path:, detail:) ->
      "Invalid value at " <> path <> ": " <> detail
  }
}

/// Parse security schemes from components.
/// Returns Ok(empty dict) if the section is absent, Error if present but
/// malformed.
fn parse_security_schemes_map(
  components_node: yay.Node,
) -> Result(Dict(String, spec.SecurityScheme), ParseError) {
  case yay.select_sugar(from: components_node, selector: "securitySchemes") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            use scheme <- result.try(parse_security_scheme(value_node))
            Ok(dict.insert(acc, name, scheme))
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
) -> Result(Dict(String, PathItem), ParseError) {
  case yay.select_sugar(from: components_node, selector: "pathItems") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            use path_item <- result.try(parse_path_item(
              value_node,
              "components.pathItems." <> name,
              None,
            ))
            Ok(dict.insert(acc, name, path_item))
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Resolve a $ref for a path item by looking it up in components.pathItems.
fn resolve_path_item_ref(
  ref_str: String,
  components: Option(Components),
) -> Result(PathItem, ParseError) {
  let ref_name =
    ref_str
    |> string.split("/")
    |> list.last
    |> result.unwrap("unknown")

  case components {
    Some(comps) ->
      case dict.get(comps.path_items, ref_name) {
        Ok(path_item) -> Ok(path_item)
        Error(_) ->
          Error(InvalidValue(
            path: "pathItem.$ref",
            detail: "Unresolved pathItem reference: " <> ref_str,
          ))
      }
    None ->
      Error(InvalidValue(
        path: "pathItem.$ref",
        detail: "No components to resolve reference: " <> ref_str,
      ))
  }
}

/// Parse a single security scheme.
fn parse_security_scheme(
  node: yay.Node,
) -> Result(spec.SecurityScheme, ParseError) {
  use type_str <- result.try(
    yay.extract_string(node, "type")
    |> result.map_error(fn(_) {
      MissingField(path: "securityScheme", field: "type")
    }),
  )

  case type_str {
    "apiKey" -> {
      use name <- result.try(
        yay.extract_string(node, "name")
        |> result.map_error(fn(_) {
          MissingField(path: "securityScheme.apiKey", field: "name")
        }),
      )
      use in_str <- result.try(
        yay.extract_string(node, "in")
        |> result.map_error(fn(_) {
          MissingField(path: "securityScheme.apiKey", field: "in")
        }),
      )
      case parse_security_scheme_in(in_str) {
        Ok(in_) -> Ok(spec.ApiKeyScheme(name:, in_:))
        Error(_) ->
          Error(InvalidValue(
            path: "securityScheme.apiKey.in",
            detail: "Only 'header', 'query' and 'cookie' are supported for apiKey. Got: '"
              <> in_str
              <> "'",
          ))
      }
    }
    "http" -> {
      use scheme <- result.try(
        yay.extract_string(node, "scheme")
        |> result.map_error(fn(_) {
          MissingField(path: "securityScheme.http", field: "scheme")
        }),
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
        |> result.map_error(fn(_) {
          MissingField(
            path: "securityScheme.openIdConnect",
            field: "openIdConnectUrl",
          )
        }),
      )
      Ok(spec.OpenIdConnectScheme(open_id_connect_url:, description:))
    }
    _ ->
      Error(InvalidValue(
        path: "securityScheme.type",
        detail: "Unsupported security scheme type: " <> type_str,
      ))
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
) -> Result(List(SecurityRequirement), ParseError) {
  case yay.select_sugar(from: node, selector: "security") {
    Ok(yay.NodeSeq(items)) ->
      list.try_map(items, fn(item) {
        parse_security_requirement_object(item, context)
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
) -> Result(Option(List(SecurityRequirement)), ParseError) {
  case yay.select_sugar(from: node, selector: "security") {
    Ok(yay.NodeSeq(items)) -> {
      use reqs <- result.try(
        list.try_map(items, fn(item) {
          parse_security_requirement_object(item, context)
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
) -> Result(SecurityRequirement, ParseError) {
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
                        Error(InvalidValue(
                          path: context <> ".security." <> scheme_name,
                          detail: "Scope must be a string",
                        ))
                    }
                  })
                yay.NodeNil -> Ok([])
                _ ->
                  Error(InvalidValue(
                    path: context <> ".security." <> scheme_name,
                    detail: "Scopes must be an array of strings",
                  ))
              })
              Ok(spec.SecuritySchemeRef(scheme_name:, scopes:))
            }
            _ ->
              Error(InvalidValue(
                path: context <> ".security",
                detail: "Security requirement key must be a string",
              ))
          }
        }),
      )
      Ok(SecurityRequirement(schemes: scheme_refs))
    }
    _ ->
      Error(InvalidValue(
        path: context <> ".security",
        detail: "Security requirement must be an object",
      ))
  }
}

/// Parse callbacks from an operation node.
/// Returns an empty dict if no callbacks are present.
/// Propagates parse errors instead of silently dropping invalid callbacks.
fn parse_callbacks(
  node: yay.Node,
  context: String,
  components: Option(Components),
) -> Result(dict.Dict(String, Callback), ParseError) {
  case yay.select_sugar(from: node, selector: "callbacks") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(callback_name) -> {
            use callback <- result.try(parse_callback_object(
              value_node,
              context,
              components,
            ))
            Ok(dict.insert(acc, callback_name, callback))
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
  components: Option(Components),
) -> Result(Callback, ParseError) {
  case node {
    yay.NodeMap(entries) -> {
      use parsed_entries <- result.try(
        list.try_fold(entries, [], fn(acc, entry) {
          let #(key_node, path_item_node) = entry
          case key_node {
            yay.NodeStr(url_expression) -> {
              use path_item <- result.try(parse_path_item(
                path_item_node,
                context <> ".callbacks." <> url_expression,
                components,
              ))
              Ok([#(url_expression, path_item), ..acc])
            }
            _ -> Ok(acc)
          }
        }),
      )
      case parsed_entries {
        [] ->
          Error(MissingField(
            path: context <> ".callbacks",
            field: "url expression",
          ))
        _ -> Ok(Callback(entries: dict.from_list(parsed_entries)))
      }
    }
    _ ->
      Error(MissingField(path: context <> ".callbacks", field: "url expression"))
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
  components: Option(Components),
) -> Result(Dict(String, PathItem), ParseError) {
  case yay.select_sugar(from: node, selector: "webhooks") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            use path_item <- result.try(parse_path_item(
              value_node,
              "webhooks." <> name,
              components,
            ))
            Ok(dict.insert(acc, name, path_item))
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse a string->string map from a node at a given key.
fn parse_string_map(node: yay.Node, key: String) -> Dict(String, String) {
  case yay.extract_string_map(node, key) {
    Ok(m) -> m
    _ -> dict.new()
  }
}

/// Parse a content map (non-result version for use in Parameter).
fn parse_content_map(node: yay.Node) -> Dict(String, MediaType) {
  case yay.select_sugar(from: node, selector: "content") {
    Ok(yay.NodeMap(entries)) ->
      list.fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(media_type_name) -> {
            let mt_schema = case
              yay.select_sugar(from: value_node, selector: "schema")
            {
              Ok(schema_node) ->
                case parse_schema_ref(schema_node) {
                  Ok(sr) -> Some(sr)
                  _ -> None
                }
              _ -> None
            }
            let mt_example =
              yay.extract_optional_string(value_node, "example")
              |> result.unwrap(None)
            let mt_examples = parse_string_map(value_node, "examples")
            let mt_encoding = parse_encoding_map(value_node)
            dict.insert(
              acc,
              media_type_name,
              MediaType(
                schema: mt_schema,
                example: mt_example,
                examples: mt_examples,
                encoding: mt_encoding,
              ),
            )
          }
          _ -> acc
        }
      })
    _ -> dict.new()
  }
}

/// Parse encoding map from a media type node.
fn parse_encoding_map(node: yay.Node) -> Dict(String, Encoding) {
  case yay.select_sugar(from: node, selector: "encoding") {
    Ok(yay.NodeMap(entries)) ->
      list.fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(prop_name) -> {
            let content_type =
              yay.extract_optional_string(value_node, "contentType")
              |> result.unwrap(None)
            let style =
              yay.extract_optional_string(value_node, "style")
              |> result.unwrap(None)
              |> option.map(parse_parameter_style)
            let explode =
              yay.extract_optional_bool(value_node, "explode")
              |> result.unwrap(None)
            dict.insert(
              acc,
              prop_name,
              Encoding(content_type:, style:, explode:),
            )
          }
          _ -> acc
        }
      })
    _ -> dict.new()
  }
}

/// Parse headers map from a node.
fn parse_headers_map(node: yay.Node) -> Dict(String, Header) {
  case yay.select_sugar(from: node, selector: "headers") {
    Ok(yay.NodeMap(entries)) ->
      list.fold(entries, dict.new(), fn(acc, entry) {
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
            let hdr_schema = case
              yay.select_sugar(from: value_node, selector: "schema")
            {
              Ok(schema_node) ->
                case parse_schema_ref(schema_node) {
                  Ok(sr) -> Some(sr)
                  _ -> None
                }
              _ -> None
            }
            dict.insert(
              acc,
              header_name,
              Header(description:, required:, schema: hdr_schema),
            )
          }
          _ -> acc
        }
      })
    _ -> dict.new()
  }
}

/// Parse links map from a node.
fn parse_links_map(node: yay.Node) -> Dict(String, Link) {
  case yay.select_sugar(from: node, selector: "links") {
    Ok(yay.NodeMap(entries)) ->
      list.fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(link_name) -> {
            let operation_id =
              yay.extract_optional_string(value_node, "operationId")
              |> result.unwrap(None)
            let description =
              yay.extract_optional_string(value_node, "description")
              |> result.unwrap(None)
            dict.insert(acc, link_name, Link(operation_id:, description:))
          }
          _ -> acc
        }
      })
    _ -> dict.new()
  }
}

/// Convert a YAML error to a string.
fn yaml_error_to_string(error: yay.YamlError) -> String {
  case error {
    yay.UnexpectedParsingError -> "Unexpected parsing error"
    yay.ParsingError(msg:, ..) -> msg
  }
}
