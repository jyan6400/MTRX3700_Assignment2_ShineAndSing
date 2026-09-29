#!/usr/bin/env bash
# =============================================================================
# run_audio_tests.sh  --  Luke Mouawad
# One command for the whole audio subsystem regression (Verilator 5.050):
#   1. every A2 audio unit test
#   2. the reused pitch-detector regression (fft_pitch_detect_tb)
#   3. the audio subsystem test (features -> classifier -> vowel_valid/vowel_id)
# Needs no game or video RTL. Run from anywhere:
#       ./sim/audio/run_audio_tests.sh            # all
#       ./sim/audio/run_audio_tests.sh audio_gate # one test
# Exit status is non-zero if any test fails. Tests whose reused/provided
# sources are not in the repo yet are reported as SKIPPED, not PASSED.
# =============================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/sim/audio/build"
VERILATOR="${VERILATOR:-verilator}"
A2="$ROOT/rtl/audio/a2"
PR="$ROOT/rtl/audio/pitch_reuse"
CL="$ROOT/rtl/audio/provided_classifier"
TB="$ROOT/sim/audio"

# name | sources (space separated) | required files that may not exist yet
declare -A SRC REQ
SRC[log2_energy]="$A2/log2_energy.sv $TB/log2_energy_tb.sv"
SRC[audio_gate]="$A2/log2_energy.sv $A2/audio_gate.sv $TB/audio_gate_tb.sv"
SRC[band_energy_8]="$A2/band_energy_8.sv $TB/band_energy_8_tb.sv"
SRC[band_normalise]="$A2/band_normalise.sv $TB/band_normalise_tb.sv"
SRC[mel_filterbank_24]="$A2/mel_filterbank_24.sv $TB/mel_filterbank_24_tb.sv"
SRC[fft_pitch_detect]="$(ls $PR/*.sv $PR/*.v $PR/fft_ip_r22sdf/*.v 2>/dev/null | tr '\n' ' ') $TB/fft_pitch_detect_tb.sv"
REQ[fft_pitch_detect]="$PR/fft_pitch_detect.sv $TB/fft_pitch_detect_tb.sv"
SRC[audio_subsystem]="$A2/log2_energy.sv $A2/band_energy_8.sv $A2/band_normalise.sv $A2/mel_filterbank_24.sv $A2/audio_features.sv $CL/classifier.sv $TB/audio_subsystem_tb.sv"
REQ[audio_subsystem]="$CL/classifier.sv $CL/templates.svh"

ORDER="log2_energy audio_gate band_energy_8 band_normalise mel_filterbank_24 fft_pitch_detect audio_subsystem"
[ $# -gt 0 ] && ORDER="$*"

mkdir -p "$BUILD"
pass=0; fail=0; skip=0; failed=""
for t in $ORDER; do
    missing=""
    for f in ${REQ[$t]:-}; do [ -f "$f" ] || missing="$missing $(basename "$f")"; done
    if [ -n "$missing" ]; then
        echo "SKIPPED: ${t}_tb (missing:$missing)"; skip=$((skip+1)); continue
    fi
    echo "=== ${t}_tb ==="
    rm -rf "$BUILD/$t"
    if ! "$VERILATOR" --binary --timing -j 0 -Wno-fatal -Wno-TIMESCALEMOD \
            -I"$CL" -I"$ROOT/memory" --top-module "${t}_tb" \
            --Mdir "$BUILD/$t" -o "${t}_tb" ${SRC[$t]} > "$BUILD/$t.build.log" 2>&1; then
        echo "BUILD FAILED: ${t}_tb (see $BUILD/$t.build.log)"; tail -20 "$BUILD/$t.build.log"
        fail=$((fail+1)); failed="$failed $t"; continue
    fi
    ( cd "$ROOT/memory" 2>/dev/null || cd "$ROOT"; "$BUILD/$t/${t}_tb" ) > "$BUILD/$t.log" 2>&1
    rc=$?
    tail -4 "$BUILD/$t.log"
    if [ $rc -eq 0 ] && grep -q "ALL TESTS PASSED" "$BUILD/$t.log"; then
        pass=$((pass+1))
    else
        echo "FAILED: ${t}_tb (see $BUILD/$t.log)"; fail=$((fail+1)); failed="$failed $t"
    fi
done
echo "-----------------------------------------------"
echo "audio tests: $pass passed, $fail failed, $skip skipped"
[ $fail -eq 0 ] || { echo "failed:$failed"; exit 1; }
