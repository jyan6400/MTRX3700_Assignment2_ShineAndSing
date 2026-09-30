`timescale 1ns/1ps

/*
 * score.sv
 *
 * PURPOSE
 * -------
 * Maintains the player's score.
 *
 * game_fsm produces one valid_hit bit for each lane. Multiple lanes can
 * therefore theoretically be hit in the same FPGA clock cycle, so this
 * module first counts how many valid_hit bits are high.
 *
 * The score then increases by that number.
 *
 * OVERFLOW BEHAVIOUR
 * ------------------
 * The score SATURATES at SCORE_MAX rather than wrapping back to zero.
 *
 * LIVE-CHANGE CONSTANT
 * --------------------
 * SCORE_MAX controls the largest score that can be stored.
 */

module score (
    input  logic       clk,
    input  logic       reset,

    // One valid-hit event for each lane.
    input  logic [3:0] valid_hit,

    // Seven bits are sufficient for values 0-99.
    output logic [6:0] score
);

    // ------------------------------------------------------------
    // Named score constants
    // ------------------------------------------------------------

    localparam logic [6:0] SCORE_ZERO = 7'd0;
    localparam logic [7:0] SCORE_MAX  = 8'd99;


    // ------------------------------------------------------------
    // Internal values
    // ------------------------------------------------------------

    // Maximum possible simultaneous hits = four.
    logic [2:0] hits_this_cycle;

    // Extra bit allows comparison before saturation.
    logic [7:0] score_sum;


    // ------------------------------------------------------------
    // Count simultaneous valid hits
    // ------------------------------------------------------------

    always_comb begin

        hits_this_cycle =
            {2'b00, valid_hit[0]} +
            {2'b00, valid_hit[1]} +
            {2'b00, valid_hit[2]} +
            {2'b00, valid_hit[3]};

        score_sum =
            {1'b0, score} +
            {5'b00000, hits_this_cycle};

    end


    // ------------------------------------------------------------
    // Score register
    // ------------------------------------------------------------

    always_ff @(posedge clk) begin

        // Reset score to zero.
        if (reset) begin

            score <= SCORE_ZERO;

        end


        // Only update the register when at least one lane was hit.
        else if (hits_this_cycle != 0) begin

            // Saturate rather than overflow beyond 99.
            if (score_sum >= SCORE_MAX)
                score <= SCORE_MAX[6:0];

            else
                score <= score_sum[6:0];

        end

    end

endmodule