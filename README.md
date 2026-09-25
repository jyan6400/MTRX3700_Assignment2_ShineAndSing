# MTRX3700 Assignment 2 — Shine & Sing

## Project Goal

This repository is for **MTRX3700 Assignment 2: Shine & Sing**, integrating:

- Lesson 3 microphone / WM8731 / VGA / Avalon-ST infrastructure
- Lesson 4 DSP / FFT / fixed-point / CDC material
- Mini-Project 2 pitch-detection modules
- Mini-Project 2 barcode-reader image-processing modules
- selected Assignment 1 Piano Tiles game logic
- the provided Assignment 2 vowel classifier

The design runs entirely in FPGA hardware on the DE1-SoC.

### Team ownership

- **Jason Yang** — Game/Control + integration lead
- **Luke Mouawad** — Audio/DSP + classifier
- **Advay Hassan** — Video/Image Processing + VGA rendering

Integration is shared by all three members. Jason coordinates the integration branch, top-level, full-system regression, Quartus build and final board bring-up, but each subsystem owner remains responsible for fixing their own subsystem during integration.

---

# 1. Frozen System Requirements and Interfaces

These requirements are frozen before subsystem development so Jason, Luke and Advay can work independently.

Changing one of these interfaces requires agreement from all affected owners.

## 1.1 Target level

The team targets the highest normal requirement rung on both processing sides:

- **Audio:** R-A4 High Distinction — 24 log-Mel energies
- **Video:** R-V4 High Distinction — smoothing → Sobel → refined profile/peaks → local/adaptive threshold
- MFCC and other work beyond R-A4 are Extras only
- Barcode decoding itself is **not** part of Assignment 2

The system must remain playable at every implemented rung.

## 1.2 Global constants

```systemverilog
AUDIO_SAMPLE_W = 16
AUDIO_FS_IN    = 48000
AUDIO_FS_FFT   = 12000
FFT_N          = 1024
FFT_CLK_HZ     = 18_432_000
AUDIO_BCLK_HZ  = 3_072_000
SYS_CLK_HZ     = 50_000_000
PIXEL_CLK_HZ   = 25_000_000

N_VOWELS       = 4
N_LANES        = 4

VOWEL_EE       = 2'd0
VOWEL_AH       = 2'd1
VOWEL_OO       = 2'd2
VOWEL_AW       = 2'd3

CLASSIFIER_FW  = 16
CLASSIFIER_D   = 24
```

The design has four clock domains:

```text
50 MHz      system/game
3.072 MHz   codec BCLK
18.432 MHz  FFT
25 MHz      VGA pixel
```

Every clock-domain crossing must use a FIFO, synchroniser or handshake.

## 1.3 Board-visible requirements

### Audio/debug

- `HEX5..HEX3`: FFT peak bin `k` in decimal, `000–511`
- `HEX2`: classified vowel `0–3`
- `HEX2` must be blank when:
  - there is no active voice, or
  - the classifier rejects the frame
- `HEX1..HEX0`: microphone level `00–99 dB`
- `LEDR9..0`: microphone envelope bar

### Video/debug

`SW2..SW1`:

```text
0 = game view
1 = edge-map view
2 = column-profile + threshold view
3 = key-mask view
```

`SW4..SW3`:

```text
0 = supplied image 1
1 = supplied image 2
2 = tutor photograph
```

`SW5`:

```text
0 = 1-D edge detector
1 = Sobel
```

### Game

Four consecutive detected white keys are the four lanes:

```text
lane 0 → ee
lane 1 → ah
lane 2 → oo
lane 3 → aw
```

A score is awarded only when:

```text
classifier result is valid
AND frame is not rejected
AND voice is active
AND classified vowel == active lane vowel
AND lane is in its hit window
```

## 1.4 Audio → Game contract

Luke owns the producer side.

Jason owns the consumer side.

```systemverilog
logic       vowel_valid;    // one-cycle pulse in game clock domain
logic [1:0] vowel_id;       // 0 ee, 1 ah, 2 oo, 3 aw
```

`vowel_valid` means:

```text
classifier result_valid
AND !classifier reject
AND voice_active
```

Jason must **not** need access to FFT bins, features, confidence, microphone samples or classifier internals.

The FFT-clock result crosses to the 50 MHz game domain using a handshake/pulse CDC wrapper before these signals reach game logic.

## 1.5 Audio debug outputs

Luke additionally exposes:

```systemverilog
logic [9:0] peak_k;              // 0..511
logic [6:0] level_db;            // 0..99
logic       voice_active;
logic [7:0] confidence;
logic       classifier_reject;
```

These are debug/display signals and are not required by Jason's game logic.

## 1.6 Game → Video contract

Jason produces these signals.

Advay must be able to develop the entire video overlay from mocked versions of them.

```systemverilog
logic [3:0] lane_active;
logic [3:0] lane_hit_window;
logic [3:0] lane_hit_pulse;

parameter GAME_COUNT_W = 4;
logic [GAME_COUNT_W-1:0] lane_count [0:3];

logic [15:0] score;
```

