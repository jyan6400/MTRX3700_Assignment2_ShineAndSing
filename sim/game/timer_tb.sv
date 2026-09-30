`timescale 1ns/1ps

module timer_tb;

    localparam int MAX_MS      = 16;
    localparam int CLKS_PER_MS = 2;
    localparam int TIMER_WIDTH = $clog2(MAX_MS);

    logic clk;
    logic reset;
    logic up;
    logic enable;

    logic [TIMER_WIDTH-1:0] start_value;
    logic [TIMER_WIDTH-1:0] timer_value;


    timer #(
        .MAX_MS(MAX_MS),
        .CLKS_PER_MS(CLKS_PER_MS)
    ) DUT (
        .clk(clk),
        .reset(reset),
        .up(up),
        .start_value(start_value),
        .enable(enable),
        .timer_value(timer_value)
    );


    // ---------------------------------------------------------------------
    // Clock
    // ---------------------------------------------------------------------

    initial clk = 1'b0;
    always #5 clk <= ~clk;


    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    task automatic step;
        begin

            @(posedge clk);
            #1;

        end
    endtask


    task automatic check_value (
        input logic [TIMER_WIDTH-1:0] expected,
        input string                  what
    );
        begin

            if (timer_value !== expected)
                $fatal(
                    1,
                    "FAIL [%s]: expected timer_value=%0d actual=%0d at t=%0t",
                    what,
                    expected,
                    timer_value,
                    $time
                );

        end
    endtask


    initial begin

        if ($test$plusargs("dump")) begin
            $dumpfile("waveform.fst");
            $dumpvars(0, timer_tb);
        end

        reset       = 1'b1;
        up          = 1'b0;
        enable      = 1'b1;
        start_value = 4'd5;


        // ================================================================
        // TEST 1
        // Down-count mode reset loads start_value.
        // ================================================================

        step();

        check_value(
            4'd5,
            "TEST1 reset load"
        );

        step();

        check_value(
            4'd5,
            "TEST1 reset hold"
        );


        // ================================================================
        // TEST 2
        // With CLKS_PER_MS=2, the countdown changes only after
        // two enabled clock edges.
        // ================================================================

        reset = 1'b0;

        step();

        check_value(
            4'd5,
            "TEST2 decrement too early"
        );

        step();

        check_value(
            4'd4,
            "TEST2 first decrement"
        );

        step();

        check_value(
            4'd4,
            "TEST2 second decrement too early"
        );

        step();

        check_value(
            4'd3,
            "TEST2 second decrement"
        );


        // ================================================================
        // TEST 3
        // enable=0 freezes both timer and partial prescaler.
        // ================================================================

        // First clock of the next two-clock interval.

        step();

        check_value(
            4'd3,
            "TEST3 before pause"
        );


        enable = 1'b0;

        repeat (5) begin

            step();

            check_value(
                4'd3,
                "TEST3 disabled"
            );

        end


        enable = 1'b1;

        // The preserved partial count means one more enabled edge
        // completes the interval.

        step();

        check_value(
            4'd2,
            "TEST3 resume"
        );


        // ================================================================
        // TEST 4
        // Reset loads a different down-count start value.
        // ================================================================

        start_value = 4'd7;
        up          = 1'b0;
        reset       = 1'b1;

        step();

        check_value(
            4'd7,
            "TEST4 reload"
        );


        reset = 1'b0;

        step();

        check_value(
            4'd7,
            "TEST4 decrement too early"
        );

        step();

        check_value(
            4'd6,
            "TEST4 decrement"
        );


        // ================================================================
        // TEST 5
        // Up-count mode starts from zero on reset.
        //
        // start_value is intentionally set to 9 here to prove it is
        // not loaded when up=1.
        // ================================================================

        up          = 1'b1;
        start_value = 4'd9;
        reset       = 1'b1;

        step();

        check_value(
            4'd0,
            "TEST5 up reset starts at zero"
        );

        step();

        check_value(
            4'd0,
            "TEST5 up reset holds zero"
        );


        // ================================================================
        // TEST 6
        // Up-count increments every CLKS_PER_MS clocks.
        // ================================================================

        reset = 1'b0;

        step();

        check_value(
            4'd0,
            "TEST6 increment too early"
        );

        step();

        check_value(
            4'd1,
            "TEST6 first increment"
        );

        step();

        check_value(
            4'd1,
            "TEST6 second increment too early"
        );

        step();

        check_value(
            4'd2,
            "TEST6 second increment"
        );


        // ================================================================
        // TEST 7
        // The direction is captured during reset.
        //
        // Changing up without reset must not change the currently
        // selected direction.
        // ================================================================

        up = 1'b0;

        step();

        check_value(
            4'd2,
            "TEST7 count changed too early"
        );

        step();

        check_value(
            4'd3,
            "TEST7 direction changed without reset"
        );


        // ================================================================
        // TEST 8
        // Reset again with up=0 returns to down-count mode.
        // ================================================================

        start_value = 4'd3;
        up          = 1'b0;
        reset       = 1'b1;

        step();

        check_value(
            4'd3,
            "TEST8 down reset"
        );


        reset = 1'b0;

        step();

        check_value(
            4'd3,
            "TEST8 decrement too early"
        );

        step();

        check_value(
            4'd2,
            "TEST8 down-count"
        );


        $display("ALL TESTS PASSED: timer_tb");
        $finish;

    end

endmodule