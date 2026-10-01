# Audio fixed-point table — Luke Mouawad

Every audio stage, from microphone sample to classifier feature word.
Notation: **Qi.f** = i integer bits, f fractional bits; "LSB" = one 16-bit microphone sample step.
Rows marked **(reused — confirm)** belong to Lesson 3 / Lesson 4 modules not yet in the repo; fill them in from those
files. Every other row is exact to the RTL in `rtl/audio/`.

## 1. Time-domain path (codec BCLK domain, 3.072 MHz, one sample per 64 clocks = 48 kHz)

| Stage | Signal | Sign | In width | Accum. width | Out width | Frac bits | Truncation / rounding | Max expected value |
|---|---|---|---|---|---|---|---|---|
| mic_load (reused — confirm) | `sample` | signed | — | — | 16 | 0 (integer LSBs) | — | ±32767 / −32768 |
| audio_gate: rectify | `abs_x` | unsigned | 16 s | — | 16 | 0 | exact (\|−32768\| = 32768 fits) | 32768 |
| audio_gate: level, `s += (\|x\| − s)·2⁻⁸` | `level` | unsigned | 16 | 34 s (diff) | 32 | Q16.16 | `>>> 8` floors; bias < 2⁻⁸ LSB | 32768.0 |
| audio_gate: noise floor (fall 2⁻¹¹, rise 2⁻¹⁵, rise while open 2⁻²¹) | `noise_floor` | unsigned | 32 | 34 s (diff) | 32 | Q16.16 | `>>>` floors; 16 frac bits so a 2⁻²¹ rise is non-zero once level − floor ≥ 32 LSB | reset 4096.0 (⅛ full scale); clamp ≥ 8.0 |
| audio_gate: gate, `level > 4·floor` | `voice_active` | unsigned | 32 × 5-bit, 32 × 7-bit | 40 | 1 | Q16.16 both sides | exact integer compare (widened, cannot overflow) | — |
| audio_gate: log2(level) | `lvl_log2` | unsigned | 32 | — | 13 | Q5.8 | see the log2 row in §2 | 31.99 |
| audio_gate: dB | `level_db` | unsigned | 13 → 15 s | 30 | 7 | 0 | `(t·1541 + 2¹⁵) >> 16`, round half-up; clamp 0..99; held 2¹³ samples (0.17 s) | 90 (full scale) |
| low_pass_conv (provided one-multiplier version) | `x_data` → `y_data` | signed | 32 = {sample, 16'b0} | product 34, acc 40 | 32 | Q16.16 | taps Q1.16 (18-bit signed); `W'(acc)` drops the top 8 accumulator bits (filter gain ≤ 1) | ±32768.0 |
| decimate 48 → 12 kHz (reused) | `y_data` | signed | 32 (Q16.16 from the filter) | — | 16 | 0 | keeps the integer part `[31:16]` (fraction truncated); every 4th output | ±32767 |
| window_function: Hamming (changed for A2) | `y_data` | signed | 16 × Q0.16 unsigned coefficient | 33 | 16 | 0 | `w = round(w·65535)` from a 512-entry symmetric ROM; `(x·w) >>> 16` floors; \|y\| ≤ \|x\| | ±32766 (centre), ±2621 (ends) |
| fft_input_buffer + async_fifo (reused; BCLK → FFT CDC) | `audio_input_data` → `fft_input` | signed | port 17 (`[W:0]`) | 1024 × 16 FIFO (M10K) | 16 | 0 | the 16-bit FIFO keeps bits [15:0]; the 17th port bit is dropped | ±32767 |

`level_db = round(20·log10(level / 1 LSB))`: one LSB reads 0 dB, full scale 90 dB (dB relative to the codec LSB).
1 dB steps; log2 error < 0.001 → < 0.5 dB before rounding (the course's 3-bit Mitchell display reads up to 2 dB low).
`level[31:24]` drives the LEDR envelope bar.

## 2. Frequency-domain path (FFT clock, 18.432 MHz; one frame = 1024 samples at 12 kHz, 85 ms)

| Stage | Signal | Sign | In width | Accum. width | Out width | Frac bits | Truncation / rounding | Max expected value |
|---|---|---|---|---|---|---|---|---|
| FFT (reused, R2²SDF) | `di_re` → `do_re`, `do_im` | signed | 16 | 16 per stage | 16 each | 0 | every butterfly `(a ± b + ½) >>> 1`: output scaled by **1/N** with rounding; bit-reversed order | a tone of amplitude a gives \|X\| ≈ 0.27a (Hamming) |
| fft_mag_sq (reused) | `mag_sq` | unsigned | 2 × 16 s | — | **33** (`MAG_W`) | 0 | exact (re² + im²) | 2³¹ |
| **R-A2** band_energy_8 | `band_acc[b]` | unsigned | 33 | 42 | 42 | 0 | exact: 64 bins × (2³³ − 1) < 2³⁹ (42 bits covers any band up to 512 bins) | < 2³⁹ |
| **R-A2** feature | `feature[b]` | unsigned | 42 | — | 16 | 0 | `>> BAND_SHIFT` (8) truncates; saturate at 65535. With the 1/N FFT a 60 dB voice reads ~1000; +36 dB saturates (R-A2 is level-dependent by design) | 65535 |
| **R-A3** band_normalise: total | `total` | unsigned | 8 × 42 | 45 | 45 | 0 | exact | < 2⁴² |
| **R-A3** divider remainder | `rem` | unsigned | 42 | 46 | — | — | exact (holds < 2·total); 1 quotient bit per clock, 17 per band | < 2⁴³ |
| **R-A3** feature | `feature[b]` | unsigned | 42 / 45 | — | 16 | **Q0.16** | `floor(E_b·2¹⁶ / total)`; saturate at 65535 when one band holds all the energy; total = 0 → 0 | 65535 |
| **R-A4** Mel weight | `r_b` | unsigned | 10-bit offset × 27-bit reciprocal | 37 | 11 | Q0.10 (1.0 = 1024) | `RECIP = round(2²⁶ / width)`, `r = (off·RECIP) >> 16` floors; within 1 LSB of the model's triangle; the two weights of a bin sum to exactly 1.0 | 1023 |
| **R-A4** weighted energy | `pu_q`, `pd_q` | unsigned | 33 × 11 | — | 44 | Q33.10 | exact | < 2⁴³ |
| **R-A4** mel_filterbank_24 | `mel_energy[m]` | unsigned | 44 | 52 | 52 | Q42.10 | exact: each bin contributes ≤ 1.0 in total, ≤ 512 bins | < 2⁵² |
| **R-A4** log2_energy | `L_m` | unsigned | 52 | — | 16 | **Q6.10** | leading-one + 65-entry LUT (Q0.12) + linear interpolation on 6 more bits (error < 5·10⁻⁵), rounded half-up to 10 bits; x = 0 → 0; saturate on carry-out | 51.99 → 53247 |
| **R-A4** frame mean | `mean_c` | unsigned | 24 × 16 → sum 21 | 37 | 16 | Q6.10 | `(Σ L · 2731) >> 16` truncates; 2731 = round(2¹⁶/24): ≤ 1 LSB shift under a 2× gain change | 53247 |
| **R-A4** feature | `feature[m]` | unsigned (offset binary) | 16, 16 | 19 s | 16 | Q6.10, 32768 = "equal to the frame mean" | `L − mean + 32768`, saturate to 0..65535 (±32 octaves ≈ ±96 dB about the mean) | 65535 |
| classifier input (provided) | `feature[D-1:0][15:0]` | unsigned | — | SAD: 16 + log2(D) + 1 = 22 | D × 16 | FW = 16 | — | — |

The model (`tools/audio/audio_model.py`) computes the same features in float: `band_energies()`, `band_energies(normalise="total")`,
`log_mel()` (log2 of `mel_bank(24, 100, 6000)` minus the mean). The hardware differs only by the truncations above and by the
constant 2¹⁰ weight scale, which the mean subtraction removes.

## 3. What a gain g on the microphone does (energy × g²)

| Rung | Feature | Effect of g |
|---|---|---|
| R-A1 | peak bin | none, but follows the pitch |
| R-A2 | E_b >> 8 | × g² (not level-robust, by design) |
| R-A3 | E_b / ΣE | cancels exactly (bit-identical for g = 2, `band_normalise_tb`) |
| R-A4 | log2 E_m − mean | every L_m and the mean shift by 2·log2(g); cancels to ≤ 1 LSB (`audio_subsystem_tb`) |

## 4. Where the constants live (Part B live-change cards)

| Card | File | Line / parameter |
|---|---|---|
| gate margin | `audio_gate.sv` | `MARGIN_Q4` (64 = K 4.0 = 12 dB) |
| gate time constants | `audio_gate.sv` | `LEVEL_SHIFT` 8, `FLOOR_FALL_SHIFT` 11, `FLOOR_RISE_SHIFT` 15, `FLOOR_RISE_OPEN_SHIFT` 21, `FLOOR_INIT` 4096 |
| band edge | `band_energy_8.sv` | `BAND_EDGES` (print with `audio_model.rtl_tables()`) |
| number of Mel bands | `mel_filterbank_24.sv` `NM`, `MEL_PTS`; `audio_features.sv` `NM`, `D` | `audio_model.rtl_tables(nmel=K)`, then re-enrol templates for D = K |
| vote length | `audio_features.sv` | `M` (passed to `classifier.sv`) |
| reject rule | `audio_features.sv` | `DMAX`, `RHO_NUM`/`RHO_DEN` (classifier), and `assign qual = classifier_result_valid && !classifier_reject && voice_active;` |
| HEX2 / vowel mapping | `audio_features.sv` | `vowel_id <= classifier_result` (0 ee, 1 ah, 2 oo, 3 aw = template order) |
| N becomes 512 | every FFT-side module takes `N`; bins become 23.4 Hz, so re-run `rtl_tables()` with N = 512 and re-enrol | |
