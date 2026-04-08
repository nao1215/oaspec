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

export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

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
info "Writing handler implementations (replacing todo stubs)..."

cat > "$SCRIPT_DIR/src/api/handlers.gleam" << 'GLEAM_EOF'
// Hand-written handler implementations for integration testing.
// These replace the generated todo stubs.

import api/request_types
import api/response_types
import api/types
import gleam/option.{None, Some}

/// List all pets - returns hardcoded test data.
pub fn list_pets(req: request_types.ListPetsRequest) -> response_types.ListPetsResponse {
  let _ = req
  let pets = [
    types.Pet(id: 1, name: "Fido", status: types.PetStatusAvailable, tag: Some("dog")),
    types.Pet(id: 2, name: "Whiskers", status: types.PetStatusPending, tag: None),
  ]
  response_types.ListPetsResponseOk(pets)
}

/// Create a pet - returns the created pet.
pub fn create_pet(req: request_types.CreatePetRequest) -> response_types.CreatePetResponse {
  let pet = types.Pet(
    id: 100,
    name: req.body.name,
    status: types.PetStatusAvailable,
    tag: req.body.tag,
  )
  response_types.CreatePetResponseCreated(pet)
}

/// Get a pet by ID.
pub fn get_pet(req: request_types.GetPetRequest) -> response_types.GetPetResponse {
  case req.pet_id {
    1 -> response_types.GetPetResponseOk(
      types.Pet(id: 1, name: "Fido", status: types.PetStatusAvailable, tag: Some("dog")),
    )
    _ -> response_types.GetPetResponseNotFound
  }
}

/// Delete a pet by ID.
pub fn delete_pet(req: request_types.DeletePetRequest) -> response_types.DeletePetResponse {
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

if gleam build 2>&1; then
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

pub fn get_user(req: request_types.GetUserRequest) -> response_types.GetUserResponse {
  let _ = req
  todo
}

pub fn post_search(req: request_types.PostSearchRequest) -> response_types.PostSearchResponse {
  let _ = req
  todo
}

pub fn post_webhook(req: request_types.PostWebhookRequest) -> response_types.PostWebhookResponse {
  let _ = req
  todo
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

if gleam build 2>&1; then
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

info "All integration tests passed!"
