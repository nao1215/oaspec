#!/bin/sh
# shellcheck shell=sh

# Integration tests for oaspec code generation.
# Uses a single generation run for file/content checks to keep tests fast.

Describe 'oaspec top-level help'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  It 'lists available subcommands when called with --help'
    When run oaspec_cli --help
    The status should be success
    The output should include 'Commands:'
    The output should include 'init'
    The output should include 'generate'
    The output should include 'validate'
    The output should include 'version'
  End

  Describe 'colour output'
    # shellspec captures stdout via a pipe, so the CLI sees stdout as
    # non-TTY. Both checks together cover the two suppression paths
    # (TTY check and NO_COLOR honour).
    It 'omits ANSI escape sequences when stdout is not a TTY'
      When run oaspec_cli --help
      The status should be success
      The output should not include "$(printf '\033[')"
    End

    It 'omits ANSI escape sequences when NO_COLOR is set'
      export NO_COLOR=1
      When run oaspec_cli --help
      The status should be success
      The output should not include "$(printf '\033[')"
    End
  End
End

Describe 'oaspec version'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  It 'prints the version when invoked as --version'
    When run oaspec_cli --version
    The status should be success
    The output should include 'oaspec v'
  End

  It 'prints the version when invoked as the version subcommand'
    When run oaspec_cli version
    The status should be success
    The output should include 'oaspec v'
  End
End

