import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/string
import oaspec/codegen/context.{type Context}
import oaspec/openapi/spec.{type Resolved}
import oaspec/util/naming
import oaspec/util/string_extra as se

/// Capitalize the first letter of a string (for HTTP scheme prefix).
pub fn capitalize_first(s: String) -> String {
  case string.pop_grapheme(s) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    Error(_) -> s
  }
}

/// Generate a chain of OR alternatives for security requirements.
/// Each alternative is tried in order; the first one with all credentials
/// present is applied. If none match, req is returned unchanged.
pub fn generate_security_or_chain(
  sb: se.StringBuilder,
  ctx: Context,
  alternatives: List(spec.SecurityRequirement),
  base_indent: Int,
) -> se.StringBuilder {
  case alternatives {
    [] -> sb
    [alt] ->
      // Last (or only) alternative: None branch falls through to req
      generate_security_alternative(sb, ctx, alt.schemes, base_indent, "req")
    [alt, ..rest] -> {
      // For this alternative, the None/fallback branch tries the next alternative
      // We generate a nested structure where the fallback is the next alternative
      case alt.schemes {
        [] -> generate_security_or_chain(sb, ctx, rest, base_indent)
        [single_scheme] -> {
          let field_name = naming.to_snake_case(single_scheme.scheme_name)
          let sb =
            sb
            |> se.indent(
              base_indent,
              "let req = case config." <> field_name <> " {",
            )
          let sb =
            generate_scheme_some_branch(sb, ctx, single_scheme, base_indent + 1)
          let sb =
            sb
            |> se.indent(base_indent + 1, "None -> {")
          let sb = generate_security_or_chain(sb, ctx, rest, base_indent + 2)
          sb
          |> se.indent(base_indent + 2, "req")
          |> se.indent(base_indent + 1, "}")
          |> se.indent(base_indent, "}")
        }
        schemes -> {
          // AND alternative with multiple schemes: tuple match
          let fields =
            list.map(schemes, fn(s) {
              "config." <> naming.to_snake_case(s.scheme_name)
            })
          let sb =
            sb
            |> se.indent(
              base_indent,
              "let req = case " <> string.join(fields, ", ") <> " {",
            )
          // Some, Some, ... branch — apply all schemes
          let some_patterns =
            list.map(schemes, fn(s) {
              "Some(" <> naming.to_snake_case(s.scheme_name) <> "_val)"
            })
          let sb =
            sb
            |> se.indent(
              base_indent + 1,
              string.join(some_patterns, ", ") <> " -> {",
            )
          let sb =
            list.fold(schemes, sb, fn(sb, scheme_ref) {
              generate_scheme_apply(
                sb,
                ctx,
                scheme_ref,
                naming.to_snake_case(scheme_ref.scheme_name) <> "_val",
                base_indent + 2,
              )
            })
          let sb =
            sb
            |> se.indent(base_indent + 2, "req")
            |> se.indent(base_indent + 1, "}")
          // Wildcard branch — try next alternative
          let wildcard =
            list.map(schemes, fn(_) { "_" })
            |> string.join(", ")
          let sb =
            sb
            |> se.indent(base_indent + 1, wildcard <> " -> {")
          let sb = generate_security_or_chain(sb, ctx, rest, base_indent + 2)
          sb
          |> se.indent(base_indent + 2, "req")
          |> se.indent(base_indent + 1, "}")
          |> se.indent(base_indent, "}")
        }
      }
    }
  }
}

