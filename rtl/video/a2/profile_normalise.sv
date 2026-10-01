`timescale 1ns/1ps
/*
 *  profile_normalise.sv -- R-V3: divide the column profile by its maximum.  (NEW, Advay)
 *
 *      n[x] = floor( p[x] * 256 / max(p) )        0..256, i.e. a fraction of the maximum in 1/256
 *
 *  After this every threshold is a fraction (0.25 = 64, 0.45 = 115) and means the same thing on
 *  any picture, any lighting and either edge detector: a Sobel profile is four times a 1-D one,
 *  a dim picture's is a fraction of a bright one's, and neither changes n.
 *
 *  Clock / reset: one clock (the 50 MHz analysis domain), synchronous active-high reset.
 *
 *  Operation, started by `start` (the column profile's `done`):
 *    pass A  walk x = 0..W-1 through the source read port (one-cycle latency) and keep the maximum.
 *    pass B  for each x: read p[x], divide, write n[x] into a W-entry RAM and present it once on
 *            the (out_wr, out_x, out_val) stream.
 *    last    the same divider turns the R-V1/R-V2 absolute threshold into the same units
 *            (thr_n = thr_abs * 256 / max, saturated at 511) so the profile view can draw it.
 *  `done` pulses once at the end. About W + 12 W + 20 clocks (4 200 for W = 320): the next sweep's
 *  first summed row is ~47 000 clocks away, so the profile is stable for the whole run.
 *
 *  The divider: p <= max, so the quotient fits in 9 bits and a restoring divider needs only 9 steps
 *  if it starts with the remainder p >> 1 (which is < max). One bit per clock, no multiplier,
 *  no DSP block. max = 0 (a black picture) gives n = 0 everywhere and thr_n = 511.
 *
 *  Read port for the next stage: rd_x -> rd_val one clock later (an inferred M10K).
 */
module profile_normalise #(
    parameter int W  = assignment2_pkg::IMG_W,
    parameter int AW = 20,          // profile width
    parameter int NW = 9            // normalised width: 0..256 needs 9 bits
) (
    input  logic                  clk,
    input  logic                  reset,
    input  logic                  start,
    input  logic [AW-1:0]         thr_abs,       // absolute threshold, converted after the walk
    // source profile (col_profile's read port)
    output logic [$clog2(W)-1:0]  src_rd_x,
    input  logic [AW-1:0]         src_rd_val,
    // results
    output logic                  busy,
    output logic                  done,
    output logic [AW-1:0]         max_val,
    output logic [NW-1:0]         thr_n,
    output logic                  out_wr,        // one pulse per column during pass B
    output logic [$clog2(W)-1:0]  out_x,
    output logic [NW-1:0]         out_val,
    // read port of the normalised profile
    input  logic [$clog2(W)-1:0]  rd_x,
    output logic [NW-1:0]         rd_val
);
    localparam int XW = $clog2(W);

    // the normalised profile: a simple dual-port RAM (write port below, read port for the next stage),
    // written in its own block so that Quartus infers an M10K
    logic [NW-1:0] nram [0:W-1];
    logic          n_we;
    logic [$clog2(W)-1:0] n_waddr;
    logic [NW-1:0] n_wdata;
    always_ff @(posedge clk) if (n_we) nram[n_waddr] <= n_wdata;
    always_ff @(posedge clk) rd_val <= nram[rd_x];

    typedef enum logic [2:0] {IDLE, MAXW, RD, WAITV, DIV, WR, TDIV, FIN} state_t;
    state_t state;
    logic [XW:0]    x;              // walk address
    logic [XW-1:0]  col;            // column being divided
    logic [AW-1:0]  mx;
    logic [AW-1:0]  rem;            // remainder (< max, so AW bits)
    logic [8:0]     low;            // the 9 dividend bits still to bring down (p[0] then 8 zeros)
    logic [NW-1:0]  q;
    logic [3:0]     step;
    logic           tdiv_sat;

    // one restoring step: bring down the next dividend bit, subtract if it fits
    logic [AW:0]  rem_sh;
    logic         fits;
    assign rem_sh = {rem, low[8]};
    assign fits   = (rem_sh >= {1'b0, mx});
    /* verilator lint_off UNUSEDSIGNAL */
    logic [AW:0]  rem_diff;              // its top bit is 0 whenever it is used
    /* verilator lint_on UNUSEDSIGNAL */
    assign rem_diff = rem_sh - {1'b0, mx};
    logic [AW-1:0] rem_next;             // < max either way, so the top bit is always 0
    assign rem_next = fits ? rem_diff[AW-1:0] : rem_sh[AW-1:0];

    assign src_rd_x = (state == MAXW) ? x[XW-1:0] : col;
    assign n_we     = (state == WR);
    assign n_waddr  = col;
    assign n_wdata  = q;
    assign busy     = (state != IDLE);

    always_ff @(posedge clk) begin
        done   <= 1'b0;
        out_wr <= 1'b0;
        if (reset) begin
            state <= IDLE; max_val <= '0; thr_n <= '0; mx <= '0; x <= '0; col <= '0;
        end else case (state)
            IDLE: if (start) begin
                x <= '0; mx <= '0; state <= MAXW;
            end
            // pass A: address x out, value for x-1 back
            MAXW: begin
                x <= x + 1'b1;
                if (x >= 1 && src_rd_val > mx) mx <= src_rd_val;
                if (int'(x) == W) begin col <= '0; state <= RD; end
            end
            // pass B
            RD:    state <= WAITV;                      // src_rd_x = col goes out this cycle
            WAITV: begin                                // src_rd_val = p[col]
                rem  <= {1'b0, src_rd_val[AW-1:1]};     // p >> 1  (< max)
                low  <= {src_rd_val[0], 8'd0};          // then p[0] and eight zeros: p * 256
                q    <= '0;
                step <= '0;
                state <= (mx == '0) ? WR : DIV;
            end
            DIV: begin
                rem  <= rem_next;
                q    <= {q[NW-2:0], fits};
                low  <= {low[7:0], 1'b0};
                step <= step + 1'b1;
                if (step == 4'd8) state <= WR;
            end
            WR: begin
                out_wr    <= 1'b1;
                out_x     <= col;
                out_val   <= q;
                if (int'(col) == W - 1) begin
                    // the absolute threshold in the same units: thr * 256 / max, 511 if it is >= 2 max
                    tdiv_sat <= (mx == '0) || ({1'b0, thr_abs} >= {mx, 1'b0});
                    rem  <= {1'b0, thr_abs[AW-1:1]};
                    low  <= {thr_abs[0], 8'd0};
                    q    <= '0;
                    step <= '0;
                    state <= TDIV;
                end else begin
                    col   <= col + 1'b1;
                    state <= RD;
                end
            end
            TDIV: begin
                if (tdiv_sat) begin
                    thr_n <= '1; state <= FIN;
                end else begin
                    rem  <= rem_next;
                    q    <= {q[NW-2:0], fits};
                    low  <= {low[7:0], 1'b0};
                    step <= step + 1'b1;
                    if (step == 4'd8) begin thr_n <= {q[NW-2:0], fits}; state <= FIN; end
                end
            end
            FIN: begin max_val <= mx; done <= 1'b1; state <= IDLE; end
            default: state <= IDLE;
        endcase
    end
endmodule