Describe 'oaspec generate'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  # -------------------------------------------------------------------
  # Basic CLI behaviour (these need to actually run the CLI)
  # -------------------------------------------------------------------

  Describe 'CLI help'
    It 'shows usage when called with --help'
      When run generate --help
      The status should be success
      The output should include 'generate'
      The output should include 'config'
    End
  End

  Describe 'error handling'
    It 'exits with error when config file does not exist'
      When run generate --config=nonexistent.yaml
      The status should be failure
      The output should include 'Error'
    End

    # Issue #398: a spec with parse-level breakage (`error_missing_info.yaml`
    # has no `info:` key, which the parser requires) must surface as a
    # non-zero exit with a diagnostic, not as silent success or a panic.
    It 'exits non-zero when the spec fails to parse'
      setup_missing_info_config() {
        rm -rf "$PROJECT_ROOT/test_missing_info"
        cat > "$PROJECT_ROOT/test_missing_info.yaml" <<EOF
input: test/fixtures/error_missing_info.yaml
package: api
output:
  dir: ./test_missing_info
EOF
      }
      cleanup_missing_info_config() {
        rm -rf "$PROJECT_ROOT/test_missing_info" "$PROJECT_ROOT/test_missing_info.yaml"
      }
      setup_missing_info_config
      When run generate --config=./test_missing_info.yaml
      The status should be failure
      The output should include 'Error'
      cleanup_missing_info_config
    End
  End

  Describe '--output flag (Issue #433)'
    setup_output_flag_dir() {
      rm -rf "$PROJECT_ROOT/test_output_flag_eq" "$PROJECT_ROOT/test_output_flag_sp"
    }
    cleanup_output_flag_dir() {
      rm -rf "$PROJECT_ROOT/test_output_flag_eq" "$PROJECT_ROOT/test_output_flag_sp"
    }
    Before 'setup_output_flag_dir'
    After 'cleanup_output_flag_dir'

    It 'writes generated files under --output=DIR'
      When run generate --config=test/fixtures/oaspec.yaml --output=./test_output_flag_eq
      The status should be success
      The output should include 'Successfully generated'
      The path "$PROJECT_ROOT/test_output_flag_eq" should be directory
    End

    It 'writes generated files under --output DIR (space form)'
      When run generate --config=test/fixtures/oaspec.yaml --output ./test_output_flag_sp
      The status should be success
      The output should include 'Successfully generated'
      The path "$PROJECT_ROOT/test_output_flag_sp" should be directory
    End
  End

  Describe 'successful generation'
    It 'exits successfully and reports file count'
      clean_test_output
      When run generate --config=test/fixtures/oaspec.yaml
      The status should be success
      The output should include 'Successfully generated'
      The output should include '16 files'
    End

    It 'accepts space-separated --config FILE form'
      clean_test_output
      When run generate --config test/fixtures/oaspec.yaml
      The status should be success
      The output should include 'Successfully generated'
    End

    It 'accepts space-separated --mode VALUE form'
      clean_test_output
      When run generate --config test/fixtures/oaspec.yaml --mode server
      The status should be success
      The output should include 'Successfully generated'
    End
  End

  Describe 'pattern constraint dependency hint (Issue #284)'
    It 'prints a Note about gleam_regexp when generated code uses pattern validation'
      clean_test_output
      When run generate --config=test/fixtures/oaspec_guards_pattern.yaml
      The status should be success
      The output should include 'Successfully generated'
      The output should include 'gleam/regexp for pattern validation'
      The output should include "gleam add gleam_regexp"
    End

    It 'does not print the Note when no patterns are present'
      clean_test_output
      When run generate --config=test/fixtures/oaspec.yaml
      The status should be success
      The output should include 'Successfully generated'
      The output should not include 'gleam_regexp'
    End
  End

  # -------------------------------------------------------------------
  # File existence checks (generate once, check many)
  # -------------------------------------------------------------------

  Describe 'generated files'
    BeforeAll 'clean_test_output'
    BeforeAll 'generate_petstore_once'
    AfterAll 'clean_test_output'

    # --- Server files ---

    It 'creates server/types.gleam'
      The path "$TEST_OUTPUT_DIR/api/types.gleam" should be file
    End

    It 'creates server/request_types.gleam'
      The path "$TEST_OUTPUT_DIR/api/request_types.gleam" should be file
    End

    It 'creates server/response_types.gleam'
      The path "$TEST_OUTPUT_DIR/api/response_types.gleam" should be file
    End

    It 'creates server/decode.gleam'
      The path "$TEST_OUTPUT_DIR/api/decode.gleam" should be file
    End

    It 'creates server/encode.gleam'
      The path "$TEST_OUTPUT_DIR/api/encode.gleam" should be file
    End

    It 'creates server/handlers.gleam'
      The path "$TEST_OUTPUT_DIR/api/handlers.gleam" should be file
    End

    It 'creates server/handlers_generated.gleam (Issue #247 sealed delegator)'
      The path "$TEST_OUTPUT_DIR/api/handlers_generated.gleam" should be file
    End

    It 'creates server/router.gleam'
      The path "$TEST_OUTPUT_DIR/api/router.gleam" should be file
    End

    # --- Client files ---

    It 'creates client/types.gleam'
      The path "$TEST_OUTPUT_DIR_CLIENT/api/types.gleam" should be file
    End

    It 'creates client/client.gleam'
      The path "$TEST_OUTPUT_DIR_CLIENT/api/client.gleam" should be file
    End
  End

  # -------------------------------------------------------------------
  # Generated code content verification (reuses the same output)
  # -------------------------------------------------------------------

  Describe 'generated code content'
    BeforeAll 'generate_petstore_once'

    # --- File header ---

    It 'types.gleam has auto-generation header'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'Code generated by oaspec'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'DO NOT EDIT'
    End

    # --- Types ---

    It 'generates Pet type with correct fields'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'pub type Pet {'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'id: Int'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'name: String'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'status: PetStatus'
    End

    It 'generates PetStatus enum variants'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'pub type PetStatus {'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'PetStatusAvailable'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'PetStatusPending'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'PetStatusSold'
    End

    It 'generates CreatePetRequest type'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'pub type CreatePetRequest {'
    End

    It 'generates Error type'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'pub type Error {'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'code: Int'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'message: String'
    End

    It 'marks optional fields with Option type'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'tag: Option(String)'
    End

    # --- OpenAPI description propagation ---

    It 'propagates schema descriptions as doc comments'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include '/// A pet in the store'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include '/// The status of a pet in the store'
    End

    # --- Request types ---

    It 'generates ListPetsRequest with query parameters'
      The contents of file "$TEST_OUTPUT_DIR/api/request_types.gleam" should include 'pub type ListPetsRequest {'
      The contents of file "$TEST_OUTPUT_DIR/api/request_types.gleam" should include 'limit: Option(Int)'
      The contents of file "$TEST_OUTPUT_DIR/api/request_types.gleam" should include 'offset: Option(Int)'
    End

    It 'generates GetPetRequest with path parameter'
      The contents of file "$TEST_OUTPUT_DIR/api/request_types.gleam" should include 'pub type GetPetRequest {'
      The contents of file "$TEST_OUTPUT_DIR/api/request_types.gleam" should include 'pet_id: Int'
    End

    # --- Response types ---

    It 'generates response types with status code variants'
      The contents of file "$TEST_OUTPUT_DIR/api/response_types.gleam" should include 'pub type ListPetsResponse {'
      The contents of file "$TEST_OUTPUT_DIR/api/response_types.gleam" should include 'ResponseOk'
      The contents of file "$TEST_OUTPUT_DIR/api/response_types.gleam" should include 'ResponseUnauthorized'
    End

    It 'generates CreatePetResponse with Created and BadRequest variants'
      The contents of file "$TEST_OUTPUT_DIR/api/response_types.gleam" should include 'pub type CreatePetResponse {'
      The contents of file "$TEST_OUTPUT_DIR/api/response_types.gleam" should include 'ResponseCreated'
      The contents of file "$TEST_OUTPUT_DIR/api/response_types.gleam" should include 'ResponseBadRequest'
    End

    It 'generates DeletePetResponse with NoContent variant'
      The contents of file "$TEST_OUTPUT_DIR/api/response_types.gleam" should include 'ResponseNoContent'
    End

    # --- Decoders ---

    It 'generates decoder functions using gleam/dynamic/decode'
      The contents of file "$TEST_OUTPUT_DIR/api/decode.gleam" should include 'import gleam/dynamic/decode'
      The contents of file "$TEST_OUTPUT_DIR/api/decode.gleam" should include 'pub fn decode_pet'
      The contents of file "$TEST_OUTPUT_DIR/api/decode.gleam" should include 'decode.field'
    End

    It 'generates enum decoder with pattern matching'
      The contents of file "$TEST_OUTPUT_DIR/api/decode.gleam" should include 'pub fn decode_pet_status'
      The contents of file "$TEST_OUTPUT_DIR/api/decode.gleam" should include '"available"'
      The contents of file "$TEST_OUTPUT_DIR/api/decode.gleam" should include '"pending"'
      The contents of file "$TEST_OUTPUT_DIR/api/decode.gleam" should include '"sold"'
    End

    It 'enum decoder rejects unknown values with decode.failure'
      The contents of file "$TEST_OUTPUT_DIR/api/decode.gleam" should include 'decode.failure'
    End

    # --- Encoders ---

    It 'generates encoder functions with _json and String variants'
      The contents of file "$TEST_OUTPUT_DIR/api/encode.gleam" should include 'import gleam/json'
      The contents of file "$TEST_OUTPUT_DIR/api/encode.gleam" should include 'pub fn encode_pet_json'
      The contents of file "$TEST_OUTPUT_DIR/api/encode.gleam" should include 'pub fn encode_pet('
      The contents of file "$TEST_OUTPUT_DIR/api/encode.gleam" should include 'json.object'
    End

    It 'ref encoder uses _json function not json.string wrapper'
      The contents of file "$TEST_OUTPUT_DIR/api/encode.gleam" should include 'encode_pet_status_json(value.status)'
    End

    # --- Server handlers ---

    It 'generates handler stubs with panic placeholders'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers.gleam" should include 'pub fn list_pets'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers.gleam" should include 'pub fn create_pet'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers.gleam" should include 'pub fn get_pet'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers.gleam" should include 'pub fn delete_pet'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers.gleam" should include 'panic as "unimplemented:'
    End

    It 'handler signatures reference request and response types'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers.gleam" should include 'import api/request_types'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers.gleam" should include 'import api/response_types'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers.gleam" should include 'request_types.ListPetsRequest'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers.gleam" should include 'response_types.ListPetsResponse'
    End

    It 'user-owned handlers.gleam has no DO NOT EDIT banner (Issue #247)'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers.gleam" should not include 'DO NOT EDIT'
    End

    # --- handlers_generated.gleam (Issue #247 sealed delegator) ---

    It 'handlers_generated.gleam carries the DO NOT EDIT banner'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers_generated.gleam" should include 'DO NOT EDIT'
    End

    It 'handlers_generated.gleam imports the user handlers module'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers_generated.gleam" should include 'import api/handlers'
    End

    It 'handlers_generated.gleam delegates each operation to handlers'
      # Issue #264: every delegator threads `state` as the first
      # argument before the request value.
      The contents of file "$TEST_OUTPUT_DIR/api/handlers_generated.gleam" should include 'handlers.list_pets(state, req)'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers_generated.gleam" should include 'handlers.create_pet(state, req)'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers_generated.gleam" should include 'handlers.get_pet(state, req)'
      The contents of file "$TEST_OUTPUT_DIR/api/handlers_generated.gleam" should include 'handlers.delete_pet(state, req)'
    End

    # --- Router ---

    It 'generates router with path matching'
      The contents of file "$TEST_OUTPUT_DIR/api/router.gleam" should include 'pub fn route'
      The contents of file "$TEST_OUTPUT_DIR/api/router.gleam" should include '"GET"'
      The contents of file "$TEST_OUTPUT_DIR/api/router.gleam" should include '"POST"'
      The contents of file "$TEST_OUTPUT_DIR/api/router.gleam" should include '"DELETE"'
    End

    It 'router dispatches via handlers_generated (Issue #247)'
      The contents of file "$TEST_OUTPUT_DIR/api/router.gleam" should include 'import api/handlers_generated'
      The contents of file "$TEST_OUTPUT_DIR/api/router.gleam" should include 'handlers_generated.'
    End

    # --- Client ---

    It 'generates client functions for each operation'
      The contents of file "$TEST_OUTPUT_DIR_CLIENT/api/client.gleam" should include 'pub fn list_pets'
      The contents of file "$TEST_OUTPUT_DIR_CLIENT/api/client.gleam" should include 'pub fn create_pet'
      The contents of file "$TEST_OUTPUT_DIR_CLIENT/api/client.gleam" should include 'pub fn get_pet'
      The contents of file "$TEST_OUTPUT_DIR_CLIENT/api/client.gleam" should include 'pub fn delete_pet'
    End

    It 'client uses oaspec/transport instead of gleam/http/request'
      The contents of file "$TEST_OUTPUT_DIR_CLIENT/api/client.gleam" should include 'import oaspec/transport'
      The contents of file "$TEST_OUTPUT_DIR_CLIENT/api/client.gleam" should include 'transport.Request('
      The contents of file "$TEST_OUTPUT_DIR_CLIENT/api/client.gleam" should not include 'import gleam/http/request'
    End

    It 'client emits the build/decode/op trio'
      The contents of file "$TEST_OUTPUT_DIR_CLIENT/api/client.gleam" should include 'pub fn build_list_pets_request'
      The contents of file "$TEST_OUTPUT_DIR_CLIENT/api/client.gleam" should include 'pub fn decode_list_pets_response'
      The contents of file "$TEST_OUTPUT_DIR_CLIENT/api/client.gleam" should include 'send send: transport.Send'
    End

    # --- Middleware ---

    # middleware.gleam is intentionally no longer emitted (see issue #116).
  End

  # -------------------------------------------------------------------
  # Mode-specific generation
  # -------------------------------------------------------------------

  Describe 'mode=server'
    It 'generates only server files'
      clean_test_output
      When run generate --config=test/fixtures/oaspec.yaml --mode=server
      The status should be success
      The output should include 'Successfully generated'
      The path "$TEST_OUTPUT_DIR/api/handlers.gleam" should be file
      The path "$TEST_OUTPUT_DIR/api/router.gleam" should be file
      The path "$TEST_OUTPUT_DIR_CLIENT/api" should not be exist
    End
  End

  Describe 'mode=client'
    It 'generates only client files'
      clean_test_output
      When run generate --config=test/fixtures/oaspec.yaml --mode=client
      The status should be success
      The output should include 'Successfully generated'
      The path "$TEST_OUTPUT_DIR_CLIENT/api/client.gleam" should be file
      The path "$TEST_OUTPUT_DIR/api" should not be exist
    End
  End

  # -------------------------------------------------------------------
  # Unsupported feature validation
  # -------------------------------------------------------------------

  # deepObject and multipart/form-data remain unsupported for server
  # generation, but client-only generation should still succeed.
  Describe 'client mode filters server-only validation errors'
    It 'generates successfully for specs with deepObject and inline oneOf'
      clean_test_output
      When run generate --config=test/fixtures/broken-oaspec.yaml --mode=client
      The status should be success
      The output should include 'Successfully generated'
      The path "$TEST_OUTPUT_DIR_CLIENT/api/client.gleam" should be file
      The path "$TEST_OUTPUT_DIR/api" should not be exist
    End
  End

  # -------------------------------------------------------------------
  # Complex supported spec (inline objects, oneOf $ref, allOf, enums)
  # -------------------------------------------------------------------

  Describe 'complex supported spec'
    BeforeAll 'clean_test_output'

    It 'generates successfully'
      When run generate --config=test/fixtures/complex-supported-oaspec.yaml
      The status should be success
      The output should include 'Successfully generated'
    End
  End

  Describe 'complex supported spec content'
    BeforeAll 'generate_complex_supported_once'

    # Inline enum types

    It 'generates inline enum for User.type'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'pub type UserType {'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'UserTypeAdmin'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'UserTypeRegular'
    End

    It 'generates inline enum for Filter.op'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'pub type FilterOp {'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'FilterOpEq'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'FilterOpNe'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'FilterOpGt'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'FilterOpLt'
    End

    It 'references inline enum type in Filter.op field'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'op: FilterOp'
    End

    # Inline object in response

    It 'generates anonymous type for inline response object'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'pub type PostSearchResponseOk {'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'results: Option(List(User))'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'total: Option(Int)'
    End

    # oneOf with $ref in response

    It 'generates oneOf type with $ref variants'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'pub type GetUserResponseOk {'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'GetUserResponseOkAdminUser(AdminUser)'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'GetUserResponseOkRegularUser(RegularUser)'
    End

    # allOf merged requestBody

    It 'generates merged allOf type for request body'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'pub type PostSearchRequest {'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'page: Option(Int)'
      The contents of file "$TEST_OUTPUT_DIR/api/types.gleam" should include 'query: Option(String)'
    End

    # Response types reference anonymous types

    It 'response types reference anonymous types correctly'
      The contents of file "$TEST_OUTPUT_DIR/api/response_types.gleam" should include 'PostSearchResponseOk(types.PostSearchResponseOk)'
      The contents of file "$TEST_OUTPUT_DIR/api/response_types.gleam" should include 'GetUserResponseOk(types.GetUserResponseOk)'
    End

    # Request types reference merged allOf type

    It 'request types reference merged allOf body type (optional since required defaults to false)'
      The contents of file "$TEST_OUTPUT_DIR/api/request_types.gleam" should include 'body: Option(types.PostSearchRequest)'
    End
  End
