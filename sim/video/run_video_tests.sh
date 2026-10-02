#!/bin/sh
# Video subsystem test suite (Advay) -- Verilator 5.050, run from anywhere:
#
#   sh sim/video/run_video_tests.sh              every video bench (10), the subsystem bench last
#   sh sim/video/run_video_tests.sh conv3x3 ...  only the named benches (names without _tb)
#   KEEP=1 sh sim/video/run_video_tests.sh ...    keep the compiled models in sim/video/build (else deleted after each bench)
#
# Each bench is compiled with --binary --timing, run from the repository root (they read memory/*.hex),
# and passes only if it prints "ALL TESTS PASSED: <name>". The subsystem bench also writes PNG frames of
# every view to docs/report_evidence/waveforms/video/. Exits 1 if any bench failed.
# (Jason's run_all_tests.sh can simply call this script.)
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
BUILD="$ROOT/sim/video/build"                # as sim/audio/build: in .gitignore
mkdir -p "$BUILD"
[ -f memory/piano0.hex ] || python3 tools/video/make_piano_images.py memory

R=rtl/video
PKG=rtl/common/assignment2_pkg.sv          # Jason's frozen constants: compiled first, before any module using them
SYNC=rtl/common/synchroniser.v             # the shared two-flop synchroniser (video_subsystem)
BR="$R/barcode_reuse"; A2="$R/a2"
SUBSYS="$A2/video_subsystem.sv $A2/profile_normalise.sv $A2/local_threshold.sv $A2/hysteresis_profile.sv \
        $A2/key_mask_generator.sv $A2/game_video_overlay.sv $BR/raster_source.sv $BR/conv3x3.sv $BR/sobel.sv \
        $BR/col_profile.sv $BR/peak_pick.sv $BR/cdc_latch.sv $BR/image_rom.sv $SYNC"

sources() {
  case "$1" in
    conv3x3)            echo "$BR/conv3x3.sv" ;;
    col_profile)        echo "$BR/col_profile.sv" ;;
    peak_pick)          echo "$BR/peak_pick.sv" ;;
    cdc_latch)          echo "$BR/cdc_latch.sv" ;;
    profile_normalise)  echo "$A2/profile_normalise.sv" ;;
    local_threshold)    echo "$A2/local_threshold.sv" ;;
    hysteresis_profile) echo "$A2/hysteresis_profile.sv" ;;
    key_mask_generator) echo "$A2/key_mask_generator.sv" ;;
    game_video_overlay) echo "$A2/game_video_overlay.sv sim/models/vga_monitor_model.sv" ;;
    video_subsystem)    echo "$SUBSYS sim/models/vga_monitor_model.sv sim/video/mock_game_state.sv" ;;
  esac
}

ALL="conv3x3 col_profile peak_pick cdc_latch profile_normalise local_threshold hysteresis_profile \
     key_mask_generator game_video_overlay video_subsystem"
LIST="${*:-$ALL}"

# No precompiled headers: Verilator makes two ~75 MB .gch files for the larger benches, which is more than a
# small workspace (Ed) can hold. Without them the build is a few MB and only slightly slower.
NOPCH="VK_PCH_I_FAST= VK_PCH_I_SLOW= CFG_CXXFLAGS_PCH=-fsyntax-only"

pass=0; fail=0; failed=""
for t in $LIST; do
  tb="${t}_tb"
  obj="$BUILD/obj_$t"
  rm -rf "$obj"
  printf '%-22s ' "$t"
  if ! verilator --binary --timing --assert -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
        -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-PINCONNECTEMPTY -Wno-MULTIDRIVEN -Wno-BLKSEQ -Wno-PROCASSINIT -Wno-TIMESCALEMOD \
        -MAKEFLAGS "$NOPCH" --top-module "$tb" -Mdir "$obj" -o "V$tb" $PKG "sim/video/$tb.sv" $(sources "$t") > "$BUILD/$t.build.log" 2>&1; then
    echo "BUILD FAILED (see sim/video/build/$t.build.log)"; fail=$((fail+1)); failed="$failed $t"; continue
  fi
  "$obj/V$tb" > "$BUILD/$t.sim.log" 2>&1
  if grep -q "ALL TESTS PASSED: $t" "$BUILD/$t.sim.log"; then
    echo "PASS"; pass=$((pass+1))
  else
    echo "FAIL (see sim/video/build/$t.sim.log)"; grep -E "FAIL|Fatal|Error" "$BUILD/$t.sim.log" | head -5; fail=$((fail+1)); failed="$failed $t"
  fi
  # delete the compiled model (small disks, e.g. an Ed workspace) unless KEEP=1
  [ "${KEEP:-0}" = 1 ] || rm -rf "$obj"
done

# the subsystem bench's frames -> PNG, into the report evidence folder
if ls frame_*.ppm > /dev/null 2>&1; then
  mkdir -p docs/report_evidence/waveforms/video
  python3 tools/video/render_frames.py > /dev/null
  for f in frame_*.png; do mv "$f" docs/report_evidence/waveforms/video/; done
  rm -f frame_*.ppm
fi

echo "video tests: $pass passed, $fail failed${failed:+ ($failed )}"
[ "$fail" -eq 0 ]
