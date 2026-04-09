/// Gleam Code IR - intermediate representation for generated Gleam source files.
/// This separates schema semantics from text rendering, preventing the
/// duplication of logic across types/decoders/client generators.
import gleam/option.{type Option}

/// A complete generated Gleam source file.
pub type Module {
  Module(header: String, imports: List(String), declarations: List(Declaration))
}

/// A top-level declaration with optional doc comment.
pub type Declaration {
  Declaration(doc: Option(String), type_def: TypeDef)
}

/// The shapes of type definition that the OpenAPI generator produces.
pub type TypeDef {
  /// `pub type Foo = Bar`
  TypeAlias(name: String, target: String)
  /// `pub type Foo { Foo(field1: Type1, field2: Type2) }`
  RecordType(name: String, fields: List(Field))
  /// `pub type Foo { FooBar(Bar) FooBaz(Baz) }`
  UnionType(name: String, variants: List(Variant))
  /// `pub type Status { StatusActive StatusInactive }`
  EnumType(name: String, variants: List(String))
}

/// A named, typed field in a record constructor.
pub type Field {
  Field(name: String, type_expr: String)
}

/// A variant in a union type.
pub type Variant {
  /// Variant with a wrapped type: `FooBar(Bar)`
  VariantWithType(name: String, inner_type: String)
  /// Variant with no payload: `FooNone`
  VariantEmpty(name: String)
}