End

# ===================================================================
# Validate subcommand tests
# ===================================================================

Describe 'oaspec validate'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  Describe 'CLI help'
    It 'shows usage when called with --help'
      When run validate_spec --help
      The status should be success
      The output should include 'validate'
      The output should include 'config'
    End
  End

  Describe 'successful validation'
    It 'validates a valid spec without generating files'
      clean_test_output
      When run validate_spec --config=test/fixtures/oaspec.yaml
      The status should be success
      The output should include 'Validation passed'
      The output should not include 'Generated'
      The output should not include 'Successfully generated'
    End

    It 'does not write any files'
      clean_test_output
      When run validate_spec --config=test/fixtures/oaspec.yaml
      The status should be success
      The output should not include 'Generated:'
    End
  End

  Describe 'error handling'
    It 'exits with error when config file does not exist'
      When run validate_spec --config=nonexistent.yaml
      The status should be failure
      The output should include 'Error'
    End

    # Issue #399: validate must exit non-zero when the spec fails to
    # parse (no info field). Without this, a regression that swallowed
    # parse errors and returned 0 would defeat validate's CI value.
    It 'exits non-zero when the underlying spec fails to parse'
      setup_validate_missing_info_config() {
        cat > "$PROJECT_ROOT/test_validate_missing_info.yaml" <<EOF
input: test/fixtures/error_missing_info.yaml
package: api
output:
  dir: ./test_validate_missing_info
EOF
      }
      cleanup_validate_missing_info_config() {
        rm -f "$PROJECT_ROOT/test_validate_missing_info.yaml"
      }
      setup_validate_missing_info_config
      When run validate_spec --config=./test_validate_missing_info.yaml
      The status should be failure
      The output should include 'Error'
      cleanup_validate_missing_info_config
    End

    # Issue #399: --mode=client must be accepted on the CLI surface.
    # Whether the fixture ultimately passes depends on the spec; the
    # test pins that the flag is parsed (no usage error) and the CLI
    # produces typed output instead of crashing.
    It 'accepts the --mode=client override flag without crashing'
      When run validate_spec --config=test/fixtures/oaspec.yaml --mode=client
      The status should be success
      The output should include 'Validation passed'
    End
  End
