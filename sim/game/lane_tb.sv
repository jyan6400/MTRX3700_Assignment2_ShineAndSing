`timescale 1ns/1ps

module lane_tb;

    localparam logic [3:0] BLANK = 4'hF;

    logic clk;
    logic reset;
    logic tick;

    logic [1:0] spawn;
    logic [1:0] clear;

    logic [3:0] start_val0;
    logic [3:0] start_val1;

    logic [1:0] active;
    logic [1:0] at_zero;
    logic [1:0] expired;

    logic [3:0] disp0;
    logic [3:0] disp1;


    // ---------------------------------------------------------------------
    // Two instances with different hit-window lengths.
    // ---------------------------------------------------------------------

    lane #(
        .HIT_WINDOW_TICKS(1)
    ) DUT0 (
        .clk(clk),
        .reset(reset),
        .tick(tick),
        .spawn(spawn[0]),
        .start_value(start_val0),
        .clear(clear[0]),
        .active(active[0]),
        .at_zero(at_zero[0]),
        .expired(expired[0]),
        .display_value(disp0)
    );


    lane #(
        .HIT_WINDOW_TICKS(3)
    ) DUT1 (
        .clk(clk),
        .reset(reset),
        .tick(tick),
        .spawn(spawn[1]),
        .start_value(start_val1),
        .clear(clear[1]),
        .active(active[1]),
        .at_zero(at_zero[1]),
        .expired(expired[1]),
        .display_value(disp1)
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


    task automatic beat;
        begin
            tick = 1'b1;

            @(posedge clk);
            #1;

            tick = 1'b0;
        end
    endtask


    task automatic do_spawn (
        input integer     idx,
        input logic [3:0] value
    );
        begin

            if (idx == 0) begin
                start_val0 = value;
                spawn[0]   = 1'b1;
            end
            else begin
                start_val1 = value;
                spawn[1]   = 1'b1;
            end

            @(posedge clk);
            #1;

            spawn = 2'b00;

        end
    endtask


    task automatic do_clear (
        input integer idx
    );
        begin

            clear[idx] = 1'b1;

            @(posedge clk);
            #1;

            clear = 2'b00;

        end
    endtask


    task automatic check_lane (
        input integer     idx,
        input logic       expected_active,
        input logic       expected_zero,
        input logic [3:0] expected_display,
        input string      what
    );

        logic [3:0] actual_display;

        begin

            actual_display = (idx == 0) ? disp0 : disp1;

            if (active[idx] !== expected_active)
                $fatal(
                    1,
                    "FAIL [%s] lane%0d active: expected=%b actual=%b",
                    what,
                    idx,
                    expected_active,
                    active[idx]
                );

            if (at_zero[idx] !== expected_zero)
                $fatal(
                    1,
                    "FAIL [%s] lane%0d at_zero: expected=%b actual=%b",
                    what,
                    idx,
                    expected_zero,
                    at_zero[idx]
                );

            if (actual_display !== expected_display)
                $fatal(
                    1,
                    "FAIL [%s] lane%0d display: expected=%h actual=%h",
                    what,
                    idx,
                    expected_display,
                    actual_display
                );

        end
    endtask


    task automatic check_expired (
        input integer idx,
        input logic   expected,
        input string  what
    );
        begin

            if (expired[idx] !== expected)
                $fatal(
                    1,
                    "FAIL [%s] lane%0d expired: expected=%b actual=%b",
                    what,
                    idx,
                    expected,
                    expired[idx]
                );

        end
    endtask


    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    integer i;

    initial begin

        if ($test$plusargs("dump")) begin
            $dumpfile("waveform.fst");
            $dumpvars(0, lane_tb);
        end

        reset      = 1'b1;
        tick       = 1'b0;
        spawn      = 2'b00;
        clear      = 2'b00;
        start_val0 = 4'd0;
        start_val1 = 4'd0;


        // ================================================================
        // TEST 1
        // Reset makes both lanes inactive and blank.
        // ================================================================

        repeat (2) step();

        check_lane(0, 1'b0, 1'b0, BLANK, "TEST1 lane0 reset");
        check_lane(1, 1'b0, 1'b0, BLANK, "TEST1 lane1 reset");

        reset = 1'b0;
        step();


        // ================================================================
        // TEST 2
        // Beats on an inactive lane do nothing.
        // ================================================================

        repeat (3) beat();

        check_lane(0, 1'b0, 1'b0, BLANK, "TEST2 idle lane");
        check_expired(0, 1'b0, "TEST2 idle expiry");


        // ================================================================
        // TEST 3
        // Countdown 3 -> 2 -> 1 -> 0.
        // ================================================================

        do_spawn(0, 4'd3);

        check_lane(0, 1'b1, 1'b0, 4'd3, "TEST3 spawn");

        beat();
        check_lane(0, 1'b1, 1'b0, 4'd2, "TEST3 value 2");

        beat();
        check_lane(0, 1'b1, 1'b0, 4'd1, "TEST3 value 1");

        beat();
        check_lane(0, 1'b1, 1'b1, 4'd0, "TEST3 value 0");

        check_expired(0, 1'b0, "TEST3 premature expiry");


        // ================================================================
        // TEST 4
        // HIT_WINDOW_TICKS=1 expires on the next beat.
        // ================================================================

        beat();

        check_expired(0, 1'b1, "TEST4 expiry pulse");
        check_lane(0, 1'b0, 1'b0, BLANK, "TEST4 expired lane");


        // ================================================================
        // TEST 5
        // expired is one cycle wide.
        // ================================================================

        step();

        check_expired(0, 1'b0, "TEST5 expiry pulse width");


        // ================================================================
        // TEST 6
        // clear removes a note without producing expired.
        // ================================================================

        do_spawn(0, 4'd5);

        beat();
        beat();

        check_lane(0, 1'b1, 1'b0, 4'd3, "TEST6 before clear");

        do_clear(0);

        check_lane(0, 1'b0, 1'b0, BLANK, "TEST6 after clear");
        check_expired(0, 1'b0, "TEST6 clear expiry");


        // ================================================================
        // TEST 7
        // Spawn while active must not overwrite current note.
        // ================================================================

        do_spawn(0, 4'd4);

        beat();

        check_lane(0, 1'b1, 1'b0, 4'd3, "TEST7 before second spawn");

        do_spawn(0, 4'd9);

        check_lane(0, 1'b1, 1'b0, 4'd3, "TEST7 ignored spawn");

        do_clear(0);


        // ================================================================
        // TEST 8
        // start_value=0 enters the hit window immediately.
        // ================================================================

        do_spawn(0, 4'd0);

        check_lane(0, 1'b1, 1'b1, 4'd0, "TEST8 zero start");

        beat();

        check_lane(0, 1'b0, 1'b0, BLANK, "TEST8 zero expiry");
        check_expired(0, 1'b1, "TEST8 expiry pulse");

        step();


        // ================================================================
        // TEST 9
        // Two lanes hold independent state.
        // ================================================================

        do_spawn(0, 4'd2);
        do_spawn(1, 4'd5);

        check_lane(0, 1'b1, 1'b0, 4'd2, "TEST9 lane0 spawn");
        check_lane(1, 1'b1, 1'b0, 4'd5, "TEST9 lane1 spawn");

        beat();

        check_lane(0, 1'b1, 1'b0, 4'd1, "TEST9 lane0 beat1");
        check_lane(1, 1'b1, 1'b0, 4'd4, "TEST9 lane1 beat1");

        beat();

        check_lane(0, 1'b1, 1'b1, 4'd0, "TEST9 lane0 zero");
        check_lane(1, 1'b1, 1'b0, 4'd3, "TEST9 lane1 beat2");

        beat();

        check_lane(0, 1'b0, 1'b0, BLANK, "TEST9 lane0 expired");
        check_lane(1, 1'b1, 1'b0, 4'd2, "TEST9 lane1 independent");

        check_expired(1, 1'b0, "TEST9 lane1 expiry");

        do_clear(1);


        // ================================================================
        // TEST 10
        // DUT1 uses HIT_WINDOW_TICKS=3.
        // ================================================================

        do_spawn(1, 4'd1);

        beat();

        check_lane(1, 1'b1, 1'b1, 4'd0, "TEST10 window opens");

        for (i = 0; i < 2; i = i + 1) begin

            beat();

            check_lane(
                1,
                1'b1,
                1'b1,
                4'd0,
                "TEST10 window remains open"
            );

            check_expired(
                1,
                1'b0,
                "TEST10 premature expiry"
            );

        end

        beat();

        check_lane(
            1,
            1'b0,
            1'b0,
            BLANK,
            "TEST10 window closes"
        );

        check_expired(
            1,
            1'b1,
            "TEST10 final expiry"
        );

        step();


        // ================================================================
        // TEST 11
        // Reset clears active notes on both lanes.
        // ================================================================

        do_spawn(0, 4'd6);
        do_spawn(1, 4'd7);

        beat();

        check_lane(0, 1'b1, 1'b0, 4'd5, "TEST11 lane0 pre-reset");
        check_lane(1, 1'b1, 1'b0, 4'd6, "TEST11 lane1 pre-reset");

        reset = 1'b1;
        step();

        check_lane(0, 1'b0, 1'b0, BLANK, "TEST11 lane0 reset");
        check_lane(1, 1'b0, 1'b0, BLANK, "TEST11 lane1 reset");


        $display("ALL TESTS PASSED: lane_tb");
        $finish;

    end

endmodule