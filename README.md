# MTRX3700 Assignment 2 — Shine and Sing

## Project Goal

This repository is for **MTRX3700 Assignment 2**, integrating reusable Lesson 3 communications/VGA modules, Lesson 4 DSP modules, Mini-Project 2 modules once released, and selected Assignment 1 game logic into one FPGA system.

**Internal team target:** first complete board integration by **Friday 2 October 2026**, with a stable fully working board build by **Sunday 4 October 2026** so there is still time for debugging, timing work, report evidence, and demo preparation.

### Team ownership

Each member has a clearly owned **individual technical module/subsystem**, while **system integration is a shared group responsibility**.

- **Jason Yang** — **Game/Control Module**: vowel-to-game event mapping, game FSM adaptation, scoring/hit logic and game-state outputs
- **Luke Mouawad** — **Audio Classification Module**: microphone/DSP pipeline, feature extraction and classifier interface
- **Advay Hassan** — **Video Processing Module**: piano-key boundary detection, key masks and VGA game rendering

**Integration is a team task.** Jason acts as the **integration lead/coordinator**, meaning he maintains the integration branch, coordinates interface compatibility, runs whole-system regressions and leads final board bring-up. This does **not** make integration solely Jason's task: each subsystem owner must integrate, debug and fix their own module when connected to the full design.

If an agreed module milestone is missed, or a submitted module does not meet the previously agreed interface/test/quality requirements in time for integration, the integration lead may take over the minimum work necessary to keep the project on schedule. Any takeover should be documented in the contribution/decision log with the original owner, agreed deadline, issue found, and work completed.

> **Note:** Mini-Project 2 has not yet been released. Filenames marked **[PROVISIONAL]** reflect the expected architecture from the Assignment 2 brief and Lessons 3–4. When the official scaffold is released, keep the official module/port names and update this README.

---

# 1. Proposed Repository Structure