End

# ===================================================================
# Issue #400: oaspec init subcommand
# ===================================================================
#
# Pin the init subcommand's three documented behaviors:
# default-output write, --output PATH override, and overwrite refusal.

Describe 'oaspec init'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  setup_init_dir() {
    rm -rf "$PROJECT_ROOT/test_init_dir"
    mkdir -p "$PROJECT_ROOT/test_init_dir"
  }

  cleanup_init_dir() {
    rm -rf "$PROJECT_ROOT/test_init_dir"
  }

  init_default_output() {
    ( cd "$PROJECT_ROOT/test_init_dir" \
      && gleam run --no-print-progress -- init )
  }

  init_with_output_path() {
    ( cd "$PROJECT_ROOT/test_init_dir" \
      && gleam run --no-print-progress -- init --output=./custom.yaml )
  }

  init_twice() {
    ( cd "$PROJECT_ROOT/test_init_dir" \
      && gleam run --no-print-progress -- init > /dev/null \
      && gleam run --no-print-progress -- init )
  }

  Before 'setup_init_dir'
  After 'cleanup_init_dir'

  It 'writes ./oaspec.yaml by default and reports the path'
    When run init_default_output
    The status should be success
    The output should include 'Created'
    The path "$PROJECT_ROOT/test_init_dir/oaspec.yaml" should be file
  End

  It 'writes to the location given via --output=PATH'
    When run init_with_output_path
    The status should be success
    The output should include 'Created'
    The path "$PROJECT_ROOT/test_init_dir/custom.yaml" should be file
  End

  It 'refuses to overwrite an existing target'
    When run init_twice
    The status should be failure
    The stderr should include 'already exists'
  End
