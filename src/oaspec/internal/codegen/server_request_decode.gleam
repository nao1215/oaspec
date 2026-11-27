import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/internal/codegen/context.{type Context}
import oaspec/internal/codegen/ir_build
import oaspec/internal/codegen/operation_ir
import oaspec/internal/openapi/spec
import oaspec/internal/util/content_type
import oaspec/internal/util/naming
import oaspec/openapi.{
  type AdditionalProperties, type Resolved, type SchemaRef, Forbidden, Inline,
  ObjectSchema, Reference, Typed, Unspecified, Untyped, Value,
}

/// How a parameter carries a Bool: one value, or a list of them.
pub type BoolShape {
  BoolScalar
  BoolList
}

/// The Bool shape of a parameter or field schema: a boolean, or an array
/// whose items are booleans, inline or through a `$ref`. `None` for every
/// other schema.
pub fn bool_shape(
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> Option(BoolShape) {
  case schema_ref_body_field_kind(schema_ref, ctx) {
    BodyFieldBool -> Some(BoolScalar)
    BodyFieldBoolArray -> Some(BoolList)
    BodyFieldUnknown
    | BodyFieldString
    | BodyFieldInt
    | BodyFieldFloat
    | BodyFieldStringArray
    | BodyFieldIntArray
    | BodyFieldFloatArray -> None
  }
}

/// `Result(List(Bool), Nil)` for the `List(String)` expression `items`:
/// every item, trimmed, must be `true` or `false`.
pub fn bool_list_result_expr(items: String) -> String {
  "list.try_map("
  <> items
  <> ", fn(item) { "
  <> bool_result_expr("string.trim(item)")
  <> " })"
}

/// `Result(Option(T), Nil)` for a value that may be absent: `Ok(None)` when
/// `lookup` does not match `present`, the parsed value in `Some` when
/// `parsed` is `Ok`, and `Error(Nil)` when a present value does not parse.
fn optional_checked_result_expr(
  lookup: String,
  present: String,
  parsed: String,
) -> String {
  "case "
  <> lookup
  <> " { "
  <> present
  <> " -> case "
  <> parsed
  <> " { Ok(value) -> Ok(Some(value)) _ -> Error(Nil) } _ -> Ok(None) }"
}

/// `Option(Bool)` for the String expression `value`, `None` when it is not
/// `true` or `false`. The router checks every Bool it reads into a request
/// before building it, so this only keeps the unchecked expressions total.
fn bool_option_expr(value: String) -> String {
  "case " <> bool_result_expr(value) <> " { Ok(b) -> Some(b) _ -> None }"
}

/// `List(Bool)` for the `List(String)` expression `items`, dropping the
/// items that are not `true` or `false`. Like `bool_option_expr`, only
/// reached where the router has not already checked the value.
fn bool_list_filter_expr(items: String, trim: Bool) -> String {
  let item = case trim {
    True -> "string.trim(item)"
    False -> "item"
  }
  "list.filter_map("
  <> items
  <> ", fn(item) { "
  <> bool_result_expr(item)
  <> " })"
}

type DeepObjectProperty {
  DeepObjectProperty(
    name: String,
    field_name: String,
    schema_ref: SchemaRef,
    required: Bool,
  )
}

pub type BodyFieldKind {
  BodyFieldUnknown
  BodyFieldString
  BodyFieldInt
  BodyFieldFloat
  BodyFieldBool
  BodyFieldStringArray
  BodyFieldIntArray
  BodyFieldFloatArray
  BodyFieldBoolArray
}

pub fn schema_ref_body_field_kind(
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> BodyFieldKind {
  case schema_ref {
    Some(schema_ref) -> body_field_kind(schema_ref, ctx)
    None -> BodyFieldUnknown
  }
}

pub fn body_field_kind(schema_ref: SchemaRef, ctx: Context) -> BodyFieldKind {
  case schema_ref {
    Inline(openapi.StringSchema(..)) -> BodyFieldString
    Inline(openapi.IntegerSchema(..)) -> BodyFieldInt
    Inline(openapi.NumberSchema(..)) -> BodyFieldFloat
    Inline(openapi.BooleanSchema(..)) -> BodyFieldBool
    Inline(openapi.ArraySchema(items:, ..)) ->
      case body_field_kind(items, ctx) {
        BodyFieldString -> BodyFieldStringArray
        BodyFieldInt -> BodyFieldIntArray
        BodyFieldFloat -> BodyFieldFloatArray
        BodyFieldBool -> BodyFieldBoolArray
        _ -> BodyFieldUnknown
      }
    Reference(..) as schema_ref ->
      case context.resolve_schema_ref(schema_ref, ctx) {
        Ok(schema_obj) -> body_field_kind_from_object(schema_obj, ctx)
        // nolint: thrown_away_error -- unresolved refs map to Unknown; the resolver reports the ref error separately
        Error(_) -> BodyFieldUnknown
      }
    _ -> BodyFieldUnknown
  }
}

fn body_field_kind_from_object(
  schema_obj: openapi.SchemaObject,
  ctx: Context,
) -> BodyFieldKind {
  case schema_obj {
    openapi.StringSchema(..) -> BodyFieldString
    openapi.IntegerSchema(..) -> BodyFieldInt
    openapi.NumberSchema(..) -> BodyFieldFloat
    openapi.BooleanSchema(..) -> BodyFieldBool
    openapi.ArraySchema(items:, ..) ->
      case body_field_kind(items, ctx) {
        BodyFieldString -> BodyFieldStringArray
        BodyFieldInt -> BodyFieldIntArray
        BodyFieldFloat -> BodyFieldFloatArray
        BodyFieldBool -> BodyFieldBoolArray
        _ -> BodyFieldUnknown
      }
    _ -> BodyFieldUnknown
  }
}

pub fn body_field_kind_needs_int(kind: BodyFieldKind) -> Bool {
  case kind {
    BodyFieldInt | BodyFieldIntArray -> True
    _ -> False
  }
}

pub fn body_field_kind_needs_float(kind: BodyFieldKind) -> Bool {
  case kind {
    BodyFieldFloat | BodyFieldFloatArray -> True
    _ -> False
  }
}

/// Generate parse expression for a path parameter (already bound as String).
/// Returns a safe expression that does not crash on invalid input.
/// For types that need parsing (int, float, bool, a string enum, a list of
/// numbers, bools or enum items), returns the raw `Result` so the router can wrap it in a
/// case expression that answers 400 on failure. A `$ref` schema is read
/// through to its target, and an array is the `simple` style
/// comma-separated list.
pub fn param_parse_expr(
  var_name: String,
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> String {
  let split = "string.split(" <> var_name <> ", \",\")"
  let schema_ref = spec.parameter_schema(param)
  case path_param_enum(param, ctx), enum_array_items(schema_ref, ctx) {
    Some(#(type_name, values)), _ ->
      enum_match_result_expr(var_name, type_name, values)
    None, Some(#(type_name, values)) ->
      enum_list_result_expr(split, type_name, values)
    None, None ->
      case schema_ref_body_field_kind(schema_ref, ctx) {
        BodyFieldInt -> "int.parse(" <> var_name <> ")"
        BodyFieldFloat -> "float.parse(" <> var_name <> ")"
        BodyFieldBool -> bool_result_expr(var_name)
        BodyFieldStringArray -> split
        BodyFieldIntArray -> "list.try_map(" <> split <> ", int.parse)"
        BodyFieldFloatArray -> "list.try_map(" <> split <> ", float.parse)"
        BodyFieldBoolArray -> bool_list_result_expr(split)
        BodyFieldString | BodyFieldUnknown -> var_name
      }
  }
}

/// Return true when the parse expression returns a Result that the router
/// must unwrap. Only string params are always safe.
pub fn param_needs_result_unwrap(
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  use <- bool.guard(
    option.is_some(enum_array_items(spec.parameter_schema(param), ctx)),
    True,
  )
  case path_param_enum(param, ctx) {
    Some(_) -> True
    None ->
      case schema_ref_body_field_kind(spec.parameter_schema(param), ctx) {
        BodyFieldInt
        | BodyFieldFloat
        | BodyFieldBool
        | BodyFieldIntArray
        | BodyFieldFloatArray
        | BodyFieldBoolArray -> True
        BodyFieldString | BodyFieldStringArray | BodyFieldUnknown -> False
      }
  }
}

fn path_param_enum(
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> Option(#(String, List(String))) {
  case spec.parameter_schema(param) {
    Some(schema_ref) -> schema_ref_string_enum(schema_ref, ctx)
    None -> None
  }
}

/// Whether the path parameter's parse expression calls into
/// `gleam/string` (a list split on commas).
pub fn path_param_needs_string(
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  case schema_ref_body_field_kind(spec.parameter_schema(param), ctx) {
    BodyFieldStringArray
    | BodyFieldIntArray
    | BodyFieldFloatArray
    | BodyFieldBoolArray -> True
    BodyFieldBool
    | BodyFieldInt
    | BodyFieldFloat
    | BodyFieldString
    | BodyFieldUnknown -> False
  }
}

/// Whether the path parameter is a list, whose parse expression calls
/// into `gleam/list`.
pub fn path_param_is_list(
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  case schema_ref_body_field_kind(spec.parameter_schema(param), ctx) {
    BodyFieldStringArray
    | BodyFieldIntArray
    | BodyFieldFloatArray
    | BodyFieldBoolArray -> True
    BodyFieldInt
    | BodyFieldFloat
    | BodyFieldBool
    | BodyFieldString
    | BodyFieldUnknown -> False
  }
}

/// Generate expression for a required query parameter.
///
/// `bound_var` is the name of a variable that the router has already bound
/// in an enclosing case expression. For scalar params (string/bool/int/float)
/// this is the raw String value pulled out of the query dict. For array
/// params with `explode=true` this is the `List(String)` from the dict; with
/// `explode=false` it is the single raw String that still needs splitting.
///
/// The router opens a `case dict.get(query, key) { Ok([raw, ..]) -> ...`
/// (or `Ok(raw_list) -> ...` for explode-true arrays) **before** asking this
/// helper for the value expression, so the lookup never `let assert`s.
///
/// For numeric scalar/array parameters the router additionally opens a
/// `case int.parse(...)` / `float.parse(...)` (or `list.try_map(..., int.parse)`)
/// case, binding `<bound_var>_parsed` (or `<bound_var>_parsed_list`) on
/// success — that's the variable name the helper returns here.
pub fn query_required_expr(
  bound_var: String,
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> String {
  query_required_expr_with_schema(
    bound_var,
    spec.parameter_schema(param),
    Some(operation_ir.effective_explode(param)),
    param.style,
    ctx,
  )
}

/// Opening and closing text of the nested case that looks up one required
/// field of a deep-object parameter or a form / multipart body in the
/// `source` dict and binds it to `binding`. A missing or unparseable value
/// falls through to `Error(Nil)`. `trim` trims array items before parsing.
fn required_field_case(
  key: String,
  source: String,
  trim: Bool,
  binding: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> #(String, String) {
  let lookup = "case dict.get(" <> source <> ", \"" <> key <> "\") { "
  let fail = " _ -> Error(Nil) }"
  let bind = " { Ok(" <> binding <> ") -> "
  let parse_case = fn(parse_expr) {
    #(lookup <> "Ok([v, ..]) -> case " <> parse_expr <> bind, fail <> fail)
  }
  let parse_list_case = fn(parse_item) {
    let item = case trim {
      True -> "string.trim(item)"
      False -> "item"
    }
    #(
      lookup
        <> "Ok(vs) -> case list.try_map(vs, fn(item) { "
        <> parse_item(item)
        <> " })"
        <> bind,
      fail <> fail,
    )
  }
  let let_case = fn(pattern, value_expr) {
    #(
      lookup <> pattern <> " -> { let " <> binding <> " = " <> value_expr <> " ",
      " }" <> fail,
    )
  }
  case schema_ref_string_enum(schema_ref, ctx) {
    Some(#(type_name, values)) ->
      parse_case(enum_match_result_expr("v", type_name, values))
    None ->
      case body_field_kind(schema_ref, ctx) {
        BodyFieldStringArray ->
          case trim {
            True ->
              let_case("Ok(vs)", "list.map(vs, fn(item) { string.trim(item) })")
            False -> let_case("Ok(vs)", "vs")
          }
        BodyFieldIntArray ->
          parse_list_case(fn(item) { "int.parse(" <> item <> ")" })
        BodyFieldFloatArray ->
          parse_list_case(fn(item) { "float.parse(" <> item <> ")" })
        BodyFieldBoolArray -> parse_list_case(bool_result_expr)
        BodyFieldInt -> parse_case("int.parse(v)")
        BodyFieldFloat -> parse_case("float.parse(v)")
        BodyFieldBool -> parse_case(bool_result_expr("v"))
        BodyFieldString | BodyFieldUnknown -> #(
          lookup <> "Ok([" <> binding <> ", ..]) -> ",
          fail,
        )
      }
  }
}

/// `Ok(True)` / `Ok(False)` for `true` / `false`, `Error(Nil)` for any
/// other value of the String expression `value`, so that a value such as
/// `TRUE`, `1`, `yes` or an empty string answers 400 instead of reading as
/// False. OpenAPI and JSON Schema spell booleans in lowercase, and the
/// generated client sends them that way.
pub fn bool_result_expr(value: String) -> String {
  "case "
  <> value
  <> " { \"true\" -> Ok(True) \"false\" -> Ok(False) _ -> Error(Nil) }"
}

/// How the router parses a present optional parameter that it checks
/// before building the request.
type CheckedParse {
  /// One value: `parse` takes the String expression of the value.
  CheckedValue(parse: fn(String) -> String)
  /// A list: `parse_items` takes the `List(String)` expression of the items.
  CheckedList(parse_items: fn(String) -> String)
}

/// The `CheckedParse` of a Bool, a list of Bools or a list of enum items.
/// `None` for every other schema.
fn optional_checked_parse(
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> Option(CheckedParse) {
  case bool_shape(schema_ref, ctx), enum_array_items(schema_ref, ctx) {
    Some(BoolScalar), _ -> Some(CheckedValue(bool_result_expr))
    Some(BoolList), _ -> Some(CheckedList(bool_list_result_expr))
    None, Some(#(type_name, values)) ->
      Some(
        CheckedList(fn(items) {
          enum_list_result_expr(items, type_name, values)
        }),
      )
    None, None -> None
  }
}

/// For an optional query, header or cookie parameter that is a Bool, a
/// list of Bools or a list of enum items, the expression of type
/// `Result(Option(T), Nil)` that reads it. A present value that does not
/// parse, such as a Bool other than `true` or `false` or an item that is not
/// one of the enum's values, is `Error(Nil)`, which the router answers with
/// 400. `None` for every other parameter.
pub fn optional_checked_param_result_expr(
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> Option(String) {
  use checked <- option.then(optional_checked_parse(
    spec.parameter_schema(param),
    ctx,
  ))
  // A query value is a list of every occurrence; a header or cookie value
  // is one String. A path parameter is always required.
  use #(lookup, multi) <- option.then(case param.in_ {
    openapi.InQuery ->
      Some(#("dict.get(query, \"" <> param.name <> "\")", True))
    openapi.InHeader ->
      Some(#(
        "dict.get(headers, \"" <> string.lowercase(param.name) <> "\")",
        False,
      ))
    openapi.InCookie ->
      Some(#("cookie_lookup(headers, \"" <> param.name <> "\")", False))
    openapi.InPath -> None
  })
  let delim = operation_ir.delimiter_for_style(param.style)
  let #(present, parsed) = case checked, multi {
    CheckedValue(parse), True -> #("Ok([v, ..])", parse("v"))
    CheckedValue(parse), False -> #("Ok(v)", parse("v"))
    CheckedList(parse_items), True ->
      case operation_ir.effective_explode(param) {
        True -> #("Ok(vs)", parse_items("vs"))
        False -> #(
          "Ok(vs)",
          // An empty item, as in `?picks=` or `?picks=true,`, does not
          // parse, so it answers 400 as it does for a required list.
          parse_items(
            "list.flat_map(vs, fn(v) { string.split(v, \"" <> delim <> "\") })",
          ),
        )
      }
    CheckedList(parse_items), False -> #(
      "Ok(v)",
      parse_items("string.split(v, \",\")"),
    )
  }
  Some(optional_checked_result_expr(lookup, present, parsed))
}

/// Whether a deep-object, form or multipart field is read in a nested case
/// that answers 400 when it does not parse: a required field, and an
/// optional Bool field, whose value must be `true` or `false` when present.
fn field_needs_check(
  required: Bool,
  schema_ref: SchemaRef,
  ctx: Context,
) -> Bool {
  required || option.is_some(bool_shape(Some(schema_ref), ctx))
}

/// The nested case that binds a field for which `field_needs_check` holds.
/// An optional field is bound as an `Option`.
fn checked_field_case(
  key: String,
  source: String,
  trim: Bool,
  binding: String,
  required: Bool,
  schema_ref: SchemaRef,
  ctx: Context,
) -> #(String, String) {
  case required {
    True -> required_field_case(key, source, trim, binding, schema_ref, ctx)
    False -> {
      let lookup = "dict.get(" <> source <> ", \"" <> key <> "\")"
      let item = case trim {
        True -> "string.trim(item)"
        False -> "item"
      }
      // `field_needs_check` holds, so an optional field is a Bool or a
      // list of Bools.
      let #(present, parsed) = case body_field_kind(schema_ref, ctx) {
        BodyFieldBoolArray -> #(
          "Ok(vs)",
          "list.try_map(vs, fn(item) { " <> bool_result_expr(item) <> " })",
        )
        BodyFieldBool
        | BodyFieldUnknown
        | BodyFieldString
        | BodyFieldInt
        | BodyFieldFloat
        | BodyFieldStringArray
        | BodyFieldIntArray
        | BodyFieldFloatArray -> #("Ok([v, ..])", bool_result_expr("v"))
      }
      #(
        "case "
          <> optional_checked_result_expr(lookup, present, parsed)
          <> " { Ok("
          <> binding
          <> ") -> ",
        " _ -> Error(Nil) }",
      )
    }
  }
}

