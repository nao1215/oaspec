import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import oaspec/codegen/allof_merge
import oaspec/codegen/client as client_gen
import oaspec/codegen/client_request
import oaspec/codegen/client_response
import oaspec/codegen/client_security
import oaspec/codegen/context
import oaspec/codegen/decoders
import oaspec/codegen/encoders
import oaspec/codegen/ir_build
import oaspec/codegen/server as server_gen
import oaspec/codegen/server_request_decode
import oaspec/codegen/types as types_gen
import oaspec/config
import oaspec/openapi/hoist
import oaspec/openapi/parser
import oaspec/openapi/schema
import oaspec/openapi/spec
import oaspec/util/content_type
import oaspec/util/http
import oaspec/util/string_extra as se
import test_helpers

pub fn main() {
  gleeunit.main()
}

// client_security tests
// ===================================================================

pub fn client_security_capitalize_first_normal_test() {
  client_security.capitalize_first("bearer")
  |> should.equal("Bearer")
}

pub fn client_security_capitalize_first_empty_test() {
  client_security.capitalize_first("")
  |> should.equal("")
}

pub fn client_security_capitalize_first_single_char_test() {
  client_security.capitalize_first("b")
  |> should.equal("B")
}

pub fn client_security_capitalize_first_already_upper_test() {
  client_security.capitalize_first("Bearer")
  |> should.equal("Bearer")
}

pub fn client_security_capitalize_first_all_lower_test() {
  client_security.capitalize_first("basic")
  |> should.equal("Basic")
}

pub fn client_security_maybe_percent_encode_reserved_false_test() {
  let param = test_helpers.simple_param("q", True, test_helpers.string_schema())
  client_security.maybe_percent_encode("value", param)
  |> should.equal("uri.percent_encode(value)")
}

pub fn client_security_maybe_percent_encode_reserved_true_test() {
  let param =
    test_helpers.make_test_param(
      "q",
      spec.InQuery,
      True,
      spec.ParameterSchema(schema.Inline(test_helpers.string_schema())),
      None,
      None,
      True,
    )
  client_security.maybe_percent_encode("value", param)
  |> should.equal("value")
}

// ===================================================================
// client_response tests
// ===================================================================

pub fn client_response_inline_schema_to_decoder_string_test() {
  client_response.inline_schema_to_decoder(test_helpers.string_schema())
  |> should.equal("dyn_decode.string")
}

pub fn client_response_inline_schema_to_decoder_int_test() {
  client_response.inline_schema_to_decoder(test_helpers.int_schema())
  |> should.equal("dyn_decode.int")
}

pub fn client_response_inline_schema_to_decoder_float_test() {
  client_response.inline_schema_to_decoder(test_helpers.float_schema())
  |> should.equal("dyn_decode.float")
}

pub fn client_response_inline_schema_to_decoder_bool_test() {
  client_response.inline_schema_to_decoder(test_helpers.bool_schema())
  |> should.equal("dyn_decode.bool")
}

pub fn client_response_inline_schema_to_decoder_object_fallback_test() {
  let obj =
    schema.ObjectSchema(
      metadata: schema.default_metadata(),
      properties: dict.new(),
      required: [],
      additional_properties: schema.Forbidden,
      min_properties: None,
      max_properties: None,
    )
  client_response.inline_schema_to_decoder(obj)
  |> should.equal("dyn_decode.string")
}

pub fn client_response_get_response_decode_expr_reference_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let schema_ref =
    schema.Reference(ref: "#/components/schemas/User", name: "User")
  client_response.get_response_decode_expr(
    schema_ref,
    "getUser",
    http.Status(200),
    ctx,
  )
  |> should.equal("decode.decode_user(resp.body)")
}

pub fn client_response_get_response_decode_expr_inline_string_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let schema_ref = schema.Inline(test_helpers.string_schema())
  client_response.get_response_decode_expr(
    schema_ref,
    "getUser",
    http.Status(200),
    ctx,
  )
  |> should.equal("json.parse(resp.body, dyn_decode.string)")
}

pub fn client_response_get_response_decode_expr_inline_int_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let schema_ref = schema.Inline(test_helpers.int_schema())
  client_response.get_response_decode_expr(
    schema_ref,
    "getUser",
    http.Status(200),
    ctx,
  )
  |> should.equal("json.parse(resp.body, dyn_decode.int)")
}

pub fn client_response_get_response_decode_expr_array_ref_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let schema_ref =
    schema.Inline(schema.ArraySchema(
      metadata: schema.default_metadata(),
      items: schema.Reference(ref: "#/components/schemas/Pet", name: "Pet"),
      min_items: None,
      max_items: None,
      unique_items: False,
    ))
  client_response.get_response_decode_expr(
    schema_ref,
    "listPets",
    http.Status(200),
    ctx,
  )
  |> should.equal("decode.decode_pet_list(resp.body)")
}

pub fn client_response_get_response_decode_expr_array_inline_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let schema_ref =
    schema.Inline(schema.ArraySchema(
      metadata: schema.default_metadata(),
      items: schema.Inline(test_helpers.int_schema()),
      min_items: None,
      max_items: None,
      unique_items: False,
    ))
  client_response.get_response_decode_expr(
    schema_ref,
    "getNumbers",
    http.Status(200),
    ctx,
  )
  |> should.equal("json.parse(resp.body, decode.list(dyn_decode.int))")
}

// ===================================================================
// server_request_decode tests
// ===================================================================

pub fn server_request_decode_body_field_kind_needs_int_true_test() {
  server_request_decode.body_field_kind_needs_int(
    server_request_decode.BodyFieldInt,
  )
  |> should.be_true()
  server_request_decode.body_field_kind_needs_int(
    server_request_decode.BodyFieldIntArray,
  )
  |> should.be_true()
}

pub fn server_request_decode_body_field_kind_needs_int_false_test() {
  server_request_decode.body_field_kind_needs_int(
    server_request_decode.BodyFieldString,
  )
  |> should.be_false()
  server_request_decode.body_field_kind_needs_int(
    server_request_decode.BodyFieldFloat,
  )
  |> should.be_false()
  server_request_decode.body_field_kind_needs_int(
    server_request_decode.BodyFieldUnknown,
  )
  |> should.be_false()
}

pub fn server_request_decode_body_field_kind_needs_float_true_test() {
  server_request_decode.body_field_kind_needs_float(
    server_request_decode.BodyFieldFloat,
  )
  |> should.be_true()
  server_request_decode.body_field_kind_needs_float(
    server_request_decode.BodyFieldFloatArray,
  )
  |> should.be_true()
}

pub fn server_request_decode_body_field_kind_needs_float_false_test() {
  server_request_decode.body_field_kind_needs_float(
    server_request_decode.BodyFieldString,
  )
  |> should.be_false()
  server_request_decode.body_field_kind_needs_float(
    server_request_decode.BodyFieldInt,
  )
  |> should.be_false()
}

pub fn server_request_decode_body_field_kind_inline_test() {
  let ctx = test_helpers.make_minimal_ctx()
  server_request_decode.body_field_kind(
    schema.Inline(test_helpers.string_schema()),
    ctx,
  )
  |> should.equal(server_request_decode.BodyFieldString)
  server_request_decode.body_field_kind(
    schema.Inline(test_helpers.int_schema()),
    ctx,
  )
  |> should.equal(server_request_decode.BodyFieldInt)
  server_request_decode.body_field_kind(
    schema.Inline(test_helpers.float_schema()),
    ctx,
  )
  |> should.equal(server_request_decode.BodyFieldFloat)
  server_request_decode.body_field_kind(
    schema.Inline(test_helpers.bool_schema()),
    ctx,
  )
  |> should.equal(server_request_decode.BodyFieldBool)
}