Semantics:

- `lane_active[i] = 1`: lane has a current note
- `lane_count[i]`: countdown value used to select brightness
- `lane_hit_window[i] = 1`: lane is currently the red / sing-now key
- `lane_hit_pulse[i]`: single-cycle successful-hit event
- `score`: current game score

The video subsystem must not inspect Jason's FSM state encoding.

## 1.7 Video coordinate contract

The course modelling pipeline uses a 320×240 8-bit greyscale source image.

Keep these parameterised:

```systemverilog
IMG_W = 320
IMG_H = 240
PIX_W = 8

X_W = $clog2(IMG_W)   // 9
Y_W = $clog2(IMG_H)   // 8
```

Final VGA output remains 640×480.

Detected boundary positions remain in source-image x coordinates.

Advay owns the conversion from detected boundaries to four playable key masks.

No fixed key x-coordinates may be supplied by Jason.

## 1.8 Classifier interface

Use the provided `classifier.sv` unchanged unless a documented fix is absolutely required.

Target R-A4 parameters:

```systemverilog
D      = 24
FW     = 16
NCLASS = 4
NT     = 4
M      = 5
```

Inputs:

```systemverilog
feature[23:0][15:0]
feature_valid
enable
```

Outputs:

```systemverilog
result[1:0]
confidence[7:0]
reject
result_valid
```

Only `D` changes between normal requirement rungs:

```text
R-A1 peak bin            D = 1
R-A2 8 band energies     D = 8
R-A3 normalised bands    D = 8
R-A4 24 log-Mel          D = 24
```

## 1.9 Testing requirements

Every new or modified module must have a self-checking testbench that:

- drives the module
- computes/checks expected outputs itself
- uses `$fatal` on the first mismatch
- prints `ALL TESTS PASSED: <name>`
- runs in Verilator 5.050

Each subsystem must also have one standalone subsystem test.

A whole-system test must exercise:

- several audio frames
- several reduced-size video frames
- classifier/game interaction
- reset
- at least one CDC path

No owner may require another owner's unfinished subsystem to run their own tests.

---

# 2. Repository Structure

