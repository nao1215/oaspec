# Server-mode request-shape checklist

This checklist tracks the request-shape boundaries that are still rejected in
server mode. The canonical capability names live in
`src/oaspec/internal/capability.gleam`.

An item is treated as closed when the current decision is documented here and a
fixture-backed test covers the behavior.

- [x] `server: complex path parameters`
  Decision: long-term non-goal.
  Reason: the server router receives one path segment per parameter, so
  structured path decoding would need a custom encoding contract that `oaspec`
  does not define.
  Fixture: `test/fixtures/server_complex_path_parameter.yaml`

- [x] `server: non-primitive query array items`
  Decision: long-term non-goal after primitive query-array support.
  Reason: the server query API is a repeated-key multimap. Keeping array items
  primitive preserves a direct mapping from the wire shape to generated Gleam
  values.
  Fixtures: `test/fixtures/server_query_array_params.yaml`,
  `test/fixtures/server_query_array_object_items.yaml`

- [x] `server: non-primitive header array items`
  Decision: long-term non-goal after primitive header-array support.
  Reason: headers arrive as flat strings. Restricting array items to primitive
  leaves keeps parsing predictable and matches the generated query-array rules.
  Fixtures: `test/fixtures/server_header_array_params.yaml`,
  `test/fixtures/server_header_array_object_items.yaml`

- [x] `server: complex deepObject properties`
  Decision: long-term non-goal after flat primitive-leaf support.
  Reason: the remaining rejected shapes are nested or non-primitive leaves that
  no longer map cleanly to the current generated router contract.
  Fixtures: `test/fixtures/server_deep_object_params.yaml`,
  `test/fixtures/server_deep_object_complex_properties.yaml`

- [x] `server: mixed form-urlencoded request`
  Decision: long-term non-goal.
  Reason: the server generator expects one typed request-body shape per
  operation. Mixing `application/x-www-form-urlencoded` with other request
  content types would require a different dispatch contract.
  Fixtures: `test/fixtures/server_form_urlencoded_body.yaml`,
  `test/fixtures/server_form_urlencoded_mixed_content.yaml`

- [x] `server: complex form-urlencoded fields`
  Decision: long-term non-goal after primitive fields, primitive arrays, and
  nested primitive-leaf objects were added.
  Reason: arrays or objects whose leaves are themselves complex still fall
  outside the current parser and router contract.
  Fixtures: `test/fixtures/server_form_urlencoded_nested_body.yaml`,
  `test/fixtures/server_form_urlencoded_complex_fields.yaml`

- [x] `server: mixed multipart request`
  Decision: long-term non-goal.
  Reason: the generated server path for multipart parsing assumes the multipart
  schema is the only request-body contract for that operation.
  Fixtures: `test/fixtures/server_multipart_body.yaml`,
  `test/fixtures/server_multipart_mixed_content.yaml`

- [x] `server: complex multipart fields`
  Decision: long-term non-goal after primitive scalar support.
  Reason: nested multipart shapes are out of scope for the current generated
  parser. The remaining supported surface stays limited to flat primitive
  values.
  Fixtures: `test/fixtures/server_multipart_body.yaml`,
  `test/fixtures/server_multipart_complex_fields.yaml`

- [x] `server: unsupported request content type`
  Decision: long-term non-goal.
  Reason: server-mode request decoding stays explicit. `application/json`,
  `application/x-www-form-urlencoded`, `multipart/form-data`,
  `application/octet-stream`, and `text/plain` remain the only supported server
  request-body contracts.
  Fixture: `test/fixtures/server_request_body_problem_json.yaml`
