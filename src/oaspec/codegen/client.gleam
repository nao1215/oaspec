import gleam/list
import gleam/option.{Some}
import gleam/string
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/codegen/types as type_gen
import oaspec/openapi/resolver
import oaspec/openapi/schema.{
  Inline, IntegerSchema, NumberSchema, Reference, StringSchema,
}
import oaspec/openapi/spec
import oaspec/util/naming
import oaspec/util/string_extra as se

/// Generate client SDK files.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let client_content = generate_client(ctx)

  [GeneratedFile(path: "client.gleam", content: client_content)]
}

/// Generate the client module with functions for each operation.
fn generate_client(ctx: Context) -> String {
  // Only import types if operations reference $ref schemas in parameters
  let operations = type_gen.collect_operations(ctx)
  let needs_types =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(p) {
        case p.schema {
          Some(Reference(_)) -> True
          _ -> False
        }
      })
    })

  let base_imports = [
    "gleam/bool",
    "gleam/float",
    "gleam/http/request",
    "gleam/http",
    "gleam/int",
    "gleam/option.{type Option, None, Some}",
    "gleam/string",
  ]
  let imports = case needs_types {
    True ->
      list.append(base_imports, [
        ctx.config.package <> "/types",
        ctx.config.package <> "/encode",
      ])
    False -> base_imports
  }

  let sb =
    se.file_header(context.version)
    |> se.imports(imports)

  // Client configuration type
  let sb =
    sb
    |> se.doc_comment("HTTP client configuration.")
    |> se.line("pub type ClientConfig {")
    |> se.indent(1, "ClientConfig(")
    |> se.indent(2, "base_url: String,")
    |> se.indent(
      2,
      "send: fn(request.Request(String)) -> Result(ClientResponse, ClientError),",
    )
    |> se.indent(1, ")")
    |> se.line("}")
    |> se.blank_line()

  // HTTP response type
  let sb =
    sb
    |> se.doc_comment("Raw HTTP response from the server.")
    |> se.line("pub type ClientResponse {")
    |> se.indent(1, "ClientResponse(")
    |> se.indent(2, "status: Int,")
    |> se.indent(2, "body: String,")
    |> se.indent(1, ")")
    |> se.line("}")
    |> se.blank_line()

  // Error type
  let sb =
    sb
    |> se.doc_comment("HTTP client errors.")
    |> se.line("pub type ClientError {")
    |> se.indent(1, "ConnectionError(detail: String)")
    |> se.indent(1, "TimeoutError")
    |> se.indent(1, "DecodeError(detail: String)")
    |> se.line("}")
    |> se.blank_line()

  // Create default client
  let sb =
    sb
    |> se.doc_comment("Create a new client configuration.")
    |> se.line("pub fn new(")
    |> se.indent(1, "base_url: String,")
    |> se.indent(
      1,
      "send: fn(request.Request(String)) -> Result(ClientResponse, ClientError),",
    )
    |> se.line(") -> ClientConfig {")
    |> se.indent(1, "ClientConfig(base_url:, send:)")
    |> se.line("}")
    |> se.blank_line()

  // Generate operation functions
  let sb =
    list.fold(operations, sb, fn(sb, op) {
      let #(op_id, operation, path, method) = op
      generate_client_function(sb, op_id, operation, path, method, ctx)
    })

  se.to_string(sb)
}

