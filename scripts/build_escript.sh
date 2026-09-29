#!/bin/sh
# Build the oaspec escript that the GitHub Release and the Docker image ship.
#
#   scripts/build_escript.sh [OUT]    (default: ./oaspec)
#
# The escript is packed from the production Erlang shipment, so it carries
# oaspec and its runtime dependencies only. See scripts/escript.erl for why
# gleescript is not used.

set -eu

OUT="${1:-oaspec}"
case "$OUT" in
  /*) ;;
  *) OUT="$(pwd)/$OUT" ;;
esac

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

gleam export erlang-shipment
escript scripts/escript.erl pack build/erlang-shipment oaspec "$OUT"