pub fn server_request_decode_body_field_kind_array_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let arr =
    schema.Inline(schema.ArraySchema(
      metadata: schema.default_metadata(),
      items: schema.Inline(test_helpers.int_schema()),
      min_items: None,
      max_items: None,
      unique_items: False,
    ))
  server_request_decode.body_field_kind(arr, ctx)
  |> should.equal(server_request_decode.BodyFieldIntArray)
}

pub fn server_request_decode_schema_ref_body_field_kind_none_test() {
  let ctx = test_helpers.make_minimal_ctx()
  server_request_decode.schema_ref_body_field_kind(None, ctx)
  |> should.equal(server_request_decode.BodyFieldUnknown)
}

pub fn server_request_decode_query_schema_needs_string_test() {
  server_request_decode.query_schema_needs_string(
    Some(schema.Inline(test_helpers.bool_schema())),
  )
  |> should.be_true()
  server_request_decode.query_schema_needs_string(
    Some(schema.Inline(test_helpers.string_schema())),
  )
  |> should.be_false()
  server_request_decode.query_schema_needs_string(None)
  |> should.be_false()
}

pub fn server_request_decode_query_schema_needs_int_test() {
  server_request_decode.query_schema_needs_int(
    Some(schema.Inline(test_helpers.int_schema())),
  )
  |> should.be_true()
  server_request_decode.query_schema_needs_int(
    Some(schema.Inline(test_helpers.string_schema())),
  )
  |> should.be_false()
}

pub fn server_request_decode_query_schema_needs_float_test() {
  server_request_decode.query_schema_needs_float(
    Some(schema.Inline(test_helpers.float_schema())),
  )
  |> should.be_true()
  server_request_decode.query_schema_needs_float(
    Some(schema.Inline(test_helpers.int_schema())),
  )
  |> should.be_false()
}

pub fn server_request_decode_param_parse_expr_string_test() {
  let param =
    test_helpers.simple_param("name", True, test_helpers.string_schema())
  server_request_decode.param_parse_expr("name_val", param)
  |> should.equal("name_val")
}

pub fn server_request_decode_param_parse_expr_int_test() {
  let param = test_helpers.simple_param("id", True, test_helpers.int_schema())
  server_request_decode.param_parse_expr("id_val", param)
  |> should.equal("int.parse(id_val)")
}

pub fn server_request_decode_param_parse_expr_float_test() {
  let param =
    test_helpers.simple_param("price", True, test_helpers.float_schema())
  server_request_decode.param_parse_expr("price_val", param)
  |> should.equal("float.parse(price_val)")
}

// Issue #263: required query / header / cookie value expressions must
// never embed `let assert`. The router opens an enclosing `case` for
// the lookup and the int/float parse, so these helpers only return the
// already-bound variable name (or a plain non-failing transform).

pub fn server_request_decode_query_required_expr_int_returns_bound_var_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let param = test_helpers.simple_param("page", True, test_helpers.int_schema())
  let expr = server_request_decode.query_required_expr("page_raw", param, ctx)
  expr |> should.equal("page_raw_parsed")
  string.contains(expr, "let assert") |> should.be_false()
}

pub fn server_request_decode_query_required_expr_float_returns_bound_var_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let param =
    test_helpers.simple_param("ratio", True, test_helpers.float_schema())
  let expr = server_request_decode.query_required_expr("ratio_raw", param, ctx)
  expr |> should.equal("ratio_raw_parsed")
  string.contains(expr, "let assert") |> should.be_false()
}

pub fn server_request_decode_query_required_expr_string_returns_bound_var_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let param =
    test_helpers.simple_param("name", True, test_helpers.string_schema())
  let expr = server_request_decode.query_required_expr("name_raw", param, ctx)
  expr |> should.equal("name_raw")
  string.contains(expr, "let assert") |> should.be_false()
}

pub fn server_request_decode_query_required_expr_bool_has_no_let_assert_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let param =
    test_helpers.simple_param("active", True, test_helpers.bool_schema())
  let expr = server_request_decode.query_required_expr("active_raw", param, ctx)
  string.contains(expr, "let assert") |> should.be_false()
  string.contains(expr, "active_raw") |> should.be_true()
}

pub fn server_request_decode_header_required_expr_int_returns_bound_var_test() {
  let param =
    test_helpers.simple_param("X-Limit", True, test_helpers.int_schema())
  let expr = server_request_decode.header_required_expr("x_limit_raw", param)
  expr |> should.equal("x_limit_raw_parsed")
  string.contains(expr, "let assert") |> should.be_false()
}

pub fn server_request_decode_header_required_expr_string_has_no_let_assert_test() {
  let param =
    test_helpers.simple_param("X-Trace", True, test_helpers.string_schema())
  let expr = server_request_decode.header_required_expr("x_trace_raw", param)
  expr |> should.equal("x_trace_raw")
}

pub fn server_request_decode_cookie_required_expr_string_returns_bound_var_test() {
  let param =
    test_helpers.simple_param("session", True, test_helpers.string_schema())
  let expr = server_request_decode.cookie_required_expr("session_raw", param)
  expr |> should.equal("session_raw")
  string.contains(expr, "let assert") |> should.be_false()
}

pub fn server_request_decode_cookie_required_expr_int_returns_bound_var_test() {
  let param =
    test_helpers.simple_param("page_size", True, test_helpers.int_schema())
  let expr = server_request_decode.cookie_required_expr("page_size_raw", param)
  expr |> should.equal("page_size_raw_parsed")
  string.contains(expr, "let assert") |> should.be_false()
}

pub fn server_request_decode_request_body_uses_form_urlencoded_test() {
  let rb =
    spec.RequestBody(
      description: None,
      content: dict.from_list([
        #(
          "application/x-www-form-urlencoded",
          spec.MediaType(
            schema: None,
            example: None,
            examples: dict.new(),
            encoding: dict.new(),
          ),
        ),
      ]),
      required: True,
    )
  server_request_decode.request_body_uses_form_urlencoded(rb)
  |> should.be_true()
}

pub fn server_request_decode_request_body_uses_multipart_test() {
  let rb =
    spec.RequestBody(
      description: None,
      content: dict.from_list([
        #(
          "multipart/form-data",
          spec.MediaType(
            schema: None,
            example: None,
            examples: dict.new(),
            encoding: dict.new(),
          ),
        ),
      ]),
      required: True,
    )
  server_request_decode.request_body_uses_multipart(rb)
  |> should.be_true()
}

pub fn server_request_decode_request_body_not_form_test() {
  let rb =
    spec.RequestBody(
      description: None,
      content: dict.from_list([
        #(
          "application/json",
          spec.MediaType(
            schema: None,
            example: None,
            examples: dict.new(),
            encoding: dict.new(),
          ),
        ),
      ]),
      required: True,
    )
  server_request_decode.request_body_uses_form_urlencoded(rb)
  |> should.be_false()
  server_request_decode.request_body_uses_multipart(rb)
  |> should.be_false()
}

// ===================================================================
// client_request tests
// ===================================================================

