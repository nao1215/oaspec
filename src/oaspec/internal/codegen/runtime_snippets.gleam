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
pub const deep_object_present: String =
  "fn deep_object_present(query: Dict(String, List(String)), prefix: String, props: List(String)) -> Bool {
  list.any(props, fn(prop) { dict.has_key(query, prefix <> \"[\" <> prop <> \"]\") })
}

"

/// Emitted when at least one `deepObject` parameter declares
/// `additionalProperties` (typed or untyped).
pub const deep_object_present_any: String =
  "fn deep_object_present_any(query: Dict(String, List(String)), prefix: String) -> Bool {
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

/// Converts the raw values of untyped deep-object `additionalProperties`
/// into `Dynamic` lists of strings.
pub const coerce_dict: String =
  "fn coerce_dict(value: Dict(String, List(String))) -> Dict(String, dynamic.Dynamic) {
  dict.map_values(value, fn(_key, values) { dynamic.list(list.map(values, dynamic.string)) })
}

"

/// Emitted when any `application/x-www-form-urlencoded` request body exists.
pub const form_url_decode_and_parse_form_body: String =
  "fn form_url_decode(value: String) -> String {
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

/// Emitted when any `multipart/form-data` request body exists. The parser
/// works on bytes, so a `format: binary` part reaches the handler unchanged;
/// it uses only `gleam_stdlib`, so it runs on Erlang and JavaScript.
pub const multipart_helpers: String =
  "fn multipart_boundary(headers: Dict(String, String)) -> Result(String, Nil) {
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

fn parse_multipart_body(body: BitArray, headers: Dict(String, String)) -> Dict(String, List(BitArray)) {
  case multipart_boundary(headers) {
    Ok(boundary) ->
      multipart_split(body, bit_array.from_string(\"--\" <> boundary))
      |> list.fold(dict.new(), fn(acc, part) {
        let part = multipart_trim_crlf(part)
        case part == <<>> || part == <<\"--\":utf8>> {
          True -> acc
          False ->
            case multipart_split_once(part, <<13, 10, 13, 10>>) {
              Ok(#(raw_part_headers, value)) ->
                case bit_array.to_string(raw_part_headers) {
                  Ok(part_headers) ->
                    case multipart_name(part_headers) {
                      Ok(name) ->
                        case dict.get(acc, name) {
                          Ok(existing) -> dict.insert(acc, name, list.append(existing, [value]))
                          Error(_) -> dict.insert(acc, name, [value])
                        }
                      Error(_) -> acc
                    }
                  Error(_) -> acc
                }
              Error(_) -> acc
            }
        }
      })
    Error(_) -> dict.new()
  }
}

// The bytes between each `delimiter` of `bytes`, including the preamble
// before the first one and whatever follows the last one.
fn multipart_split(bytes: BitArray, delimiter: BitArray) -> List(BitArray) {
  multipart_split_loop(bytes, delimiter, [])
}

fn multipart_split_loop(bytes: BitArray, delimiter: BitArray, acc: List(BitArray)) -> List(BitArray) {
  case multipart_split_once(bytes, delimiter) {
    Ok(#(part, rest)) -> multipart_split_loop(rest, delimiter, [part, ..acc])
    Error(_) -> list.reverse([bytes, ..acc])
  }
}

// The bytes before and after the first `separator` in `bytes`.
fn multipart_split_once(bytes: BitArray, separator: BitArray) -> Result(#(BitArray, BitArray), Nil) {
  case separator {
    <<first, _:bytes>> ->
      case multipart_find(bytes, separator, first, 0) {
        Ok(at) -> {
          let after = at + bit_array.byte_size(separator)
          case bit_array.slice(bytes, 0, at), bit_array.slice(bytes, after, bit_array.byte_size(bytes) - after) {
            Ok(before), Ok(rest) -> Ok(#(before, rest))
            _, _ -> Error(Nil)
          }
        }
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// The offset of the first `needle` in `rest`, which starts `offset` bytes
// into the input. Only a byte equal to the needle's `first` byte is
// compared in full.
fn multipart_find(rest: BitArray, needle: BitArray, first: Int, offset: Int) -> Result(Int, Nil) {
  case rest {
    <<byte, tail:bytes>> if byte == first ->
      case bit_array.slice(rest, 0, bit_array.byte_size(needle)) {
        Ok(window) if window == needle -> Ok(offset)
        _ -> multipart_find(tail, needle, first, offset + 1)
      }
    <<_, tail:bytes>> -> multipart_find(tail, needle, first, offset + 1)
    _ -> Error(Nil)
  }
}

// The part without the CRLF that ends the delimiter line before it and the
// CRLF that belongs to the delimiter after it. The bytes in between are
// the part, unchanged.
fn multipart_trim_crlf(part: BitArray) -> BitArray {
  let part = case part {
    <<13, 10, rest:bytes>> -> rest
    _ -> part
  }
  let size = bit_array.byte_size(part)
  case bit_array.slice(part, size - 2, 2) {
    Ok(<<13, 10>>) ->
      case bit_array.slice(part, 0, size - 2) {
        Ok(value) -> value
        Error(_) -> part
      }
    _ -> part
  }
}

"

/// Emitted when a `multipart/form-data` request body has a text part. A
/// part whose bytes are not UTF-8 is left out, so a required text field
/// with such a part answers 400.
pub const multipart_text_fields: String =
  "fn multipart_text_fields(parts: Dict(String, List(BitArray))) -> Dict(String, List(String)) {
  dict.fold(parts, dict.new(), fn(acc, name, values) {
    case list.try_map(values, bit_array.to_string) {
      Ok(texts) -> dict.insert(acc, name, texts)
      Error(_) -> acc
    }
  })
}

"

/// Emitted when at least one nested form-urlencoded request body exists
/// (a body schema with `style: deepObject` properties).
pub const form_object_present: String =
  "fn form_object_present(form_body: Dict(String, List(String)), prefix: String, props: List(String)) -> Bool {
  list.any(props, fn(prop) { dict.has_key(form_body, prefix <> \"[\" <> prop <> \"]\") })
}

"

/// Cookie-parameter lookup helper. Wrapped in a `doc_comment(\"Extract a
/// cookie value from the Cookie header.\")` by the caller before being
/// spliced in.
pub const cookie_lookup: String =
  "fn cookie_lookup(headers: Dict(String, String), key: String) -> Result(String, Nil) {
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
pub const encode_dynamic: String =
  "fn encode_dynamic(value: dynamic.Dynamic) -> json.Json {
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
pub const text_body: String =
  "fn text_body(body: transport.Body) -> Result(String, ClientError) {
  case body {
    transport.TextBody(text) -> Ok(text)
    transport.BytesBody(_) -> Error(InvalidResponse(detail: \"expected text body, got bytes\"))
    transport.EmptyBody -> Error(InvalidResponse(detail: \"expected text body, got empty body\"))
  }
}

"

/// Client-side helper for binary response bodies.
pub const bytes_body: String =
  "fn bytes_body(body: transport.Body) -> Result(BitArray, ClientError) {
  case body {
    transport.BytesBody(bytes) -> Ok(bytes)
    transport.TextBody(_) -> Error(InvalidResponse(detail: \"expected binary body, got text\"))
    transport.EmptyBody -> Error(InvalidResponse(detail: \"expected binary body, got empty body\"))
  }
}

"

/// Client-side helper that maps an async transport result into the
/// generated response type.
pub const await_response: String =
  "fn await_response(
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
