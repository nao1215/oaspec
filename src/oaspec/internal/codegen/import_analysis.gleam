import gleam/dict
import gleam/list
import gleam/option.{Some}
import oaspec/openapi/schema.{AllOfSchema, Inline, ObjectSchema, Reference}
import oaspec/openapi/spec.{
  type HttpMethod, type Operation, type Resolved, ParameterSchema, Value,
}

/// Check if any operation has parameters with Reference schemas,
/// or request body content with Reference/ObjectSchema/AllOfSchema.
/// This determines whether the generated module needs to import the types module.
pub fn operations_need_typed_schemas(
  operations: List(#(String, Operation(Resolved), String, HttpMethod)),
) -> Bool {
  list.any(operations, fn(op) {
    let #(_, operation, _, _) = op
    let has_ref_body = case operation.request_body {
      Some(Value(rb)) ->
        list.any(dict.to_list(rb.content), fn(ce) {
          let #(_, mt) = ce
          case mt.schema {
            Some(Reference(..)) -> True
            Some(Inline(ObjectSchema(..))) -> True
            Some(Inline(AllOfSchema(..))) -> True
            _ -> False
          }
        })
      _ -> False
    }
    let has_ref_params =
      list.any(operation.parameters, fn(ref_p) {
        case ref_p {
          Value(p) ->
            case p.payload {
              ParameterSchema(Reference(..)) -> True
              _ -> False
            }
          _ -> False
        }
      })
    has_ref_body || has_ref_params
  })
}

/// Check if any operation has optional (non-required) parameters.
pub fn operations_have_optional_params(
  operations: List(#(String, Operation(Resolved), String, HttpMethod)),
) -> Bool {
  list.any(operations, fn(op) {
    let #(_, operation, _, _) = op
    list.any(operation.parameters, fn(ref_p) {
      case ref_p {
        Value(p) -> !p.required
        _ -> False
      }
    })
  })
}

/// Check if any operation has an optional (non-required) request body.
pub fn operations_have_optional_body(
  operations: List(#(String, Operation(Resolved), String, HttpMethod)),
) -> Bool {
  list.any(operations, fn(op) {
    let #(_, operation, _, _) = op
    case operation.request_body {
      Some(Value(rb)) -> !rb.required
      _ -> False
    }
  })
}
