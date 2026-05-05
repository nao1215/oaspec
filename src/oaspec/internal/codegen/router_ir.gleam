import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oaspec/config
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/codegen/guards
import oaspec/internal/codegen/import_analysis
import oaspec/internal/codegen/server_request_decode as decode_helpers
import oaspec/internal/openapi/schema.{Inline, Reference}
import oaspec/internal/openapi/spec.{type Resolved, Value}
import oaspec/internal/util/content_type
import oaspec/internal/util/naming

/// Structured requirements for router generation.
pub type RouterRequirements {
  RouterRequirements(
    has_deep_object: Bool,
    has_deep_object_with_ap: Bool,
    needs_deep_object_present: Bool,
    has_deep_object_untyped_ap: Bool,
    has_form_urlencoded_body: Bool,
    has_multipart_body: Bool,
    has_binary_request_body: Bool,
    needs_bit_array_import: Bool,
    has_nested_form_urlencoded_body: Bool,
    needs_int: Bool,
    needs_float: Bool,
    needs_bool: Bool,
    needs_string: Bool,
    needs_cookie_lookup: Bool,
    needs_list_import: Bool,
    needs_uri_import: Bool,
    needs_option: Bool,
    needs_json: Bool,
    needs_json_for_guards: Bool,
    needs_decode: Bool,
    needs_encode: Bool,
    uses_query: Bool,
    uses_headers: Bool,
    uses_body: Bool,
    has_params_ops: Bool,
    has_enum_ref_params: Bool,
    needs_guards: Bool,
  )
}

