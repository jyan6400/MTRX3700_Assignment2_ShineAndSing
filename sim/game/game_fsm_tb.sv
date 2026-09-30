`timescale 1ns/1ps

module game_fsm_tb;

    logic clk;
    logic reset;

    logic [3:0] button_edge;
    logic [3:0] lane_active;
    logic [3:0] lane_zero;

    logic       spawn_valid;
    logic [1:0] spawn_lane;

    logic [3:0] lane_spawn;
    logic [3:0] lane_clear;
    logic [3:0] valid_hit;
    logic [3:0] hit_pulse;


    // ---------------------------------------------------------------------
    // DUT
    // ---------------------------------------------------------------------

    game_fsm DUT (
        .clk(clk),
        .reset(reset),

        .button_edge(button_edge),

        .lane_active(lane_active),
        .lane_zero(lane_zero),

        .spawn_valid(spawn_valid),
        .spawn_lane(spawn_lane),

        .lane_spawn(lane_spawn),
        .lane_clear(lane_clear),

        .valid_hit(valid_hit),
        .hit_pulse(hit_pulse)
    );


    // ---------------------------------------------------------------------
    // Clock
    // ---------------------------------------------------------------------

    initial clk = 1'b0;
    always #5 clk <= ~clk;


    // ---------------------------------------------------------------------
    // Check outputs
    // ---------------------------------------------------------------------

    task automatic check_outputs (
        input logic [3:0] expected_spawn,
        input logic [3:0] expected_clear,
        input logic [3:0] expected_hit,
        input logic [3:0] expected_led,
        input string      what
    );
        begin

            if (lane_spawn !== expected_spawn)
                $fatal(
                    1,
                    "FAIL [%s] lane_spawn: expected=%b actual=%b",
                    what,
                    expected_spawn,
                    lane_spawn
                );

            if (lane_clear !== expected_clear)
                $fatal(
                    1,
                    "FAIL [%s] lane_clear: expected=%b actual=%b",
                    what,
                    expected_clear,
                    lane_clear
                );

            if (valid_hit !== expected_hit)
                $fatal(
                    1,
                    "FAIL [%s] valid_hit: expected=%b actual=%b",
                    what,
                    expected_hit,
                    valid_hit
                );

            if (hit_pulse !== expected_led)
                $fatal(
                    1,
                    "FAIL [%s] hit_pulse: expected=%b actual=%b",
                    what,
                    expected_led,
                    hit_pulse
                );

        end
    endtask


    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    initial begin

        if ($test$plusargs("dump")) begin
            $dumpfile("waveform.fst");
            $dumpvars(0, game_fsm_tb);
        end

        reset       = 1'b1;
        button_edge = 4'b0000;

        lane_active = 4'b0000;
        lane_zero   = 4'b0000;

        spawn_valid = 1'b0;
        spawn_lane  = 2'b00;


        // ================================================================
        // TEST 1
        // Reset clears all lanes.
        // ================================================================

        repeat (2) @(posedge clk);
        #1;

        check_outputs(
            4'b0000,
            4'b1111,
            4'b0000,
            4'b0000,
            "TEST1 reset"
        );


        // Leave reset.

        reset = 1'b0;

        @(posedge clk);
        #1;


        // ================================================================
        // TEST 2
        // Spawn lane 2.
        // ================================================================

        spawn_valid = 1'b1;
        spawn_lane  = 2'd2;
        lane_active = 4'b0000;

        #1;

        check_outputs(
            4'b0100,
            4'b0000,
            4'b0000,
            4'b0000,
            "TEST2 spawn"
        );

        spawn_valid = 1'b0;


        // ================================================================
        // TEST 3
        // Cannot spawn into an already-active lane.
        // ================================================================

        lane_active = 4'b0100;

        spawn_valid = 1'b1;
        spawn_lane  = 2'd2;

        #1;

        check_outputs(
            4'b0000,
            4'b0000,
            4'b0000,
            4'b0000,
            "TEST3 occupied lane"
        );

        spawn_valid = 1'b0;


        // ================================================================
        // TEST 4
        // Correct hit on lane 2.
        // ================================================================

        lane_active = 4'b0100;
        lane_zero   = 4'b0100;
        button_edge = 4'b0100;

        #1;

        check_outputs(
            4'b0000,
            4'b0100,
            4'b0100,
            4'b0100,
            "TEST4 valid hit"
        );

        button_edge = 4'b0000;
        #1;


        // ================================================================
        // TEST 5
        // Early press forfeits the active note but does not score.
        // ================================================================

        lane_active = 4'b0010;
        lane_zero   = 4'b0000;
        button_edge = 4'b0010;

        #1;

        check_outputs(
            4'b0000,
            4'b0010,
            4'b0000,
            4'b0000,
            "TEST5 early press"
        );

        button_edge = 4'b0000;
        #1;


        // ================================================================
        // TEST 6
        // Pressing an inactive lane does nothing.
        // ================================================================

        lane_active = 4'b0000;
        lane_zero   = 4'b0000;
        button_edge = 4'b0001;

        #1;

        check_outputs(
            4'b0000,
            4'b0000,
            4'b0000,
            4'b0000,
            "TEST6 inactive press"
        );

        button_edge = 4'b0000;
        #1;


        // ================================================================
        // TEST 7
        // Two simultaneous valid hits.
        // ================================================================

        lane_active = 4'b1001;
        lane_zero   = 4'b1001;
        button_edge = 4'b1001;

        #1;

        check_outputs(
            4'b0000,
            4'b1001,
            4'b1001,
            4'b1001,
            "TEST7 simultaneous hits"
        );

        button_edge = 4'b0000;
        #1;


        // ================================================================
        // TEST 8
        // Mixed simultaneous presses:
        // lane 3 valid, lane 2 early, lane 1 inactive.
        // ================================================================

        lane_active = 4'b1100;
        lane_zero   = 4'b1000;
        button_edge = 4'b1110;

        #1;

        check_outputs(
            4'b0000,
            4'b1100,
            4'b1000,
            4'b1000,
            "TEST8 mixed presses"
        );

        button_edge = 4'b0000;
        #1;


        // ================================================================
        // TEST 9
        // Reset during gameplay.
        // ================================================================

        reset = 1'b1;

        @(posedge clk);
        #1;

        check_outputs(
            4'b0000,
            4'b1111,
            4'b0000,
            4'b0000,
            "TEST9 gameplay reset"
        );


        $display("ALL TESTS PASSED: game_fsm_tb");
        $finish;

    end

endmodule