```text
MTRX3700_Assignment2_ShineAndSing/
│
├── README.md
├── .gitignore
├── run_all_tests.sh
│
├── rtl/
│   │
│   ├── top/
│   │   └── top_level.sv                         # Jason
│   │
│   ├── common/
│   │   ├── assignment2_pkg.sv                  # shared constants/types
│   │   ├── synchroniser.v                      # reused
│   │   ├── audio_game_cdc.sv                   # Jason
│   │   └── game_video_cdc.sv                   # Jason / integration
│   │
│   ├── audio/
│   │   │
│   │   ├── lesson3_reuse/
│   │   │   ├── i2c_master.sv
│   │   │   ├── set_audio_encoder.sv
│   │   │   ├── mic_load.sv
│   │   │   ├── i2c_pll.v
│   │   │   └── adc_pll.v
│   │   │
│   │   ├── pitch_reuse/
│   │   │   ├── low_pass_conv.sv
│   │   │   ├── decimate.sv
│   │   │   ├── window_function.sv
│   │   │   ├── async_fifo.v
│   │   │   ├── fft_input_buffer.sv
│   │   │   ├── fft_mag_sq.sv
│   │   │   ├── fft_find_peak.sv
│   │   │   ├── fft_output_buffer.sv
│   │   │   ├── fft_pitch_detect.sv
│   │   │   └── fft_ip_r22sdf/
│   │   │       └── ...                         # supplied FFT RTL
│   │   │
│   │   ├── provided_classifier/
│   │   │   ├── classifier.sv
│   │   │   └── templates.svh
│   │   │
│   │   └── a2/
│   │       ├── audio_gate.sv                   # Luke
│   │       ├── band_energy_8.sv               # Luke, R-A2
│   │       ├── band_normalise.sv               # Luke, R-A3
│   │       ├── mel_filterbank_24.sv            # Luke, R-A4
│   │       ├── log2_energy.sv                  # Luke, R-A4
│   │       └── audio_features.sv               # Luke wrapper
│   │
│   ├── video/
│   │   │
│   │   ├── lesson3_reuse/
│   │   │   ├── vga_face.sv
│   │   │   ├── video_pll.sv
│   │   │   └── [other supplied VGA/Avalon files unchanged]
│   │   │
│   │   ├── barcode_reuse/
│   │   │   ├── conv3x3.sv
│   │   │   ├── col_profile.sv
│   │   │   ├── peak_pick.sv
│   │   │   ├── [actual 1-D edge module from barcode workspace]
│   │   │   └── [actual blanking/latch module from barcode workspace]
│   │   │
│   │   └── a2/
│   │       ├── profile_normalise.sv            # Advay, R-V3
│   │       ├── hysteresis_profile.sv            # Advay, R-V3
│   │       ├── local_threshold.sv               # Advay, R-V4
│   │       ├── key_mask_generator.sv            # Advay
│   │       └── game_video_overlay.sv            # Advay
│   │
│   └── game/
│       ├── game_fsm.sv                          # Jason
│       ├── lane.sv                              # Jason
│       ├── score.sv                             # Jason
│       ├── timer.sv                             # Jason
│       └── vowel_hit_mapper.sv                  # Jason
│
├── sim/
│   ├── models/
│   │   ├── wm8731_model.sv
│   │   └── vga_monitor_model.sv
│   │
│   ├── audio/
│   │   ├── fft_pitch_detect_tb.sv
│   │   ├── audio_gate_tb.sv
│   │   ├── band_energy_8_tb.sv
│   │   ├── band_normalise_tb.sv
│   │   ├── mel_filterbank_24_tb.sv
│   │   ├── log2_energy_tb.sv
│   │   └── audio_subsystem_tb.sv
│   │
│   ├── video/
│   │   ├── conv3x3_tb.sv
│   │   ├── col_profile_tb.sv
│   │   ├── peak_pick_tb.sv
│   │   ├── profile_normalise_tb.sv
│   │   ├── local_threshold_tb.sv
│   │   ├── key_mask_generator_tb.sv
│   │   ├── game_video_overlay_tb.sv
│   │   └── video_subsystem_tb.sv
│   │
│   ├── game/
│   │   ├── vowel_hit_mapper_tb.sv
│   │   ├── game_fsm_tb.sv
│   │   ├── score_tb.sv
│   │   └── game_subsystem_tb.sv
│   │
│   └── system/
│       └── top_level_tb.sv
│
├── quartus/
│   ├── assignment2.qpf
│   ├── assignment2.qsf
│   ├── assignment2.sdc
│   ├── *.qsys
│   └── ip/
│
├── memory/
│   ├── piano0.mif
│   ├── piano1.mif
│   ├── piano2.mif
│   └── test_waveform.hex
│
├── tools/
│   ├── audio/
│   │   ├── audio_model.py
│   │   ├── A2_audio_modelling.ipynb
│   │   ├── mfcc_walkthrough.ipynb
│   │   ├── train_templates.py
│   │   └── make_test_templates.py
│   │
│   └── video/
│       ├── A2_video_modelling.ipynb
│       ├── video_model.py
│       └── image_conversion_script.py
│
└── docs/
    ├── interface_contract.md
    ├── fixed_point_table.md
    ├── clock_domain_map.md
    ├── report_evidence/
    │   ├── waveforms/
    │   ├── timing/
    │   ├── quartus/
    │   └── screenshots/
    └── project_management/
        ├── meeting_minutes.md
        ├── decision_log.md
        ├── risk_register.md
        └── contribution_log.md
```

---

# 3. Reuse Register

## 3.1 Audio

| File / block | Source | Action | Owner |
|---|---|---|---|
| `i2c_master.sv` | Lesson 3 | reuse | Luke |
| `set_audio_encoder.sv` | Lesson 3 | reuse | Luke |
| `mic_load.sv` | Lesson 3 | reuse | Luke |
| `i2c_pll.v` | Lesson 3 | reuse | Luke |
| `adc_pll.v` | Lesson 3 | reuse | Luke |
| `low_pass_conv.sv` | Lesson 4 | reuse tested version | Luke |
| `decimate.sv` | Pitch mini-project | reuse | Luke |
| `window_function.sv` | Pitch mini-project | reuse | Luke |
| `async_fifo.v` | Lesson 4 generated IP | reuse unchanged | Luke |
| `fft_input_buffer.sv` | Pitch mini-project | reuse | Luke |
| FFT RTL | Pitch mini-project | reuse unchanged | Luke |
| `fft_mag_sq.sv` | Pitch mini-project | reuse | Luke |
| `fft_find_peak.sv` | Pitch mini-project | reuse | Luke |
| `fft_output_buffer.sv` | Pitch mini-project | reuse where useful | Luke |
| `fft_pitch_detect_tb.sv` | Pitch mini-project | keep as regression | Luke |
| `classifier.sv` | Provided A2 | reuse unchanged | Luke |
| `templates.svh` | Generated A2 | regenerate from enrolment | Luke |

## 3.2 Video

| File / block | Source | Action | Owner |
|---|---|---|---|
| VGA/Avalon source chain | Lesson 3 | reuse/adapt | Advay |
| `video_pll.sv` | Lesson 3 | reuse | Advay |
| `vga_monitor_model.sv` | Lesson 3 | simulation | Advay |
| 1-D edge module | Barcode mini-project | reuse exact filename | Advay |
| `conv3x3.sv` | Barcode mini-project | reuse/parameterise kernel | Advay |
| `col_profile.sv` | Barcode mini-project | reuse/adapt rows | Advay |
| `peak_pick.sv` | Barcode mini-project | reuse then extend for R-V3 | Advay |
| blanking/frame latch | Barcode mini-project | reuse | Advay |
| `bar_decode.sv` | Barcode mini-project | **NOT USED in A2** | — |

