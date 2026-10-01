/*
 * synchroniser.v
 *
 * PURPOSE
 * -------
 * Synchronises an asynchronous external input to CLOCK_50.
 *
 * Physical push-buttons are not aligned to the FPGA clock, so sampling one
 * directly can cause metastability. Two flip-flops are used in series before
 * the signal is passed to debounce.v.
 *
 * SIGNAL FLOW
 * -----------
 * external input x
 *      |
 *      v
 *   flip-flop 1
 *      |
 *      v
 *   flip-flop 2
 *      |
 *      v
 * synchronised output y
 */

module synchroniser (
    input  clk,
    input  x,
    output y
);

    reg x_q0;
    reg x_q1;

    always @(posedge clk) begin
        x_q0 <= x;
        x_q1 <= x_q0;
    end

    assign y = x_q1;

endmodule