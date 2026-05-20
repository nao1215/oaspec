//// Unit tests for the pure planner helpers used by `external_loader`.
//// Every case here exercises ref parsing, schema lookup, alias chaining,
//// or collision diagnostics without touching the filesystem (issue #372).

import gleam/dict
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import oaspec/internal/openapi/external_loader_planner as planner
import oaspec/openapi/schema.{
  type SchemaObject, BooleanSchema, Inline, IntegerSchema, Reference,
}
import oaspec/openapi/spec.{
  type Components, type OpenApiSpec, Components, OpenApiSpec, Value,
}

pub fn main() {
  gleeunit.main()
}

// --- helpers --------------------------------------------------------

fn empty_components() -> Components(spec.Unresolved) {
  Components(
    schemas: dict.new(),
    parameters: dict.new(),
    request_bodies: dict.new(),
    responses: dict.new(),
    security_schemes: dict.new(),
    path_items: dict.new(),
    headers: dict.new(),
    examples: dict.new(),
    links: dict.new(),
    callbacks: dict.new(),
  )
}

fn make_spec(
  components: option.Option(Components(spec.Unresolved)),
) -> OpenApiSpec(spec.Unresolved) {
  OpenApiSpec(
    openapi: "3.0.3",
    info: spec.Info(
      title: "T",
      description: None,
      version: "1",
      summary: None,
      terms_of_service: None,
      contact: None,
      license: None,
    ),
    paths: dict.new(),
    components: components,
    servers: [],
    security: [],
    webhooks: dict.new(),
    tags: [],
    external_docs: None,
    json_schema_dialect: None,
  )
}

fn int_schema() -> SchemaObject {
  IntegerSchema(
    metadata: schema.default_metadata(),
    format: None,
    minimum: None,
    maximum: None,
    exclusive_minimum: None,
    exclusive_maximum: None,
    multiple_of: None,
  )
}

fn bool_schema() -> SchemaObject {
  BooleanSchema(metadata: schema.default_metadata())
}

fn make_param(name: String) -> spec.Parameter(spec.Unresolved) {
  spec.Parameter(
    name: name,
    in_: spec.InQuery,
    description: None,
    required: False,
    payload: spec.ParameterSchema(Inline(int_schema())),
    style: None,
    explode: None,
    deprecated: False,
    allow_reserved: False,
    examples: dict.new(),
  )
}

fn make_request_body() -> spec.RequestBody(spec.Unresolved) {
  spec.RequestBody(description: None, content: dict.new(), required: False)
}

fn make_response() -> spec.Response(spec.Unresolved) {
  spec.Response(
    description: None,
    content: dict.new(),
    headers: dict.new(),
    links: dict.new(),
  )
}

fn make_path_item() -> spec.PathItem(spec.Unresolved) {
  spec.PathItem(
    summary: None,
    description: None,
    get: None,
    post: None,
    put: None,
    delete: None,
    patch: None,
    head: None,
    options: None,
    trace: None,
    parameters: [],
    servers: [],
  )
}

// --- extract_external_ref ------------------------------------------

