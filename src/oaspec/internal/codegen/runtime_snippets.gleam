//// Static runtime helper snippets spliced into generated code.
////
//// Each constant is emitted byte-for-byte (via `string_extra.raw`) when its
//// gating flag in `RouterRequirements` / encoder analysis / client analysis
//// holds. Lifting them out of the original `se.line` / `se.indent` chains in
//// `server` / `encoders` / `client` keeps the generator functions short and
//// makes the snippet bodies trivially diff-able.
////
//// Each snippet ends with a trailing newline + blank line so the caller
//// can chain the next emission immediately without an explicit
//// `se.blank_line()` afterwards.

/// Emitted when at least one optional `deepObject` query parameter exists
/// and that parameter has no `additionalProperties` entry.
pub const deep_object_present: String = "fn deep_object_present(query: Dict(String, List(String)), prefix: String, props: List(String)) -> Bool {
  list.any(props, fn(prop) { dict.has_key(query, prefix <> \"[\" <> prop <> \"]\") })
}

"

/// Emitted when at least one `deepObject` parameter declares
/// `additionalProperties` (typed or untyped).
pub const deep_object_present_any: String = "fn deep_object_present_any(query: Dict(String, List(String)), prefix: String) -> Bool {
  let prefix_bracket = prefix <> \"[\"
  dict.fold(query, False, fn(found, k, _v) { found || string.starts_with(k, prefix_bracket) })
}

fn deep_object_additional_properties(query: Dict(String, List(String)), prefix: String, known_props: List(String)) -> Dict(String, List(String)) {
  let prefix_bracket = prefix <> \"[\"
  let prefix_len = string.length(prefix_bracket)
  dict.fold(query, dict.new(), fn(acc, k, v) {
    case string.starts_with(k, prefix_bracket) && string.ends_with(k, \"]\") {
      True -> {
        let prop = string.slice(k, prefix_len, string.length(k) - prefix_len - 1)
        case list.contains(known_props, prop) { True -> acc False -> dict.insert(acc, prop, v) }
      }
      False -> acc
    }
  })
}

"

/// Type-safe identity coercion used when `deepObject` parameters have
/// untyped `additionalProperties` (Dynamic value type).
pub const coerce_dict: String = "@external(erlang, \"gleam_stdlib\", \"identity\")
fn coerce_dict(value: Dict(String, List(String))) -> Dict(String, dynamic.Dynamic)

"

/// Emitted when any `application/x-www-form-urlencoded` request body exists.
pub const form_url_decode_and_parse_form_body: String = "fn form_url_decode(value: String) -> String {
  let value = string.replace(value, \"+\", \" \")
  case uri.percent_decode(value) { Ok(decoded) -> decoded Error(_) -> value }
}

fn parse_form_body(body: String) -> Dict(String, List(String)) {
  let parts = case body { \"\" -> [] _ -> string.split(body, \"&\") }
  list.fold(parts, dict.new(), fn(acc, part) {
    case part {
      \"\" -> acc
      _ ->
        case string.split_once(part, on: \"=\") {
          Ok(#(raw_key, raw_value)) -> {
            let key = form_url_decode(raw_key)
            let value = form_url_decode(raw_value)
            case dict.get(acc, key) {
              Ok(existing) -> dict.insert(acc, key, list.append(existing, [value]))
              Error(_) -> dict.insert(acc, key, [value])
            }
          }
          Error(_) -> {
            let key = form_url_decode(part)
            case dict.get(acc, key) {
              Ok(existing) -> dict.insert(acc, key, list.append(existing, [\"\"]))
              Error(_) -> dict.insert(acc, key, [\"\"])
            }
          }
        }
    }
  })
}

"

/// Emitted when any `multipart/form-data` request body exists.
pub const multipart_helpers: String = "fn multipart_boundary(headers: Dict(String, String)) -> Result(String, Nil) {
  case dict.get(headers, \"content-type\") {
    Ok(content_type) ->
      list.find_map(string.split(content_type, \";\"), fn(part) {
        let trimmed = string.trim(part)
        case string.starts_with(trimmed, \"boundary=\") {
          True -> Ok(string.replace(trimmed, \"boundary=\", \"\"))
          False -> Error(Nil)
        }
      })
    Error(_) -> Error(Nil)
  }
}

fn multipart_name(raw_headers: String) -> Result(String, Nil) {
  list.find_map(string.split(raw_headers, \"\\r\\n\"), fn(line) {
    case string.contains(line, \"name=\") {
      True ->
        list.find_map(string.split(line, \";\"), fn(part) {
          let trimmed = string.trim(part)
          case string.starts_with(trimmed, \"name=\") {
            True -> Ok(string.replace(string.replace(trimmed, \"name=\", \"\"), \"\\\"\", \"\"))
            False -> Error(Nil)
          }
        })
      False -> Error(Nil)
    }
  })
}

fn parse_multipart_body(body: String, headers: Dict(String, String)) -> Dict(String, List(String)) {
  case multipart_boundary(headers) {
    Ok(boundary) -> {
      let delimiter = \"--\" <> boundary
      let parts = string.split(body, delimiter)
      list.fold(parts, dict.new(), fn(acc, part) {
        let normalized_part = part |> string.remove_prefix(\"\\r\\n\") |> string.remove_suffix(\"\\r\\n\")
        case normalized_part == \"\" || normalized_part == \"--\" {
          True -> acc
          False ->
            case string.split_once(normalized_part, on: \"\\r\\n\\r\\n\") {
              Ok(#(raw_part_headers, raw_value)) ->
                case multipart_name(raw_part_headers) {
                  Ok(name) -> {
                    let value = raw_value
                    case dict.get(acc, name) {
                      Ok(existing) -> dict.insert(acc, name, list.append(existing, [value]))
                      Error(_) -> dict.insert(acc, name, [value])
                    }
                  }
                  Error(_) -> acc
                }
              Error(_) -> acc
            }
        }
      })
    }
    Error(_) -> dict.new()
  }
}

"

/// Emitted when at least one nested form-urlencoded request body exists
/// (a body schema with `style: deepObject` properties).
pub const form_object_present: String = "fn form_object_present(form_body: Dict(String, List(String)), prefix: String, props: List(String)) -> Bool {
  list.any(props, fn(prop) { dict.has_key(form_body, prefix <> \"[\" <> prop <> \"]\") })
}

"

/// Cookie-parameter lookup helper. Wrapped in a `doc_comment(\"Extract a
/// cookie value from the Cookie header.\")` by the caller before being
/// spliced in.
pub const cookie_lookup: String = "fn cookie_lookup(headers: Dict(String, String), key: String) -> Result(String, Nil) {
  case dict.get(headers, \"cookie\") {
    Ok(raw) ->
      list.find_map(string.split(raw, \";\"), fn(part) {
        let trimmed = string.trim(part)
        case string.split_once(trimmed, on: \"=\") {
          Ok(#(cookie_key, cookie_value)) ->
            case string.trim(cookie_key) == key {
              True -> uri.percent_decode(string.trim(cookie_value))
              False -> Error(Nil)
            }
          Error(_) -> Error(Nil)
        }
      })
    Error(_) -> Error(Nil)
  }
}

"

/// Encoder for untyped `additionalProperties: true` schemas — inspects the
/// runtime type of each Dynamic value.
pub const encode_dynamic: String = "fn encode_dynamic(value: dynamic.Dynamic) -> json.Json {
  case dynamic.classify(value) {
    \"String\" ->
      case decode.run(value, decode.string) {
        Ok(s) -> json.string(s)
        Error(_) -> json.null()
      }
    \"Int\" ->
      case decode.run(value, decode.int) {
        Ok(i) -> json.int(i)
        Error(_) -> json.null()
      }
    \"Float\" ->
      case decode.run(value, decode.float) {
        Ok(f) -> json.float(f)
        Error(_) -> json.null()
      }
    \"Bool\" ->
      case decode.run(value, decode.bool) {
        Ok(b) -> json.bool(b)
        Error(_) -> json.null()
      }
    \"Nil\" -> json.null()
    _ -> json.null()
  }
}

"

/// Client-side helper that extracts a UTF-8 string from a `transport.Body`,
/// surfacing `InvalidResponse` for non-text bodies.
pub const text_body: String = "fn text_body(body: transport.Body) -> Result(String, ClientError) {
  case body {
    transport.TextBody(text) -> Ok(text)
    transport.BytesBody(_) -> Error(InvalidResponse(detail: \"expected text body, got bytes\"))
    transport.EmptyBody -> Error(InvalidResponse(detail: \"expected text body, got empty body\"))
  }
}

"

/// Client-side helper for binary response bodies.
pub const bytes_body: String = "fn bytes_body(body: transport.Body) -> Result(BitArray, ClientError) {
  case body {
    transport.BytesBody(bytes) -> Ok(bytes)
    transport.TextBody(_) -> Error(InvalidResponse(detail: \"expected binary body, got text\"))
    transport.EmptyBody -> Error(InvalidResponse(detail: \"expected binary body, got empty body\"))
  }
}

"

/// Client-side helper that maps an async transport result into the
/// generated response type.
pub const await_response: String = "fn await_response(
  response_async: transport.Async(Result(transport.Response, transport.TransportError)),
  decode: fn(transport.Response) -> Result(a, ClientError),
) -> transport.Async(Result(a, ClientError)) {
  response_async
  |> transport.map(fn(resp_result) {
    resp_result |> result.map_error(TransportError)
  })
  |> transport.map_try(decode)
}

"
