# Video / image processing + VGA rendering (Advay)

Everything under `rtl/video/`, `sim/video/` and `tools/video/`, plus `memory/piano*.{mif,hex,png,txt}`,
`sim/models/vga_monitor_model.sv`, `quartus/vga_sink.qsys` (+ its script) and `quartus/video_subsystem_files.qsf`.

```
sh sim/video/run_video_tests.sh            # all 10 video benches, Verilator 5.050, ~3 min
sh sim/video/run_video_tests.sh game_video_overlay video_subsystem    # just some
python3 tools/video/hw_model.py            # the integer model: what every mode finds on every picture
python3 tools/video/make_piano_images.py   # regenerate memory/piano0..2 from memory/originals (the supplied pictures)
```
Each bench stops with `$fatal` on its first mismatch and prints `ALL TESTS PASSED: <name>`. The subsystem
bench writes PNGs of every view to `docs/report_evidence/waveforms/video/`.

---

## 1. What it does

```
 SW4..3 ──► 3 x image_rom (piano0/1/2, dual-clock M10K)
                │ port A, 50 MHz                                              port B, 25 MHz │
                ▼                                                                            ▼
 raster_source ─► [conv3x3 smoothing, R-V4] ─► 1-D difference (SW5=0) | sobel (SW5=1) ─► col_profile (rows 150..176)
   ─► profile_normalise (÷ max) ─► local_threshold (k × 25-column mean)
   ─► picker by SW7..6:  R-V4/R-V3 hysteresis_profile │ R-V1/R-V2 peak_pick
   ─► key_mask_generator (median spacing, lattice fit, 4 lanes = the four middle keys)
   ─► result bundle ══ cdc_latch (req/ack, applied while the source waits at pixel 0,0) ══►
                                                                    game_video_overlay ─► Avalon-ST ─► vga_sink
   edge map (4 bit/pixel) and profile view ══ dual-clock RAMs ══►          ▲
                                                 game state (25 MHz, from Jason's game_video_cdc)
```

### The files (`rtl/video/`)