```text
MTRX3700_Assignment2_ShineAndSing/
│
├── README.md
├── .gitignore
│
├── quartus/
│   ├── assignment2.qpf
│   ├── assignment2.qsf
│   ├── assignment2.sdc
│   ├── platform_designer/
│   │   ├── vga.qsys
│   │   └── generated/
│   └── ip/
│       ├── video_pll/              # REUSED — Lesson 3
│       ├── audio_pll/              # REUSED — Lesson 3
│       └── fft/                    # REUSED — Lesson 4 / Mini-Project 2
│
├── rtl/
│   ├── top/
│   │   ├── top_level.sv            # NEW — Jason
│   │   ├── clock_reset_control.sv  # NEW/ADAPTED if required — Jason
│   │   └── system_debug.sv         # NEW optional — Jason
│   │
│   ├── audio/
│   │   ├── reused/
│   │   │   ├── i2c_master.sv            # REUSED — Lesson 3
│   │   │   ├── set_audio_encoder.sv     # REUSED — Lesson 3
│   │   │   ├── mic_load.sv              # REUSED — Lesson 3
│   │   │   ├── clock_divider.sv         # REUSED — Lesson 3
│   │   │   ├── adc_pll.sv               # REUSED — Lesson 3
│   │   │   ├── async_fifo.sv            # REUSED — Lesson 4
│   │   │   ├── fft_input_buffer.sv      # REUSED — Lesson 4
│   │   │   ├── window.sv                # REUSED — [PROVISIONAL MP2]
│   │   │   ├── decimator.sv             # REUSED — [PROVISIONAL MP2]
│   │   │   ├── magnitude_squared.sv     # REUSED — [PROVISIONAL MP2]
│   │   │   └── peak_finder.sv           # REUSED — [PROVISIONAL MP2]
│   │   ├── classifier/
│   │   │   ├── classifier.sv            # PROVIDED / REUSED from A2 scaffold
│   │   │   └── classifier_interface.sv  # NEW — Luke
│   │   └── new/
│   │       ├── audio_level_gate.sv       # NEW — Luke
│   │       ├── band_energy.sv            # NEW — Luke, if targeting higher audio rung
│   │       ├── feature_normalise.sv      # NEW — Luke
│   │       ├── mel_filterbank.sv         # NEW — Luke
│   │       └── log_energy.sv             # NEW — Luke
│   │
│   ├── video/
│   │   ├── reused/
│   │   │   ├── vga_face.sv              # REUSED/ADAPTED — Lesson 3
│   │   │   ├── video_pll.sv              # REUSED — Lesson 3
│   │   │   ├── edge_1d.sv                # REUSED — [PROVISIONAL MP2]
│   │   │   ├── column_profile.sv         # REUSED — [PROVISIONAL MP2]
│   │   │   ├── boundary_picker.sv        # REUSED — [PROVISIONAL MP2]
│   │   │   └── blanking_latch.sv         # REUSED — [PROVISIONAL MP2]
│   │   └── new/
│   │       ├── key_mask_generator.sv     # NEW — Advay
│   │       ├── game_video_overlay.sv     # NEW — Advay
│   │       ├── sobel_3x3.sv              # NEW — Advay, if targeting higher video rung
│   │       ├── line_buffer.sv            # NEW/ADAPTED — Advay
│   │       ├── profile_normalise.sv      # NEW — Advay
│   │       ├── nonmax_suppression.sv     # NEW — Advay
│   │       ├── hysteresis_threshold.sv   # NEW — Advay
│   │       └── adaptive_threshold.sv     # NEW — Advay
│   │
│   ├── game/
│   │   ├── game_fsm.sv              # REUSED/ADAPTED — Assignment 1 — Jason
│   │   ├── lane.sv                  # REUSED/ADAPTED — Assignment 1 — Jason
│   │   ├── score.sv                 # REUSED/ADAPTED — Assignment 1 — Jason
│   │   ├── timer.sv                 # REUSED if useful — Jason
│   │   └── vowel_hit_mapper.sv      # NEW — Jason
│   │
│   └── common/
│       ├── synchroniser.v           # REUSED
│       ├── pulse_stretch.sv         # REUSED if useful
│       └── cdc_handshake.sv         # NEW only if required — Jason
│
├── memory/
│   ├── piano.mif                    # PROVIDED/REUSED image
│   └── coefficients/
│
├── sim/
│   ├── models/
│   │   ├── wm8731_model.sv          # REUSED — Lesson 3
│   │   └── vga_monitor_model.sv     # REUSED — Lesson 3
│   ├── audio/
│   │   ├── audio_level_gate_tb.sv
│   │   ├── classifier_interface_tb.sv
│   │   ├── band_energy_tb.sv
│   │   └── audio_pipeline_tb.sv
│   ├── video/
│   │   ├── key_mask_generator_tb.sv
│   │   ├── game_video_overlay_tb.sv
│   │   ├── sobel_3x3_tb.sv
│   │   └── video_pipeline_tb.sv
│   ├── game/
│   │   ├── vowel_hit_mapper_tb.sv
│   │   ├── game_fsm_tb.sv
│   │   └── score_tb.sv
│   └── system/
│       ├── top_level_tb.sv
│       └── cdc_integration_tb.sv
│
├── scripts/
│   ├── run_all_tests.sh
│   ├── compile_fpga.py              # use scaffold version if supplied
│   └── submit_to_ed.py              # use scaffold version if supplied
│
└── docs/
    ├── architecture/
    │   ├── system_block_diagram.drawio
    │   ├── clock_domain_map.md
    │   └── interface_table.md
    ├── project_management/
    │   ├── meeting_minutes.md
    │   ├── decision_log.md
    │   ├── risk_register.md
    │   └── contribution_log.md
    └── report_evidence/
        ├── waveforms/
        ├── timing/
        └── screenshots/
```

---

# 2. Reuse Register

| Module / Function | Source | Status | Owner |
|---|---|---|---|
| `i2c_master` | Lesson 3 | Reuse directly | Luke |
| `set_audio_encoder` | Lesson 3 mic workspace | Reuse directly | Luke |
| `mic_load` | Lesson 3 | Reuse directly | Luke |
| WM8731 model | Lesson 3 | Simulation only | Luke |
| Audio PLL / clock divider | Lesson 3 | Reuse directly | Luke |
| VGA Platform Designer chain | Lesson 3 | Reuse/adapt | Advay |
| VGA source/image infrastructure | Lesson 3 | Reuse/adapt | Advay |
| VGA monitor model | Lesson 3 | Simulation only | Advay |
| Async FIFO | Lesson 4 | Reuse directly | Luke |
| FFT input buffer | Lesson 4 | Reuse directly | Luke |
| Decimator/window/FFT/mag²/peak finder | Mini-Project 2 | Reuse once released | Luke |
| 1-D edge/profile/boundary pipeline | Mini-Project 2 | Reuse once released | Advay |
| `game_fsm` | Assignment 1 | Reuse/adapt | Jason |
| `lane` / hit-window logic | Assignment 1 | Reuse/adapt | Jason |
| `score` | Assignment 1 | Reuse/adapt | Jason |
| synchronisers / CDC helpers | Earlier lessons/A1 | Reuse where appropriate | Jason |

