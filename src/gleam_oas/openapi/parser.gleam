import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_oas/openapi/schema.{
  type Discriminator, type SchemaObject, type SchemaRef, AllOfSchema,
  AnyOfSchema, ArraySchema, BooleanSchema, Discriminator, Inline, IntegerSchema,
  NumberSchema, ObjectSchema, OneOfSchema, Reference, StringSchema,
}
import gleam_oas/openapi/spec.{
  type Components, type HttpMethod, type Info, type MediaType, type OpenApiSpec,
  type Operation, type Parameter, type ParameterIn, type PathItem,
  type RequestBody, type Response, type Server, Components, Delete, Get, Info,
  MediaType, OpenApiSpec, Operation, Parameter, Patch, PathItem, Post, Put,
  RequestBody, Response, Server,
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

  // Parse components FIRST so we can resolve $ref during path parsing
  let components = parse_components(node) |> option.from_result

  use paths <- result.try(parse_paths(node, components))
  let servers = parse_servers(node) |> result.unwrap([])

  Ok(OpenApiSpec(openapi:, info:, paths:, components:, servers:))
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

  Ok(Info(title:, description:, version:))
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

  Ok(Server(url:, description:))
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
            use path_item <- result.try(parse_path_item(
              value_node,
              path,
              components,
            ))
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

  let get =
    parse_operation_at(node, "get", path, Get, components)
    |> option.from_result
  let post =
    parse_operation_at(node, "post", path, Post, components)
    |> option.from_result
  let put =
    parse_operation_at(node, "put", path, Put, components)
    |> option.from_result
  let delete =
    parse_operation_at(node, "delete", path, Delete, components)
    |> option.from_result
  let patch =
    parse_operation_at(node, "patch", path, Patch, components)
    |> option.from_result

  let parameters = parse_parameters_list(node, components) |> result.unwrap([])

  Ok(PathItem(
    summary:,
    description:,
    get:,
    post:,
    put:,
    delete:,
    patch:,
    parameters:,
  ))
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

  let parameters = parse_parameters_list(node, components) |> result.unwrap([])
  let request_body =
    parse_request_body_at(node, context, components) |> option.from_result
  let responses =
    parse_responses(node, context, components) |> result.unwrap(dict.new())

  Ok(Operation(
    operation_id:,
    summary:,
    description:,
    tags:,
    parameters:,
    request_body:,
    responses:,
    deprecated:,
  ))
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

      let required =
        yay.extract_optional_bool(node, "required")
        |> result.unwrap(None)
        |> option.unwrap(case in_ {
          spec.InPath -> True
          _ -> False
        })

      let deprecated =
        yay.extract_optional_bool(node, "deprecated")
        |> result.unwrap(None)
        |> option.unwrap(False)

      let param_schema = case yay.select_sugar(from: node, selector: "schema") {
        Ok(schema_node) -> parse_schema_ref(schema_node) |> option.from_result
        _ -> None
      }

      let style =
        yay.extract_optional_string(node, "style")
        |> result.unwrap(None)

      Ok(Parameter(
        name:,
        in_:,
        description:,
        required:,
        schema: param_schema,
        style:,
        deprecated:,
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

  let content = parse_content(node, context) |> result.unwrap(dict.new())

  Ok(RequestBody(description:, content:, required:))
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
            let mt_schema = case
              yay.select_sugar(from: value_node, selector: "schema")
            {
              Ok(schema_node) ->
                parse_schema_ref(schema_node) |> option.from_result
              _ -> None
            }
            Ok(dict.insert(acc, media_type_name, MediaType(schema: mt_schema)))
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
      let description =
        yay.extract_optional_string(node, "description")
        |> result.unwrap(None)

      let content = parse_content(node, "response") |> result.unwrap(dict.new())

      Ok(Response(description:, content:))
    }
  }
}