pub fn extract_external_ref_relative_test() {
  Reference(ref: "./other.yaml#/components/schemas/Foo", name: "Foo")
  |> planner.extract_external_ref
  |> should.equal(Some(#("./other.yaml", "Foo")))
}

pub fn extract_external_ref_parent_dir_test() {
  Reference(ref: "../shared.yaml#/components/schemas/Bar", name: "Bar")
  |> planner.extract_external_ref
  |> should.equal(Some(#("../shared.yaml", "Bar")))
}

pub fn extract_external_ref_local_returns_none_test() {
  Reference(ref: "#/components/schemas/Pet", name: "Pet")
  |> planner.extract_external_ref
  |> should.equal(None)
}

pub fn extract_external_ref_inline_returns_none_test() {
  Inline(int_schema())
  |> planner.extract_external_ref
  |> should.equal(None)
}

pub fn extract_external_ref_no_fragment_returns_none_test() {
  Reference(ref: "./other.yaml", name: "")
  |> planner.extract_external_ref
  |> should.equal(None)
}

pub fn extract_external_ref_wrong_prefix_returns_none_test() {
  Reference(ref: "./other.yaml#/components/parameters/Foo", name: "Foo")
  |> planner.extract_external_ref
  |> should.equal(None)
}

pub fn extract_external_ref_nested_fragment_returns_none_test() {
  Reference(ref: "./other.yaml#/components/schemas/Outer/properties", name: "x")
  |> planner.extract_external_ref
  |> should.equal(None)
}

// --- extract_external_component_ref --------------------------------

pub fn extract_component_ref_parameters_test() {
  planner.extract_external_component_ref(
    "./other.yaml#/components/parameters/Foo",
  )
  |> should.equal(Some(#("./other.yaml", "/components/parameters/", "Foo")))
}

pub fn extract_component_ref_request_bodies_test() {
  planner.extract_external_component_ref(
    "./other.yaml#/components/requestBodies/Body",
  )
  |> should.equal(Some(#("./other.yaml", "/components/requestBodies/", "Body")))
}

pub fn extract_component_ref_responses_test() {
  planner.extract_external_component_ref(
    "../shared.yaml#/components/responses/NotFound",
  )
  |> should.equal(
    Some(#("../shared.yaml", "/components/responses/", "NotFound")),
  )
}

pub fn extract_component_ref_path_items_test() {
  planner.extract_external_component_ref(
    "./other.yaml#/components/pathItems/Reusable",
  )
  |> should.equal(Some(#("./other.yaml", "/components/pathItems/", "Reusable")))
}

pub fn extract_component_ref_schemas_returns_none_test() {
  // schemas are handled by extract_external_ref, not this one.
  planner.extract_external_component_ref("./other.yaml#/components/schemas/Foo")
  |> should.equal(None)
}

pub fn extract_component_ref_local_returns_none_test() {
  planner.extract_external_component_ref("#/components/parameters/Foo")
  |> should.equal(None)
}

// --- local_schema_names ---------------------------------------------

pub fn local_schema_names_filters_external_test() {
  let entries = [
    #("Local", Inline(int_schema())),
    #(
      "ExternalAlias",
      Reference(ref: "./other.yaml#/components/schemas/Pet", name: "Pet"),
    ),
    #(
      "InternalAlias",
      Reference(ref: "#/components/schemas/Other", name: "Other"),
    ),
  ]
  // ExternalAlias is filtered out; InternalAlias and Local stay because
  // an internal alias is not an external ref.
  planner.local_schema_names(entries)
  |> should.equal(["Local", "InternalAlias"])
}

pub fn local_schema_names_empty_test() {
  planner.local_schema_names([])
  |> should.equal([])
}

// --- local_schema_name_from_ref ------------------------------------

pub fn local_schema_name_from_ref_local_test() {
  planner.local_schema_name_from_ref("#/components/schemas/Widget")
  |> should.equal(Some("Widget"))
}

pub fn local_schema_name_from_ref_cross_file_test() {
  planner.local_schema_name_from_ref("./other.yaml#/components/schemas/Widget")
  |> should.equal(None)
}

pub fn local_schema_name_from_ref_nested_path_test() {
  planner.local_schema_name_from_ref(
    "#/components/schemas/Outer/properties/inner",
  )
  |> should.equal(None)
}

pub fn local_schema_name_from_ref_empty_name_test() {
  planner.local_schema_name_from_ref("#/components/schemas/")
  |> should.equal(None)
}

// --- base_dir_of ----------------------------------------------------

pub fn base_dir_of_with_directory_test() {
  planner.base_dir_of("specs/api/openapi.yaml")
  |> should.equal(Some("specs/api"))
}

pub fn base_dir_of_bare_filename_test() {
  // filepath.directory_name returns "" for a bare filename; the planner
  // substitutes "." so callers resolve relative refs against CWD.
  planner.base_dir_of("openapi.yaml")
  |> should.equal(Some("."))
}

// --- check_local_collision -----------------------------------------

pub fn check_local_collision_entry_equals_fragment_ok_test() {
  // Widget: $ref: './other.yaml#/.../Widget' is intentionally allowed.
  planner.check_local_collision("Widget", "Widget", "./other.yaml", ["Widget"])
  |> should.equal(Ok(Nil))
}

pub fn check_local_collision_unique_fragment_ok_test() {
  planner.check_local_collision("Alias", "Imported", "./other.yaml", [
    "Alias", "Other",
  ])
  |> should.equal(Ok(Nil))
}

pub fn check_local_collision_conflict_errors_test() {
  planner.check_local_collision("Alias", "Widget", "./other.yaml", [
    "Widget", "Other",
  ])
  |> should.be_error()
}

// --- check_cross_file_collision ------------------------------------

pub fn check_cross_file_collision_empty_ok_test() {
  planner.check_cross_file_collision("Pet", "./a.yaml", dict.new())
  |> should.equal(Ok(Nil))
}

pub fn check_cross_file_collision_same_path_idempotent_test() {
  let imported = dict.from_list([#("Pet", "./a.yaml")])
  planner.check_cross_file_collision("Pet", "./a.yaml", imported)
  |> should.equal(Ok(Nil))
}

pub fn check_cross_file_collision_different_path_errors_test() {
  let imported = dict.from_list([#("Pet", "./a.yaml")])
  planner.check_cross_file_collision("Pet", "./b.yaml", imported)
  |> should.be_error()
}

// --- check_nested_local_collision ----------------------------------

pub fn check_nested_local_collision_no_conflict_test() {
  planner.check_nested_local_collision("Pet", "./a.yaml", ["Other"])
  |> should.equal(Ok(Nil))
}

pub fn check_nested_local_collision_conflict_errors_test() {
  planner.check_nested_local_collision("Pet", "./a.yaml", ["Pet"])
  |> should.be_error()
}

// --- check_nested_cross_file_collision -----------------------------

pub fn check_nested_cross_file_collision_same_path_ok_test() {
  let target = Inline(int_schema())
  let imports = dict.from_list([#("Pet", #("./a.yaml", target))])
  planner.check_nested_cross_file_collision("Pet", "./a.yaml", imports)
  |> should.equal(Ok(Nil))
}

pub fn check_nested_cross_file_collision_different_path_errors_test() {
  let target = Inline(int_schema())
  let imports = dict.from_list([#("Pet", #("./a.yaml", target))])
  planner.check_nested_cross_file_collision("Pet", "./b.yaml", imports)
  |> should.be_error()
}

// --- find_schema_follow_alias --------------------------------------

pub fn find_schema_follow_alias_inline_test() {
  let schemas = dict.from_list([#("Pet", Inline(int_schema()))])
  let components = Components(..empty_components(), schemas: schemas)
  planner.find_schema_follow_alias(components, "Pet", "./a.yaml")
  |> should.equal(Ok(Inline(int_schema())))
}

pub fn find_schema_follow_alias_single_local_alias_test() {
  let target = Inline(bool_schema())
  let schemas =
    dict.from_list([
      #("Pet", Reference(ref: "#/components/schemas/Animal", name: "Animal")),
      #("Animal", target),
    ])
  let components = Components(..empty_components(), schemas: schemas)
  planner.find_schema_follow_alias(components, "Pet", "./a.yaml")
  |> should.equal(Ok(target))
}

pub fn find_schema_follow_alias_chained_alias_errors_test() {
  let schemas =
    dict.from_list([
      #("Pet", Reference(ref: "#/components/schemas/Animal", name: "Animal")),
      #("Animal", Reference(ref: "#/components/schemas/Beast", name: "Beast")),
    ])
  let components = Components(..empty_components(), schemas: schemas)
  planner.find_schema_follow_alias(components, "Pet", "./a.yaml")
  |> should.be_error()
}

pub fn find_schema_follow_alias_cross_file_alias_errors_test() {
  let schemas =
    dict.from_list([
      #(
        "Pet",
        Reference(
          ref: "./other.yaml#/components/schemas/Animal",
          name: "Animal",
        ),
      ),
    ])
  let components = Components(..empty_components(), schemas: schemas)
  planner.find_schema_follow_alias(components, "Pet", "./a.yaml")
  |> should.be_error()
}

pub fn find_schema_follow_alias_missing_test() {
  let components = empty_components()
  planner.find_schema_follow_alias(components, "Missing", "./a.yaml")
  |> should.be_error()
}

// --- find_external_schema (None components branch) ----------------

pub fn find_external_schema_no_components_test() {
  planner.find_external_schema(make_spec(None), "Pet", "./a.yaml")
  |> should.be_error()
}

pub fn find_external_schema_with_components_test() {
  let schemas = dict.from_list([#("Pet", Inline(int_schema()))])
  let components = Components(..empty_components(), schemas: schemas)
  planner.find_external_schema(make_spec(Some(components)), "Pet", "./a.yaml")
  |> should.equal(Ok(Inline(int_schema())))
}

// --- find_external_parameter ---------------------------------------

pub fn find_external_parameter_inline_test() {
  let param = make_param("limit")
  let parameters = dict.from_list([#("limit", Value(param))])
  let components = Components(..empty_components(), parameters: parameters)
  planner.find_external_parameter(
    make_spec(Some(components)),
    "limit",
    "./a.yaml",
  )
  |> should.equal(Ok(param))
}

pub fn find_external_parameter_chained_ref_errors_test() {
  let parameters =
    dict.from_list([#("limit", spec.Ref("#/components/parameters/Other"))])
  let components = Components(..empty_components(), parameters: parameters)
  planner.find_external_parameter(
    make_spec(Some(components)),
    "limit",
    "./a.yaml",
  )
  |> should.be_error()
}

pub fn find_external_parameter_missing_errors_test() {
  let components = empty_components()
  planner.find_external_parameter(
    make_spec(Some(components)),
    "limit",
    "./a.yaml",
  )
  |> should.be_error()
}

pub fn find_external_parameter_no_components_errors_test() {
  planner.find_external_parameter(make_spec(None), "limit", "./a.yaml")
  |> should.be_error()
}

// --- find_external_request_body ------------------------------------

pub fn find_external_request_body_inline_test() {
  let body = make_request_body()
  let bodies = dict.from_list([#("Body", Value(body))])
  let components = Components(..empty_components(), request_bodies: bodies)
  planner.find_external_request_body(
    make_spec(Some(components)),
    "Body",
    "./a.yaml",
  )
  |> should.equal(Ok(body))
}

pub fn find_external_request_body_missing_errors_test() {
  planner.find_external_request_body(
    make_spec(Some(empty_components())),
    "Body",
    "./a.yaml",
  )
  |> should.be_error()
}

// --- find_external_response ----------------------------------------

pub fn find_external_response_inline_test() {
  let response = make_response()
  let responses = dict.from_list([#("OK", Value(response))])
  let components = Components(..empty_components(), responses: responses)
  planner.find_external_response(make_spec(Some(components)), "OK", "./a.yaml")
  |> should.equal(Ok(response))
}

pub fn find_external_response_chained_ref_errors_test() {
  let responses =
    dict.from_list([#("OK", spec.Ref("#/components/responses/Other"))])
  let components = Components(..empty_components(), responses: responses)
  planner.find_external_response(make_spec(Some(components)), "OK", "./a.yaml")
  |> should.be_error()
}

// --- find_external_path_item ---------------------------------------

pub fn find_external_path_item_inline_test() {
  let path_item = make_path_item()
  let path_items = dict.from_list([#("Reusable", Value(path_item))])
  let components = Components(..empty_components(), path_items: path_items)
  planner.find_external_path_item(
    make_spec(Some(components)),
    "Reusable",
    "./a.yaml",
  )
  |> should.equal(Ok(path_item))
}

pub fn find_external_path_item_missing_errors_test() {
  planner.find_external_path_item(
    make_spec(Some(empty_components())),
    "Reusable",
    "./a.yaml",
  )
  |> should.be_error()
}
