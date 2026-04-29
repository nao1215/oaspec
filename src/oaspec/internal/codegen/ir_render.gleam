/// Renderer for Gleam Code IR -> source text.
/// Pure function: takes IR, produces String. No IO.
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oaspec/internal/codegen/context
import oaspec/internal/codegen/ir.{
  type Declaration, type Module, type TypeDef, EnumType, RecordType, TypeAlias,
  UnionType, VariantEmpty, VariantWithHeaders, VariantWithType,
  VariantWithTypeAndHeaders,
}
import oaspec/internal/util/string_extra as se

/// Render a complete IR Module to a Gleam source string.
pub fn render(module: Module) -> String {
  let sb =
    se.file_header(context.version)
    |> se.imports(ir.module_imports(module))

  let sb =
    list.fold(ir.module_declarations(module), sb, fn(sb, decl) {
      render_declaration(sb, decl)
    })

  let sb =
    list.fold(ir.module_header_records(module), sb, fn(sb, rec) {
      render_header_record(sb, rec)
    })

  se.to_string(sb)
}

/// Render a single declaration (doc comment + type definition).
fn render_declaration(
  sb: se.StringBuilder,
  decl: Declaration,
) -> se.StringBuilder {
  let sb = case ir.declaration_doc(decl) {
    Some(doc) -> sb |> se.doc_comment(doc)
    None -> sb
  }
  render_type_def(sb, ir.declaration_type_def(decl))
}

/// Render a type definition to Gleam source.
fn render_type_def(sb: se.StringBuilder, type_def: TypeDef) -> se.StringBuilder {
  case type_def {
    TypeAlias(name:, target:) ->
      sb
      |> se.line("pub type " <> name <> " = " <> target)
      |> se.blank_line()

    RecordType(name:, fields:) -> {
      let sb = sb |> se.line("pub type " <> name <> " {")
      let field_strs = list.map(fields, fn(f) { f.name <> ": " <> f.type_expr })
      let sb =
        sb
        |> se.indent(1, name <> "(" <> string.join(field_strs, ", ") <> ")")
      sb
      |> se.line("}")
      |> se.blank_line()
    }

    UnionType(name:, variants:) -> {
      let sb = sb |> se.line("pub type " <> name <> " {")
      let sb =
        list.fold(variants, sb, fn(sb, variant) {
          case variant {
            VariantWithType(name: vname, inner_type:) ->
              sb |> se.indent(1, vname <> "(" <> inner_type <> ")")
            VariantEmpty(name: vname) -> sb |> se.indent(1, vname)
            VariantWithTypeAndHeaders(name: vname, inner_type:, headers_type:) ->
              sb
              |> se.indent(
                1,
                vname <> "(" <> inner_type <> ", " <> headers_type <> ")",
              )
            VariantWithHeaders(name: vname, headers_type:) ->
              sb |> se.indent(1, vname <> "(" <> headers_type <> ")")
          }
        })
      sb
      |> se.line("}")
      |> se.blank_line()
    }

    EnumType(name:, variants:) -> {
      let sb = sb |> se.line("pub type " <> name <> " {")
      let sb =
        list.fold(variants, sb, fn(sb, variant_name) {
          sb |> se.indent(1, variant_name)
        })
      sb
      |> se.line("}")
      |> se.blank_line()
    }
  }
}

/// Render a response header record type.
fn render_header_record(
  sb: se.StringBuilder,
  rec: ir.ResponseHeaderRecord,
) -> se.StringBuilder {
  let name = rec.name
  let field_strs = list.map(rec.fields, fn(f) { f.name <> ": " <> f.type_expr })
  sb
  |> se.line("pub type " <> name <> " {")
  |> se.indent(1, name <> "(" <> string.join(field_strs, ", ") <> ")")
  |> se.line("}")
  |> se.blank_line()
}