| Folder | Files |
|---|---|
| `lesson3_reuse/` | `vga_face.sv` (the Avalon-ST source pattern the overlay is built on; kept for reference, not compiled), `video_pll.sv` |
| `barcode_reuse/` | `conv3x3.sv`, `col_profile.sv`, `peak_pick.sv` (Advay's lesson solutions); `sobel.sv`, `raster_source.sv`, `cdc_latch.sv`, `image_rom.sv` (Mini-Project 2 workspace) — all unchanged |
| `a2/` | the five planned modules — `profile_normalise.sv`, `hysteresis_profile.sv`, `local_threshold.sv`, `key_mask_generator.sv`, `game_video_overlay.sv` — and `video_subsystem.sv`, the integrated video path |

`video_subsystem.sv` is the only extra file in `a2/`. It instantiates the reused modules and the five new
ones and holds the glue that has no module of its own: the 1-D difference (one register and a subtractor),
the rung selection, the sequencer, the board thresholds (KEY3..1, SW0), the two debug memories and the
crossing into the pixel clock. The digit font for the score is inside `game_video_overlay.sv`.

### The pictures (`memory/`)

| SW4..3 | File | What it is |
|---|---|---|
| 0 | `piano0` | **supplied picture 1** (`memory/originals/supplied_piano_1.png`), 300×240 inside the 320×240 frame |
| 1 | `piano1` | **supplied picture 2** (`memory/originals/supplied_piano_2.png`), 320×160, letterboxed top and bottom |
| 2, 3 | `piano2` | photo-like test picture: picture 1 with the notebook's `photo_like()` — lighting gradient (left side at 20 %), noise, a shadow across one key. **Replace with the tutor's photograph** for the demo. |

The assignment page gives the two pictures only as images (no `.mif`); as the tutor said on Ed, they are saved
and converted with the barcode mini-project's converter — here `tools/video/image_conversion_script.py`
(greyscale, fit inside 320×240, grey letterbox). `make_piano_images.py` runs that conversion on
`memory/originals/`. Each `.txt` holds the true key boundaries, measured on the converted picture
independently of the key finder (the darkest column of each gap between white keys, plus the keyboard's two
outer edges).

### Results at the default settings (all switches down, KEY3 defaults)

| Rung | Mode (SW7..6) | Picker | piano0 (supplied 1) | piano1 (supplied 2) | piano2 (photo-like) |
|---|---|---|---|---|---|
| R-V1 | 2 (or 3), SW5 = 0 | 1-D difference + `peak_pick`, threshold 2048 | 11/11 | 8/8 | 7/11 — the dim left half is lost |
| R-V2 | 2 (or 3), SW5 = 1 | Sobel + `peak_pick`, threshold 2048 × 4 | 11/11 | 8/8 | 7/11 |
| R-V3 | 1 | normalise + NMS + hysteresis 0.45/0.25 | 11/11 | 8/8 | 8/11 (Sobel), 7/11 (1-D) |
| R-V4 | **0 (default)** | smoothing + hysteresis on k × local mean (floor 0.10) + lattice | 11/11 | 8/8 | **11/11**; the two shadow edges (x ≈ 77, 85) are found and dropped by the lattice |

R-V3 and R-V4 give the same with either edge detector (SW5). From `video_subsystem_tb`: found = within 3 px of a
true boundary, 0 spurious kept. Every rung reads both supplied pictures; the photo-like picture is the one
that needs R-V4, and the benches check that the lower rungs do fail on it. The rung ladder is visible on the
board with the switches.

## 2. For Jason: instantiating it

```systemverilog
video_subsystem u_video (                                                         // LANE_FIRST = 15: middle keys
    .clk_50(CLOCK_50), .reset_50(reset50), .clk_25(clk_25), .reset_25(reset25),   // KEY0, synchronised per domain
    .sw_view(SW[2:1]), .sw_image(SW[4:3]), .sw_edge(SW[5]), .sw_mode(SW[7:6]), .sw_adjust(SW[0]), .key_n(KEY[3:1]),
    .lane_active, .lane_count, .lane_hit_window, .lane_hit_pulse, .score,          // from game_video_cdc (25 MHz)
    .st_data, .st_startofpacket(st_sop), .st_endofpacket(st_eop), .st_valid, .st_ready,
    .boundary_valid(), .boundary_count(), .boundary_x(), .lanes_valid());           // debug only
vga_sink u_vga (.clk_clk(clk_25), .reset_reset_n(~reset25),
    .video_in_data(st_data), .video_in_startofpacket(st_sop), .video_in_endofpacket(st_eop),
    .video_in_valid(st_valid), .video_in_ready(st_ready),
    .vga_CLK(VGA_CLK), .vga_HS(VGA_HS), .vga_VS(VGA_VS), .vga_BLANK(VGA_BLANK_N), .vga_SYNC(VGA_SYNC_N),
    .vga_R(VGA_R), .vga_G(VGA_G), .vga_B(VGA_B));
video_pll video_pll_u (.refclk(CLOCK_50), .rst(1'b0), .outclk_0(clk_25), .locked(pll_locked));
```
* Resets: `reset50`/`reset25` = KEY0 through two flops in each domain (as the barcode `top_level.sv`), with
  `~pll_locked` OR-ed into the 25 MHz one.
* `lane_count` is the contract's `logic [GAME_COUNT_W-1:0] lane_count [0:3]`; a lower count = closer to the
  hit window = brighter key. **Tell me if your countdown runs the other way.**
* The game view reads only the frozen Game → Video signals; nothing about the FSM.
* Quartus lines (files, qsys, MIFs, SDC notes): now in Jason's `quartus/assignment2.qsf`.
* The pictures: `video_subsystem`'s `MIF0..2` default to `"../memory/pianoN.mif"` (Quartus looks from the
  project folder `quartus/`; a `.mif` it cannot find is only a Critical Warning and gives a black picture)
  and `HEX0..2` to `"memory/pianoN.hex"` (the benches run from the repository root).
* Sizes come from `rtl/common/assignment2_pkg.sv`: `video_subsystem`'s parameters are named and defaulted
  from it (`IMG_W`, `IMG_H`, `VGA_W`, `VGA_H`, `GAME_COUNT_W`; the `score` port is `SCORE_W` bits), so
  top_level needs no parameter overrides. The package must be compiled before the video files (first in
  the `.qsf`; `run_video_tests.sh` puts it first on every Verilator command line). The new `a2/` modules
  default to `IMG_W`/`IMG_H` too; the reused modules keep their own `W`/`H` names (unchanged, per the
  reuse rule) and are given the package values by the blocks that instantiate them.
* Contract D (debug outputs, 50 MHz): `boundary_valid`, `boundary_count[$clog2(NMAX+1)-1:0]`,
  `boundary_x[NMAX-1:0][8:0]` (packed; `boundary_x[i]` = source-image x of boundary i), as the plan recommends.
