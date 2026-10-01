`timescale 1ns/1ps

module game_subsystem_tb;

    import assignment2_pkg::*;

    // ============================================================
    // Clock / reset
    // ============================================================

    logic clk;
    logic reset;

    always #5 clk = ~clk;


    // ============================================================
    // Classifier-side stimulus
    // ============================================================

    logic       vowel_valid;
    logic [1:0] vowel_id;

    logic [3:0] vowel_lane_valid;


    // ============================================================
    // Game control
    // ============================================================

    logic       spawn_valid;
    logic [1:0] spawn_lane;
    logic [3:0] start_value;

    logic tick;

    logic [3:0] lane_spawn;
    logic [3:0] lane_clear;

    logic [3:0] valid_hit;
    logic [3:0] hit_pulse;


    // ============================================================
    // Lane status
    // ============================================================

    logic [3:0] lane_active;
    logic [3:0] lane_zero;
    logic [3:0] lane_expired;

    logic [3:0] lane_display [0:3];


    // ============================================================
    // Score
    // ============================================================

    logic [6:0] score_value;


    // ============================================================
    // Vowel -> lane mapper
    // ============================================================

    vowel_hit_mapper u_vowel_hit_mapper (
        .vowel_valid      (vowel_valid),
        .vowel_id         (vowel_id),
        .vowel_lane_valid (vowel_lane_valid)
    );


    // ============================================================
    // Game FSM
    //
    // The existing A1 button_edge input is driven by the new
    // A2 vowel mapper. This lets us reuse game_fsm unchanged.
    // ============================================================

    game_fsm u_game_fsm (
        .clk         (clk),
        .reset       (reset),

        .button_edge (vowel_lane_valid),

        .lane_active (lane_active),
        .lane_zero   (lane_zero),

        .spawn_valid (spawn_valid),
        .spawn_lane  (spawn_lane),

        .lane_spawn  (lane_spawn),
        .lane_clear  (lane_clear),

        .valid_hit   (valid_hit),
        .hit_pulse   (hit_pulse)
    );


    // ============================================================
    // Four game lanes
    //
    // Use a short two-tick hit window for simulation.
    // ============================================================

    genvar i;

    generate
        for (i = 0; i < N_LANES; i = i + 1) begin : GEN_LANES

            lane #(
                .HIT_WINDOW_TICKS(2)
            ) u_lane (
                .clk           (clk),
                .reset         (reset),

                .tick          (tick),

                .spawn         (lane_spawn[i]),
                .start_value   (start_value),
                .clear         (lane_clear[i]),

                .active        (lane_active[i]),
                .at_zero       (lane_zero[i]),
                .expired       (lane_expired[i]),

                .display_value (lane_display[i])
            );

        end
    endgenerate


    // ============================================================
    // Score
    // ============================================================

    score u_score (
        .clk       (clk),
        .reset     (reset),
        .valid_hit (valid_hit),
        .score     (score_value)
    );


    // ============================================================
    // Helper task: check condition
    // ============================================================

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            if (!condition) begin
                $fatal(1, "FAIL: %s", message);
            end
        end
    endtask


    // ============================================================
    // Helper task: spawn note
    // ============================================================

    task automatic spawn_note(
        input logic [1:0] lane_id
    );
        begin
            @(negedge clk);

            spawn_lane  = lane_id;
            spawn_valid = 1'b1;

            @(posedge clk);
            #1;

            @(negedge clk);

            spawn_valid = 1'b0;
        end
    endtask


    // ============================================================
    // Helper task: musical tick
    // ============================================================

    task automatic beat_tick;
        begin
            @(negedge clk);

            tick = 1'b1;

            @(posedge clk);
            #1;

            @(negedge clk);

            tick = 1'b0;
        end
    endtask


    // ============================================================
    // Helper task: send classifier result
    // ============================================================

    task automatic send_vowel(
        input logic [1:0] id
    );
        begin
            @(negedge clk);

            vowel_id    = id;
            vowel_valid = 1'b1;

            // Allow combinational mapper/FSM outputs to settle.
            #1;

            @(posedge clk);
            #1;

            @(negedge clk);

            vowel_valid = 1'b0;
        end
    endtask


    // ============================================================
    // Test sequence
    // ============================================================

    initial begin

        clk          = 1'b0;
        reset        = 1'b1;

        vowel_valid  = 1'b0;
        vowel_id     = VOWEL_EE;

        spawn_valid  = 1'b0;
        spawn_lane   = 2'd0;

        start_value  = 4'd1;

        tick         = 1'b0;


        // --------------------------------------------------------
        // Reset
        // --------------------------------------------------------

        repeat (2) @(posedge clk);

        @(negedge clk);
        reset = 1'b0;

        // Allow game_fsm to enter PLAY_STATE.
        repeat (2) @(posedge clk);
        #1;

        check(
            lane_active == 4'b0000,
            "all lanes should be inactive after reset"
        );

        check(
            score_value == 7'd0,
            "score should start at zero"
        );


        // --------------------------------------------------------
        // TEST 1
        // ee -> lane 0
        // --------------------------------------------------------

        start_value = 4'd1;

        spawn_note(2'd0);

        check(
            lane_active[0],
            "lane 0 should become active"
        );

        beat_tick();

        check(
            lane_zero[0],
            "lane 0 should be in hit window"
        );

        send_vowel(VOWEL_EE);

        check(
            score_value == 7'd1,
            "ee hit on lane 0 should increase score to 1"
        );

        check(
            !lane_active[0],
            "lane 0 should clear after successful hit"
        );


        // --------------------------------------------------------
        // TEST 2
        // ah -> lane 1
        // --------------------------------------------------------

        spawn_note(2'd1);
        beat_tick();

        check(
            lane_zero[1],
            "lane 1 should be in hit window"
        );

        send_vowel(VOWEL_AH);

        check(
            score_value == 7'd2,
            "ah hit on lane 1 should increase score to 2"
        );

        check(
            !lane_active[1],
            "lane 1 should clear after successful hit"
        );


        // --------------------------------------------------------
        // TEST 3
        // oo -> lane 2
        // --------------------------------------------------------

        spawn_note(2'd2);
        beat_tick();

        check(
            lane_zero[2],
            "lane 2 should be in hit window"
        );

        send_vowel(VOWEL_OO);

        check(
            score_value == 7'd3,
            "oo hit on lane 2 should increase score to 3"
        );

        check(
            !lane_active[2],
            "lane 2 should clear after successful hit"
        );


        // --------------------------------------------------------
        // TEST 4
        // aw -> lane 3
        // --------------------------------------------------------

        spawn_note(2'd3);
        beat_tick();

        check(
            lane_zero[3],
            "lane 3 should be in hit window"
        );

        send_vowel(VOWEL_AW);

        check(
            score_value == 7'd4,
            "aw hit on lane 3 should increase score to 4"
        );

        check(
            !lane_active[3],
            "lane 3 should clear after successful hit"
        );


        // --------------------------------------------------------
        // TEST 5
        // Wrong vowel must not score.
        //
        // Lane 0 expects ee, but classifier reports ah.
        // --------------------------------------------------------

        spawn_note(2'd0);
        beat_tick();

        check(
            lane_zero[0],
            "lane 0 should be in hit window before wrong-vowel test"
        );

        send_vowel(VOWEL_AH);

        check(
            score_value == 7'd4,
            "wrong vowel must not increase score"
        );

        check(
            lane_active[0],
            "wrong vowel for another lane should not clear lane 0"
        );

        // Now hit the same note correctly.
        send_vowel(VOWEL_EE);

        check(
            score_value == 7'd5,
            "correct vowel after wrong vowel should score"
        );

        check(
            !lane_active[0],
            "lane 0 should clear after correct vowel"
        );


        // --------------------------------------------------------
        // TEST 6
        // Correct vowel outside hit window must not score.
        //
        // Existing A1 game behaviour also clears an early note.
        // --------------------------------------------------------

        start_value = 4'd2;

        spawn_note(2'd2);

        check(
            lane_active[2],
            "lane 2 should be active for early-hit test"
        );

        check(
            !lane_zero[2],
            "lane 2 should not yet be in hit window"
        );

        send_vowel(VOWEL_OO);

        check(
            score_value == 7'd5,
            "correct vowel outside hit window must not score"
        );

        check(
            !lane_active[2],
            "current A1 behaviour should clear an early-hit note"
        );


        // --------------------------------------------------------
        // TEST 7
        // Silence / no valid classifier result must do nothing.
        // --------------------------------------------------------

        start_value = 4'd1;

        spawn_note(2'd1);
        beat_tick();

        check(
            lane_zero[1],
            "lane 1 should be ready for silence test"
        );

        repeat (3) @(posedge clk);
        #1;

        check(
            score_value == 7'd5,
            "no vowel_valid event must not change score"
        );

        check(
            lane_active[1],
            "no vowel_valid event must not clear active lane"
        );

        // Clear it with the correct vowel before next test.
        send_vowel(VOWEL_AH);

        check(
            score_value == 7'd6,
            "correct vowel should score after silence test"
        );


        // --------------------------------------------------------
        // TEST 8
        // Missed note expires after its hit window.
        // --------------------------------------------------------

        start_value = 4'd0;

        spawn_note(2'd3);

        check(
            lane_zero[3],
            "lane 3 should immediately enter hit window"
        );

        // HIT_WINDOW_TICKS = 2.
        beat_tick();

        check(
            lane_active[3],
            "lane 3 should remain active during first hit-window tick"
        );

        beat_tick();

        check(
            !lane_active[3],
            "lane 3 should expire after hit window"
        );

        check(
            lane_expired[3],
            "lane 3 should assert expired pulse"
        );

        check(
            score_value == 7'd6,
            "expired note must not increase score"
        );


        // --------------------------------------------------------
        // Finished
        // --------------------------------------------------------

        $display("ALL TESTS PASSED: game_subsystem_tb");
        $finish;

    end

endmodule