**Rule:** do not rewrite working lesson/MP2 modules just to make them “Assignment 2 code.” If a reused module is modified, document exactly what changed and extend its tests.

---

# 3. Work Split

## Jason Yang — Individual Module: Game/Control Subsystem

### Primary individual deliverable

Jason owns the **Game/Control Module** as his individual technical contribution. Its job is to turn a classified vowel event into a game action and expose clean game-state signals to the video subsystem.

### Reused code
- `game_fsm.sv`
- `lane.sv`
- `score.sv`
- timer/hit-window support
- synchronisers / pulse-stretch helpers where needed

### New/adapted code
- `vowel_hit_mapper.sv`
- adaptations to `game_fsm.sv`, `lane.sv`, and `score.sv`
- `game_control_tb.sv` or equivalent subsystem TB
- game-state interface signals for the video subsystem

### Instructions
1. Define a small input contract from Luke's module, ideally:
   ```text
   vowel_valid
   vowel_id[1:0]
   optional confidence/level qualifier
   ```
2. Convert the classifier event into exactly one game action per accepted vowel event.
3. Reuse the Assignment 1 game logic where practical rather than rewriting it.
4. Preserve and test hit-window, miss/clear and score-saturation behaviour.
5. Expose a clean video-facing contract, e.g.:
   ```text
   lane_active[3:0]
   lane_state/countdown
   hit_pulse[3:0]
   score
   game_enable
   ```
6. Write self-checking tests for:
   - each vowel mapping,
   - inactive-lane input,
   - valid hit,
   - early/wrong hit if relevant,
   - simultaneous/rapid events,
   - reset,
   - score saturation.
7. Document the module clock domain and any assumptions about incoming event timing.

### Definition of done
- all four vowel IDs map to the intended game lanes;
- one classifier event produces one controlled game event;
- A1 game behaviour remains correct after adaptation;
- subsystem TB passes independently;
- Advay can consume the game-state outputs without depending on internal game logic.

### Additional role: Integration Lead

Jason also acts as **integration lead/coordinator**, but integration remains shared by all three members. Jason's coordination duties are:
- maintain the integration branch,
- maintain the system interface/clock-domain table,
- schedule integration checkpoints,
- run full-system regressions,
- maintain the Quartus top-level/QSF/SDC,
- lead final board bring-up.

Luke and Advay remain responsible for debugging and correcting their own subsystems during integration.

---

## Luke Mouawad — Audio/DSP Pipeline and Classifier Interface

### Reused code
- Lesson 3 I2C/WM8731 configuration
- `mic_load`
- codec PLL / clock divider
- WM8731 model
- async FIFO
- FFT input buffer
- Mini-Project 2 decimation/window/FFT/magnitude²/peak finder once released

### New code
- `audio_level_gate.sv`
- `classifier_interface.sv`
- higher-rung DSP blocks such as band energy, normalisation, Mel mapping and log energy if targeted

### Instructions
1. Rebuild and verify the complete Lesson 3 audio path first.
2. Run I2C and LJ receiver tests before integrating FFT logic.
3. Import official MP2 modules unchanged where possible.
4. Create a clean interface to Jason:
   ```text
   vowel_valid
   vowel_id[1:0]
   optional confidence/level
   ```
5. Ensure one detected vowel creates a controlled event rather than accidental repeated game hits.
6. Implement silence/level gating and parameterise thresholds where practical.
7. Maintain an explicit fixed-point table: total bits, fractional bits, signedness, expected range.
8. Test silence, max/min samples, zero-energy frames, adjacent FFT peaks, strong tones and valid/no-valid transitions.
9. Create an audio subsystem TB with numerical assertions.
10. Save DSP plots, waveforms and resource/timing changes for the report.

### Definition of done
- codec/model configuration passes;
- 1024-sample frames reach FFT correctly;
- feature outputs match expected numerical values;
- classifier interface is stable and documented;
- Jason can consume the audio result without knowing the internal DSP pipeline.

---

## Advay Hassan — Video/Image Processing and Game Rendering