* Clock crossings inside the video subsystem: switches → the shared `rtl/common/synchroniser.v` (one per
  bit, in the clock domain that uses the switch); KEY3..1 → `synchroniser.v` then debounced; results →
  `cdc_latch`; edge map / profile view → dual-clock RAMs. The SDC needs only
  `set_clock_groups -asynchronous` between CLOCK_50 and the video PLL clock.
* The threshold keys (KEY3..1, SW0) are handled inside `video_subsystem`, because R-V3 puts "thresholds
  controllable from free board inputs" in the video scope. If top_level should own the keys instead, the
  five values (`hi`, `lo`, `floor_lvl`, `k_q`, `thr_abs`) can become inputs: say so and I will change it.

## 3. Board

| Control | Function |
|---|---|
| SW2..SW1 | view: 0 game, 1 edge map, 2 profile + threshold lines, 3 key masks |
| SW4..SW3 | picture: 0 supplied picture 1, 1 supplied picture 2, 2 (and 3) photo-like / tutor's photograph |
| SW5 | 0 = 1-D difference, 1 = Sobel |
| SW7..SW6 | 0 = R-V4 (default), 1 = R-V3, 2 or 3 = R-V1/R-V2 (with SW5 = 0 that is R-V1, with SW5 = 1 R-V2) |
| KEY1 / KEY2 | raise / lower the value SW0 selects: R-V3 hi (SW0=0) / lo (SW0=1), step 8/256; R-V4 k (SW0=0, steps of 0.2) / floor (SW0=1, steps of 4/256); R-V1/R-V2 the absolute threshold (step 256) |
| KEY3 | restore every default |
| VGA, game view | the four keys, each coloured over its whole real shape (round the black keys, from the top of the key to its bottom) from the game state (amber note brightening as lane_count falls, red hit window, green flash on a hit, faint blue idle), vowel id on each lane, score top-left (5 digits), red square top-right if no lanes were found |
| VGA, debug views | top-left: mode, edge detector, number of boundaries. Profile view: yellow = normalised profile, red = high threshold (the local-average curve at R-V4), orange = low threshold, green lines = kept boundaries, magenta = dropped by the lattice |

## 4. Design decisions (for the report)

* **Rows 150..176** (`Y0`, `Y1`): below the black keys, where each white-key gap is a clean pair of edges, in
  *both* supplied pictures — picture 1's black keys end at row 147 and its white keys at 217; picture 2
  (letterboxed) has black keys to row 137 and white keys only to row 179, with the dark frame below. One
  row of margin each side for the 3×3 windows.
