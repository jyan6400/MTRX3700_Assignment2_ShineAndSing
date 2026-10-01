`timescale 1ns/1ps
/*
 *  hysteresis_profile.sv -- R-V3/R-V4 peak picker: non-maximum suppression, two thresholds
 *  (hysteresis) and a minimum spacing.  (NEW, Advay: the R-V3 extension of peak_pick.sv)
 *
 *  Works on the normalised profile n[x] (0..256 = 0..1 of the maximum) and is the hardware twin of
 *  pick_nms_hyst() in the video modelling notebook:
 *
 *    candidate  1 <= x <= W-2, n[x] >= both neighbours (a local maximum; >= so a plateau counts),
 *               and n[x] > lo(x)                                    <- non-maximum suppression
 *    strong     a candidate with n[x] > hi(x)                       <- the high threshold accepts
 *    accepted   strong, or within min_gap (<=) of a strong candidate <- the low threshold keeps the
 *               weaker peak beside an accepted one (the other side of the same key gap)
 *    merged     accepted peaks closer than min_gap to the last kept one are the same boundary: the
 *               larger wins, a tie keeps the first (peak_pick.sv's rule)
 *
 *  hi(x), lo(x):
 *    adaptive = 0 (R-V3)  the constants hi, lo (board-adjustable; defaults 0.45 = 115, 0.25 = 64)
 *    adaptive = 1 (R-V4)  hi(x) = max(t[x], floor), lo(x) = max(t[x] - t[x]/4, floor), with t the
 *                         local-average threshold from local_threshold.sv
 *
 *  Sequential, one clock (50 MHz analysis domain), synchronous active-high reset:
 *    WALK   x = 0..W: reads n[x] and t[x] (one-cycle latency, the same pipeline alignment as
 *           peak_pick.sv), stores up to NC candidates with a "strong" bit and a "strong one within
 *           min_gap before me" bit, and streams (x, n, hi(x), lo(x)) out for the profile view.
 *    BACK   candidates last to first: add "strong one within min_gap after me".
 *    MERGE  candidates first to last: the min_gap merge into pos[] (NMAX entries).
 *  About W + 2 NC + 5 clocks. More than NC candidates sets cand_overflow and ignores the rest (only
 *  seen with the 1-D detector at R-V3 on the noisy picture, which is expected to fail there anyway).
 *  The boundary list is read like peak_pick's: pos_of(idx), count.
 */
module hysteresis_profile #(
    parameter int W    = assignment2_pkg::IMG_W,
    parameter int NW   = 9,
    parameter int NC   = 64,
    parameter int NMAX = 32
) (
    input  logic                    clk,
    input  logic                    reset,
    input  logic                    start,
    input  logic                    adaptive,
    input  logic [NW-1:0]           hi,
    input  logic [NW-1:0]           lo,
    input  logic [NW-1:0]           floor_lvl,
    input  logic [$clog2(W)-1:0]    min_gap,
    // the normalised profile and the local threshold, read at the same address
    output logic [$clog2(W)-1:0]    rd_x,
    input  logic [NW-1:0]           n_val,
    input  logic [NW-1:0]           t_val,         // local threshold (TW = NW in local_threshold)
    // results
    output logic                    busy,
    output logic                    done,
    output logic [$clog2(NMAX):0]   count,
    input  logic [$clog2(NMAX)-1:0] idx,
    output logic [$clog2(W)-1:0]    pos_of,
    output logic                    cand_overflow,
    // (x, n, hi(x), lo(x)) for the profile view, one per column during WALK
    output logic                    dsp_wr,
    output logic [$clog2(W)-1:0]    dsp_x,
    output logic [NW-1:0]           dsp_n,
    output logic [NW-1:0]           dsp_hi,
    output logic [NW-1:0]           dsp_lo
);
    localparam int XW  = $clog2(W);
    localparam int IW  = $clog2(NMAX);
    localparam int CW  = $clog2(NC);

    logic [XW-1:0] pos [0:NMAX-1];
    assign pos_of = pos[idx];

    // candidate list
    logic [XW-1:0] cpos [0:NC-1];
    logic [NW-1:0] cval [0:NC-1];
    logic          cstr [0:NC-1];
    logic          cacc [0:NC-1];
    logic [CW:0]   nc;

    typedef enum logic [2:0] {IDLE, WALK, BSTART, BACK, MERGE, FIN} state_t;
    state_t state;
    logic [XW:0]   x;
    logic [NW-1:0] v_prev, v_cur;
    logic [NW-1:0] t_cur;
    logic [XW-1:0] cur_x;
    logic          have_ls;               // a strong candidate has been seen (forward)
    logic [XW-1:0] ls_pos;
    logic [CW:0]   i;                     // candidate index for BACK / MERGE
    logic          have_last;
    logic [XW-1:0] last_pos;
    logic [NW-1:0] last_val;

    // per-column thresholds
    function automatic logic [NW-1:0] hi_of(input logic [NW-1:0] t);
        if (!adaptive) return hi;
        return (t > floor_lvl) ? t : floor_lvl;
    endfunction
    function automatic logic [NW-1:0] lo_of(input logic [NW-1:0] t);
        logic [NW-1:0] w;
        w = t - (t >> 2);
        if (!adaptive) return lo;
        return (w > floor_lvl) ? w : floor_lvl;
    endfunction

    logic [NW-1:0] cur_hi, cur_lo;
    assign cur_hi = hi_of(t_cur);
    assign cur_lo = lo_of(t_cur);
    logic is_cand, is_strong;
    assign is_cand   = (v_cur >= v_prev) && (v_cur >= n_val) && (v_cur > cur_lo);
    assign is_strong = (v_cur > cur_hi);

    assign rd_x = x[XW-1:0];
    assign busy = (state != IDLE);

    // index helpers
    logic [CW-1:0] ci;
    assign ci = CW'(i);

    always_ff @(posedge clk) begin
        done   <= 1'b0;
        dsp_wr <= 1'b0;
        if (reset) begin
            state <= IDLE; count <= '0; nc <= '0; x <= '0; cand_overflow <= 1'b0;
            have_ls <= 1'b0; have_last <= 1'b0;
        end else case (state)
            IDLE: if (start) begin
                x <= '0; nc <= '0; count <= '0; cand_overflow <= 1'b0;
                have_ls <= 1'b0; have_last <= 1'b0;
                v_prev <= '0; v_cur <= '0; t_cur <= '0;
                state <= WALK;
            end
            WALK: begin
                x      <= x + 1'b1;
                v_prev <= v_cur;
                v_cur  <= n_val;
                t_cur  <= t_val;
                cur_x  <= XW'(x - 1'b1);
                // stream the column that just arrived (x - 1) for the profile view
                if (x >= 1) begin
                    dsp_wr <= 1'b1;
                    dsp_x  <= XW'(x - 1'b1);
                    dsp_n  <= n_val;
                    dsp_hi <= hi_of(t_val);
                    dsp_lo <= lo_of(t_val);
                end
                // examine centre cur_x = x - 2 against x - 3 (v_prev) and x - 1 (n_val)
                if (x >= 3 && is_cand) begin
                    if (int'(nc) < NC) begin
                        cpos[CW'(nc)] <= cur_x;
                        cval[CW'(nc)] <= v_cur;
                        cstr[CW'(nc)] <= is_strong;
                        cacc[CW'(nc)] <= is_strong || (have_ls && ((cur_x - ls_pos) <= min_gap));
                        nc <= nc + 1'b1;
                        if (is_strong) begin have_ls <= 1'b1; ls_pos <= cur_x; end
                    end else begin
                        cand_overflow <= 1'b1;
                    end
                end
                if (int'(x) == W) state <= BSTART;
            end
            // the candidate list is complete (the last centre, W-2, was stored on the last WALK clock)
            BSTART: begin
                have_ls <= 1'b0;
                i       <= nc - 1'b1;
                state   <= (nc == '0) ? FIN : BACK;
            end
            // last candidate to first: is there a strong one within min_gap after me?
            BACK: begin
                if (have_ls && ((ls_pos - cpos[ci]) <= min_gap)) cacc[ci] <= 1'b1;
                if (cstr[ci]) begin have_ls <= 1'b1; ls_pos <= cpos[ci]; end
                if (i == '0) state <= MERGE;
                else i <= i - 1'b1;
            end
            // first to last: the min_gap merge
            MERGE: begin
                if (cacc[ci]) begin
                    if (have_last && ((cpos[ci] - last_pos) < min_gap)) begin
                        if (cval[ci] > last_val) begin
                            pos[IW'(count - 1'b1)] <= cpos[ci];
                            last_pos <= cpos[ci];
                            last_val <= cval[ci];
                        end
                    end else if (int'(count) < NMAX) begin
                        pos[IW'(count)] <= cpos[ci];
                        count     <= count + 1'b1;
                        last_pos  <= cpos[ci];
                        last_val  <= cval[ci];
                        have_last <= 1'b1;
                    end
                end
                if (i == nc - 1'b1) state <= FIN;
                else i <= i + 1'b1;
            end
            FIN: begin done <= 1'b1; state <= IDLE; end
            default: state <= IDLE;
        endcase
    end
endmodule