pub fn client_request_get_body_type_reference_test() {
  let rb =
    spec.RequestBody(
      description: None,
      content: dict.from_list([
        #(
          "application/json",
          spec.MediaType(
            schema: Some(schema.Reference(
              ref: "#/components/schemas/Pet",
              name: "Pet",
            )),
            example: None,
            examples: dict.new(),
            encoding: dict.new(),
          ),
        ),
      ]),
      required: True,
    )
  client_request.get_body_type(rb, "createPet")
  |> should.equal("types.Pet")
}

pub fn client_request_get_body_type_inline_string_test() {
  let rb =
    spec.RequestBody(
      description: None,
      content: dict.from_list([
        #(
          "application/json",
          spec.MediaType(
            schema: Some(schema.Inline(test_helpers.string_schema())),
            example: None,
            examples: dict.new(),
            encoding: dict.new(),
          ),
        ),
      ]),
      required: True,
    )
  client_request.get_body_type(rb, "createMessage")
  |> should.equal("String")
}

pub fn client_request_get_body_type_inline_int_test() {
  let rb =
    spec.RequestBody(
      description: None,
      content: dict.from_list([
        #(
          "application/json",
          spec.MediaType(
            schema: Some(schema.Inline(test_helpers.int_schema())),
            example: None,
            examples: dict.new(),
            encoding: dict.new(),
          ),
        ),
      ]),
      required: True,
    )
  client_request.get_body_type(rb, "setCount")
  |> should.equal("Int")
}

pub fn client_request_get_body_type_multi_content_test() {
  let mt =
    spec.MediaType(
      schema: None,
      example: None,
      examples: dict.new(),
      encoding: dict.new(),
    )
  let rb =
    spec.RequestBody(
      description: None,
      content: dict.from_list([
        #("application/json", mt),
        #("text/plain", mt),
      ]),
      required: True,
    )
  client_request.get_body_type(rb, "createItem")
  |> should.equal("String")
}

pub fn client_request_get_body_type_empty_content_test() {
  let rb =
    spec.RequestBody(description: None, content: dict.new(), required: True)
  client_request.get_body_type(rb, "noContent")
  |> should.equal("String")
}

pub fn client_request_get_body_type_inline_object_test() {
  let obj =
    schema.ObjectSchema(
      metadata: schema.default_metadata(),
      properties: dict.new(),
      required: [],
      additional_properties: schema.Forbidden,
      min_properties: None,
      max_properties: None,
    )
  let rb =
    spec.RequestBody(
      description: None,
      content: dict.from_list([
        #(
          "application/json",
          spec.MediaType(
            schema: Some(schema.Inline(obj)),
            example: None,
            examples: dict.new(),
            encoding: dict.new(),
          ),
        ),
      ]),
      required: True,
    )
  client_request.get_body_type(rb, "createItem")
  |> should.equal("types.CreateItemRequestBody")
}

pub fn client_request_is_exploded_array_param_default_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let arr =
    schema.ArraySchema(
      metadata: schema.default_metadata(),
      items: schema.Inline(test_helpers.string_schema()),
      min_items: None,
      max_items: None,
      unique_items: False,
    )
  let param =
    test_helpers.make_test_param(
      "tags",
      spec.InQuery,
      True,
      spec.ParameterSchema(schema.Inline(arr)),
      None,
      None,
      False,
    )
  // Default: form style + explode=true
  client_request.is_exploded_array_param(param, ctx)
  |> should.be_true()
}

pub fn client_request_is_exploded_array_param_explicit_false_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let arr =
    schema.ArraySchema(
      metadata: schema.default_metadata(),
      items: schema.Inline(test_helpers.string_schema()),
      min_items: None,
      max_items: None,
      unique_items: False,
    )
  let param =
    test_helpers.make_test_param(
      "tags",
      spec.InQuery,
      True,
      spec.ParameterSchema(schema.Inline(arr)),
      None,
      Some(False),
      False,
    )
  client_request.is_exploded_array_param(param, ctx)
  |> should.be_false()
}

pub fn client_request_is_exploded_array_param_non_array_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let param =
    test_helpers.simple_param("name", True, test_helpers.string_schema())
  client_request.is_exploded_array_param(param, ctx)
  |> should.be_false()
}

pub fn client_request_is_deep_object_param_object_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let obj =
    schema.ObjectSchema(
      metadata: schema.default_metadata(),
      properties: dict.new(),
      required: [],
      additional_properties: schema.Forbidden,
      min_properties: None,
      max_properties: None,
    )
  let param =
    test_helpers.make_test_param(
      "filter",
      spec.InQuery,
      True,
      spec.ParameterSchema(schema.Inline(obj)),
      Some(spec.DeepObjectStyle),
      None,
      False,
    )
  client_request.is_deep_object_param(param, ctx)
  |> should.be_true()
}

pub fn client_request_is_deep_object_param_string_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let param =
    test_helpers.simple_param("name", True, test_helpers.string_schema())
  client_request.is_deep_object_param(param, ctx)
  |> should.be_false()
}

pub fn client_request_multipart_field_is_binary_true_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let binary_schema =
    schema.StringSchema(
      metadata: schema.default_metadata(),
      format: Some("binary"),
      enum_values: [],
      min_length: None,
      max_length: None,
      pattern: None,
    )
  client_request.multipart_field_is_binary(schema.Inline(binary_schema), ctx)
  |> should.be_true()
}

pub fn client_request_multipart_field_is_binary_false_test() {
  let ctx = test_helpers.make_minimal_ctx()
  client_request.multipart_field_is_binary(
    schema.Inline(test_helpers.string_schema()),
    ctx,
  )
  |> should.be_false()
}

// ===================================================================
// ir_build tests
// ===================================================================

pub fn ir_build_sorted_entries_empty_test() {
  ir_build.sorted_entries(dict.new())
  |> should.equal([])
}