/// Generate a single security alternative (last in chain, None -> req).
fn generate_security_alternative(
  sb: se.StringBuilder,
  ctx: Context,
  schemes: List(spec.SecuritySchemeRef),
  base_indent: Int,
  fallback: String,
) -> se.StringBuilder {
  case schemes {
    [] -> sb
    [single_scheme] -> {
      let field_name = naming.to_snake_case(single_scheme.scheme_name)
      let sb =
        sb
        |> se.indent(
          base_indent,
          "let req = case config." <> field_name <> " {",
        )
      let sb =
        generate_scheme_some_branch(sb, ctx, single_scheme, base_indent + 1)
      sb
      |> se.indent(base_indent + 1, "None -> " <> fallback)
      |> se.indent(base_indent, "}")
    }
    schemes -> {
      // AND: tuple match
      let fields =
        list.map(schemes, fn(s) {
          "config." <> naming.to_snake_case(s.scheme_name)
        })
      let sb =
        sb
        |> se.indent(
          base_indent,
          "let req = case " <> string.join(fields, ", ") <> " {",
        )
      let some_patterns =
        list.map(schemes, fn(s) {
          "Some(" <> naming.to_snake_case(s.scheme_name) <> "_val)"
        })
      let sb =
        sb
        |> se.indent(
          base_indent + 1,
          string.join(some_patterns, ", ") <> " -> {",
        )
      let sb =
        list.fold(schemes, sb, fn(sb, scheme_ref) {
          generate_scheme_apply(
            sb,
            ctx,
            scheme_ref,
            naming.to_snake_case(scheme_ref.scheme_name) <> "_val",
            base_indent + 2,
          )
        })
      let sb =
        sb
        |> se.indent(base_indent + 2, "req")
        |> se.indent(base_indent + 1, "}")
      // Wildcard
      let wildcard =
        list.map(schemes, fn(_) { "_" })
        |> string.join(", ")
      sb
      |> se.indent(base_indent + 1, wildcard <> " -> " <> fallback)
      |> se.indent(base_indent, "}")
    }
  }
}

/// Generate the Some branch for a single scheme (the apply-credential line).
fn generate_scheme_some_branch(
  sb: se.StringBuilder,
  ctx: Context,
  scheme_ref: spec.SecuritySchemeRef,
  indent: Int,
) -> se.StringBuilder {
  case context.spec(ctx).components {
    Some(components) ->
      case dict.get(components.security_schemes, scheme_ref.scheme_name) {
        Ok(spec.Value(spec.ApiKeyScheme(
          name: header_name,
          in_: spec.SchemeInHeader,
        ))) ->
          sb
          |> se.indent(
            indent,
            "Some(key) -> request.set_header(req, \""
              <> string.lowercase(header_name)
              <> "\", key)",
          )
        Ok(spec.Value(spec.ApiKeyScheme(
          name: query_name,
          in_: spec.SchemeInQuery,
        ))) ->
          sb
          |> se.indent(indent, "Some(key) -> {")
          |> se.indent(
            indent + 1,
            "let sep = case string.contains(req.path, \"?\") {",
          )
          |> se.indent(indent + 2, "True -> \"&\"")
          |> se.indent(indent + 2, "False -> \"?\"")
          |> se.indent(indent + 1, "}")
          |> se.indent(
            indent + 1,
            "request.Request(..req, path: req.path <> sep <> \""
              <> query_name
              <> "=\" <> key)",
          )
          |> se.indent(indent, "}")
        Ok(spec.Value(spec.ApiKeyScheme(
          name: cookie_name,
          in_: spec.SchemeInCookie,
        ))) ->
          sb
          |> se.indent(indent, "Some(value) -> {")
          |> se.indent(
            indent + 1,
            "let existing = list.key_find(req.headers, \"cookie\") |> result.unwrap(\"\")",
          )
          |> se.indent(
            indent + 1,
            "let cookie_val = \"" <> cookie_name <> "=\" <> value",
          )
          |> se.indent(indent + 1, "let new_cookie = case existing {")
          |> se.indent(indent + 2, "\"\" -> cookie_val")
          |> se.indent(indent + 2, "_ -> existing <> \"; \" <> cookie_val")
          |> se.indent(indent + 1, "}")
          |> se.indent(
            indent + 1,
            "request.set_header(req, \"cookie\", new_cookie)",
          )
          |> se.indent(indent, "}")
        Ok(spec.Value(spec.HttpScheme(scheme: "basic", ..))) ->
          sb
          |> se.indent(
            indent,
            "Some(token) -> request.set_header(req, \"authorization\", \"Basic \" <> token)",
          )
        Ok(spec.Value(spec.HttpScheme(scheme: "digest", ..))) ->
          sb
          |> se.indent(
            indent,
            "Some(token) -> request.set_header(req, \"authorization\", \"Digest \" <> token)",
          )
        Ok(spec.Value(spec.HttpScheme(scheme: "bearer", ..)))
        | Ok(spec.Value(spec.OAuth2Scheme(..)))
        | Ok(spec.Value(spec.OpenIdConnectScheme(..))) ->
          sb
          |> se.indent(
            indent,
            "Some(token) -> request.set_header(req, \"authorization\", \"Bearer \" <> token)",
          )
        Ok(spec.Value(spec.HttpScheme(scheme: scheme_name, ..))) ->
          sb
          |> se.indent(
            indent,
            "Some(token) -> request.set_header(req, \"authorization\", \""
              <> capitalize_first(scheme_name)
              <> " \" <> token)",
          )
        _ -> sb
      }
    _ -> sb
  }
}

