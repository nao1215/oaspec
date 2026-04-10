import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oaspec/openapi/parse_error.{type ParseError, InvalidValue, MissingField}
import oaspec/openapi/spec.{type SecurityRequirement, SecurityRequirement}
import yay

/// Parse a single security scheme.
pub fn parse_security_scheme(
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

/// Parse top-level security requirements.
/// Returns Ok([]) if absent, Error if present but malformed.
pub fn parse_security_requirements(
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
pub fn parse_optional_security_requirements(
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
