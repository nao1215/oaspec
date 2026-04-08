import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import oaspec/codegen/context.{type Context, type GeneratedFile, GeneratedFile}
import oaspec/openapi/resolver
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, ArraySchema, Inline,
  IntegerSchema, NumberSchema, ObjectSchema, Reference, StringSchema,
}
import oaspec/util/naming
import oaspec/util/string_extra as se

/// Generate guard/validation functions from OpenAPI schemas that have constraints.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let content = generate_guards(ctx)
  case string.contains(content, "pub fn validate_") {
    True -> [GeneratedFile(path: "guards.gleam", content: content)]
    False -> []
  }
}

/// Generate validation guard functions for schemas with constraints.
fn generate_guards(ctx: Context) -> String {
  let schemas = case ctx.spec.components {
    Some(components) ->
      list.sort(dict.to_list(components.schemas), fn(a, b) {
        string.compare(a.0, b.0)
      })
    None -> []
  }

  // Determine which imports are needed based on constraint types present.
  // Generated guard functions use string/list.length for validation;
  // constraint values (min/max) are baked as literals at generation time,
  // so gleam/int and gleam/float are NOT needed in the generated output.
  let constraint_types = collect_constraint_types(schemas, ctx)
  let imports = []
  let imports = case constraint_types.has_string {
    True -> ["gleam/string", ..imports]
    False -> imports
  }
  let imports = case constraint_types.has_list {
    True -> ["gleam/list", ..imports]
    False -> imports
  }

  let sb =
    se.file_header(context.version)
    |> se.imports(imports)

  let sb =
    list.fold(schemas, sb, fn(sb, entry) {
      let #(name, schema_ref) = entry
      generate_guards_for_schema(sb, name, schema_ref, ctx)
    })

  se.to_string(sb)
}

/// Track which constraint types exist in the schema set.
type ConstraintTypes {
  ConstraintTypes(
    has_string: Bool,
    has_integer: Bool,
    has_float: Bool,
    has_list: Bool,
  )
}

