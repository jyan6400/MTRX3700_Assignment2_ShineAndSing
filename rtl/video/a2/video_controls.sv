`timescale 1ns/1ps
/*
 *  video_controls.sv -- the free board inputs (KEY3..KEY1, SW0) become the picker's thresholds, so
 *  they can be moved on the board during the demo (R-V3: "both thresholds adjustable from the board").
 *  (NEW, Advay)
 *
 *    KEY1  raise the selected value          KEY2  lower it          KEY3  restore every default
 *    SW0   which value KEY1/KEY2 move, depending on the picker mode (SW7..SW6):
 *
 *      mode              SW0 = 0                         SW0 = 1
 *      0  R-V4           k   (k_q, step 8 = +-0.2 x)      floor   (step 4 = 1.6 %)
 *      1  R-V3           hi  (step 8 = 3.1 % of max)      lo      (step 8)
 *      2,3 R-V2 / R-V1   thr_abs (step 256, 1-D units)    thr_abs
 *
 *  Defaults (chosen with tools/video/hw_model.py on the two supplied pictures: at these values every
 *  rung reads both of them, and only R-V4 also reads the photo-like picture):
 *    hi = 115 (0.45), lo = 64 (0.25), floor = 26 (0.10), k_q = 102 (k = 2.5 over 25 columns),
 *    thr_abs = 2048 in 1-D units (x4 = 8192 with Sobel).
 *
 *  Clock / reset: the 50 MHz analysis clock, synchronous active-high reset (reset restores defaults).
 *  KEYs are active low and bounce: each is synchronised (two flops), sampled every DB_TICKS clocks
 *  (2^16 = 1.3 ms at 50 MHz, longer than a bounce) and a press is the sample going from up to down.
 *  SW0 and the mode come in raw and are synchronised here too.
 */
module video_controls #(
    parameter int AW       = 20,
    parameter int NW       = 9,
    parameter int DB_TICKS = 65536,
    parameter logic [NW-1:0] HI_DEF    = 9'd115,
    parameter logic [NW-1:0] LO_DEF    = 9'd64,
    parameter logic [NW-1:0] FLOOR_DEF = 9'd26,
    parameter logic [7:0]    KQ_DEF    = 8'd102,
    parameter logic [AW-1:0] ABS_DEF   = AW'(2048)
) (
    input  logic          clk,
    input  logic          reset,
    input  logic [3:1]    key_n,        // KEY3..KEY1, active low, straight from the pins
    input  logic          sw_sel,       // SW0
    input  logic [1:0]    mode,         // picker mode (already synchronised by the caller or not: synchronised again here)
    output logic [NW-1:0] hi,
    output logic [NW-1:0] lo,
    output logic [NW-1:0] floor_lvl,
    output logic [7:0]    k_q,
    output logic [AW-1:0] thr_abs
);
    // ---- synchronisers (the shared rtl/common/synchroniser.v, one per bit) ----
    logic [3:1] kn_s, k_s;
    logic       sel_s;
    logic [1:0] m_s;
    for (genvar i = 1; i <= 3; i++) begin : g_key
        synchroniser u_key (.clk(clk), .x(key_n[i]), .y(kn_s[i]));
    end
    assign k_s = ~kn_s;                             // 1 = pressed
    synchroniser u_sel (.clk(clk), .x(sw_sel), .y(sel_s));
    for (genvar i = 0; i < 2; i++) begin : g_mode
        synchroniser u_mode (.clk(clk), .x(mode[i]), .y(m_s[i]));
    end

    // ---- slow sampling = debounce ----
    logic [$clog2(DB_TICKS):0] tick_cnt;
    logic tick;
    assign tick = (32'(tick_cnt) == DB_TICKS - 1);
    always_ff @(posedge clk) begin
        if (reset || tick) tick_cnt <= '0;
        else tick_cnt <= tick_cnt + 1'b1;
    end
    logic [3:1] k_smp, press;
    always_ff @(posedge clk) begin
        press <= '0;
        if (reset) k_smp <= '0;
        else if (tick) begin
            k_smp  <= k_s;
            press  <= k_s & ~k_smp;                 // was up at the last sample, down now
        end
    end

    // ---- the adjustable values ----
    function automatic logic [NW-1:0] up(input logic [NW-1:0] v, input int step);
        return (32'(v) + step > 256) ? NW'(256) : NW'(32'(v) + step);
    endfunction
    function automatic logic [NW-1:0] down(input logic [NW-1:0] v, input int step);
        return (32'(v) < step) ? '0 : NW'(32'(v) - step);
    endfunction

    always_ff @(posedge clk) begin
        if (reset || press[3]) begin
            hi <= HI_DEF; lo <= LO_DEF; floor_lvl <= FLOOR_DEF; k_q <= KQ_DEF; thr_abs <= ABS_DEF;
        end else if (press[1] || press[2]) begin
            case (m_s)
                2'd0: if (!sel_s) begin
                          if (press[1]) k_q <= (k_q > 8'd247) ? 8'd255 : k_q + 8'd8;
                          else          k_q <= (k_q < 8'd8)   ? 8'd0   : k_q - 8'd8;
                      end else begin
                          if (press[1]) floor_lvl <= up(floor_lvl, 4);
                          else          floor_lvl <= down(floor_lvl, 4);
                      end
                2'd1: if (!sel_s) begin
                          if (press[1]) hi <= up(hi, 8);
                          else          hi <= down(hi, 8);
                      end else begin
                          if (press[1]) lo <= up(lo, 8);
                          else          lo <= down(lo, 8);
                      end
                default: begin
                          if (press[1]) thr_abs <= (thr_abs > {AW{1'b1}} - AW'(256)) ? {AW{1'b1}} : thr_abs + AW'(256);
                          else          thr_abs <= (thr_abs < AW'(256)) ? '0 : thr_abs - AW'(256);
                      end
            endcase
        end
    end
endmodule
