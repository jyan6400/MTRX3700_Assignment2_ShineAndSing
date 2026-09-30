`timescale 1ns/1ns

/*
 * timer.v
 *
 * PURPOSE
 * -------
 * Reused Reaction Time Game timer.
 *
 * Converts the FPGA clock into millisecond timing and can either count upward
 * from zero or downward from start_value.
 *
 * For Piano Tiles, top_level.sv uses this timer in DOWN mode. When it reaches
 * zero, top_level generates beat_tick and immediately resets the timer back to
 * BEAT_MS. This creates the common musical timing grid used by every lane.
 *
 * PARAMETERS
 * ----------
 * MAX_MS      : maximum representable timer value.
 * CLKS_PER_MS : number of FPGA clock cycles in one millisecond.
 *
 * At 50 MHz:
 *      CLKS_PER_MS = 50,000
 */

module timer #(
    parameter MAX_MS      = 2047,
    parameter CLKS_PER_MS = 50000
) (
    input                       clk,
    input                       reset,
    input                       up,
    input  [$clog2(MAX_MS)-1:0] start_value,
    input                       enable,
    output [$clog2(MAX_MS)-1:0] timer_value
);

    // Counts FPGA clock cycles within one millisecond.
    reg [$clog2(CLKS_PER_MS)-1:0] clk_count;

    // Millisecond timer value.
    reg [$clog2(MAX_MS)-1:0] ms_count;

    // Stores the selected count direction.
    reg count_up;


    // ------------------------------------------------------------
    // Timer state
    // ------------------------------------------------------------

    always @(posedge clk) begin

        if (reset) begin
            clk_count <= 0;

            // Up-count mode starts at zero.
            if (up) begin
                ms_count <= 0;
                count_up <= 1'b1;
            end

            // Down-count mode starts from start_value.
            else begin
                ms_count <= start_value;
                count_up <= 1'b0;
            end
        end

        else if (enable) begin

            // One millisecond has elapsed.
            if (clk_count >= CLKS_PER_MS - 1) begin
                clk_count <= 0;

                if (count_up)
                    ms_count <= ms_count + 1'b1;
                else
                    ms_count <= ms_count - 1'b1;
            end

            // Still counting FPGA clock cycles.
            else begin
                clk_count <= clk_count + 1'b1;
            end
        end

    end


    // Current millisecond count.
    assign timer_value = ms_count;

endmodule