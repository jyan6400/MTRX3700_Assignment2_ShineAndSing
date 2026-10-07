`timescale 1ns/1ps
// =============================================================================
// audio_gate.sv  --  NEW, Luke Mouawad, R-A1 (gate and level)
// -----------------------------------------------------------------------------
// The course "Gate and Level in dB" recipe (tools/audio/audio_model.py gate()),
// in fixed point. Runs on the 48 kHz samples straight from mic_load (before the
// low-pass / decimator), in the codec BCLK domain (3.072 MHz, 64 clocks/sample).
//
// Once per sample, from the registers as they stand:
//   gate   voice_active <= level > K * floor            K = MARGIN_Q4/16 = 4 (12 dB)
//   floor  level <  floor        : floor += (level - floor) >>> FLOOR_FALL_SHIFT       (2^-11, 43 ms)
//          gate open             : floor += (level - floor) >>  FLOOR_RISE_OPEN_SHIFT  (2^-21, 44 s)
//          otherwise (room)      : floor += (level - floor) >>  FLOOR_RISE_SHIFT       (2^-15, 0.7 s)
//          floor >= FLOOR_MIN (only matters in digital silence)
//   level  level += ((|x| << 16) - level) >>> LEVEL_SHIFT                                (2^-8, 5.3 ms)
//
// The floor is a MINIMUM tracker: the quiet moments between words pull it down
// to the room; a held vowel lifts it only at 2^-21, so the gate stays open for
// ~10 s of continuous vowel (2^-19 would close it after ~2.5 s; probe 2 holds
// 2 s and a tutor may hold 4). Reset value 1/8 of full scale: the gate stays
// closed until the room has been heard (~230 ms).
//
// level_db (HEX1..0) = round(20*log10(level / 1 LSB)) = round(6.0206 * log2(level)),
//   log2 from log2_energy (LUT + interpolation, < 0.5 dB error before rounding),
//   1 dB steps, 0..99 (full scale 90). Updated every 2^DB_HOLD_SH samples
//   (0.17 s) so the display can be read.
//
// Formats: level, noise_floor unsigned Q16.16 (32 bits, units of one sample LSB).
// Clock/reset domain : codec BCLK, synchronous active-high reset.
// Outputs            : registered. voice_active / level_db are BCLK-domain
//                      signals: audio_features.sv synchronises voice_active into
//                      the FFT domain; the top level crosses level_db to 50 MHz.
//                      level[31:24] is the LEDR envelope bar source.
// =============================================================================

// =============================================================================
// LIVE CHANGE -- VOICE GATE SENSITIVITY
// =============================================================================
// The main live-change knob is MARGIN_Q4 in the parameter list below.
//
// Gate condition implemented in this module:
//     level * 16 > noise_floor * MARGIN_Q4
//
// MARGIN_Q4 is therefore a Q4 ratio:
//     32  = 2.0 x noise floor
//     64  = 4.0 x noise floor (current default)
//     128 = 8.0 x noise floor
//
// Increase MARGIN_Q4:
//   + stricter rejection of background noise
//   - quieter/distant speech is less likely to open the gate
//
// Decrease MARGIN_Q4:
//   + easier activation for quiet/distant speech
//   - greater chance of noise opening the gate
//
// LEVEL_SHIFT and the FLOOR_*_SHIFT parameters control time constants rather
// than the threshold ratio. Smaller shifts respond faster; larger shifts
// respond more slowly.
// =============================================================================
module audio_gate #(
    parameter int SAMPLE_W              = 16,
    parameter int ENV_FRAC              = 16,     // fraction bits of level and floor
    parameter int LEVEL_SHIFT           = 8,      // level tau        2^8  samples
    parameter int FLOOR_FALL_SHIFT      = 11,     // floor fall tau   2^11 samples
    parameter int FLOOR_RISE_SHIFT      = 15,     // floor rise tau   2^15 samples (gate closed)
    parameter int FLOOR_RISE_OPEN_SHIFT = 21,     // floor rise tau   2^21 samples (gate open)
    parameter int MARGIN_Q4             = 64,     // gate margin K = 64/16 = 4.0 (12 dB)
    parameter int FLOOR_INIT            = 4096,   // reset floor, sample LSBs (1/8 full scale)
    parameter int FLOOR_MIN             = 8,      // floor never below this, sample LSBs
    parameter int DB_HOLD_SH            = 13,     // level_db updated every 2^13 samples
    // derived
    parameter int ENV_W                 = SAMPLE_W + ENV_FRAC
) (
    input  logic                       clk,
    input  logic                       reset,
    input  logic signed [SAMPLE_W-1:0] sample,
    input  logic                       sample_valid,
    output logic                       voice_active,
    output logic [6:0]                 level_db,
    output logic [ENV_W-1:0]           level,        // Q16.16, debug + LEDR bar
    output logic [ENV_W-1:0]           noise_floor   // Q16.16, debug
);
    localparam int LOG_F   = 8;                         // log2 fraction bits
    localparam int LOG_W   = $clog2(ENV_W) + LOG_F;
    localparam int DB_MULT = 1541;                      // 20log10(2) * 2^16 / 2^LOG_F
    localparam int CMP_W   = ENV_W + 8;

    // ---------------- registers-as-they-stand comparisons -------------------
    logic gate_open;
    assign gate_open = (CMP_W'(level) * CMP_W'(16)) > (CMP_W'(noise_floor) * CMP_W'(MARGIN_Q4));

    // ---------------- next level --------------------------------------------
    logic [SAMPLE_W-1:0]     abs_x;
    logic signed [ENV_W+1:0] lvl_diff;
    logic [ENV_W-1:0]        level_nx;
    always_comb begin
        abs_x    = sample[SAMPLE_W-1] ? SAMPLE_W'(-sample) : SAMPLE_W'(sample);   // |-32768| = 32768
        lvl_diff = $signed({2'b00, abs_x, {ENV_FRAC{1'b0}}}) - $signed({2'b00, level});
        level_nx = ENV_W'($signed({2'b00, level}) + (lvl_diff >>> LEVEL_SHIFT));
    end

    // ---------------- next floor (uses the old level) -----------------------
    logic signed [ENV_W+1:0] fl_diff;
    logic [ENV_W-1:0]        floor_nx;
    always_comb begin
        fl_diff = $signed({2'b00, level}) - $signed({2'b00, noise_floor});
        if (level < noise_floor) floor_nx = ENV_W'($signed({2'b00, noise_floor}) + (fl_diff >>> FLOOR_FALL_SHIFT));
        else if (gate_open)      floor_nx = ENV_W'($signed({2'b00, noise_floor}) + (fl_diff >>> FLOOR_RISE_OPEN_SHIFT));
        else                     floor_nx = ENV_W'($signed({2'b00, noise_floor}) + (fl_diff >>> FLOOR_RISE_SHIFT));
        if (floor_nx < (ENV_W'(FLOOR_MIN) << ENV_FRAC)) floor_nx = ENV_W'(FLOOR_MIN) << ENV_FRAC;
    end

    // ---------------- state -------------------------------------------------
    logic [DB_HOLD_SH-1:0] db_cnt;
    logic                  db_sample;              // log2 the new level next clock

    always_ff @(posedge clk) begin
        if (reset) begin
            level        <= '0;
            noise_floor  <= ENV_W'(FLOOR_INIT) << ENV_FRAC;
            voice_active <= 1'b0;
            db_cnt       <= '0;
            db_sample    <= 1'b0;
        end else begin
            db_sample <= 1'b0;
            if (sample_valid) begin
                voice_active <= gate_open;
                noise_floor  <= floor_nx;
                level        <= level_nx;
                db_cnt       <= db_cnt + 1'b1;
                db_sample    <= (db_cnt == '0);
            end
        end
    end

    // ---------------- level in dB -------------------------------------------
    logic [LOG_W-1:0] lvl_log2;                    // log2(level register), Q.LOG_F
    logic             lvl_log2_valid;
    /* verilator lint_off UNUSEDSIGNAL */
    logic             lvl_log2_zero;               // level 0 already gives y = 0 -> 0 dB
    /* verilator lint_on UNUSEDSIGNAL */

    log2_energy #(.IN_W(ENV_W), .FRAC_W(LOG_F)) u_log2 (
        .clk, .reset,
        .x(level), .in_valid(db_sample),
        .y(lvl_log2), .out_valid(lvl_log2_valid), .zero(lvl_log2_zero));

    logic signed [LOG_W+1:0] t_log;                // log2(level in LSBs), Q.LOG_F
    logic [LOG_W+12:0]       db_full;
    always_comb begin
        t_log   = $signed({2'b00, lvl_log2}) - $signed((LOG_W+2)'(ENV_FRAC << LOG_F));
        db_full = ((LOG_W+13)'(t_log) * (LOG_W+13)'(DB_MULT) + (LOG_W+13)'(1 << 15)) >> 16;
    end

    always_ff @(posedge clk) begin
        if (reset)               level_db <= '0;
        else if (lvl_log2_valid) begin
            if (t_log <= 0)            level_db <= 7'd0;
            else if (db_full > 99)     level_db <= 7'd99;
            else                       level_db <= 7'(db_full);
        end
    end
endmodule
