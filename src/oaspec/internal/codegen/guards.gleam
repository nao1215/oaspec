import gleam/bool
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/set.{type Set}
import gleam/string
import oaspec/config
import oaspec/internal/codegen/allof_merge
import oaspec/internal/codegen/codec_helpers
import oaspec/internal/codegen/context.{
  type Context, type GeneratedFile, GeneratedFile,
}
import oaspec/internal/codegen/ir_build
import oaspec/internal/codegen/schema_dispatch
import oaspec/internal/codegen/schema_utils
import oaspec/internal/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, ArraySchema, Inline,
  IntegerSchema, NumberSchema, ObjectSchema, Reference, StringSchema, Typed,
  Untyped,
}
import oaspec/internal/util/naming
import oaspec/internal/util/string_extra as se

pub type GuardFunctionKind {
  FieldValidator
  DelegatingFieldValidator(canonical_name: String)
  CompositeValidator
}

pub type GuardFunction {
  GuardFunction(
    name: String,
    docs: List(String),
    param_decl: String,
    return_type: String,
    body: String,
    kind: GuardFunctionKind,
  )
}

pub type GuardModule {
  GuardModule(imports: List(String), functions: List(GuardFunction))
}

/// Check whether a named component schema has a composite validator.
/// Used by server/client generators to decide whether to emit guard calls.
pub fn schema_has_validator(name: String, ctx: Context) -> Bool {
  schema_has_validator_visiting(name, ctx, [])
}

/// Cycle-aware variant. `visiting` is the stack of schema names whose
/// `schema_has_validator` evaluation is currently in flight. When a
/// nested-record check would recurse back into one of them (e.g. a
/// recursive `Comment` schema whose `replies` is `array<Comment>`, or
/// mutually-recursive `User` ↔ `Link`), we short-circuit the loop by
/// returning `False` for that arm — the schema can still earn a
/// validator through other (non-cyclic) constraints.
fn schema_has_validator_visiting(
  name: String,
  ctx: Context,
  visiting: List(String),
) -> Bool {
  use <- bool.guard(when: list.contains(visiting, name), return: False)
  case context.spec(ctx).components {
    Some(components) ->
      case dict.get(components.schemas, name) {
        Ok(schema_ref) ->
          !ir_build.is_internal_schema(schema_ref)
          && !list.is_empty(
            collect_guard_calls_visiting(name, schema_ref, ctx, [
              name,
              ..visiting
            ]),
          )
        // nolint: thrown_away_error -- unknown schema name simply has no validator
        Error(_) -> False
      }
    None -> False
  }
}

/// Generate guard/validation functions from OpenAPI schemas that have constraints.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let module = build_module(ctx)
  case list.is_empty(module.functions) {
    True -> []
    False -> [
      GeneratedFile(
        path: "guards.gleam",
        content: render_module(module),
        target: context.SharedTarget,
        write_mode: context.Overwrite,
      ),
    ]
  }
}

/// Build the structured guard module before rendering.
pub fn build_module(ctx: Context) -> GuardModule {
  let schemas = case context.spec(ctx).components {
    Some(components) ->
      list.sort(dict.to_list(components.schemas), fn(a, b) {
        string.compare(a.0, b.0)
      })
      |> list.filter(fn(entry) { !ir_build.is_internal_schema(entry.1) })
    None -> []
  }

  // Determine which imports are needed based on constraint types present.
  // Generated guard functions use string/list.length for validation;
  // constraint values (min/max) are baked as literals at generation time,
  // so gleam/int and gleam/float are NOT needed in the generated output.
  // gleam/json is always imported because the ValidationFailure encoder
  // emitted below uses it.
  let constraint_types = collect_constraint_types(schemas, ctx)
  let imports = ["gleam/json"]
  let imports = case constraint_types.has_string {
    True -> ["gleam/string", ..imports]
    False -> imports
  }
  let imports = case constraint_types.has_regexp {
    True -> ["gleam/regexp", ..imports]
    False -> imports
  }
  let imports = case constraint_types.has_list {
    True -> ["gleam/list", ..imports]
    False -> imports
  }
  let imports = case constraint_types.has_dict {
    True -> ["gleam/dict.{type Dict}", ..imports]
    False -> imports
  }
  let imports = case constraint_types.has_float_multiple_of {
    True -> ["gleam/int", "gleam/float", ..imports]
    False -> imports
  }
  // Import types module when composite validators reference named types
  let needs_types =
    list.any(schemas, fn(entry) {
      let #(name, schema_ref) = entry
      let guard_calls = collect_guard_calls(name, schema_ref, ctx)
      case list.is_empty(guard_calls) {
        True -> False
        False -> {
          let resolved = context.resolve_schema_ref(schema_ref, ctx)
          case resolved {
            Ok(ObjectSchema(..)) | Ok(AllOfSchema(..)) -> True
            _ -> False
          }
        }
      }
    })
  let imports = case needs_types {
    True -> [config.package(context.config(ctx)) <> "/types", ..imports]
    False -> imports
  }
  // Import option module when composite validators handle optional fields
  let needs_option =
    list.any(schemas, fn(entry) {
      let #(name, schema_ref) = entry
      let guard_calls = collect_guard_calls(name, schema_ref, ctx)
      list.any(guard_calls, fn(call) {
        let #(_, _, is_required, _, _) = call
        !is_required
      })
    })
  // Issue #537: a composite validator whose schema (or whose nullable
  // referenced primitive field) renders as `Option(...)` in the
  // generated signature needs the bare `Option` type in scope. Detect
  // that separately from `needs_option` (which only covers
  // `option.Some` / `option.None` pattern matching for optional
  // fields). Importing `{type Option}` unconditionally would trip
  // `Unused imported type` on specs that exercise optional fields
  // but never produce `Option(...)` in a signature.
  let needs_option_type =
    list.any(schemas, fn(entry) {
      let #(name, schema_ref) = entry
      string.contains(
        composite_validator_type(name, schema_ref, ctx),
        "Option(",
      )
    })
  let imports = case needs_option, needs_option_type {
    True, True -> ["gleam/option.{type Option}", ..imports]
    True, False -> ["gleam/option", ..imports]
    False, _ -> imports
  }

  // Issue #520: nested-composite and composite-list emissions use
  // `list.append`/`list.reverse`/`list.fold` to merge inner failures
  // into the outer accumulator, so `gleam/list` becomes mandatory
  // whenever any schema has a Composite or CompositeList call —
  // independent of the existing `has_list` (which tracks array-length
  // constraints).
  let needs_list_for_composites =
    list.any(schemas, fn(entry) {
      let #(name, schema_ref) = entry
      let guard_calls = collect_guard_calls(name, schema_ref, ctx)
      list.any(guard_calls, fn(call) {
        let #(_, _, _, kind, _) = call
        case kind {
          Composite | CompositeList -> True
          Direct -> False
        }
      })
    })
  let imports = case needs_list_for_composites && !constraint_types.has_list {
    True -> ["gleam/list", ..imports]
    False -> imports
  }

  let field_validators =
    list.flat_map(schemas, fn(entry) {
      let #(name, schema_ref) = entry
      collect_guard_functions_for_schema(name, schema_ref, ctx)
    })
    |> dedupe_guard_functions()

  let composite_validators =
    list.flat_map(schemas, fn(entry) {
      let #(name, schema_ref) = entry
      maybe_one(build_composite_guard_function(name, schema_ref, ctx))
    })

  GuardModule(
    imports: imports,
    functions: list.append(field_validators, composite_validators),
  )
}