/// Generate scheme application using a known value variable (for AND tuple matches).
fn generate_scheme_apply(
  sb: se.StringBuilder,
  ctx: Context,
  scheme_ref: spec.SecuritySchemeRef,
  val_var: String,
  indent: Int,
) -> se.StringBuilder {
  case context.spec(ctx).components {
    Some(components) ->
      case dict.get(components.security_schemes, scheme_ref.scheme_name) {
        Ok(spec.Value(spec.ApiKeyScheme(
          name: header_name,
          in_: spec.SchemeInHeader,
        ))) ->
          sb
          |> se.indent(
            indent,
            "let req = request.set_header(req, \""
              <> string.lowercase(header_name)
              <> "\", "
              <> val_var
              <> ")",
          )
        Ok(spec.Value(spec.ApiKeyScheme(
          name: query_name,
          in_: spec.SchemeInQuery,
        ))) ->
          sb
          |> se.indent(
            indent,
            "let sep = case string.contains(req.path, \"?\") {",
          )
          |> se.indent(indent + 1, "True -> \"&\"")
          |> se.indent(indent + 1, "False -> \"?\"")
          |> se.indent(indent, "}")
          |> se.indent(
            indent,
            "let req = request.Request(..req, path: req.path <> sep <> \""
              <> query_name
              <> "=\" <> "
              <> val_var
              <> ")",
          )
        Ok(spec.Value(spec.ApiKeyScheme(
          name: cookie_name,
          in_: spec.SchemeInCookie,
        ))) ->
          sb
          |> se.indent(
            indent,
            "let existing = list.key_find(req.headers, \"cookie\") |> result.unwrap(\"\")",
          )
          |> se.indent(
            indent,
            "let cookie_val = \"" <> cookie_name <> "=\" <> " <> val_var,
          )
          |> se.indent(indent, "let new_cookie = case existing {")
          |> se.indent(indent + 1, "\"\" -> cookie_val")
          |> se.indent(indent + 1, "_ -> existing <> \"; \" <> cookie_val")
          |> se.indent(indent, "}")
          |> se.indent(
            indent,
            "let req = request.set_header(req, \"cookie\", new_cookie)",
          )
        Ok(spec.Value(spec.HttpScheme(scheme: "basic", ..))) ->
          sb
          |> se.indent(
            indent,
            "let req = request.set_header(req, \"authorization\", \"Basic \" <> "
              <> val_var
              <> ")",
          )
        Ok(spec.Value(spec.HttpScheme(scheme: "digest", ..))) ->
          sb
          |> se.indent(
            indent,
            "let req = request.set_header(req, \"authorization\", \"Digest \" <> "
              <> val_var
              <> ")",
          )
        Ok(spec.Value(spec.HttpScheme(scheme: "bearer", ..)))
        | Ok(spec.Value(spec.OAuth2Scheme(..)))
        | Ok(spec.Value(spec.OpenIdConnectScheme(..))) ->
          sb
          |> se.indent(
            indent,
            "let req = request.set_header(req, \"authorization\", \"Bearer \" <> "
              <> val_var
              <> ")",
          )
        Ok(spec.Value(spec.HttpScheme(scheme: scheme_name, ..))) ->
          sb
          |> se.indent(
            indent,
            "let req = request.set_header(req, \"authorization\", \""
              <> capitalize_first(scheme_name)
              <> " \" <> "
              <> val_var
              <> ")",
          )
        _ -> sb
      }
    _ -> sb
  }
}

/// Wrap a value expression with uri.percent_encode or not, based on allowReserved.
/// When allowReserved is true, reserved characters are sent as-is per OpenAPI spec.
pub fn maybe_percent_encode(
  value_expr: String,
  param: spec.Parameter(Resolved),
) -> String {
  case param.allow_reserved {
    True -> value_expr
    False -> "uri.percent_encode(" <> value_expr <> ")"
  }
}
