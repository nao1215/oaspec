//// Tests for the precomputed analyzed-operations cache on `Context`.
//// `context.operations(ctx)` is the shared analyzed view that every codegen
//// pass should consume — these tests pin down its shape and ensure it stays
//// in sync with `operations.collect_operations` (issue #371).

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import oaspec/internal/codegen/context
import oaspec/internal/openapi/operations
import oaspec/internal/openapi/resolver
import oaspec/openapi/schema
import oaspec/openapi/spec
import test_helpers

pub fn main() {
  gleeunit.main()
}

const petstore = "test/fixtures/petstore.yaml"

const readonly_writeonly = "test/fixtures/readonly_writeonly_properties.yaml"

pub fn operations_matches_direct_collect_test() {
  let ctx = test_helpers.make_ctx(petstore)
  let cached = context.operations(ctx)
  let direct = operations.collect_operations(context.spec(ctx))
  cached
  |> should.equal(direct)
}

pub fn operations_is_idempotent_across_calls_test() {
  // The cache is computed once at context.new/2 — repeated reads must not
  // re-run the traversal (and therefore must be the exact same list).
  let ctx = test_helpers.make_ctx(petstore)
  context.operations(ctx)
  |> should.equal(context.operations(ctx))
}

pub fn operations_petstore_op_ids_test() {
  let ctx = test_helpers.make_ctx(petstore)
  let op_ids =
    context.operations(ctx)
    |> list.map(fn(op) { op.0 })
  // petstore.yaml fixture defines operationIds explicitly, so the synthesizer
  // path is not exercised here — but we lock in the canonical set so any
  // accidental reshuffling shows up as a failed test.
  op_ids
  |> list.contains("listPets")
  |> should.be_true()
  op_ids
  |> list.contains("createPet")
  |> should.be_true()
}

pub fn operations_paths_are_sorted_test() {
  let ctx = test_helpers.make_ctx(petstore)
  let paths =
    context.operations(ctx)
    |> list.map(fn(op) { op.2 })
  // collect_operations sorts paths alphabetically before flat-mapping methods,
  // so the resulting path sequence must be non-decreasing.
  paths
  |> list.sort(string.compare)
  |> should.equal(paths)
}

pub fn operations_petstore_snapshot_test() {
  let ctx = test_helpers.make_ctx(petstore)
  let snapshot =
    context.operations(ctx)
    |> list.map(fn(op) {
      #(
        op.0,
        spec.method_to_lower(op.3),
        op.2,
        list.length(op.1.parameters),
        case op.1.request_body {
          Some(_) -> True
          None -> False
        },
        list.length(op.1.servers),
      )
    })

  snapshot
  |> should.equal([
    #("listPets", "get", "/pets", 2, False, 0),
    #("createPet", "post", "/pets", 0, True, 0),
    #("getPet", "get", "/pets/{petId}", 1, False, 0),
    #("deletePet", "delete", "/pets/{petId}", 1, False, 0),
  ])
}

pub fn schema_cache_matches_direct_resolver_test() {
  let ctx = test_helpers.make_ctx(readonly_writeonly)
  let account_read_ref =
    schema.make_reference("#/components/schemas/AccountRead")
  context.resolve_schema_ref(account_read_ref, ctx)
  |> should.equal(resolver.resolve_schema_ref(
    account_read_ref,
    context.spec(ctx),
  ))
}

pub fn schema_metadata_exposes_nested_property_flags_test() {
  let ctx = test_helpers.make_ctx(readonly_writeonly)
  let account_read_ref =
    schema.make_reference("#/components/schemas/AccountRead")
  let account_write_ref =
    schema.make_reference("#/components/schemas/AccountWrite")
  let assert Some(id_ref) = find_property_ref(account_read_ref, "id", ctx)
  let assert Some(password_ref) =
    find_property_ref(account_write_ref, "password", ctx)
  let assert Some(id_metadata) = context.schema_metadata(id_ref, ctx)
  let assert Some(password_metadata) =
    context.schema_metadata(password_ref, ctx)

  id_metadata.read_only
  |> should.be_true()
  password_metadata.write_only
  |> should.be_true()
}

fn find_property_ref(
  schema_ref: schema.SchemaRef,
  prop_name: String,
  ctx: context.Context,
) -> option.Option(schema.SchemaRef) {
  case context.resolve_schema_ref(schema_ref, ctx) {
    Ok(schema_obj) -> find_property_ref_in_object(schema_obj, prop_name, ctx)
    // nolint: thrown_away_error -- test helper treats unresolved refs as absence while walking for a known property
    Error(_) -> None
  }
}

fn find_property_ref_in_object(
  schema_obj: schema.SchemaObject,
  prop_name: String,
  ctx: context.Context,
) -> option.Option(schema.SchemaRef) {
  case schema_obj {
    schema.ObjectSchema(properties:, ..) ->
      case dict.get(properties, prop_name) {
        Ok(prop_ref) -> Some(prop_ref)
        // nolint: thrown_away_error -- missing property means keep searching other allOf branches
        Error(_) -> None
      }
    schema.AllOfSchema(schemas:, ..) ->
      list.fold(schemas, None, fn(found, part_ref) {
        case found {
          Some(_) -> found
          None -> find_property_ref(part_ref, prop_name, ctx)
        }
      })
    _ -> None
  }
}