## 3.3 Game

| File / block | Source | Action | Owner |
|---|---|---|---|
| `game_fsm.sv` | Assignment 1 | reuse/adapt | Jason |
| `lane.sv` | Assignment 1 | reuse/adapt | Jason |
| `score.sv` | Assignment 1 | reuse/adapt | Jason |
| `timer.sv` | Assignment 1 | reuse if useful | Jason |
| A1 button/debounce logic | Assignment 1 | not part of normal A2 hit path | Jason |

### Reuse rule

Do not rewrite working lesson/mini-project modules just to make them "Assignment 2 code".

If a reused module is modified:

1. document exactly what changed
2. explain why
3. extend or rerun its regression test

---

# 4. Work Split

## 4.1 Jason Yang — Game/Control and Integration

### Files owned

```text
rtl/game/game_fsm.sv
rtl/game/lane.sv
rtl/game/score.sv
rtl/game/timer.sv
rtl/game/vowel_hit_mapper.sv
rtl/common/audio_game_cdc.sv
rtl/common/game_video_cdc.sv
rtl/top/top_level.sv

sim/game/*
sim/system/top_level_tb.sv
quartus/assignment2.sdc
```

### Independent input contract

Jason develops against a mocked input:

```systemverilog
vowel_valid
vowel_id[1:0]
```

No Luke RTL is required.

### Required behaviour

1. `ee/ah/oo/aw` map to lanes `0/1/2/3`.
2. A vowel event can score only while that lane is in its hit window.
3. Wrong vowel → no score.
4. Correct vowel outside hit window → no score.
5. Repeated classifier frames must not accidentally count as repeated hits.
6. At most one lane is in the hit window at one time.
7. Reset clears game state and score.
8. Expose video state only through the frozen Game → Video contract.
9. Do not expose internal FSM state encodings to Advay.
10. Choose beat/hit-window parameters long enough for classifier vote latency and document them.

### Tests Jason writes

#### `vowel_hit_mapper_tb.sv`

Test:

- all four vowel mappings
- invalid event
- back-to-back events
- reset

#### `game_subsystem_tb.sv`

Test:

- correct vowel in window
- wrong vowel
- early vowel
- late vowel
- no-valid event
- reset
- score increments exactly once

#### `audio_game_cdc_tb.sv`

Test:

- event safely crosses FFT → 50 MHz
- multi-bit `vowel_id` stays coherent
- no event is lost
- no event is duplicated

### Deliverable to Advay

Provide a test fixture/stub that produces:

```systemverilog
lane_active
lane_count
lane_hit_window
lane_hit_pulse
score
```

Advay must be able to test video without compiling the game subsystem.

### Definition of done

- game tests pass independently
- game runs entirely from synthetic vowel events
- CDC test passes
- video-facing outputs match frozen contract
- top-level accepts Luke and Advay modules without interface changes

### Additional role: integration lead

Jason also:

- maintains the integration branch
- maintains the interface table
- maintains the clock-domain map
- runs whole-system regressions
- maintains top-level / QSF / SDC
- coordinates Quartus builds
- leads final board bring-up
- records integration blockers

Luke and Advay remain responsible for correcting their own subsystem bugs.

---

## 4.2 Luke Mouawad — Audio/DSP and Classifier

### Files owned

All files under:

```text
rtl/audio/a2/
sim/audio/
tools/audio/
```

Luke also maintains the reused audio regression set.

### Independent output contract

Luke develops to:

```systemverilog
vowel_valid
vowel_id[1:0]
```

A dummy sink is sufficient.

No Jason or Advay RTL is required.

### Baseline regressions first

Before new A2 DSP:

1. codec/I2S input works
2. Lesson 4 low-pass/decimation passes
3. `fft_pitch_detect_tb.sv` passes
4. 1 kHz test gives approximately `k = 84/85`

### R-A1 — Gate and Level

Implement:

```text
audio_gate.sv
```

Required outputs:

```systemverilog
voice_active
level_db[6:0]
```

Requirements:

- fast leaky average of `|x|`
- tracked noise floor
- margin-based voice gate
- classifier disabled/blanked in silence
- dB display `00–99`
- parameterise gate margin and time constants

### R-A2 — 8 Band Energies

Implement:

```text
band_energy_8.sv
```

Input:

```text
mag_sq + mag_valid
```

Output:

```text
8 × 16-bit unsigned feature words
feature_valid once per completed frame
```

Test exact bin ownership, especially band edges.

### R-A3 — Normalisation

Implement:

```text
band_normalise.sv
```

Target behaviour:

- same vowel at approximately 2× amplitude should produce a sufficiently similar feature vector/classification
- document all widths and truncations

### R-A4 — 24 Log-Mel Energies

Implement:

```text
mel_filterbank_24.sv
log2_energy.sv
audio_features.sv
```

