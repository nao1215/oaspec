import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/string
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/openapi/spec.{type Resolved}

/// Capitalize the first letter of a string. Used to render HTTP scheme
/// prefixes like `Bearer` / `Basic` / `Digest` in the emitted security
/// metadata.
pub fn capitalize_first(value: String) -> String {
  case string.pop_grapheme(value) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    // nolint: thrown_away_error -- empty string has no first grapheme; fall back to the original value
    Error(_) -> value
  }
}

/// Render the OpenAPI security requirements for an operation as a Gleam
/// list-of-`SecurityAlternative` literal that can be inlined into a
/// generated `transport.Request`. Returns `"[]"` when the operation has
/// no security or when none of the listed schemes resolve.
pub fn render_security_metadata(
  ctx: Context,
  alternatives: List(spec.SecurityRequirement),
) -> String {
  case alternatives {
    [] -> "[]"
    _ -> {
      let rendered =
        alternatives
        |> list.filter_map(fn(alt) {
          case render_alternative(ctx, alt) {
            "" -> Error(Nil)
            s -> Ok(s)
          }
        })
      case rendered {
        [] -> "[]"
        _ -> "[" <> string.join(rendered, ", ") <> "]"
      }
    }
  }
}

fn render_alternative(
  ctx: Context,
  alt: spec.SecurityRequirement,
) -> String {
  let reqs =
    alt.schemes
    |> list.filter_map(fn(scheme_ref) { render_requirement(ctx, scheme_ref) })
  case reqs {
    [] -> ""
    _ -> "transport.SecurityAlternative([" <> string.join(reqs, ", ") <> "])"
  }
}

fn render_requirement(
  ctx: Context,
  scheme_ref: spec.SecuritySchemeRef,
) -> Result(String, Nil) {
  case context.spec(ctx).components {
    Some(components) ->
      case dict.get(components.security_schemes, scheme_ref.scheme_name) {
        Ok(spec.Value(scheme)) ->
          case scheme {
            spec.ApiKeyScheme(name: header_name, in_: spec.SchemeInHeader) ->
              Ok(api_key(scheme_ref.scheme_name, "ApiKeyHeader", header_name))
            spec.ApiKeyScheme(name: query_name, in_: spec.SchemeInQuery) ->
              Ok(api_key(scheme_ref.scheme_name, "ApiKeyQuery", query_name))
            spec.ApiKeyScheme(name: cookie_name, in_: spec.SchemeInCookie) ->
              Ok(api_key(scheme_ref.scheme_name, "ApiKeyCookie", cookie_name))
            spec.HttpScheme(scheme: prefix, ..) ->
              Ok(http_authorization(
                scheme_ref.scheme_name,
                capitalize_first(prefix),
              ))
            spec.OAuth2Scheme(..) | spec.OpenIdConnectScheme(..) ->
              Ok(http_authorization(scheme_ref.scheme_name, "Bearer"))
            _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn api_key(scheme_name: String, variant: String, name: String) -> String {
  "transport."
  <> variant
  <> "(scheme_name: \""
  <> scheme_name
  <> "\", "
  <> field_label(variant)
  <> ": \""
  <> name
  <> "\")"
}

fn http_authorization(scheme_name: String, prefix: String) -> String {
  "transport.HttpAuthorization(scheme_name: \""
  <> scheme_name
  <> "\", prefix: \""
  <> prefix
  <> "\")"
}

fn field_label(variant: String) -> String {
  case variant {
    "ApiKeyHeader" -> "header_name"
    "ApiKeyQuery" -> "query_name"
    "ApiKeyCookie" -> "cookie_name"
    _ -> "name"
  }
}

/// Wrap a value expression with `uri.percent_encode` unless the parameter
/// declares `allowReserved: true`.
pub fn maybe_percent_encode(
  value_expr: String,
  param: spec.Parameter(Resolved),
) -> String {
  use <- bool.guard(param.allow_reserved, value_expr)
  "uri.percent_encode(" <> value_expr <> ")"
}