pub fn ir_build_sorted_entries_ordering_test() {
  let entries = dict.from_list([#("cherry", 3), #("apple", 1), #("banana", 2)])
  ir_build.sorted_entries(entries)
  |> should.equal([#("apple", 1), #("banana", 2), #("cherry", 3)])
}

pub fn ir_build_sorted_entries_single_test() {
  let entries = dict.from_list([#("only", 42)])
  ir_build.sorted_entries(entries)
  |> should.equal([#("only", 42)])
}

pub fn ir_build_is_internal_schema_true_test() {
  let meta = schema.SchemaMetadata(..schema.default_metadata(), internal: True)
  let string_schema =
    schema.StringSchema(
      metadata: meta,
      format: None,
      enum_values: [],
      min_length: None,
      max_length: None,
      pattern: None,
    )
  ir_build.is_internal_schema(schema.Inline(string_schema))
  |> should.be_true()
}

pub fn ir_build_is_internal_schema_false_test() {
  ir_build.is_internal_schema(schema.Inline(test_helpers.string_schema()))
  |> should.be_false()
}

pub fn ir_build_is_internal_schema_reference_test() {
  ir_build.is_internal_schema(schema.Reference(
    ref: "#/components/schemas/User",
    name: "User",
  ))
  |> should.be_false()
}

// ===================================================================
// allof_merge tests
// ===================================================================

pub fn allof_merge_single_object_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let obj =
    schema.ObjectSchema(
      metadata: schema.default_metadata(),
      properties: dict.from_list([
        #("name", schema.Inline(test_helpers.string_schema())),
        #("age", schema.Inline(test_helpers.int_schema())),
      ]),
      required: ["name"],
      additional_properties: schema.Forbidden,
      min_properties: None,
      max_properties: None,
    )
  let result = allof_merge.merge_allof_schemas([schema.Inline(obj)], ctx)
  dict.size(result.properties) |> should.equal(2)
  result.required |> should.equal(["name"])
  result.additional_properties |> should.equal(schema.Forbidden)
}

pub fn allof_merge_two_objects_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let obj1 =
    schema.ObjectSchema(
      metadata: schema.default_metadata(),
      properties: dict.from_list([
        #("name", schema.Inline(test_helpers.string_schema())),
      ]),
      required: ["name"],
      additional_properties: schema.Forbidden,
      min_properties: None,
      max_properties: None,
    )
  let obj2 =
    schema.ObjectSchema(
      metadata: schema.default_metadata(),
      properties: dict.from_list([
        #("age", schema.Inline(test_helpers.int_schema())),
      ]),
      required: ["age"],
      additional_properties: schema.Forbidden,
      min_properties: None,
      max_properties: None,
    )
  let result =
    allof_merge.merge_allof_schemas(
      [schema.Inline(obj1), schema.Inline(obj2)],
      ctx,
    )
  dict.size(result.properties) |> should.equal(2)
  list.contains(result.required, "name") |> should.be_true()
  list.contains(result.required, "age") |> should.be_true()
}

pub fn allof_merge_non_object_value_field_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let result =
    allof_merge.merge_allof_schemas(
      [schema.Inline(test_helpers.string_schema())],
      ctx,
    )
  dict.has_key(result.properties, "value") |> should.be_true()
}

pub fn allof_merge_additional_properties_typed_wins_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let obj1 =
    schema.ObjectSchema(
      metadata: schema.default_metadata(),
      properties: dict.new(),
      required: [],
      additional_properties: schema.Untyped,
      min_properties: None,
      max_properties: None,
    )
  let obj2 =
    schema.ObjectSchema(
      metadata: schema.default_metadata(),
      properties: dict.new(),
      required: [],
      additional_properties: schema.Typed(
        schema.Inline(test_helpers.string_schema()),
      ),
      min_properties: None,
      max_properties: None,
    )
  let result =
    allof_merge.merge_allof_schemas(
      [schema.Inline(obj1), schema.Inline(obj2)],
      ctx,
    )
  // Typed should take precedence over Untyped
  case result.additional_properties {
    schema.Typed(_) -> True
    _ -> False
  }
  |> should.be_true()
}

pub fn allof_merge_empty_schemas_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let result = allof_merge.merge_allof_schemas([], ctx)
  dict.size(result.properties) |> should.equal(0)
  result.required |> should.equal([])
}

// ===================================================================
// decoders tests (additional)
// ===================================================================

pub fn decoders_empty_spec_generates_files_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let files = list.append(decoders.generate(ctx), encoders.generate(ctx))
  list.length(files) |> should.equal(2)
}

pub fn decoders_empty_spec_decode_file_has_header_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let files = decoders.generate(ctx)
  let assert Ok(decode_file) =
    list.find(files, fn(f) { f.path == "decode.gleam" })
  string.contains(decode_file.content, "// Code generated by oaspec")
  |> should.be_true()
}

pub fn decoders_empty_spec_encode_file_has_header_test() {
  let ctx = test_helpers.make_minimal_ctx()
  let files = encoders.generate(ctx)
  let assert Ok(encode_file) =
    list.find(files, fn(f) { f.path == "encode.gleam" })
  string.contains(encode_file.content, "// Code generated by oaspec")
  |> should.be_true()
}

pub fn decoders_single_object_schema_test() {
  let assert Ok(test_spec) =
    parser.parse_string(
      "
openapi: '3.0.3'
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    User:
      type: object
      required:
        - name
      properties:
        name:
          type: string
        age:
          type: integer
",
    )
  let ctx = test_helpers.make_ctx_from_spec(test_spec)
  let files = decoders.generate(ctx)
  let assert Ok(decode_file) =
    list.find(files, fn(f) { f.path == "decode.gleam" })
  string.contains(decode_file.content, "decode_user") |> should.be_true()
}

pub fn decoders_single_object_encoder_test() {
  let assert Ok(test_spec) =
    parser.parse_string(
      "
openapi: '3.0.3'
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    User:
      type: object
      required:
        - name
      properties:
        name:
          type: string
",
    )
  let ctx = test_helpers.make_ctx_from_spec(test_spec)
  let files = encoders.generate(ctx)
  let assert Ok(encode_file) =
    list.find(files, fn(f) { f.path == "encode.gleam" })
  string.contains(encode_file.content, "encode_user") |> should.be_true()
}

// ===================================================================
// client_security.generate_security_or_chain tests
// ===================================================================

fn make_security_ctx(
  schemes: List(#(String, spec.SecurityScheme)),
) -> context.Context {
  let components =
    spec.Components(
      schemas: dict.new(),
      parameters: dict.new(),
      request_bodies: dict.new(),
      responses: dict.new(),
      security_schemes: dict.from_list(
        list.map(schemes, fn(entry) {
          let #(name, scheme) = entry
          #(name, spec.Value(scheme))
        }),
      ),
      path_items: dict.new(),
      headers: dict.new(),
      examples: dict.new(),
      links: dict.new(),
      callbacks: dict.new(),
    )
  let test_spec =
    spec.OpenApiSpec(
      openapi: "3.0.3",
      info: spec.Info(
        title: "Test",
        description: None,
        version: "1.0.0",
        summary: None,
        terms_of_service: None,
        contact: None,
        license: None,
      ),
      paths: dict.new(),
      components: Some(components),
      servers: [],
      security: [],
      webhooks: dict.new(),
      tags: [],
      external_docs: None,
      json_schema_dialect: None,
    )
  let cfg =
    config.new(
      input: "test.yaml",
      output_server: "./test_output/api",
      output_client: "./test_output_client/api",
      package: "api",
      mode: config.Both,
      validate: False,
    )
  context.new(test_spec, cfg)
}

fn run_security_chain(
  ctx: context.Context,
  alternatives: List(spec.SecurityRequirement),
) -> String {
  let sb = se.new()
  let sb = client_security.generate_security_or_chain(sb, ctx, alternatives, 1)
  se.to_string(sb)
}

pub fn security_chain_empty_alternatives_test() {
  let ctx = make_security_ctx([])
  let result = run_security_chain(ctx, [])
  result |> should.equal("")
}

pub fn security_chain_single_api_key_header_test() {
  let ctx =
    make_security_ctx([
      #(
        "ApiKey",
        spec.ApiKeyScheme(name: "X-API-Key", in_: spec.SchemeInHeader),
      ),
    ])
  let alt =
    spec.SecurityRequirement(schemes: [
      spec.SecuritySchemeRef(scheme_name: "ApiKey", scopes: []),
    ])
  let result = run_security_chain(ctx, [alt])
  string.contains(result, "config.api_key") |> should.be_true()
  string.contains(result, "x-api-key") |> should.be_true()
  string.contains(result, "set_header") |> should.be_true()
  string.contains(result, "None -> req") |> should.be_true()
}

pub fn security_chain_single_bearer_test() {
  let ctx =
    make_security_ctx([
      #(
        "BearerAuth",
        spec.HttpScheme(scheme: "bearer", bearer_format: Some("JWT")),
      ),
    ])
  let alt =
    spec.SecurityRequirement(schemes: [
      spec.SecuritySchemeRef(scheme_name: "BearerAuth", scopes: []),
    ])
  let result = run_security_chain(ctx, [alt])
  string.contains(result, "config.bearer_auth") |> should.be_true()
  string.contains(result, "\"authorization\"") |> should.be_true()
  string.contains(result, "\"Bearer \"") |> should.be_true()
  string.contains(result, "None -> req") |> should.be_true()
}