Final classifier input:

```systemverilog
feature[23:0][15:0]
feature_valid
```

Target behaviour:

- improved robustness to pitch
- improved robustness to recording level/distance
- compatible with provided `classifier.sv`

MFCC is an Extra and is not required for R-A4.

### Classifier

Do **not** rewrite `classifier.sv`.

Luke is responsible for:

- generating `templates.svh`
- understanding `D`, `FW`, `NT`, `M`, `DMAX`, `RHO_NUM`, `RHO_DEN`
- connecting `voice_active → enable`
- producing the frozen `vowel_valid/vowel_id` interface

### Fixed-point document

Luke must maintain:

```text
docs/fixed_point_table.md
```

For every audio stage record:

- signed / unsigned
- input width
- accumulator width
- output width
- fractional bits
- truncation / rounding
- maximum expected value

### Tests Luke writes

At minimum:

```text
audio_gate_tb.sv
band_energy_8_tb.sv
band_normalise_tb.sv
mel_filterbank_24_tb.sv
log2_energy_tb.sv
audio_subsystem_tb.sv
```

Test:

- silence
- room noise
- voiced signal
- exact band-edge FFT bins
- maximum energy
- zero energy
- doubled amplitude
- shifted pitch
- classifier reject
- classifier accept
- one `feature_valid` per frame

### Definition of done

Luke can run one command that:

1. runs all audio unit tests
2. runs the old pitch-detector regression
3. processes representative vowel test data
4. produces correct `vowel_valid/vowel_id`
5. requires no game or video RTL

---

## 4.3 Advay Hassan — Video Processing and VGA Rendering

### Files owned

```text
rtl/video/*
sim/video/*
tools/video/*
```

### Independent game input contract

Advay develops against mocked:

```systemverilog
lane_active[3:0]
lane_count[0:3]
lane_hit_window[3:0]
lane_hit_pulse[3:0]
score[15:0]
```

No Jason RTL is required.

### Baseline reuse first

Before A2 extensions:

1. Lesson 3 VGA output works
2. barcode `conv3x3.sv` regression passes
3. `col_profile.sv` regression passes
4. `peak_pick.sv` regression passes
5. barcode decoding is removed/ignored from the A2 path

### R-V0 — Edge Map

Provide the basic edge-map path.

View 1 must display the edge map.

### R-V1 — Profile, Boundaries and Game

Reuse:

```text
col_profile.sv
peak_pick.sv
blanking/frame latch
```

Requirements:

- boundaries come from image processing
- no manually typed key x-coordinates
- choose four consecutive detected white keys
- view 2 shows profile + threshold
- view 3 shows four key masks
- game view uses the detected masks

### R-V2 — Sobel

Reuse `conv3x3.sv` with the Sobel kernel.

Requirements:

- proper line-buffer implementation
- account for convolution x/y latency
- `SW5` selects 1-D vs Sobel
- noisy second image must still produce usable boundaries

Do not create a second unrelated `sobel_3x3.sv` if `conv3x3.sv` already performs the required convolution.

### R-V3 — Refined Peaks

Add/extend:

```text
profile_normalise.sv
peak_pick.sv
hysteresis_profile.sv
```

Requirements:

- divide/scale profile by maximum
- local maxima only
- minimum key spacing
- high threshold
- low threshold / hysteresis
- one threshold setting works for both supplied images
- thresholds controllable from free board inputs

### R-V4 — Photograph Robustness

Reuse `conv3x3.sv` a second time with a smoothing kernel before Sobel.

Add:

```text
local_threshold.sv
```

Requirements:

- smoothing before Sobel
- threshold follows local profile average
- shadowed/uneven image still finds every white-key gap
- game remains playable
- any extra detected boundary can be explained

### Rendering

`game_video_overlay.sv` owns:

- lane brightness from `lane_count`
- red appearance during `lane_hit_window`
- score drawing
- debug view switching
- key-mask rendering

It must use only the frozen game-state interface.

### Tests Advay writes

At minimum:

```text
conv3x3 regression
col_profile regression
peak_pick regression
profile_normalise_tb.sv
local_threshold_tb.sv
key_mask_generator_tb.sv
game_video_overlay_tb.sv
video_subsystem_tb.sv
```

Test:

- flat image
- one strong edge
- multiple expected key gaps
- closely spaced false peaks
- noisy image
- shadow / gradient
- frame reset
- vertical blanking
- random Avalon-ST stalls
- convolution latency
- game state changing mid-frame

### Definition of done

- all video tests run without Jason's game RTL
- all four debug views work
- all four playable masks come from detected boundaries
- noisy second image passes R-V2
- both supplied images pass R-V3 with one threshold configuration
- photograph path implements the R-V4 architecture

---

# 5. System Architecture

