`timescale 1ns/1ps
/*
 *  REUSED MODULE -- Lesson 3.2d / Mini-Project 2 (barcode reader), Advay's completed peak_pick.sv.
 *  CHANGES FOR ASSIGNMENT 2: none. In A2 it is the R-V2 picker (Sobel profile, one absolute threshold,
 *  local maxima, min_gap). Its R-V3 extension -- divide by the maximum and a second threshold -- is
 *  a2/profile_normalise.sv + a2/hysteresis_profile.sv, which keep this module's walk and merge rule
 *  (same pipeline alignment, same ">=" plateau test, same strict ">" tie rule) so the two agree.
 *
 *  peak_pick.sv -- walk a 1-D profile and list its peaks.
 *
 *  Lesson 4's fft_find_peak returns the single largest bin. This is the plural: every column
 *  that is (a) above a threshold and (b) a local maximum (not smaller than either neighbour)
 *  is a candidate, and candidates closer together than min_gap are merged, the larger winning.
 *
 *  Sequential: `start` begins a walk over x = 0..W-1 reading the profile through rd_x/rd_val
 *  (one-cycle read latency), so it takes about W+3 clocks and no per-pixel logic. Positions
 *  are stored in a small array; `done` pulses at the end with `count` valid. The list is read
 *  combinationally: pos_of(idx).
 */
module peak_pick #(
    parameter int W    = 320,
    parameter int AW   = 20,
    parameter int NMAX = 32
) (
    input  logic                    clk,
    input  logic                    reset,
    input  logic                    start,
    input  logic [AW-1:0]           thr,
    input  logic [$clog2(W)-1:0]    min_gap,
    output logic [$clog2(W)-1:0]    rd_x,
    input  logic [AW-1:0]           rd_val,
    output logic                    busy,       // 1 while walking: rd_x/rd_val then present every entry in order
    output logic                    done,
    output logic [$clog2(NMAX):0]   count,
    input  logic [$clog2(NMAX)-1:0] idx,
    output logic [$clog2(W)-1:0]    pos_of
);
    localparam int XW = $clog2(W);
    localparam int IW = $clog2(NMAX);     // width of an index into pos[]
    logic [XW-1:0] pos [0:NMAX-1];
    assign pos_of = pos[idx];

    typedef enum logic [1:0] {IDLE, WALK, FLUSH, FIN} state_t;
    state_t state;
    logic [XW:0]   x;                 // address being read (one ahead of the value examined)
    logic [AW-1:0] v_prev, v_cur;     // values at x-2 (prev) and x-1 (cur); rd_val is x
    logic [XW-1:0] cur_x;
    logic [XW-1:0] last_pos;
    logic [AW-1:0] last_val;
    logic          have_last;

    // is the value at cur_x a peak?  (neighbour at rd_val is the column after it)
    // Rule 1: above the threshold.  Rule 2: not smaller than either neighbour.
    // '>=' (not '>') on the neighbours so a flat-topped peak (plateau) still counts.
    logic is_peak;
    assign is_peak = (v_cur > thr) && (v_cur >= v_prev) && (v_cur >= rd_val);

    assign rd_x = x[XW-1:0];
    assign busy = (state == WALK);
    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (reset) begin
            state <= IDLE; count <= '0; x <= '0; have_last <= 1'b0;
        end else case (state)
            IDLE: if (start) begin
                x <= '0; count <= '0; have_last <= 1'b0; v_prev <= '0; v_cur <= '0;
                state <= WALK;
            end
            WALK: begin
                // pipeline: rd_val is the value at x (read last cycle) -> becomes v_cur, and
                // the previous v_cur (at x-1) is examined against its two neighbours.
                x <= x + 1'b1;
                v_prev <= v_cur;
                v_cur  <= rd_val;
                cur_x  <= XW'(x - 1);              // rd_val was read from x-1: v_cur is the value AT cur_x
                if (x >= 3 && is_peak) begin        // examine centre cur_x = x-2 (needs both neighbours)
                    if (have_last && ((cur_x - last_pos) < min_gap)) begin
                        // Rule 3: too close to the previous peak -> same feature. Keep the larger.
                        // Strict '>' so on a tie the FIRST one stays (e.g. the start of a plateau).
                        if (v_cur > last_val) begin
                            pos[IW'(count - 1'b1)] <= cur_x;
                            last_pos               <= cur_x;
                            last_val               <= v_cur;
                        end
                    end
                    else if (int'(count) < NMAX) begin
                        // A new, separate peak: append it to the list and remember it.
                        pos[IW'(count)] <= cur_x;
                        count           <= count + 1'b1;
                        last_pos        <= cur_x;
                        last_val        <= v_cur;
                        have_last       <= 1'b1;
                    end
                end
                if (x == W) state <= FIN;                    // last real column examined
            end
            FIN: begin done <= 1'b1; state <= IDLE; end
            default: state <= IDLE;
        endcase
    end
endmodule