pub fn security_chain_single_basic_test() {
  let ctx =
    make_security_ctx([
      #("BasicAuth", spec.HttpScheme(scheme: "basic", bearer_format: None)),
    ])
  let alt =
    spec.SecurityRequirement(schemes: [
      spec.SecuritySchemeRef(scheme_name: "BasicAuth", scopes: []),
    ])
  let result = run_security_chain(ctx, [alt])
  string.contains(result, "\"Basic \"") |> should.be_true()
}

pub fn security_chain_single_api_key_query_test() {
  let ctx =
    make_security_ctx([
      #("ApiKey", spec.ApiKeyScheme(name: "api_key", in_: spec.SchemeInQuery)),
    ])
  let alt =
    spec.SecurityRequirement(schemes: [
      spec.SecuritySchemeRef(scheme_name: "ApiKey", scopes: []),
    ])
  let result = run_security_chain(ctx, [alt])
  string.contains(result, "api_key=") |> should.be_true()
  string.contains(result, "req.path") |> should.be_true()
  string.contains(result, "None -> req") |> should.be_true()
}

pub fn security_chain_single_api_key_cookie_test() {
  let ctx =
    make_security_ctx([
      #(
        "SessionId",
        spec.ApiKeyScheme(name: "session_id", in_: spec.SchemeInCookie),
      ),
    ])
  let alt =
    spec.SecurityRequirement(schemes: [
      spec.SecuritySchemeRef(scheme_name: "SessionId", scopes: []),
    ])
  let result = run_security_chain(ctx, [alt])
  string.contains(result, "session_id=") |> should.be_true()
  string.contains(result, "cookie") |> should.be_true()
  string.contains(result, "None -> req") |> should.be_true()
}

pub fn security_chain_or_two_alternatives_test() {
  let ctx =
    make_security_ctx([
      #("BearerAuth", spec.HttpScheme(scheme: "bearer", bearer_format: None)),
      #(
        "ApiKey",
        spec.ApiKeyScheme(name: "X-API-Key", in_: spec.SchemeInHeader),
      ),
    ])
  let alt1 =
    spec.SecurityRequirement(schemes: [
      spec.SecuritySchemeRef(scheme_name: "BearerAuth", scopes: []),
    ])
  let alt2 =
    spec.SecurityRequirement(schemes: [
      spec.SecuritySchemeRef(scheme_name: "ApiKey", scopes: []),
    ])
  let result = run_security_chain(ctx, [alt1, alt2])
  // First alternative tries BearerAuth
  string.contains(result, "config.bearer_auth") |> should.be_true()
  string.contains(result, "\"Bearer \"") |> should.be_true()
  // None branch falls through to second alternative (ApiKey)
  string.contains(result, "None -> {") |> should.be_true()
  string.contains(result, "config.api_key") |> should.be_true()
  string.contains(result, "x-api-key") |> should.be_true()
}

pub fn security_chain_and_multiple_schemes_test() {
  let ctx =
    make_security_ctx([
      #(
        "ApiKey",
        spec.ApiKeyScheme(name: "X-API-Key", in_: spec.SchemeInHeader),
      ),
      #("BearerAuth", spec.HttpScheme(scheme: "bearer", bearer_format: None)),
    ])
  // AND requirement: both ApiKey AND BearerAuth must be present
  let alt =
    spec.SecurityRequirement(schemes: [
      spec.SecuritySchemeRef(scheme_name: "ApiKey", scopes: []),
      spec.SecuritySchemeRef(scheme_name: "BearerAuth", scopes: []),
    ])
  let result = run_security_chain(ctx, [alt])
  // Tuple match pattern: case config.api_key, config.bearer_auth
  string.contains(result, "config.api_key") |> should.be_true()
  string.contains(result, "config.bearer_auth") |> should.be_true()
  // Some(api_key_val), Some(bearer_auth_val) pattern
  string.contains(result, "Some(api_key_val)") |> should.be_true()
  string.contains(result, "Some(bearer_auth_val)") |> should.be_true()
  // Wildcard fallback
  string.contains(result, "_, _ -> req") |> should.be_true()
}

pub fn security_chain_oauth2_uses_bearer_test() {
  let ctx =
    make_security_ctx([
      #("OAuth2", spec.OAuth2Scheme(description: None, flows: dict.new())),
    ])
  let alt =
    spec.SecurityRequirement(schemes: [
      spec.SecuritySchemeRef(scheme_name: "OAuth2", scopes: ["read"]),
    ])
  let result = run_security_chain(ctx, [alt])
  string.contains(result, "\"Bearer \"") |> should.be_true()
}

pub fn security_chain_openid_connect_uses_bearer_test() {
  let ctx =
    make_security_ctx([
      #(
        "OidcAuth",
        spec.OpenIdConnectScheme(
          open_id_connect_url: "https://example.com/.well-known/openid-configuration",
          description: None,
        ),
      ),
    ])
  let alt =
    spec.SecurityRequirement(schemes: [
      spec.SecuritySchemeRef(scheme_name: "OidcAuth", scopes: []),
    ])
  let result = run_security_chain(ctx, [alt])
  string.contains(result, "\"Bearer \"") |> should.be_true()
  string.contains(result, "config.oidc_auth") |> should.be_true()
}

pub fn security_chain_digest_test() {
  let ctx =
    make_security_ctx([
      #("DigestAuth", spec.HttpScheme(scheme: "digest", bearer_format: None)),
    ])
  let alt =
    spec.SecurityRequirement(schemes: [
      spec.SecuritySchemeRef(scheme_name: "DigestAuth", scopes: []),
    ])
  let result = run_security_chain(ctx, [alt])
  string.contains(result, "\"Digest \"") |> should.be_true()
}

pub fn security_chain_custom_http_scheme_test() {
  let ctx =
    make_security_ctx([
      #("HmacAuth", spec.HttpScheme(scheme: "hoba", bearer_format: None)),
    ])
  let alt =
    spec.SecurityRequirement(schemes: [
      spec.SecuritySchemeRef(scheme_name: "HmacAuth", scopes: []),
    ])
  let result = run_security_chain(ctx, [alt])
  // Custom scheme name should be capitalized
  string.contains(result, "\"Hoba \"") |> should.be_true()
}

pub fn security_chain_or_with_and_fallback_test() {
  let ctx =
    make_security_ctx([
      #(
        "ApiKey",
        spec.ApiKeyScheme(name: "X-API-Key", in_: spec.SchemeInHeader),
      ),
      #("BearerAuth", spec.HttpScheme(scheme: "bearer", bearer_format: None)),
    ])
  // First alternative: AND (both required)
  let alt1 =
    spec.SecurityRequirement(schemes: [
      spec.SecuritySchemeRef(scheme_name: "ApiKey", scopes: []),
      spec.SecuritySchemeRef(scheme_name: "BearerAuth", scopes: []),
    ])
  // Second alternative: single scheme fallback
  let alt2 =
    spec.SecurityRequirement(schemes: [
      spec.SecuritySchemeRef(scheme_name: "ApiKey", scopes: []),
    ])
  let result = run_security_chain(ctx, [alt1, alt2])
  // AND branch with tuple match
  string.contains(result, "Some(api_key_val), Some(bearer_auth_val)")
  |> should.be_true()
  // Wildcard falls through to second alternative
  string.contains(result, "_, _ -> {") |> should.be_true()
  // Second alternative checks just ApiKey
  // The output contains "config.api_key" at least twice (once per alternative)
  let parts = string.split(result, "config.api_key")
  { list.length(parts) >= 3 } |> should.be_true()
}