End

# ===================================================================
# output.dir default derivation tests (Issue #248)
# ===================================================================

Describe 'oaspec output.dir default derivation'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  setup_dir_only_config() {
    rm -rf "$PROJECT_ROOT/test_dir_only"
    cat > "$PROJECT_ROOT/test_dir_only.yaml" <<EOF
input: test/fixtures/petstore.yaml
package: api
output:
  dir: ./test_dir_only
EOF
  }

  cleanup_dir_only_config() {
    rm -rf "$PROJECT_ROOT/test_dir_only" "$PROJECT_ROOT/test_dir_only.yaml"
  }

  Before 'setup_dir_only_config'
  After 'cleanup_dir_only_config'

  It 'puts server under <dir>/<package> and client under <dir>/<package>_client'
    When run generate --config=./test_dir_only.yaml
    The status should be success
    The output should include 'Successfully generated'
    The path "$PROJECT_ROOT/test_dir_only/api/types.gleam" should be file
    The path "$PROJECT_ROOT/test_dir_only/api_client/types.gleam" should be file
    # Both default paths must land inside <dir> so that `gleam build` rooted
    # at <dir> picks up both. The pre-#248 sibling `./test_dir_only_client/`
    # location must NOT be written.
    The path "$PROJECT_ROOT/test_dir_only_client" should not be exist
  End
End

# ===================================================================
# Nested package paths (Issue #387)
# ===================================================================

Describe 'oaspec nested package'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  setup_nested_pkg() {
    rm -rf "$PROJECT_ROOT/test_nested_pkg"
    cat > "$PROJECT_ROOT/test_nested_pkg.yaml" <<EOF
input: test/fixtures/petstore.yaml
package: dco_check/github
output:
  dir: ./test_nested_pkg
EOF
    # Match `generate_petstore_once` in spec_helper.sh: silence both
    # streams so the BeforeAll hook produces no output (shellspec
    # treats stdout from BeforeAll as a hook error).
    cd "$PROJECT_ROOT" && gleam run -- generate --config=./test_nested_pkg.yaml >/dev/null 2>&1
  }

  cleanup_nested_pkg() {
    rm -rf "$PROJECT_ROOT/test_nested_pkg" "$PROJECT_ROOT/test_nested_pkg.yaml"
  }

  BeforeAll 'setup_nested_pkg'
  AfterAll 'cleanup_nested_pkg'

  # Server tree: <dir>/dco_check/github/...
  It 'writes server files under <dir>/<a>/<b>'
    The path "$PROJECT_ROOT/test_nested_pkg/dco_check/github/types.gleam" should be file
    The path "$PROJECT_ROOT/test_nested_pkg/dco_check/github/router.gleam" should be file
  End

  # Client tree: <dir>/dco_check/github_client/... — `_client` suffix
  # attaches to the LAST package segment only.
  It 'writes client files under <dir>/<a>/<b>_client'
    The path "$PROJECT_ROOT/test_nested_pkg/dco_check/github_client/types.gleam" should be file
    The path "$PROJECT_ROOT/test_nested_pkg/dco_check/github_client/client.gleam" should be file
  End

  # Regression guard: the pre-#387 single-segment fallback
  # `<dir>/dco_check_github` (slashes stripped) must NOT be written.
  It 'does not write the slashes-stripped fallback path'
    The path "$PROJECT_ROOT/test_nested_pkg/dco_check_github" should not be exist
  End

  # Generated code must import the full `<a>/<b>` module path so the
  # Gleam compiler resolves it against `<dir>/<a>/<b>/...`. #387 was
  # reported precisely because the validator rejected the layout that
  # makes these imports compilable.
  It 'client imports reference the nested package'
    The contents of file "$PROJECT_ROOT/test_nested_pkg/dco_check/github_client/client.gleam" should include 'import dco_check/github/types'
  End

  It 'router imports reference the nested package'
    The contents of file "$PROJECT_ROOT/test_nested_pkg/dco_check/github/router.gleam" should include 'import dco_check/github/handlers_generated'
  End
End

# ===================================================================
# `oaspec init` round-trip — Issue #387 follow-up
# ===================================================================
#
# `init` creates a default oaspec.yaml. After Issue #387 added
# `include:` and `targets:` to the schema, the template grew new
# commented-out blocks documenting both. The parser must still load
# the shipped template cleanly (the new blocks are comments, but a
# stray colon or indent slip would only surface in a CI run).

