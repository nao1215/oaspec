import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oaspec/openapi/diagnostic.{type Diagnostic, NoSourceLoc, SourceLoc}
import oaspec/openapi/schema.{
  type Discriminator, type SchemaObject, type SchemaRef, AllOfSchema,
  AnyOfSchema, ArraySchema, BooleanSchema, Discriminator, Inline, IntegerSchema,
  NumberSchema, ObjectSchema, OneOfSchema, StringSchema,
}
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
pub fn parse_file(path: String) -> Result(OpenApiSpec(Unresolved), Diagnostic) {
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) {
      diagnostic.file_error(detail: "Cannot read file: " <> path)
    }),
  )

  parse_string(content)
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
  parse_root(root)
}

/// Parse the root OpenAPI object.
fn parse_root(node: yay.Node) -> Result(OpenApiSpec(Unresolved), Diagnostic) {
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
    |> result.map_error(fn(_) {
      diagnostic.missing_field(path: "", field: "openapi")
    }),
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
) -> Result(Option(Components(Unresolved)), Diagnostic) {
  case yay.select_sugar(from: root, selector: "components") {
    Ok(_) -> {
      use comps <- result.try(parse_components(root))
      Ok(Some(comps))
    }
    Error(_) -> Ok(None)
  }
}

/// Parse the info object.
fn parse_info(root: yay.Node) -> Result(Info, Diagnostic) {
  use info_node <- result.try(
    yay.select_sugar(from: root, selector: "info")
    |> result.map_error(fn(_) {
      diagnostic.missing_field(path: "", field: "info")
    }),
  )

  use title <- result.try(
    yay.extract_string(info_node, "title")
    |> result.map_error(fn(_) {
      diagnostic.missing_field(path: "info", field: "title")
    }),
  )

  use version <- result.try(
    yay.extract_string(info_node, "version")
    |> result.map_error(fn(_) {
      diagnostic.missing_field(path: "info", field: "version")
    }),
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
fn parse_servers(root: yay.Node) -> Result(List(Server), Diagnostic) {
  case yay.select_sugar(from: root, selector: "servers") {
    Ok(yay.NodeSeq(items)) -> list.try_map(items, parse_server)
    _ -> Ok([])
  }
}

/// Parse a single server object.
fn parse_server(node: yay.Node) -> Result(Server, Diagnostic) {
  use url <- result.try(
    yay.extract_string(node, "url")
    |> result.map_error(fn(_) {
      diagnostic.missing_field(path: "servers", field: "url")
    }),
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
) -> Result(PathItem(Unresolved), Diagnostic) {
  let summary =
    yay.extract_optional_string(node, "summary")
    |> result.unwrap(None)

  let description =
    yay.extract_optional_string(node, "description")
    |> result.unwrap(None)

  // Operations are optional, but if present must parse correctly.
  use get <- result.try(parse_optional_operation(node, "get", path, components))
  use post <- result.try(parse_optional_operation(
    node,
    "post",
    path,
    components,
  ))
  use put <- result.try(parse_optional_operation(node, "put", path, components))
  use delete <- result.try(parse_optional_operation(
    node,
    "delete",
    path,
    components,
  ))
  use patch <- result.try(parse_optional_operation(
    node,
    "patch",
    path,
    components,
  ))
  use head <- result.try(parse_optional_operation(
    node,
    "head",
    path,
    components,
  ))
  use options <- result.try(parse_optional_operation(
    node,
    "options",
    path,
    components,
  ))
  use trace <- result.try(parse_optional_operation(
    node,
    "trace",
    path,
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
  components: Option(Components(Unresolved)),
) -> Result(Option(Operation(Unresolved)), Diagnostic) {
  case yay.select_sugar(from: node, selector: method_key) {
    Ok(_) -> {
      use op <- result.try(parse_operation_at(
        node,
        method_key,
        path,
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
  components: Option(Components(Unresolved)),
) -> Result(Operation(Unresolved), Diagnostic) {
  use op_node <- result.try(
    yay.select_sugar(from: node, selector: method_key)
    |> result.map_error(fn(_) {
      diagnostic.missing_field(path:, field: method_key)
    }),
  )

  parse_operation(op_node, path <> "." <> method_key, components)
}

/// Parse a single operation.
fn parse_operation(
  node: yay.Node,
  context: String,
  components: Option(Components(Unresolved)),
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
  components: Option(Components(Unresolved)),
) -> Result(Option(RefOr(RequestBody(Unresolved))), Diagnostic) {
  case yay.select_sugar(from: node, selector: "requestBody") {
    Ok(_) -> {
      use rb <- result.try(parse_request_body_at(node, context, components))
      Ok(Some(rb))
    }
    Error(_) -> Ok(None)
  }
}

/// Parse responses, treating the field as optional.
/// OpenAPI 3.x requires responses on operations, but webhook operations
/// in the wild often omit them. Validation can catch missing responses.
fn parse_responses_required(
  node: yay.Node,
  context: String,
  components: Option(Components(Unresolved)),
) -> Result(
  dict.Dict(http.HttpStatusCode, RefOr(Response(Unresolved))),
  Diagnostic,
) {
  parse_responses(node, context, components)
}

/// Parse parameters list from a node.
fn parse_parameters_list(
  node: yay.Node,
  components: Option(Components(Unresolved)),
) -> Result(List(RefOr(Parameter(Unresolved))), Diagnostic) {
  case yay.select_sugar(from: node, selector: "parameters") {
    Ok(yay.NodeSeq(items)) ->
      list.try_map(items, fn(item) { parse_parameter(item, components) })
    _ -> Ok([])
  }
}

/// Parse a single parameter.
fn parse_parameter(
  node: yay.Node,
  _components: Option(Components(Unresolved)),
) -> Result(RefOr(Parameter(Unresolved)), Diagnostic) {
  // Check for $ref first
  case yay.extract_optional_string(node, "$ref") {
    Ok(Some(ref_str)) -> {
      Ok(Ref(ref_str))
    }
    _ -> {
      use name <- result.try(
        yay.extract_string(node, "name")
        |> result.map_error(fn(_) {
          diagnostic.missing_field(path: "parameter", field: "name")
        }),
      )

      use in_str <- result.try(
        yay.extract_string(node, "in")
        |> result.map_error(fn(_) {
          diagnostic.missing_field(path: "parameter." <> name, field: "in")
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
          Error(diagnostic.invalid_value(
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
            use sr <- result.try(parse_schema_ref(
              schema_node,
              "parameter.schema",
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
            use parsed <- result.try(parse_parameter_style(s))
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

      use content <- result.try(parse_content_map(node))
      let examples = value.extract_map(node, "examples")

      let payload = case param_schema {
        Ok(sr) -> spec.ParameterSchema(sr)
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
fn parse_parameter_in(value: String) -> Result(ParameterIn, Diagnostic) {
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
      ))
  }
}

/// Map a style string to a ParameterStyle ADT value.
fn parse_parameter_style(
  value: String,
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
      ))
  }
}

/// Map an apiKey "in" string to a SecuritySchemeIn ADT value.
fn parse_security_scheme_in(
  value: String,
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
      ))
  }
}

/// Parse requestBody from a node.
fn parse_request_body_at(
  node: yay.Node,
  context: String,
  _components: Option(Components(Unresolved)),
) -> Result(RefOr(RequestBody(Unresolved)), Diagnostic) {
  use rb_node <- result.try(
    yay.select_sugar(from: node, selector: "requestBody")
    |> result.map_error(fn(_) {
      diagnostic.missing_field(path: context, field: "requestBody")
    }),
  )

  // Check for $ref first
  case yay.extract_optional_string(rb_node, "$ref") {
    Ok(Some(ref_str)) -> Ok(Ref(ref_str))
    _ -> {
      use rb <- result.try(parse_request_body(rb_node, context))
      Ok(Value(rb))
    }
  }
}

/// Parse a request body object.
fn parse_request_body(
  node: yay.Node,
  context: String,
) -> Result(RequestBody(Unresolved), Diagnostic) {
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
                  use sr <- result.try(parse_schema_ref(
                    schema_node,
                    context <> ".schema",
                  ))
                  Ok(Some(sr))
                }
                _ -> Ok(None)
              },
            )
            let mt_example = value.extract_optional(value_node, "example")
            let mt_examples = value.extract_map(value_node, "examples")
            use mt_encoding <- result.try(parse_encoding_map(value_node))
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
      ))
  }
}

/// Parse content map (media type -> schema).
fn parse_content(
  node: yay.Node,
  context: String,
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
                  use sr <- result.try(parse_schema_ref(
                    schema_node,
                    context <> ".schema",
                  ))
                  Ok(Some(sr))
                }
                _ -> Ok(None)
              },
            )
            let mt_example = value.extract_optional(value_node, "example")
            let mt_examples = value.extract_map(value_node, "examples")
            use mt_encoding <- result.try(parse_encoding_map(value_node))
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
                    ))
                    Ok(dict.insert(acc, code, resp))
                  }
                  Error(_) -> Ok(acc)
                }
            }
          yay.NodeInt(code) -> {
            use resp <- result.try(parse_response(value_node, components))
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
) -> Result(RefOr(Response(Unresolved)), Diagnostic) {
  // Check for $ref first
  case yay.extract_optional_string(node, "$ref") {
    Ok(Some(ref_str)) -> Ok(Ref(ref_str))
    _ -> {
      // description is REQUIRED per OpenAPI spec
      use description <- result.try(
        yay.extract_string(node, "description")
        |> result.map(Some)
        |> result.map_error(fn(_) {
          diagnostic.missing_field(path: "response", field: "description")
        }),
      )

      use content <- result.try(parse_content(node, "response"))
      use headers <- result.try(parse_headers_map(node))
      use links <- result.try(parse_links_map(node))

      Ok(Value(Response(description:, content:, headers:, links:)))
    }
  }
}

