import gleam/bool
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import oaspec/config
import oaspec/internal/codegen/allof_merge
import oaspec/internal/codegen/context.{
  type Context, type GeneratedFile, GeneratedFile,
}
import oaspec/internal/codegen/ir_build
import oaspec/internal/codegen/types as type_gen
import oaspec/internal/openapi/resolver
import oaspec/internal/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, ArraySchema, Inline,
  IntegerSchema, NumberSchema, ObjectSchema, Reference, StringSchema,
}
import oaspec/internal/util/naming
import oaspec/internal/util/string_extra as se

/// Check whether a named component schema has a composite validator.
/// Used by server/client generators to decide whether to emit guard calls.
pub fn schema_has_validator(name: String, ctx: Context) -> Bool {
  case context.spec(ctx).components {
    Some(components) ->
      case dict.get(components.schemas, name) {
        Ok(schema_ref) ->
          !ir_build.is_internal_schema(schema_ref)
          && !list.is_empty(collect_guard_calls(name, schema_ref, ctx))
        // nolint: thrown_away_error -- unknown schema name simply has no validator
        Error(_) -> False
      }
    None -> False
  }
}

/// Generate guard/validation functions from OpenAPI schemas that have constraints.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let content = generate_guards(ctx)
  case string.contains(content, "pub fn validate_") {
    True -> [
      GeneratedFile(
        path: "guards.gleam",
        content: content,
        target: context.SharedTarget,
        write_mode: context.Overwrite,
      ),
    ]
    False -> []
  }
}

/// Generate validation guard functions for schemas with constraints.
fn generate_guards(ctx: Context) -> String {
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
          let resolved = case schema_ref {
            Inline(s) -> Ok(s)
            Reference(..) ->
              resolver.resolve_schema_ref(schema_ref, context.spec(ctx))
          }
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
        let #(_, _, is_required) = call
        !is_required
      })
    })
  let imports = case needs_option {
    True -> ["gleam/option", ..imports]
    False -> imports
  }

  let sb =
    se.file_header(context.version)
    |> se.imports(imports)
    |> emit_validation_failure_type()

  let sb =
    list.fold(schemas, sb, fn(sb, entry) {
      let #(name, schema_ref) = entry
      generate_guards_for_schema(sb, name, schema_ref, ctx)
    })

  // Generate composite validate_<type> functions that call all field validators
  let sb =
    list.fold(schemas, sb, fn(sb, entry) {
      let #(name, schema_ref) = entry
      generate_composite_validator(sb, name, schema_ref, ctx)
    })

  // #339: when the same field appears in multiple schemas via allOf
  // flattening, the per-field validators have byte-identical bodies.
  // Collapse the duplicates: keep one canonical definition and
  // rewrite the rest as 1-line delegating stubs that forward to it.
  // The composite validators (which call the per-field validators by
  // name) keep working unchanged because the duplicate names still
  // exist — they just delegate now.
  se.to_string(sb)
  |> dedupe_field_validator_definitions
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
fn dedupe_field_validator_definitions(source: String) -> String {
  // Split on the boundary between top-level pub functions. The first
  // chunk is the file header (imports, type defs, helpers); each
  // subsequent chunk is one `pub fn` definition (with the leading
  // "pub fn " stripped by the split).
  case string.split(source, on: "\npub fn ") {
    [] -> source
    [_only_header] -> source
    [head, ..raw_chunks] -> {
      // Parse each chunk into structured form. Chunks that don't
      // match the expected per-field validator shape are passed
      // through unchanged.
      let parsed = list.map(raw_chunks, parse_function_chunk)
      // Group eligible chunks by body and pick a canonical name per
      // group (lex-first). Keys are body strings; values are the
      // canonical function name.
      let canonical_by_body = build_body_to_canonical_name_map(parsed)
      // Rewrite each chunk: if the chunk is a duplicate (its name
      // isn't the canonical for its body), emit a delegating stub.
      let rewritten =
        list.map(parsed, fn(p) {
          rewrite_chunk_if_duplicate(p, canonical_by_body)
        })
      // Re-join with the original separator.
      head <> string.concat(list.map(rewritten, fn(c) { "\npub fn " <> c }))
    }
  }
}

/// Lightweight parse of a single `pub fn` chunk. The chunk does NOT
/// include the leading `pub fn `. `name` is everything up to the
/// first `(`. `signature_and_body` keeps the full original text from
/// after the name onward, used as-is when emission is unchanged.
type ParsedChunk {
  ParsedChunk(
    /// Function name (e.g. `validate_inline_upload_title_length`).
    name: String,
    /// Parameter declaration block, e.g. `value: String`.
    param_decl: String,
    /// Return type, e.g. `Result(String, ValidationFailure)`.
    return_type: String,
    /// The function body, including surrounding whitespace —
    /// everything between the first `{` (after the signature) and
    /// the matching `}` of the function definition. Used as the
    /// dedup key.
    body: String,
    /// Trailing text after the closing `}` (typically `\n` and any
    /// blank-line separator before the next function). Preserved so
    /// reconstruction keeps the original formatting.
    trailing: String,
    /// The full original chunk text. Used verbatim when the chunk
    /// is the canonical / unique definition.
    original: String,
  )
}

fn parse_function_chunk(chunk: String) -> ParsedChunk {
  // Try to extract `name(params) -> return_type {body}trailing`.
  // When parsing fails (chunk doesn't match the expected per-field
  // validator shape), fall back to a passthrough record with empty
  // structured fields and the original text intact.
  let fallback =
    ParsedChunk(
      name: "",
      param_decl: "",
      return_type: "",
      body: "",
      trailing: "",
      original: chunk,
    )
  parse_function_chunk_strict(chunk)
  |> result.unwrap(fallback)
}