```text
                         AUDIO SIDE — LUKE
                         =================

MIC
 │
 ▼
WM8731 / mic_load
16-bit @ 48 kHz
 │
 ├──────────────► audio_gate
 │                 │
 │                 ├──► level_db
 │                 └──► voice_active
 │
 ▼
low_pass_conv
 │
 ▼
decimate
48 kHz → 12 kHz
 │
 ▼
window_function
 │
 ▼
async_fifo + fft_input_buffer
CDC: audio/BCLK → FFT
 │
 ▼
1024-point FFT @ 18.432 MHz
 │
 ▼
fft_mag_sq
 │
 ├──────────────► fft_find_peak ───► peak_k debug
 │
 ▼
R-A4 FEATURE PIPELINE
24 log-Mel energies
 │
 ▼
provided classifier
 │
 ▼
result / reject / result_valid
 │
 ▼
vowel_valid + vowel_id
 │
 ▼
audio_game_cdc
FFT → 50 MHz


                         GAME SIDE — JASON
                         ==================

vowel_valid + vowel_id
 │
 ▼
vowel_hit_mapper
 │
 ▼
game_fsm / lane / timer / score
 │
 ├──► lane_active[3:0]
 ├──► lane_count[0:3]
 ├──► lane_hit_window[3:0]
 ├──► lane_hit_pulse[3:0]
 └──► score[15:0]
 │
 ▼
game_video_cdc
50 MHz → 25 MHz


                         VIDEO SIDE — ADVAY
                         ===================

piano image ROM
 │
 ├───────────────► game_video_overlay
 │
 ▼
optional R-V4 smoothing conv3x3
 │
 ▼
1-D edge / Sobel conv3x3
 │
 ▼
col_profile
 │
 ▼
profile normalise
 │
 ▼
NMS + spacing + hysteresis
 │
 ▼
local/adaptive threshold
 │
 ▼
detected boundaries
 │
 ▼
key_mask_generator
 │
 ▼
game_video_overlay
 │
 ▼
VGA 640×480 @ 25 MHz
```

---

# 6. Integration Contracts

## 6.1 Contract A — Luke → Jason

Destination clock domain: 50 MHz after CDC.

```systemverilog
output logic       vowel_valid;
output logic [1:0] vowel_id;
```

`vowel_valid` is one cycle only.

No other audio signal may be required by game logic.

## 6.2 Contract B — Jason → Advay

Destination: video subsystem after game→video CDC/frame latch.

```systemverilog
output logic [3:0] lane_active;
output logic [3:0] lane_hit_window;
output logic [3:0] lane_hit_pulse;
output logic [GAME_COUNT_W-1:0] lane_count [0:3];
output logic [15:0] score;
```

Advay must not depend on Jason's FSM encoding.

## 6.3 Contract C — Luke → Top-Level Debug

```systemverilog
peak_k[9:0]
level_db[6:0]
voice_active
classifier_result[1:0]
classifier_result_valid
classifier_reject
confidence[7:0]
```

Used only for board display/debug.

## 6.4 Contract D — Video Internal Boundary Representation

Advay owns this contract internally.

Recommended:

```systemverilog
boundary_x[NMAX-1:0][8:0]
boundary_count[$clog2(NMAX+1)-1:0]
boundary_valid
```

Boundary x positions use 320-pixel source coordinates.

The rest of the system must not hard-code or consume these boundary positions directly.

---

# 7. Shared Integration Plan

Integration is explicitly a **group task**, not a fourth subsystem assigned to one person.

## Jason — integration lead/coordinator

- maintain integration branch
- maintain top-level
- maintain QSF/SDC
- check interface compatibility
- schedule merge checkpoints
- run whole-system tests
- run board builds
- record blockers
- coordinate final board bring-up

## Luke — audio integration responsibility

- connect the audio/classifier subsystem into top-level
- fix audio-side interface issues
- fix fixed-point issues
- fix audio CDC issues
- debug microphone/classifier behaviour on hardware

## Advay — video integration responsibility

- connect video/boundary/overlay subsystem into top-level
- fix Avalon-ST issues
- fix boundary/mask issues
- fix VGA issues
- debug display/image-processing behaviour on hardware

## Schedule-protection / takeover rule

1. Every owned module has an agreed interface, test requirement and milestone.
2. If a module misses its milestone, the owner communicates the delay immediately.
3. The owner provides the latest working commit.
4. The team gives a short explicit recovery window.
5. If still blocking integration, Jason may complete/replace only the work needed to unblock the system.
6. Any takeover is recorded in:

```text
docs/project_management/contribution_log.md
docs/project_management/decision_log.md
```

Record:

```text
original owner
agreed milestone
status at milestone
integration blocker
takeover work performed
final commit(s)
```

This is a contingency only.

---

# 8. Git Workflow

Suggested branches:

```text
main
├── audio-luke
├── video-advay
└── integration-jason
```

Rules:

1. Do not develop directly on `main`.
2. Pull/rebase before merge.
3. Every meaningful change must be committed.
4. Do not use chat/file transfer as the primary integration workflow.
5. Merge only after relevant tests pass.
6. Subsystem owners fix their own failures during integration.
7. Tag known-good milestones.

