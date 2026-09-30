`timescale 1ns/1ps

/*
 * lane.sv
 *
 * PURPOSE
 * -------
 * Represents ONE of the four Piano Tiles countdown lanes.
 *
 * top_level.sv instantiates this module four times.
 *
 * A lane does not decide whether a player has scored. It only:
 *      - stores the current countdown value
 *      - decrements on each shared musical beat
 *      - reports when it has reached zero
 *      - holds zero for the hit window
 *      - removes a missed note once the hit window expires
 *
 * The scoring rules remain in game_fsm.sv.
 *
 *
 * NOTE LIFECYCLE
 * --------------
 *
 * inactive
 *    |
 *    | spawn
 *    v
 * countdown N
 *    |
 *    | beat ticks
 *    v
 * countdown 0
 *    |
 *    | HIT_WINDOW_TICKS
 *    v
 * expired / inactive
 *
 *
 * PRIORITY
 * --------
 * reset > clear > spawn > tick
 *
 *
 * LIVE-CHANGE PARAMETER
 * ---------------------
 * HIT_WINDOW_TICKS controls how many musical ticks the player has while the
 * lane displays zero.
 */

module lane #(
    parameter int HIT_WINDOW_TICKS = 1
) (
    input  logic       clk,
    input  logic       reset,

    // Shared beat pulse generated in top_level.sv.
    input  logic       tick,

    // Commands from game_fsm.sv.
    input  logic       spawn,
    input  logic [3:0] start_value,
    input  logic       clear,

    // Lane status returned to game_fsm.sv.
    output logic       active,
    output logic       at_zero,
    output logic       expired,

    // Value sent to the corresponding HEX display.
    output logic [3:0] display_value
);

    // ------------------------------------------------------------
    // Named constants
    // ------------------------------------------------------------

    localparam logic [3:0] COUNT_ZERO  = 4'd0;
    localparam logic [3:0] COUNT_STEP  = 4'd1;

    // seven_seg.v blanks any value outside decimal 0-9.
    localparam logic [3:0] BLANK_DIGIT = 4'hF;

    // Prevent a zero-width vector when HIT_WINDOW_TICKS = 1.
    localparam int WINDOW_WIDTH =
        (HIT_WINDOW_TICKS < 2) ? 1 : $clog2(HIT_WINDOW_TICKS);

    // Final counter value before the hit window expires.
    localparam logic [WINDOW_WIDTH-1:0] WINDOW_MAX =
        WINDOW_WIDTH'(HIT_WINDOW_TICKS - 1);


    // ------------------------------------------------------------
    // Lane registers
    // ------------------------------------------------------------

    // Current countdown displayed to the player.
    logic [3:0] count;

    // Number of beat ticks spent at zero.
    logic [WINDOW_WIDTH-1:0] window;


    // ------------------------------------------------------------
    // Lane sequential logic
    // ------------------------------------------------------------

    always_ff @(posedge clk) begin

        // expired is a one-cycle event pulse.
        expired <= 1'b0;


        // --------------------------------------------------------
        // Reset
        // --------------------------------------------------------

        if (reset) begin
            active <= 1'b0;
            count  <= COUNT_ZERO;
            window <= '0;
        end


        // --------------------------------------------------------
        // Clear
        // --------------------------------------------------------
        //
        // game_fsm clears the note after:
        //      - a valid hit, or
        //      - an early press.

        else if (clear) begin
            active <= 1'b0;
            count  <= COUNT_ZERO;
            window <= '0;
        end


        // --------------------------------------------------------
        // Spawn
        // --------------------------------------------------------
        //
        // Never overwrite a note that is already active.

        else if (spawn && !active) begin
            active <= 1'b1;
            count  <= start_value;
            window <= '0;
        end


        // --------------------------------------------------------
        // Musical beat tick
        // --------------------------------------------------------

        else if (tick && active) begin

            // Note is still counting toward zero.
            if (count != COUNT_ZERO) begin
                count <= count - COUNT_STEP;
            end

            // Note is currently at zero.
            else begin

                // Player failed to hit within the allowed window.
                if (window == WINDOW_MAX) begin
                    active  <= 1'b0;
                    window  <= '0;
                    expired <= 1'b1;
                end

                // Continue holding the zero hit window.
                else begin
                    window <= window + 1'b1;
                end

            end
        end
    end


    // ------------------------------------------------------------
    // Combinational lane outputs
    // ------------------------------------------------------------

    always_comb begin

        // A valid hit is possible only when an active note is at zero.
        at_zero =
            active &&
            (count == COUNT_ZERO);

        // Inactive lanes display nothing.
        display_value =
            active ? count : BLANK_DIGIT;

    end

endmodule