fn parse_function_chunk_strict(chunk: String) -> Result(ParsedChunk, Nil) {
  use #(name, after_open_paren) <- result.try(string.split_once(chunk, on: "("))
  use #(param_decl, after_arrow) <- result.try(string.split_once(
    after_open_paren,
    on: ") -> ",
  ))
  use #(return_type, after_open_brace) <- result.try(string.split_once(
    after_arrow,
    on: " {\n",
  ))
  use #(body, trailing) <- result.try(rsplit_once_on_close_brace(
    after_open_brace,
  ))
  Ok(ParsedChunk(
    name: name,
    param_decl: param_decl,
    return_type: return_type,
    body: body,
    trailing: trailing,
    original: chunk,
  ))
}

/// Split a string at its LAST occurrence of `\n}\n`. Used to find
/// the closing `}` of the function (the trailing `\n` after `}`
/// always exists in the generator's output). Returns the portion
/// before `\n}` (the body, excluding the closing brace itself) and
/// the portion after `}\n` (the trailing formatting before the
/// next function — typically a blank line plus the next function's
/// doc-comment block).
fn rsplit_once_on_close_brace(s: String) -> Result(#(String, String), Nil) {
  let needle = "\n}\n"
  case string.split(s, on: needle) {
    [_only] -> Error(Nil)
    parts -> {
      // All but the last chunk belong to the body (including any
      // intermediate `\n}\n` that legitimately appear inside nested
      // case expressions — though in practice generated function
      // bodies never contain bare `\n}\n` because case branches
      // indent further).
      case list.reverse(parts) {
        [] -> Error(Nil)
        [last_part, ..rev_rest] -> {
          let body =
            list.reverse(rev_rest)
            |> string.join(needle)
          // `last_part` is what came AFTER the final `\n}\n` —
          // i.e. the inter-function whitespace + the next
          // function's doc-comment lines (if any). Return body
          // (without the closing brace) and last_part (the
          // trailing block, which the caller is responsible for
          // re-emitting verbatim after its own closing brace).
          Ok(#(body, last_part))
        }
      }
    }
  }
}

/// Group eligible chunks (parsed successfully and whose name starts
/// with the `validate_` per-field-validator prefix) by their body
/// content. For each body that has multiple defining chunks, pick
/// the lex-first name as canonical. Returns a Dict keyed by body.
fn build_body_to_canonical_name_map(
  parsed: List(ParsedChunk),
) -> dict.Dict(String, String) {
  list.fold(parsed, dict.new(), fn(acc, chunk) {
    case is_dedupable(chunk) {
      False -> acc
      True ->
        case dict.get(acc, chunk.body) {
          Error(Nil) -> dict.insert(acc, chunk.body, chunk.name)
          Ok(existing) ->
            case string.compare(chunk.name, existing) {
              order.Lt -> dict.insert(acc, chunk.body, chunk.name)
              _ -> acc
            }
        }
    }
  })
}

/// A chunk is dedup-eligible if it's a per-field validator (its name
/// starts with `validate_` and ends with one of the recognised
/// constraint suffixes used by `generate_*_guard`). The composite
/// `validate_<type>` functions are NOT dedup-eligible because their
/// names are the public stable surface that downstream code calls.
fn is_dedupable(chunk: ParsedChunk) -> Bool {
  use <- bool.guard(
    when: !string.starts_with(chunk.name, "validate_"),
    return: False,
  )
  list.any(per_field_validator_suffixes(), fn(suffix) {
    string.ends_with(chunk.name, suffix)
  })
}

fn per_field_validator_suffixes() -> List(String) {
  [
    "_length", "_pattern", "_range", "_exclusive", "_multiple_of", "_count",
    "_unique",
  ]
}

/// If `chunk` is a duplicate of an earlier definition for the same
/// body, emit a one-line delegator that forwards to the canonical
/// name. Otherwise emit the chunk verbatim.
fn rewrite_chunk_if_duplicate(
  chunk: ParsedChunk,
  canonical_by_body: dict.Dict(String, String),
) -> String {
  case dict.get(canonical_by_body, chunk.body) {
    // Body has no canonical entry (chunk wasn't dedup-eligible) →
    // pass through unchanged.
    Error(Nil) -> chunk.original
    Ok(canonical_name) ->
      case canonical_name == chunk.name {
        // This chunk IS the canonical → keep its full body.
        True -> chunk.original
        // This chunk is a duplicate → emit a delegating stub.
        False -> emit_delegator(chunk, canonical_name)
      }
  }
}

fn emit_delegator(chunk: ParsedChunk, canonical_name: String) -> String {
  // Per-field validators always take a single parameter named
  // `value`, so the delegator just passes it through. The closing
  // `}\n` here matches the `\n}\n` that `parse_function_chunk`
  // stripped while extracting the body. The chunk's `trailing`
  // (everything after the original `\n}\n` — typically a blank
  // line plus the next function's doc-comment) is preserved
  // verbatim so subsequent functions don't lose their docs.
  chunk.name
  <> "("
  <> chunk.param_decl
  <> ") -> "
  <> chunk.return_type
  <> " {\n  "
  <> canonical_name
  <> "(value)\n}\n"
  <> chunk.trailing
}

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
  let schema = case schema_ref {
    Inline(s) -> Ok(s)
    Reference(..) -> resolver.resolve_schema_ref(schema_ref, context.spec(ctx))
  }
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
    Ok(NumberSchema(minimum: Some(_), ..))
    | Ok(NumberSchema(maximum: Some(_), ..))
    | Ok(NumberSchema(exclusive_minimum: Some(_), ..))
    | Ok(NumberSchema(exclusive_maximum: Some(_), ..)) ->
      ConstraintTypes(..acc, has_float: True)
    Ok(NumberSchema(multiple_of: Some(_), ..)) ->
      ConstraintTypes(..acc, has_float: True, has_float_multiple_of: True)
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

/// Generate guard functions for a single schema's constrained fields.
fn generate_guards_for_schema(
  sb: se.StringBuilder,
  name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> se.StringBuilder {
  case schema_ref {
    Inline(schema) -> generate_guards_for_schema_object(sb, name, schema, ctx)
    Reference(name:, ..) -> {
      let resolved_name = name
      case resolver.resolve_schema_ref(schema_ref, context.spec(ctx)) {
        Ok(schema) ->
          generate_guards_for_schema_object(sb, resolved_name, schema, ctx)
        _ -> sb
      }
    }
  }
}

/// Generate guard functions for fields within a schema object.
fn generate_guards_for_schema_object(
  sb: se.StringBuilder,
  name: String,
  schema: SchemaObject,
  ctx: Context,
) -> se.StringBuilder {
  case schema {
    ObjectSchema(properties:, min_properties:, max_properties:, ..) -> {
      let sb =
        generate_properties_count_guard(
          sb,
          name,
          "",
          min_properties,
          max_properties,
        )
      let props = ir_build.sorted_entries(properties)
      list.fold(props, sb, fn(sb, entry) {
        let #(prop_name, prop_ref) = entry
        generate_field_guard(sb, name, prop_name, prop_ref, ctx)
      })
    }
    AllOfSchema(schemas:, ..) -> {
      let props =
        ir_build.sorted_entries(
          allof_merge.merge_allof_schemas(schemas, ctx).properties,
        )
      list.fold(props, sb, fn(sb, entry) {
        let #(prop_name, prop_ref) = entry
        generate_field_guard(sb, name, prop_name, prop_ref, ctx)
      })
    }
    // Top-level string/integer constraints (type aliases with constraints)
    StringSchema(min_length:, max_length:, pattern:, ..) -> {
      let sb = generate_string_guard(sb, name, "", min_length, max_length)
      generate_string_pattern_guard(sb, name, "", pattern)
    }
    IntegerSchema(
      minimum:,
      maximum:,
      exclusive_minimum:,
      exclusive_maximum:,
      multiple_of:,
      ..,
    ) -> {
      let sb = generate_integer_guard(sb, name, "", minimum, maximum)
      let sb =
        generate_integer_exclusive_guard(
          sb,
          name,
          "",
          exclusive_minimum,
          exclusive_maximum,
        )
      generate_integer_multiple_of_guard(sb, name, "", multiple_of)
    }
    NumberSchema(
      minimum:,
      maximum:,
      exclusive_minimum:,
      exclusive_maximum:,
      multiple_of:,
      ..,
    ) -> {
      let sb = generate_float_guard(sb, name, "", minimum, maximum)
      let sb =
        generate_float_exclusive_guard(
          sb,
          name,
          "",
          exclusive_minimum,
          exclusive_maximum,
        )
      generate_float_multiple_of_guard(sb, name, "", multiple_of)
    }
    ArraySchema(min_items:, max_items:, unique_items:, ..) -> {
      let sb = generate_list_guard(sb, name, "", min_items, max_items)
      generate_unique_items_guard(sb, name, "", unique_items)
    }
    _ -> sb
  }
}

/// Generate a guard for a specific field based on its schema type and constraints.
fn generate_field_guard(
  sb: se.StringBuilder,
  schema_name: String,
  prop_name: String,
  prop_ref: SchemaRef,
  ctx: Context,
) -> se.StringBuilder {
  let resolved = case prop_ref {
    Inline(schema) -> Ok(schema)
    Reference(..) -> resolver.resolve_schema_ref(prop_ref, context.spec(ctx))
  }
  case resolved {
    Ok(StringSchema(min_length:, max_length:, pattern:, ..)) -> {
      let sb =
        generate_string_guard(
          sb,
          schema_name,
          prop_name,
          min_length,
          max_length,
        )
      generate_string_pattern_guard(sb, schema_name, prop_name, pattern)
    }
    Ok(IntegerSchema(
      minimum:,
      maximum:,
      exclusive_minimum:,
      exclusive_maximum:,
      multiple_of:,
      ..,
    )) -> {
      let sb =
        generate_integer_guard(sb, schema_name, prop_name, minimum, maximum)
      let sb =
        generate_integer_exclusive_guard(
          sb,
          schema_name,
          prop_name,
          exclusive_minimum,
          exclusive_maximum,
        )
      generate_integer_multiple_of_guard(
        sb,
        schema_name,
        prop_name,
        multiple_of,
      )
    }
    Ok(NumberSchema(
      minimum:,
      maximum:,
      exclusive_minimum:,
      exclusive_maximum:,
      multiple_of:,
      ..,
    )) -> {
      let sb =
        generate_float_guard(sb, schema_name, prop_name, minimum, maximum)
      let sb =
        generate_float_exclusive_guard(
          sb,
          schema_name,
          prop_name,
          exclusive_minimum,
          exclusive_maximum,
        )
      generate_float_multiple_of_guard(sb, schema_name, prop_name, multiple_of)
    }
    Ok(ArraySchema(min_items:, max_items:, unique_items:, ..)) -> {
      let sb =
        generate_list_guard(sb, schema_name, prop_name, min_items, max_items)
      generate_unique_items_guard(sb, schema_name, prop_name, unique_items)
    }
    _ -> sb
  }
}

/// Generate a string pattern validation guard.
fn generate_string_pattern_guard(
  sb: se.StringBuilder,
  schema_name: String,
  prop_name: String,
  pattern: Option(String),
) -> se.StringBuilder {
  case pattern {
    None -> sb
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
      sb
      |> se.line(
        "/// Validate string pattern for "
        <> schema_name
        <> field_label(prop_name)
        <> ".",
      )
      |> se.line(
        "pub fn "
        <> fn_name
        <> "(value: String) -> Result(String, ValidationFailure) {",
      )
      |> se.indent(1, "case regexp.from_string(" <> pattern_literal <> ") {")
      |> se.indent(2, "Ok(re) -> case regexp.check(re, value) {")
      |> se.indent(3, "True -> Ok(value)")
      |> se.indent(3, "False -> " <> mismatch_failure)
      |> se.indent(2, "}")
      |> se.indent(
        2,
        "Error(regexp.CompileError(error:, ..)) -> " <> invalid_pattern_failure,
      )
      |> se.indent(1, "}")
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Word used in minLength/maxLength error messages.
/// Singular when the bound is exactly one; plural otherwise.
fn character_word(n: Int) -> String {
  case n {
    1 -> "character"
    _ -> "characters"
  }
}

/// Generate a string length validation guard.
fn generate_string_guard(
  sb: se.StringBuilder,
  schema_name: String,
  prop_name: String,
  min_length: Option(Int),
  max_length: Option(Int),
) -> se.StringBuilder {
  case min_length, max_length {
    None, None -> sb
    _, _ -> {
      let fn_name = guard_function_name(schema_name, prop_name, "length")
      let min_failure = fn(min) {
        validation_failure_literal(
          prop_name,
          "minLength",
          "must be at least "
            <> int.to_string(min)
            <> " "
            <> character_word(min),
        )
      }
      let max_failure = fn(max) {
        validation_failure_literal(
          prop_name,
          "maxLength",
          "must be at most " <> int.to_string(max) <> " " <> character_word(max),
        )
      }
      let sb =
        sb
        |> se.line(
          "/// Validate string length for "
          <> schema_name
          <> field_label(prop_name)
          <> ".",
        )
      let sb =
        sb
        |> se.line(
          "pub fn "
          <> fn_name
          <> "(value: String) -> Result(String, ValidationFailure) {",
        )
      let sb = sb |> se.indent(1, "let len = string.length(value)")
      let sb = case min_length, max_length {
        Some(min), Some(max) ->
          sb
          |> se.indent(1, "case len < " <> int.to_string(min) <> " {")
          |> se.indent(2, "True -> " <> min_failure(min))
          |> se.indent(2, "False ->")
          |> se.indent(3, "case len > " <> int.to_string(max) <> " {")
          |> se.indent(4, "True -> " <> max_failure(max))
          |> se.indent(4, "False -> Ok(value)")
          |> se.indent(3, "}")
          |> se.indent(1, "}")
        Some(min), None ->
          sb
          |> se.indent(1, "case len < " <> int.to_string(min) <> " {")
          |> se.indent(2, "True -> " <> min_failure(min))
          |> se.indent(2, "False -> Ok(value)")
          |> se.indent(1, "}")
        None, Some(max) ->
          sb
          |> se.indent(1, "case len > " <> int.to_string(max) <> " {")
          |> se.indent(2, "True -> " <> max_failure(max))
          |> se.indent(2, "False -> Ok(value)")
          |> se.indent(1, "}")
        None, None -> sb
      }
      sb
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Generate an integer range validation guard.
fn generate_integer_guard(
  sb: se.StringBuilder,
  schema_name: String,
  prop_name: String,
  minimum: Option(Int),
  maximum: Option(Int),
) -> se.StringBuilder {
  case minimum, maximum {
    None, None -> sb
    _, _ -> {
      let fn_name = guard_function_name(schema_name, prop_name, "range")
      let min_failure = fn(min) {
        validation_failure_literal(
          prop_name,
          "minimum",
          "must be at least " <> int.to_string(min),
        )
      }
      let max_failure = fn(max) {
        validation_failure_literal(
          prop_name,
          "maximum",
          "must be at most " <> int.to_string(max),
        )
      }
      let sb =
        sb
        |> se.line(
          "/// Validate integer range for "
          <> schema_name
          <> field_label(prop_name)
          <> ".",
        )
      let sb =
        sb
        |> se.line(
          "pub fn "
          <> fn_name
          <> "(value: Int) -> Result(Int, ValidationFailure) {",
        )
      let sb = case minimum, maximum {
        Some(min), Some(max) ->
          sb
          |> se.indent(1, "case value < " <> int.to_string(min) <> " {")
          |> se.indent(2, "True -> " <> min_failure(min))
          |> se.indent(2, "False ->")
          |> se.indent(3, "case value > " <> int.to_string(max) <> " {")
          |> se.indent(4, "True -> " <> max_failure(max))
          |> se.indent(4, "False -> Ok(value)")
          |> se.indent(3, "}")
          |> se.indent(1, "}")
        Some(min), None ->
          sb
          |> se.indent(1, "case value < " <> int.to_string(min) <> " {")
          |> se.indent(2, "True -> " <> min_failure(min))
          |> se.indent(2, "False -> Ok(value)")
          |> se.indent(1, "}")
        None, Some(max) ->
          sb
          |> se.indent(1, "case value > " <> int.to_string(max) <> " {")
          |> se.indent(2, "True -> " <> max_failure(max))
          |> se.indent(2, "False -> Ok(value)")
          |> se.indent(1, "}")
        None, None -> sb
      }
      sb
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Generate a float range validation guard.
fn generate_float_guard(
  sb: se.StringBuilder,
  schema_name: String,
  prop_name: String,
  minimum: Option(Float),
  maximum: Option(Float),
) -> se.StringBuilder {
  case minimum, maximum {
    None, None -> sb
    _, _ -> {
      let fn_name = guard_function_name(schema_name, prop_name, "range")
      let min_failure = fn(min) {
        validation_failure_literal(
          prop_name,
          "minimum",
          "must be at least " <> float.to_string(min),
        )
      }
      let max_failure = fn(max) {
        validation_failure_literal(
          prop_name,
          "maximum",
          "must be at most " <> float.to_string(max),
        )
      }
      let sb =
        sb
        |> se.line(
          "/// Validate float range for "
          <> schema_name
          <> field_label(prop_name)
          <> ".",
        )
      let sb =
        sb
        |> se.line(
          "pub fn "
          <> fn_name
          <> "(value: Float) -> Result(Float, ValidationFailure) {",
        )
      let sb = case minimum, maximum {
        Some(min), Some(max) ->
          sb
          |> se.indent(1, "case value <. " <> float.to_string(min) <> " {")
          |> se.indent(2, "True -> " <> min_failure(min))
          |> se.indent(2, "False ->")
          |> se.indent(3, "case value >. " <> float.to_string(max) <> " {")
          |> se.indent(4, "True -> " <> max_failure(max))
          |> se.indent(4, "False -> Ok(value)")
          |> se.indent(3, "}")
          |> se.indent(1, "}")
        Some(min), None ->
          sb
          |> se.indent(1, "case value <. " <> float.to_string(min) <> " {")
          |> se.indent(2, "True -> " <> min_failure(min))
          |> se.indent(2, "False -> Ok(value)")
          |> se.indent(1, "}")
        None, Some(max) ->
          sb
          |> se.indent(1, "case value >. " <> float.to_string(max) <> " {")
          |> se.indent(2, "True -> " <> max_failure(max))
          |> se.indent(2, "False -> Ok(value)")
          |> se.indent(1, "}")
        None, None -> sb
      }
      sb
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Generate an integer exclusive range validation guard.
fn generate_integer_exclusive_guard(
  sb: se.StringBuilder,
  schema_name: String,
  prop_name: String,
  exclusive_minimum: Option(Int),
  exclusive_maximum: Option(Int),
) -> se.StringBuilder {
  case exclusive_minimum, exclusive_maximum {
    None, None -> sb
    _, _ -> {
      let fn_name =
        guard_function_name(schema_name, prop_name, "exclusive_range")
      let min_failure = fn(min) {
        validation_failure_literal(
          prop_name,
          "exclusiveMinimum",
          "must be greater than " <> int.to_string(min),
        )
      }
      let max_failure = fn(max) {
        validation_failure_literal(
          prop_name,
          "exclusiveMaximum",
          "must be less than " <> int.to_string(max),
        )
      }
      let sb =
        sb
        |> se.line(
          "/// Validate integer exclusive range for "
          <> schema_name
          <> field_label(prop_name)
          <> ".",
        )
      let sb =
        sb
        |> se.line(
          "pub fn "
          <> fn_name
          <> "(value: Int) -> Result(Int, ValidationFailure) {",
        )
      let sb = case exclusive_minimum, exclusive_maximum {
        Some(min), Some(max) ->
          sb
          |> se.indent(1, "case value > " <> int.to_string(min) <> " {")
          |> se.indent(2, "False -> " <> min_failure(min))
          |> se.indent(2, "True ->")
          |> se.indent(3, "case value < " <> int.to_string(max) <> " {")
          |> se.indent(4, "False -> " <> max_failure(max))
          |> se.indent(4, "True -> Ok(value)")
          |> se.indent(3, "}")
          |> se.indent(1, "}")
        Some(min), None ->
          sb
          |> se.indent(1, "case value > " <> int.to_string(min) <> " {")
          |> se.indent(2, "False -> " <> min_failure(min))
          |> se.indent(2, "True -> Ok(value)")
          |> se.indent(1, "}")
        None, Some(max) ->
          sb
          |> se.indent(1, "case value < " <> int.to_string(max) <> " {")
          |> se.indent(2, "False -> " <> max_failure(max))
          |> se.indent(2, "True -> Ok(value)")
          |> se.indent(1, "}")
        None, None -> sb
      }
      sb
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Generate an integer multipleOf validation guard.
fn generate_integer_multiple_of_guard(
  sb: se.StringBuilder,
  schema_name: String,
  prop_name: String,
  multiple_of: Option(Int),
) -> se.StringBuilder {
  case multiple_of {
    None -> sb
    Some(m) -> {
      let fn_name = guard_function_name(schema_name, prop_name, "multiple_of")
      let failure =
        validation_failure_literal(
          prop_name,
          "multipleOf",
          "must be a multiple of " <> int.to_string(m),
        )
      sb
      |> se.line(
        "/// Validate integer multipleOf for "
        <> schema_name
        <> field_label(prop_name)
        <> ".",
      )
      |> se.line(
        "pub fn "
        <> fn_name
        <> "(value: Int) -> Result(Int, ValidationFailure) {",
      )
      |> se.indent(1, "case value % " <> int.to_string(m) <> " == 0 {")
      |> se.indent(2, "False -> " <> failure)
      |> se.indent(2, "True -> Ok(value)")
      |> se.indent(1, "}")
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Generate a float exclusive range validation guard.
fn generate_float_exclusive_guard(
  sb: se.StringBuilder,
  schema_name: String,
  prop_name: String,
  exclusive_minimum: Option(Float),
  exclusive_maximum: Option(Float),
) -> se.StringBuilder {
  case exclusive_minimum, exclusive_maximum {
    None, None -> sb
    _, _ -> {
      let fn_name =
        guard_function_name(schema_name, prop_name, "exclusive_range")
      let min_failure = fn(min) {
        validation_failure_literal(
          prop_name,
          "exclusiveMinimum",
          "must be greater than " <> float.to_string(min),
        )
      }
      let max_failure = fn(max) {
        validation_failure_literal(
          prop_name,
          "exclusiveMaximum",
          "must be less than " <> float.to_string(max),
        )
      }
      let sb =
        sb
        |> se.line(
          "/// Validate float exclusive range for "
          <> schema_name
          <> field_label(prop_name)
          <> ".",
        )
      let sb =
        sb
        |> se.line(
          "pub fn "
          <> fn_name
          <> "(value: Float) -> Result(Float, ValidationFailure) {",
        )
      let sb = case exclusive_minimum, exclusive_maximum {
        Some(min), Some(max) ->
          sb
          |> se.indent(1, "case value >. " <> float.to_string(min) <> " {")
          |> se.indent(2, "False -> " <> min_failure(min))
          |> se.indent(2, "True ->")
          |> se.indent(3, "case value <. " <> float.to_string(max) <> " {")
          |> se.indent(4, "False -> " <> max_failure(max))
          |> se.indent(4, "True -> Ok(value)")
          |> se.indent(3, "}")
          |> se.indent(1, "}")
        Some(min), None ->
          sb
          |> se.indent(1, "case value >. " <> float.to_string(min) <> " {")
          |> se.indent(2, "False -> " <> min_failure(min))
          |> se.indent(2, "True -> Ok(value)")
          |> se.indent(1, "}")
        None, Some(max) ->
          sb
          |> se.indent(1, "case value <. " <> float.to_string(max) <> " {")
          |> se.indent(2, "False -> " <> max_failure(max))
          |> se.indent(2, "True -> Ok(value)")
          |> se.indent(1, "}")
        None, None -> sb
      }
      sb
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Generate a float multipleOf validation guard.
fn generate_float_multiple_of_guard(
  sb: se.StringBuilder,
  schema_name: String,
  prop_name: String,
  multiple_of: Option(Float),
) -> se.StringBuilder {
  case multiple_of {
    None -> sb
    Some(m) -> {
      let fn_name = guard_function_name(schema_name, prop_name, "multiple_of")
      let failure =
        validation_failure_literal(
          prop_name,
          "multipleOf",
          "must be a multiple of " <> float.to_string(m),
        )
      sb
      |> se.line(
        "/// Validate float multipleOf for "
        <> schema_name
        <> field_label(prop_name)
        <> ".",
      )
      |> se.line(
        "pub fn "
        <> fn_name
        <> "(value: Float) -> Result(Float, ValidationFailure) {",
      )
      |> se.indent(
        1,
        "let remainder = value -. float.truncate(value /. "
          <> float.to_string(m)
          <> " |> int.to_float) *. "
          <> float.to_string(m),
      )
      |> se.indent(1, "case remainder == 0.0 || remainder == -0.0 {")
      |> se.indent(2, "False -> " <> failure)
      |> se.indent(2, "True -> Ok(value)")
      |> se.indent(1, "}")
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Generate a list length validation guard.
fn generate_list_guard(
  sb: se.StringBuilder,
  schema_name: String,
  prop_name: String,
  min_items: Option(Int),
  max_items: Option(Int),
) -> se.StringBuilder {
  case min_items, max_items {
    None, None -> sb
    _, _ -> {
      let fn_name = guard_function_name(schema_name, prop_name, "length")
      let min_failure = fn(min) {
        validation_failure_literal(
          prop_name,
          "minItems",
          "must have at least " <> int.to_string(min) <> " items",
        )
      }
      let max_failure = fn(max) {
        validation_failure_literal(
          prop_name,
          "maxItems",
          "must have at most " <> int.to_string(max) <> " items",
        )
      }
      let sb =
        sb
        |> se.line(
          "/// Validate list length for "
          <> schema_name
          <> field_label(prop_name)
          <> ".",
        )
      let sb =
        sb
        |> se.line(
          "pub fn "
          <> fn_name
          <> "(value: List(a)) -> Result(List(a), ValidationFailure) {",
        )
      let sb =
        sb
        |> se.indent(1, "let len = list.length(value)")
      let sb = case min_items, max_items {
        Some(min), Some(max) ->
          sb
          |> se.indent(1, "case len < " <> int.to_string(min) <> " {")
          |> se.indent(2, "True -> " <> min_failure(min))
          |> se.indent(2, "False ->")
          |> se.indent(3, "case len > " <> int.to_string(max) <> " {")
          |> se.indent(4, "True -> " <> max_failure(max))
          |> se.indent(4, "False -> Ok(value)")
          |> se.indent(3, "}")
          |> se.indent(1, "}")
        Some(min), None ->
          sb
          |> se.indent(1, "case len < " <> int.to_string(min) <> " {")
          |> se.indent(2, "True -> " <> min_failure(min))
          |> se.indent(2, "False -> Ok(value)")
          |> se.indent(1, "}")
        None, Some(max) ->
          sb
          |> se.indent(1, "case len > " <> int.to_string(max) <> " {")
          |> se.indent(2, "True -> " <> max_failure(max))
          |> se.indent(2, "False -> Ok(value)")
          |> se.indent(1, "}")
        None, None -> sb
      }
      sb
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Generate a uniqueItems validation guard.
fn generate_unique_items_guard(
  sb: se.StringBuilder,
  schema_name: String,
  prop_name: String,
  unique_items: Bool,
) -> se.StringBuilder {
  use <- bool.guard(!unique_items, sb)
  let fn_name = guard_function_name(schema_name, prop_name, "unique")
  let failure =
    validation_failure_literal(prop_name, "uniqueItems", "items must be unique")
  sb
  |> se.line(
    "/// Validate unique items for "
    <> schema_name
    <> field_label(prop_name)
    <> ".",
  )
  |> se.line(
    "pub fn "
    <> fn_name
    <> "(value: List(a)) -> Result(List(a), ValidationFailure) {",
  )
  |> se.indent(
    1,
    "case list.length(value) == list.length(list.unique(value)) {",
  )
  |> se.indent(2, "True -> Ok(value)")
  |> se.indent(2, "False -> " <> failure)
  |> se.indent(1, "}")
  |> se.line("}")
  |> se.blank_line()
}

/// Generate a minProperties/maxProperties validation guard for objects.
fn generate_properties_count_guard(
  sb: se.StringBuilder,
  schema_name: String,
  prop_name: String,
  min_properties: Option(Int),
  max_properties: Option(Int),
) -> se.StringBuilder {
  case min_properties, max_properties {
    None, None -> sb
    _, _ -> {
      let fn_name = guard_function_name(schema_name, prop_name, "properties")
      let min_failure = fn(min) {
        validation_failure_literal(
          prop_name,
          "minProperties",
          "must have at least " <> int.to_string(min) <> " properties",
        )
      }
      let max_failure = fn(max) {
        validation_failure_literal(
          prop_name,
          "maxProperties",
          "must have at most " <> int.to_string(max) <> " properties",
        )
      }
      let sb =
        sb
        |> se.line(
          "/// Validate property count for "
          <> schema_name
          <> field_label(prop_name)
          <> ".",
        )
        |> se.line(
          "pub fn "
          <> fn_name
          <> "(value: Dict(k, v)) -> Result(Dict(k, v), ValidationFailure) {",
        )
        |> se.indent(1, "let count = dict.size(value)")
      let sb = case min_properties, max_properties {
        Some(min), Some(max) ->
          sb
          |> se.indent(1, "case count < " <> int.to_string(min) <> " {")
          |> se.indent(2, "True -> " <> min_failure(min))
          |> se.indent(2, "False ->")
          |> se.indent(3, "case count > " <> int.to_string(max) <> " {")
          |> se.indent(4, "True -> " <> max_failure(max))
          |> se.indent(4, "False -> Ok(value)")
          |> se.indent(3, "}")
          |> se.indent(1, "}")
        Some(min), None ->
          sb
          |> se.indent(1, "case count < " <> int.to_string(min) <> " {")
          |> se.indent(2, "True -> " <> min_failure(min))
          |> se.indent(2, "False -> Ok(value)")
          |> se.indent(1, "}")
        None, Some(max) ->
          sb
          |> se.indent(1, "case count > " <> int.to_string(max) <> " {")
          |> se.indent(2, "True -> " <> max_failure(max))
          |> se.indent(2, "False -> Ok(value)")
          |> se.indent(1, "}")
        None, None -> sb
      }
      sb
      |> se.line("}")
      |> se.blank_line()
    }
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
    "" -> "validate_" <> base <> "_" <> constraint
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

/// Generate a composite validate function for a schema that calls all
/// individual field validators. This enables auto-validation by calling
/// a single function rather than individual field guards.
fn generate_composite_validator(
  sb: se.StringBuilder,
  name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> se.StringBuilder {
  let guard_calls = collect_guard_calls(name, schema_ref, ctx)
  case list.is_empty(guard_calls) {
    True -> sb
    False -> {
      let fn_name = "validate_" <> naming.to_snake_case(name)
      let type_name = naming.schema_to_type_name(name)
      let gleam_type = composite_validator_type(name, schema_ref, ctx)
      let sb =
        sb
        |> se.doc_comment("Validate all constraints for " <> type_name <> ".")
        |> se.doc_comment(
          "Auto-calls all field validators and collects failures.",
        )
        |> se.line(
          "pub fn "
          <> fn_name
          <> "(value: "
          <> gleam_type
          <> ") -> Result("
          <> gleam_type
          <> ", List(ValidationFailure)) {",
        )
        |> se.indent(1, "let errors = []")
      let sb =
        list.fold(guard_calls, sb, fn(sb, call) {
          let #(guard_fn, accessor, is_required) = call
          case is_required {
            True ->
              sb
              |> se.indent(
                1,
                "let errors = case " <> guard_fn <> "(" <> accessor <> ") {",
              )
              |> se.indent(2, "Ok(_) -> errors")
              |> se.indent(2, "Error(failure) -> [failure, ..errors]")
              |> se.indent(1, "}")
            False ->
              sb
              |> se.indent(1, "let errors = case " <> accessor <> " {")
              |> se.indent(2, "option.Some(v) -> case " <> guard_fn <> "(v) {")
              |> se.indent(3, "Ok(_) -> errors")
              |> se.indent(3, "Error(failure) -> [failure, ..errors]")
              |> se.indent(2, "}")
              |> se.indent(2, "option.None -> errors")
              |> se.indent(1, "}")
          }
        })
      sb
      |> se.indent(1, "case errors {")
      |> se.indent(2, "[] -> Ok(value)")
      |> se.indent(2, "_ -> Error(errors)")
      |> se.indent(1, "}")
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Determine the Gleam type for the composite validator parameter.
fn composite_validator_type(
  name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> String {
  let schema = case schema_ref {
    Inline(s) -> Ok(s)
    Reference(..) -> resolver.resolve_schema_ref(schema_ref, context.spec(ctx))
  }
  case schema {
    Ok(ObjectSchema(..)) | Ok(AllOfSchema(..)) ->
      "types." <> naming.schema_to_type_name(name)
    Ok(s) -> {
      type_gen.schema_to_gleam_type(s, ctx)
    }
    _ -> "types." <> naming.schema_to_type_name(name)
  }
}

/// A guard call with metadata about whether the field is optional.
/// #(guard_fn_name, accessor_expr, is_optional)
type GuardCall =
  #(String, String, Bool)

/// Collect all guard function calls for a schema's constrained fields.
fn collect_guard_calls(
  name: String,
  schema_ref: SchemaRef,
  ctx: Context,
) -> List(GuardCall) {
  let schema = case schema_ref {
    Inline(s) -> Ok(s)
    Reference(..) -> resolver.resolve_schema_ref(schema_ref, context.spec(ctx))
  }
  case schema {
    Ok(ObjectSchema(
      properties:,
      required:,
      min_properties:,
      max_properties:,
      ..,
    )) -> {
      let prop_calls =
        ir_build.sorted_entries(properties)
        |> list.flat_map(fn(entry) {
          let #(prop_name, prop_ref) = entry
          let is_required = list.contains(required, prop_name)
          collect_field_guard_calls(name, prop_name, prop_ref, is_required, ctx)
        })
      let size_calls = case min_properties, max_properties {
        None, None -> []
        _, _ -> [
          #(guard_function_name(name, "", "properties"), "value", True),
        ]
      }
      list.append(prop_calls, size_calls)
    }
    Ok(AllOfSchema(schemas:, ..)) -> {
      let merged = allof_merge.merge_allof_schemas(schemas, ctx)
      ir_build.sorted_entries(merged.properties)
      |> list.flat_map(fn(entry) {
        let #(prop_name, prop_ref) = entry
        let is_required = list.contains(merged.required, prop_name)
        collect_field_guard_calls(name, prop_name, prop_ref, is_required, ctx)
      })
    }
    Ok(StringSchema(min_length:, max_length:, pattern:, ..)) -> {
      let calls = case min_length, max_length {
        None, None -> []
        _, _ -> [
          #(guard_function_name(name, "", "length"), "value", True),
        ]
      }
      case pattern {
        None -> calls
        Some(_) ->
          list.append(calls, [
            #(guard_function_name(name, "", "pattern"), "value", True),
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
          #(guard_function_name(name, "", "range"), "value", True),
        ]
      }
      let calls = case exclusive_minimum, exclusive_maximum {
        None, None -> calls
        _, _ ->
          list.append(calls, [
            #(guard_function_name(name, "", "exclusive_range"), "value", True),
          ])
      }
      case multiple_of {
        None -> calls
        Some(_) ->
          list.append(calls, [
            #(guard_function_name(name, "", "multiple_of"), "value", True),
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
          #(guard_function_name(name, "", "range"), "value", True),
        ]
      }
      let calls = case exclusive_minimum, exclusive_maximum {
        None, None -> calls
        _, _ ->
          list.append(calls, [
            #(guard_function_name(name, "", "exclusive_range"), "value", True),
          ])
      }
      case multiple_of {
        None -> calls
        Some(_) ->
          list.append(calls, [
            #(guard_function_name(name, "", "multiple_of"), "value", True),
          ])
      }
    }
    Ok(ArraySchema(min_items:, max_items:, unique_items:, ..)) -> {
      let length_calls = case min_items, max_items {
        None, None -> []
        _, _ -> [
          #(guard_function_name(name, "", "length"), "value", True),
        ]
      }
      let unique_calls = case unique_items {
        True -> [
          #(guard_function_name(name, "", "unique"), "value", True),
        ]
        False -> []
      }
      list.append(length_calls, unique_calls)
    }
    _ -> []
  }
}

/// Collect guard calls for a single field.
fn collect_field_guard_calls(
  schema_name: String,
  prop_name: String,
  prop_ref: SchemaRef,
  is_required: Bool,
  ctx: Context,
) -> List(GuardCall) {
  let resolved = case prop_ref {
    Inline(schema) -> Ok(schema)
    Reference(..) -> resolver.resolve_schema_ref(prop_ref, context.spec(ctx))
  }
  let accessor = "value." <> naming.to_snake_case(prop_name)
  case resolved {
    Ok(StringSchema(min_length:, max_length:, pattern:, ..)) -> {
      let calls = case min_length, max_length {
        None, None -> []
        _, _ -> [
          #(
            guard_function_name(schema_name, prop_name, "length"),
            accessor,
            is_required,
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
            ),
          ])
      }
    }
    Ok(ArraySchema(min_items:, max_items:, unique_items:, ..)) -> {
      let length_calls = case min_items, max_items {
        None, None -> []
        _, _ -> [
          #(
            guard_function_name(schema_name, prop_name, "length"),
            accessor,
            is_required,
          ),
        ]
      }
      let unique_calls = case unique_items {
        True -> [
          #(
            guard_function_name(schema_name, prop_name, "unique"),
            accessor,
            is_required,
          ),
        ]
        False -> []
      }
      list.append(length_calls, unique_calls)
    }
    _ -> []
  }
}