/// Parse the components section.
fn parse_components(
  root: yay.Node,
) -> Result(Components(Unresolved), Diagnostic) {
  use components_node <- result.try(
    yay.select_sugar(from: root, selector: "components")
    |> result.map_error(fn(_) {
      diagnostic.missing_field(path: "", field: "components")
    }),
  )

  use schemas <- result.try(parse_schemas_map(components_node))
  use parameters <- result.try(parse_parameters_map(components_node))
  use request_bodies <- result.try(parse_request_bodies_map(components_node))
  use responses <- result.try(parse_responses_map(components_node))
  use security_schemes <- result.try(parse_security_schemes_map(components_node))
  use path_items <- result.try(parse_path_items_map(components_node))
  use headers <- result.try(parse_headers_map(components_node))
  let examples = value.extract_map(components_node, "examples")
  use links <- result.try(parse_links_map(components_node))

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
) -> Result(Dict(String, SchemaRef), Diagnostic) {
  case yay.select_sugar(from: components_node, selector: "schemas") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(name) -> {
            use schema_ref <- result.try(parse_schema_ref(
              value_node,
              "components.schemas." <> name,
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
                use param <- result.try(parse_parameter(value_node, None))
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
                use resp <- result.try(parse_response(value_node, None))
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
pub fn parse_schema_ref(
  node: yay.Node,
  path: String,
) -> Result(SchemaRef, Diagnostic) {
  case yay.extract_optional_string(node, "$ref") {
    Ok(Some(ref)) -> Ok(schema.make_reference(ref))
    _ -> {
      use schema_obj <- result.try(parse_schema_object(node, path))
      Ok(Inline(schema_obj))
    }
  }
}

/// Parse a schema object.
pub fn parse_schema_object(
  node: yay.Node,
  path: String,
) -> Result(SchemaObject, Diagnostic) {
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

  let default = value.extract_optional(node, "default")

  let example = value.extract_optional(node, "example")

  let const_value = value.extract_optional(node, "const")

  let unsupported_keywords = detect_unsupported_keywords(node)

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
      const_value:,
      raw_type: None,
      unsupported_keywords:,
      internal: False,
      provenance: schema.UserAuthored,
    )

  // Check for composition keywords first
  case yay.select_sugar(from: node, selector: "allOf") {
    Ok(yay.NodeSeq(items)) -> {
      use schemas <- result.try(
        list.try_map(items, parse_schema_ref(_, path <> ".allOf")),
      )
      Ok(AllOfSchema(metadata:, schemas:))
    }
    _ ->
      case yay.select_sugar(from: node, selector: "oneOf") {
        Ok(yay.NodeSeq(items)) -> {
          use schemas <- result.try(
            list.try_map(items, parse_schema_ref(_, path <> ".oneOf")),
          )
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
              use schemas <- result.try(
                list.try_map(items, parse_schema_ref(_, path <> ".anyOf")),
              )
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
            _ -> parse_typed_schema(node, metadata, path)
          }
      }
  }
}

/// Detect unsupported JSON Schema 2020-12 keywords present in a schema node.
/// Returns a list of keyword names found (does NOT fail — stores them for later).
/// Note: `const` is NOT in this list because it is parsed into `const_value`.
fn detect_unsupported_keywords(node: yay.Node) -> List(String) {
  let keywords = [
    "$defs", "prefixItems", "if", "then", "else", "dependentSchemas",
    "unevaluatedProperties", "unevaluatedItems", "contentEncoding",
    "contentMediaType", "contentSchema", "not",
  ]
  list.filter(keywords, fn(keyword) {
    case yay.select_sugar(from: node, selector: keyword) {
      Ok(_) -> True
      Error(_) -> False
    }
  })
}

/// Parse a typed schema (string, integer, number, boolean, array, object).
fn parse_typed_schema(
  node: yay.Node,
  metadata: schema.SchemaMetadata,
  path: String,
) -> Result(SchemaObject, Diagnostic) {
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
          _ -> {
            // Store multi-type for normalize pass
            let updated_meta =
              schema.SchemaMetadata(
                ..metadata,
                raw_type: Some(non_null_types),
                nullable: metadata.nullable || has_null,
              )
            // Default to first type for now; normalize will convert to oneOf
            let primary = case non_null_types {
              [first, ..] -> first
              [] -> "object"
            }
            Ok(#(primary, updated_meta))
          }
        }
      }
      Ok(yay.NodeStr(s)) -> Ok(#(s, metadata))
      _ -> {
        // When type is absent, default to "object".
        // Unsupported keywords (const, if/then/else, etc.) are already caught
        // by check_unsupported_schema_keywords before reaching this point,
        // so this fallback is safe for legitimate type-less schemas.
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
          Ok(items_node) -> parse_schema_ref(items_node, path <> ".items")
          _ -> Error(diagnostic.missing_field(path: path, field: "items"))
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
      use properties <- result.try(parse_properties(node, path))
      let required = case yay.extract_string_list(node, "required") {
        Ok(r) -> r
        _ -> []
      }
      use additional_properties <- result.try(
        case yay.select_sugar(from: node, selector: "additionalProperties") {
          Ok(yay.NodeBool(True)) -> Ok(schema.Untyped)
          Ok(yay.NodeBool(False)) -> Ok(schema.Forbidden)
          Ok(ap_node) -> {
            use sr <- result.try(parse_schema_ref(
              ap_node,
              path <> ".additionalProperties",
            ))
            Ok(schema.Typed(sr))
          }
          // Per JSON Schema, absent additionalProperties means allowed
          _ -> Ok(schema.Untyped)
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
        min_properties:,
        max_properties:,
      ))
    }

    unrecognized ->
      Error(diagnostic.invalid_value(
        path: path <> ".type",
        detail: "Unrecognized schema type '"
          <> unrecognized
          <> "'. Supported types: string, integer, number, boolean, array, object.",
      ))
  }
}

/// Parse properties map from an object schema.
fn parse_properties(
  node: yay.Node,
  path: String,
) -> Result(Dict(String, SchemaRef), Diagnostic) {
  case yay.select_sugar(from: node, selector: "properties") {
    Ok(yay.NodeMap(entries)) -> {
      list.try_fold(entries, dict.new(), fn(acc, entry) {
        let #(key_node, value_node) = entry
        case key_node {
          yay.NodeStr(prop_name) -> {
            use schema_ref <- result.try(parse_schema_ref(
              value_node,
              path <> "." <> prop_name,
            ))
            Ok(dict.insert(acc, prop_name, schema_ref))
          }
          _ -> Ok(acc)
        }
      })
    }
    _ -> Ok(dict.new())
  }
}

/// Parse discriminator from a node.
fn parse_discriminator(node: yay.Node) -> Result(Discriminator, Diagnostic) {
  use disc_node <- result.try(
    yay.select_sugar(from: node, selector: "discriminator")
    |> result.map_error(fn(_) {
      diagnostic.missing_field(path: "schema", field: "discriminator")
    }),
  )

  use property_name <- result.try(
    yay.extract_string(disc_node, "propertyName")
    |> result.map_error(fn(_) {
      diagnostic.missing_field(path: "discriminator", field: "propertyName")
    }),
  )

  let mapping = case yay.extract_string_map(disc_node, "mapping") {
    Ok(m) -> m
    _ -> dict.new()
  }

  Ok(Discriminator(property_name:, mapping:))
}

/// Convert a parse error to a human-readable string.
pub fn parse_error_to_string(error: Diagnostic) -> String {
  diagnostic.to_short_string(error)
}

/// Parse security schemes from components.
/// Returns Ok(empty dict) if the section is absent, Error if present but
/// malformed.
fn parse_security_schemes_map(
  components_node: yay.Node,
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
                use scheme <- result.try(parse_security_scheme(value_node))
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
) -> Result(spec.SecurityScheme, Diagnostic) {
  use type_str <- result.try(
    yay.extract_string(node, "type")
    |> result.map_error(fn(_) {
      diagnostic.missing_field(path: "securityScheme", field: "type")
    }),
  )

  case type_str {
    "apiKey" -> {
      use name <- result.try(
        yay.extract_string(node, "name")
        |> result.map_error(fn(_) {
          diagnostic.missing_field(path: "securityScheme.apiKey", field: "name")
        }),
      )
      use in_str <- result.try(
        yay.extract_string(node, "in")
        |> result.map_error(fn(_) {
          diagnostic.missing_field(path: "securityScheme.apiKey", field: "in")
        }),
      )
      case parse_security_scheme_in(in_str) {
        Ok(in_) -> Ok(spec.ApiKeyScheme(name:, in_:))
        Error(_) ->
          Error(diagnostic.invalid_value(
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
          diagnostic.missing_field(path: "securityScheme.http", field: "scheme")
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
          diagnostic.missing_field(
            path: "securityScheme.openIdConnect",
            field: "openIdConnectUrl",
          )
        }),
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
) -> Result(List(SecurityRequirement), Diagnostic) {
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
) -> Result(Option(List(SecurityRequirement)), Diagnostic) {
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
                        ))
                    }
                  })
                yay.NodeNil -> Ok([])
                _ ->
                  Error(diagnostic.invalid_value(
                    path: context <> ".security." <> scheme_name,
                    detail: "Scopes must be an array of strings",
                  ))
              })
              Ok(spec.SecuritySchemeRef(scheme_name:, scopes:))
            }
            _ ->
              Error(diagnostic.invalid_value(
                path: context <> ".security",
                detail: "Security requirement key must be a string",
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
      ))
  }
}