/// Render the structured guard module to Gleam source.
fn render_module(module: GuardModule) -> String {
  let sb =
    se.file_header(context.version)
    |> se.imports(module.imports)
    |> emit_validation_failure_type()

  list.fold(module.functions, sb, render_guard_function)
  |> se.to_string()
}

fn render_guard_function(
  sb: se.StringBuilder,
  function: GuardFunction,
) -> se.StringBuilder {
  let sb =
    list.fold(function.docs, sb, fn(sb, doc) { sb |> se.line("/// " <> doc) })
  let sb =
    sb
    |> se.line(
      "pub fn "
      <> function.name
      <> "("
      <> function.param_decl
      <> ") -> "
      <> function.return_type
      <> " {",
    )
  let sb =
    function.body
    |> string.split(on: "\n")
    |> list.fold(sb, fn(sb, line) { sb |> se.line(line) })
  sb
  |> se.line("}")
  |> se.blank_line()
}

fn dedupe_guard_functions(functions: List(GuardFunction)) -> List(GuardFunction) {
  let canonical_by_key =
    list.fold(functions, dict.new(), fn(acc, function) {
      case function.kind {
        FieldValidator ->
          case dict.get(acc, dedupe_key(function)) {
            Error(Nil) -> dict.insert(acc, dedupe_key(function), function.name)
            Ok(existing) ->
              case string.compare(function.name, existing) {
                order.Lt ->
                  dict.insert(acc, dedupe_key(function), function.name)
                _ -> acc
              }
          }
        _ -> acc
      }
    })

  list.map(functions, fn(function) {
    case function.kind {
      FieldValidator ->
        case dict.get(canonical_by_key, dedupe_key(function)) {
          Ok(canonical_name) ->
            case canonical_name == function.name {
              True -> function
              False -> emit_guard_delegator(function, canonical_name)
            }
          Error(Nil) -> function
        }
      _ -> function
    }
  })
}

fn dedupe_key(function: GuardFunction) -> String {
  function.param_decl <> "->" <> function.return_type <> "{\n" <> function.body
}

fn emit_guard_delegator(
  function: GuardFunction,
  canonical_name: String,
) -> GuardFunction {
  GuardFunction(
    ..function,
    body: "  " <> canonical_name <> "(value)",
    kind: DelegatingFieldValidator(canonical_name),
  )
}