/// Generate a client function for a single operation.
fn generate_client_function(
  sb: se.StringBuilder,
  op_id: String,
  operation: spec.Operation,
  path: String,
  method: spec.HttpMethod,
  ctx: Context,
) -> se.StringBuilder {
  let fn_name = naming.operation_to_function_name(op_id)

  let sb = case operation.summary {
    Some(summary) -> sb |> se.doc_comment(summary)
    _ -> sb
  }
  let sb = case operation.description {
    Some(desc) -> sb |> se.doc_comment(desc)
    _ -> sb
  }

  let path_params =
    list.filter(operation.parameters, fn(p) {
      case p.in_ {
        spec.InPath -> True
        _ -> False
      }
    })

  let query_params =
    list.filter(operation.parameters, fn(p) {
      case p.in_ {
        spec.InQuery -> True
        _ -> False
      }
    })

  let header_params =
    list.filter(operation.parameters, fn(p) {
      case p.in_ {
        spec.InHeader -> True
        _ -> False
      }
    })

  let cookie_params =
    list.filter(operation.parameters, fn(p) {
      case p.in_ {
        spec.InCookie -> True
        _ -> False
      }
    })

  // Function signature
  let params =
    build_param_list(
      path_params,
      query_params,
      header_params,
      cookie_params,
      operation,
      ctx,
    )
  let sb =
    sb
    |> se.line(
      "pub fn "
      <> fn_name
      <> "(config: ClientConfig"
      <> params
      <> ") -> Result(ClientResponse, ClientError) {",
    )

  // Build URL with path params
  let sb = sb |> se.indent(1, "let path = \"" <> path <> "\"")
  let sb =
    list.fold(path_params, sb, fn(sb, p) {
      let param_name = naming.to_snake_case(p.name)
      let to_string_expr = param_to_string_expr(p, param_name)
      sb
      |> se.indent(
        1,
        "let path = string.replace(path, \"{"
          <> p.name
          <> "}\", "
          <> to_string_expr
          <> ")",
      )
    })

  // Build query string from query params
  let sb = case list.is_empty(query_params) {
    True -> sb
    False -> {
      let sb = sb |> se.indent(1, "let query_parts = []")
      let sb =
        list.fold(query_params, sb, fn(sb, p) {
          let param_name = naming.to_snake_case(p.name)
          case p.required {
            True -> {
              let to_str = to_str_for_required(p, param_name)
              sb
              |> se.indent(
                1,
                "let query_parts = [\""
                  <> p.name
                  <> "=\" <> "
                  <> to_str
                  <> ", ..query_parts]",
              )
            }
            False -> {
              let to_str = to_str_for_optional_value(p)
              sb
              |> se.indent(1, "let query_parts = case " <> param_name <> " {")
              |> se.indent(
                2,
                "Some(v) -> [\""
                  <> p.name
                  <> "=\" <> "
                  <> to_str
                  <> ", ..query_parts]",
              )
              |> se.indent(2, "None -> query_parts")
              |> se.indent(1, "}")
            }
          }
        })
      let sb =
        sb
        |> se.indent(1, "let query_string = string.join(query_parts, \"&\")")
        |> se.indent(1, "let path = case query_string {")
        |> se.indent(2, "\"\" -> path")
        |> se.indent(2, "_ -> path <> \"?\" <> query_string")
        |> se.indent(1, "}")
      sb
    }
  }

  // Build the request
  let http_method = case method {
    spec.Get -> "http.Get"
    spec.Post -> "http.Post"
    spec.Put -> "http.Put"
    spec.Delete -> "http.Delete"
    spec.Patch -> "http.Patch"
  }

  let has_body = option.is_some(operation.request_body)

  let sb =
    sb
    |> se.indent(1, "let assert Ok(req) = request.to(config.base_url <> path)")
    |> se.indent(1, "let req = request.set_method(req, " <> http_method <> ")")

  // Only set content-type for requests with body
  let sb = case has_body {
    True ->
      sb
      |> se.indent(
        1,
        "let req = request.set_header(req, \"content-type\", \"application/json\")",
      )
      |> se.indent(1, "let req = request.set_body(req, body)")
    False -> sb
  }

  // Set header parameters
  let sb =
    list.fold(header_params, sb, fn(sb, p) {
      let param_name = naming.to_snake_case(p.name)
      let header_name = string.lowercase(p.name)
      case p.required {
        True -> {
          let to_str = param_to_string_expr(p, param_name)
          sb
          |> se.indent(
            1,
            "let req = request.set_header(req, \""
              <> header_name
              <> "\", "
              <> to_str
              <> ")",
          )
        }
        False -> {
          let to_str = to_str_for_optional_value(p)
          sb
          |> se.indent(1, "let req = case " <> param_name <> " {")
          |> se.indent(
            2,
            "Some(v) -> request.set_header(req, \""
              <> header_name
              <> "\", "
              <> to_str
              <> ")",
          )
          |> se.indent(2, "None -> req")
          |> se.indent(1, "}")
        }
      }
    })

  // Set cookie parameters: combine all into a single "cookie" header
  let sb = case list.is_empty(cookie_params) {
    True -> sb
    False -> {
      let sb = sb |> se.indent(1, "let cookie_parts = []")
      let sb =
        list.fold(cookie_params, sb, fn(sb, p) {
          let param_name = naming.to_snake_case(p.name)
          case p.required {
            True -> {
              let to_str = param_to_string_expr(p, param_name)
              sb
              |> se.indent(
                1,
                "let cookie_parts = [\""
                  <> p.name
                  <> "=\" <> "
                  <> to_str
                  <> ", ..cookie_parts]",
              )
            }
            False -> {
              let to_str = to_str_for_optional_value(p)
              sb
              |> se.indent(1, "let cookie_parts = case " <> param_name <> " {")
              |> se.indent(
                2,
                "Some(v) -> [\""
                  <> p.name
                  <> "=\" <> "
                  <> to_str
                  <> ", ..cookie_parts]",
              )
              |> se.indent(2, "None -> cookie_parts")
              |> se.indent(1, "}")
            }
          }
        })
      sb
      |> se.indent(1, "let req = case cookie_parts {")
      |> se.indent(2, "[] -> req")
      |> se.indent(
        2,
        "_ -> request.set_header(req, \"cookie\", string.join(cookie_parts, \"; \"))",
      )
      |> se.indent(1, "}")
    }
  }

  let sb =
    sb
    |> se.indent(1, "config.send(req)")

  sb
  |> se.line("}")
  |> se.blank_line()
}