/// Parse callbacks from an operation node.
/// Returns an empty dict if no callbacks are present.
/// Propagates parse errors instead of silently dropping invalid callbacks.
fn parse_callbacks(
  node: yay.Node,
  context: String,
  components: Option(Components(Unresolved)),
) -> Result(dict.Dict(String, Callback(Unresolved)), Diagnostic) {
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
  components: Option(Components(Unresolved)),
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
          ))
        _ -> Ok(Callback(entries: dict.from_list(parsed_entries)))
      }
    }
    _ ->
      Error(diagnostic.missing_field(
        path: context <> ".callbacks",
        field: "url expression",
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
                  use sr <- result.try(parse_schema_ref(
                    schema_node,
                    "content.schema",
                  ))
                  Ok(Some(sr))
                }
                _ -> Ok(None)
              },
            )
            let mt_example = value.extract_optional(value_node, "example")
            let mt_examples = value.extract_map(value_node, "examples")
            use mt_encoding <- result.try(parse_encoding_map(value_node))
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
                  use parsed <- result.try(parse_parameter_style(s))
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
fn parse_headers_map(node: yay.Node) -> Result(Dict(String, Header), Diagnostic) {
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
                  use sr <- result.try(parse_schema_ref(
                    schema_node,
                    "header." <> header_name <> ".schema",
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