fn collect_guard_functions_for_schema(
  name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> List(GuardFunction) {
  case schema_ref {
    Inline(schema) ->
      collect_guard_functions_for_schema_object(name, schema, ctx)
    Reference(name:, ..) ->
      case context.resolve_schema_ref(schema_ref, ctx) {
        Ok(schema) ->
          collect_guard_functions_for_schema_object(name, schema, ctx)
        _ -> []
      }
  }
}

fn collect_guard_functions_for_schema_object(
  name: String,
  schema: SchemaObject,
  ctx: Context,
) -> List(GuardFunction) {
  case schema {
    ObjectSchema(properties:, min_properties:, max_properties:, ..) ->
      list.append(
        maybe_one(build_properties_count_guard_function(
          name,
          "",
          min_properties,
          max_properties,
        )),
        ir_build.sorted_entries(properties)
          |> list.flat_map(fn(entry) {
            let #(prop_name, prop_ref) = entry
            collect_field_guard_functions(name, prop_name, prop_ref, ctx)
          }),
      )

    AllOfSchema(schemas:, ..) ->
      list.append(
        [],
        ir_build.sorted_entries(
          allof_merge.merge_allof_schemas(schemas, ctx).properties,
        )
          |> list.flat_map(fn(entry) {
            let #(prop_name, prop_ref) = entry
            collect_field_guard_functions(name, prop_name, prop_ref, ctx)
          }),
      )

    StringSchema(min_length:, max_length:, pattern:, ..) ->
      list.flatten([
        maybe_one(build_string_guard_function(name, "", min_length, max_length)),
        maybe_one(build_string_pattern_guard_function(name, "", pattern)),
      ])

    IntegerSchema(
      minimum:,
      maximum:,
      exclusive_minimum:,
      exclusive_maximum:,
      multiple_of:,
      ..,
    ) ->
      list.flatten([
        maybe_one(build_integer_guard_function(name, "", minimum, maximum)),
        maybe_one(build_integer_exclusive_guard_function(
          name,
          "",
          exclusive_minimum,
          exclusive_maximum,
        )),
        maybe_one(build_integer_multiple_of_guard_function(
          name,
          "",
          multiple_of,
        )),
      ])

    NumberSchema(
      minimum:,
      maximum:,
      exclusive_minimum:,
      exclusive_maximum:,
      multiple_of:,
      ..,
    ) ->
      list.flatten([
        maybe_one(build_float_guard_function(name, "", minimum, maximum)),
        maybe_one(build_float_exclusive_guard_function(
          name,
          "",
          exclusive_minimum,
          exclusive_maximum,
        )),
        maybe_one(build_float_multiple_of_guard_function(name, "", multiple_of)),
      ])

    ArraySchema(min_items:, max_items:, unique_items:, ..) ->
      list.flatten([
        maybe_one(build_list_guard_function(name, "", min_items, max_items)),
        maybe_one(build_unique_items_guard_function(name, "", unique_items)),
      ])

    _ -> []
  }
}

fn collect_field_guard_functions(
  schema_name: String,
  prop_name: String,
  prop_ref: SchemaRef,
  ctx: Context,
) -> List(GuardFunction) {
  let resolved = context.resolve_schema_ref(prop_ref, ctx)
  case resolved {
    Ok(StringSchema(min_length:, max_length:, pattern:, ..)) ->
      list.flatten([
        maybe_one(build_string_guard_function(
          schema_name,
          prop_name,
          min_length,
          max_length,
        )),
        maybe_one(build_string_pattern_guard_function(
          schema_name,
          prop_name,
          pattern,
        )),
      ])

    Ok(IntegerSchema(
      minimum:,
      maximum:,
      exclusive_minimum:,
      exclusive_maximum:,
      multiple_of:,
      ..,
    )) ->
      list.flatten([
        maybe_one(build_integer_guard_function(
          schema_name,
          prop_name,
          minimum,
          maximum,
        )),
        maybe_one(build_integer_exclusive_guard_function(
          schema_name,
          prop_name,
          exclusive_minimum,
          exclusive_maximum,
        )),
        maybe_one(build_integer_multiple_of_guard_function(
          schema_name,
          prop_name,
          multiple_of,
        )),
      ])

    Ok(NumberSchema(
      minimum:,
      maximum:,
      exclusive_minimum:,
      exclusive_maximum:,
      multiple_of:,
      ..,
    )) ->
      list.flatten([
        maybe_one(build_float_guard_function(
          schema_name,
          prop_name,
          minimum,
          maximum,
        )),
        maybe_one(build_float_exclusive_guard_function(
          schema_name,
          prop_name,
          exclusive_minimum,
          exclusive_maximum,
        )),
        maybe_one(build_float_multiple_of_guard_function(
          schema_name,
          prop_name,
          multiple_of,
        )),
      ])

    Ok(ArraySchema(min_items:, max_items:, unique_items:, ..)) ->
      list.flatten([
        maybe_one(build_list_guard_function(
          schema_name,
          prop_name,
          min_items,
          max_items,
        )),
        maybe_one(build_unique_items_guard_function(
          schema_name,
          prop_name,
          unique_items,
        )),
      ])

    _ -> []
  }
}

fn maybe_one(value: Option(a)) -> List(a) {
  case value {
    Some(v) -> [v]
    None -> []
  }
}

// ---------------------------------------------------------------------------
// #339: per-field validator de-duplication across allOf children.
// ---------------------------------------------------------------------------

/// Post-process a generated `guards.gleam` source string and collapse
/// per-field validator definitions whose bodies are byte-identical
/// (the case that arises when an allOf parent's constrained property
/// is flattened into multiple children). One canonical definition is
/// kept; the others are rewritten into one-line stubs that forward to
/// the canonical one. The composite validators continue to call the
/// per-field validators by the original names, so call-site code is
/// unchanged.
/// Track which constraint types exist in the schema set.
type ConstraintTypes {
  ConstraintTypes(
    has_string: Bool,
    has_regexp: Bool,
    has_integer: Bool,
    has_float: Bool,
    has_list: Bool,
    has_float_multiple_of: Bool,
    has_dict: Bool,
  )
}

/// Scan all schemas to find which constraint types are present.
fn collect_constraint_types(
  schemas: List(#(String, SchemaRef)),
  ctx: Context,
) -> ConstraintTypes {
  list.fold(
    schemas,
    ConstraintTypes(False, False, False, False, False, False, False),
    fn(acc, entry) {
      let #(_name, schema_ref) = entry
      collect_schema_constraint_types(acc, schema_ref, ctx, set.new())
    },
  )
}

/// Collect constraint types from a single schema ref.
/// Issue #297: `seen` tracks visited $ref names to break circular references.
fn collect_schema_constraint_types(
  acc: ConstraintTypes,
  schema_ref: SchemaRef,
  ctx: Context,
  seen: Set(String),
) -> ConstraintTypes {
  // Short-circuit on circular $ref to prevent infinite recursion.
  case schema_ref {
    Reference(name:, ..) ->
      case set.contains(seen, name) {
        True -> acc
        False ->
          collect_schema_constraint_types_inner(
            acc,
            schema_ref,
            ctx,
            set.insert(seen, name),
          )
      }
    _ -> collect_schema_constraint_types_inner(acc, schema_ref, ctx, seen)
  }
}

fn collect_schema_constraint_types_inner(
  acc: ConstraintTypes,
  schema_ref: SchemaRef,
  ctx: Context,
  seen: Set(String),
) -> ConstraintTypes {
  let schema = context.resolve_schema_ref(schema_ref, ctx)
  case schema {
    Ok(StringSchema(min_length:, max_length:, pattern:, ..)) -> {
      let acc = case min_length, max_length {
        None, None -> acc
        _, _ -> ConstraintTypes(..acc, has_string: True)
      }

      case pattern {
        Some(_) -> ConstraintTypes(..acc, has_regexp: True)
        None -> acc
      }
    }
    Ok(IntegerSchema(minimum: Some(_), ..))
    | Ok(IntegerSchema(maximum: Some(_), ..))
    | Ok(IntegerSchema(exclusive_minimum: Some(_), ..))
    | Ok(IntegerSchema(exclusive_maximum: Some(_), ..))
    | Ok(IntegerSchema(multiple_of: Some(_), ..)) ->
      ConstraintTypes(..acc, has_integer: True)
    // Issue #521: a NumberSchema with both `minimum` and
    // `multipleOf` declared was hitting the range arm first (because
    // pattern arms are tried top-down), which left
    // `has_float_multiple_of` False — the resulting `guards.gleam`
    // emitted `float.truncate` / `int.to_float` calls without the
    // matching `gleam/float` / `gleam/int` imports. Putting the
    // multipleOf arm first ensures both flags fire whenever
    // `multiple_of` is Some, regardless of which other constraints
    // happen to be present.
    Ok(NumberSchema(multiple_of: Some(_), ..)) ->
      ConstraintTypes(..acc, has_float: True, has_float_multiple_of: True)
    Ok(NumberSchema(minimum: Some(_), ..))
    | Ok(NumberSchema(maximum: Some(_), ..))
    | Ok(NumberSchema(exclusive_minimum: Some(_), ..))
    | Ok(NumberSchema(exclusive_maximum: Some(_), ..)) ->
      ConstraintTypes(..acc, has_float: True)
    Ok(ArraySchema(min_items: Some(_), ..))
    | Ok(ArraySchema(max_items: Some(_), ..))
    | Ok(ArraySchema(unique_items: True, ..)) ->
      ConstraintTypes(..acc, has_list: True)
    Ok(ObjectSchema(properties:, min_properties:, max_properties:, ..)) -> {
      let acc = case min_properties, max_properties {
        None, None -> acc
        _, _ -> ConstraintTypes(..acc, has_dict: True)
      }
      dict.to_list(properties)
      |> list.fold(acc, fn(a, prop) {
        let #(_, prop_ref) = prop
        collect_schema_constraint_types(a, prop_ref, ctx, seen)
      })
    }
    Ok(AllOfSchema(schemas:, ..)) ->
      list.fold(schemas, acc, fn(a, s) {
        collect_schema_constraint_types(a, s, ctx, seen)
      })
    _ -> acc
  }
}

/// Build the guard function name from schema name, property name, and constraint type.
fn guard_function_name(
  schema_name: String,
  prop_name: String,
  constraint: String,
) -> String {
  let base = naming.to_snake_case(schema_name)
  case prop_name {
    // Issue #537: append `_root_` so a schema-level validator on a
    // hoisted inline-array component schema (e.g.
    // `IssuesAddIssueFieldValuesRequestIssueFieldValues`, generated
    // when the parent's `issue_field_values: type:array, maxItems`
    // is hoisted) does not collide with the parent's field-level
    // validator on the same constraint kind. Without the infix, both
    // schemas' validators end up with the same `pub fn` name and
    // `gleam build` rejects the module with `Duplicate definition`
    // on the full GitHub OpenAPI. The infix is fixed and chosen to
    // be lexically distinct from any plausible property name.
    "" -> "validate_" <> base <> "_root_" <> constraint
    _ ->
      "validate_"
      <> base
      <> "_"
      <> naming.to_snake_case(prop_name)
      <> "_"
      <> constraint
  }
}

/// Format a field label for documentation.
fn field_label(prop_name: String) -> String {
  case prop_name {
    "" -> ""
    _ -> "." <> prop_name
  }
}

/// Render a runtime string literal for generated Gleam source.
fn gleam_string_literal(value: String) -> String {
  let escaped =
    value
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
    |> string.replace("\n", "\\n")
    |> string.replace("\r", "\\r")
    |> string.replace("\t", "\\t")
  "\"" <> escaped <> "\""
}

/// Emit the `ValidationFailure` type and its JSON encoder. Always
/// generated when guards.gleam is generated (i.e. whenever any schema
/// has constraints), so that routers and clients can rely on the
/// structured shape.
fn emit_validation_failure_type(sb: se.StringBuilder) -> se.StringBuilder {
  sb
  |> se.doc_comment("A single field-level validation failure.")
  |> se.doc_comment(
    "Composite validators return `List(ValidationFailure)` so callers can build structured 422 bodies and clients can branch per-field instead of parsing prose messages. `field` is the JSON property name (empty for top-level constraints), `code` is a JSON Schema keyword like `minLength` / `maximum` / `pattern`, and `message` is human-readable.",
  )
  |> se.line("pub type ValidationFailure {")
  |> se.indent(
    1,
    "ValidationFailure(field: String, code: String, message: String)",
  )
  |> se.line("}")
  |> se.blank_line()
  |> se.doc_comment(
    "Encode a `ValidationFailure` as JSON for emitting 422 response bodies.",
  )
  |> se.line(
    "pub fn validation_failure_to_json(failure: ValidationFailure) -> json.Json {",
  )
  |> se.indent(1, "json.object([")
  |> se.indent(2, "#(\"field\", json.string(failure.field)),")
  |> se.indent(2, "#(\"code\", json.string(failure.code)),")
  |> se.indent(2, "#(\"message\", json.string(failure.message)),")
  |> se.indent(1, "])")
  |> se.line("}")
  |> se.blank_line()
}

/// Build a Gleam source expression that constructs a
/// `Error(ValidationFailure(...))` with the given field / code / message.
fn validation_failure_literal(
  field: String,
  code: String,
  message: String,
) -> String {
  "Error(ValidationFailure(field: "
  <> gleam_string_literal(field)
  <> ", code: "
  <> gleam_string_literal(code)
  <> ", message: "
  <> gleam_string_literal(message)
  <> "))"
}

/// Like `validation_failure_literal` but the `message` is an arbitrary
/// Gleam source expression evaluated at runtime (e.g. a string-concat
/// pulling the regex compile error). Caller is responsible for the
/// expression already being valid Gleam source.
fn validation_failure_dynamic(
  field: String,
  code: String,
  message_expr: String,
) -> String {
  "Error(ValidationFailure(field: "
  <> gleam_string_literal(field)
  <> ", code: "
  <> gleam_string_literal(code)
  <> ", message: "
  <> message_expr
  <> "))"
}

fn build_composite_guard_function(
  name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> Option(GuardFunction) {
  let guard_calls = collect_guard_calls(name, schema_ref, ctx)
  case list.is_empty(guard_calls) {
    True -> None
    False -> {
      let fn_name = "validate_" <> naming.to_snake_case(name)
      let type_name = naming.schema_to_type_name(name)
      let gleam_type = composite_validator_type(name, schema_ref, ctx)
      let call_lines =
        list.flat_map(guard_calls, fn(call) {
          let #(guard_fn, accessor, is_required, kind, extra_unwrap) = call
          case kind, is_required, extra_unwrap {
            Direct, True, _ -> [
              "  let errors = case " <> guard_fn <> "(" <> accessor <> ") {",
              "    Ok(_) -> errors",
              "    Error(failure) -> [failure, ..errors]",
              "  }",
            ]
            Direct, False, False -> [
              "  let errors = case " <> accessor <> " {",
              "    option.Some(v) -> case " <> guard_fn <> "(v) {",
              "      Ok(_) -> errors",
              "      Error(failure) -> [failure, ..errors]",
              "    }",
              "    option.None -> errors",
              "  }",
            ]
            // Issue #537: the field's static type is `Option(Option(T))`,
            // so the constraint validator (which takes the bare `T`) is
            // only reachable through nested `Some(Some(v))` matches. The
            // `_ -> errors` arm collapses both `None` (field absent) and
            // `Some(None)` (field present, explicit null) into a no-op,
            // which matches the spec's intent — neither shape supplies a
            // value to constrain.
            Direct, False, True -> [
              "  let errors = case " <> accessor <> " {",
              "    option.Some(option.Some(v)) -> case " <> guard_fn <> "(v) {",
              "      Ok(_) -> errors",
              "      Error(failure) -> [failure, ..errors]",
              "    }",
              "    _ -> errors",
              "  }",
            ]
            // Issue #520: nested-record validators return
            // `Result(_, List(ValidationFailure))`; merge their failure
            // list into the outer accumulator.
            Composite, True, _ -> [
              "  let errors = case " <> guard_fn <> "(" <> accessor <> ") {",
              "    Ok(_) -> errors",
              "    Error(failures) -> list.append(list.reverse(failures), errors)",
              "  }",
            ]
            Composite, False, False -> [
              "  let errors = case " <> accessor <> " {",
              "    option.Some(v) -> case " <> guard_fn <> "(v) {",
              "      Ok(_) -> errors",
              "      Error(failures) -> list.append(list.reverse(failures), errors)",
              "    }",
              "    option.None -> errors",
              "  }",
            ]
            Composite, False, True -> [
              "  let errors = case " <> accessor <> " {",
              "    option.Some(option.Some(v)) -> case " <> guard_fn <> "(v) {",
              "      Ok(_) -> errors",
              "      Error(failures) -> list.append(list.reverse(failures), errors)",
              "    }",
              "    _ -> errors",
              "  }",
            ]
            // Issue #520: lists of validatable records are folded so
            // every element runs through the inner composite validator.
            CompositeList, True, _ -> [
              "  let errors = list.fold("
                <> accessor
                <> ", errors, fn(errs, item) {",
              "    case " <> guard_fn <> "(item) {",
              "      Ok(_) -> errs",
              "      Error(failures) -> list.append(list.reverse(failures), errs)",
              "    }",
              "  })",
            ]
            CompositeList, False, False -> [
              "  let errors = case " <> accessor <> " {",
              "    option.Some(items) -> list.fold(items, errors, fn(errs, item) {",
              "      case " <> guard_fn <> "(item) {",
              "        Ok(_) -> errs",
              "        Error(failures) -> list.append(list.reverse(failures), errs)",
              "      }",
              "    })",
              "    option.None -> errors",
              "  }",
            ]
            CompositeList, False, True -> [
              "  let errors = case " <> accessor <> " {",
              "    option.Some(option.Some(items)) -> list.fold(items, errors, fn(errs, item) {",
              "      case " <> guard_fn <> "(item) {",
              "        Ok(_) -> errs",
              "        Error(failures) -> list.append(list.reverse(failures), errs)",
              "      }",
              "    })",
              "    _ -> errors",
              "  }",
            ]
          }
        })
      Some(GuardFunction(
        name: fn_name,
        docs: [
          "Validate all constraints for " <> type_name <> ".",
          "Auto-calls all field validators and collects failures.",
        ],
        param_decl: "value: " <> gleam_type,
        return_type: "Result(" <> gleam_type <> ", List(ValidationFailure))",
        body: string.join(
          list.flatten([
            ["  let errors = []"],
            call_lines,
            [
              "  case errors {",
              "    [] -> Ok(value)",
              "    _ -> Error(errors)",
              "  }",
            ],
          ]),
          "\n",
        ),
        kind: CompositeValidator,
      ))
    }
  }
}

fn build_string_pattern_guard_function(
  schema_name: String,
  prop_name: String,
  pattern: Option(String),
) -> Option(GuardFunction) {
  case pattern {
    None -> None
    Some(pattern) -> {
      let fn_name = guard_function_name(schema_name, prop_name, "pattern")
      let pattern_literal = gleam_string_literal(pattern)
      let invalid_pattern_prefix =
        gleam_string_literal("invalid pattern: " <> pattern <> ": ")
      let mismatch_failure =
        validation_failure_literal(
          prop_name,
          "pattern",
          "must match pattern: " <> pattern,
        )
      let invalid_pattern_failure =
        validation_failure_dynamic(
          prop_name,
          "invalidPattern",
          invalid_pattern_prefix <> " <> error",
        )
      Some(GuardFunction(
        name: fn_name,
        docs: [
          "Validate string pattern for "
          <> schema_name
          <> field_label(prop_name)
          <> ".",
        ],
        param_decl: "value: String",
        return_type: "Result(String, ValidationFailure)",
        body: string.join(
          [
            "  case regexp.from_string(" <> pattern_literal <> ") {",
            "    Ok(re) -> case regexp.check(re, value) {",
            "      True -> Ok(value)",
            "      False -> " <> mismatch_failure,
            "    }",
            "    Error(regexp.CompileError(error:, ..)) -> "
              <> invalid_pattern_failure,
            "  }",
          ],
          "\n",
        ),
        kind: FieldValidator,
      ))
    }
  }
}

fn character_word(n: Int) -> String {
  case n {
    1 -> "character"
    _ -> "characters"
  }
}

// Issue #403: shared range-guard skeleton. The 7 build_*_guard_function
// helpers below differ only in: function-name suffix, docs phrase,
// param / return type, the value-extraction prelude (e.g.
// `let len = string.length(value)`), the variable that gets compared,
// the comparison operator and value-to-string conversion, and the
// failure keyword / phrase. RangeGuardSpec collects every per-call
// difference so the case-block emission lives in exactly one place.

type RangeBound {
  RangeBound(
    /// Operator placed between `compare_var` and `value_str`. The
    /// emitted shape is always `True -> failure / False -> Ok(value)`,
    /// so callers express "this is a failure when …" via the operator:
    /// inclusive guards use `<` / `>` (and `<.` / `>.` for floats),
    /// exclusive guards use `<=` / `>=` (and `<=.` / `>=.`).
    operator: String,
    value_str: String,
    keyword: String,
    phrase: String,
  )
}

type RangeGuardSpec {
  RangeGuardSpec(
    name_suffix: String,
    doc_what: String,
    param_decl: String,
    return_type: String,
    /// Lines emitted before the case block (e.g.
    /// `let len = string.length(value)`). Empty for guards that
    /// compare `value` directly.
    value_prelude: List(String),
    compare_var: String,
    min: Option(RangeBound),
    max: Option(RangeBound),
  )
}

fn build_range_guard(
  schema_name: String,
  prop_name: String,
  spec: RangeGuardSpec,
) -> Option(GuardFunction) {
  case spec.min, spec.max {
    None, None -> None
    _, _ -> {
      let fn_name =
        guard_function_name(schema_name, prop_name, spec.name_suffix)
      let lines =
        list.append(
          spec.value_prelude,
          range_check_lines(spec.compare_var, prop_name, spec.min, spec.max),
        )
      Some(GuardFunction(
        name: fn_name,
        docs: [
          "Validate "
          <> spec.doc_what
          <> " for "
          <> schema_name
          <> field_label(prop_name)
          <> ".",
        ],
        param_decl: spec.param_decl,
        return_type: spec.return_type,
        body: string.join(lines, "\n"),
        kind: FieldValidator,
      ))
    }
  }
}

fn range_check_lines(
  compare_var: String,
  prop_name: String,
  min: Option(RangeBound),
  max: Option(RangeBound),
) -> List(String) {
  case min, max {
    Some(lo), Some(hi) -> [
      "  case "
        <> compare_var
        <> " "
        <> lo.operator
        <> " "
        <> lo.value_str
        <> " {",
      "    True -> "
        <> validation_failure_literal(prop_name, lo.keyword, lo.phrase),
      "    False ->",
      "      case "
        <> compare_var
        <> " "
        <> hi.operator
        <> " "
        <> hi.value_str
        <> " {",
      "        True -> "
        <> validation_failure_literal(prop_name, hi.keyword, hi.phrase),
      "        False -> Ok(value)",
      "      }",
      "  }",
    ]
    Some(lo), None -> [
      "  case "
        <> compare_var
        <> " "
        <> lo.operator
        <> " "
        <> lo.value_str
        <> " {",
      "    True -> "
        <> validation_failure_literal(prop_name, lo.keyword, lo.phrase),
      "    False -> Ok(value)",
      "  }",
    ]
    None, Some(hi) -> [
      "  case "
        <> compare_var
        <> " "
        <> hi.operator
        <> " "
        <> hi.value_str
        <> " {",
      "    True -> "
        <> validation_failure_literal(prop_name, hi.keyword, hi.phrase),
      "    False -> Ok(value)",
      "  }",
    ]
    None, None -> []
  }
}

fn build_string_guard_function(
  schema_name: String,
  prop_name: String,
  min_length: Option(Int),
  max_length: Option(Int),
) -> Option(GuardFunction) {
  build_range_guard(
    schema_name,
    prop_name,
    RangeGuardSpec(
      name_suffix: "length",
      doc_what: "string length",
      param_decl: "value: String",
      return_type: "Result(String, ValidationFailure)",
      value_prelude: ["  let len = string.length(value)"],
      compare_var: "len",
      min: option.map(min_length, fn(n) {
        RangeBound(
          operator: "<",
          value_str: int.to_string(n),
          keyword: "minLength",
          phrase: "must be at least "
            <> int.to_string(n)
            <> " "
            <> character_word(n),
        )
      }),
      max: option.map(max_length, fn(n) {
        RangeBound(
          operator: ">",
          value_str: int.to_string(n),
          keyword: "maxLength",
          phrase: "must be at most "
            <> int.to_string(n)
            <> " "
            <> character_word(n),
        )
      }),
    ),
  )
}

fn build_integer_guard_function(
  schema_name: String,
  prop_name: String,
  minimum: Option(Int),
  maximum: Option(Int),
) -> Option(GuardFunction) {
  build_range_guard(
    schema_name,
    prop_name,
    RangeGuardSpec(
      name_suffix: "range",
      doc_what: "integer range",
      param_decl: "value: Int",
      return_type: "Result(Int, ValidationFailure)",
      value_prelude: [],
      compare_var: "value",
      min: option.map(minimum, fn(n) {
        RangeBound(
          operator: "<",
          value_str: int.to_string(n),
          keyword: "minimum",
          phrase: "must be at least " <> int.to_string(n),
        )
      }),
      max: option.map(maximum, fn(n) {
        RangeBound(
          operator: ">",
          value_str: int.to_string(n),
          keyword: "maximum",
          phrase: "must be at most " <> int.to_string(n),
        )
      }),
    ),
  )
}

fn build_float_guard_function(
  schema_name: String,
  prop_name: String,
  minimum: Option(Float),
  maximum: Option(Float),
) -> Option(GuardFunction) {
  build_range_guard(
    schema_name,
    prop_name,
    RangeGuardSpec(
      name_suffix: "range",
      doc_what: "float range",
      param_decl: "value: Float",
      return_type: "Result(Float, ValidationFailure)",
      value_prelude: [],
      compare_var: "value",
      min: option.map(minimum, fn(n) {
        RangeBound(
          operator: "<.",
          value_str: float.to_string(n),
          keyword: "minimum",
          phrase: "must be at least " <> float.to_string(n),
        )
      }),
      max: option.map(maximum, fn(n) {
        RangeBound(
          operator: ">.",
          value_str: float.to_string(n),
          keyword: "maximum",
          phrase: "must be at most " <> float.to_string(n),
        )
      }),
    ),
  )
}

fn build_integer_exclusive_guard_function(
  schema_name: String,
  prop_name: String,
  exclusive_minimum: Option(Int),
  exclusive_maximum: Option(Int),
) -> Option(GuardFunction) {
  // Exclusive bounds are expressed via `<=` / `>=` so the same
  // `True -> failure / False -> Ok(value)` shape applies.
  build_range_guard(
    schema_name,
    prop_name,
    RangeGuardSpec(
      name_suffix: "exclusive_range",
      doc_what: "integer exclusive range",
      param_decl: "value: Int",
      return_type: "Result(Int, ValidationFailure)",
      value_prelude: [],
      compare_var: "value",
      min: option.map(exclusive_minimum, fn(n) {
        RangeBound(
          operator: "<=",
          value_str: int.to_string(n),
          keyword: "exclusiveMinimum",
          phrase: "must be greater than " <> int.to_string(n),
        )
      }),
      max: option.map(exclusive_maximum, fn(n) {
        RangeBound(
          operator: ">=",
          value_str: int.to_string(n),
          keyword: "exclusiveMaximum",
          phrase: "must be less than " <> int.to_string(n),
        )
      }),
    ),
  )
}

fn build_integer_multiple_of_guard_function(
  schema_name: String,
  prop_name: String,
  multiple_of: Option(Int),
) -> Option(GuardFunction) {
  case multiple_of {
    None -> None
    Some(m) ->
      Some(GuardFunction(
        name: guard_function_name(schema_name, prop_name, "multiple_of"),
        docs: [
          "Validate integer multipleOf for "
          <> schema_name
          <> field_label(prop_name)
          <> ".",
        ],
        param_decl: "value: Int",
        return_type: "Result(Int, ValidationFailure)",
        body: string.join(
          [
            "  case value % " <> int.to_string(m) <> " == 0 {",
            "    False -> "
              <> validation_failure_literal(
              prop_name,
              "multipleOf",
              "must be a multiple of " <> int.to_string(m),
            ),
            "    True -> Ok(value)",
            "  }",
          ],
          "\n",
        ),
        kind: FieldValidator,
      ))
  }
}

fn build_float_exclusive_guard_function(
  schema_name: String,
  prop_name: String,
  exclusive_minimum: Option(Float),
  exclusive_maximum: Option(Float),
) -> Option(GuardFunction) {
  build_range_guard(
    schema_name,
    prop_name,
    RangeGuardSpec(
      name_suffix: "exclusive_range",
      doc_what: "float exclusive range",
      param_decl: "value: Float",
      return_type: "Result(Float, ValidationFailure)",
      value_prelude: [],
      compare_var: "value",
      min: option.map(exclusive_minimum, fn(n) {
        RangeBound(
          operator: "<=.",
          value_str: float.to_string(n),
          keyword: "exclusiveMinimum",
          phrase: "must be greater than " <> float.to_string(n),
        )
      }),
      max: option.map(exclusive_maximum, fn(n) {
        RangeBound(
          operator: ">=.",
          value_str: float.to_string(n),
          keyword: "exclusiveMaximum",
          phrase: "must be less than " <> float.to_string(n),
        )
      }),
    ),
  )
}

fn build_float_multiple_of_guard_function(
  schema_name: String,
  prop_name: String,
  multiple_of: Option(Float),
) -> Option(GuardFunction) {
  case multiple_of {
    None -> None
    Some(m) ->
      Some(GuardFunction(
        name: guard_function_name(schema_name, prop_name, "multiple_of"),
        docs: [
          "Validate float multipleOf for "
          <> schema_name
          <> field_label(prop_name)
          <> ".",
        ],
        param_decl: "value: Float",
        return_type: "Result(Float, ValidationFailure)",
        // Issue #521: the prior expression
        //   value -. float.truncate(value /. m |> int.to_float) *. m
        // was malformed — the `|> int.to_float` was applied to a
        // Float (the result of `value /. m`) instead of the Int
        // returned by `float.truncate`, and `float.truncate(_)` was
        // multiplied by `m` (Float) with `*.` (which expects Float on
        // both sides), so even with `gleam/float` and `gleam/int`
        // imported the body did not type-check. The corrected form
        // is `value -. int.to_float(float.truncate(value /. m)) *. m`,
        // which computes truncation-toward-zero modulo.
        body: string.join(
          [
            "  let remainder = value -. int.to_float(float.truncate(value /. "
              <> float.to_string(m)
              <> ")) *. "
              <> float.to_string(m),
            "  case remainder == 0.0 || remainder == -0.0 {",
            "    False -> "
              <> validation_failure_literal(
              prop_name,
              "multipleOf",
              "must be a multiple of " <> float.to_string(m),
            ),
            "    True -> Ok(value)",
            "  }",
          ],
          "\n",
        ),
        kind: FieldValidator,
      ))
  }
}

fn build_list_guard_function(
  schema_name: String,
  prop_name: String,
  min_items: Option(Int),
  max_items: Option(Int),
) -> Option(GuardFunction) {
  build_range_guard(
    schema_name,
    prop_name,
    RangeGuardSpec(
      name_suffix: "length",
      doc_what: "list length",
      param_decl: "value: List(a)",
      return_type: "Result(List(a), ValidationFailure)",
      value_prelude: ["  let len = list.length(value)"],
      compare_var: "len",
      min: option.map(min_items, fn(n) {
        RangeBound(
          operator: "<",
          value_str: int.to_string(n),
          keyword: "minItems",
          phrase: "must have at least " <> int.to_string(n) <> " items",
        )
      }),
      max: option.map(max_items, fn(n) {
        RangeBound(
          operator: ">",
          value_str: int.to_string(n),
          keyword: "maxItems",
          phrase: "must have at most " <> int.to_string(n) <> " items",
        )
      }),
    ),
  )
}

fn build_unique_items_guard_function(
  schema_name: String,
  prop_name: String,
  unique_items: Bool,
) -> Option(GuardFunction) {
  use <- bool.guard(when: !unique_items, return: None)
  Some(GuardFunction(
    name: guard_function_name(schema_name, prop_name, "unique"),
    docs: [
      "Validate unique items for "
      <> schema_name
      <> field_label(prop_name)
      <> ".",
    ],
    param_decl: "value: List(a)",
    return_type: "Result(List(a), ValidationFailure)",
    body: string.join(
      [
        "  case list.length(value) == list.length(list.unique(value)) {",
        "    True -> Ok(value)",
        "    False -> "
          <> validation_failure_literal(
          prop_name,
          "uniqueItems",
          "items must be unique",
        ),
        "  }",
      ],
      "\n",
    ),
    kind: FieldValidator,
  ))
}

fn build_properties_count_guard_function(
  schema_name: String,
  prop_name: String,
  min_properties: Option(Int),
  max_properties: Option(Int),
) -> Option(GuardFunction) {
  build_range_guard(
    schema_name,
    prop_name,
    RangeGuardSpec(
      name_suffix: "properties",
      doc_what: "property count",
      param_decl: "value: Dict(k, v)",
      return_type: "Result(Dict(k, v), ValidationFailure)",
      value_prelude: ["  let count = dict.size(value)"],
      compare_var: "count",
      min: option.map(min_properties, fn(n) {
        RangeBound(
          operator: "<",
          value_str: int.to_string(n),
          keyword: "minProperties",
          phrase: "must have at least " <> int.to_string(n) <> " properties",
        )
      }),
      max: option.map(max_properties, fn(n) {
        RangeBound(
          operator: ">",
          value_str: int.to_string(n),
          keyword: "maxProperties",
          phrase: "must have at most " <> int.to_string(n) <> " properties",
        )
      }),
    ),
  )
}

/// Determine the Gleam type for the composite validator parameter.
///
/// Issue #537: non-object / non-allOf schemas previously fell through
/// to `schema_dispatch.schema_type(s)`, which renders `ArraySchema` as
/// `"List(" <> bare_type <> ")"` — the inner Reference's type name
/// emitted WITHOUT the `types.` prefix. `guards.gleam` does NOT
/// re-export schema types, so the bare name resolves to "Unknown
/// type" at `gleam build` time on any spec whose array-typed
/// component schema's items are a `$ref` (e.g. GitHub's
/// `projects-v2-view-sort-by-item: type:array, items: $ref`). Using
/// `codec_helpers.qualified_schema_ref_type` qualifies the inner ref
/// and keeps inline primitives unqualified.
fn composite_validator_type(
  name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> String {
  let schema = context.resolve_schema_ref(schema_ref, ctx)
  case schema {
    Ok(ObjectSchema(..)) | Ok(AllOfSchema(..)) ->
      "types." <> naming.schema_to_type_name(name)
    Ok(s) -> schema_dispatch.schema_type_qualified(s)
    _ -> "types." <> naming.schema_to_type_name(name)
  }
}

/// Shape of a generated guard invocation.
///
/// - `Direct`: the validator returns `Result(T, ValidationFailure)` —
///   the historical leaf case (range / pattern / length / unique).
/// - `Composite`: the validator returns
///   `Result(T, List(ValidationFailure))` — the per-schema aggregator
///   for a nested record. Issue #520.
/// - `CompositeList`: the field is `List(T)` and each item must be
///   recursively validated against its composite validator. Issue
///   #520.
type GuardCallKind {
  Direct
  Composite
  CompositeList
}

/// A guard call with metadata about whether the field is optional and
/// what shape its validator returns.
/// `#(guard_fn_name, accessor_expr, is_required, kind, extra_unwrap)`.
///
/// `extra_unwrap` (Issue #537): True when the accessor's runtime type
/// is `Option(Option(T))` — i.e. the field is `not in required` AND
/// references a `nullable: true` schema (whose alias is itself
/// `Option(T)`). The composite validator must peel a SECOND `Option`
/// layer before calling the per-constraint validator, otherwise the
/// validator receives `Option(T)` where it expects `T` and `gleam
/// build` rejects the module with `Type mismatch`.
type GuardCall =
  #(String, String, Bool, GuardCallKind, Bool)

/// Collect all guard function calls for a schema's constrained fields.
fn collect_guard_calls(
  name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> List(GuardCall) {
  collect_guard_calls_visiting(name, schema_ref, ctx, [])
}

fn collect_guard_calls_visiting(
  name: String,
  schema_ref: SchemaRef,
  ctx: Context,
  visiting: List(String),
) -> List(GuardCall) {
  let schema = context.resolve_schema_ref(schema_ref, ctx)
  case schema {
    Ok(ObjectSchema(
      properties:,
      required:,
      min_properties:,
      max_properties:,
      additional_properties:,
      ..,
    )) -> {
      let prop_calls =
        ir_build.sorted_entries(properties)
        |> list.flat_map(fn(entry) {
          let #(prop_name, prop_ref) = entry
          // Issue #537: a `required: true` AND `nullable: true` field
          // still renders as `Option(<T>)` in the generated record
          // type (`schema_dispatch.schema_type` wraps every nullable
          // through `Option(_)`). The composite validator must
          // therefore unwrap before calling the per-field validator,
          // exactly as it does for plain optional fields. Treat the
          // call as not-required when the field is nullable so the
          // emitter falls into the `option.Some(v) ->` shape.
          let is_required =
            list.contains(required, prop_name)
            && !schema_utils.schema_ref_is_nullable(prop_ref, ctx)
          collect_field_guard_calls(
            name,
            prop_name,
            prop_ref,
            is_required,
            ctx,
            visiting,
          )
        })
      let size_calls = case min_properties, max_properties {
        None, None -> []
        _, _ -> {
          // Issue #537: the `properties` constraint validator's
          // signature is `Dict(k, v) -> Result(Dict(k, v), _)`. When
          // the generated record carries an `additional_properties`
          // field (i.e. the spec declares `additionalProperties: Typed
          // | Untyped`), pass `value.additional_properties` so the
          // call type-checks. The record's other concrete fields are
          // always populated and don't contribute to `dict.size`
          // anyway; the constraint counts only the open-ended bag.
          // For schemas without an `additional_properties` field, fall
          // back to `value` — that path is already broken on records
          // with concrete fields (no `Dict` view exists), but at
          // least dict-only schemas (which are the common case) now
          // compile.
          let size_accessor = case additional_properties {
            Typed(_) | Untyped -> "value.additional_properties"
            _ -> "value"
          }
          [
            #(
              guard_function_name(name, "", "properties"),
              size_accessor,
              True,
              Direct,
              False,
            ),
          ]
        }
      }
      list.append(prop_calls, size_calls)
    }
    Ok(AllOfSchema(schemas:, ..)) -> {
      let merged = allof_merge.merge_allof_schemas(schemas, ctx)
      ir_build.sorted_entries(merged.properties)
      |> list.flat_map(fn(entry) {
        let #(prop_name, prop_ref) = entry
        // Issue #537: see the parallel branch above for why nullable
        // counts toward "needs unwrapping" alongside `not in
        // required`.
        let is_required =
          list.contains(merged.required, prop_name)
          && !schema_utils.schema_ref_is_nullable(prop_ref, ctx)
        collect_field_guard_calls(
          name,
          prop_name,
          prop_ref,
          is_required,
          ctx,
          visiting,
        )
      })
    }
    Ok(StringSchema(metadata:, min_length:, max_length:, pattern:, ..)) -> {
      // Issue #537: a top-level `nullable: true` schema renders the
      // composite's `value` parameter as `Option(<T>)`, so the inner
      // constraint validators must be reached via the
      // `option.Some(v) -> validator(v)` shape — set `is_req=False`
      // when nullable so the dispatch lands on the unwrap arm.
      let is_req = !metadata.nullable
      let calls = case min_length, max_length {
        None, None -> []
        _, _ -> [
          #(
            guard_function_name(name, "", "length"),
            "value",
            is_req,
            Direct,
            False,
          ),
        ]
      }
      case pattern {
        None -> calls
        Some(_) ->
          list.append(calls, [
            #(
              guard_function_name(name, "", "pattern"),
              "value",
              is_req,
              Direct,
              False,
            ),
          ])
      }
    }
    Ok(IntegerSchema(
      metadata:,
      minimum:,
      maximum:,
      exclusive_minimum:,
      exclusive_maximum:,
      multiple_of:,
      ..,
    )) -> {
      let is_req = !metadata.nullable
      let calls = case minimum, maximum {
        None, None -> []
        _, _ -> [
          #(
            guard_function_name(name, "", "range"),
            "value",
            is_req,
            Direct,
            False,
          ),
        ]
      }
      let calls = case exclusive_minimum, exclusive_maximum {
        None, None -> calls
        _, _ ->
          list.append(calls, [
            #(
              guard_function_name(name, "", "exclusive_range"),
              "value",
              is_req,
              Direct,
              False,
            ),
          ])
      }
      case multiple_of {
        None -> calls
        Some(_) ->
          list.append(calls, [
            #(
              guard_function_name(name, "", "multiple_of"),
              "value",
              is_req,
              Direct,
              False,
            ),
          ])
      }
    }
    Ok(NumberSchema(
      metadata:,
      minimum:,
      maximum:,
      exclusive_minimum:,
      exclusive_maximum:,
      multiple_of:,
      ..,
    )) -> {
      let is_req = !metadata.nullable
      let calls = case minimum, maximum {
        None, None -> []
        _, _ -> [
          #(
            guard_function_name(name, "", "range"),
            "value",
            is_req,
            Direct,
            False,
          ),
        ]
      }
      let calls = case exclusive_minimum, exclusive_maximum {
        None, None -> calls
        _, _ ->
          list.append(calls, [
            #(
              guard_function_name(name, "", "exclusive_range"),
              "value",
              is_req,
              Direct,
              False,
            ),
          ])
      }
      case multiple_of {
        None -> calls
        Some(_) ->
          list.append(calls, [
            #(
              guard_function_name(name, "", "multiple_of"),
              "value",
              is_req,
              Direct,
              False,
            ),
          ])
      }
    }
    Ok(ArraySchema(metadata:, min_items:, max_items:, unique_items:, ..)) -> {
      let is_req = !metadata.nullable
      let length_calls = case min_items, max_items {
        None, None -> []
        _, _ -> [
          #(
            guard_function_name(name, "", "length"),
            "value",
            is_req,
            Direct,
            False,
          ),
        ]
      }
      let unique_calls = case unique_items {
        True -> [
          #(
            guard_function_name(name, "", "unique"),
            "value",
            is_req,
            Direct,
            False,
          ),
        ]
        False -> []
      }
      list.append(length_calls, unique_calls)
    }
    _ -> []
  }
}