/// Compute semantic requirements for the generated router module.
pub fn analyze(ctx: Context) -> RouterRequirements {
  let operations = context.operations(ctx)

  let has_deep_object =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) -> decode_helpers.is_deep_object_param(p, ctx)
          _ -> False
        }
      })
    })
  let has_deep_object_with_ap =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            decode_helpers.is_deep_object_param(p, ctx)
            && decode_helpers.deep_object_has_additional_properties(p, ctx)
          _ -> False
        }
      })
    })
  let needs_deep_object_present =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            decode_helpers.is_deep_object_param(p, ctx)
            && !p.required
            && !decode_helpers.deep_object_has_untyped_additional_properties(
              p,
              ctx,
            )
          _ -> False
        }
      })
    })
  let has_deep_object_untyped_ap =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            decode_helpers.is_deep_object_param(p, ctx)
            && decode_helpers.deep_object_has_untyped_additional_properties(
              p,
              ctx,
            )
          _ -> False
        }
      })
    })
  let has_form_urlencoded_body =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      decode_helpers.operation_uses_form_urlencoded_body(operation)
    })
  let has_multipart_body =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      decode_helpers.operation_uses_multipart_body(operation)
    })
  // Issue #485: when any operation declares
  // `application/octet-stream` on its request body, the route
  // function takes `body: BitArray` instead of `body: String` so
  // arbitrary binary payloads round-trip without being forced
  // through `bit_array.to_string`. Specs without any binary
  // request body keep the existing `body: String` signature.
  let has_binary_request_body =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      decode_helpers.operation_uses_octet_stream_body(operation)
    })
  // The route arms shadow `body` with the String conversion
  // only for non-binary arms that actually have a request body.
  // The `bit_array` / `result` imports are needed iff at least
  // one such arm exists alongside a binary one.
  let needs_bit_array_import =
    has_binary_request_body
    && list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      option.is_some(operation.request_body)
      && !decode_helpers.operation_uses_octet_stream_body(operation)
    })
  let has_nested_form_urlencoded_body =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(Value(rb)) ->
          decode_helpers.form_urlencoded_body_has_nested_object(rb, ctx)
        _ -> False
      }
    })

  let needs_int =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            decode_helpers.query_schema_needs_int(spec.parameter_schema(p), ctx)
            || decode_helpers.deep_object_param_needs_int(p, ctx)
          _ -> False
        }
      })
      || case operation.request_body {
        Some(Value(rb)) ->
          decode_helpers.form_urlencoded_body_needs_int(rb, ctx)
        _ -> False
      }
      || case operation.request_body {
        Some(Value(rb)) -> decode_helpers.multipart_body_needs_int(rb, ctx)
        _ -> False
      }
    })
    || operations_have_response_header_of_type(operations, "Int")

  let needs_float =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            decode_helpers.query_schema_needs_float(
              spec.parameter_schema(p),
              ctx,
            )
            || decode_helpers.deep_object_param_needs_float(p, ctx)
          _ -> False
        }
      })
      || case operation.request_body {
        Some(Value(rb)) ->
          decode_helpers.form_urlencoded_body_needs_float(rb, ctx)
        _ -> False
      }
      || case operation.request_body {
        Some(Value(rb)) -> decode_helpers.multipart_body_needs_float(rb, ctx)
        _ -> False
      }
    })
    || operations_have_response_header_of_type(operations, "Float")

  let needs_bool = operations_have_response_header_of_type(operations, "Bool")

  let needs_string =
    has_form_urlencoded_body
    || has_multipart_body
    || has_deep_object_with_ap
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            case p.in_ {
              spec.InCookie -> True
              spec.InQuery | spec.InHeader ->
                decode_helpers.query_schema_needs_string(spec.parameter_schema(
                  p,
                ))
                || decode_helpers.deep_object_param_needs_string(p, ctx)
              spec.InPath ->
                decode_helpers.query_schema_needs_string(spec.parameter_schema(
                  p,
                ))
            }
          _ -> False
        }
      })
      || case operation.request_body {
        Some(Value(rb)) ->
          decode_helpers.form_urlencoded_body_needs_string(rb, ctx)
        _ -> False
      }
    })

  let needs_cookie_lookup =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) -> p.in_ == spec.InCookie
          _ -> False
        }
      })
    })

  let needs_list_import =
    needs_cookie_lookup
    || has_deep_object
    || has_form_urlencoded_body
    || has_multipart_body
    || operations_have_response_headers(operations)
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            case p.in_, spec.parameter_schema(p) {
              spec.InQuery, Some(Inline(schema.ArraySchema(..))) -> True
              spec.InHeader, Some(Inline(schema.ArraySchema(..))) -> True
              _, _ -> False
            }
          _ -> False
        }
      })
    })
  let needs_uri_import = needs_cookie_lookup || has_form_urlencoded_body

  let needs_option =
    import_analysis.operations_have_optional_params(operations)
    || import_analysis.operations_have_optional_body(operations)
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      let has_optional_deep_object_fields =
        list.any(operation.parameters, fn(ref_p) {
          case ref_p {
            Value(p) ->
              decode_helpers.deep_object_param_has_optional_fields(p, ctx)
            _ -> False
          }
        })
      let has_optional_form_urlencoded_fields = case operation.request_body {
        Some(Value(rb)) ->
          decode_helpers.form_urlencoded_body_has_optional_fields(rb, ctx)
        _ -> False
      }
      let has_optional_multipart_fields = case operation.request_body {
        Some(Value(rb)) ->
          decode_helpers.multipart_body_has_optional_fields(rb, ctx)
        _ -> False
      }
      has_optional_deep_object_fields
      || has_optional_form_urlencoded_fields
      || has_optional_multipart_fields
    })
    || operations_have_optional_response_header(operations)

  let needs_json =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(dict.to_list(operation.responses), fn(entry) {
        let #(_, ref_or) = entry
        case ref_or {
          Value(response) -> {
            let content_entries = dict.to_list(response.content)
            case content_entries {
              [#(media_type_name, media_type)] ->
                case content_type.is_json_compatible(media_type_name) {
                  True ->
                    case media_type.schema {
                      Some(_) -> True
                      None -> False
                    }
                  False -> False
                }
              _ -> False
            }
          }
          _ -> False
        }
      })
    })

  let needs_decode =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      case operation.request_body {
        Some(Value(rb)) ->
          list.any(dict.to_list(rb.content), fn(entry) {
            let #(content_type_name, _) = entry
            content_type.is_json_compatible(content_type_name)
          })
        _ -> False
      }
    })

  let uses_query =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) -> p.in_ == spec.InQuery
          _ -> False
        }
      })
    })

  let uses_headers =
    has_multipart_body
    || list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) -> p.in_ == spec.InHeader || p.in_ == spec.InCookie
          _ -> False
        }
      })
    })

  let uses_body =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      option.is_some(operation.request_body)
    })

  let has_params_ops =
    list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      !list.is_empty(operation.parameters)
      || option.is_some(operation.request_body)
    })

  let has_enum_ref_params =
    decode_helpers.operations_have_enum_ref_params(operations, ctx)

  let needs_guards =
    config.validate(context.config(ctx))
    && list.any(operations, fn(op) {
      let #(_, operation, _, _) = op
      operation_needs_guard_validation(operation, ctx)
    })
  let needs_json_for_guards = needs_guards

  RouterRequirements(
    has_deep_object: has_deep_object,
    has_deep_object_with_ap: has_deep_object_with_ap,
    needs_deep_object_present: needs_deep_object_present,
    has_deep_object_untyped_ap: has_deep_object_untyped_ap,
    has_form_urlencoded_body: has_form_urlencoded_body,
    has_multipart_body: has_multipart_body,
    has_binary_request_body: has_binary_request_body,
    needs_bit_array_import: needs_bit_array_import,
    has_nested_form_urlencoded_body: has_nested_form_urlencoded_body,
    needs_int: needs_int,
    needs_float: needs_float,
    needs_bool: needs_bool,
    needs_string: needs_string,
    needs_cookie_lookup: needs_cookie_lookup,
    needs_list_import: needs_list_import,
    needs_uri_import: needs_uri_import,
    needs_option: needs_option,
    needs_json: needs_json,
    needs_json_for_guards: needs_json_for_guards,
    needs_decode: needs_decode,
    needs_encode: needs_json,
    uses_query: uses_query,
    uses_headers: uses_headers,
    uses_body: uses_body,
    has_params_ops: has_params_ops,
    has_enum_ref_params: has_enum_ref_params,
    needs_guards: needs_guards,
  )
}

