// =============================================================================
// audio_gate_tb.sv  --  NEW, Luke Mouawad
// Self-checking unit test for audio_gate.sv (R-A1).
//
// Two DUTs see the same 48 kHz sample stream:
//   A : default parameters (the ones compiled for the board)
//   B : fast time constants + 10-sample hang-over, so the floor-rise and
//       hold/hysteresis paths change many times inside a short simulation
//
// Every sample, each DUT is compared against a bit-exact integer model
// (level, noise floor, voice_active), and level_db is checked against
// 20*log10(level) computed with real arithmetic (+/-1 dB, 0 below 1 LSB).
//
// Behavioural checks on DUT A (independent of the model):
//   silence        : gate never opens, floor clamps to FLOOR_MIN, 0 dB
//   room noise     : gate never opens, floor settles at the noise level
//   voiced signal  : opens within 20 ms, stays open for a 2 s held vowel
//   back to noise  : closes within hang-over + 30 ms and stays closed
//   doubled amp.   : dB reading rises by 6 +/- 1 dB
//   maximum level  : full-scale square wave reads 90 dB
//   reset          : clears gate, level and dB mid-vowel
// On DUT B: the floor rises under a sustained vowel and the gate closes.
// =============================================================================
`timescale 1ns/1ps

// ----------------------------------------------------------------------------
// DUT + bit-exact reference model
// ----------------------------------------------------------------------------
module gate_check #(
    parameter int    LEVEL_SHIFT      = 8,
    parameter int    FLOOR_FALL_SHIFT = 10,
    parameter int    FLOOR_RISE_SHIFT = 20,
    parameter int    MARGIN_ON_Q4     = 64,
    parameter int    MARGIN_OFF_Q4    = 45,
    parameter int    HOLD_SAMPLES     = 9600,
    parameter int    FLOOR_MIN        = 8,
    parameter string NAME             = "A"
) (
    input  logic               clk,
    input  logic               reset,
    input  logic signed [15:0] sample,
    input  logic               sample_valid,
    input  logic               check,          // all outputs settled
    output logic               voice_active,
    output logic [6:0]         level_db,
    output logic [23:0]        level,
    output logic [23:0]        noise_floor
);
    localparam int EF    = 8;
    localparam int FF    = (FLOOR_RISE_SHIFT > EF) ? FLOOR_RISE_SHIFT : EF;
    localparam int FL_SH = FF - EF;
    localparam int FL_W  = 16 + FF;

    audio_gate #(
        .LEVEL_SHIFT(LEVEL_SHIFT), .FLOOR_FALL_SHIFT(FLOOR_FALL_SHIFT),
        .FLOOR_RISE_SHIFT(FLOOR_RISE_SHIFT), .MARGIN_ON_Q4(MARGIN_ON_Q4),
        .MARGIN_OFF_Q4(MARGIN_OFF_Q4), .HOLD_SAMPLES(HOLD_SAMPLES),
        .FLOOR_MIN(FLOOR_MIN)
    ) dut (
        .clk, .reset, .sample, .sample_valid,
        .voice_active, .level_db, .level, .noise_floor);

    // model state
    longint m_level, m_floor, m_hold;
    bit     m_active;
    longint n_samples = 0;

    always @(posedge clk) begin
        if (reset) begin
            m_level  = 0;
            m_floor  = (64'd1 << FL_W) - 1;
            m_active = 0;
            m_hold   = 0;
        end else if (sample_valid) begin
            longint a, d, lext, fl, fl_l;
            bit     on, off;
            a    = (sample < 0) ? -longint'(sample) : longint'(sample);
            // gate decision uses the registers before this sample's update
            fl_l = m_floor >>> FL_SH;
            on   = (m_level * 16) >  (fl_l * MARGIN_ON_Q4);
            off  = (m_level * 16) >= (fl_l * MARGIN_OFF_Q4);
            if (!m_active) begin
                if (on) begin m_active = 1; m_hold = HOLD_SAMPLES; end
            end else if (off)        m_hold = HOLD_SAMPLES;
            else if (m_hold == 0)    m_active = 0;
            else                     m_hold = m_hold - 1;
            // floor tracker (uses the old level)
            lext = m_level <<< FL_SH;
            d    = lext - m_floor;
            if (lext < m_floor) fl = m_floor + (d >>> FLOOR_FALL_SHIFT);
            else                fl = m_floor + (d >>> FLOOR_RISE_SHIFT);
            if (fl < (longint'(FLOOR_MIN) <<< FF)) fl = longint'(FLOOR_MIN) <<< FF;
            m_floor = fl;
            // fast leaky average of |x|
            d       = (a <<< EF) - m_level;
            m_level = m_level + (d >>> LEVEL_SHIFT);
            n_samples++;
        end

        if (!reset && check) begin
            real    lsb, edb;
            longint e;
            if (longint'(level) != m_level)
                $fatal(1, "[%s] sample %0d: level %0d != model %0d", NAME, n_samples, level, m_level);
            if (longint'(noise_floor) != (m_floor >>> FL_SH))
                $fatal(1, "[%s] sample %0d: floor %0d != model %0d", NAME, n_samples, noise_floor, m_floor >>> FL_SH);
            if (voice_active !== m_active)
                $fatal(1, "[%s] sample %0d: voice_active %b != model %b", NAME, n_samples, voice_active, m_active);
            lsb = real'(m_level) / 256.0;
            if (lsb <= 1.0) e = 0;
            else begin
                edb = 20.0 * $log10(lsb);
                e   = longint'($floor(edb + 0.5));
                if (e > 99) e = 99;
            end
            if (longint'(level_db) > e + 1 || longint'(level_db) < e - 1)
                $fatal(1, "[%s] sample %0d: level_db %0d, 20log10(%f) -> %0d", NAME, n_samples, level_db, lsb, e);
        end
    end
endmodule

// ----------------------------------------------------------------------------
module audio_gate_tb;
    localparam int FS       = 48000;
    localparam int SLOT     = 8;              // clocks per sample (>= 6 for dB)
    localparam real PI      = 3.14159265358979;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic               reset = 1'b1;
    logic signed [15:0] sample = '0;
    logic               sample_valid = 1'b0;
    logic               check = 1'b0;

    logic        va_a, va_b;
    logic [6:0]  db_a, db_b;
    logic [23:0] lvl_a, lvl_b, fl_a, fl_b;

    gate_check #(.NAME("A_default")) u_a (
        .clk, .reset, .sample, .sample_valid, .check,
        .voice_active(va_a), .level_db(db_a), .level(lvl_a), .noise_floor(fl_a));

    gate_check #(.LEVEL_SHIFT(3), .FLOOR_FALL_SHIFT(3), .FLOOR_RISE_SHIFT(7),
                 .HOLD_SAMPLES(10), .FLOOR_MIN(2), .NAME("B_fast")) u_b (
        .clk, .reset, .sample, .sample_valid, .check,
        .voice_active(va_b), .level_db(db_b), .level(lvl_b), .noise_floor(fl_b));

    // ------------------------------------------------------------------ stimulus
    real    phase = 0.0;
    longint t_idx = 0;                  // global sample index

    typedef enum {SILENCE, NOISE, VOWEL, SQUARE} kind_t;

    function automatic logic signed [15:0] gen(kind_t k, real amp);
        real v;
        int  n;
        n = int'($urandom_range(80, 0)) - 40;            // room noise, mean |x| ~ 20
        case (k)
            SILENCE: v = 0.0;
            NOISE:   v = n;
            VOWEL:   v = amp * ($sin(phase) + 0.6 * $sin(2.0 * phase) + 0.4 * $sin(3.0 * phase)) + n;
            SQUARE:  v = ($sin(phase) >= 0.0) ? 32767.0 : -32768.0;
        endcase
        if (v >  32767.0) v =  32767.0;
        if (v < -32768.0) v = -32768.0;
        return 16'(int'(v));
    endfunction

    // plays n samples; per-sample hook counters exposed to the caller
    int first_active, last_active, n_active, n_inactive;
    task automatic play(input kind_t k, input real amp, input int n, input real f0 = 150.0);
        first_active = -1; last_active = -1; n_active = 0; n_inactive = 0;
        for (int i = 0; i < n; i++) begin
            sample       <= gen(k, amp);
            sample_valid <= 1'b1;
            phase = phase + 2.0 * PI * f0 / FS;
            if (phase > 2.0 * PI) phase = phase - 2.0 * PI;
            @(posedge clk);
            sample_valid <= 1'b0;
            repeat (SLOT - 2) @(posedge clk);
            check <= 1'b1;
            @(posedge clk);
            check <= 1'b0;
            if (va_a) begin
                n_active++;
                if (first_active < 0) first_active = i;
                last_active = i;
            end else n_inactive++;
            t_idx++;
        end
    endtask

    function automatic int ms(real t);
        return int'(t * FS / 1000.0);
    endfunction

    int db_1x, db_2x;
    logic [23:0] fl_b_early;

    initial begin
        repeat (4) @(posedge clk);
        reset <= 1'b0;
        @(posedge clk);

        // --- room noise straight after reset: floor falls from max, gate shut
        play(NOISE, 0, ms(400));
        if (n_active != 0) $fatal(1, "room noise opened the gate (%0d samples)", n_active);
        if (fl_a < 12*256 || fl_a > 30*256)
            $fatal(1, "floor did not settle on room noise: %0d LSB", fl_a / 256);
        $display("room noise : floor %0d LSB, level %0d dB, gate shut", fl_a / 256, db_a);

        // --- held vowel, 2 s: opens within 20 ms, never drops out (probe 2)
        play(VOWEL, 2000.0, ms(2000));
        if (first_active < 0 || first_active > ms(20))
            $fatal(1, "vowel did not open the gate within 20 ms (first=%0d)", first_active);
        if (n_active != ms(2000) - first_active)
            $fatal(1, "gate dropped out during a 2 s held vowel (%0d inactive)", n_inactive - first_active);
        if (db_a < 50) $fatal(1, "vowel level %0d dB unexpectedly low", db_a);
        $display("held vowel : open after %0d samples, stayed open 2 s, level %0d dB", first_active, db_a);

        // --- back to room noise: must close after the hang-over (not stick)
        play(NOISE, 0, ms(500));
        if (va_a) $fatal(1, "gate never cleared after the vowel stopped");
        if (last_active < 9600 || last_active > 9600 + ms(30))
            $fatal(1, "gate closed after %0d samples, expected hang-over 9600 + <30 ms", last_active);
        $display("vowel stops: gate closed %0d samples later", last_active + 1);

        // --- doubled amplitude: +6 dB
        play(VOWEL, 1500.0, ms(300));
        db_1x = db_a;
        play(VOWEL, 3000.0, ms(300));
        db_2x = db_a;
        if (db_2x - db_1x < 5 || db_2x - db_1x > 7)
            $fatal(1, "2x amplitude changed level by %0d dB, expected 6", db_2x - db_1x);
        $display("2x amplitude: %0d dB -> %0d dB", db_1x, db_2x);

        // --- maximum level: full-scale square wave
        play(SQUARE, 0, ms(100));
        if (db_a != 90) $fatal(1, "full scale reads %0d dB, expected 90", db_a);
        $display("full scale : %0d dB", db_a);

        // --- digital silence: closes, floor clamps to FLOOR_MIN, 0 dB
        play(SILENCE, 0, ms(600));
        if (va_a) $fatal(1, "gate open in digital silence");
        if (fl_a != 24'(8 * 256)) $fatal(1, "floor %0d not clamped to FLOOR_MIN", fl_a);
        if (db_a != 0) $fatal(1, "silence reads %0d dB", db_a);
        $display("silence    : gate shut, floor at FLOOR_MIN, 0 dB");

        // --- room noise after silence must not open the gate either
        play(NOISE, 0, ms(300));
        if (n_active != 0) $fatal(1, "room noise after silence opened the gate");

        // --- DUT B: floor rises under a sustained vowel and the gate closes
        play(VOWEL, 2000.0, ms(10));
        fl_b_early = fl_b;
        play(VOWEL, 2000.0, ms(200));
        if (fl_b <= fl_b_early) $fatal(1, "[B] floor did not rise under sustained input");
        if (va_b) $fatal(1, "[B] fast floor should have closed the gate on a steady tone");

        // --- reset in the middle of a vowel
        play(VOWEL, 2000.0, ms(100));
        if (!va_a) $fatal(1, "gate should be open before reset test");
        reset <= 1'b1;
        repeat (3) @(posedge clk);
        if (va_a || lvl_a != 0 || db_a != 0 || fl_a != 24'hFFFFFF)
            $fatal(1, "reset did not clear the gate (va=%b lvl=%0d db=%0d fl=%h)", va_a, lvl_a, db_a, fl_a);
        reset <= 1'b0;
        @(posedge clk);
        play(NOISE, 0, ms(200));
        if (n_active != 0) $fatal(1, "gate opened on noise after reset");

        $display("%0d samples checked against the model", t_idx);
        $display("ALL TESTS PASSED: audio_gate");
        $finish;
    end
endmodule