/// Collect guard calls for a single field.
///
/// `visiting` is propagated from `collect_guard_calls_visiting` so the
/// nested-record (`Composite` / `CompositeList`) branches can break
/// schema-graph cycles when deciding whether to emit a recursive call.
fn collect_field_guard_calls(
  schema_name: String,
  prop_name: String,
  prop_ref: SchemaRef,
  is_required: Bool,
  ctx: Context,
  visiting: List(String),
) -> List(GuardCall) {
  let resolved = context.resolve_schema_ref(prop_ref, ctx)
  let accessor = "value." <> naming.to_snake_case(prop_name)
  // Issue #537: `extra_unwrap` is True when the field's static type is
  // `Option(Option(<T>))` rather than `Option(<T>)` or `<T>`. The
  // double layer ONLY arises when the field is NOT in `required` AND
  // the referenced schema's TYPE ALIAS itself unwraps to
  // `Option(...)` — that happens specifically for `$ref` to a
  // nullable primitive / nullable array, whose alias IR is
  // `pub type X = Option(<inner>)`. Nullable objects / unions keep
  // a non-Option alias (the record / union itself) and only pick up
  // the outer optional wrapping, so they need only ONE unwrap.
  // An unresolved `$ref` cannot tell us whether its alias is
  // `Option(...)`; treat it as the conservative non-Option case so the
  // composite emits a single-unwrap shape (matching the resolver's
  // diagnostic surface — broken refs surface elsewhere).
  let alias_is_optional = case prop_ref {
    Reference(..) ->
      case resolved {
        Ok(s) -> codec_helpers.schema_ref_has_bare_option_type(Inline(s))
        // nolint: thrown_away_error -- conservative fallback: see comment above.
        Error(_) -> False
      }
    _ -> False
  }
  let extra_unwrap = !is_required && alias_is_optional
  case resolved {
    Ok(StringSchema(min_length:, max_length:, pattern:, ..)) -> {
      let calls = case min_length, max_length {
        None, None -> []
        _, _ -> [
          #(
            guard_function_name(schema_name, prop_name, "length"),
            accessor,
            is_required,
            Direct,
            extra_unwrap,
          ),
        ]
      }
      case pattern {
        None -> calls
        Some(_) ->
          list.append(calls, [
            #(
              guard_function_name(schema_name, prop_name, "pattern"),
              accessor,
              is_required,
              Direct,
              extra_unwrap,
            ),
          ])
      }
    }
    Ok(IntegerSchema(
      minimum:,
      maximum:,
      exclusive_minimum:,
      exclusive_maximum:,
      multiple_of:,
      ..,
    )) -> {
      let calls = case minimum, maximum {
        None, None -> []
        _, _ -> [
          #(
            guard_function_name(schema_name, prop_name, "range"),
            accessor,
            is_required,
            Direct,
            extra_unwrap,
          ),
        ]
      }
      let calls = case exclusive_minimum, exclusive_maximum {
        None, None -> calls
        _, _ ->
          list.append(calls, [
            #(
              guard_function_name(schema_name, prop_name, "exclusive_range"),
              accessor,
              is_required,
              Direct,
              extra_unwrap,
            ),
          ])
      }
      case multiple_of {
        None -> calls
        Some(_) ->
          list.append(calls, [
            #(
              guard_function_name(schema_name, prop_name, "multiple_of"),
              accessor,
              is_required,
              Direct,
              extra_unwrap,
            ),
          ])
      }
    }
    Ok(NumberSchema(
      minimum:,
      maximum:,
      exclusive_minimum:,
      exclusive_maximum:,
      multiple_of:,
      ..,
    )) -> {
      let calls = case minimum, maximum {
        None, None -> []
        _, _ -> [
          #(
            guard_function_name(schema_name, prop_name, "range"),
            accessor,
            is_required,
            Direct,
            extra_unwrap,
          ),
        ]
      }
      let calls = case exclusive_minimum, exclusive_maximum {
        None, None -> calls
        _, _ ->
          list.append(calls, [
            #(
              guard_function_name(schema_name, prop_name, "exclusive_range"),
              accessor,
              is_required,
              Direct,
              extra_unwrap,
            ),
          ])
      }
      case multiple_of {
        None -> calls
        Some(_) ->
          list.append(calls, [
            #(
              guard_function_name(schema_name, prop_name, "multiple_of"),
              accessor,
              is_required,
              Direct,
              extra_unwrap,
            ),
          ])
      }
    }
    Ok(ArraySchema(items:, min_items:, max_items:, unique_items:, ..)) -> {
      let length_calls = case min_items, max_items {
        None, None -> []
        _, _ -> [
          #(
            guard_function_name(schema_name, prop_name, "length"),
            accessor,
            is_required,
            Direct,
            extra_unwrap,
          ),
        ]
      }
      let unique_calls = case unique_items {
        True -> [
          #(
            guard_function_name(schema_name, prop_name, "unique"),
            accessor,
            is_required,
            Direct,
            extra_unwrap,
          ),
        ]
        False -> []
      }
      // Issue #520: when the array's items are a `$ref` to a schema
      // that has its own composite validator, fold over the list and
      // run the inner validator on every element. Without this, an
      // out-of-range element in `Poll.options` (where each option has
      // a constrained `weight`) silently passes the outer
      // `validate_poll`.
      let item_calls = case items {
        Reference(name: item_name, ..) ->
          case schema_has_validator_visiting(item_name, ctx, visiting) {
            True -> [
              #(
                "validate_" <> naming.to_snake_case(item_name),
                accessor,
                is_required,
                CompositeList,
                extra_unwrap,
              ),
            ]
            False -> []
          }
        _ -> []
      }
      list.flatten([length_calls, unique_calls, item_calls])
    }
    // Issue #520: a property whose schema is a `$ref` to a record
    // type with its own composite validator should propagate that
    // record's failures into the outer aggregator. Pre-fix,
    // out-of-range nested fields slipped past `validate_<outer>`
    // entirely.
    Ok(ObjectSchema(..)) ->
      case prop_ref {
        Reference(name: ref_name, ..) ->
          case schema_has_validator_visiting(ref_name, ctx, visiting) {
            True -> [
              #(
                "validate_" <> naming.to_snake_case(ref_name),
                accessor,
                is_required,
                Composite,
                extra_unwrap,
              ),
            ]
            False -> []
          }
        _ -> []
      }
    _ -> []
  }
}