/// Render the final import list from structured requirements.
pub fn imports(requirements: RouterRequirements, ctx: Context) -> List(String) {
  let std_imports = ["gleam/dict.{type Dict}"]
  let std_imports = case requirements.needs_list_import {
    True -> list.append(std_imports, ["gleam/list"])
    False -> std_imports
  }
  let std_imports = case requirements.needs_uri_import {
    True -> list.append(std_imports, ["gleam/uri"])
    False -> std_imports
  }
  let std_imports = case requirements.needs_int {
    True -> list.append(std_imports, ["gleam/int"])
    False -> std_imports
  }
  let std_imports = case requirements.needs_float {
    True -> list.append(std_imports, ["gleam/float"])
    False -> std_imports
  }
  let std_imports = case requirements.needs_bool {
    True -> list.append(std_imports, ["gleam/bool"])
    False -> std_imports
  }
  let std_imports = case requirements.needs_option {
    True -> list.append(std_imports, ["gleam/option.{None, Some}"])
    False -> std_imports
  }
  let std_imports = case
    requirements.needs_json || requirements.needs_json_for_guards
  {
    True -> list.append(std_imports, ["gleam/json"])
    False -> std_imports
  }
  let std_imports = case requirements.needs_string {
    True -> list.append(std_imports, ["gleam/string"])
    False -> std_imports
  }
  let std_imports = case requirements.has_deep_object_untyped_ap {
    True -> list.append(std_imports, ["gleam/dynamic"])
    False -> std_imports
  }
  // Issue #485: when the route signature is `body: BitArray`
  // and at least one non-binary arm exists, every non-binary
  // arm shadows `body` with
  // `bit_array.to_string(body) |> result.unwrap("")`, so both
  // `gleam/bit_array` and `gleam/result` need to be imported.
  // Pure-binary specs skip the imports to avoid unused warnings.
  let std_imports = case requirements.needs_bit_array_import {
    True -> list.append(std_imports, ["gleam/bit_array", "gleam/result"])
    False -> std_imports
  }

  let pkg_imports = [
    config.package(context.config(ctx)) <> "/handlers",
    config.package(context.config(ctx)) <> "/handlers_generated",
  ]
  let pkg_imports = case
    requirements.has_deep_object
    || requirements.has_form_urlencoded_body
    || requirements.has_multipart_body
    || requirements.has_enum_ref_params
  {
    True ->
      list.append(pkg_imports, [config.package(context.config(ctx)) <> "/types"])
    False -> pkg_imports
  }
  let pkg_imports = case requirements.needs_decode {
    True ->
      list.append(pkg_imports, [
        config.package(context.config(ctx)) <> "/decode",
      ])
    False -> pkg_imports
  }
  let pkg_imports = case requirements.needs_encode {
    True ->
      list.append(pkg_imports, [
        config.package(context.config(ctx)) <> "/encode",
      ])
    False -> pkg_imports
  }
  let pkg_imports = case requirements.has_params_ops {
    True ->
      list.append(pkg_imports, [
        config.package(context.config(ctx)) <> "/request_types",
        config.package(context.config(ctx)) <> "/response_types",
      ])
    False ->
      list.append(pkg_imports, [
        config.package(context.config(ctx)) <> "/response_types",
      ])
  }
  let pkg_imports = case requirements.needs_guards {
    True ->
      list.append(pkg_imports, [
        config.package(context.config(ctx)) <> "/guards",
      ])
    False -> pkg_imports
  }

  list.append(std_imports, pkg_imports)
}

