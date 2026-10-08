#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/sim/system/build_rng"
VERILATOR="${VERILATOR:-verilator}"
mkdir -p "$BUILD"
"$VERILATOR" -Wall -Wno-fatal -Wno-TIMESCALEMOD --timing --binary \
  --top-module rng_tb --Mdir "$BUILD" -o rng_tb \
  "$ROOT/rtl/game/rng.v" "$ROOT/sim/system/rng_tb.sv"
"$BUILD/rng_tb"
