#!/usr/bin/env bash
# =============================================================================
# MTRX3700 Assignment 2 - Shine and Sing: complete test regression
#
# Run from anywhere:
#   bash run_all_tests.sh
#
# Requirements: Bash, Verilator (tested by the team with 5.050), C++ toolchain,
#               make, Python 3 (used by the video suite).
#
# The existing suite scripts are the source of truth for compilation, test
# selection and PASS/FAIL criteria. Logs are saved under sim/test_logs/.
# =============================================================================
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$ROOT/sim/test_logs"
mkdir -p "$LOG_DIR"

# Avoid running from an unexpected working directory; some benches load
# memory/*.hex relative to the repository root.
cd "$ROOT" || exit 1

if ! command -v "${VERILATOR:-verilator}" >/dev/null 2>&1; then
    echo "ERROR: Verilator is not installed or not on PATH." >&2
    echo "Install Verilator and a C++ compiler, then rerun this script." >&2
    exit 2
fi

printf '\n============================================================\n'
printf ' MTRX3700 Assignment 2 - Shine and Sing: ALL TESTS\n'
printf '============================================================\n'
printf 'Repository: %s\n' "$ROOT"
printf 'Verilator:  %s\n' "$("${VERILATOR:-verilator}" --version 2>/dev/null || echo unknown)"
printf 'Logs:       %s\n' "$LOG_DIR"

names=("Audio" "Video" "System (includes RNG)")
scripts=(
    "sim/audio/run_audio_tests.sh"
    "sim/video/run_video_tests.sh"
    "sim/system/run_system_tests.sh"
)
logs=("audio.log" "video.log" "system.log")
results=()
failures=0

for i in "${!scripts[@]}"; do
    suite="${names[$i]}"
    script="${scripts[$i]}"
    logfile="$LOG_DIR/${logs[$i]}"

    printf '\n------------------------------------------------------------\n'
    printf '[%d/%d] %s regression\n' "$((i + 1))" "${#scripts[@]}" "$suite"
    printf '%s\n' '------------------------------------------------------------'

    if [[ ! -f "$script" ]]; then
        printf 'FAIL: Missing test runner: %s\n' "$script" | tee "$logfile"
        results+=("FAIL (missing script)")
        ((failures += 1))
        continue
    fi

    # tee provides live output for the marker while preserving a complete log.
    # PIPESTATUS[0] is the test runner's exit status, not tee's.
    bash "$script" 2>&1 | tee "$logfile"
    status=${PIPESTATUS[0]}

    if (( status == 0 )); then
        results+=("PASS")
        printf '\n>>> %s: PASS\n' "$suite"
    else
        results+=("FAIL (exit $status)")
        ((failures += 1))
        printf '\n>>> %s: FAIL (exit %d)\n' "$suite" "$status"
        printf '    Full log: %s\n' "$logfile"
    fi
done

printf '\n============================================================\n'
printf ' FINAL REGRESSION SUMMARY\n'
printf '============================================================\n'
for i in "${!names[@]}"; do
    printf '%-26s %s\n' "${names[$i]}:" "${results[$i]}"
done
printf '%s\n' '------------------------------------------------------------'
if (( failures == 0 )); then
    printf 'ALL SUITES COMPLETED WITHOUT REPORTED FAILURES\n'
    printf 'NOTE: Audio tests may report SKIPPED benches when files or\n'
    printf '      available memory are insufficient; review audio.log.\n'
    exit 0
else
    printf '%d SUITE(S) FAILED - see logs in %s\n' "$failures" "$LOG_DIR"
    exit 1
fi
