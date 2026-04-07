import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam_oas/codegen/context.{
  type Context, type GeneratedFile, GeneratedFile,
}
import gleam_oas/codegen/types as type_gen
import gleam_oas/openapi/resolver
import gleam_oas/openapi/schema.{Inline, IntegerSchema, Reference, StringSchema}
import gleam_oas/openapi/spec
import gleam_oas/util/naming
import gleam_oas/util/string_extra as se

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
    "gleam/http/request",
    "gleam/http",
    "gleam/int",
    "gleam/option.{type Option, None, Some}",
    "gleam/string",
  ]
  let imports = case needs_types {
    True -> list.append(base_imports, [ctx.config.package <> "/types"])
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
  let operations = type_gen.collect_operations(ctx)

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
  _ctx: Context,
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
      let to_string_expr = case p.schema {
        Some(Inline(IntegerSchema(..))) -> "int.to_string(" <> param_name <> ")"
        _ -> param_name
      }
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
          let to_str = case p.schema {
            Some(Inline(IntegerSchema(..))) -> "int.to_string(v)"
            _ -> "v"
          }
          case p.required {
            True ->
              sb
              |> se.indent(
                1,
                "let query_parts = [\""
                  <> p.name
                  <> "=\" <> "
                  <> to_str_for_required(p, param_name)
                  <> ", ..query_parts]",
              )
            False ->
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
        True ->
          sb
          |> se.indent(
            1,
            "let req = request.set_header(req, \""
              <> header_name
              <> "\", "
              <> param_name
              <> ")",
          )
        False ->
          sb
          |> se.indent(1, "let req = case " <> param_name <> " {")
          |> se.indent(
            2,
            "Some(v) -> request.set_header(req, \"" <> header_name <> "\", v)",
          )
          |> se.indent(2, "None -> req")
          |> se.indent(1, "}")
      }
    })

  // Set cookie parameters via Cookie header
  let sb =
    list.fold(cookie_params, sb, fn(sb, p) {
      let param_name = naming.to_snake_case(p.name)
      case p.required {
        True ->
          sb
          |> se.indent(
            1,
            "let req = request.set_header(req, \"cookie\", \""
              <> p.name
              <> "=\" <> "
              <> param_name
              <> ")",
          )
        False ->
          sb
          |> se.indent(1, "let req = case " <> param_name <> " {")
          |> se.indent(
            2,
            "Some(v) -> request.set_header(req, \"cookie\", \""
              <> p.name
              <> "=\" <> v)",
          )
          |> se.indent(2, "None -> req")
          |> se.indent(1, "}")
      }
    })

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
) -> String {
  let all_params =
    list.append(path_params, query_params)
    |> list.append(header_params)
    |> list.append(cookie_params)

  let param_strs =
    list.map(all_params, fn(p) {
      let param_name = naming.to_snake_case(p.name)
      let param_type = param_to_type(p)
      ", " <> param_name <> ": " <> param_type
    })

  let body_param = case operation.request_body {
    Some(_) -> [", body: String"]
    _ -> []
  }

  string.join(list.append(param_strs, body_param), "")
}

/// Convert a parameter to its Gleam type.
fn param_to_type(param: spec.Parameter) -> String {
  let base = case param.schema {
    Some(Inline(StringSchema(..))) -> "String"
    Some(Inline(IntegerSchema(..))) -> "Int"
    Some(Inline(schema.NumberSchema(..))) -> "Float"
    Some(Inline(schema.BooleanSchema(..))) -> "Bool"
    Some(Reference(ref:)) ->
      naming.schema_to_type_name(resolver.ref_to_name(ref))
    _ -> "String"
  }
  case param.required {
    True -> base
    False -> "Option(" <> base <> ")"
  }
}

/// Convert a required param to string for query building.
fn to_str_for_required(param: spec.Parameter, param_name: String) -> String {
  case param.schema {
    Some(Inline(IntegerSchema(..))) -> "int.to_string(" <> param_name <> ")"
    _ -> param_name
  }
}