* **The colour fills the real key, not a box** (`game_video_overlay`, `KEY_SHAPE = 1`). The key finder gives
  each lane's left and right boundary; the rest of the outline is read from the displayed picture: the key's
  white level is the mean of 8 pixels down its centre column in the analysed rows; a pixel is "key white" if
  it is at least 5/8 of that (black keys, gaps and the frame are far darker; 3/4 was tried in the Python
  prototype and broke on the photo-like picture's gradient and noise, 5/8 held on all three); the key's top
  and bottom are the ends of the unbroken key-white run down the centre column through the analysed rows; the
  key is every key-white pixel between its two boundaries and between top and bottom. Measured one frame,
  used the next (the picture is static): the first two frames after the lanes change, or a lane where no run
  is found, show the plain band of rows 150..176 as before. Nothing about the keys is typed in. Cost: a few
  registers and comparators per lane, no memory.
* **Normalise by the maximum** (R-V3): every threshold becomes a fraction, independent of picture brightness and
  of the detector (Sobel's 1-2-1 weights give 4× the 1-D difference). 0.45 / 0.25 (115 / 64 of 256) read both
  supplied pictures. Picture 1's boundaries range from 0.48 to 1.0 of the strongest, so the earlier 0.70 / 0.35
  missed four of them.
* **Absolute threshold in 1-D units, ×4 for Sobel** (R-V1/R-V2): 2048 / 8192, so one setting serves both
  detectors. Chosen with `hw_model.py`: the weakest true gap in the 27 summed rows is ~2400 (1-D), so 2048
  reads both supplied pictures (2560 already misses one).
* **Local average** (R-V4): t = k × mean over 25 columns, k = 2.5 (the notebook's). hi(x) = max(t, floor),
  lo(x) = max(¾t, floor), floor = 0.10 of the maximum. The floor stops flat, dim stretches from producing peaks.
* **Lattice fit** (`key_mask_generator`): the white keys are equally spaced; the lower median gap is the key
  width and boundaries off the lattice (±¼ key) are dropped — the photo's shadow edges (x ≈ 77, 85) are the
  extra boundaries R-V4 finds, and they are explained and removed here. Lanes are counted on the kept list, so
  an extra boundary cannot shift the game onto different keys. On the real pictures the lattice also drops the
  keyboard's last edge when the end key is cut off by the photo (picture 1, x = 309) or wider than the rest
  (picture 2, x = 299): that key is then just not a lane candidate. (The notebook's `template_fit`, unchanged.)
* **Lanes = the four middle white keys found** (`LANE_FIRST = 15`, the default; first key = (kept − 5) / 2).
  The two supplied pictures have 9 and 6 whole keys on the lattice, so no fixed key number suits both;
  centring does, and suits an unknown photograph too. Lanes: piano0 x = 68–197, piano1 61–209, piano2 68–197.
  `LANE_FIRST = 0..14` still fixes lane 0 to that key. **State this in the report.**
* **Latency is carried, not corrected**: every convolution stage outputs its window's centre coordinates with
  the value, so the profile is indexed by true picture column whatever the delay (conv3x3 bench checks the
  3-clock latency and the coordinates). With smoothing on, the Sobel window's border centres are masked.
* **The frame tag (Lesson 2.3c lab question) matters here**: `col_profile`'s 1-bit tag means a column written
  two sweeps ago reads as current. Switching SW5 (1-D writes x = W-1, Sobel does not) produced a stale
  column in simulation; `video_subsystem` forces columns outside the current detector's valid range to 0.
* **Avalon-ST hold under stalls (fix to display.sv)**: memories are addressed with the pixel presented *next*
  clock (the next on a handshake, the same otherwise), so the offered data never changes while
  valid && !ready. `display.sv`'s unconditional one-ahead read changes the data on a stall at an odd x
  (demonstrated: the overlay bench fails with that version, 20 % random stalls).
* **No frame shows a mix of states**: results and game state are copied into frame registers when the last
  pixel of a frame is accepted; the overlay bench changes the game state mid-frame to check this. The
  picture select (SW4..3) is applied between frames too, and the debug memories are read once per pixel and
  held, so nothing a switch or the 50 MHz side does can change a pixel while the controller is stalling.

## 5. Reuse register (video)

| File | From | Change for A2 |
|---|---|---|
| `barcode_reuse/conv3x3.sv` | Lesson 2.3b (Advay) | none (used three times: Sobel Gx, Gy, and the smoothing table) |
| `barcode_reuse/col_profile.sv` | Lesson 2.3c (Advay) | none (parameters: rows, X_LAST) |
| `barcode_reuse/peak_pick.sv` | Lesson 3.2d (Advay) | none (the R-V1/R-V2 picker) |
| `barcode_reuse/sobel.sv`, `raster_source.sv`, `cdc_latch.sv`, `image_rom.sv` | Mini-Project 2 workspace | none |
| `lesson3_reuse/video_pll.sv` | Lesson 3 | none (instantiated in top_level) |
| `lesson3_reuse/vga_face.sv` | Lesson 3 (Advay) | none; reference only (not compiled): its Avalon-ST source pattern is what the overlay is built on |
| `a2/game_video_overlay.sv` | MP2 `display.sv` (itself `vga_face.sv` with a picture ROM) | adapted: views, lanes, score, frame registers, stall-safe addressing |
| `a2/video_subsystem.sv` | MP2 `barcode_reader.sv` + its top-level wiring | adapted: bar decoder removed, 1-D detector, R-V3/R-V4 stages, rung selection, board thresholds |
| `rtl/common/synchroniser.v` | shared (Jason) | none |
| `sim/models/vga_monitor_model.sv` | Lesson 3 | none |
| MP2 benches `tb_conv3x3`, `tb_col_profile`, `tb_peak_pick` | Mini-Project 2 | converted to `$fatal` + `ALL TESTS PASSED`, extended with reference checks |
| `bar_decode.sv` | Mini-Project 2 | **not used** in A2 |
| `hex_seg.sv` | Mini-Project 2 | **not used**: section 1.3 gives every HEX display to audio |

Two notes for the report:

* **The picture memory.** `vga_face.sv` has its image memories inside it, but they are three 3-bit 640×480
  faces read on one clock. The piano pictures are 8-bit 320×240 and each is read by two clocks at once (the
  50 MHz sweep and the 25 MHz display), which is what Mini-Project 2's `image_rom.sv` is: so it is reused,
  unchanged, and lives in `barcode_reuse/` with the other Mini-Project 2 files.
* **The 1-D edge detector.** The plan expected to reuse one from the barcode mini-project. There is none: the
  Mini-Project 2 barcode reader is Sobel-only (`raster_source → sobel → col_profile → peak_pick →
  bar_decode`). The 1-D difference is one register and a subtractor, so it is written inside
  `video_subsystem.sv` rather than as a module.

New: `profile_normalise`, `hysteresis_profile`, `local_threshold`, `key_mask_generator`, `game_video_overlay`,
`video_subsystem`; `tools/video/hw_model.py` (bit-exact model), `make_piano_images.py`,
`image_conversion_script.py` (MP2 `image_to_mif.py` with its `.mif`/`.hex`/`.png` writers in the same file).

## 6. Tests (sim/video)

| Bench | What it proves |
|---|---|
| `conv3x3_tb` | Sobel and smoothing tables vs the bench's own 3×3 sums on every interior centre; latency exactly 3 clocks; coordinates carried |
| `col_profile_tb` | rows Y0..Y1 only, frame tag restart, one `done` per frame; the piano window at full width |
| `peak_pick_tb` | MP2 cases + 200 random profiles vs a reference picker |
| `cdc_latch_tb` | two asynchronous clocks: bundles cross whole, in order, only in the update window; destination reset |
| `profile_normalise_tb` | flat zero / flat constant / one edge / 20-bit maximum / 100 random; threshold conversion and saturation |
| `local_threshold_tb` | window ends, spike, step (shadow), saturation, k = 0, 50 random |
| `hysteresis_profile_tb` | strong / weak-beside-strong / lone weak / false peaks below lo / plateau; adaptive shadowed half; overflow; 300 random |
| `key_mask_generator_tb` | lattice, shadow edge, missed boundary, too few keys, fixed `lane_first`, middle keys on both supplied pictures' lists; 300 random lists |
| `game_video_overlay_tb` | 24 frames into the VGA monitor model with 20 % stalls: 0 protocol errors; lane colours from the latched game state; **the key shape** — the mock picture is a small keyboard and the bench's own outline of each key is compared at 12 pixels per lane (on the key beside a black key, on the black key, below the analysed rows, on the gap, in the frame, on bright patches above and touching the key, on a mid-grey smudge), with the plain band expected for the first two frames after the lanes change; the digit font — every pixel of the score with all ten digits, the vowel id on each lane, the debug readout; no-keys marker; every debug view; game state and view changed mid-frame; hit flash; reset mid-frame |
| `video_subsystem_tb` | the integrated path as top_level uses it, two asynchronous clocks, mock game. **Key finder, exact:** every rung × both detectors × three pictures against a reference the bench computes from the pixels (boundaries, kept flags, spacing, lanes, every profile-view column, every edge-map pixel swept, no detector output outside the valid picture) — this covers the 1-D detector, the rung selection and the latency/coordinates. **Against the truth:** every rung reads both supplied pictures, only R-V4 the photo-like one. **Display:** the CDC copy, four views per picture checked and saved as PNG; in the game and mask views the colour must run up the key between the black keys (row 100), miss the black key beside it, and stay off the frame above and below. **Thresholds:** bounced and held presses = one step, SW0/mode selection, clamps, KEY3, and results with moved thresholds exact. **Play and reset:** hits drawn, reset of both domains mid-frame; 0 protocol problems |

The checks of the modules that were folded in (1-D detector, digit font, threshold keys, key finder) moved
into the last two benches; five deliberate faults in `video_subsystem.sv` (no left-neighbour check, no
smoothed-border mask, no stale-column mask, Sobel threshold not ×4, no debounce edge) each make
`video_subsystem_tb` fail.

## 7. Still to do / check on the Quartus VM

* **The tutor's photograph** at the demo: `python3 tools/video/image_conversion_script.py photo.jpg memory/piano2`,
  recompile. If its keys sit elsewhere in the frame, `Y0`/`Y1` (parameters of `video_subsystem`, which also
  sets the rows the lanes are drawn over) may need to move; check first with `hw_model.py` (copy the photo's
  `.txt` with rough boundaries).
* **Not run here (no Quartus in this environment):** synthesis, the Timing Analyzer, and the M10K check. Expect
  about 280 of the 397 M10K blocks: 3 pictures × 75, the 4-bit edge map 38, line buffers and profile RAMs ~15.
  If audio needs more, the edge map can drop to 2 bits (−19 blocks): a small change to the edge-map width in
  `video_subsystem.sv` / `game_video_overlay.sv`. Check in the fitter
  report that the line buffers, profile RAMs and edge map became M10K, not registers (plan's risk register).