Suggested tags:

```text
reuse-baseline
audio-r1
audio-r2
audio-r3
audio-r4
video-r1
video-r2
video-r3
video-r4
first-system-integration
board-working-v1
final-demo
```

---

# 9. Definition of Done for Every New/Modified Module

- [ ] synthesizable RTL
- [ ] documented interface
- [ ] documented clock/reset domain
- [ ] self-checking testbench
- [ ] normal case tested
- [ ] edge/boundary case tested
- [ ] reset/stall/invalid case tested where relevant
- [ ] no unexplained critical warnings
- [ ] committed to Git
- [ ] owner review completed
- [ ] neighbouring-module integration test completed where relevant
- [ ] useful waveform/report evidence saved

---

# 10. Milestones

## M0 — Repository Ready

- structure created
- access confirmed
- branch rules agreed
- ownership agreed
- interfaces frozen

## M1 — Reuse Baseline Verified

Audio:

- Lesson 3 mic chain verified
- pitch-detection simulation passes

Video:

- Lesson 3 VGA verified
- barcode mini-project regression passes

Game:

- A1 game regression passes

## M2 — Independent Subsystem Skeletons

Jason:

- synthetic vowel input drives game

Luke:

- classifier wrapper + gate skeleton works

Advay:

- mock game signals drive VGA overlay

## M3 — Required Baseline Rungs

Audio:

- R-A0/R-A1 working

Video:

- R-V0/R-V1 working

Game:

- scoring integrated with vowel events

## M4 — Credit Rungs

Audio:

- R-A2 band energy

Video:

- R-V2 Sobel

## M5 — Distinction Rungs

Audio:

- R-A3 normalised bands

Video:

- R-V3 refined peak detection

## M6 — High Distinction Rungs

Audio:

- R-A4 24 log-Mel

Video:

- R-V4 smoothing + adaptive/local threshold

## M7 — First Full Simulation

- audio/classifier connected
- game reacts
- game drives video
- whole-system test passes

## M8 — Quartus Integration

- Platform Designer generated
- PLL/IP present
- QSF/SDC correct
- full compile succeeds
- all four clocks constrained
- timing analysed

## M9 — First Working Board

- microphone works
- classifier produces meaningful events
- game reacts
- VGA displays game state

## M10 — Stable Demo Build

- full regression passes
- timing acceptable
- no blocking bugs
- report evidence saved
- known-good `.sof` tagged

---

# 11. Risk Register

| Risk | Likelihood | Impact | Mitigation | Owner |
|---|---:|---:|---|---|
| CDC fault between audio/FFT/game/VGA | High | High | frozen interfaces, FIFO/synchroniser/handshake, CDC tests | Jason |
| Classifier repeats/false-triggers | Medium | High | gate/qualify valid, one-shot event interface | Luke |
| Fixed-point overflow/scaling error | Medium | High | fixed-point table, numerical reference tests | Luke |
| Audio R-A4 exceeds resources/timing | Medium | High | staged implementation, width review, Quartus checks | Luke |
| Boundary detector not robust | Medium | High | notebook reference, synthetic images, staged rungs | Advay |
| VGA stream breaks under stalls | Medium | High | random-stall Avalon-ST tests | Advay |
| R-V4 line buffers infer registers instead of RAM | Medium | High | verify M10K inference in Quartus | Advay |
| Convolution latency misaligns boundaries | Medium | High | explicit latency test and coordinate compensation | Advay |
| Integration happens too late | Medium | High | independent mocks + frozen ports + regular merge checkpoints | All |
| Work exists only locally | Medium | High | frequent commits | All |
| Report evidence forgotten | Medium | Medium | save evidence at verification time | All |
| Tutor photo compile is late | Medium | High | keep image files separate and build flow rehearsed | Jason/Advay |

---

# 12. Project Management Evidence

Maintain:

```text
docs/project_management/meeting_minutes.md
docs/project_management/decision_log.md
docs/project_management/risk_register.md
docs/project_management/contribution_log.md
```

## Meeting template

```text
Date:
Present:
Completed since last meeting:
Problems:
Decisions:
Tasks assigned:
Owner:
Deadline:
```

## Contribution log template

```text
Date | Member | Module/task | Commit/PR | Test evidence | Status
```

## Decision log example

```text
Decision:
Audio → game uses a one-event valid pulse rather than a level-sensitive classifier result.

Reason:
Prevents one held vowel from repeatedly scoring.

Affected modules:
audio_game_cdc
vowel_hit_mapper
```

---

# 13. Report Evidence Responsibilities

## Q1 — System Design

Jason leads:

- complete system block diagram
- signal widths
- sample/frame rates
- clock domains
- CDC mechanisms
- module interfaces
- valid/ready semantics
- what latches during blanking
- what happens to mid-frame results

Luke and Advay provide exact subsystem details.

## Q2 — Audio and Image Processing

