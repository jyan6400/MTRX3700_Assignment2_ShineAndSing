#!/usr/bin/env bash
# =============================================================================
# run_audio_tests.sh  --  Luke Mouawad
# One command for the whole audio subsystem regression (Verilator 5.050):
#   1. every A2 audio unit test
#   2. the reused Lesson 4 regressions: tb_fft_mag_sq, tb_fft_find_peak,
#      tb_fft_input_buffer (unchanged lesson benches: they print "Error"/"Wrong"
#      on a mismatch, so they pass when they finish with none), and
#      fft_pitch_detect_tb (1 kHz test tone -> k = 84/85)
#   3. the audio subsystem test: FFT frames -> features -> provided classifier
#      -> vowel_valid / vowel_id, in two passes (enrol templates, then test)
# Needs no game or video RTL. Run from anywhere:
#       ./sim/audio/run_audio_tests.sh                  # all
#       ./sim/audio/run_audio_tests.sh audio_gate       # one test
# Exit status is non-zero if any test fails. Tests whose reused/provided
# sources are not in the repo yet are reported as SKIPPED, never as PASSED.
# =============================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/sim/audio/build"
VERILATOR="${VERILATOR:-verilator}"
A2="$ROOT/rtl/audio/a2"
PR="$ROOT/rtl/audio/pitch_reuse"
CL="$ROOT/rtl/audio/provided_classifier"
TB="$ROOT/sim/audio"
VFLAGS="--binary --timing -j 0 -Wno-fatal -Wno-TIMESCALEMOD"

declare -A SRC REQ LEGACY
SM="$ROOT/sim/models"
SRC[tb_fft_mag_sq]="$PR/fft_mag_sq.sv $TB/tb_fft_mag_sq.sv"
SRC[tb_fft_find_peak]="$PR/fft_find_peak.sv $TB/tb_fft_find_peak.sv"
SRC[tb_fft_input_buffer]="$PR/fft_input_buffer.sv $PR/async_fifo.sv $SM/dcfifo.v $TB/tb_fft_input_buffer.sv"
REQ[tb_fft_input_buffer]="$SM/dcfifo.v $ROOT/memory/test_waveform.hex"
LEGACY[tb_fft_mag_sq]=1; LEGACY[tb_fft_find_peak]=1; LEGACY[tb_fft_input_buffer]=1
SRC[window_function]="$PR/window_function.sv $TB/window_function_tb.sv"
SRC[log2_energy]="$A2/log2_energy.sv $TB/log2_energy_tb.sv"
SRC[audio_gate]="$A2/log2_energy.sv $A2/audio_gate.sv $TB/audio_gate_tb.sv"
SRC[band_energy_8]="$A2/band_energy_8.sv $TB/band_energy_8_tb.sv"
SRC[band_normalise]="$A2/band_normalise.sv $TB/band_normalise_tb.sv"
SRC[mel_filterbank_24]="$A2/mel_filterbank_24.sv $TB/mel_filterbank_24_tb.sv"
SRC[fft_pitch_detect]="$(ls $PR/*.sv $PR/*.v $PR/fft_ip_r22sdf/*.v 2>/dev/null | tr '\n' ' ') $SM/dcfifo.v $TB/fft_pitch_detect_tb.sv"
REQ[fft_pitch_detect]="$PR/fft_pitch_detect.sv $PR/fft_ip_r22sdf/FFT.v $SM/dcfifo.v $ROOT/memory/test_waveform.hex"
SRC[audio_subsystem]="$A2/log2_energy.sv $A2/band_energy_8.sv $A2/band_normalise.sv $A2/mel_filterbank_24.sv $A2/audio_features.sv $TB/audio_subsystem_tb.sv"
REQ[audio_subsystem]="$CL/classifier.sv"

ORDER="tb_fft_mag_sq tb_fft_find_peak tb_fft_input_buffer window_function log2_energy audio_gate band_energy_8 band_normalise mel_filterbank_24 fft_pitch_detect audio_subsystem"
[ $# -gt 0 ] && ORDER="$*"

# build <dir> <top> <extra args...> ; returns non-zero on failure
build() {
    local dir=$1 top=$2; shift 2
    rm -rf "$dir"
    "$VERILATOR" $VFLAGS --top-module "$top" --Mdir "$dir" -o "$top" "$@" > "$dir.build.log" 2>&1 \
        || { echo "BUILD FAILED: $top (see $dir.build.log)"; grep -m5 "%Error" "$dir.build.log"; return 1; }
}

mkdir -p "$BUILD"
pass=0; fail=0; skip=0; failed=""
for t in $ORDER; do
    missing=""
    for f in ${REQ[$t]:-}; do [ -f "$f" ] || missing="$missing $(basename "$f")"; done
    if [ -n "$missing" ]; then
        echo "SKIPPED: $t (missing:$missing)"; skip=$((skip+1)); continue
    fi
    top="${t}_tb"; [ -n "${LEGACY[$t]:-}" ] && top="$t"
    echo "=== $top ==="
    ok=1
    if [ "$t" = audio_subsystem ]; then
        # pass 1: enrol, with a blank templates.svh on the include path (Verilator
        # resolves `include only through -I, so the board's templates.svh in
        # provided_classifier/ is never picked up here); it writes the real ones.
        E="$BUILD/enrol_inc"; T="$BUILD/test_inc"; mkdir -p "$E" "$T"
        echo "localparam logic [D-1:0][FW-1:0] TEMPLATES [0:NCLASS*NT-1] = '{default: '0};" > "$E/templates.svh"
        if build "$BUILD/${t}_enrol" "${t}_tb" -I"$E" ${SRC[$t]} "$CL/classifier.sv" \
           && "$BUILD/${t}_enrol/${t}_tb" +enrol="$T/templates.svh" > "$BUILD/${t}_enrol.log" 2>&1 \
           && grep -q ENROLLED "$BUILD/${t}_enrol.log"; then
            grep ENROLLED "$BUILD/${t}_enrol.log"
            # pass 2: test against the enrolled templates
            build "$BUILD/$t" "${t}_tb" -I"$T" ${SRC[$t]} "$CL/classifier.sv" || ok=0
        else
            echo "ENROL FAILED (see $BUILD/${t}_enrol.log)"; ok=0
        fi
    else
        build "$BUILD/$t" "$top" ${SRC[$t]} || ok=0
    fi
    if [ $ok -eq 1 ]; then
        ( cd "$ROOT/memory" 2>/dev/null || cd "$ROOT"; "$BUILD/$t/$top" ) > "$BUILD/$t.log" 2>&1
        rc=$?
        if [ -n "${LEGACY[$t]:-}" ]; then
            if [ $rc -eq 0 ] && ! grep -qiE "error|wrong|warning|timeout" "$BUILD/$t.log"; then
                echo "PASSED (lesson bench, no errors reported): $top"; pass=$((pass+1)); continue
            fi
        elif [ $rc -eq 0 ] && grep -q "ALL TESTS PASSED" "$BUILD/$t.log"; then
            grep "ALL TESTS PASSED" "$BUILD/$t.log"; pass=$((pass+1)); continue
        fi
        grep -m3 -E "Fatal|Error|FAIL" "$BUILD/$t.log"
        echo "FAILED: $top (see $BUILD/$t.log)"
    fi
    fail=$((fail+1)); failed="$failed $t"
done
echo "-----------------------------------------------"
echo "audio tests: $pass passed, $fail failed, $skip skipped"
[ $fail -eq 0 ] || { echo "failed:$failed"; exit 1; }