// ===================================================================
// Regression: router imports decode module when request body exists
// even if responses have no JSON schema (callback_api pattern)
// ===================================================================

pub fn router_imports_decode_when_request_body_without_json_response_test() {
  let assert Ok(test_spec) =
    parser.parse_string(
      "
openapi: '3.0.3'
info:
  title: Test
  version: 1.0.0
paths:
  /webhooks:
    post:
      operationId: registerWebhook
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                url:
                  type: string
      responses:
        '201':
          description: registered
",
    )
  let ctx = test_helpers.make_ctx_from_spec(test_spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  // Router must import decode module when request body exists,
  // regardless of whether responses contain JSON schemas
  string.contains(router_file.content, "import api/decode")
  |> should.be_true()
}

pub fn router_deep_object_includes_additional_properties_field_test() {
  // Per Issue #249, absent `additionalProperties` is now `Unspecified` and
  // suppresses the generated record's AP field. To exercise the deepObject
  // additional-properties collection path we have to opt in explicitly with
  // `additionalProperties: true`.
  let assert Ok(test_spec) =
    parser.parse_string(
      "
openapi: '3.0.3'
info:
  title: Test
  version: 1.0.0
paths:
  /search:
    get:
      operationId: searchItems
      parameters:
        - name: filter
          in: query
          style: deepObject
          explode: true
          required: true
          schema:
            type: object
            additionalProperties: true
            required:
              - name
            properties:
              name:
                type: string
      responses:
        '200':
          description: ok
",
    )
  let ctx = test_helpers.make_ctx_from_spec(test_spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })
  string.contains(
    router_file.content,
    "additional_properties: coerce_dict(deep_object_additional_properties(query, \"filter\", [\"name\"]))",
  )
  |> should.be_true()
}

// --- with_* auth configuration helper tests ---

pub fn with_helpers_generated_for_api_key_and_bearer_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /pets:
    get:
      operationId: listPets
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    ApiKeyAuth:
      type: apiKey
      in: header
      name: X-API-Key
    BearerAuth:
      type: http
      scheme: bearer
security:
  - ApiKeyAuth: []
  - BearerAuth: []
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // with_api_key_auth helper must be generated
  string.contains(
    content,
    "pub fn with_api_key_auth(config: ClientConfig, token: String) -> ClientConfig {",
  )
  |> should.be_true()
  string.contains(content, "ClientConfig(..config, api_key_auth: Some(token))")
  |> should.be_true()
  // with_bearer_auth helper must be generated
  string.contains(
    content,
    "pub fn with_bearer_auth(config: ClientConfig, token: String) -> ClientConfig {",
  )
  |> should.be_true()
  string.contains(content, "ClientConfig(..config, bearer_auth: Some(token))")
  |> should.be_true()
}

pub fn with_helpers_doc_comment_for_api_key_header_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    ApiKeyAuth:
      type: apiKey
      in: header
      name: X-API-Key
security:
  - ApiKeyAuth: []
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  string.contains(
    content,
    "/// Set the API key for the ApiKeyAuth security scheme (header: X-API-Key).",
  )
  |> should.be_true()
}

pub fn with_helpers_doc_comment_for_api_key_query_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    QueryAuth:
      type: apiKey
      in: query
      name: api_key
security:
  - QueryAuth: []
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  string.contains(
    content,
    "/// Set the API key for the QueryAuth security scheme (query: api_key).",
  )
  |> should.be_true()
  string.contains(
    content,
    "pub fn with_query_auth(config: ClientConfig, token: String) -> ClientConfig {",
  )
  |> should.be_true()
}

pub fn with_helpers_doc_comment_for_cookie_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    CookieAuth:
      type: apiKey
      in: cookie
      name: session_id
security:
  - CookieAuth: []
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  string.contains(
    content,
    "/// Set the API key for the CookieAuth security scheme (cookie: session_id).",
  )
  |> should.be_true()
}

pub fn with_helpers_doc_comment_for_oauth2_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    OAuth2Auth:
      type: oauth2
      flows:
        authorizationCode:
          authorizationUrl: https://example.com/auth
          tokenUrl: https://example.com/token
          scopes:
            read: Read access
security:
  - OAuth2Auth: []
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  string.contains(
    content,
    "/// Set the OAuth2 token for the OAuth2Auth security scheme.",
  )
  |> should.be_true()
}

pub fn with_helpers_not_generated_when_no_security_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // No auth with_* helpers should be present
  string.contains(content, "pub fn with_api_key_auth(")
  |> should.be_false()
  string.contains(content, "pub fn with_bearer_auth(")
  |> should.be_false()
}

pub fn with_helpers_appear_before_default_base_url_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
servers:
  - url: https://api.example.com
paths:
  /x:
    get:
      operationId: getX
      responses:
        '200': { description: ok }
components:
  securitySchemes:
    BearerAuth:
      type: http
      scheme: bearer
security:
  - BearerAuth: []
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  let content = client_file.content
  // new must come before with_bearer_auth, which must come before default_base_url
  let assert Ok(new_pos) =
    test_helpers.find_substring_index(content, "pub fn new(")
  let assert Ok(with_pos) =
    test_helpers.find_substring_index(content, "pub fn with_bearer_auth(")
  let assert Ok(base_url_pos) =
    test_helpers.find_substring_index(content, "pub fn default_base_url(")
  should.be_true(new_pos < with_pos)
  should.be_true(with_pos < base_url_pos)
}

// --- content_type structured syntax suffix tests ---

pub fn content_type_from_string_problem_json_test() {
  content_type.from_string("application/problem+json")
  |> should.equal(content_type.ApplicationJson)
}

pub fn content_type_from_string_json_patch_json_test() {
  content_type.from_string("application/json-patch+json")
  |> should.equal(content_type.ApplicationJson)
}

pub fn content_type_from_string_vendor_json_test() {
  content_type.from_string("application/vnd.api+json")
  |> should.equal(content_type.ApplicationJson)
}

pub fn content_type_from_string_soap_xml_test() {
  content_type.from_string("application/soap+xml")
  |> should.equal(content_type.ApplicationXml)
}

pub fn content_type_from_string_plain_json_unchanged_test() {
  content_type.from_string("application/json")
  |> should.equal(content_type.ApplicationJson)
}

pub fn content_type_from_string_unsupported_unchanged_test() {
  content_type.from_string("image/png")
  |> should.equal(content_type.UnsupportedContentType("image/png"))
}

pub fn content_type_is_json_compatible_true_test() {
  content_type.is_json_compatible("application/problem+json")
  |> should.be_true()
}

pub fn content_type_is_json_compatible_plain_json_test() {
  content_type.is_json_compatible("application/json")
  |> should.be_true()
}

pub fn content_type_is_json_compatible_false_test() {
  content_type.is_json_compatible("text/plain")
  |> should.be_false()
}