### Luke

Provide:

- gate theory
- noise-floor tracking
- dB approximation
- R-A1 → R-A4 theory
- fixed-point formats
- truncation/scaling choices
- feature-vector plots

### Advay

Provide:

- rows used in column profile
- thresholds
- minimum spacing
- Sobel/kernel theory
- normalisation/NMS/hysteresis
- local thresholding
- profile plots and detected boundaries

## Q3 — Testing and Verification

Each owner supplies:

- self-checking tests
- rationale for test inputs
- annotated waveform evidence
- one meaningful failure case

System test must include audio and video.

At least one reported test should intentionally fail against a broken module variant.

## Q4 — Hardware Mindset

Jason coordinates:

- predicted ALM/M10K/DSP usage
- actual Quartus usage
- Fmax for all four clocks
- slowest critical path
- proposed optimisation

Luke supplies audio resource notes.

Advay supplies line-buffer / image-processing resource notes.

Save a Post-Technology Map screenshot showing:

- one clock-domain crossing
- and either:
  - DSP multiplier, or
  - line-buffer M10K

## Q5 — Contributions

Maintain a table of:

- member
- owned modules
- owned testbenches
- integration tasks
- who uploads

---

# 14. Demo Requirements

Be ready to explain and predict behaviour before the tutor performs each probe.

## Audio

### R-A0

Tone generator:

```text
k = round(fN/fs)
```

and `HEX5..HEX3` shows the detected FFT bin.

### R-A1

- hold vowel for two seconds
- dB display responds
- classifier output is blank in silence
- explain limitation of peak-bin-only classification

### R-A2

Two vowels at same pitch/loudness should classify differently.

### R-A3

Same vowel at different loudness should stay the same class.

### R-A4

Same vowel should be more robust to:

- clearly higher pitch
- increased distance / lower recording level

## Video

### R-V1

Game works from detected keys, not fixed coordinates.

### R-V2

Noisy second picture works using Sobel.

### R-V3

High/low thresholds can be adjusted while viewing profile.

### R-V4

Tutor photograph with shadow/uneven lighting still finds key gaps using:

```text
smoothing
→ Sobel
→ local/adaptive threshold
```

## Live-change preparation

Know where to change:

- gate margin
- band edge
- number of Mel bands
- classifier vote length
- edge threshold
- minimum key spacing
- beat
- hit window
- vowel-to-key mapping
- lane colour
- view mapping
- HEX mapping
- reject rule
- hit rule
- blanking latch behaviour
- convolution delay
- clock-domain transfer

---

# 15. Immediate Next Actions

## Jason

- [ ] Create `assignment2_pkg.sv` with frozen constants.
- [ ] Create mock audio event generator for game tests.
- [ ] Import A1 `game_fsm.sv`, `lane.sv`, `score.sv`, `timer.sv`.
- [ ] Implement `vowel_hit_mapper.sv`.
- [ ] Implement/test `audio_game_cdc.sv`.
- [ ] Freeze Game → Video ports.
- [ ] Give Advay a mock-game test source.
- [ ] Start `top_level.sv` using subsystem stubs.

## Luke

- [ ] Move tested pitch detector files into `rtl/audio/pitch_reuse/`.
- [ ] Preserve passing `fft_pitch_detect_tb.sv` as regression.
- [ ] Add provided `classifier.sv`, training scripts and templates.
- [ ] Implement/test R-A1 gate + dB level.
- [ ] Implement/test R-A2 8-band accumulator.
- [ ] Implement/test R-A3 normalisation.
- [ ] Implement/test R-A4 24 log-Mel path.
- [ ] Produce only `vowel_valid/vowel_id` for Jason.
- [ ] Maintain fixed-point table continuously.

## Advay

- [ ] Move tested `conv3x3.sv`, `col_profile.sv`, `peak_pick.sv` into `barcode_reuse/`.
- [ ] Preserve barcode unit tests as regressions.
- [ ] Import Lesson 3 VGA pipeline.
- [ ] Implement R-V1 piano boundary/mask path.
- [ ] Use `conv3x3.sv` for R-V2 Sobel.
- [ ] Extend peak processing for R-V3.
- [ ] Reuse `conv3x3.sv` with smoothing coefficients for R-V4.
- [ ] Implement local/adaptive profile threshold.
- [ ] Build game overlay entirely against mocked game-state ports.
- [ ] Produce PNG/debug evidence from subsystem TB.

---

# 16. Team Rule

> Each member owns a technical subsystem. Interfaces are frozen first, every subsystem is testable against mocks, and integration connects already-tested blocks rather than waiting on unfinished code.

No member should wait for another person's implementation before beginning their own work.

Small tested increments should be committed regularly.

If a subsystem blocks the agreed schedule:

1. record the issue
2. give the owner a defined recovery window
3. use the documented takeover process only if necessary

The final objective is one stable, tested, timing-clean DE1-SoC build with the highest normal audio and video rungs working together.
