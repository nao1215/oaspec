import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import oaspec/capability
import oaspec/codegen/validate.{
  type ValidationError, SeverityError, SeverityWarning, TargetBoth, TargetClient,
  ValidationError,
}
import oaspec/openapi/schema.{
  type SchemaObject, type SchemaRef, AllOfSchema, AnyOfSchema, ArraySchema,
  Inline, ObjectSchema, OneOfSchema, Reference,
}
import oaspec/openapi/spec.{type OpenApiSpec, ConcreteEntry}

/// Run capability checks on a resolved spec.
/// Returns errors for unsupported features and warnings for parsed-but-unused features.
pub fn check(spec: OpenApiSpec) -> List(ValidationError) {
  let schema_errors = check_schemas(spec)
  let security_errors = check_security_schemes(spec)
  let scope_warnings = check_scope(spec)
  list.flatten([schema_errors, security_errors, scope_warnings])
}

/// Check all schemas for unsupported keywords stored during lossless parse.
fn check_schemas(spec: OpenApiSpec) -> List(ValidationError) {
  case spec.components {
    None -> []
    Some(components) ->
      dict.to_list(components.schemas)
      |> list.flat_map(fn(entry) {
        let #(name, schema_ref) = entry
        check_schema_ref("components.schemas." <> name, schema_ref)
      })
  }
}

/// Check a SchemaRef recursively for unsupported keywords.
fn check_schema_ref(path: String, ref: SchemaRef) -> List(ValidationError) {
  case ref {
    Reference(..) -> []
    Inline(schema_obj) -> check_schema(path, schema_obj)
  }
}

/// Check a single schema and recurse into children.
fn check_schema(path: String, schema_obj: SchemaObject) -> List(ValidationError) {
  let metadata = schema.get_metadata(schema_obj)

  // Check unsupported keywords stored by lossless parser
  let keyword_errors = case metadata.unsupported_keywords {
    [] -> []
    keywords -> {
      let keyword_list = string.join(keywords, "', '")
      [
        ValidationError(
          severity: SeverityError,
          target: TargetBoth,
          path: path,
          detail: "Unsupported JSON Schema keyword '"
            <> keyword_list
            <> "' found. Remove or model differently. See: "
            <> string.join(
            list.filter_map(keywords, fn(k) {
              list.find(capability.registry(), fn(c) { c.name == k })
              |> result.map(fn(c) { c.note })
            }),
            "; ",
          ),
        ),
      ]
    }
  }

  // Recurse into children
  let child_errors = case schema_obj {
    ObjectSchema(properties:, additional_properties:, ..) -> {
      let prop_errors =
        dict.to_list(properties)
        |> list.flat_map(fn(e) { check_schema_ref(path <> "." <> e.0, e.1) })
      let ap_errors = case additional_properties {
        Some(ap) -> check_schema_ref(path <> ".additionalProperties", ap)
        None -> []
      }
      list.append(prop_errors, ap_errors)
    }
    ArraySchema(items:, ..) -> check_schema_ref(path <> ".items", items)
    AllOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s) { check_schema_ref(path <> ".allOf", s) })
    OneOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s) { check_schema_ref(path <> ".oneOf", s) })
    AnyOfSchema(schemas:, ..) ->
      list.flat_map(schemas, fn(s) { check_schema_ref(path <> ".anyOf", s) })
    _ -> []
  }

  list.append(keyword_errors, child_errors)
}

/// Check security schemes for unsupported types (e.g. mutualTLS).
fn check_security_schemes(spec: OpenApiSpec) -> List(ValidationError) {
  case spec.components {
    None -> []
    Some(components) ->
      dict.to_list(components.security_schemes)
      |> list.filter_map(fn(entry) {
        let #(_name, component_entry) = entry
        case component_entry {
          ConcreteEntry(_scheme) -> {
            // mutualTLS would have been rejected at parse time since
            // parse_security_scheme doesn't recognize it. Nothing to
            // check here for now.
            Error(Nil)
          }
          _ -> Error(Nil)
        }
      })
  }
}

/// Check for parsed-but-unused features using the capability registry.
fn check_scope(spec: OpenApiSpec) -> List(ValidationError) {
  let webhook_w = case dict.is_empty(spec.webhooks) {
    True -> []
    False -> [
      ValidationError(
        severity: SeverityWarning,
        target: TargetBoth,
        path: "webhooks",
        detail: "Webhooks are parsed but not used by code generation.",
      ),
    ]
  }
  let external_docs_w = case spec.external_docs {
    Some(_) -> [
      ValidationError(
        severity: SeverityWarning,
        target: TargetBoth,
        path: "externalDocs",
        detail: "External docs are parsed but not used by code generation.",
      ),
    ]
    None -> []
  }
  let tags_w = case list.is_empty(spec.tags) {
    True -> []
    False -> [
      ValidationError(
        severity: SeverityWarning,
        target: TargetBoth,
        path: "tags",
        detail: "Top-level tags are parsed but not used by code generation.",
      ),
    ]
  }
  // Operation/path servers
  let server_w =
    dict.to_list(spec.paths)
    |> list.flat_map(fn(entry) {
      let #(path, path_item) = entry
      let path_w = case list.is_empty(path_item.servers) {
        True -> []
        False -> [
          ValidationError(
            severity: SeverityWarning,
            target: TargetClient,
            path: "paths." <> path <> ".servers",
            detail: "Path-level servers are parsed but client uses only top-level server URL.",
          ),
        ]
      }
      path_w
    })
  // Component headers/examples/links
  let comp_w = case spec.components {
    Some(c) -> {
      let h = case dict.is_empty(c.headers) {
        True -> []
        False -> [
          ValidationError(
            severity: SeverityWarning,
            target: TargetBoth,
            path: "components.headers",
            detail: "Component headers are parsed but not used by code generation.",
          ),
        ]
      }
      let l = case dict.is_empty(c.links) {
        True -> []
        False -> [
          ValidationError(
            severity: SeverityWarning,
            target: TargetBoth,
            path: "components.links",
            detail: "Component links are parsed but not used by code generation.",
          ),
        ]
      }
      list.append(h, l)
    }
    None -> []
  }
  list.flatten([webhook_w, external_docs_w, tags_w, server_w, comp_w])
}