Describe 'oaspec init round-trip'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  setup_init_round_trip() {
    rm -rf "$PROJECT_ROOT/test_init_round_trip"
    mkdir -p "$PROJECT_ROOT/test_init_round_trip"
    cp "$PROJECT_ROOT/test/fixtures/petstore.yaml" \
       "$PROJECT_ROOT/test_init_round_trip/openapi.yaml"
  }

  cleanup_init_round_trip() {
    rm -rf "$PROJECT_ROOT/test_init_round_trip"
  }

  # Shellspec evaluates the It body in the host shell, so any
  # `cd` inside it leaks across cases and outlives `After`.
  # Wrap the steps in subshell helpers (`( cd ...; ... )`) so the
  # working directory only changes inside `When run`'s subprocess
  # — cleanup can then `rm -rf` the test dir without yanking the
  # parent shell's cwd.
  init_in_test_dir() {
    ( cd "$PROJECT_ROOT/test_init_round_trip" \
      && gleam run --no-print-progress -- init --output=./oaspec.yaml )
  }

  init_then_validate_in_test_dir() {
    ( cd "$PROJECT_ROOT/test_init_round_trip" \
      && gleam run --no-print-progress -- init --output=./oaspec.yaml \
           > /dev/null \
      && gleam run --no-print-progress -- validate --config=./oaspec.yaml )
  }

  Before 'setup_init_round_trip'
  After 'cleanup_init_round_trip'

  It 'creates an oaspec.yaml that the validator can load and parse'
    When run init_in_test_dir
    The status should be success
    The output should include 'Created'
    The path "$PROJECT_ROOT/test_init_round_trip/oaspec.yaml" should be file
  End

  It 'validates against a real spec without parse errors'
    # Generates the template via init, then runs validate against
    # the petstore stub copied as openapi.yaml above. If the
    # template's commented include / targets blocks broke the
    # YAML parser, this would fail before any validation logic ran.
    When run init_then_validate_in_test_dir
    The status should be success
    The output should include 'Validation passed'
  End
End

# ===================================================================
# Issue #387 — `include:` filter (subset of operations)
# ===================================================================
#
# `include.tags` and `include.paths` let users generate code for a
# subset of the spec without modifying the spec itself. Operations
# pass when their tag list intersects `include.tags` OR their path
# matches one of `include.paths` (`/foo/**` matches anything under
# `/foo/`). Both lists empty == no filter.

Describe 'oaspec include filter'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  setup_path_filter_config() {
    rm -rf "$PROJECT_ROOT/test_include_path"
    cat > "$PROJECT_ROOT/test_include_path.yaml" <<EOF
input: test/fixtures/petstore.yaml
package: api
output:
  dir: ./test_include_path
include:
  paths:
    - "/pets"
EOF
  }

  cleanup_path_filter_config() {
    rm -rf "$PROJECT_ROOT/test_include_path" \
           "$PROJECT_ROOT/test_include_path.yaml"
  }

  Describe 'path filter'
    Before 'setup_path_filter_config'
    After 'cleanup_path_filter_config'

    It 'keeps only the operations on the matched path'
      When run generate --config=./test_include_path.yaml
      The status should be success
      The output should include 'Successfully generated'
      # /pets stays (listPets, createPet) but /pets/{petId} is filtered
      # out, so its operations must NOT appear in handlers.gleam.
      The contents of file "$PROJECT_ROOT/test_include_path/api/handlers.gleam" should include 'pub fn list_pets'
      The contents of file "$PROJECT_ROOT/test_include_path/api/handlers.gleam" should include 'pub fn create_pet'
      The contents of file "$PROJECT_ROOT/test_include_path/api/handlers.gleam" should not include 'pub fn get_pet'
      The contents of file "$PROJECT_ROOT/test_include_path/api/handlers.gleam" should not include 'pub fn delete_pet'
    End
  End

  setup_glob_filter_config() {
    rm -rf "$PROJECT_ROOT/test_include_glob"
    cat > "$PROJECT_ROOT/test_include_glob.yaml" <<EOF
input: test/fixtures/petstore.yaml
package: api
output:
  dir: ./test_include_glob
include:
  paths:
    - "/pets/**"
EOF
  }

  cleanup_glob_filter_config() {
    rm -rf "$PROJECT_ROOT/test_include_glob" \
           "$PROJECT_ROOT/test_include_glob.yaml"
  }

  Describe 'path glob filter'
    Before 'setup_glob_filter_config'
    After 'cleanup_glob_filter_config'

    It 'keeps only operations under the glob prefix'
      When run generate --config=./test_include_glob.yaml
      The status should be success
      The output should include 'Successfully generated'
      # `/pets/**` matches `/pets/{petId}` (getPet, deletePet) but
      # NOT the bare `/pets` path itself (which has listPets and
      # createPet) — that is the documented strict-prefix glob
      # behaviour.
      The contents of file "$PROJECT_ROOT/test_include_glob/api/handlers.gleam" should include 'pub fn get_pet'
      The contents of file "$PROJECT_ROOT/test_include_glob/api/handlers.gleam" should include 'pub fn delete_pet'
      The contents of file "$PROJECT_ROOT/test_include_glob/api/handlers.gleam" should not include 'pub fn list_pets'
      The contents of file "$PROJECT_ROOT/test_include_glob/api/handlers.gleam" should not include 'pub fn create_pet'
    End
  End

  setup_tag_filter_config() {
    rm -rf "$PROJECT_ROOT/test_include_tag"
    cat > "$PROJECT_ROOT/test_include_tag.yaml" <<EOF
input: test/fixtures/petstore.yaml
package: api
output:
  dir: ./test_include_tag
include:
  tags:
    - pets
EOF
  }

  cleanup_tag_filter_config() {
    rm -rf "$PROJECT_ROOT/test_include_tag" \
           "$PROJECT_ROOT/test_include_tag.yaml"
  }

  Describe 'tag filter'
    Before 'setup_tag_filter_config'
    After 'cleanup_tag_filter_config'

    It 'keeps every operation tagged with the listed tag'
      When run generate --config=./test_include_tag.yaml
      The status should be success
      The output should include 'Successfully generated'
      # All petstore operations are tagged `pets`, so the tag
      # filter is a no-op for this fixture — but the run still
      # demonstrates that tag-based filtering parses and applies
      # without error.
      The contents of file "$PROJECT_ROOT/test_include_tag/api/handlers.gleam" should include 'pub fn list_pets'
      The contents of file "$PROJECT_ROOT/test_include_tag/api/handlers.gleam" should include 'pub fn get_pet'
    End
  End