### Reused code
- Lesson 3 VGA source / Platform Designer chain
- video PLL
- image ROM / `.mif` infrastructure
- VGA monitor model
- Mini-Project 2 1-D edge, column profile, boundary picker and blanking logic once released

### New code
- `key_mask_generator.sv`
- `game_video_overlay.sv`
- higher-rung Sobel/line-buffer/NMS/hysteresis/adaptive-threshold modules if targeted

### Instructions
1. Rebuild and verify the Lesson 3 VGA output before adding game logic.
2. Confirm Avalon-ST `valid/ready`, `startofpacket` and `endofpacket` behaviour under random stalls.
3. Import official MP2 image/boundary modules unchanged where possible.
4. Generate four playable key masks from **detected boundaries**, not arbitrary hard-coded screen positions.
5. Create the game overlay using state inputs supplied by Jason.
6. Keep key/boundary state stable for the appropriate frame interval.
7. Add 3×3 Sobel and line buffers only after baseline boundary detection works.
8. Test uniform images, strong edges, closely spaced edges, left/right border cases, VGA stalls and packet framing.
9. Create a video subsystem TB with assertions.
10. Save input image, edge/profile output, selected boundaries, final overlay and stall waveform for the report.

### Definition of done
- stable VGA under backpressure;
- correct piano-key boundaries;
- four masks derive from detected boundaries;
- game state colours/changes the correct visual key;
- subsystem TB passes without relying only on manual waveform viewing.

---

# 4. Shared Integration Plan

Integration is explicitly a **group task**, not a fourth subsystem assigned to one person.

## Integration responsibilities

### Jason — integration lead/coordinator
- maintains the integration branch and top-level project;
- checks interface compatibility;
- schedules merge/integration checkpoints;
- runs whole-system tests and board builds;
- records blockers and assigns them back to the relevant subsystem owner.

### Luke — audio integration responsibility
- connects and validates the audio/classifier subsystem in the shared top-level;
- fixes audio-side interface, timing, fixed-point or valid/ready problems found during system testing;
- remains available during board bring-up for microphone/classifier debugging.

### Advay — video integration responsibility
- connects and validates the video/boundary/overlay subsystem in the shared top-level;
- fixes Avalon-ST, boundary, mask or VGA issues found during system testing;
- remains available during board bring-up for display/video debugging.

## Schedule-protection / takeover rule

To manage the risk of late or sub-standard subsystem delivery:

1. Every owned module has an agreed interface, test requirement and milestone date.
2. If a module misses its milestone, the owner must communicate the delay immediately and provide the latest working commit.
3. The team first gives the owner a short, explicit recovery window.
4. If the module is still blocking integration, the integration lead may complete or replace only the work necessary to unblock the system.
5. Any takeover is recorded in:
   ```text
   docs/project_management/contribution_log.md
   docs/project_management/decision_log.md
   ```
6. The record should include:
   ```text
   original owner
   agreed milestone
   status at milestone
   integration blocker
   takeover work performed
   final commit(s)
   ```
7. This is a contingency, not the default workflow. The goal is still that each member completes and integrates their own technical module.

---

# 5. Integration Contracts

## Audio → Game

```text
vowel_valid        1 bit
vowel_id           2 bits
audio_level        optional
```

Producer: Luke  
Consumer: Jason

## Game → Video

```text
lane_active[3:0]
lane_state/countdown
hit_pulse[3:0]
score
game_enable
```

Producer: Jason  
Consumer: Advay

## Boundary Detector → Overlay

```text
boundary_0 ... boundary_4
boundary_valid
```

or equivalent official MP2 signals.

Producer/consumer: Advay

---

# 6. Git Workflow

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
4. Do not use chat/file transfer as the primary code-integration workflow.
5. Merge only after relevant tests pass.
6. Subsystem owners fix their own module failures during integration.
7. Tag known-good milestones:
   ```text
   mp2-imported
   audio-working
   video-working
   first-system-integration
   board-working-v1
   final-demo
   ```

---

# 7. Definition of Done for Every New/Modified Module

- [ ] synthesizable RTL
- [ ] documented interface
- [ ] documented clock/reset domain
- [ ] self-checking testbench
- [ ] normal case
- [ ] edge/boundary case
- [ ] reset/stall/invalid case where relevant
- [ ] no unexplained warnings
- [ ] committed to Git
- [ ] owner review
- [ ] neighbouring-module integration test
- [ ] useful waveform/report evidence saved

---

