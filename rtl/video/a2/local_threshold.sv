`timescale 1ns/1ps
/*
 *  local_threshold.sv -- R-V4: a threshold that follows the profile's local average.  (NEW, Advay)
 *
 *      t[x] = ( k_q * sum_{j = x-HALF}^{x+HALF} n[j] ) >> 10          (n outside 0..W-1 counts as 0)
 *
 *  With HALF = 12 the window is 25 columns (the video modelling notebook's), and k_q = k * 1024 / 25:
 *  the default k_q = 102 is k = 2.5 x the local mean. In a shadow the local mean is low, so the
 *  threshold follows it down and the shadowed half of the keyboard is judged against its own
 *  surroundings: the audio gate's noise floor, sideways.
 *
 *  Hardware: Lesson 4's moving average. The normalised profile is read once, in order, one column per
 *  clock; a (2 HALF + 1)-deep delay line of the values read gives the one leaving the window, so the
 *  running sum costs one add and one subtract per column (no RAM second port, no divider).
 *  One multiplier (k_q x sum). t saturates at 2^TW - 1 (it is only compared with n <= 256).
 *
 *  Clock / reset: one clock (50 MHz analysis domain), synchronous active-high reset.
 *  `start` -> about W + HALF + 3 clocks -> `done`. Results: a W-entry RAM with a one-cycle read port.
 */

// =============================================================================
// LIVE CHANGE -- R-V4 LOCAL ADAPTIVE THRESHOLD
// =============================================================================
// HALF sets the neighbourhood radius. The full moving window is:
//
//     WIN = 2*HALF + 1
//
// With HALF=12, the default window is 25 profile columns.
//
// Larger HALF:
//   + smoother, broader estimate of the local profile level
//   - less responsive to a rapidly changing local illumination condition
//
// Smaller HALF:
//   + more local adaptation
//   - more sensitivity to local profile variation/noise
//
// k_q is supplied at run time by video_subsystem.sv and multiplies the local
// running sum. Increasing k_q raises the adaptive threshold; decreasing it
// lowers the threshold. The exact fixed-point relationship is documented in
// the module header above.
// =============================================================================
module local_threshold #(
    parameter int W    = assignment2_pkg::IMG_W,
    parameter int NW   = 9,         // normalised profile width
    parameter int TW   = 9,         // threshold width (saturating)
    parameter int HALF = 12,        // window = 2 HALF + 1 columns
    parameter int KW   = 8          // k_q width
) (
    input  logic                  clk,
    input  logic                  reset,
    input  logic                  start,
    input  logic [KW-1:0]         k_q,
    output logic [$clog2(W)-1:0]  src_rd_x,
    input  logic [NW-1:0]         src_rd_val,
    output logic                  busy,
    output logic                  done,
    input  logic [$clog2(W)-1:0]  rd_x,
    output logic [TW-1:0]         rd_val
);
    localparam int XW   = $clog2(W);
    localparam int WIN  = 2 * HALF + 1;
    localparam int SW   = NW + $clog2(WIN) + 1;          // running-sum width
    localparam int PW   = SW + KW;                       // product width
    localparam int AXW  = $clog2(W + HALF + 2) + 1;      // walk address width

    typedef enum logic [1:0] {IDLE, WALK, FIN} state_t;
    state_t state;
    logic [AXW-1:0] a;                      // address being read
    logic [NW-1:0]  dl [0:WIN-1];           // the last WIN values that entered the window
    logic [SW-1:0]  sum;

    assign src_rd_x = (int'(a) < W) ? XW'(a) : '0;
    assign busy     = (state != IDLE);

    // the value entering the window this cycle is n[a-1] (read last cycle), or 0 past the end
    logic [NW-1:0] v_in;
    assign v_in = ((int'(a) >= 1) && (int'(a) <= W)) ? src_rd_val : '0;
    logic [SW-1:0] sum_next;
    assign sum_next = sum + SW'(v_in) - SW'(dl[WIN-1]);

    // centre column of the window after this value has entered: (a - 1) - HALF
    int cx;
    assign cx = int'(a) - (HALF + 1);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [PW-1:0] prod;                   // the low 10 bits are the >> 10
    /* verilator lint_on UNUSEDSIGNAL */
    assign prod = PW'(sum_next) * PW'(k_q);
    logic [PW-11:0] t_full;
    assign t_full = prod[PW-1:10];
    logic [TW-1:0] t_sat;
    assign t_sat = (int'(t_full) > (1 << TW) - 1) ? '1 : TW'(t_full);

    // results: a simple dual-port RAM written in its own block (Quartus infers an M10K)
    logic [TW-1:0] tram [0:W-1];
    logic          t_we;
    logic [XW-1:0] t_waddr;
    assign t_we    = (state == WALK) && (a >= 1) && (cx >= 0) && (cx < W);
    assign t_waddr = XW'(cx);
    always_ff @(posedge clk) if (t_we) tram[t_waddr] <= t_sat;
    always_ff @(posedge clk) rd_val <= tram[rd_x];

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (reset) begin
            state <= IDLE; a <= '0; sum <= '0;
        end else case (state)
            IDLE: if (start) begin
                a <= '0; sum <= '0;
                for (int i = 0; i < WIN; i++) dl[i] <= '0;
                state <= WALK;
            end
            WALK: begin
                a <= a + 1'b1;
                if (a >= 1) begin
                    sum <= sum_next;
                    dl[0] <= v_in;
                    for (int i = 1; i < WIN; i++) dl[i] <= dl[i-1];
                end
                if (int'(a) == W + HALF) state <= FIN;
            end
            FIN: begin done <= 1'b1; state <= IDLE; end
            default: state <= IDLE;
        endcase
    end
endmodule
