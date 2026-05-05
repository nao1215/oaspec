import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import oaspec/config
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/codegen/guards
import oaspec/internal/codegen/import_analysis
import oaspec/internal/openapi/schema.{Inline, Reference}
import oaspec/internal/openapi/spec.{ParameterSchema, Value}
import oaspec/internal/util/content_type as ct_util

/// Structured import / helper requirements for client generation.
pub type ClientRequirements {
  ClientRequirements(
    needs_bool: Bool,
    needs_float: Bool,
    has_multi_content_response: Bool,
    has_form_urlencoded: Bool,
    has_multipart: Bool,
    needs_list: Bool,
    needs_dyn_decode: Bool,
    needs_json: Bool,
    needs_string: Bool,
    needs_typed_schemas: Bool,
    needs_option_type: Bool,
    needs_some_ctor: Bool,
    needs_none_ctor: Bool,
    needs_int: Bool,
    needs_bytes_helper: Bool,
    needs_text_helper: Bool,
    needs_uri: Bool,
    needs_guards: Bool,
  )
}

/// Compute semantic requirements for the generated client module.
pub fn analyze(ctx: Context) -> ClientRequirements {
  let operations = context.operations(ctx)
  let all_params =
    list.flat_map(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.filter_map(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) -> Ok(p)
          _ -> Error(Nil)
        }
      })
    })

  let needs_bool =
    list.any(all_params, fn(p) {
      case p.payload {
        ParameterSchema(Inline(schema.BooleanSchema(..))) -> True
        _ -> False
      }
    })
  let needs_float_param =
    list.any(all_params, fn(p) {
      case p.payload {
        ParameterSchema(Inline(schema.NumberSchema(..))) -> True
        _ -> False
      }
    })
  let has_multi_content_response =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) -> list.length(dict.to_list(response.content)) > 1
          _ -> False
        }
      })
    })

  let has_form_urlencoded =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(Value(rb)) ->
          list.any(dict.to_list(rb.content), fn(ce) {
            let #(key, _) = ce
            key == "application/x-www-form-urlencoded"
          })
        _ -> False
      }
    })

  let has_multipart =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(Value(rb)) ->
          list.any(dict.to_list(rb.content), fn(ce) {
            let #(key, _) = ce
            key == "multipart/form-data"
          })
        _ -> False
      }
    })

  // Issue #387: when any response declares `headers:`, the client
  // assembles a typed headers record by calling `list.key_find` on
  // `resp.headers`. That makes `gleam/list` mandatory and (for any
  // optional header field) brings `Some`/`None` into the body of the
  // function. Track both signals here so the import builder picks up
  // the right shapes.
  let has_response_headers =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) -> dict.size(response.headers) > 0
          _ -> False
        }
      })
    })
  let has_optional_response_headers =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) ->
            list.any(dict.to_list(response.headers), fn(h_entry) {
              let #(_, header) = h_entry
              !header.required
            })
          _ -> False
        }
      })
    })

  let needs_list =
    has_form_urlencoded
    || has_multi_content_response
    || has_response_headers
    || list.any(all_params, fn(p) { p.in_ == spec.InQuery })
    || list.any(all_params, fn(p) { p.in_ == spec.InCookie })
    || list.any(all_params, fn(p) { p.in_ == spec.InHeader })
    || list.any(all_params, fn(p) {
      case p.payload {
        ParameterSchema(Inline(schema.ArraySchema(..))) -> True
        ParameterSchema(Reference(..) as sr) ->
          case context.resolve_schema_ref(sr, ctx) {
            Ok(schema.ArraySchema(..)) -> True
            _ -> False
          }
        _ -> False
      }
    })

  let needs_dyn_decode =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) ->
            list.any(dict.to_list(response.content), fn(ce) {
              let #(media_type_name, mt) = ce
              case media_type_name {
                "text/plain" -> False
                _ ->
                  case mt.schema {
                    // Issue #493 / CodeRabbit follow-up: array
                    // responses keyed by `$ref` items also go
                    // through `dyn_decode.list(...)` now (instead
                    // of the synthetic `decode_<name>_list`
                    // wrapper), so the import must fire for them
                    // too. Without this, generated client code
                    // references `dyn_decode.list` without
                    // importing the module.
                    Some(Inline(schema.ArraySchema(items: _, ..))) -> True
                    Some(Inline(schema.StringSchema(..))) -> True
                    Some(Inline(schema.IntegerSchema(..))) -> True
                    Some(Inline(schema.NumberSchema(..))) -> True
                    Some(Inline(schema.BooleanSchema(..))) -> True
                    _ -> False
                  }
              }
            })
          _ -> False
        }
      })
    })

  let needs_json =
    needs_dyn_decode
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(Value(rb)) ->
          list.any(dict.to_list(rb.content), fn(ce) {
            let #(ct_name, mt) = ce
            // Issue #485: an `application/octet-stream` body is
            // wrapped via `transport.BytesBody`, not
            // `json.to_string`, so a `type: string, format: binary`
            // request body must not pull in `gleam/json`.
            case ct_util.from_string(ct_name) {
              ct_util.ApplicationOctetStream | ct_util.Wildcard -> False
              _ ->
                case mt.schema {
                  Some(Inline(schema.StringSchema(..))) -> True
                  Some(Inline(schema.IntegerSchema(..))) -> True
                  Some(Inline(schema.NumberSchema(..))) -> True
                  Some(Inline(schema.BooleanSchema(..))) -> True
                  _ -> False
                }
            }
          })
        _ -> False
      }
    })

  let needs_string =
    has_multi_content_response
    || has_form_urlencoded
    || has_multipart
    || list.any(all_params, fn(p) {
      p.in_ == spec.InPath || p.in_ == spec.InCookie
    })

  let needs_typed_schemas =
    import_analysis.operations_need_typed_schemas(operations)
  // `needs_option_type` represents the bare `Option(...)` type
  // appearing in client function SIGNATURES. Optional response
  // headers do not surface in signatures (only as `Some`/`None`
  // constructors inside function bodies), so they are not added
  // here — Issue #387.
  let needs_option_type =
    import_analysis.operations_have_optional_params(operations)
    || import_analysis.operations_have_optional_body(operations)
  let needs_some_ctor =
    needs_option_type
    || has_optional_response_headers
    || any_operation_has_server(ctx)
  let needs_none_ctor =
    needs_option_type
    || has_optional_response_headers
    || any_operation_has_no_server(ctx)

  // Issue #387: typed response headers (`type: integer`, `type: number`)
  // are extracted via `int.parse` / `float.parse`, so we must import
  // those modules whenever any operation declares such a header.
  let has_int_response_header =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) ->
            list.any(dict.to_list(response.headers), fn(h_entry) {
              let #(_, header) = h_entry
              case header.schema {
                Some(Inline(schema.IntegerSchema(..))) -> True
                _ -> False
              }
            })
          _ -> False
        }
      })
    })
  let has_float_response_header =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) ->
            list.any(dict.to_list(response.headers), fn(h_entry) {
              let #(_, header) = h_entry
              case header.schema {
                Some(Inline(schema.NumberSchema(..))) -> True
                _ -> False
              }
            })
          _ -> False
        }
      })
    })

  let needs_int =
    has_int_response_header
    || list.any(all_params, fn(p) {
      case p.payload {
        ParameterSchema(Inline(schema.IntegerSchema(..))) -> True
        ParameterSchema(Inline(schema.ArraySchema(
          items: Inline(schema.IntegerSchema(..)),
          ..,
        ))) -> True
        ParameterSchema(Reference(..) as sr) ->
          case context.resolve_schema_ref(sr, ctx) {
            Ok(schema.IntegerSchema(..)) -> True
            Ok(schema.ArraySchema(items: Inline(schema.IntegerSchema(..)), ..)) ->
              True
            _ -> False
          }
        _ -> False
      }
    })

  let needs_float = needs_float_param || has_float_response_header

  let needs_bytes_helper =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) ->
            list.any(dict.to_list(response.content), fn(ce) {
              let #(name, _) = ce
              case ct_util.from_string(name) {
                ct_util.ApplicationOctetStream | ct_util.Wildcard -> True
                _ -> False
              }
            })
          _ -> False
        }
      })
    })

  let needs_text_helper =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) ->
            list.any(dict.to_list(response.content), fn(ce) {
              let #(_, mt) = ce
              case mt.schema {
                Some(_) -> True
                None -> False
              }
            })
          _ -> False
        }
      })
    })

  let needs_uri =
    has_form_urlencoded
    || list.any(all_params, fn(p) {
      p.in_ == spec.InPath || p.in_ == spec.InCookie
    })

  let needs_guards =
    config.validate(context.config(ctx))
    && list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(Value(rb)) -> {
          let content_entries = dict.to_list(rb.content)
          case content_entries {
            [#(_, mt)] ->
              case mt.schema {
                Some(schema.Reference(name:, ..)) ->
                  guards.schema_has_validator(name, ctx)
                _ -> False
              }
            _ -> False
          }
        }
        _ -> False
      }
    })

  ClientRequirements(
    needs_bool: needs_bool,
    needs_float: needs_float,
    has_multi_content_response: has_multi_content_response,
    has_form_urlencoded: has_form_urlencoded,
    has_multipart: has_multipart,
    needs_list: needs_list,
    needs_dyn_decode: needs_dyn_decode,
    needs_json: needs_json,
    needs_string: needs_string,
    needs_typed_schemas: needs_typed_schemas,
    needs_option_type: needs_option_type,
    needs_some_ctor: needs_some_ctor,
    needs_none_ctor: needs_none_ctor,
    needs_int: needs_int,
    needs_bytes_helper: needs_bytes_helper,
    needs_text_helper: needs_text_helper,
    needs_uri: needs_uri,
    needs_guards: needs_guards,
  )
}