pub fn content_type_is_xml_compatible_suffix_test() {
  content_type.is_xml_compatible("application/soap+xml")
  |> should.be_true()
}

pub fn content_type_is_xml_compatible_plain_xml_test() {
  content_type.is_xml_compatible("application/xml")
  |> should.be_true()
}

pub fn content_type_is_xml_compatible_false_test() {
  content_type.is_xml_compatible("application/json")
  |> should.be_false()
}

pub fn json_suffix_request_body_validates_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /errors:
    post:
      operationId: reportError
      requestBody:
        required: true
        content:
          application/problem+json:
            schema:
              $ref: '#/components/schemas/Problem'
      responses:
        '200': { description: ok }
components:
  schemas:
    Problem:
      type: object
      properties:
        title:
          type: string
        status:
          type: integer
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  // Should generate client code without validation errors
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  // The content-type header should use the original media type
  string.contains(client_file.content, "application/problem+json")
  |> should.be_true()
}

pub fn json_suffix_response_generates_typed_decode_test() {
  let yaml =
    "
openapi: 3.0.3
info:
  title: Test
  version: 1.0.0
paths:
  /errors:
    get:
      operationId: getError
      responses:
        '200':
          description: ok
          content:
            application/problem+json:
              schema:
                $ref: '#/components/schemas/Problem'
components:
  schemas:
    Problem:
      type: object
      properties:
        title:
          type: string
        status:
          type: integer
"
  let assert Ok(spec) = parser.parse_string(yaml)
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = client_gen.generate(ctx)
  let assert [client_file] = files
  // Should use JSON decode (not string passthrough)
  string.contains(client_file.content, "decode.decode_problem(resp.body)")
  |> should.be_true()
}

// ===================================================================
// Encoder: optional non-nullable field omits key on None (issue #303)
// ===================================================================

/// A property that is optional (not in `required`) and not `nullable: true`
/// must be omitted from the JSON object when its `Option(_)` field is
/// `None` — emitting `"<key>": null` is schema-invalid per OpenAPI 3.0/3.1.
pub fn encoders_optional_non_nullable_field_is_omitted_on_none_test() {
  let assert Ok(spec) =
    parser.parse_string(
      "
openapi: '3.0.3'
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    ErrorResponse:
      type: object
      required: [error]
      properties:
        error:
          type: string
        details:
          type: array
          items:
            type: string
        comment:
          type: string
          nullable: true
",
    )
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = encoders.generate(ctx)
  let assert Ok(encode_file) =
    list.find(files, fn(f) { f.path == "encode.gleam" })

  // Optional + non-nullable `details` must use the omit-on-None shape.
  string.contains(encode_file.content, "case value.details {")
  |> should.be_true()
  string.contains(encode_file.content, "option.None -> []") |> should.be_true()
  string.contains(
    encode_file.content,
    "option.Some(x) -> [#(\"details\", json.array(x, json.string))]",
  )
  |> should.be_true()

  // Optional + nullable `comment` keeps the json.nullable shape
  // (None → null on the wire is permitted because nullable: true).
  string.contains(
    encode_file.content,
    "json.nullable(value.comment, json.string)",
  )
  |> should.be_true()

  // The buggy fallback must not survive: no `json.nullable(value.details, ...)`.
  string.contains(encode_file.content, "json.nullable(value.details")
  |> should.be_false()

  // The new shape uses list.flatten when any property is optional+non-nullable.
  string.contains(encode_file.content, "list.flatten([") |> should.be_true()
}

// ===================================================================
// Enum query parameter codegen (issue #305)
// ===================================================================

/// Optional `$ref` enum query parameter must emit a string→variant
/// match returning Option(<EnumType>) — not a raw String.
pub fn server_optional_enum_query_param_emits_inline_match_test() {
  let assert Ok(spec) =
    parser.parse_string(
      "
openapi: '3.0.3'
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - in: query
          name: visibility
          required: false
          schema:
            $ref: '#/components/schemas/Visibility'
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
components:
  schemas:
    Visibility:
      type: string
      enum: [public, unlisted, private]
",
    )
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })

  // Optional enum query: inline String→Variant match returns Option.
  string.contains(
    router_file.content,
    "\"public\" -> Some(types.VisibilityPublic)",
  )
  |> should.be_true()
  string.contains(
    router_file.content,
    "\"unlisted\" -> Some(types.VisibilityUnlisted)",
  )
  |> should.be_true()
  string.contains(
    router_file.content,
    "\"private\" -> Some(types.VisibilityPrivate)",
  )
  |> should.be_true()
  // Default arm produces None for unknown values.
  string.contains(router_file.content, "_ -> None") |> should.be_true()
  // The broken-default fallback must not survive: there is no remaining
  // `Some(v)` that would assign a raw String into the enum slot.
  string.contains(router_file.content, "Ok([v, ..]) -> Some(v)")
  |> should.be_false()
}

/// Required `$ref` enum query parameter must emit the same Result
/// scaffold as int / float (open `case`, bind `<raw>_parsed`, close
/// `_ -> 400`) so unknown values fall through to a Bad Request.
pub fn server_required_enum_query_param_emits_result_scaffold_test() {
  let assert Ok(spec) =
    parser.parse_string(
      "
openapi: '3.0.3'
info:
  title: Test
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - in: query
          name: priority
          required: true
          schema:
            $ref: '#/components/schemas/Priority'
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
components:
  schemas:
    Priority:
      type: string
      enum: [low, medium, high]
",
    )
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })

  // Inline String→Result match for each variant.
  string.contains(router_file.content, "\"low\" -> Ok(types.PriorityLow)")
  |> should.be_true()
  string.contains(router_file.content, "\"medium\" -> Ok(types.PriorityMedium)")
  |> should.be_true()
  string.contains(router_file.content, "\"high\" -> Ok(types.PriorityHigh)")
  |> should.be_true()
  // Result scaffold binds <raw>_parsed on Ok.
  string.contains(router_file.content, "Ok(priority_raw_parsed) -> {")
  |> should.be_true()
  // The handler body uses the typed bound variable.
  string.contains(router_file.content, "priority: priority_raw_parsed,")
  |> should.be_true()
  // Unknown values return 400 with an RFC 7807-shaped Problem JSON body
  // (issue #307 — replaced the previous plain-text "Bad Request").
  string.contains(router_file.content, "status: 400") |> should.be_true()
  string.contains(
    router_file.content,
    "\"{\\\"type\\\":\\\"about:blank\\\",\\\"title\\\":\\\"invalid query parameter\\\"}\"",
  )
  |> should.be_true()
  string.contains(
    router_file.content,
    "[#(\"content-type\", \"application/problem+json\")]",
  )
  |> should.be_true()
}

// ===================================================================
// Router error responses use Problem JSON (issue #307)
// ===================================================================

