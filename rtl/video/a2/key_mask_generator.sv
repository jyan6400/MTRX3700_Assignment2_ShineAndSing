`timescale 1ns/1ps
/*
 *  key_mask_generator.sv -- detected boundaries -> the four playable keys.  (NEW, Advay)
 *
 *  Input: the boundary list from whichever picker the mode selected (source-image x, ascending).
 *  Output: four lanes, lane i = [lane_l[i], lane_r[i]] in source x, taken from four consecutive white
 *  keys (key j spans kept boundary j .. kept boundary j+1) starting at key lane_first, or -- when
 *  lane_first = 15, our default -- the FOUR MIDDLE KEYS of whatever was found: first = (kept - 5) / 2.
 *  (The two supplied pictures have 9 and 6 whole keys on the lattice, so no fixed key number suits
 *  both; centring does, and suits an unknown photograph too.) Nothing about the keys is typed in:
 *  every coordinate comes from the picture.
 *
 *  A keyboard is a pattern: white keys are equally spaced. Before counting keys the list is cleaned
 *  the way the video modelling notebook's template_fit() does it, so that one extra boundary (the
 *  photograph's shadow edge, a picture frame) does not shift every lane by a key:
 *    spacing s  the lower median of the gaps between consecutive boundaries
 *    keep       the first boundary, then each boundary d from the last kept one with |d - s| < s/4
 *               (on the lattice) or d > 1.5 s (a boundary was missed: accept it and move on)
 *    drop       everything else (off the lattice) -- flagged in kept_mask so the profile and mask
 *               views can show which boundaries were dropped and why.
 *
 *  Sequential, one clock (50 MHz analysis domain), synchronous active-high reset:
 *    COPY   count clocks: the list is read through idx / pos_of into registers
 *    MED    count clocks, two-stage pipeline: stage 1 compares gap i with every gap (NMAX-1
 *           comparators, registered), stage 2 counts the ones (a popcount of nibbles) and keeps the
 *           smallest gap with at least (m-1)/2 + 1 gaps <= it: the lower median
 *    FIT    count-1 clocks: the lattice walk
 *    LANES  1 clock
 *  About 3 x NMAX clocks at most.
 */
module key_mask_generator #(
    parameter int W    = assignment2_pkg::IMG_W,
    parameter int NMAX = 32
) (
    input  logic                       clk,
    input  logic                       reset,
    input  logic                       start,
    input  logic [3:0]                 lane_first,    // the key that is lane 0; 15 = the four middle keys
    input  logic [$clog2(NMAX):0]      count,
    output logic [$clog2(NMAX)-1:0]    idx,
    input  logic [$clog2(W)-1:0]       pos_of,
    // results (stable from done to the next start)
    output logic                       busy,
    output logic                       done,
    output logic [$clog2(NMAX):0]      bcount,        // raw boundaries
    output logic [NMAX*$clog2(W)-1:0]  bounds,        // raw boundary x, entry 0 in the low bits
    output logic [NMAX-1:0]            kept_mask,     // bit i: raw boundary i is on the lattice
    output logic [$clog2(NMAX):0]      kcount,        // kept boundaries
    output logic [$clog2(W)-1:0]       spacing,       // key spacing s (0 if fewer than 3 boundaries)
    output logic                       lanes_valid,
    output logic [4*$clog2(W)-1:0]     lane_l,        // lane i left boundary, lane 0 in the low bits
    output logic [4*$clog2(W)-1:0]     lane_r
);
    localparam int XW = $clog2(W);
    localparam int IW = $clog2(NMAX);
    localparam int CW = $clog2(NMAX) + 1;

    logic [XW-1:0] b [0:NMAX-1];          // raw list
    logic [XW-1:0] k [0:NMAX-1];          // kept list
    logic [CW-1:0] n;                     // raw count latched at start
    logic [CW-1:0] i;
    logic [XW-1:0] med;
    logic          have_med;

    // the first lane's key: fixed, or centred on the kept keys (kcount - 1 keys, 4 of them used)
    logic [CW-1:0] first_auto, first_eff;
    assign first_auto = (kcount >= CW'(5)) ? CW'((kcount - CW'(5)) >> 1) : '0;
    assign first_eff  = (lane_first == 4'hF) ? first_auto : CW'(lane_first);
    logic [XW-1:0] lastk;

    typedef enum logic [2:0] {IDLE, COPY, MED, MEDF, FIT, LANES, FIN} state_t;
    state_t state;
    assign busy = (state != IDLE);
    assign idx  = IW'(i);

    // gaps between consecutive raw boundaries
    logic [XW-1:0] gap [0:NMAX-2];
    always_comb for (int j = 0; j < NMAX - 1; j++) gap[j] = b[j+1] - b[j];

    // MED stage 1 (registered): which of the m = n-1 gaps are <= gap[i]
    logic [NMAX-2:0] le_bits;
    logic [XW-1:0]   gap_q;
    logic            med_v;                 // stage 2 has a valid comparison this clock
    always_ff @(posedge clk) begin
        gap_q <= gap[IW'(i)];
        for (int j = 0; j < NMAX - 1; j++) le_bits[j] <= (CW'(j) < n - 1'b1) && (gap[j] <= gap[IW'(i)]);
    end
    // MED stage 2: count them, four bits at a time
    function automatic logic [CW-1:0] popcount(input logic [NMAX-2:0] v);
        logic [CW-1:0] c;
        logic [4*((NMAX+2)/4)-1:0] w;
        c = '0; w = '0; w[NMAX-2:0] = v;
        for (int nb = 0; nb < (NMAX + 2) / 4; nb++)
            c = c + CW'(w[4*nb]) + CW'(w[4*nb+1]) + CW'(w[4*nb+2]) + CW'(w[4*nb+3]);
        return c;
    endfunction
    logic [CW-1:0] le_count;
    assign le_count = popcount(le_bits);
    // lower median of m values: the element of rank (m-1)/2, i.e. at least (m-1)/2 + 1 values <= it
    logic [CW-1:0] need;
    assign need = ((n - CW'(2)) >> 1) + 1'b1;

    // FIT: distance from the last kept boundary
    logic [XW-1:0] d;
    logic [XW:0]   dev;                   // |d - s|
    logic          on_lattice, skipped;
    assign d          = b[IW'(i)] - lastk;
    assign dev        = (d > med) ? {1'b0, d - med} : {1'b0, med - d};
    assign on_lattice = (dev < {3'b000, med[XW-1:2]});
    assign skipped    = ({d, 1'b0} > ({1'b0, med} + {med, 1'b0}) );      // 2d > 3s

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (reset) begin
            state <= IDLE; bcount <= '0; kcount <= '0; kept_mask <= '0; spacing <= '0;
            lanes_valid <= 1'b0; i <= '0; n <= '0; med_v <= 1'b0;
        end else case (state)
            IDLE: if (start) begin
                n <= count; i <= '0; kept_mask <= '0; have_med <= 1'b0; med <= '0; med_v <= 1'b0;
                lanes_valid <= 1'b0;
                state <= (count == '0) ? LANES : COPY;
                kcount <= '0;
            end
            COPY: begin
                b[IW'(i)] <= pos_of;
                if (i == n - 1'b1) begin
                    i <= '0;
                    state <= (n >= 3) ? MED : FIT;          // too few to have a spacing: keep them all
                end else i <= i + 1'b1;
            end
            MED: begin                                  // stage 1 runs on i, stage 2 on i-1
                med_v <= 1'b1;
                if (med_v && le_count >= need && (!have_med || gap_q < med)) begin med <= gap_q; have_med <= 1'b1; end
                if (i == n - CW'(2)) state <= MEDF;
                else i <= i + 1'b1;
            end
            MEDF: begin                                 // stage 2 for the last gap
                if (le_count >= need && (!have_med || gap_q < med)) begin med <= gap_q; have_med <= 1'b1; end
                med_v <= 1'b0; i <= '0; state <= FIT;
            end
            FIT: begin
                if (i == '0) begin
                    k[0] <= b[0]; lastk <= b[0]; kept_mask[0] <= 1'b1; kcount <= 1;
                end else if (!have_med || on_lattice || skipped) begin
                    k[IW'(kcount)] <= b[IW'(i)]; lastk <= b[IW'(i)]; kept_mask[IW'(i)] <= 1'b1;
                    kcount <= kcount + 1'b1;
                end
                if (i == n - 1'b1) state <= LANES;
                else i <= i + 1'b1;
            end
            LANES: begin
                spacing     <= have_med ? med : '0;
                bcount      <= n;
                for (int j = 0; j < NMAX; j++) bounds[j*XW +: XW] <= (CW'(j) < n) ? b[j] : '0;
                lanes_valid <= (32'(kcount) >= 32'(first_eff) + 5);
                for (int j = 0; j < 4; j++) begin
                    lane_l[j*XW +: XW] <= k[IW'(32'(first_eff) + j)];
                    lane_r[j*XW +: XW] <= k[IW'(32'(first_eff) + j + 1)];
                end
                state <= FIN;
            end
            FIN: begin done <= 1'b1; state <= IDLE; end
            default: state <= IDLE;
        endcase
    end
endmodule
