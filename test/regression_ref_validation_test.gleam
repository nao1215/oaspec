//// Regression tests for `parser.parse_string_resolved` (#616).
////
//// The structural `parse_string` accepts any spec whose YAML/JSON
//// layout matches the OpenAPI shape, even when a `$ref` points at a
//// non-existent component or forms a cycle. The new
//// `parse_string_resolved` entry point parses, normalises, resolves,
//// and validates every `SchemaRef.Reference` reachable from the spec.
////
//// The three acceptance tests below come from the issue's DoD:
////   - missing `$ref` is rejected by `parse_string_resolved`
////   - circular schema `$ref` is rejected by `parse_string_resolved`
////   - the legacy `parse_string` keeps its lenient behaviour

import gleeunit/should
import oaspec/openapi/parser as oaspec_parser

pub fn parse_resolved_rejects_missing_ref_test() {
  let spec =
    "openapi: 3.0.3
info:
  title: T
  version: 1.0.0
paths:
  /x:
    get:
      operationId: x
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Missing'
"
  case oaspec_parser.parse_string_resolved(spec) {
    // nolint: thrown_away_error -- this test asserts on the failure-mode shape, not the diagnostic payload
    Error(_) -> should.be_true(True)
    Ok(_) -> should.fail()
  }
}

pub fn parse_resolved_detects_circular_ref_test() {
  let spec =
    "openapi: 3.0.3
info:
  title: C
  version: 1.0.0
paths: {}
components:
  schemas:
    A:
      type: object
      properties:
        next:
          $ref: '#/components/schemas/A'
"
  case oaspec_parser.parse_string_resolved(spec) {
    // nolint: thrown_away_error -- this test asserts on the failure-mode shape, not the diagnostic payload
    Error(_) -> should.be_true(True)
    Ok(_) -> should.fail()
  }
}

pub fn parse_string_lenient_accepts_missing_ref_test() {
  let spec =
    "openapi: 3.0.3
info:
  title: T
  version: 1.0.0
paths: {}
components:
  schemas:
    A:
      $ref: '#/components/schemas/Missing'
"
  case oaspec_parser.parse_string(spec) {
    Ok(_) -> should.be_true(True)
    // nolint: thrown_away_error -- the structural parser must accept this spec; the test fails the suite if a diagnostic is surfaced
    Error(_) -> should.fail()
  }
}

pub fn parse_resolved_accepts_well_formed_spec_test() {
  let spec =
    "openapi: 3.0.3
info:
  title: T
  version: 1.0.0
paths:
  /things:
    get:
      operationId: listThings
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Thing'
components:
  schemas:
    Thing:
      type: object
      properties:
        id:
          type: string
"
  case oaspec_parser.parse_string_resolved(spec) {
    Ok(_) -> should.be_true(True)
    // nolint: thrown_away_error -- a well-formed spec must round-trip cleanly; the test fails the suite on any diagnostic
    Error(_) -> should.fail()
  }
}