/// Body decode failures, path/query/header parameter parse failures, and
/// unmatched routes must emit `application/problem+json` with an RFC 7807
/// shape rather than plain `Bad Request` / `Not Found` text.
pub fn server_error_paths_emit_problem_json_test() {
  let assert Ok(spec) =
    parser.parse_string(
      "
openapi: '3.0.3'
info:
  title: Test
  version: 1.0.0
paths:
  /things:
    post:
      operationId: createThing
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [name]
              properties:
                name:
                  type: string
      responses:
        '201':
          description: created
          content:
            application/json:
              schema:
                type: object
",
    )
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })

  // The decode-fail branch emits a Problem JSON body, not plain text.
  string.contains(router_file.content, "\"Bad Request\"") |> should.be_false()
  string.contains(router_file.content, "\"Not Found\"") |> should.be_false()
  string.contains(
    router_file.content,
    "[#(\"content-type\", \"application/problem+json\")]",
  )
  |> should.be_true()
  // Body decode failure carries the spec-relevant title.
  string.contains(
    router_file.content,
    "\\\"title\\\":\\\"invalid request body\\\"",
  )
  |> should.be_true()
  // The unmatched-route catch-all uses the same Problem shape.
  string.contains(router_file.content, "\\\"title\\\":\\\"not found\\\"")
  |> should.be_true()
  // Status codes are intact.
  string.contains(router_file.content, "status: 400") |> should.be_true()
  string.contains(router_file.content, "status: 404") |> should.be_true()
}

// ===================================================================
// oneOf with discriminator: unknown-value fallback (issue #308)
// ===================================================================

/// The unknown-discriminator branch must surface a discriminator-specific
/// error message FIRST, before any inner variant decoder runs. The fix
/// uses `decode.then(decode.failure(Nil, ...), ...)` to short-circuit
/// the chain so the inner decoder is never invoked at runtime.
pub fn decoders_unknown_discriminator_short_circuits_test() {
  let assert Ok(spec) =
    parser.parse_string(
      "
openapi: '3.0.3'
info:
  title: Test
  version: 1.0.0
paths: {}
components:
  schemas:
    Shape:
      oneOf:
        - $ref: '#/components/schemas/Circle'
        - $ref: '#/components/schemas/Square'
      discriminator:
        propertyName: kind
        mapping:
          circle: '#/components/schemas/Circle'
          square: '#/components/schemas/Square'
    Circle:
      type: object
      required: [kind, radius]
      properties:
        kind:
          type: string
          enum: [circle]
        radius:
          type: number
    Square:
      type: object
      required: [kind, side]
      properties:
        kind:
          type: string
          enum: [square]
        side:
          type: number
",
    )
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = decoders.generate(ctx)
  let assert Ok(decode_file) =
    list.find(files, fn(f) { f.path == "decode.gleam" })

  // The catch-all branch must lead with `decode.failure(Nil, ...)` so
  // the inner variant decoder is never run on unknown discriminators.
  string.contains(decode_file.content, "decode.failure(Nil,")
  |> should.be_true()

  // Error message must name the discriminator value at runtime and the
  // valid alternatives at codegen time.
  string.contains(decode_file.content, "unknown discriminator '")
  |> should.be_true()
  string.contains(decode_file.content, "<> disc_value <>")
  |> should.be_true()
  // Valid values are sorted alphabetically for deterministic output.
  string.contains(decode_file.content, "(expected circle|square)")
  |> should.be_true()
}

// ===================================================================
// Binary response bodies use BytesBody(BitArray) (issue #304)
// ===================================================================

/// `application/octet-stream` responses must round-trip real bytes via
/// `BytesBody(BitArray)`. The router type definition introduces the
/// `ResponseBody` sum (TextBody / BytesBody / EmptyBody), the matching
/// response_types variant carries `BitArray`, and the dispatcher wraps
/// the handler's payload in `BytesBody(data)`.
pub fn server_octet_stream_response_emits_bytes_body_test() {
  let assert Ok(spec) =
    parser.parse_string(
      "
openapi: '3.0.3'
info:
  title: Test
  version: 1.0.0
paths:
  /thumbnail:
    get:
      operationId: getThumbnail
      responses:
        '200':
          description: PNG bytes
          content:
            application/octet-stream:
              schema:
                type: string
                format: binary
",
    )
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let server_files = server_gen.generate(ctx)
  let type_files = types_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(server_files, fn(f) { f.path == "router.gleam" })
  let assert Ok(response_types_file) =
    list.find(type_files, fn(f) { f.path == "response_types.gleam" })

  // The router emits a ResponseBody sum with the three documented variants.
  string.contains(router_file.content, "pub type ResponseBody")
  |> should.be_true()
  string.contains(router_file.content, "TextBody(String)") |> should.be_true()
  string.contains(router_file.content, "BytesBody(BitArray)")
  |> should.be_true()
  string.contains(router_file.content, "EmptyBody") |> should.be_true()

  // ServerResponse threads the new sum (not raw String) as its body.
  string.contains(router_file.content, "body: ResponseBody")
  |> should.be_true()
  string.contains(router_file.content, "body: String,") |> should.be_false()

  // Octet-stream responses dispatch via BytesBody — the bytes are not
  // smuggled through json.to_string or a String literal.
  string.contains(router_file.content, "body: BytesBody(data)")
  |> should.be_true()
  string.contains(
    router_file.content,
    "[#(\"content-type\", \"application/octet-stream\")]",
  )
  |> should.be_true()

  // The matching response_types variant carries BitArray (issue #304:
  // ir_build.gleam emits "BitArray" for octet-stream variants instead
  // of "String"). The fact that the variant is BitArray is what makes
  // the BytesBody wrapping type-check.
  string.contains(
    response_types_file.content,
    "GetThumbnailResponseOk(BitArray)",
  )
  |> should.be_true()
}

/// JSON responses keep using `TextBody(json.to_string(...))` so the
/// existing String-based contract continues to work end-to-end. This
/// guards against accidentally collapsing every body into BytesBody.
pub fn server_json_response_uses_text_body_test() {
  let assert Ok(spec) =
    parser.parse_string(
      "
openapi: '3.0.3'
info:
  title: Test
  version: 1.0.0
paths:
  /pets:
    get:
      operationId: listPets
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
                properties:
                  name:
                    type: string
",
    )
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })

  // JSON dispatch wraps the encoded String in TextBody(...).
  string.contains(router_file.content, "TextBody(json.to_string(")
  |> should.be_true()
  // No `body: BytesBody(...)` wrapping for a JSON-only spec — the
  // ResponseBody type definition still names BytesBody (always present),
  // but no dispatcher arm uses it.
  string.contains(router_file.content, "body: BytesBody(") |> should.be_false()
  // 404 fallback is still TextBody-shaped Problem JSON.
  string.contains(
    router_file.content,
    "TextBody(\"{\\\"type\\\":\\\"about:blank\\\"",
  )
  |> should.be_true()
}

/// A response with no `content` block must dispatch to `EmptyBody`,
/// preserving the previous "no body, just status" semantics without
/// forcing handlers to invent a placeholder String.
pub fn server_empty_response_emits_empty_body_test() {
  let assert Ok(spec) =
    parser.parse_string(
      "
openapi: '3.0.3'
info:
  title: Test
  version: 1.0.0
paths:
  /pets/{id}:
    delete:
      operationId: deletePet
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: integer
      responses:
        '204':
          description: deleted
",
    )
  let spec = hoist.hoist(spec)
  let ctx = test_helpers.make_ctx_from_spec(spec)
  let files = server_gen.generate(ctx)
  let assert Ok(router_file) =
    list.find(files, fn(f) { f.path == "router.gleam" })

  // 204 must dispatch via EmptyBody, not body: "" or TextBody("").
  string.contains(
    router_file.content,
    "status: 204, body: EmptyBody, headers: [])",
  )
  |> should.be_true()
  string.contains(router_file.content, "status: 204, body: \"\"")
  |> should.be_false()
}
