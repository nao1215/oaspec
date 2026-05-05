#!/bin/sh
# shellcheck shell=sh

# Regression tests for scripts/check_sync.sh.
# Ensures the sync-check output accurately describes what it validates
# and that failure guidance points to a real remediation path.

Describe 'check_sync.sh'
  Include "$SHELLSPEC_SPECDIR/spec_helper.sh"

  check_sync() {
    cd "$PROJECT_ROOT" && bash scripts/check_sync.sh 2>&1
  }

  check_sync_with_version_drift() {
    cd "$PROJECT_ROOT"
    cp gleam.toml gleam.toml.bak
    sed -i 's/^version = .*/version = "99.99.99"/' gleam.toml
    set +e
    bash scripts/check_sync.sh 2>&1
    rc=$?
    set -e
    mv gleam.toml.bak gleam.toml
    return $rc
  }

  Describe 'success path'
    It 'passes on a consistent repo'
      When run check_sync
      The status should be success
      The output should include 'Versions and counts are in sync'
    End

    It 'reports version consistency check'
      When run check_sync
      The output should include 'Checking version consistency'
    End

    It 'reports live test counts'
      When run check_sync
      The output should include 'Live test counts'
    End

    It 'does not mention capability boundaries'
      When run check_sync
      The output should not include 'boundaries'
    End

    It 'does not reference update_sync.sh'
      When run check_sync
      The output should not include 'update_sync.sh'
    End
  End

  Describe 'failure path'
    It 'exits with error on version drift'
      When run check_sync_with_version_drift
      The status should be failure
      The output should include 'DRIFT:'
      The output should include 'FAILED:'
    End

    It 'shows actionable remediation guidance on failure'
      When run check_sync_with_version_drift
      The status should be failure
      The output should include 'Fix the inconsistencies listed above manually'
    End
  End
End
