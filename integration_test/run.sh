#!/bin/bash
# Integration test: verify generated code compiles and works correctly.
#
# This script:
#   1. Generates server code from the Petstore OpenAPI spec
#   2. Compiles the generated code in a standalone Gleam project (proves type-safety)
#   3. Runs tests that verify type construction, JSON encode/decode round-trips,
#      middleware composition, and simulated server/client communication

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/lib/mise_bootstrap.sh
. "$PROJECT_ROOT/scripts/lib/mise_bootstrap.sh"
oaspec_require_tool gleam

info() { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

cd "$PROJECT_ROOT"

# -------------------------------------------------------
# Step 1: Generate code
# -------------------------------------------------------
info "Generating code from Petstore OpenAPI spec..."

rm -rf "$SCRIPT_DIR/src/api"
mkdir -p "$SCRIPT_DIR/src/api"

gleam run -- generate \
  --config="$SCRIPT_DIR/oaspec.yaml" \
  --mode=server

info "Code generation done."

# -------------------------------------------------------
# Step 2: Overwrite handlers with real implementation
# -------------------------------------------------------
info "Writing handler implementations (replacing panic stubs)..."

cat > "$SCRIPT_DIR/src/api/handlers.gleam" << 'GLEAM_EOF'
// Hand-written handler implementations for integration testing.
// These replace the generated panic stubs.

import api/request_types
import api/response_types
import api/types
import gleam/option.{None, Some}

/// Application state passed to every handler. Empty for this fixture.
pub type State {
  State
}

/// List all pets - returns hardcoded test data.
pub fn list_pets(state: State, req: request_types.ListPetsRequest) -> response_types.ListPetsResponse {
  let _ = state
  let _ = req
  let pets = [
    types.Pet(id: 1, name: "Fido", status: types.PetStatusAvailable, tag: Some("dog")),
    types.Pet(id: 2, name: "Whiskers", status: types.PetStatusPending, tag: None),
  ]
  response_types.ListPetsResponseOk(pets)
}

/// Create a pet - returns the created pet.
pub fn create_pet(state: State, req: request_types.CreatePetRequest) -> response_types.CreatePetResponse {
  let _ = state
  let pet = types.Pet(
    id: 100,
    name: req.body.name,
    status: types.PetStatusAvailable,
    tag: req.body.tag,
  )
  response_types.CreatePetResponseCreated(pet)
}

/// Get a pet by ID.
pub fn get_pet(state: State, req: request_types.GetPetRequest) -> response_types.GetPetResponse {
  let _ = state
  case req.pet_id {
    1 -> response_types.GetPetResponseOk(
      types.Pet(id: 1, name: "Fido", status: types.PetStatusAvailable, tag: Some("dog")),
    )
    _ -> response_types.GetPetResponseNotFound
  }
}

/// Delete a pet by ID.
pub fn delete_pet(state: State, req: request_types.DeletePetRequest) -> response_types.DeletePetResponse {
  let _ = state
  case req.pet_id {
    1 -> response_types.DeletePetResponseNoContent
    _ -> response_types.DeletePetResponseNotFound
  }
}
GLEAM_EOF

info "Handler implementations written."

# -------------------------------------------------------
# Step 3: Compile
# -------------------------------------------------------
info "Compiling generated code (type-safety check)..."

cd "$SCRIPT_DIR"
gleam deps download

if gleam build --warnings-as-errors 2>&1; then
  info "PASS: Generated code compiles successfully."
else
  fail "Generated code failed to compile."
fi

# -------------------------------------------------------
# Step 4: Run tests
# -------------------------------------------------------
info "Running integration tests..."

if gleam test 2>&1; then
  info "PASS: All integration tests passed."
else
  fail "Integration tests failed."
fi

info "Server integration tests passed."

# -------------------------------------------------------
# Step 5: Generate client code and verify it compiles
# -------------------------------------------------------
info "Testing client code generation..."

CLIENT_DIR="$SCRIPT_DIR/client_test"
rm -rf "$CLIENT_DIR"
mkdir -p "$CLIENT_DIR/src"

# Create a config file that outputs client code with matching package/directory name
cat > "$CLIENT_DIR/oaspec-client.yaml" << 'YAML_EOF'
input: test/fixtures/petstore.yaml
output:
  client: ./integration_test/client_test/src/api
package: api
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$CLIENT_DIR/oaspec-client.yaml" \
  --mode=client

# Create a minimal Gleam project around the generated client code
cat > "$CLIENT_DIR/gleam.toml" << 'TOML_EOF'
name = "client_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
gleam_http = ">= 4.0.0 and < 5.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$CLIENT_DIR/src/client_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cd "$CLIENT_DIR"
gleam deps download

if gleam build --warnings-as-errors 2>&1; then
  info "PASS: Generated client code compiles (warnings-as-errors)."
else
  fail "Generated client code failed to compile."
fi

# Clean up
rm -rf "$CLIENT_DIR"

info "Petstore client integration tests passed."

# -------------------------------------------------------
# Step 6: Generate complex spec and verify it compiles
# -------------------------------------------------------
info "Testing complex spec code generation (inline schemas, oneOf, allOf, discriminator)..."

COMPLEX_DIR="$SCRIPT_DIR/complex_test"
rm -rf "$COMPLEX_DIR"
mkdir -p "$COMPLEX_DIR/src"

cat > "$COMPLEX_DIR/oaspec-complex.yaml" << 'YAML_EOF'
input: test/fixtures/complex_supported_openapi.yaml
output:
  server: ./integration_test/complex_test/src/api
package: api
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$COMPLEX_DIR/oaspec-complex.yaml" \
  --mode=server

# Overwrite handler stubs with minimal implementations that compile
cat > "$COMPLEX_DIR/src/api/handlers.gleam" << 'GLEAM_EOF'
import api/request_types
import api/response_types

pub type State {
  State
}

pub fn get_user(state: State, req: request_types.GetUserRequest) -> response_types.GetUserResponse {
  let _ = state
  let _ = req
  panic as "complex_test stub"
}

pub fn post_search(state: State, req: request_types.PostSearchRequest) -> response_types.PostSearchResponse {
  let _ = state
  let _ = req
  panic as "complex_test stub"
}

pub fn post_webhook(state: State, req: request_types.PostWebhookRequest) -> response_types.PostWebhookResponse {
  let _ = state
  let _ = req
  panic as "complex_test stub"
}

pub fn get_required_params(state: State, req: request_types.GetRequiredParamsRequest) -> response_types.GetRequiredParamsResponse {
  let _ = state
  let _ = req
  panic as "complex_test stub"
}
GLEAM_EOF

cat > "$COMPLEX_DIR/gleam.toml" << 'TOML_EOF'
name = "complex_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$COMPLEX_DIR/src/complex_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cd "$COMPLEX_DIR"
gleam deps download

if gleam build --warnings-as-errors 2>&1; then
  info "PASS: Generated complex spec code compiles successfully."
else
  fail "Generated complex spec code failed to compile."
fi

# Clean up
rm -rf "$COMPLEX_DIR"

info "Complex spec integration tests passed."

# -------------------------------------------------------
# Step 7: Generate security-bearing spec client and verify it compiles
# -------------------------------------------------------
info "Testing security scheme client code generation (apiKey header, bearer)..."

SECURE_DIR="$SCRIPT_DIR/secure_test"
rm -rf "$SECURE_DIR"
mkdir -p "$SECURE_DIR/src"

cat > "$SECURE_DIR/oaspec-secure.yaml" << 'YAML_EOF'
input: test/fixtures/secure_api.yaml
output:
  client: ./integration_test/secure_test/src/api
package: api
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$SECURE_DIR/oaspec-secure.yaml" \
  --mode=client

cat > "$SECURE_DIR/gleam.toml" << 'TOML_EOF'
name = "secure_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
gleam_http = ">= 4.0.0 and < 5.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$SECURE_DIR/src/secure_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cd "$SECURE_DIR"
gleam deps download

if gleam build --warnings-as-errors 2>&1; then
  info "PASS: Generated security client code compiles (warnings-as-errors)."
else
  fail "Generated security client code failed to compile."
fi

# Clean up
rm -rf "$SECURE_DIR"

info "Security client integration tests passed."

# -------------------------------------------------------
# Step 8: Generate primitive API client and verify it compiles
# -------------------------------------------------------
info "Testing primitive schema + default response client code generation..."

PRIM_DIR="$SCRIPT_DIR/primitive_test"
rm -rf "$PRIM_DIR"
mkdir -p "$PRIM_DIR/src"

cat > "$PRIM_DIR/oaspec-prim.yaml" << 'YAML_EOF'
input: test/fixtures/primitive_api.yaml
output:
  client: ./integration_test/primitive_test/src/api
package: api
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$PRIM_DIR/oaspec-prim.yaml" \
  --mode=client

cat > "$PRIM_DIR/gleam.toml" << 'TOML_EOF'
name = "primitive_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
gleam_http = ">= 4.0.0 and < 5.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$PRIM_DIR/src/primitive_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cd "$PRIM_DIR"
gleam deps download

if gleam build --warnings-as-errors 2>&1; then
  info "PASS: Generated primitive API client code compiles (warnings-as-errors)."
else
  fail "Generated primitive API client code failed to compile."
fi

# Clean up
rm -rf "$PRIM_DIR"

# -------------------------------------------------------
# Step 9: Generate form-urlencoded server and verify it compiles
# -------------------------------------------------------
info "Testing form-urlencoded server code generation..."

FORM_DIR="$SCRIPT_DIR/form_test"
rm -rf "$FORM_DIR"
mkdir -p "$FORM_DIR/src"

cat > "$FORM_DIR/oaspec-form.yaml" << 'YAML_EOF'
input: test/fixtures/server_form_urlencoded_body.yaml
output:
  server: ./integration_test/form_test/src/api
package: api
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$FORM_DIR/oaspec-form.yaml" \
  --mode=server

cat > "$FORM_DIR/src/api/handlers.gleam" << 'GLEAM_EOF'
import api/request_types
import api/response_types

pub type State {
  State
}

pub fn submit_form(state: State, req: request_types.SubmitFormRequest) -> response_types.SubmitFormResponse {
  let _ = state
  let _ = req
  response_types.SubmitFormResponseOk
}
GLEAM_EOF

cat > "$FORM_DIR/gleam.toml" << 'TOML_EOF'
name = "form_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$FORM_DIR/src/form_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cd "$FORM_DIR"
gleam deps download

if gleam build --warnings-as-errors 2>&1; then
  info "PASS: Generated form-urlencoded server code compiles (warnings-as-errors)."
else
  fail "Generated form-urlencoded server code failed to compile."
fi

rm -rf "$FORM_DIR"

info "Form-urlencoded server integration tests passed."

# -------------------------------------------------------
# Step 10: Generate multipart server and verify it compiles
# -------------------------------------------------------
info "Testing multipart server code generation..."

MULTI_DIR="$SCRIPT_DIR/multipart_test"
rm -rf "$MULTI_DIR"
mkdir -p "$MULTI_DIR/src"

cat > "$MULTI_DIR/oaspec-multi.yaml" << 'YAML_EOF'
input: test/fixtures/server_multipart_body.yaml
output:
  server: ./integration_test/multipart_test/src/api
package: api
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$MULTI_DIR/oaspec-multi.yaml" \
  --mode=server

cat > "$MULTI_DIR/src/api/handlers.gleam" << 'GLEAM_EOF'
import api/request_types
import api/response_types

pub type State {
  State
}

pub fn upload_multipart(state: State, req: request_types.UploadMultipartRequest) -> response_types.UploadMultipartResponse {
  let _ = state
  let _ = req
  response_types.UploadMultipartResponseOk
}
GLEAM_EOF

cat > "$MULTI_DIR/gleam.toml" << 'TOML_EOF'
name = "multipart_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$MULTI_DIR/src/multipart_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cd "$MULTI_DIR"
gleam deps download

if gleam build --warnings-as-errors 2>&1; then
  info "PASS: Generated multipart server code compiles (warnings-as-errors)."
else
  fail "Generated multipart server code failed to compile."
fi

rm -rf "$MULTI_DIR"

info "Multipart server integration tests passed."

# -------------------------------------------------------
# Step 11: Generate callback spec and verify it compiles
# -------------------------------------------------------
info "Testing callback handler code generation..."

CALLBACK_DIR="$SCRIPT_DIR/callback_test"
rm -rf "$CALLBACK_DIR"
mkdir -p "$CALLBACK_DIR/src"

cat > "$CALLBACK_DIR/oaspec-callback.yaml" << 'YAML_EOF'
input: test/fixtures/callback_api.yaml
output:
  server: ./integration_test/callback_test/src/api
package: api
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$CALLBACK_DIR/oaspec-callback.yaml" \
  --mode=server

cat > "$CALLBACK_DIR/src/api/handlers.gleam" << 'GLEAM_EOF'
import api/request_types
import api/response_types

pub type State {
  State
}

pub fn register_webhook(state: State, req: request_types.RegisterWebhookRequest) -> response_types.RegisterWebhookResponse {
  let _ = state
  let _ = req
  response_types.RegisterWebhookResponseCreated
}

// Note: callbacks are parsed but no longer produce handler stubs — see
// issue #117.
GLEAM_EOF

cat > "$CALLBACK_DIR/gleam.toml" << 'TOML_EOF'
name = "callback_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$CALLBACK_DIR/src/callback_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cd "$CALLBACK_DIR"
gleam deps download

if gleam build --warnings-as-errors 2>&1; then
  info "PASS: Generated callback code compiles (warnings-as-errors)."
else
  fail "Generated callback code failed to compile."
fi

rm -rf "$CALLBACK_DIR"

info "Callback integration tests passed."

# -------------------------------------------------------
# Step 12: Generate cookie params server and verify it compiles
# -------------------------------------------------------
info "Testing cookie parameter server code generation..."

COOKIE_DIR="$SCRIPT_DIR/cookie_test"
rm -rf "$COOKIE_DIR"
mkdir -p "$COOKIE_DIR/src"

cat > "$COOKIE_DIR/cookie_api.yaml" << 'YAML_EOF'
openapi: "3.0.3"
info:
  title: Cookie Params API
  version: 1.0.0
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: session
          in: cookie
          required: true
          schema:
            type: string
        - name: debug
          in: cookie
          required: false
          schema:
            type: boolean
      responses:
        "200":
          description: ok
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/ItemList"
components:
  schemas:
    ItemList:
      type: object
      required:
        - items
      properties:
        items:
          type: array
          items:
            type: string
YAML_EOF

cat > "$COOKIE_DIR/oaspec-cookie.yaml" << 'YAML_EOF'
input: ./integration_test/cookie_test/cookie_api.yaml
output:
  server: ./integration_test/cookie_test/src/api
package: api
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$COOKIE_DIR/oaspec-cookie.yaml" \
  --mode=server

cat > "$COOKIE_DIR/src/api/handlers.gleam" << 'GLEAM_EOF'
import api/request_types
import api/response_types
import api/types

pub type State {
  State
}

pub fn list_items(state: State, req: request_types.ListItemsRequest) -> response_types.ListItemsResponse {
  let _ = state
  let _ = req
  response_types.ListItemsResponseOk(types.ItemList(items: ["item1"]))
}
GLEAM_EOF

cat > "$COOKIE_DIR/gleam.toml" << 'TOML_EOF'
name = "cookie_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$COOKIE_DIR/src/cookie_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cd "$COOKIE_DIR"
gleam deps download

if gleam build --warnings-as-errors 2>&1; then
  info "PASS: Generated cookie params server code compiles (warnings-as-errors)."
else
  fail "Generated cookie params server code failed to compile."
fi

rm -rf "$COOKIE_DIR"

info "Cookie params integration tests passed."

# -------------------------------------------------------
# Step 13: Generate deepObject params server and verify it compiles
# -------------------------------------------------------
info "Testing deepObject parameter server code generation..."

DEEP_DIR="$SCRIPT_DIR/deepobject_test"
rm -rf "$DEEP_DIR"
mkdir -p "$DEEP_DIR/src"

cat > "$DEEP_DIR/oaspec-deep.yaml" << 'YAML_EOF'
input: test/fixtures/server_deep_object_params.yaml
output:
  server: ./integration_test/deepobject_test/src/api
package: api
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$DEEP_DIR/oaspec-deep.yaml" \
  --mode=server

cat > "$DEEP_DIR/src/api/handlers.gleam" << 'GLEAM_EOF'
import api/request_types
import api/response_types

pub type State {
  State
}

pub fn search_items(state: State, req: request_types.SearchItemsRequest) -> response_types.SearchItemsResponse {
  let _ = state
  let _ = req
  response_types.SearchItemsResponseOk
}
GLEAM_EOF

cat > "$DEEP_DIR/gleam.toml" << 'TOML_EOF'
name = "deepobject_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$DEEP_DIR/src/deepobject_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cd "$DEEP_DIR"
gleam deps download

if gleam build --warnings-as-errors 2>&1; then
  info "PASS: Generated deepObject params server code compiles (warnings-as-errors)."
else
  fail "Generated deepObject params server code failed to compile."
fi

rm -rf "$DEEP_DIR"

info "DeepObject params integration tests passed."

# -------------------------------------------------------
# Step 14: Generate reserved-keyword spec and verify it compiles
# -------------------------------------------------------
# Guards the escape pipeline in src/oaspec/util/naming.gleam against
# regressions: if any codegen site forgets to call escape_keyword for a
# record field, operationId-derived function, or parameter name, the
# emitted Gleam will fail to parse and this step will fail.
info "Testing reserved-keyword spec code generation (server + client)..."

KW_SERVER_DIR="$SCRIPT_DIR/reserved_keywords_server_test"
rm -rf "$KW_SERVER_DIR"
mkdir -p "$KW_SERVER_DIR/src"

cat > "$KW_SERVER_DIR/oaspec-kw-server.yaml" << 'YAML_EOF'
input: test/fixtures/reserved_keywords.yaml
output:
  server: ./integration_test/reserved_keywords_server_test/src/api
package: api
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$KW_SERVER_DIR/oaspec-kw-server.yaml" \
  --mode=server

cat > "$KW_SERVER_DIR/gleam.toml" << 'TOML_EOF'
name = "reserved_keywords_server_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$KW_SERVER_DIR/src/reserved_keywords_server_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cd "$KW_SERVER_DIR"
gleam deps download

if gleam build --warnings-as-errors 2>&1; then
  info "PASS: Generated reserved-keyword server code compiles (warnings-as-errors)."
else
  fail "Generated reserved-keyword server code failed to compile."
fi

rm -rf "$KW_SERVER_DIR"

KW_CLIENT_DIR="$SCRIPT_DIR/reserved_keywords_client_test"
rm -rf "$KW_CLIENT_DIR"
mkdir -p "$KW_CLIENT_DIR/src"

cat > "$KW_CLIENT_DIR/oaspec-kw-client.yaml" << 'YAML_EOF'
input: test/fixtures/reserved_keywords.yaml
output:
  client: ./integration_test/reserved_keywords_client_test/src/api
package: api
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$KW_CLIENT_DIR/oaspec-kw-client.yaml" \
  --mode=client

cat > "$KW_CLIENT_DIR/gleam.toml" << 'TOML_EOF'
name = "reserved_keywords_client_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
gleam_http = ">= 4.0.0 and < 5.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$KW_CLIENT_DIR/src/reserved_keywords_client_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cd "$KW_CLIENT_DIR"
gleam deps download

if gleam build --warnings-as-errors 2>&1; then
  info "PASS: Generated reserved-keyword client code compiles (warnings-as-errors)."
else
  fail "Generated reserved-keyword client code failed to compile."
fi

rm -rf "$KW_CLIENT_DIR"

info "Reserved-keyword integration tests passed."

# -------------------------------------------------------
# Step 15: Exercise generated guards end-to-end against invalid input
# -------------------------------------------------------
# Compile the guard_constraints_api spec and call every emitted guard
# function directly with both valid and invalid values. This protects
# against regressions in guards.gleam that would otherwise only surface
# when a user enables `validate: true` on a spec with constraints.
info "Testing generated guards end-to-end (reject invalid data)..."

GUARD_DIR="$SCRIPT_DIR/guard_constraints_test"
rm -rf "$GUARD_DIR"
mkdir -p "$GUARD_DIR/src" "$GUARD_DIR/test"

cat > "$GUARD_DIR/oaspec-guard.yaml" << 'YAML_EOF'
input: test/fixtures/guard_constraints_api.yaml
output:
  server: ./integration_test/guard_constraints_test/src/api
package: api
# validate is explicit because issue #268 changed the default for
# server-producing modes from `false` to `true`. This step intentionally
# exercises the opt-out path so the grep below for the absence of
# `guards.validate_item(` keeps verifying the off-state semantics.
validate: false
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$GUARD_DIR/oaspec-guard.yaml" \
  --mode=server

# Replace panic stubs so server code compiles.
cat > "$GUARD_DIR/src/api/handlers.gleam" << 'GLEAM_EOF'
import api/request_types
import api/response_types

pub type State {
  State
}

pub fn create_item(state: State, req: request_types.CreateItemRequest) -> response_types.CreateItemResponse {
  let _ = state
  response_types.CreateItemResponseCreated(req.body)
}
GLEAM_EOF

cat > "$GUARD_DIR/gleam.toml" << 'TOML_EOF'
name = "guard_constraints_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
gleam_regexp = ">= 1.0.0 and < 2.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$GUARD_DIR/src/guard_constraints_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cat > "$GUARD_DIR/test/guard_constraints_test_test.gleam" << 'GLEAM_EOF'
// E2E tests for generated guard functions. Each constraint family
// (string length, string pattern, integer range, exclusive range,
// multipleOf, float range, array length, array uniqueness, and the
// composite schema validator) is exercised with both a valid and an
// invalid value so a regression in any single branch fails this suite.

import api/guards
import api/types
import gleam/option.{Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// --- string length ---------------------------------------------------

pub fn name_length_valid_test() {
  guards.validate_item_name_length("acme")
  |> should.equal(Ok("acme"))
}

pub fn name_length_too_short_test() {
  guards.validate_item_name_length("ab")
  |> should.be_error
}

pub fn name_length_too_long_test() {
  guards.validate_item_name_length("xxxxxxxxxxxxxxxxxxxxxx")
  |> should.be_error
}

// --- string pattern --------------------------------------------------

pub fn slug_pattern_valid_test() {
  guards.validate_item_slug_pattern("good_slug1")
  |> should.equal(Ok("good_slug1"))
}

pub fn slug_pattern_invalid_test() {
  guards.validate_item_slug_pattern("Bad Slug")
  |> should.be_error
}

// --- integer range ---------------------------------------------------

pub fn quantity_range_valid_test() {
  guards.validate_item_quantity_range(50)
  |> should.equal(Ok(50))
}

pub fn quantity_range_below_minimum_test() {
  guards.validate_item_quantity_range(0)
  |> should.be_error
}

pub fn quantity_range_above_maximum_test() {
  guards.validate_item_quantity_range(1001)
  |> should.be_error
}

// --- integer exclusive range ----------------------------------------

pub fn price_exclusive_valid_test() {
  guards.validate_item_price_exclusive_range(5000)
  |> should.equal(Ok(5000))
}

pub fn price_exclusive_at_lower_bound_test() {
  guards.validate_item_price_exclusive_range(0)
  |> should.be_error
}

pub fn price_exclusive_at_upper_bound_test() {
  guards.validate_item_price_exclusive_range(10_000)
  |> should.be_error
}

// --- integer multipleOf ---------------------------------------------

pub fn batch_size_multiple_of_valid_test() {
  guards.validate_item_batch_size_multiple_of(25)
  |> should.equal(Ok(25))
}

pub fn batch_size_multiple_of_invalid_test() {
  guards.validate_item_batch_size_multiple_of(7)
  |> should.be_error
}

// --- float range -----------------------------------------------------

pub fn weight_range_valid_test() {
  guards.validate_item_weight_range(50.0)
  |> should.equal(Ok(50.0))
}

pub fn weight_range_below_minimum_test() {
  guards.validate_item_weight_range(0.05)
  |> should.be_error
}

pub fn weight_range_above_maximum_test() {
  guards.validate_item_weight_range(100.0)
  |> should.be_error
}

// --- array length ----------------------------------------------------

pub fn tags_length_valid_test() {
  guards.validate_item_tags_length(["a", "b"])
  |> should.equal(Ok(["a", "b"]))
}

pub fn tags_length_empty_test() {
  guards.validate_item_tags_length([])
  |> should.be_error
}

pub fn tags_length_too_long_test() {
  guards.validate_item_tags_length(["a", "b", "c", "d", "e", "f"])
  |> should.be_error
}

// --- array uniqueness -----------------------------------------------

pub fn tags_unique_valid_test() {
  guards.validate_item_tags_unique(["a", "b"])
  |> should.equal(Ok(["a", "b"]))
}

pub fn tags_unique_duplicate_test() {
  guards.validate_item_tags_unique(["a", "a"])
  |> should.be_error
}

// --- composite validator --------------------------------------------

fn valid_item() -> types.Item {
  types.Item(
    name: "acme",
    slug: Some("good_slug"),
    quantity: 10,
    price: Some(500),
    weight: Some(5.0),
    batch_size: Some(10),
    tags: ["a", "b"],
  )
}

pub fn composite_valid_test() {
  let item = valid_item()
  guards.validate_item(item)
  |> should.equal(Ok(item))
}

pub fn composite_collects_multiple_errors_test() {
  let item =
    types.Item(
      name: "ab",
      slug: Some("Bad"),
      quantity: 0,
      price: Some(0),
      weight: Some(1000.0),
      batch_size: Some(7),
      tags: [],
    )
  let result = guards.validate_item(item)
  case result {
    Error(errors) -> {
      should.be_true(case errors {
        [] -> False
        _ -> True
      })
    }
    Ok(_) -> should.fail()
  }
}

// --- opt-in: default (validate omitted) does NOT embed guard calls --

// Sanity: the omitted-validate router we compile for this step must
// NOT carry `guards.validate_item(` in its body — that pattern only
// appears when validate:true is set. We assert that by reading the
// generated router.gleam below from run.sh, not from inside gleeunit.
GLEAM_EOF

cd "$GUARD_DIR"
gleam deps download

if gleam test 2>&1; then
  info "PASS: Generated guards reject invalid data end-to-end."
else
  fail "Generated guard E2E tests failed."
fi

# Confirm the default (validate omitted => false) path does NOT emit
# guard calls into router.gleam. This locks the opt-in semantics.
if grep -q "guards.validate_item(" "$GUARD_DIR/src/api/router.gleam"; then
  fail "Default router.gleam unexpectedly calls guards.validate_item — opt-in semantics broken."
else
  info "PASS: Default (validate unset) router.gleam does not embed guard calls."
fi

rm -rf "$GUARD_DIR"

# -------------------------------------------------------
# Step 16: Verify validate:true wires guard calls into generated code
# -------------------------------------------------------
info "Testing validate:true wiring (opt-in guard invocation)..."

GUARD_V_DIR="$SCRIPT_DIR/guard_validate_on_test"
rm -rf "$GUARD_V_DIR"
mkdir -p "$GUARD_V_DIR/src"

cat > "$GUARD_V_DIR/oaspec-guard-v.yaml" << 'YAML_EOF'
input: test/fixtures/guard_constraints_api.yaml
output:
  server: ./integration_test/guard_validate_on_test/src/api
package: api
validate: true
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$GUARD_V_DIR/oaspec-guard-v.yaml" \
  --mode=server

cat > "$GUARD_V_DIR/src/api/handlers.gleam" << 'GLEAM_EOF'
import api/request_types
import api/response_types

pub type State {
  State
}

pub fn create_item(state: State, req: request_types.CreateItemRequest) -> response_types.CreateItemResponse {
  let _ = state
  response_types.CreateItemResponseCreated(req.body)
}
GLEAM_EOF

cat > "$GUARD_V_DIR/gleam.toml" << 'TOML_EOF'
name = "guard_validate_on_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
gleam_regexp = ">= 1.0.0 and < 2.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$GUARD_V_DIR/src/guard_validate_on_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cd "$GUARD_V_DIR"
gleam deps download

if gleam build --warnings-as-errors 2>&1; then
  info "PASS: validate:true code compiles (warnings-as-errors)."
else
  fail "validate:true code failed to compile."
fi

if grep -q "guards.validate_item(" "$GUARD_V_DIR/src/api/router.gleam"; then
  info "PASS: validate:true router.gleam embeds guards.validate_item."
else
  fail "validate:true router.gleam is missing expected guards.validate_item call."
fi

rm -rf "$GUARD_V_DIR"

info "Guard constraint integration tests passed."

# -------------------------------------------------------
# Step 17: Issue #263 — required query/header/cookie/numeric parse
# failures must return 400 instead of crashing the BEAM via let assert.
# This step compiles a tiny spec with one required string query, one
# required integer query, one required header, and one required cookie,
# then drives the generated router with both the happy path and each
# failure mode. A regression that re-introduces `let assert` panics
# would surface here as a test failure (not a compile failure).
# -------------------------------------------------------
info "Testing Issue #263 required-param 400 handling..."

REQ_DIR="$SCRIPT_DIR/required_params_test"
rm -rf "$REQ_DIR"
mkdir -p "$REQ_DIR/src/api" "$REQ_DIR/test"

cat > "$REQ_DIR/required_params.yaml" << 'YAML_EOF'
openapi: "3.0.3"
info:
  title: Required Params Test API
  version: 1.0.0
paths:
  /search:
    get:
      operationId: search
      parameters:
        - name: q
          in: query
          required: true
          schema:
            type: string
        - name: limit
          in: query
          required: true
          schema:
            type: integer
        - name: x-trace-id
          in: header
          required: true
          schema:
            type: string
        - name: session
          in: cookie
          required: true
          schema:
            type: string
      responses:
        "200":
          description: ok
YAML_EOF

cat > "$REQ_DIR/oaspec-req.yaml" << 'YAML_EOF'
input: ./integration_test/required_params_test/required_params.yaml
output:
  server: ./integration_test/required_params_test/src/api
package: api
validate: false
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$REQ_DIR/oaspec-req.yaml" \
  --mode=server

cat > "$REQ_DIR/src/api/handlers.gleam" << 'GLEAM_EOF'
import api/request_types
import api/response_types

pub type State {
  State
}

pub fn search(state: State, req: request_types.SearchRequest) -> response_types.SearchResponse {
  let _ = state
  let _ = req
  response_types.SearchResponseOk
}
GLEAM_EOF

cat > "$REQ_DIR/gleam.toml" << 'TOML_EOF'
name = "required_params_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$REQ_DIR/src/required_params_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cat > "$REQ_DIR/test/required_params_test_test.gleam" << 'GLEAM_EOF'
// Issue #263 — drive the generated router and check each failure mode
// returns ServerResponse(status: 400) instead of crashing the BEAM via
// `let assert`. The happy path verifies the router still reaches the
// handler and returns 200 when every required parameter is supplied.

import api/handlers
import api/router
import gleam/dict
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn full_query() {
  dict.from_list([#("q", ["hello"]), #("limit", ["10"])])
}

fn full_headers() {
  dict.from_list([
    #("x-trace-id", "abc"),
    #("cookie", "session=opaque"),
  ])
}

pub fn happy_path_returns_200_test() {
  let resp =
    router.route(handlers.State, "GET", ["search"], full_query(), full_headers(), "")
  resp.status |> should.equal(200)
}

pub fn missing_required_string_query_returns_400_test() {
  let query = dict.from_list([#("limit", ["10"])])
  let resp = router.route(handlers.State, "GET", ["search"], query, full_headers(), "")
  resp.status |> should.equal(400)
  // Issue #307: 400 responses are now RFC 7807-shaped Problem JSON.
  // Issue #304: bodies are wrapped in `TextBody` so binary responses can
  // ride a `BytesBody(BitArray)` variant on the same type.
  resp.body
  |> should.equal(router.TextBody("{\"type\":\"about:blank\",\"title\":\"missing or invalid parameter\"}"))
  resp.headers
  |> should.equal([#("content-type", "application/problem+json")])
}

pub fn missing_required_integer_query_returns_400_test() {
  let query = dict.from_list([#("q", ["hello"])])
  let resp = router.route(handlers.State, "GET", ["search"], query, full_headers(), "")
  resp.status |> should.equal(400)
}

pub fn unparseable_integer_query_returns_400_test() {
  // limit=not-a-number must NOT crash the BEAM via `let assert`.
  let query = dict.from_list([#("q", ["hello"]), #("limit", ["abc"])])
  let resp = router.route(handlers.State, "GET", ["search"], query, full_headers(), "")
  resp.status |> should.equal(400)
}

pub fn missing_required_header_returns_400_test() {
  let headers = dict.from_list([#("cookie", "session=opaque")])
  let resp = router.route(handlers.State, "GET", ["search"], full_query(), headers, "")
  resp.status |> should.equal(400)
}

pub fn missing_required_cookie_returns_400_test() {
  let headers = dict.from_list([#("x-trace-id", "abc")])
  let resp = router.route(handlers.State, "GET", ["search"], full_query(), headers, "")
  resp.status |> should.equal(400)
}

pub fn empty_query_list_returns_400_test() {
  // dict.get returns Ok([]) when a key is present but holds no value;
  // a router that pattern-matched only `Ok([_, ..])` would crash here.
  let query = dict.from_list([#("q", []), #("limit", ["10"])])
  let resp = router.route(handlers.State, "GET", ["search"], query, full_headers(), "")
  resp.status |> should.equal(400)
}
GLEAM_EOF

cd "$REQ_DIR"
gleam deps download

# Note: this tiny spec has no components/schemas, so the generated
# decode/encode/types modules are intentionally empty. Suppressing
# --warnings-as-errors here keeps the focus on the Issue #263 contract
# (router behaviour on missing/unparseable required params), not on
# warnings inherent to the minimal fixture.
if gleam build; then
  info "PASS: Required-param test code compiles."
else
  fail "Required-param test code failed to compile."
fi

if gleam test; then
  info "PASS: Required-param 400 handling verified."
else
  fail "Required-param 400 handling integration tests failed."
fi

cd "$PROJECT_ROOT"
rm -rf "$REQ_DIR"

info "Issue #263 required-param integration tests passed."

# -------------------------------------------------------
# Step 18: Issue #304 — binary response bodies must round-trip as
# `BytesBody(BitArray)` instead of being smuggled through `String`.
# A spec with an `application/octet-stream` 200 response is generated;
# the handler returns a real PNG header byte sequence, and the test
# asserts the router emits `BytesBody(<<...:bits>>)` with the right
# content-type.
# -------------------------------------------------------
info "Testing Issue #304 binary response body handling..."

BIN_DIR="$SCRIPT_DIR/binary_response_test"
rm -rf "$BIN_DIR"
mkdir -p "$BIN_DIR/src/api" "$BIN_DIR/test"

cat > "$BIN_DIR/binary_response.yaml" << 'YAML_EOF'
openapi: "3.0.3"
info:
  title: Binary Response Test API
  version: 1.0.0
paths:
  /thumbnail:
    get:
      operationId: getThumbnail
      responses:
        "200":
          description: PNG bytes
          content:
            application/octet-stream:
              schema:
                type: string
                format: binary
        "204":
          description: no thumbnail
YAML_EOF

cat > "$BIN_DIR/oaspec-bin.yaml" << 'YAML_EOF'
input: ./integration_test/binary_response_test/binary_response.yaml
output:
  server: ./integration_test/binary_response_test/src/api
package: api
validate: false
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$BIN_DIR/oaspec-bin.yaml" \
  --mode=server

cat > "$BIN_DIR/src/api/handlers.gleam" << 'GLEAM_EOF'
import api/response_types

pub type State {
  State
}

pub fn get_thumbnail(state: State) -> response_types.GetThumbnailResponse {
  let _ = state
  // PNG magic header — real binary, not UTF-8.
  response_types.GetThumbnailResponseOk(<<137, 80, 78, 71, 13, 10, 26, 10>>)
}
GLEAM_EOF

cat > "$BIN_DIR/gleam.toml" << 'TOML_EOF'
name = "binary_response_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$BIN_DIR/src/binary_response_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cat > "$BIN_DIR/test/binary_response_test_test.gleam" << 'GLEAM_EOF'
// Issue #304 — a spec with `application/octet-stream` responses must
// emit `BytesBody(BitArray)` from the generated router so adapters can
// stream real binary bytes (PNGs, file downloads, …) without forcing a
// String round-trip. The matching response_types variant must wrap
// `BitArray`, not `String`.

import api/handlers
import api/router
import gleam/dict
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn binary_response_emits_bytes_body_test() {
  let resp =
    router.route(
      handlers.State,
      "GET",
      ["thumbnail"],
      dict.new(),
      dict.new(),
      "",
    )
  resp.status |> should.equal(200)
  resp.body
  |> should.equal(router.BytesBody(<<137, 80, 78, 71, 13, 10, 26, 10>>))
  resp.headers
  |> should.equal([#("content-type", "application/octet-stream")])
}

pub fn unknown_route_uses_text_body_problem_json_test() {
  // Sanity: the same router still returns a TextBody-shaped Problem
  // JSON for unknown routes, proving text and bytes coexist on the
  // same `ResponseBody` type.
  let resp =
    router.route(
      handlers.State,
      "GET",
      ["nope"],
      dict.new(),
      dict.new(),
      "",
    )
  resp.status |> should.equal(404)
  resp.body
  |> should.equal(router.TextBody("{\"type\":\"about:blank\",\"title\":\"not found\"}"))
}
GLEAM_EOF

cd "$BIN_DIR"
gleam deps download

if gleam build; then
  info "PASS: Binary-response test code compiles."
else
  fail "Binary-response test code failed to compile."
fi

if gleam test; then
  info "PASS: Binary-response BytesBody round-trip verified."
else
  fail "Binary-response integration tests failed."
fi

cd "$PROJECT_ROOT"
rm -rf "$BIN_DIR"

info "Issue #304 binary response integration tests passed."

# -------------------------------------------------------
# Step 19: Issue #306 — typed response headers must reach the wire.
# A spec declaring `responses.<code>.headers` is generated; the handler
# returns body + a populated headers struct; the test asserts the
# router emits both the implicit content-type tuple AND the spec-
# declared header values (skipping None for optional headers).
# -------------------------------------------------------
info "Testing Issue #306 response header plumbing..."

HDR_DIR="$SCRIPT_DIR/response_headers_test"
rm -rf "$HDR_DIR"
mkdir -p "$HDR_DIR/src/api" "$HDR_DIR/test"

cat > "$HDR_DIR/response_headers.yaml" << 'YAML_EOF'
openapi: "3.0.3"
info:
  title: Response Headers Test API
  version: 1.0.0
paths:
  /v1/posts:
    get:
      operationId: listPosts
      responses:
        "200":
          description: page of posts
          headers:
            Pagination-Cursor:
              schema:
                type: string
            Pagination-Limit:
              required: true
              schema:
                type: integer
          content:
            application/json:
              schema:
                type: object
                properties:
                  total:
                    type: integer
        "204":
          description: no posts
          headers:
            X-Cache-Hit:
              required: true
              schema:
                type: boolean
YAML_EOF

cat > "$HDR_DIR/oaspec-hdr.yaml" << 'YAML_EOF'
input: ./integration_test/response_headers_test/response_headers.yaml
output:
  server: ./integration_test/response_headers_test/src/api
package: api
validate: false
YAML_EOF

cd "$PROJECT_ROOT"

gleam run -- generate \
  --config="$HDR_DIR/oaspec-hdr.yaml" \
  --mode=server

cat > "$HDR_DIR/src/api/handlers.gleam" << 'GLEAM_EOF'
import api/response_types
import api/types
import gleam/option.{Some}

pub type State {
  State
}

pub fn list_posts(state: State) -> response_types.ListPostsResponse {
  let _ = state
  response_types.ListPostsResponseOk(
    types.ListPostsResponseOk(total: Some(2)),
    response_types.ListPostsResponseOkHeaders(
      pagination_cursor: Some("opaque-cursor"),
      pagination_limit: 25,
    ),
  )
}
GLEAM_EOF

cat > "$HDR_DIR/gleam.toml" << 'TOML_EOF'
name = "response_headers_test"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
TOML_EOF

cat > "$HDR_DIR/src/response_headers_test.gleam" << 'GLEAM_EOF'
pub fn main() {
  Nil
}
GLEAM_EOF

cat > "$HDR_DIR/test/response_headers_test_test.gleam" << 'GLEAM_EOF'
// Issue #306 — a spec declaring response headers must wire those
// values through `response_types.<Variant>(data, hdrs)` and onto the
// `ServerResponse.headers` list. This test drives a handler that
// returns body + headers and asserts the router lifts both onto the
// wire alongside the implicit content-type tuple.

import api/handlers
import api/router
import gleam/dict
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn declared_response_headers_reach_wire_test() {
  let resp =
    router.route(
      handlers.State,
      "GET",
      ["v1", "posts"],
      dict.new(),
      dict.new(),
      "",
    )
  resp.status |> should.equal(200)

  // The spec-declared headers must appear in the returned headers
  // list. Required Int (Pagination-Limit) is stringified; optional
  // String (Pagination-Cursor) is present because the handler set
  // Some(...). Order is whatever list.flatten produces — assert
  // membership, not position.
  list.contains(resp.headers, #("content-type", "application/json"))
  |> should.be_true()
  list.contains(resp.headers, #("Pagination-Cursor", "opaque-cursor"))
  |> should.be_true()
  list.contains(resp.headers, #("Pagination-Limit", "25"))
  |> should.be_true()
}
GLEAM_EOF

cd "$HDR_DIR"
gleam deps download

if gleam build; then
  info "PASS: Response-headers test code compiles."
else
  fail "Response-headers test code failed to compile."
fi

if gleam test; then
  info "PASS: Response-headers wire plumbing verified."
else
  fail "Response-headers integration tests failed."
fi

cd "$PROJECT_ROOT"
rm -rf "$HDR_DIR"

info "Issue #306 response header integration tests passed."

info "All integration tests passed!"
