/*
 * rng.v
 *
 * PURPOSE
 * -------
 * Reused pseudo-random number generator based on a 10-bit Linear Feedback
 * Shift Register (LFSR).
 *
 * In Piano Tiles, top_level.sv uses bits of random_value to choose:
 *      1. which lane receives the next note
 *      2. the starting countdown value of that note
 *
 * This is deterministic pseudo-random logic rather than true randomness,
 * which makes it simple and synthesizable in hardware.
 *
 * PARAMETERS
 * ----------
 * OFFSET    : value added to the LFSR output.
 * MAX_VALUE : determines the width of random_value.
 * SEED      : initial non-zero LFSR state.
 */

module rng #(
    parameter OFFSET    = 200,
    parameter MAX_VALUE = 1223,
    parameter SEED      = 10'b0000000001
) (
    input clk,
    output [$clog2(MAX_VALUE)-1:0] random_value
);

    // LFSR architecture is fixed at 10 bits for the reused RTG generator.
    localparam integer LFSR_MSB      = 10;
    localparam integer FEEDBACK_TAP  = 7;

    // 10-bit LFSR. Original RTG module indexes the register from 10 down to 1.
    reg [10:1] lfsr;

    // XOR feedback used by the LFSR.
    wire feedback;


    // ------------------------------------------------------------
    // Initial state
    // ------------------------------------------------------------

    initial begin
        lfsr = SEED;
    end


    // ------------------------------------------------------------
    // Feedback calculation
    // ------------------------------------------------------------

    assign feedback =
        lfsr[LFSR_MSB] ^ lfsr[FEEDBACK_TAP];


    // ------------------------------------------------------------
    // LFSR shift
    // ------------------------------------------------------------

    always @(posedge clk) begin
        lfsr[10:2] <= lfsr[9:1];
        lfsr[1]    <= feedback;
    end


    // Offset the LFSR value into the required output range.
    assign random_value = lfsr + OFFSET;

endmodule