#!/usr/bin/env bash
# =============================================================================
# run_system_tests.sh
# Whole-system integration regression for MTRX3700 Assignment 2.
#
# Runs codec-enabled top_level_codec_tb using Verilator.
# Covers:
#   - reset
#   - pseudo-random lane spawning
#   - early/wrong/correct vowel handling
#   - no duplicate scoring
#   - audio -> game CDC
#   - game -> video CDC
#
# Run from anywhere:
#   ./sim/system/run_system_tests.sh
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/sim/system/build_codec"
VERILATOR="${VERILATOR:-verilator}"

cd "$ROOT"

echo "==============================================="
echo " MTRX3700 Assignment 2 - System Regression"
echo "==============================================="

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo
echo "Codec-specific integration test"

echo

echo "Building top_level_codec_tb..."

"$VERILATOR" \
  -Wall \
  -Wno-fatal \
  -Wno-TIMESCALEMOD \
  +define+SYSTEM_CODEC_TEST \
  --timing \
  --binary \
  --top-module top_level_codec_tb \
  --Mdir "$BUILD" \
  -o top_level_codec_tb \
  -I"$ROOT/rtl/audio/provided_classifier" \
  "$ROOT/sim/models/wm8731_model.sv" \
  "$ROOT/rtl/audio/lesson3_reuse/i2c_master.sv" \
  "$ROOT/rtl/audio/lesson3_reuse/set_audio_encoder.sv" \
  "$ROOT/rtl/common/assignment2_pkg.sv" \
  "$ROOT/rtl/common/audio_game_cdc.sv" \
  "$ROOT/rtl/common/game_video_cdc.sv" \
  "$ROOT/rtl/common/synchroniser.v" \
  "$ROOT/rtl/game/vowel_hit_mapper.sv" \
  "$ROOT/rtl/game/game_fsm.sv" \
  "$ROOT/rtl/game/lane.sv" \
  "$ROOT/rtl/game/score.sv" \
  "$ROOT/rtl/game/timer.v" \
  "$ROOT/rtl/game/rng.v" \
  "$ROOT/rtl/audio/lesson3_reuse/mic_load.sv" \
  "$ROOT/rtl/audio/pitch_reuse/low_pass_conv.sv" \
  "$ROOT/rtl/audio/pitch_reuse/decimate.sv" \
  "$ROOT/rtl/audio/pitch_reuse/window_function.sv" \
  "$ROOT/rtl/audio/pitch_reuse/async_fifo.v" \
  "$ROOT/rtl/audio/pitch_reuse/fft_input_buffer.sv" \
  "$ROOT/rtl/audio/pitch_reuse/fft_mag_sq.sv" \
  "$ROOT/rtl/audio/pitch_reuse/fft_find_peak.sv" \
  "$ROOT/rtl/audio/pitch_reuse/fft_output_buffer.sv" \
  "$ROOT/rtl/audio/pitch_reuse/fft_pitch_detect.sv" \
  "$ROOT"/rtl/audio/pitch_reuse/fft_ip_r22sdf/*.v \
  "$ROOT/sim/models/dcfifo.v" \
  "$ROOT/rtl/audio/a2/audio_gate.sv" \
  "$ROOT/rtl/audio/a2/audio_features.sv" \
  "$ROOT/rtl/audio/a2/band_energy_8.sv" \
  "$ROOT/rtl/audio/a2/band_normalise.sv" \
  "$ROOT/rtl/audio/a2/mel_filterbank_24.sv" \
  "$ROOT/rtl/audio/a2/log2_energy.sv" \
  "$ROOT/rtl/audio/provided_classifier/classifier.sv" \
  "$ROOT/rtl/video/lesson3_reuse/video_pll.sv" \
  "$ROOT/rtl/video/barcode_reuse/raster_source.sv" \
  "$ROOT/rtl/video/barcode_reuse/image_rom.sv" \
  "$ROOT/rtl/video/barcode_reuse/conv3x3.sv" \
  "$ROOT/rtl/video/barcode_reuse/sobel.sv" \
  "$ROOT/rtl/video/barcode_reuse/col_profile.sv" \
  "$ROOT/rtl/video/barcode_reuse/peak_pick.sv" \
  "$ROOT/rtl/video/barcode_reuse/cdc_latch.sv" \
  "$ROOT/rtl/video/a2/profile_normalise.sv" \
  "$ROOT/rtl/video/a2/hysteresis_profile.sv" \
  "$ROOT/rtl/video/a2/local_threshold.sv" \
  "$ROOT/rtl/video/a2/key_mask_generator.sv" \
  "$ROOT/rtl/video/a2/game_video_overlay.sv" \
  "$ROOT/rtl/video/a2/video_subsystem.sv" \
  "$ROOT/rtl/top/top_level.sv" \
  "$ROOT/sim/system/top_level_codec_tb.sv"

echo
echo "Running top_level_codec_tb..."
echo

"$BUILD/top_level_codec_tb"

echo
echo "==============================================="
echo "CODEC INTEGRATION TEST PASSED"
echo "==============================================="