/// Optional `gleam/option` import line for client signatures and ctors.
fn option_import(requirements: ClientRequirements) -> Option(String) {
  case
    requirements.needs_option_type,
    requirements.needs_some_ctor,
    requirements.needs_none_ctor
  {
    True, _, _ -> Some("gleam/option.{type Option, None, Some}")
    False, True, True -> Some("gleam/option.{None, Some}")
    False, True, False -> Some("gleam/option.{Some}")
    False, False, True -> Some("gleam/option.{None}")
    False, False, False -> None
  }
}

/// Render the final import list from structured requirements.
pub fn imports(requirements: ClientRequirements, ctx: Context) -> List(String) {
  let base_imports = [
    "gleam/result",
    "oaspec/transport",
    config.package(context.config(ctx)) <> "/decode",
    config.package(context.config(ctx)) <> "/response_types",
  ]
  let base_imports = case requirements.needs_int {
    True -> ["gleam/int", ..base_imports]
    False -> base_imports
  }
  let base_imports = case option_import(requirements) {
    Some(import_line) -> [import_line, ..base_imports]
    None -> base_imports
  }
  let base_imports = case requirements.needs_typed_schemas {
    True ->
      list.append(
        [
          config.package(context.config(ctx)) <> "/types",
          config.package(context.config(ctx)) <> "/encode",
        ],
        base_imports,
      )
    False -> base_imports
  }
  let base_imports = [
    config.package(context.config(ctx)) <> "/request_types",
    ..base_imports
  ]
  let base_imports = case requirements.needs_string {
    True -> ["gleam/string", ..base_imports]
    False -> base_imports
  }
  let imports = case requirements.needs_dyn_decode {
    True -> ["gleam/dynamic/decode as dyn_decode", ..base_imports]
    False -> base_imports
  }
  let imports = case requirements.needs_json {
    True -> ["gleam/json", ..imports]
    False -> imports
  }
  let imports = case requirements.needs_bool {
    True -> ["gleam/bool", ..imports]
    False -> imports
  }
  let imports = case requirements.needs_float {
    True -> ["gleam/float", ..imports]
    False -> imports
  }
  let imports = case requirements.needs_list {
    True -> ["gleam/list", ..imports]
    False -> imports
  }
  let imports = case requirements.needs_uri {
    True -> ["gleam/uri", ..imports]
    False -> imports
  }
  case requirements.needs_guards {
    True -> [config.package(context.config(ctx)) <> "/guards", ..imports]
    False -> imports
  }
}

fn any_operation_has_server(ctx: Context) -> Bool {
  list.any(context.operations(ctx), fn(op) {
    let #(_, operation, _, _) = op
    case operation.servers {
      [] ->
        case context.spec(ctx).servers {
          [] -> False
          _ -> True
        }
      _ -> True
    }
  })
}

fn any_operation_has_no_server(ctx: Context) -> Bool {
  list.any(context.operations(ctx), fn(op) {
    let #(_, operation, _, _) = op
    case operation.servers {
      [] ->
        case context.spec(ctx).servers {
          [] -> True
          _ -> False
        }
      _ -> False
    }
  })
}
