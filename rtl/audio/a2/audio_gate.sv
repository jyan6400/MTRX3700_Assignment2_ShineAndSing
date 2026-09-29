// =============================================================================
// audio_gate.sv  --  NEW, Luke Mouawad, R-A1 (gate and level)
// -----------------------------------------------------------------------------
// Runs on the 48 kHz microphone samples straight from mic_load (before the
// low-pass / decimator), in the codec BCLK domain (3.072 MHz, 64 clocks per
// sample). Produces the level in dB for HEX1..HEX0 and the voice gate that
// enables the classifier and blanks HEX2.
//
//  1. Level  (fast leaky average of |x|, time constant 2^LEVEL_SHIFT samples)
//        level += ((|x| << ENV_FRAC) - level) >>> LEVEL_SHIFT
//     unsigned Q16.ENV_FRAC, in units of one 16-bit sample LSB.
//
//  2. Noise floor  (asymmetric tracker = running minimum of the level)
//        level <  floor : floor += (level - floor) >>> FLOOR_FALL_SHIFT  (fast)
//        level >= floor : floor += (level - floor) >>  FLOOR_RISE_SHIFT  (slow)
//        floor >= FLOOR_MIN                                   (digital silence)
//     unsigned Q16.FLOOR_RISE_SHIFT so the slow rise does not truncate to 0.
//     Reset value = maximum, so the gate stays shut while the floor settles
//     (~8 fall time constants, ~170 ms with the defaults).
//
//  3. Gate  (margin with hysteresis and a hang-over)
//        open  when level > floor * MARGIN_ON_Q4  / 16
//        stay  while level >= floor * MARGIN_OFF_Q4 / 16  (reloads hold counter)
//        close after HOLD_SAMPLES+1 consecutive samples below the off margin
//
//  4. Level in dB  (00..99 on HEX1..HEX0)
//        level_db = round( 20*log10(level) ) = round( 6.0206 * log2(level) )
//     log2 from log2_energy (Q5.8), 6.0206 * 2^-8 = 1541 * 2^-16.
//     Full scale (|x| = 32768) reads 90 dB, one LSB reads 0 dB. 1 dB steps.
//
// Defaults at 48 kHz: level tau 5.3 ms, floor fall tau 21 ms, floor rise tau
// 21.8 s (a vowel held for 2 s raises the floor by < 9 % of the gap),
// open +12.0 dB, close +9.0 dB, hang-over 200 ms.
//
// Clock/reset domain : codec BCLK, synchronous active-high reset.
// Outputs            : registered, valid from the sample after each sample_valid.
//                      voice_active / level_db are BCLK-domain signals; the
//                      consumer synchronises them (see audio_features.sv).
// =============================================================================
module audio_gate #(
    parameter int SAMPLE_W         = 16,
    parameter int ENV_FRAC         = 8,       // fractional bits of level
    parameter int LEVEL_SHIFT      = 8,       // level tau   = 2^8  samples
    parameter int FLOOR_FALL_SHIFT = 10,      // floor fall tau = 2^10 samples
    parameter int FLOOR_RISE_SHIFT = 20,      // floor rise tau = 2^20 samples
    parameter int MARGIN_ON_Q4     = 64,      // 4.00x = +12.0 dB  (gate margin)
    parameter int MARGIN_OFF_Q4    = 45,      // 2.81x =  +9.0 dB  (hysteresis)
    parameter int HOLD_SAMPLES     = 9600,    // 200 ms hang-over
    parameter int FLOOR_MIN        = 8,       // in sample LSBs
    // derived
    parameter int ENV_W            = SAMPLE_W + ENV_FRAC
) (
    input  logic                       clk,
    input  logic                       reset,
    input  logic signed [SAMPLE_W-1:0] sample,
    input  logic                       sample_valid,
    output logic                       voice_active,
    output logic [6:0]                 level_db,
    output logic [ENV_W-1:0]           level,        // debug, Q16.ENV_FRAC
    output logic [ENV_W-1:0]           noise_floor   // debug, Q16.ENV_FRAC
);
    localparam int FLOOR_FRAC = (FLOOR_RISE_SHIFT > ENV_FRAC) ? FLOOR_RISE_SHIFT : ENV_FRAC;
    localparam int FL_W       = SAMPLE_W + FLOOR_FRAC;
    localparam int FL_SH      = FLOOR_FRAC - ENV_FRAC;
    localparam int HOLD_W     = $clog2(HOLD_SAMPLES + 1) + 1;
    localparam int LOG_F      = 8;                         // log2 fraction bits
    localparam int LOG_W      = $clog2(ENV_W) + LOG_F;
    localparam int DB_MULT    = 1541;                      // 20log10(2) * 2^16 / 2^LOG_F
    localparam int CMP_W      = ENV_W + 8;

    // ---------------- 1. level -----------------------------------------------
    logic [SAMPLE_W-1:0]      abs_x;
    logic signed [ENV_W+1:0]  lvl_diff;
    always_comb begin
        abs_x    = sample[SAMPLE_W-1] ? SAMPLE_W'(-sample) : SAMPLE_W'(sample); // |-32768| = 32768
        lvl_diff = $signed({2'b00, abs_x, {ENV_FRAC{1'b0}}}) - $signed({2'b00, level});
    end

    // ---------------- 2. noise floor ----------------------------------------
    logic [FL_W-1:0]          floor_q;           // Q16.FLOOR_FRAC
    logic [FL_W-1:0]          lvl_ext, floor_nx;
    logic signed [FL_W+1:0]   fl_diff;
    always_comb begin
        lvl_ext = FL_W'(level) << FL_SH;
        fl_diff = $signed({2'b00, lvl_ext}) - $signed({2'b00, floor_q});
        if (lvl_ext < floor_q) floor_nx = FL_W'($signed({2'b00, floor_q}) + (fl_diff >>> FLOOR_FALL_SHIFT));
        else                   floor_nx = FL_W'($signed({2'b00, floor_q}) + (fl_diff >>> FLOOR_RISE_SHIFT));
        if (floor_nx < (FL_W'(FLOOR_MIN) << FLOOR_FRAC)) floor_nx = FL_W'(FLOOR_MIN) << FLOOR_FRAC;
    end
    assign noise_floor = ENV_W'(floor_q >> FL_SH);

    // ---------------- 3. gate comparisons (same Q16.ENV_FRAC units) ---------
    logic above_on, above_off;
    always_comb begin
        above_on  = (CMP_W'(level) * CMP_W'(16)) >  (CMP_W'(noise_floor) * CMP_W'(MARGIN_ON_Q4));
        above_off = (CMP_W'(level) * CMP_W'(16)) >= (CMP_W'(noise_floor) * CMP_W'(MARGIN_OFF_Q4));
    end

    logic [HOLD_W-1:0] hold_cnt;
    logic              upd_d;                    // level updated last cycle

    always_ff @(posedge clk) begin
        if (reset) begin
            level        <= '0;
            floor_q      <= '1;
            voice_active <= 1'b0;
            hold_cnt     <= '0;
            upd_d        <= 1'b0;
        end else begin
            upd_d <= sample_valid;
            if (sample_valid) begin
                level   <= ENV_W'($signed({2'b00, level}) + (lvl_diff >>> LEVEL_SHIFT));
                floor_q <= floor_nx;
                if (!voice_active) begin
                    if (above_on) begin
                        voice_active <= 1'b1;
                        hold_cnt     <= HOLD_W'(HOLD_SAMPLES);
                    end
                end else if (above_off) begin
                    hold_cnt <= HOLD_W'(HOLD_SAMPLES);
                end else if (hold_cnt == '0) begin
                    voice_active <= 1'b0;
                end else begin
                    hold_cnt <= hold_cnt - 1'b1;
                end
            end
        end
    end

    // ---------------- 4. level in dB ----------------------------------------
    logic [LOG_W-1:0] lvl_log2;                  // log2(level register), Q.LOG_F
    logic             lvl_log2_valid;
    /* verilator lint_off UNUSEDSIGNAL */
    logic             lvl_log2_zero;         // level 0 already gives y = 0 -> 0 dB
    /* verilator lint_on UNUSEDSIGNAL */

    log2_energy #(.IN_W(ENV_W), .FRAC_W(LOG_F)) u_log2 (
        .clk, .reset,
        .x(level), .in_valid(upd_d),
        .y(lvl_log2), .out_valid(lvl_log2_valid), .zero(lvl_log2_zero));

    logic signed [LOG_W+1:0] t_log;              // log2(level in LSBs), Q.LOG_F
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