# 8. Gantt / Milestone Plan

Planning date: **Tuesday 22 September 2026**

Targets:
- **First complete board integration:** Friday **2 October**
- **Stable fully working board:** Sunday **4 October**

| Date | Jason — Integration/Game | Luke — Audio/DSP | Advay — Video | Team Milestone |
|---|---|---|---|---|
| Tue 22 Sep | Create repo structure; define clocks/interfaces; import A1 game | Import Lesson 3 audio; list Lesson 4 reuse | Import Lesson 3 VGA | Repo + ownership agreed |
| Wed 23 Sep | Adapt game event interface; extend A1 tests | Re-run mic/I2C/LJ simulations | Re-run VGA simulation | Lesson 3 baseline verified |
| Thu 24 Sep | Draft system diagram + CDC map | Integrate current FFT/FIFO lesson modules | Prepare boundary interface + overlay scaffold | Interfaces frozen v1 |
| Fri 25 Sep | Implement vowel→hit mapping | Finish audio level/gate + classifier wrapper scaffold | Finish key-mask + overlay scaffold | New-module skeletons compile |
| Sat 26 Sep | Integration harness with mocked subsystems | Audio subsystem TBs | Video subsystem TBs | Standalone tests running |
| Sun 27 Sep | Review interfaces; update top-level | Fixed-point/numerical verification | Backpressure/packet verification | Subsystem Review 1 |
| Mon 28 Sep | Merge verified reuse | Import MP2 audio if released; regression | Import MP2 video if released; regression | MP2 baseline imported |
| Tue 29 Sep | Integrate Game/Control with Luke; resolve game-side CDC | Integrate Audio/Classifier with Jason; fix audio-side issues | Deliver and integrate clean boundary/mask interface | Audio→game working |
| Wed 30 Sep | Integrate game outputs into shared top-level; run full simulation | Debug audio path in shared top-level | Integrate game state into video overlay and debug VGA path | **First complete simulation — all three present** |
| Thu 1 Oct | Maintain Quartus/QSF/SDC and coordinate fixes | Fix audio/classifier integration failures | Fix VGA/Platform Designer/video failures | **Shared full compile + timing report** |
| Fri 2 Oct | Lead/co-ordinate board bring-up; debug game/control | Own mic/classifier hardware debug | Own VGA/boundary hardware debug | **FIRST COMPLETE BOARD BUILD — group integration session** |
| Sat 3 Oct | System regression + CDC/timing fixes | Audio fixes + report evidence | Video fixes + report evidence | Board-working v2 |
| Sun 4 Oct | Final known-good `.sof`; tag release | Final audio verification | Final video verification | **STABLE FULL SYSTEM DEADLINE** |

The period after 4 October should be reserved for higher-grade feature upgrades, stronger tests, timing optimisation, report writing, annotated waveforms, and demo practice — not baseline integration.

---

# 9. Milestones

### M0 — Repository Ready — 22 Sep
- structure created
- member access confirmed
- branch rules agreed
- ownership assigned

### M1 — Reused Lesson 3 Baseline Verified — 23 Sep
- microphone chain passes
- VGA chain passes
- A1 game regression passes

### M2 — Interfaces Frozen — 24 Sep
- widths and directions documented
- clock domains documented
- valid/ready semantics fixed
- system diagram v1 complete

### M3 — Standalone New Modules — 27 Sep
- audio wrapper/gate tested
- key-mask/overlay tested
- vowel→game mapping tested

### M4 — MP2 Import — 28 Sep or within 24 h of release
- official files imported
- original tests run
- no unnecessary rewrites

### M5 — First Full Simulation — 30 Sep
- audio/classifier path connected
- game reacts
- game drives video

### M6 — Quartus Integration — 1 Oct
- Platform Designer generated
- PLL/IP present
- QSF/SDC correct
- full design compiles
- timing analysed

### M7 — First Working Board — 2 Oct
- microphone works
- classifier produces meaningful events
- game reacts
- VGA displays game state

### M8 — Stable Board Release — 4 Oct
- regression passes
- timing acceptable
- no blocking bugs
- report evidence saved
- known-good release tagged

---

# 10. Risk Register

