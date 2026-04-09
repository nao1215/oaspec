/// Renderer for Gleam Code IR -> source text.
/// Pure function: takes IR, produces String. No IO.
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oaspec/codegen/context
import oaspec/codegen/ir.{
  type Declaration, type Module, type TypeDef, EnumType, RecordType, TypeAlias,
  UnionType, VariantEmpty, VariantWithType,
}
import oaspec/util/string_extra as se

/// Render a complete IR Module to a Gleam source string.
pub fn render(module: Module) -> String {
  let sb =
    se.file_header(context.version)
    |> se.imports(module.imports)

  let sb =
    list.fold(module.declarations, sb, fn(sb, decl) {
      render_declaration(sb, decl)
    })

  se.to_string(sb)
}

/// Render a single declaration (doc comment + type definition).
fn render_declaration(
  sb: se.StringBuilder,
  decl: Declaration,
) -> se.StringBuilder {
  let sb = case decl.doc {
    Some(doc) -> sb |> se.doc_comment(doc)
    None -> sb
  }
  render_type_def(sb, decl.type_def)
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