End

# ===================================================================
# Issue #387 — `targets:` array (multi-target codegen)
# ===================================================================
#
# Splits a single spec into multiple Gleam packages in one
# `oaspec generate` run. Each `targets:` entry has its own
# `package`, `output`, and `include`, but all entries share the
# top-level `input`, `mode`, and `validate`. The CLI parses the
# spec once and runs the per-target pipeline (filter → capability
# check → hoist → dedup → validate → codegen → write) for each
# target in order.

Describe 'oaspec multi-target generate'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  setup_multi_target_config() {
    rm -rf "$PROJECT_ROOT/test_multi_targets"
    cat > "$PROJECT_ROOT/test_multi_targets.yaml" <<EOF
input: test/fixtures/petstore.yaml
mode: client
targets:
  - package: petshop/listing
    output:
      dir: ./test_multi_targets
    include:
      paths:
        - "/pets"
  - package: petshop/details
    output:
      dir: ./test_multi_targets
    include:
      paths:
        - "/pets/**"
EOF
  }

  cleanup_multi_target_config() {
    rm -rf "$PROJECT_ROOT/test_multi_targets" \
           "$PROJECT_ROOT/test_multi_targets.yaml"
  }

  Before 'setup_multi_target_config'
  After 'cleanup_multi_target_config'

  It 'writes one package per target with its filtered subset'
    When run generate --config=./test_multi_targets.yaml
    The status should be success
    The output should include 'Successfully generated'
    The output should include '[target: petshop/listing]'
    The output should include '[target: petshop/details]'
    # listing target: only the /pets operations land in its client.
    The path "$PROJECT_ROOT/test_multi_targets/petshop/listing/client.gleam" should be file
    The contents of file "$PROJECT_ROOT/test_multi_targets/petshop/listing/client.gleam" should include 'pub fn list_pets'
    The contents of file "$PROJECT_ROOT/test_multi_targets/petshop/listing/client.gleam" should include 'pub fn create_pet'
    The contents of file "$PROJECT_ROOT/test_multi_targets/petshop/listing/client.gleam" should not include 'pub fn get_pet'
    The contents of file "$PROJECT_ROOT/test_multi_targets/petshop/listing/client.gleam" should not include 'pub fn delete_pet'
    # details target: only the /pets/** operations land in its client.
    The path "$PROJECT_ROOT/test_multi_targets/petshop/details/client.gleam" should be file
    The contents of file "$PROJECT_ROOT/test_multi_targets/petshop/details/client.gleam" should include 'pub fn get_pet'
    The contents of file "$PROJECT_ROOT/test_multi_targets/petshop/details/client.gleam" should include 'pub fn delete_pet'
    The contents of file "$PROJECT_ROOT/test_multi_targets/petshop/details/client.gleam" should not include 'pub fn list_pets'
    The contents of file "$PROJECT_ROOT/test_multi_targets/petshop/details/client.gleam" should not include 'pub fn create_pet'
  End

  setup_multi_target_overlap_config() {
    rm -rf "$PROJECT_ROOT/test_multi_targets_overlap"
    # Two targets with the same package would write to the same
    # directory. The CLI must reject this before any file is written.
    cat > "$PROJECT_ROOT/test_multi_targets_overlap.yaml" <<EOF
input: test/fixtures/petstore.yaml
mode: client
targets:
  - package: shared/api
    output:
      dir: ./test_multi_targets_overlap
    include:
      paths:
        - "/pets"
  - package: shared/api
    output:
      dir: ./test_multi_targets_overlap
    include:
      paths:
        - "/pets/**"
EOF
  }

  cleanup_multi_target_overlap_config() {
    rm -rf "$PROJECT_ROOT/test_multi_targets_overlap" \
           "$PROJECT_ROOT/test_multi_targets_overlap.yaml"
  }

  Describe 'overlap detection'
    Before 'setup_multi_target_overlap_config'
    After 'cleanup_multi_target_overlap_config'

    It 'rejects configs whose targets resolve to the same output dir'
      When run generate --config=./test_multi_targets_overlap.yaml
      The status should be failure
      The output should include 'two targets resolve to the same output directory'
      The path "$PROJECT_ROOT/test_multi_targets_overlap" should not be exist
    End
  End

  setup_single_target_shared_output_config() {
    rm -rf "$PROJECT_ROOT/test_single_shared_output"
    # A single config with mode: both whose `output.server` and
    # `output.client` resolve to the same directory is the legitimate
    # case the golden/petstore.oaspec.yaml fixture has used since the
    # repo started. The codegen writes shared files (types, decode,
    # encode, guards, request_types, response_types) with identical
    # content for both modes, plus server-only files (router,
    # handlers, handlers_generated) and one client-only file
    # (client.gleam) with unique names — so a shared output directory
    # never clobbers anything. The CLI must accept this; the
    # multi-target overlap check above only catches cross-config
    # collisions.
    cat > "$PROJECT_ROOT/test_single_shared_output.yaml" <<EOF
input: test/fixtures/petstore.yaml
mode: both
package: api
output:
  server: ./test_single_shared_output/api
  client: ./test_single_shared_output/api
EOF
  }

  cleanup_single_target_shared_output_config() {
    rm -rf "$PROJECT_ROOT/test_single_shared_output" \
           "$PROJECT_ROOT/test_single_shared_output.yaml"
  }

  Describe 'single-target shared output'
    Before 'setup_single_target_shared_output_config'
    After 'cleanup_single_target_shared_output_config'

    It 'accepts mode: both with output.server == output.client'
      When run generate --config=./test_single_shared_output.yaml
      The status should be success
      The output should include 'Successfully generated'
      The output should not include 'two targets resolve to the same output directory'
      The path "$PROJECT_ROOT/test_single_shared_output/api/types.gleam" should be exist
      The path "$PROJECT_ROOT/test_single_shared_output/api/router.gleam" should be exist
      The path "$PROJECT_ROOT/test_single_shared_output/api/client.gleam" should be exist
    End
  End

  setup_multi_target_with_output_override_config() {
    rm -rf "$PROJECT_ROOT/test_multi_targets_override"
    cat > "$PROJECT_ROOT/test_multi_targets_override.yaml" <<EOF
input: test/fixtures/petstore.yaml
mode: client
targets:
  - package: foo/listing
    output:
      dir: ./test_multi_targets_override
    include:
      paths:
        - "/pets"
  - package: foo/details
    output:
      dir: ./test_multi_targets_override
    include:
      paths:
        - "/pets/**"
EOF
  }

  cleanup_multi_target_with_output_override_config() {
    rm -rf "$PROJECT_ROOT/test_multi_targets_override" \
           "$PROJECT_ROOT/test_multi_targets_override.yaml"
  }

  Describe 'CLI --output override'
    Before 'setup_multi_target_with_output_override_config'
    After 'cleanup_multi_target_with_output_override_config'

    It 'rejects --output override on a multi-target config'
      When run generate --config=./test_multi_targets_override.yaml --output=./somewhere_else
      The status should be failure
      The output should include 'cannot override the output directory for a multi-target config'
    End
  End