/// Parse the components section.
fn parse_components(root: yay.Node) -> Result(Components, ParseError) {
  use components_node <- result.try(
    yay.select_sugar(from: root, selector: "components")
    |> result.map_error(fn(_) { MissingField(path: "", field: "components") }),
  )

  let schemas = parse_schemas_map(components_node) |> result.unwrap(dict.new())
  let parameters =
    parse_parameters_map(components_node) |> result.unwrap(dict.new())
  let request_bodies =
    parse_request_bodies_map(components_node) |> result.unwrap(dict.new())
  let responses =
    parse_responses_map(components_node) |> result.unwrap(dict.new())

  Ok(Components(schemas:, parameters:, request_bodies:, responses:))
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
    Ok(Some(ref)) -> Ok(Reference(ref:))
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

  // Check for composition keywords first
  case yay.select_sugar(from: node, selector: "allOf") {
    Ok(yay.NodeSeq(items)) -> {
      use schemas <- result.try(list.try_map(items, parse_schema_ref))
      Ok(AllOfSchema(description:, schemas:))
    }
    _ ->
      case yay.select_sugar(from: node, selector: "oneOf") {
        Ok(yay.NodeSeq(items)) -> {
          use schemas <- result.try(list.try_map(items, parse_schema_ref))
          let discriminator = parse_discriminator(node) |> option.from_result
          Ok(OneOfSchema(description:, schemas:, discriminator:))
        }
        _ ->
          case yay.select_sugar(from: node, selector: "anyOf") {
            Ok(yay.NodeSeq(items)) -> {
              use schemas <- result.try(list.try_map(items, parse_schema_ref))
              Ok(AnyOfSchema(description:, schemas:))
            }
            _ -> parse_typed_schema(node, description, nullable)
          }
      }
  }
}

/// Parse a typed schema (string, integer, number, boolean, array, object).
fn parse_typed_schema(
  node: yay.Node,
  description: Option(String),
  nullable: Bool,
) -> Result(SchemaObject, ParseError) {
  let type_str =
    yay.extract_optional_string(node, "type")
    |> result.unwrap(None)
    |> option.unwrap("object")

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
        description:,
        format:,
        enum_values:,
        min_length:,
        max_length:,
        pattern:,
        nullable:,
      ))
    }

    "integer" -> {
      let minimum =
        yay.extract_optional_int(node, "minimum") |> result.unwrap(None)
      let maximum =
        yay.extract_optional_int(node, "maximum") |> result.unwrap(None)
      Ok(IntegerSchema(description:, format:, minimum:, maximum:, nullable:))
    }

    "number" -> {
      let minimum =
        yay.extract_optional_float(node, "minimum") |> result.unwrap(None)
      let maximum =
        yay.extract_optional_float(node, "maximum") |> result.unwrap(None)
      Ok(NumberSchema(description:, format:, minimum:, maximum:, nullable:))
    }

    "boolean" -> Ok(BooleanSchema(description:, nullable:))

    "array" -> {
      let items = case yay.select_sugar(from: node, selector: "items") {
        Ok(items_node) ->
          parse_schema_ref(items_node)
          |> result.unwrap(
            Inline(StringSchema(
              description: None,
              format: None,
              enum_values: [],
              min_length: None,
              max_length: None,
              pattern: None,
              nullable: False,
            )),
          )
        _ ->
          Inline(StringSchema(
            description: None,
            format: None,
            enum_values: [],
            min_length: None,
            max_length: None,
            pattern: None,
            nullable: False,
          ))
      }
      let min_items =
        yay.extract_optional_int(node, "minItems") |> result.unwrap(None)
      let max_items =
        yay.extract_optional_int(node, "maxItems") |> result.unwrap(None)
      Ok(ArraySchema(description:, items:, min_items:, max_items:, nullable:))
    }

    // Default: object
    _ -> {
      let properties = parse_properties(node) |> result.unwrap(dict.new())
      let required = case yay.extract_string_list(node, "required") {
        Ok(r) -> r
        _ -> []
      }
      let #(additional_properties, additional_properties_untyped) = case
        yay.select_sugar(from: node, selector: "additionalProperties")
      {
        Ok(yay.NodeBool(True)) -> #(None, True)
        Ok(yay.NodeBool(False)) -> #(None, False)
        Ok(ap_node) -> #(parse_schema_ref(ap_node) |> option.from_result, False)
        _ -> #(None, False)
      }
      Ok(ObjectSchema(
        description:,
        properties:,
        required:,
        additional_properties:,
        additional_properties_untyped:,
        nullable:,
      ))
    }
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

/// Convert a YAML error to a string.
fn yaml_error_to_string(error: yay.YamlError) -> String {
  case error {
    yay.UnexpectedParsingError -> "Unexpected parsing error"
    yay.ParsingError(msg:, ..) -> msg
  }
}
