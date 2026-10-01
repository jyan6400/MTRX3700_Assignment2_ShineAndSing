`timescale 1ns/1ps
/*
 *  pick_runs.sv -- the simple run picker of R-V1.  (NEW, Advay)
 *  Not part of the Mini-Project 2 barcode reader (which uses peak_pick.sv only); written for A2,
 *  under the name the course's tools/video/video_model.py gives it, from that model's float twin
 *  pick_runs():
 *
 *      every run of consecutive columns above thr is one boundary, placed at its centre
 *      (first + last) / 2; a run whose centre is closer than min_gap to the previous boundary is
 *      dropped (runs merge).
 *
 *  Same interface as peak_pick.sv (start, a one-cycle-latency profile read port, count, pos_of(idx)),
 *  so video_analysis.sv can select either picker. W + 3 clocks per walk.
 */
module pick_runs #(
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
    output logic                    busy,
    output logic                    done,
    output logic [$clog2(NMAX):0]   count,
    input  logic [$clog2(NMAX)-1:0] idx,
    output logic [$clog2(W)-1:0]    pos_of
);
    localparam int XW = $clog2(W);
    localparam int IW = $clog2(NMAX);
    logic [XW-1:0] pos [0:NMAX-1];
    assign pos_of = pos[idx];

    typedef enum logic [1:0] {IDLE, WALK, FIN} state_t;
    state_t state;
    logic [XW:0]   x;                  // address being read; rd_val is the value at x - 1
    logic          in_run;
    logic [XW-1:0] run_first;
    logic [XW-1:0] last_pos;
    logic          have_last;

    assign rd_x = x[XW-1:0];
    assign busy = (state == WALK);

    // the column whose value is on rd_val this cycle, and whether it is above the threshold
    logic [XW-1:0] cx;
    logic          above;
    assign cx    = XW'(x - 1'b1);
    assign above = (x >= 1) && (int'(x) <= W) && (rd_val > thr);

    // does a run end on this walk step, and where does it start and end?
    //   above, not in a run, last column      -> a one-column run at cx
    //   above, in a run, last column          -> run_first .. cx
    //   not above, in a run                   -> run_first .. cx - 1
    logic          closing;
    logic [XW-1:0] c_first, c_last;
    always_comb begin
        closing = 1'b0; c_first = cx; c_last = cx;
        if (state == WALK && x >= 1) begin
            if (above && !in_run && int'(x) == W)     begin closing = 1'b1; c_first = cx;        c_last = cx;           end
            else if (above && in_run && int'(x) == W) begin closing = 1'b1; c_first = run_first; c_last = cx;           end
            else if (!above && in_run)                begin closing = 1'b1; c_first = run_first; c_last = XW'(x - 2'd2); end
        end
    end
    // the run's centre, (first + last) / 2, and whether it is far enough from the previous boundary
    /* verilator lint_off UNUSEDSIGNAL */
    logic [XW:0]   c_sum;                        // bit 0 is dropped by the halving
    /* verilator lint_on UNUSEDSIGNAL */
    logic [XW-1:0] c_mid;
    logic          keep;
    assign c_sum = {1'b0, c_first} + {1'b0, c_last};
    assign c_mid = c_sum[XW:1];
    assign keep  = closing && !(have_last && ((c_mid - last_pos) < min_gap)) && (int'(count) < NMAX);

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (reset) begin
            state <= IDLE; count <= '0; x <= '0; in_run <= 1'b0; have_last <= 1'b0;
        end else case (state)
            IDLE: if (start) begin
                x <= '0; count <= '0; in_run <= 1'b0; have_last <= 1'b0;
                state <= WALK;
            end
            WALK: begin
                x <= x + 1'b1;
                if (x >= 1) begin
                    if (above && !in_run)      begin in_run <= 1'b1; run_first <= cx; end
                    else if (!above && in_run) in_run <= 1'b0;
                end
                if (keep) begin
                    pos[IW'(count)] <= c_mid;
                    count           <= count + 1'b1;
                    last_pos        <= c_mid;
                    have_last       <= 1'b1;
                end
                if (int'(x) == W) state <= FIN;
            end
            FIN: begin done <= 1'b1; in_run <= 1'b0; state <= IDLE; end
            default: state <= IDLE;
        endcase
    end
endmodule