| Risk | Likelihood | Impact | Mitigation | Owner |
|---|---:|---:|---|---|
| MP2 released later than expected | Medium | High | Finish Lesson 3/A1 reuse first; import MP2 within 24 h | All |
| CDC fault between audio/FFT/game/VGA clocks | High | High | Explicit clock-domain map; FIFO/synchroniser/handshake; CDC tests | Jason |
| Classifier repeats/false-triggers | Medium | High | Gate/qualify valid; silence tests; event interface | Luke |
| Fixed-point overflow/scaling error | Medium | High | Fixed-point table; numerical reference tests; wide accumulators | Luke |
| Boundary detector not robust | Medium | High | Synthetic edge cases; multiple images; incremental upgrades | Advay |
| VGA stream breaks under backpressure | Medium | High | Random-stall Avalon-ST tests | Advay |
| Platform Designer/IP regeneration breaks build | Medium | Medium | Commit source metadata; document generation; tag known-good build | Jason/Advay |
| Integration happens too late | Medium | High | Shared integration checkpoints; hard full-simulation deadline 30 Sep; board target 2 Oct | All (Jason leads) |
| A subsystem owner misses an agreed milestone or delivers below agreed integration quality | Medium | High | Recovery window, latest working commit, then documented integration-lead takeover only if needed to unblock schedule | All / Jason coordinates |
| Work exists only locally | Medium | High | Frequent Git commits and contribution log | All |
| Report evidence forgotten | Medium | Medium | Save evidence at verification time | All |

---

# 11. Project Management Evidence

The rubric rewards a strong plan, milestones, risks, meeting evidence and version-control history.

Maintain:

```text
docs/project_management/meeting_minutes.md
docs/project_management/decision_log.md
docs/project_management/risk_register.md
docs/project_management/contribution_log.md
```

### Meeting template

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

### Contribution-log template

```text
Date | Member | Module/task | Commit/PR | Test evidence | Status
```

### Decision-log example

```text
2026-09-24
Decision: classifier → game uses a one-event valid pulse rather than a level-sensitive ID.
Reason: avoids repeated hits while one vowel remains detected.
Affected modules: classifier_interface, vowel_hit_mapper.
```

Every Sunday, compare progress against the Gantt table, record slipped work, update risks, and document any reallocation.

---

# 12. Report-Evidence Responsibilities

## Q1 — System Design
Jason leads:
- complete block diagram
- signal widths
- clock domains
- module functions
- handshake/CDC details

Luke and Advay must provide accurate subsystem interfaces.

## Q2 — DSP Theory + Hardware
Luke leads audio DSP:
- equations
- fixed-point formats
- scaling/truncation
- quantitative plots/results/trade-offs

Advay contributes image-processing DSP where relevant.

## Q3 — Testing & Verification
Each owner provides:
- self-checking tests
- edge/boundary cases
- quantitative metrics
- annotated waveform(s)

## Q4 — Hardware Mindset / Timing
Jason leads:
- Fmax per important clock
- critical paths
- slack
- mitigation/optimisation
- before/after timing where useful

Luke and Advay supply subsystem timing notes.

## Q5 — Project Management
Keep:
- this Gantt plan
- milestones
- risk register
- meeting minutes
- decision log
- Git history
- contribution log
- short reflection when the plan changes

---

# 13. Immediate Next Actions

## Jason
- [ ] Create repo/folder structure
- [ ] Import A1 `game_fsm`, `lane`, `score`
- [ ] Implement the individual Game/Control subsystem interface
- [ ] Start `vowel_hit_mapper.sv` + subsystem TB
- [ ] Draft shared top-level interfaces
- [ ] Create clock-domain/interface table
- [ ] Create integration branch

## Luke
- [ ] Import final Lesson 3 microphone files
- [ ] Re-run I2C/LJ simulation
- [ ] Import completed Lesson 4 FFT/FIFO modules
- [ ] Define provisional classifier interface
- [ ] Start audio-level gate TB

## Advay
- [ ] Import final Lesson 3 VGA workspace
- [ ] Re-run VGA simulation
- [ ] Define provisional boundary-output format
- [ ] Start key-mask generator
- [ ] Start overlay TB with random `ready` stalls

---

# Team Rule

> **Each member owns a technical module. Integration is shared. One person leads coordination, but no one is assigned everyone else's integration work by default.**

No member should wait until an entire subsystem is “finished” before committing or exposing its interface. Small tested increments should be merged regularly so system-level problems appear early.

If a subsystem blocks the agreed schedule, the team records the issue, gives the owner a defined recovery window, and only then uses the documented takeover process if necessary.

Our internal baseline deadline is **4 October 2026**, not the assignment submission deadline.