/// Scan all schemas to find which constraint types are present.
fn collect_constraint_types(
  schemas: List(#(String, SchemaRef)),
  ctx: Context,
) -> ConstraintTypes {
  list.fold(
    schemas,
    ConstraintTypes(False, False, False, False),
    fn(acc, entry) {
      let #(_name, schema_ref) = entry
      collect_schema_constraint_types(acc, schema_ref, ctx)
    },
  )
}

/// Collect constraint types from a single schema ref.
fn collect_schema_constraint_types(
  acc: ConstraintTypes,
  schema_ref: SchemaRef,
  ctx: Context,
) -> ConstraintTypes {
  let schema = case schema_ref {
    Inline(s) -> Ok(s)
    Reference(_) -> resolver.resolve_schema_ref(schema_ref, ctx.spec)
  }
  case schema {
    Ok(StringSchema(min_length: Some(_), ..))
    | Ok(StringSchema(max_length: Some(_), ..)) ->
      ConstraintTypes(..acc, has_string: True)
    Ok(IntegerSchema(minimum: Some(_), ..))
    | Ok(IntegerSchema(maximum: Some(_), ..)) ->
      ConstraintTypes(..acc, has_integer: True)
    Ok(NumberSchema(minimum: Some(_), ..))
    | Ok(NumberSchema(maximum: Some(_), ..)) ->
      ConstraintTypes(..acc, has_float: True)
    Ok(ArraySchema(min_items: Some(_), ..))
    | Ok(ArraySchema(max_items: Some(_), ..)) ->
      ConstraintTypes(..acc, has_list: True)
    Ok(ObjectSchema(properties:, ..)) ->
      dict.to_list(properties)
      |> list.fold(acc, fn(a, prop) {
        let #(_, prop_ref) = prop
        collect_schema_constraint_types(a, prop_ref, ctx)
      })
    Ok(AllOfSchema(schemas:, ..)) ->
      list.fold(schemas, acc, fn(a, s) {
        collect_schema_constraint_types(a, s, ctx)
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
    Reference(ref:) -> {
      let resolved_name = resolver.ref_to_name(ref)
      case resolver.resolve_schema_ref(schema_ref, ctx.spec) {
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
    ObjectSchema(properties:, ..) -> {
      let props = dict.to_list(properties)
      list.fold(props, sb, fn(sb, entry) {
        let #(prop_name, prop_ref) = entry
        generate_field_guard(sb, name, prop_name, prop_ref, ctx)
      })
    }
    AllOfSchema(schemas:, ..) -> {
      let merged_props =
        list.fold(schemas, dict.new(), fn(acc, s_ref) {
          case s_ref {
            Inline(ObjectSchema(properties:, ..)) -> dict.merge(acc, properties)
            Reference(_) ->
              case resolver.resolve_schema_ref(s_ref, ctx.spec) {
                Ok(ObjectSchema(properties:, ..)) -> dict.merge(acc, properties)
                _ -> acc
              }
            _ -> acc
          }
        })
      let props = dict.to_list(merged_props)
      list.fold(props, sb, fn(sb, entry) {
        let #(prop_name, prop_ref) = entry
        generate_field_guard(sb, name, prop_name, prop_ref, ctx)
      })
    }
    // Top-level string/integer constraints (type aliases with constraints)
    StringSchema(min_length:, max_length:, ..) ->
      generate_string_guard(sb, name, "", min_length, max_length)
    IntegerSchema(minimum:, maximum:, ..) ->
      generate_integer_guard(sb, name, "", minimum, maximum)
    NumberSchema(minimum:, maximum:, ..) ->
      generate_float_guard(sb, name, "", minimum, maximum)
    ArraySchema(min_items:, max_items:, ..) ->
      generate_list_guard(sb, name, "", min_items, max_items)
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
    Reference(_) -> resolver.resolve_schema_ref(prop_ref, ctx.spec)
  }
  case resolved {
    Ok(StringSchema(min_length:, max_length:, ..)) ->
      generate_string_guard(sb, schema_name, prop_name, min_length, max_length)
    Ok(IntegerSchema(minimum:, maximum:, ..)) ->
      generate_integer_guard(sb, schema_name, prop_name, minimum, maximum)
    Ok(NumberSchema(minimum:, maximum:, ..)) ->
      generate_float_guard(sb, schema_name, prop_name, minimum, maximum)
    Ok(ArraySchema(min_items:, max_items:, ..)) ->
      generate_list_guard(sb, schema_name, prop_name, min_items, max_items)
    _ -> sb
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
          "pub fn " <> fn_name <> "(value: String) -> Result(String, String) {",
        )
      let sb = sb |> se.indent(1, "let len = string.length(value)")
      let sb = case min_length, max_length {
        Some(min), Some(max) ->
          sb
          |> se.indent(1, "case len < " <> int.to_string(min) <> " {")
          |> se.indent(
            2,
            "True -> Error(\"must be at least "
              <> int.to_string(min)
              <> " characters\")",
          )
          |> se.indent(2, "False ->")
          |> se.indent(3, "case len > " <> int.to_string(max) <> " {")
          |> se.indent(
            4,
            "True -> Error(\"must be at most "
              <> int.to_string(max)
              <> " characters\")",
          )
          |> se.indent(4, "False -> Ok(value)")
          |> se.indent(3, "}")
          |> se.indent(1, "}")
        Some(min), None ->
          sb
          |> se.indent(1, "case len < " <> int.to_string(min) <> " {")
          |> se.indent(
            2,
            "True -> Error(\"must be at least "
              <> int.to_string(min)
              <> " characters\")",
          )
          |> se.indent(2, "False -> Ok(value)")
          |> se.indent(1, "}")
        None, Some(max) ->
          sb
          |> se.indent(1, "case len > " <> int.to_string(max) <> " {")
          |> se.indent(
            2,
            "True -> Error(\"must be at most "
              <> int.to_string(max)
              <> " characters\")",
          )
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
          "pub fn " <> fn_name <> "(value: Int) -> Result(Int, String) {",
        )
      let sb = case minimum, maximum {
        Some(min), Some(max) ->
          sb
          |> se.indent(1, "case value < " <> int.to_string(min) <> " {")
          |> se.indent(
            2,
            "True -> Error(\"must be at least " <> int.to_string(min) <> "\")",
          )
          |> se.indent(2, "False ->")
          |> se.indent(3, "case value > " <> int.to_string(max) <> " {")
          |> se.indent(
            4,
            "True -> Error(\"must be at most " <> int.to_string(max) <> "\")",
          )
          |> se.indent(4, "False -> Ok(value)")
          |> se.indent(3, "}")
          |> se.indent(1, "}")
        Some(min), None ->
          sb
          |> se.indent(1, "case value < " <> int.to_string(min) <> " {")
          |> se.indent(
            2,
            "True -> Error(\"must be at least " <> int.to_string(min) <> "\")",
          )
          |> se.indent(2, "False -> Ok(value)")
          |> se.indent(1, "}")
        None, Some(max) ->
          sb
          |> se.indent(1, "case value > " <> int.to_string(max) <> " {")
          |> se.indent(
            2,
            "True -> Error(\"must be at most " <> int.to_string(max) <> "\")",
          )
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
          "pub fn " <> fn_name <> "(value: Float) -> Result(Float, String) {",
        )
      let sb = case minimum, maximum {
        Some(min), Some(max) ->
          sb
          |> se.indent(1, "case value <. " <> float.to_string(min) <> " {")
          |> se.indent(
            2,
            "True -> Error(\"must be at least " <> float.to_string(min) <> "\")",
          )
          |> se.indent(2, "False ->")
          |> se.indent(3, "case value >. " <> float.to_string(max) <> " {")
          |> se.indent(
            4,
            "True -> Error(\"must be at most " <> float.to_string(max) <> "\")",
          )
          |> se.indent(4, "False -> Ok(value)")
          |> se.indent(3, "}")
          |> se.indent(1, "}")
        Some(min), None ->
          sb
          |> se.indent(1, "case value <. " <> float.to_string(min) <> " {")
          |> se.indent(
            2,
            "True -> Error(\"must be at least " <> float.to_string(min) <> "\")",
          )
          |> se.indent(2, "False -> Ok(value)")
          |> se.indent(1, "}")
        None, Some(max) ->
          sb
          |> se.indent(1, "case value >. " <> float.to_string(max) <> " {")
          |> se.indent(
            2,
            "True -> Error(\"must be at most " <> float.to_string(max) <> "\")",
          )
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
          <> "(value: List(a)) -> Result(List(a), String) {",
        )
      let sb =
        sb
        |> se.indent(1, "let len = list.length(value)")
      let sb = case min_items, max_items {
        Some(min), Some(max) ->
          sb
          |> se.indent(1, "case len < " <> int.to_string(min) <> " {")
          |> se.indent(
            2,
            "True -> Error(\"must have at least "
              <> int.to_string(min)
              <> " items\")",
          )
          |> se.indent(2, "False ->")
          |> se.indent(3, "case len > " <> int.to_string(max) <> " {")
          |> se.indent(
            4,
            "True -> Error(\"must have at most "
              <> int.to_string(max)
              <> " items\")",
          )
          |> se.indent(4, "False -> Ok(value)")
          |> se.indent(3, "}")
          |> se.indent(1, "}")
        Some(min), None ->
          sb
          |> se.indent(1, "case len < " <> int.to_string(min) <> " {")
          |> se.indent(
            2,
            "True -> Error(\"must have at least "
              <> int.to_string(min)
              <> " items\")",
          )
          |> se.indent(2, "False -> Ok(value)")
          |> se.indent(1, "}")
        None, Some(max) ->
          sb
          |> se.indent(1, "case len > " <> int.to_string(max) <> " {")
          |> se.indent(
            2,
            "True -> Error(\"must have at most "
              <> int.to_string(max)
              <> " items\")",
          )
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