End

# ===================================================================
# Issue #387 — Reference-typed response header refused at codegen
# ===================================================================
#
# The client extractor today supports inline String / Int / Float /
# Bool response header schemas. A `$ref` header schema has no
# extractor wired up; the generator must abort with a clear error
# message rather than silently emit broken client code. This block
# pins the failure mode so a future regression cannot quietly start
# producing uncompilable output again.

Describe 'oaspec response header schema'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  setup_ref_header_config() {
    rm -rf "$PROJECT_ROOT/test_ref_header"
    mkdir -p "$PROJECT_ROOT/test_ref_header"
    cat > "$PROJECT_ROOT/test_ref_header.yaml" <<EOF
input: test/fixtures/issue_387_response_header_ref.yaml
package: ref_header
mode: client
output:
  dir: ./test_ref_header
EOF
  }

  cleanup_ref_header_config() {
    rm -rf "$PROJECT_ROOT/test_ref_header" "$PROJECT_ROOT/test_ref_header.yaml"
  }

  Before 'setup_ref_header_config'
  After 'cleanup_ref_header_config'

  It 'refuses to generate a client when a response header uses a ref schema'
    # Issue #552: validate.validate_response_headers now catches this
    # at validate time and emits a structured Diagnostic instead of
    # letting codegen panic. The CLI surfaces the diagnostic with the
    # header name + offending kind in the message; the previous
    # "Cannot generate client extractor for response header" wording
    # is gone, replaced by the validation hint.
    When run generate --config=./test_ref_header.yaml
    The status should be failure
    The output should include "Response header 'X-Item-Kind' has an unsupported schema"
    The output should include "ref to component schema"
  End
End

# ===================================================================
# generate --check tests
# ===================================================================

Describe 'oaspec generate --check'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  Describe 'when output matches'
    setup() { clean_test_output; generate --config=test/fixtures/oaspec.yaml >/dev/null 2>&1 || true; }
    Before 'setup'

    It 'passes when generated code matches existing files'
      When run generate --config=test/fixtures/oaspec.yaml --check
      The status should be success
      The output should include 'check passed'
    End
  End

  Describe 'when output does not exist'
    Before 'clean_test_output'

    It 'fails when output files do not exist'
      When run generate --config=test/fixtures/oaspec.yaml --check
      The status should be failure
      The output should include 'out of date'
    End
  End
End

# ===================================================================
# generate --fail-on-warnings tests
# ===================================================================

Describe 'oaspec generate --fail-on-warnings'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  Describe 'with a clean spec'
    It 'succeeds when there are no warnings'
      clean_test_output
      When run generate --config=test/fixtures/oaspec.yaml --fail-on-warnings
      The status should be success
      The output should include 'Successfully generated'
    End
  End

  Describe 'with a spec that has warnings'
    It 'fails when warnings are present'
      clean_test_output
      When run generate --config=test/fixtures/oaspec-with-warnings.yaml --fail-on-warnings
      The status should be failure
      The output should include 'Warnings:'
      The output should include '--fail-on-warnings is set'
    End
  End
End
