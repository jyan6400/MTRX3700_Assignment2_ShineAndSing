`timescale 1ns/1ps

/*
 * game_fsm.sv
 *
 * PURPOSE
 * -------
 * Central control logic for Piano Tiles.
 *
 * This module decides:
 *      - whether a requested note can spawn
 *      - whether a button press is a valid hit
 *      - what happens after an early press
 *      - when a lane should be cleared
 *      - when a score event and hit-LED event should be generated
 *
 *
 * BUTTON RULES
 * ------------
 *
 * 1. Active lane + countdown at zero:
 *      VALID HIT
 *      -> increment score
 *      -> flash LED
 *      -> remove note
 *
 * 2. Active lane + countdown above zero:
 *      EARLY PRESS
 *      -> remove note
 *      -> no score
 *
 * 3. Inactive lane:
 *      -> ignore press
 *
 *
 * ANTI-MASHING
 * ------------
 * top_level.sv converts the debounced button level into a one-cycle
 * button_edge pulse. Therefore holding a KEY does not repeatedly trigger
 * this FSM.
 */

module game_fsm (
    input  logic       clk,
    input  logic       reset,

    // One-cycle button press events.
    input  logic [3:0] button_edge,

    // Current lane status.
    input  logic [3:0] lane_active,
    input  logic [3:0] lane_zero,

    // New-note request.
    input  logic       spawn_valid,
    input  logic [1:0] spawn_lane,

    // Commands sent to each lane.
    output logic [3:0] lane_spawn,
    output logic [3:0] lane_clear,

    // Score events.
    output logic [3:0] valid_hit,

    // Successful-hit LED events.
    output logic [3:0] hit_pulse
);

    // Number of physical game lanes.
    localparam int NUM_LANES = 4;


    // ------------------------------------------------------------
    // FSM states
    // ------------------------------------------------------------

    typedef enum logic {
        RESET_STATE,
        PLAY_STATE
    } state_type;

    state_type current_state;
    state_type next_state;


    // ------------------------------------------------------------
    // Next-state logic
    // ------------------------------------------------------------

    always_comb begin

        // Stay in the current state unless a transition is required.
        next_state = current_state;

        case (current_state)

            RESET_STATE: begin
                if (!reset)
                    next_state = PLAY_STATE;
            end

            PLAY_STATE: begin
                if (reset)
                    next_state = RESET_STATE;
            end

            default: begin
                next_state = RESET_STATE;
            end

        endcase

    end


    // ------------------------------------------------------------
    // State register
    // ------------------------------------------------------------

    always_ff @(posedge clk) begin

        if (reset)
            current_state <= RESET_STATE;
        else
            current_state <= next_state;

    end


    // ------------------------------------------------------------
    // Game control outputs
    // ------------------------------------------------------------

    always_comb begin

        // Default: no action on any lane.
        lane_spawn = '0;
        lane_clear = '0;
        valid_hit  = '0;
        hit_pulse  = '0;


        // --------------------------------------------------------
        // Reset state
        // --------------------------------------------------------
        //
        // Clear all four lanes.

        if (current_state == RESET_STATE) begin

            lane_clear = '1;

        end


        // --------------------------------------------------------
        // Play state
        // --------------------------------------------------------

        else if (current_state == PLAY_STATE) begin


            // ----------------------------------------------------
            // Note spawning
            // ----------------------------------------------------
            //
            // Only spawn onto an empty lane. Existing notes are
            // therefore never overwritten.

            if (
                spawn_valid &&
                !lane_active[spawn_lane]
            ) begin

                lane_spawn[spawn_lane] = 1'b1;

            end


            // ----------------------------------------------------
            // Button handling
            // ----------------------------------------------------

            for (int i = 0; i < NUM_LANES; i = i + 1) begin

                if (button_edge[i]) begin


                    // --------------------------------------------
                    // Correct hit
                    // --------------------------------------------

                    if (
                        lane_active[i] &&
                        lane_zero[i]
                    ) begin

                        valid_hit[i]  = 1'b1;
                        hit_pulse[i]  = 1'b1;
                        lane_clear[i] = 1'b1;

                    end


                    // --------------------------------------------
                    // Early press
                    // --------------------------------------------
                    //
                    // Forfeit the active note but give no score.

                    else if (
                        lane_active[i] &&
                        !lane_zero[i]
                    ) begin

                        lane_clear[i] = 1'b1;

                    end


                    // Inactive-lane presses require no action.

                end
            end

        end

    end

endmodule