/// Wrap the record constructor `constructor` in the nested `cases` so it
/// becomes `Ok(constructor)` only when every case matched.
fn checked_constructor(
  cases: List(#(String, String)),
  constructor: String,
) -> String {
  let opening = cases |> list.map(fn(c) { c.0 }) |> string.concat
  let closing =
    cases |> list.reverse |> list.map(fn(c) { c.1 }) |> string.concat
  opening <> "Ok(" <> constructor <> ")" <> closing
}

fn query_required_expr_with_schema(
  bound_var: String,
  schema_ref: Option(SchemaRef),
  explode: Option(Bool),
  style: Option(openapi.ParameterStyle),
  ctx: Context,
) -> String {
  let delim = operation_ir.delimiter_for_style(style)
  // The router parses a Bool parameter in its own case and binds the
  // result (see `query_required_open_parse_case` in server.gleam).
  use <- bool.lazy_guard(bool_shape(schema_ref, ctx) == Some(BoolScalar), fn() {
    bound_var <> "_parsed"
  })
  use <- bool.lazy_guard(bool_shape(schema_ref, ctx) == Some(BoolList), fn() {
    bound_var <> "_parsed_list"
  })
  // Likewise an array of enum items.
  use <- bool.lazy_guard(
    option.is_some(enum_array_items(schema_ref, ctx)),
    fn() { bound_var <> "_parsed_list" },
  )
  case schema_ref {
    Some(Inline(openapi.ArraySchema(items: Inline(openapi.StringSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "list.map(string.split("
          <> bound_var
          <> ", \""
          <> delim
          <> "\"), fn(item) { string.trim(item) })"
        _ -> "list.map(" <> bound_var <> ", fn(item) { string.trim(item) })"
      }
    Some(Inline(openapi.ArraySchema(
      items: Inline(openapi.IntegerSchema(..)),
      ..,
    ))) ->
      // The router opens a `case list.try_map(..., int.parse)` and binds
      // `<bound_var>_parsed_list` on Ok, so the value expression is just
      // that bound name.
      bound_var <> "_parsed_list"
    Some(Inline(openapi.ArraySchema(items: Inline(openapi.NumberSchema(..)), ..))) ->
      bound_var <> "_parsed_list"
    Some(Inline(openapi.IntegerSchema(..))) -> bound_var <> "_parsed"
    Some(Inline(openapi.NumberSchema(..))) -> bound_var <> "_parsed"
    Some(ref) ->
      case schema_ref_string_enum(ref, ctx) {
        // Required enum query params rely on the router-side
        // open/close scaffolding (see `query_required_open_parse_case` /
        // `close_single_value_required_parse_case` in server.gleam) to
        // bind `<bound_var>_parsed` on a successful match and emit a 400
        // on unknown values. The expression here is just the bound name.
        Some(_) -> bound_var <> "_parsed"
        None -> bound_var
      }
    None -> bound_var
  }
}

/// Generate expression for an optional query parameter.
pub fn query_optional_expr(
  key: String,
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> String {
  query_optional_expr_with_schema(
    key,
    spec.parameter_schema(param),
    Some(operation_ir.effective_explode(param)),
    param.style,
    ctx,
  )
}

/// Classify the underlying scalar kind of a SchemaRef,
/// resolving `$ref` to its target schema. Used by query / header /
/// cookie parameter codegen so that ref-typed scalars get the same
/// `int.parse` / `float.parse` / boolean parsing as their inline
/// equivalents instead of a raw String, which would not type-check
/// against `Option(Int)`.
type ScalarKind {
  IntegerScalar
  NumberScalar
  BooleanScalar
}

fn schema_ref_scalar_kind(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Option(ScalarKind) {
  case context.resolve_schema_ref(schema_ref, ctx) {
    Ok(openapi.IntegerSchema(..)) -> Some(IntegerScalar)
    Ok(openapi.NumberSchema(..)) -> Some(NumberScalar)
    Ok(openapi.BooleanSchema(..)) -> Some(BooleanScalar)
    _ -> None
  }
}

/// If `schema_ref` is a `$ref` to a string enum schema, return the
/// generated Gleam type name and the list of enum values (in spec
/// order). Used by query parameter codegen to emit a string→variant
/// match for `$ref`-based enum query parameters.
pub fn schema_ref_string_enum(
  schema_ref: SchemaRef,
  ctx: Context,
) -> Option(#(String, List(String))) {
  case schema_ref {
    Reference(name: ref_name, ..) ->
      case context.resolve_schema_ref(schema_ref, ctx) {
        Ok(openapi.StringSchema(enum_values: values, ..)) ->
          case values {
            [_, ..] -> Some(#(naming.schema_to_type_name(ref_name), values))
            [] -> None
          }
        _ -> None
      }
    _ -> None
  }
}

/// True iff any query / header / cookie parameter on any of the given
/// operations has a `$ref` schema that resolves to a string-enum.
///
/// The router emits `types.<EnumType><Variant>` references
/// for these parameters (see `enum_match_result_expr` and
/// `enum_match_option_expr` below), but the import of the `types`
/// module is gated on a separate set of features (deep object, form,
/// multipart). This helper lets the router-import logic ask "does any
/// of my emitted code reference `types`?" without re-implementing the
/// per-param dispatch.
pub fn operations_have_enum_ref_params(
  operations: List(context.AnalyzedOperation),
  ctx: Context,
) -> Bool {
  list.any(operations, fn(op) {
    let context.AnalyzedOperation(_, operation, _, _) = op
    list.any(operation.parameters, fn(ref_p) {
      case ref_p {
        Value(p) -> parameter_is_enum_ref(p, ctx)
        _ -> False
      }
    })
  })
}

fn parameter_is_enum_ref(p: openapi.Parameter(Resolved), ctx: Context) -> Bool {
  case p.in_, spec.parameter_schema(p) {
    openapi.InQuery, Some(s)
    | openapi.InHeader, Some(s)
    | openapi.InCookie, Some(s)
    | openapi.InPath, Some(s)
    ->
      option.is_some(schema_ref_string_enum(s, ctx))
      || option.is_some(enum_array_items(Some(s), ctx))
    _, _ -> False
  }
}

/// Render the inline Gleam expression that converts a raw query-string
/// `<bound_var>` into `Result(types.<TypeName><Variant>, Nil)`. Used by
/// the required-enum query path (server.gleam opens a case on this
/// expression; the Ok arm binds `<bound_var>_parsed`).
pub fn enum_match_result_expr(
  bound_var: String,
  type_name: String,
  values: List(String),
) -> String {
  let arms =
    values
    |> list.map(fn(v) {
      "\""
      <> v
      <> "\" -> Ok(types."
      <> type_name
      <> naming.to_pascal_case(v)
      <> ")"
    })
    |> string.join(" ")
  "case " <> bound_var <> " { " <> arms <> " _ -> Error(Nil) }"
}

/// The enum type name and values of an inline array schema whose items are
/// a `$ref` to a string enum. `None` for every other schema.
pub fn enum_array_items(
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> Option(#(String, List(String))) {
  case schema_ref {
    Some(Inline(openapi.ArraySchema(items:, ..))) ->
      schema_ref_string_enum(items, ctx)
    _ -> None
  }
}

/// `Result(List(types.<TypeName>), Nil)` for the `List(String)` expression
/// `items`: every item, trimmed, must be one of the enum's `values`.
pub fn enum_list_result_expr(
  items: String,
  type_name: String,
  values: List(String),
) -> String {
  "list.try_map("
  <> items
  <> ", fn(item) { "
  <> enum_match_result_expr("string.trim(item)", type_name, values)
  <> " })"
}

/// Render the inline Gleam expression that converts a raw query-string
/// `<v_var>` into `Option(types.<TypeName><Variant>)` for an optional
/// enum query parameter. Unknown values map to `None`, matching the
/// permissive behaviour of Int / Float optional query handling.
fn enum_match_option_expr(
  v_var: String,
  type_name: String,
  values: List(String),
) -> String {
  let arms =
    values
    |> list.map(fn(v) {
      "\""
      <> v
      <> "\" -> Some(types."
      <> type_name
      <> naming.to_pascal_case(v)
      <> ")"
    })
    |> string.join(" ")
  "case " <> v_var <> " { " <> arms <> " _ -> None }"
}

fn query_optional_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  explode: Option(Bool),
  style: Option(openapi.ParameterStyle),
  ctx: Context,
) -> String {
  let delim = operation_ir.delimiter_for_style(style)
  case schema_ref {
    // For `style: pipeDelimited` / `style:
    // spaceDelimited` / `style: form, explode: false` (i.e. delim
    // != ","), the codegen uses `Ok(vs)` to accept every occurrence
    // (`?tags=a&tags=b` keeps `b`), flat_maps the splits across them,
    // and filters out the empty strings produced by empty input or
    // trailing delimiters, so `?tags=` is `Some([])`, not `Some([""])`.
    Some(Inline(openapi.ArraySchema(items: Inline(openapi.StringSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some(vs |> list.flat_map(fn(v) { string.split(v, \""
          <> delim
          <> "\") }) |> list.map(string.trim) |> list.filter(fn(s) { s != \"\" })) _ -> None }"
        _ ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { string.trim(item) })) _ -> None }"
      }
    Some(Inline(openapi.ArraySchema(
      items: Inline(openapi.IntegerSchema(..)),
      ..,
    ))) ->
      case explode {
        Some(False) ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some(vs |> list.flat_map(fn(v) { string.split(v, \""
          <> delim
          <> "\") }) |> list.filter_map(fn(item) { let trimmed = string.trim(item) case trimmed { \"\" -> Error(Nil) _ -> int.parse(trimmed) } })) _ -> None }"
        _ ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let trimmed = string.trim(item) case int.parse(trimmed) { Ok(n) -> n _ -> 0 } })) _ -> None }"
      }
    Some(Inline(openapi.ArraySchema(items: Inline(openapi.NumberSchema(..)), ..))) ->
      case explode {
        Some(False) ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some(vs |> list.flat_map(fn(v) { string.split(v, \""
          <> delim
          <> "\") }) |> list.filter_map(fn(item) { let trimmed = string.trim(item) case trimmed { \"\" -> Error(Nil) _ -> float.parse(trimmed) } })) _ -> None }"
        _ ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some(list.map(vs, fn(item) { let trimmed = string.trim(item) case float.parse(trimmed) { Ok(n) -> n _ -> 0.0 } })) _ -> None }"
      }
    Some(Inline(openapi.ArraySchema(
      items: Inline(openapi.BooleanSchema(..)),
      ..,
    ))) ->
      case explode {
        Some(False) ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some("
          <> bool_list_filter_expr(
            "vs |> list.flat_map(fn(v) { string.split(v, \""
              <> delim
              <> "\") })",
            True,
          )
          <> ") _ -> None }"
        _ ->
          "case dict.get(query, \""
          <> key
          <> "\") { Ok(vs) -> Some("
          <> bool_list_filter_expr("vs", True)
          <> ") _ -> None }"
      }
    Some(Inline(openapi.IntegerSchema(..))) ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok([v, ..]) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    Some(Inline(openapi.NumberSchema(..))) ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
    Some(Inline(openapi.BooleanSchema(..))) ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok([v, ..]) -> "
      <> bool_option_expr("v")
      <> " _ -> None }"
    Some(ref) ->
      case schema_ref_string_enum(ref, ctx) {
        Some(#(type_name, values)) -> {
          // Enum-typed query params need string→variant
          // conversion. Unknown values fall through to None, matching
          // the permissive handling of malformed Int / Float optional
          // query params.
          "case dict.get(query, \""
          <> key
          <> "\") { Ok([v, ..]) -> "
          <> enum_match_option_expr("v", type_name, values)
          <> " _ -> None }"
        }
        None ->
          // When the `$ref` resolves to an integer /
          // number / boolean schema, mirror the parse handling of
          // the corresponding `Inline(...)` arms above; a bare `Some(v)`
          // (a String) would not fit the `Option(Int|Float|Bool)` slot.
          case schema_ref_scalar_kind(ref, ctx) {
            Some(IntegerScalar) ->
              "case dict.get(query, \""
              <> key
              <> "\") { Ok([v, ..]) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
            Some(NumberScalar) ->
              "case dict.get(query, \""
              <> key
              <> "\") { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } _ -> None }"
            Some(BooleanScalar) ->
              "case dict.get(query, \""
              <> key
              <> "\") { Ok([v, ..]) -> "
              <> bool_option_expr("v")
              <> " _ -> None }"
            None ->
              "case dict.get(query, \""
              <> key
              <> "\") { Ok([v, ..]) -> Some(v) _ -> None }"
          }
      }
    None ->
      "case dict.get(query, \""
      <> key
      <> "\") { Ok([v, ..]) -> Some(v) _ -> None }"
  }
}

fn deep_object_properties(
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> List(DeepObjectProperty) {
  let details = case spec.parameter_schema(param) {
    Some(Reference(..) as schema_ref) ->
      case context.resolve_schema_ref(schema_ref, ctx) {
        Ok(ObjectSchema(properties:, required:, ..)) -> #(properties, required)
        _ -> #(dict.new(), [])
      }
    Some(Inline(ObjectSchema(properties:, required:, ..))) -> #(
      properties,
      required,
    )
    _ -> #(dict.new(), [])
  }
  let #(properties, required_fields) = details
  ir_build.sorted_entries(properties)
  |> list.map(fn(entry) {
    let #(prop_name, prop_ref) = entry
    DeepObjectProperty(
      name: prop_name,
      field_name: naming.to_snake_case(prop_name),
      schema_ref: prop_ref,
      required: list.contains(required_fields, prop_name),
    )
  })
}

fn deep_object_type_name(
  param: openapi.Parameter(Resolved),
  op_id: String,
) -> String {
  case spec.parameter_schema(param) {
    Some(Reference(name:, ..)) -> "types." <> naming.schema_to_type_name(name)
    _ ->
      "types."
      <> naming.schema_to_type_name(op_id)
      <> "Param"
      <> naming.to_pascal_case(param.name)
  }
}

/// True when the deep-object parameter has a property that must be checked
/// (see `field_needs_check`), so the router must look it up into a Result
/// and answer 400 when it is missing or does not parse.
pub fn deep_object_needs_check(
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  list.any(deep_object_properties(param, ctx), fn(prop) {
    deep_object_property_needs_check(prop, ctx)
  })
}

fn deep_object_property_needs_check(
  prop: DeepObjectProperty,
  ctx: Context,
) -> Bool {
  field_needs_check(prop.required, prop.schema_ref, ctx)
}

/// Expression of type `Result(T, Nil)` (or `Result(Option(T), Nil)` for an
/// optional parameter) that builds the deep-object record. The router binds
/// it and answers 400 on `Error`.
pub fn deep_object_result_expr(
  key: String,
  param: openapi.Parameter(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  let constructor = deep_object_constructor_result_expr(key, param, op_id, ctx)
  case param.required {
    True -> constructor
    False ->
      "case "
      <> deep_object_presence_check(key, param, ctx)
      <> " { True -> case "
      <> constructor
      <> " { Ok(value) -> Ok(Some(value)) _ -> Error(Nil) } False -> Ok(None) }"
  }
}

/// Plain expression that builds the deep-object record when the parameter
/// has no required property.
pub fn deep_object_required_expr(
  key: String,
  param: openapi.Parameter(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  deep_object_constructor_expr(key, param, op_id, ctx)
}

pub fn deep_object_optional_expr(
  key: String,
  param: openapi.Parameter(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  "case "
  <> deep_object_presence_check(key, param, ctx)
  <> " { True -> Some("
  <> deep_object_required_expr(key, param, op_id, ctx)
  <> ") False -> None }"
}

fn deep_object_presence_check(
  key: String,
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> String {
  case deep_object_has_untyped_additional_properties(param, ctx) {
    True -> "deep_object_present_any(query, \"" <> key <> "\")"
    False -> {
      let prop_names =
        deep_object_properties(param, ctx)
        |> list.map(fn(prop) { "\"" <> prop.name <> "\"" })
        |> string.join(", ")
      "deep_object_present(query, \"" <> key <> "\", [" <> prop_names <> "])"
    }
  }
}

fn deep_object_constructor_result_expr(
  key: String,
  param: openapi.Parameter(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  let cases =
    deep_object_properties(param, ctx)
    |> list.filter(fn(prop) { deep_object_property_needs_check(prop, ctx) })
    |> list.map(fn(prop) {
      checked_field_case(
        key <> "[" <> prop.name <> "]",
        "query",
        True,
        deep_object_binding(prop),
        prop.required,
        prop.schema_ref,
        ctx,
      )
    })
  checked_constructor(
    cases,
    deep_object_constructor_expr(key, param, op_id, ctx),
  )
}

fn deep_object_binding(prop: DeepObjectProperty) -> String {
  "deep_" <> prop.field_name
}

/// Record constructor for the deep-object parameter. Properties that must
/// be checked are read from the `deep_<field>` variables that
/// `deep_object_constructor_result_expr` binds; the others are looked up
/// inline.
fn deep_object_constructor_expr(
  key: String,
  param: openapi.Parameter(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  let fields =
    deep_object_properties(param, ctx)
    |> list.map(fn(prop) {
      let prop_key = key <> "[" <> prop.name <> "]"
      let value_expr = case deep_object_property_needs_check(prop, ctx) {
        True -> deep_object_binding(prop)
        False ->
          query_optional_expr_with_schema(
            prop_key,
            Some(prop.schema_ref),
            Some(True),
            None,
            ctx,
          )
      }
      prop.field_name <> ": " <> value_expr
    })

  // Add additional_properties field if the schema has it
  let ap_kind = case spec.parameter_schema(param) {
    Some(schema_ref) -> schema_ref_additional_properties(schema_ref, ctx)
    None -> Forbidden
  }
  let fields = case ap_kind {
    // Forbidden and Unspecified both suppress the generated record's
    // additional_properties field.
    Forbidden | Unspecified -> fields
    Untyped -> {
      let prop_names =
        deep_object_properties(param, ctx)
        |> list.map(fn(prop) { "\"" <> prop.name <> "\"" })
        |> string.join(", ")
      let expr =
        "coerce_dict(deep_object_additional_properties(query, \""
        <> key
        <> "\", ["
        <> prop_names
        <> "]))"
      list.append(fields, ["additional_properties: " <> expr])
    }
    Typed(_) -> {
      // Typed additional properties need type-specific conversion;
      // use empty dict as fallback until type-aware collection is implemented
      list.append(fields, ["additional_properties: dict.new()"])
    }
  }

  let fields_str = string.join(fields, ", ")
  deep_object_type_name(param, op_id) <> "(" <> fields_str <> ")"
}

pub fn deep_object_has_additional_properties(
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  case spec.parameter_schema(param) {
    Some(Reference(..) as schema_ref) ->
      case context.resolve_schema_ref(schema_ref, ctx) {
        Ok(ObjectSchema(additional_properties: openapi.Typed(_), ..)) -> True
        Ok(ObjectSchema(additional_properties: openapi.Untyped, ..)) -> True
        _ -> False
      }
    Some(Inline(ObjectSchema(additional_properties: openapi.Typed(_), ..))) ->
      True
    Some(Inline(ObjectSchema(additional_properties: openapi.Untyped, ..))) ->
      True
    _ -> False
  }
}

pub fn deep_object_has_untyped_additional_properties(
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  case spec.parameter_schema(param) {
    Some(schema_ref) ->
      case schema_ref_additional_properties(schema_ref, ctx) {
        Untyped -> True
        _ -> False
      }
    None -> False
  }
}

pub fn deep_object_param_has_optional_fields(
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  use <- bool.guard(!operation_ir.is_deep_object_param(param, ctx), False)
  list.any(deep_object_properties(param, ctx), fn(prop) { !prop.required })
}

pub fn deep_object_param_needs_string(
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  deep_object_param_needs(param, ctx, fn(prop) {
    query_schema_needs_string(Some(prop.schema_ref))
  })
}

pub fn deep_object_param_needs_int(
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  deep_object_param_needs(param, ctx, fn(prop) {
    query_schema_needs_int(Some(prop.schema_ref), ctx)
  })
}

pub fn deep_object_param_needs_float(
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> Bool {
  deep_object_param_needs(param, ctx, fn(prop) {
    query_schema_needs_float(Some(prop.schema_ref), ctx)
  })
}

fn deep_object_param_needs(
  param: openapi.Parameter(Resolved),
  ctx: Context,
  predicate: fn(DeepObjectProperty) -> Bool,
) -> Bool {
  use <- bool.guard(!operation_ir.is_deep_object_param(param, ctx), False)
  list.any(deep_object_properties(param, ctx), predicate)
}

pub fn request_body_uses_form_urlencoded(
  rb: openapi.RequestBody(Resolved),
) -> Bool {
  dict.has_key(rb.content, "application/x-www-form-urlencoded")
}

pub fn request_body_uses_multipart(rb: openapi.RequestBody(Resolved)) -> Bool {
  dict.has_key(rb.content, "multipart/form-data")
}

/// An `application/octet-stream` request body is raw
/// bytes, so the router takes `body: BitArray` instead of
/// `body: String`. The single-arm dispatch (no other content types
/// allowed alongside binary) is enforced by the validator.
fn request_body_uses_octet_stream(rb: openapi.RequestBody(Resolved)) -> Bool {
  dict.has_key(rb.content, "application/octet-stream")
}

pub fn operation_uses_form_urlencoded_body(
  operation: openapi.Operation(Resolved),
) -> Bool {
  case operation.request_body {
    Some(Value(rb)) -> request_body_uses_form_urlencoded(rb)
    _ -> False
  }
}

pub fn operation_uses_multipart_body(
  operation: openapi.Operation(Resolved),
) -> Bool {
  case operation.request_body {
    Some(Value(rb)) -> request_body_uses_multipart(rb)
    _ -> False
  }
}

pub fn operation_uses_octet_stream_body(
  operation: openapi.Operation(Resolved),
) -> Bool {
  case operation.request_body {
    Some(Value(rb)) -> request_body_uses_octet_stream(rb)
    _ -> False
  }
}

fn object_properties_from_schema_ref(
  schema_ref: SchemaRef,
  ctx: Context,
) -> List(DeepObjectProperty) {
  let details = case schema_ref {
    Reference(..) as schema_ref ->
      case context.resolve_schema_ref(schema_ref, ctx) {
        Ok(ObjectSchema(properties:, required:, ..)) -> #(properties, required)
        _ -> #(dict.new(), [])
      }
    Inline(ObjectSchema(properties:, required:, ..)) -> #(properties, required)
    _ -> #(dict.new(), [])
  }
  let #(properties, required_fields) = details
  ir_build.sorted_entries(properties)
  |> list.map(fn(entry) {
    let #(prop_name, prop_ref) = entry
    DeepObjectProperty(
      name: prop_name,
      field_name: naming.to_snake_case(prop_name),
      schema_ref: prop_ref,
      required: list.contains(required_fields, prop_name),
    )
  })
}

fn form_urlencoded_body_properties(
  rb: openapi.RequestBody(Resolved),
  ctx: Context,
) -> List(DeepObjectProperty) {
  case dict.get(rb.content, "application/x-www-form-urlencoded") {
    Ok(media_type) -> {
      case media_type.schema {
        Some(schema_ref) -> object_properties_from_schema_ref(schema_ref, ctx)
        None -> []
      }
    }
    // nolint: thrown_away_error -- absence of the content type means no properties to enumerate
    Error(_) -> []
  }
}

fn multipart_body_properties(
  rb: openapi.RequestBody(Resolved),
  ctx: Context,
) -> List(DeepObjectProperty) {
  case dict.get(rb.content, "multipart/form-data") {
    Ok(media_type) ->
      case media_type.schema {
        Some(schema_ref) -> object_properties_from_schema_ref(schema_ref, ctx)
        None -> []
      }
    // nolint: thrown_away_error -- absence of the content type means no properties to enumerate
    Error(_) -> []
  }
}

fn schema_ref_resolves_to_object(schema_ref: SchemaRef, ctx: Context) -> Bool {
  case context.resolve_schema_ref(schema_ref, ctx) {
    Ok(ObjectSchema(..)) -> True
    _ -> False
  }
}

fn schema_ref_additional_properties(
  schema_ref: SchemaRef,
  ctx: Context,
) -> AdditionalProperties {
  case context.resolve_schema_ref(schema_ref, ctx) {
    Ok(ObjectSchema(additional_properties:, ..)) -> additional_properties
    _ -> Forbidden
  }
}

fn body_additional_properties(
  rb: openapi.RequestBody(Resolved),
  content_type: String,
  ctx: Context,
) -> AdditionalProperties {
  case dict.get(rb.content, content_type) {
    Ok(media_type) ->
      case media_type.schema {
        Some(schema_ref) -> schema_ref_additional_properties(schema_ref, ctx)
        None -> Forbidden
      }
    // nolint: thrown_away_error -- absence of the content type means no additionalProperties
    Error(_) -> Forbidden
  }
}

fn form_urlencoded_schema_ref_type_name(schema_ref: SchemaRef) -> String {
  case schema_ref {
    Reference(name:, ..) -> "types." <> naming.schema_to_type_name(name)
    Inline(_) -> "String"
  }
}

fn form_urlencoded_body_type_name(
  rb: openapi.RequestBody(Resolved),
  op_id: String,
) -> String {
  case dict.get(rb.content, "application/x-www-form-urlencoded") {
    Ok(media_type) ->
      case media_type.schema {
        Some(Reference(name:, ..)) ->
          "types." <> naming.schema_to_type_name(name)
        Some(Inline(ObjectSchema(..))) ->
          "types." <> naming.schema_to_type_name(op_id) <> "Request"
        Some(Inline(openapi.StringSchema(..)))
        | Some(Inline(openapi.IntegerSchema(..)))
        | Some(Inline(openapi.NumberSchema(..)))
        | Some(Inline(openapi.BooleanSchema(..)))
        | Some(Inline(openapi.ArraySchema(..)))
        | Some(Inline(openapi.AllOfSchema(..)))
        | Some(Inline(openapi.OneOfSchema(..)))
        | Some(Inline(openapi.AnyOfSchema(..)))
        | None -> "String"
      }
    // nolint: thrown_away_error -- absence of the content type falls back to the raw body type
    Error(_) -> "String"
  }
}

fn multipart_body_type_name(
  rb: openapi.RequestBody(Resolved),
  op_id: String,
) -> String {
  case dict.get(rb.content, "multipart/form-data") {
    Ok(media_type) ->
      case media_type.schema {
        Some(Reference(name:, ..)) ->
          "types." <> naming.schema_to_type_name(name)
        Some(Inline(ObjectSchema(..))) ->
          "types." <> naming.schema_to_type_name(op_id) <> "Request"
        Some(Inline(openapi.StringSchema(..)))
        | Some(Inline(openapi.IntegerSchema(..)))
        | Some(Inline(openapi.NumberSchema(..)))
        | Some(Inline(openapi.BooleanSchema(..)))
        | Some(Inline(openapi.ArraySchema(..)))
        | Some(Inline(openapi.AllOfSchema(..)))
        | Some(Inline(openapi.OneOfSchema(..)))
        | Some(Inline(openapi.AnyOfSchema(..)))
        | None -> "String"
      }
    // nolint: thrown_away_error -- absence of the content type falls back to the raw body type
    Error(_) -> "String"
  }
}

fn form_urlencoded_key(prefix: String, name: String) -> String {
  case prefix {
    "" -> name
    _ -> prefix <> "[" <> name <> "]"
  }
}

fn form_urlencoded_object_constructor_expr(
  type_name: String,
  prefix: String,
  properties: List(DeepObjectProperty),
  additional_properties: AdditionalProperties,
  ctx: Context,
  nesting_depth: Int,
) -> String {
  form_urlencoded_object_parts(
    type_name,
    prefix,
    properties,
    additional_properties,
    ctx,
    nesting_depth,
  ).1
}

/// Expression of type `Result(T, Nil)` that builds the form object at
/// `prefix`; `Error(Nil)` when a required field, at any nesting level,
/// is missing or does not parse.
fn form_urlencoded_object_result_expr(
  type_name: String,
  prefix: String,
  properties: List(DeepObjectProperty),
  additional_properties: AdditionalProperties,
  ctx: Context,
  nesting_depth: Int,
) -> String {
  let #(cases, constructor) =
    form_urlencoded_object_parts(
      type_name,
      prefix,
      properties,
      additional_properties,
      ctx,
      nesting_depth,
    )
  checked_constructor(cases, constructor)
}

/// True when a field of the form object, at any nesting level, must be
/// checked: a primitive field for which `field_needs_check` holds, or a
/// nested object that has one.
fn form_urlencoded_properties_need_check(
  properties: List(DeepObjectProperty),
  ctx: Context,
  nesting_depth: Int,
) -> Bool {
  list.any(properties, fn(prop) {
    case
      nesting_depth < 5 && schema_ref_resolves_to_object(prop.schema_ref, ctx)
    {
      True ->
        form_urlencoded_properties_need_check(
          object_properties_from_schema_ref(prop.schema_ref, ctx),
          ctx,
          nesting_depth + 1,
        )
      False -> field_needs_check(prop.required, prop.schema_ref, ctx)
    }
  })
}

/// The record constructor of a form object and the nested cases that bind
/// every field that must be checked (see
/// `form_urlencoded_properties_need_check`). The other fields are looked
/// up inline. An object without a field to check has no cases, so its
/// constructor can be used on its own.
fn form_urlencoded_object_parts(
  type_name: String,
  prefix: String,
  properties: List(DeepObjectProperty),
  additional_properties: AdditionalProperties,
  ctx: Context,
  nesting_depth: Int,
) -> #(List(#(String, String)), String) {
  let entries =
    list.map(properties, fn(prop) {
      form_urlencoded_field_parts(prefix, prop, ctx, nesting_depth)
    })
  let fields = entries |> list.map(fn(e) { e.1 }) |> string.join(", ")
  let additional_props_suffix = case additional_properties {
    // Forbidden and Unspecified both mean the generated record has no
    // additional_properties field.
    Forbidden | Unspecified -> ""
    Typed(_) | Untyped -> ", additional_properties: dict.new()"
  }
  #(
    list.flat_map(entries, fn(e) { e.0 }),
    type_name <> "(" <> fields <> additional_props_suffix <> ")",
  )
}

/// One field of a form object: the cases that bind it when it must be
/// checked, and its `field: value` text.
fn form_urlencoded_field_parts(
  prefix: String,
  prop: DeepObjectProperty,
  ctx: Context,
  nesting_depth: Int,
) -> #(List(#(String, String)), String) {
  let key = form_urlencoded_key(prefix, prop.name)
  let binding = "body_" <> prop.field_name
  let is_object =
    nesting_depth < 5 && schema_ref_resolves_to_object(prop.schema_ref, ctx)
  let nested_props = case is_object {
    True -> object_properties_from_schema_ref(prop.schema_ref, ctx)
    False -> []
  }
  let nested_checked =
    is_object
    && form_urlencoded_properties_need_check(
      nested_props,
      ctx,
      nesting_depth + 1,
    )
  case
    nested_checked,
    !is_object && field_needs_check(prop.required, prop.schema_ref, ctx)
  {
    True, _ -> {
      let nested =
        form_urlencoded_object_result_expr(
          form_urlencoded_schema_ref_type_name(prop.schema_ref),
          key,
          nested_props,
          schema_ref_additional_properties(prop.schema_ref, ctx),
          ctx,
          nesting_depth + 1,
        )
      let result_expr = case prop.required {
        True -> nested
        False ->
          "case "
          <> form_object_presence_check(key, prop.schema_ref, ctx)
          <> " { True -> case "
          <> nested
          <> " { Ok(value) -> Ok(Some(value)) _ -> Error(Nil) } False -> Ok(None) }"
      }
      #(
        [
          #(
            "case " <> result_expr <> " { Ok(" <> binding <> ") -> ",
            " _ -> Error(Nil) }",
          ),
        ],
        prop.field_name <> ": " <> binding,
      )
    }
    False, True -> #(
      [
        checked_field_case(
          key,
          "form_body",
          True,
          binding,
          prop.required,
          prop.schema_ref,
          ctx,
        ),
      ],
      prop.field_name <> ": " <> binding,
    )
    False, False -> {
      // Reached only for a nested object without a field to check or an
      // optional primitive field that is not a Bool.
      let value_expr = case is_object, prop.required {
        True, True ->
          form_urlencoded_object_required_expr(
            key,
            prop.schema_ref,
            ctx,
            nesting_depth + 1,
          )
        True, False ->
          form_urlencoded_object_optional_expr(
            key,
            prop.schema_ref,
            ctx,
            nesting_depth + 1,
          )
        False, _ ->
          form_body_optional_expr_with_schema(key, Some(prop.schema_ref), ctx)
      }
      #([], prop.field_name <> ": " <> value_expr)
    }
  }
}

fn form_object_presence_check(
  prefix: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> String {
  let prop_names =
    object_properties_from_schema_ref(schema_ref, ctx)
    |> list.map(fn(prop) { "\"" <> prop.name <> "\"" })
    |> string.join(", ")
  "form_object_present(form_body, \"" <> prefix <> "\", [" <> prop_names <> "])"
}

fn form_urlencoded_object_required_expr(
  prefix: String,
  schema_ref: SchemaRef,
  ctx: Context,
  nesting_depth: Int,
) -> String {
  form_urlencoded_object_constructor_expr(
    form_urlencoded_schema_ref_type_name(schema_ref),
    prefix,
    object_properties_from_schema_ref(schema_ref, ctx),
    schema_ref_additional_properties(schema_ref, ctx),
    ctx,
    nesting_depth,
  )
}

fn form_urlencoded_object_optional_expr(
  prefix: String,
  schema_ref: SchemaRef,
  ctx: Context,
  nesting_depth: Int,
) -> String {
  let props = object_properties_from_schema_ref(schema_ref, ctx)
  "case "
  <> form_object_presence_check(prefix, schema_ref, ctx)
  <> " { True -> Some("
  <> form_urlencoded_object_constructor_expr(
    form_urlencoded_schema_ref_type_name(schema_ref),
    prefix,
    props,
    schema_ref_additional_properties(schema_ref, ctx),
    ctx,
    nesting_depth,
  )
  <> ") False -> None }"
}

fn form_urlencoded_body_constructor_expr(
  rb: openapi.RequestBody(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  form_urlencoded_object_constructor_expr(
    form_urlencoded_body_type_name(rb, op_id),
    "",
    form_urlencoded_body_properties(rb, ctx),
    body_additional_properties(rb, "application/x-www-form-urlencoded", ctx),
    ctx,
    0,
  )
}

pub fn form_urlencoded_body_has_optional_fields(
  rb: openapi.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  form_urlencoded_properties_have_optional_fields(
    form_urlencoded_body_properties(rb, ctx),
    ctx,
    True,
  )
}

pub fn form_urlencoded_body_needs_string(
  rb: openapi.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  form_urlencoded_properties_need_string(
    form_urlencoded_body_properties(rb, ctx),
    ctx,
    True,
  )
}

pub fn form_urlencoded_body_needs_int(
  rb: openapi.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  form_urlencoded_properties_need_int(
    form_urlencoded_body_properties(rb, ctx),
    ctx,
    True,
  )
}

pub fn form_urlencoded_body_needs_float(
  rb: openapi.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  form_urlencoded_properties_need_float(
    form_urlencoded_body_properties(rb, ctx),
    ctx,
    True,
  )
}

pub fn form_urlencoded_body_has_nested_object(
  rb: openapi.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  list.any(form_urlencoded_body_properties(rb, ctx), fn(prop) {
    schema_ref_resolves_to_object(prop.schema_ref, ctx)
  })
}

fn multipart_body_constructor_expr(
  rb: openapi.RequestBody(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  multipart_body_parts(rb, op_id, ctx).1
}

/// The record constructor of a multipart body and the nested cases that
/// bind every field that must be checked (see `field_needs_check`). A body
/// without such a field has no cases, so its constructor can be used on
/// its own.
fn multipart_body_parts(
  rb: openapi.RequestBody(Resolved),
  op_id: String,
  ctx: Context,
) -> #(List(#(String, String)), String) {
  let entries =
    multipart_body_properties(rb, ctx)
    |> list.map(fn(prop) {
      let binding = "body_" <> prop.field_name
      case field_needs_check(prop.required, prop.schema_ref, ctx) {
        True -> #(
          [
            checked_field_case(
              prop.name,
              "multipart_body",
              False,
              binding,
              prop.required,
              prop.schema_ref,
              ctx,
            ),
          ],
          prop.field_name <> ": " <> binding,
        )
        False -> #(
          [],
          prop.field_name
            <> ": "
            <> multipart_body_optional_expr_with_schema(
            prop.name,
            Some(prop.schema_ref),
            ctx,
          ),
        )
      }
    })
  let fields = entries |> list.map(fn(e) { e.1 }) |> string.join(", ")
  let additional_props_suffix = case
    body_additional_properties(rb, "multipart/form-data", ctx)
  {
    // Forbidden and Unspecified both mean the generated record has no
    // additional_properties field.
    Forbidden | Unspecified -> ""
    Typed(_) | Untyped -> ", additional_properties: dict.new()"
  }
  #(
    list.flat_map(entries, fn(e) { e.0 }),
    multipart_body_type_name(rb, op_id)
      <> "("
      <> fields
      <> additional_props_suffix
      <> ")",
  )
}

/// For a form-urlencoded or multipart body with a field that must be
/// checked, an expression of type `Result(T, Nil)` (`Result(Option(T), Nil)`
/// for an optional body) that builds the body record. The router binds it
/// and answers 400 on `Error`. `None` for every other body.
pub fn checked_body_result_expr(
  rb: openapi.RequestBody(Resolved),
  op_id: String,
  ctx: Context,
) -> Option(String) {
  let result = case dict.to_list(rb.content) {
    [#(ct_name, _)] ->
      case content_type.from_string(ct_name) {
        content_type.FormUrlEncoded -> {
          let properties = form_urlencoded_body_properties(rb, ctx)
          case form_urlencoded_properties_need_check(properties, ctx, 0) {
            True ->
              Some(form_urlencoded_object_result_expr(
                form_urlencoded_body_type_name(rb, op_id),
                "",
                properties,
                body_additional_properties(
                  rb,
                  "application/x-www-form-urlencoded",
                  ctx,
                ),
                ctx,
                0,
              ))
            False -> None
          }
        }
        content_type.MultipartFormData ->
          case
            list.any(multipart_body_properties(rb, ctx), fn(prop) {
              field_needs_check(prop.required, prop.schema_ref, ctx)
            })
          {
            True -> {
              let #(cases, constructor) = multipart_body_parts(rb, op_id, ctx)
              Some(checked_constructor(cases, constructor))
            }
            False -> None
          }
        content_type.ApplicationJson
        | content_type.TextPlain
        | content_type.ApplicationOctetStream
        | content_type.ApplicationXml
        | content_type.TextXml
        | content_type.Wildcard
        | content_type.UnsupportedContentType(_) -> None
      }
    _ -> None
  }
  use result <- option.map(result)
  case rb.required {
    True -> result
    False ->
      "case body { \"\" -> Ok(None) _ -> case "
      <> result
      <> " { Ok(value) -> Ok(Some(value)) _ -> Error(Nil) } }"
  }
}

pub fn multipart_body_has_optional_fields(
  rb: openapi.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  list.any(multipart_body_properties(rb, ctx), fn(prop) { !prop.required })
}

pub fn multipart_body_needs_int(
  rb: openapi.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  list.any(multipart_body_properties(rb, ctx), fn(prop) {
    body_field_kind_needs_int(schema_ref_body_field_kind(
      Some(prop.schema_ref),
      ctx,
    ))
  })
}

pub fn multipart_body_needs_float(
  rb: openapi.RequestBody(Resolved),
  ctx: Context,
) -> Bool {
  list.any(multipart_body_properties(rb, ctx), fn(prop) {
    body_field_kind_needs_float(schema_ref_body_field_kind(
      Some(prop.schema_ref),
      ctx,
    ))
  })
}

fn form_urlencoded_properties_have_optional_fields(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
) -> Bool {
  list.any(props, fn(prop) {
    !prop.required
    || case
      allow_nested_objects
      && schema_ref_resolves_to_object(prop.schema_ref, ctx)
    {
      True ->
        form_urlencoded_properties_have_optional_fields(
          object_properties_from_schema_ref(prop.schema_ref, ctx),
          ctx,
          False,
        )
      False -> False
    }
  })
}

fn form_urlencoded_properties_need_string(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
) -> Bool {
  form_urlencoded_properties_need(props, ctx, allow_nested_objects, fn(prop) {
    query_schema_needs_string(Some(prop.schema_ref))
  })
}

fn form_urlencoded_properties_need_int(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
) -> Bool {
  form_urlencoded_properties_need(props, ctx, allow_nested_objects, fn(prop) {
    body_field_kind_needs_int(schema_ref_body_field_kind(
      Some(prop.schema_ref),
      ctx,
    ))
  })
}

fn form_urlencoded_properties_need_float(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
) -> Bool {
  form_urlencoded_properties_need(props, ctx, allow_nested_objects, fn(prop) {
    body_field_kind_needs_float(schema_ref_body_field_kind(
      Some(prop.schema_ref),
      ctx,
    ))
  })
}

fn form_urlencoded_properties_need(
  props: List(DeepObjectProperty),
  ctx: Context,
  allow_nested_objects: Bool,
  predicate: fn(DeepObjectProperty) -> Bool,
) -> Bool {
  list.any(props, fn(prop) {
    predicate(prop)
    || case
      allow_nested_objects
      && schema_ref_resolves_to_object(prop.schema_ref, ctx)
    {
      True ->
        form_urlencoded_properties_need(
          object_properties_from_schema_ref(prop.schema_ref, ctx),
          ctx,
          False,
          predicate,
        )
      False -> False
    }
  })
}

pub fn query_schema_needs_string(schema_ref: Option(SchemaRef)) -> Bool {
  case schema_ref {
    Some(Inline(openapi.ArraySchema(..))) -> True
    _ -> False
  }
}

pub fn query_schema_needs_int(
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> Bool {
  case schema_ref {
    Some(Inline(openapi.IntegerSchema(..))) -> True
    Some(Inline(openapi.ArraySchema(
      items: Inline(openapi.IntegerSchema(..)),
      ..,
    ))) -> True
    // A `$ref` whose target is `type: integer` triggers
    // `int.parse` emission downstream, so the router needs the
    // `gleam/int` import too.
    Some(Reference(..) as ref) ->
      case schema_ref_scalar_kind(ref, ctx) {
        Some(IntegerScalar) -> True
        _ -> False
      }
    _ -> False
  }
}

pub fn query_schema_needs_float(
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> Bool {
  case schema_ref {
    Some(Inline(openapi.NumberSchema(..))) -> True
    Some(Inline(openapi.ArraySchema(items: Inline(openapi.NumberSchema(..)), ..))) ->
      True
    Some(Reference(..) as ref) ->
      case schema_ref_scalar_kind(ref, ctx) {
        Some(NumberScalar) -> True
        _ -> False
      }
    _ -> False
  }
}

fn form_body_optional_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  body_optional_expr(key, "form_body", True, "_", schema_ref, ctx)
}

fn multipart_body_optional_expr_with_schema(
  key: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  body_optional_expr(key, "multipart_body", False, "_", schema_ref, ctx)
}

/// Inline string-enum dispatch for an optional form/multipart body
/// field. Unknown values map to `None`, matching the
/// permissive behaviour already used for `$ref`-typed enum query
/// parameters.
fn body_optional_enum_expr(
  lookup: String,
  miss: String,
  type_name: String,
  values: List(String),
) -> String {
  "case "
  <> lookup
  <> " { Ok([v, ..]) -> "
  <> enum_match_option_expr("v", type_name, values)
  <> " "
  <> miss
  <> " -> None }"
}

/// Generate an optional body field expression.
/// `source` is the dict name, `miss` is the miss pattern ("_" or "Error(_)").
fn body_optional_expr(
  key: String,
  source: String,
  trim_items: Bool,
  miss: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  let lookup = "dict.get(" <> source <> ", \"" <> key <> "\")"
  // A `$ref`-typed string-enum
  // field needs string→variant dispatch. Without this branch the field
  // ends up as `Some(v)` where `v: String` clashes with the
  // `Option(types.<EnumName>)` slot.
  case
    schema_ref
    |> option.then(fn(ref) { schema_ref_string_enum(ref, ctx) })
  {
    Some(#(type_name, values)) ->
      body_optional_enum_expr(lookup, miss, type_name, values)
    None -> body_optional_expr_kind(lookup, miss, schema_ref, trim_items, ctx)
  }
}

/// Existing per-`BodyFieldKind` dispatch for `body_optional_expr`,
/// extracted so the enum check above can short-circuit cleanly.
fn body_optional_expr_kind(
  lookup: String,
  miss: String,
  schema_ref: Option(SchemaRef),
  trim_items: Bool,
  ctx: Context,
) -> String {
  case schema_ref_body_field_kind(schema_ref, ctx) {
    BodyFieldStringArray ->
      case trim_items {
        True ->
          "case "
          <> lookup
          <> " { Ok(vs) -> Some(list.map(vs, fn(item) { string.trim(item) })) "
          <> miss
          <> " -> None }"
        False ->
          "case " <> lookup <> " { Ok(vs) -> Some(vs) " <> miss <> " -> None }"
      }
    BodyFieldIntArray ->
      "case "
      <> lookup
      <> " { Ok(vs) -> Some(list.map(vs, fn(item) { "
      <> array_item_int_parse(trim_items)
      <> " })) "
      <> miss
      <> " -> None }"
    BodyFieldFloatArray ->
      "case "
      <> lookup
      <> " { Ok(vs) -> Some(list.map(vs, fn(item) { "
      <> array_item_float_parse(trim_items)
      <> " })) "
      <> miss
      <> " -> None }"
    BodyFieldBoolArray ->
      "case "
      <> lookup
      <> " { Ok(vs) -> Some("
      <> bool_list_filter_expr("vs", trim_items)
      <> ") "
      <> miss
      <> " -> None }"
    BodyFieldInt ->
      "case "
      <> lookup
      <> " { Ok([v, ..]) -> { case int.parse(v) { Ok(n) -> Some(n) _ -> None } } "
      <> miss
      <> " -> None }"
    BodyFieldFloat ->
      "case "
      <> lookup
      <> " { Ok([v, ..]) -> { case float.parse(v) { Ok(n) -> Some(n) _ -> None } } "
      <> miss
      <> " -> None }"
    BodyFieldBool ->
      "case "
      <> lookup
      <> " { Ok([v, ..]) -> "
      <> bool_option_expr("v")
      <> " "
      <> miss
      <> " -> None }"
    _ ->
      "case " <> lookup <> " { Ok([v, ..]) -> Some(v) " <> miss <> " -> None }"
  }
}

/// Parse expression for array items: int, with optional trimming.
/// Uses a case expression instead of `let assert` to avoid panicking on
/// malformed input — bad values fall back to 0.
fn array_item_int_parse(trim: Bool) -> String {
  use <- bool.guard(!trim, "case int.parse(item) { Ok(n) -> n _ -> 0 }")
  "let trimmed = string.trim(item) case int.parse(trimmed) { Ok(n) -> n _ -> 0 }"
}

/// Parse expression for array items: float, with optional trimming.
/// Uses a case expression instead of `let assert` to avoid panicking on
/// malformed input — bad values fall back to 0.0.
fn array_item_float_parse(trim: Bool) -> String {
  use <- bool.guard(!trim, "case float.parse(item) { Ok(n) -> n _ -> 0.0 }")
  "let trimmed = string.trim(item) case float.parse(trimmed) { Ok(n) -> n _ -> 0.0 }"
}

/// Generate expression for a required header parameter.
///
/// `bound_var` is the raw header String the router has already pulled
/// out of the headers dict in an enclosing `case dict.get(...) { Ok(<var>) ->`.
/// The router additionally opens a numeric parse case for int/float scalar
/// params, binding `<bound_var>_parsed` on success.
pub fn header_required_expr(
  bound_var: String,
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> String {
  single_value_required_expr(bound_var, spec.parameter_schema(param), ctx)
}

/// Generate expression for an optional header parameter.
pub fn header_optional_expr(
  key: String,
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> String {
  let lookup = "dict.get(headers, \"" <> key <> "\")"
  single_value_optional_expr(
    lookup,
    "v",
    "_",
    spec.parameter_schema(param),
    ctx,
  )
}

/// Generate expression for a required cookie parameter.
///
/// `bound_var` is the raw cookie String the router has already pulled out
/// via `case cookie_lookup(...) { Ok(<var>) ->`. As with the header helper
/// the router pre-binds `<bound_var>_parsed` for numeric scalar types.
pub fn cookie_required_expr(
  bound_var: String,
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> String {
  single_value_required_expr(bound_var, spec.parameter_schema(param), ctx)
}

/// Generate expression for an optional cookie parameter.
pub fn cookie_optional_expr(
  key: String,
  param: openapi.Parameter(Resolved),
  ctx: Context,
) -> String {
  let lookup = "cookie_lookup(headers, \"" <> key <> "\")"
  single_value_optional_expr(
    lookup,
    "v",
    "Error(_)",
    spec.parameter_schema(param),
    ctx,
  )
}

/// Generate a required value expression for a source that returns a single
/// String value. Used for headers (dict.get returns single string) and
/// cookies. Header / cookie arrays are comma-separated in a single string.
///
/// The lookup itself (and any int/float parse) is wrapped in an enclosing
/// case in the router, which binds `bound_var` (and `<bound_var>_parsed`
/// for numeric scalars). This helper just produces the value expression
/// that consumes those bound names — it never emits `let assert`.
fn single_value_required_expr(
  bound_var: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  // The router parses a Bool parameter in its own case and binds the
  // result (see `single_value_required_open_parse_case` in server.gleam).
  use <- bool.lazy_guard(bool_shape(schema_ref, ctx) == Some(BoolScalar), fn() {
    bound_var <> "_parsed"
  })
  use <- bool.lazy_guard(bool_shape(schema_ref, ctx) == Some(BoolList), fn() {
    bound_var <> "_parsed_list"
  })
  // Likewise a `$ref` enum and an array of enum items.
  use <- bool.lazy_guard(
    option.is_some(enum_array_items(schema_ref, ctx)),
    fn() { bound_var <> "_parsed_list" },
  )
  use <- bool.lazy_guard(
    option.is_some(option.then(schema_ref, schema_ref_string_enum(_, ctx))),
    fn() { bound_var <> "_parsed" },
  )
  case schema_ref {
    Some(Inline(openapi.ArraySchema(items: Inline(openapi.StringSchema(..)), ..))) ->
      "list.map(string.split("
      <> bound_var
      <> ", \",\"), fn(item) { string.trim(item) })"
    Some(Inline(openapi.ArraySchema(
      items: Inline(openapi.IntegerSchema(..)),
      ..,
    ))) ->
      // Router pre-parses to a List(Int) and binds <bound_var>_parsed_list.
      bound_var <> "_parsed_list"
    Some(Inline(openapi.ArraySchema(items: Inline(openapi.NumberSchema(..)), ..))) ->
      bound_var <> "_parsed_list"
    Some(Inline(openapi.IntegerSchema(..))) -> bound_var <> "_parsed"
    Some(Inline(openapi.NumberSchema(..))) -> bound_var <> "_parsed"
    _ -> bound_var
  }
}

/// Generate an optional expression for a source that returns a single value.
fn single_value_optional_expr(
  lookup: String,
  var: String,
  miss: String,
  schema_ref: Option(SchemaRef),
  ctx: Context,
) -> String {
  // A `$ref` string enum reads an unknown value as `None`, as an optional
  // enum query parameter does.
  case option.then(schema_ref, schema_ref_string_enum(_, ctx)) {
    Some(#(type_name, values)) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> "
      <> enum_match_option_expr(var, type_name, values)
      <> " "
      <> miss
      <> " -> None }"
    None -> single_value_optional_primitive_expr(lookup, var, miss, schema_ref)
  }
}

fn single_value_optional_primitive_expr(
  lookup: String,
  var: String,
  miss: String,
  schema_ref: Option(SchemaRef),
) -> String {
  case schema_ref {
    Some(Inline(openapi.ArraySchema(items: Inline(openapi.StringSchema(..)), ..))) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> Some(list.map(string.split("
      <> var
      <> ", \",\"), fn(item) { string.trim(item) })) "
      <> miss
      <> " -> None }"
    Some(Inline(openapi.ArraySchema(
      items: Inline(openapi.IntegerSchema(..)),
      ..,
    ))) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> Some(list.map(string.split("
      <> var
      <> ", \",\"), fn(item) { "
      <> array_item_int_parse(True)
      <> " })) "
      <> miss
      <> " -> None }"
    Some(Inline(openapi.ArraySchema(items: Inline(openapi.NumberSchema(..)), ..))) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> Some(list.map(string.split("
      <> var
      <> ", \",\"), fn(item) { "
      <> array_item_float_parse(True)
      <> " })) "
      <> miss
      <> " -> None }"
    Some(Inline(openapi.ArraySchema(
      items: Inline(openapi.BooleanSchema(..)),
      ..,
    ))) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> Some("
      <> bool_list_filter_expr("string.split(" <> var <> ", \",\")", True)
      <> ") "
      <> miss
      <> " -> None }"
    Some(Inline(openapi.IntegerSchema(..))) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> { case int.parse("
      <> var
      <> ") { Ok(n) -> Some(n) _ -> None } } "
      <> miss
      <> " -> None }"
    Some(Inline(openapi.NumberSchema(..))) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> { case float.parse("
      <> var
      <> ") { Ok(n) -> Some(n) _ -> None } } "
      <> miss
      <> " -> None }"
    Some(Inline(openapi.BooleanSchema(..))) ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> "
      <> bool_option_expr(var)
      <> " "
      <> miss
      <> " -> None }"
    _ ->
      "case "
      <> lookup
      <> " { Ok("
      <> var
      <> ") -> Some("
      <> var
      <> ") "
      <> miss
      <> " -> None }"
  }
}

/// Generate the body decode expression for a request body.
pub fn generate_body_decode_expr(
  rb: openapi.RequestBody(Resolved),
  op_id: String,
  ctx: Context,
) -> String {
  let content_entries = dict.to_list(rb.content)
  case content_entries {
    [#(ct_name, media_type)] ->
      case content_type.from_string(ct_name) {
        content_type.ApplicationJson -> {
          let decode_fn = case media_type.schema {
            Some(Reference(name:, ..)) ->
              "decode.decode_" <> naming.to_snake_case(name) <> "(body)"
            _ ->
              "decode.decode_"
              <> naming.to_snake_case(op_id)
              <> "_request_body(body)"
          }
          // The router decodes a required JSON body into `decoded_body`
          // before it builds the request.
          case rb.required {
            True -> "decoded_body"
            False ->
              "case body { \"\" -> None _ -> { case "
              <> decode_fn
              <> " { Ok(decoded) -> Some(decoded) _ -> None } } }"
          }
        }
        content_type.FormUrlEncoded -> {
          let body_expr = form_urlencoded_body_constructor_expr(rb, op_id, ctx)
          case rb.required {
            True -> body_expr
            False -> "case body { \"\" -> None _ -> Some(" <> body_expr <> ") }"
          }
        }
        content_type.MultipartFormData -> {
          let body_expr = multipart_body_constructor_expr(rb, op_id, ctx)
          case rb.required {
            True -> body_expr
            False -> "case body { \"\" -> None _ -> Some(" <> body_expr <> ") }"
          }
        }
        _ -> {
          case rb.required {
            True -> "body"
            False -> "case body { \"\" -> None _ -> Some(body) }"
          }
        }
      }
    _ -> {
      case rb.required {
        True -> "body"
        False -> "case body { \"\" -> None _ -> Some(body) }"
      }
    }
  }
}