fn operation_needs_guard_validation(
  operation: spec.Operation(Resolved),
  ctx: Context,
) -> Bool {
  let needs_body_guard = case operation.request_body {
    Some(Value(rb)) -> {
      let content_entries = dict.to_list(rb.content)
      case content_entries {
        [#(_, mt)] ->
          case mt.schema {
            Some(Inline(schema.ObjectSchema(..)))
            | Some(Inline(schema.AllOfSchema(..))) -> True
            Some(Reference(name:, ..)) -> guards.schema_has_validator(name, ctx)
            _ -> False
          }
        _ -> False
      }
    }
    _ -> False
  }
  config.validate(context.config(ctx)) && needs_body_guard
}

fn operations_have_response_headers(
  operations: List(context.AnalyzedOperation),
) -> Bool {
  list.any(operations, fn(op) {
    let #(_, operation, _, _) = op
    list.any(dict.to_list(operation.responses), fn(entry) {
      let #(_, ref_or) = entry
      case ref_or {
        Value(response) -> !dict.is_empty(response.headers)
        _ -> False
      }
    })
  })
}

fn operations_have_response_header_of_type(
  operations: List(context.AnalyzedOperation),
  type_name: String,
) -> Bool {
  list.any(operations, fn(op) {
    let #(_, operation, _, _) = op
    list.any(dict.to_list(operation.responses), fn(entry) {
      let #(_, ref_or) = entry
      case ref_or {
        Value(response) ->
          list.any(sorted_header_specs(response.headers), fn(spec) {
            spec.field_type == type_name
          })
        _ -> False
      }
    })
  })
}

fn operations_have_optional_response_header(
  operations: List(context.AnalyzedOperation),
) -> Bool {
  list.any(operations, fn(op) {
    let #(_, operation, _, _) = op
    list.any(dict.to_list(operation.responses), fn(entry) {
      let #(_, ref_or) = entry
      case ref_or {
        Value(response) ->
          list.any(sorted_header_specs(response.headers), fn(spec) {
            !spec.required
          })
        _ -> False
      }
    })
  })
}

type HeaderSpec {
  HeaderSpec(
    header_name: String,
    field_name: String,
    field_type: String,
    required: Bool,
  )
}

fn sorted_header_specs(
  headers: dict.Dict(String, spec.Header),
) -> List(HeaderSpec) {
  headers
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.map(fn(entry) {
    let #(header_name, header) = entry
    let field_name = naming.to_snake_case(header_name)
    let field_type = response_header_field_type(header.schema)
    HeaderSpec(
      header_name: header_name,
      field_name: field_name,
      field_type: field_type,
      required: header.required,
    )
  })
}

fn response_header_field_type(
  schema_opt: option.Option(schema.SchemaRef),
) -> String {
  case schema_opt {
    Some(Inline(schema.IntegerSchema(..))) -> "Int"
    Some(Inline(schema.NumberSchema(..))) -> "Float"
    Some(Inline(schema.BooleanSchema(..))) -> "Bool"
    Some(Inline(schema.StringSchema(..))) -> "String"
    Some(Reference(name:, ..)) -> "types." <> naming.schema_to_type_name(name)
    _ -> "String"
  }
}