/// Build parameter list for function signature.
fn build_param_list(
  path_params: List(spec.Parameter),
  query_params: List(spec.Parameter),
  header_params: List(spec.Parameter),
  cookie_params: List(spec.Parameter),
  operation: spec.Operation,
  ctx: Context,
) -> String {
  let all_params =
    list.append(path_params, query_params)
    |> list.append(header_params)
    |> list.append(cookie_params)

  let param_strs =
    list.map(all_params, fn(p) {
      let param_name = naming.to_snake_case(p.name)
      let param_type = param_to_type(p, ctx)
      ", " <> param_name <> ": " <> param_type
    })

  let body_param = case operation.request_body {
    Some(_) -> [", body: String"]
    _ -> []
  }

  string.join(list.append(param_strs, body_param), "")
}

/// Convert a parameter to its Gleam type string.
fn param_to_type(param: spec.Parameter, _ctx: Context) -> String {
  let base = case param.schema {
    Some(Inline(StringSchema(..))) -> "String"
    Some(Inline(IntegerSchema(..))) -> "Int"
    Some(Inline(schema.NumberSchema(..))) -> "Float"
    Some(Inline(schema.BooleanSchema(..))) -> "Bool"
    Some(Reference(ref:)) ->
      "types." <> naming.schema_to_type_name(resolver.ref_to_name(ref))
    _ -> "String"
  }
  case param.required {
    True -> base
    False -> "Option(" <> base <> ")"
  }
}

/// Convert a parameter value to its String representation for URL/header use.
fn param_to_string_expr(param: spec.Parameter, param_name: String) -> String {
  case param.schema {
    Some(Inline(IntegerSchema(..))) -> "int.to_string(" <> param_name <> ")"
    Some(Inline(NumberSchema(..))) -> "float.to_string(" <> param_name <> ")"
    Some(Inline(schema.BooleanSchema(..))) ->
      "bool.to_string(" <> param_name <> ")"
    Some(Reference(ref:)) -> {
      let name = resolver.ref_to_name(ref)
      "encode.encode_"
      <> naming.to_snake_case(name)
      <> "_to_string("
      <> param_name
      <> ")"
    }
    _ -> param_name
  }
}

/// Convert a required param to string for query building.
fn to_str_for_required(param: spec.Parameter, param_name: String) -> String {
  param_to_string_expr(param, param_name)
}

/// Convert an optional param value (bound to `v`) to string.
fn to_str_for_optional_value(param: spec.Parameter) -> String {
  case param.schema {
    Some(Inline(IntegerSchema(..))) -> "int.to_string(v)"
    Some(Inline(NumberSchema(..))) -> "float.to_string(v)"
    Some(Inline(schema.BooleanSchema(..))) -> "bool.to_string(v)"
    Some(Reference(ref:)) -> {
      let name = resolver.ref_to_name(ref)
      "encode.encode_" <> naming.to_snake_case(name) <> "_to_string(v)"
    }
    _ -> "v"
  }
}
