`timescale 1ns/1ps

module game_video_cdc_tb;

    import assignment2_pkg::*;

    logic game_clk;
    logic pixel_clk;
    logic reset;

    logic [3:0] game_lane_active;
    logic [3:0] game_lane_hit_window;
    logic [3:0] game_lane_hit_pulse;

    logic [GAME_COUNT_W-1:0] game_lane_count [0:3];
    logic [SCORE_W-1:0]      game_score;

    logic source_busy;

    logic [3:0] video_lane_active;
    logic [3:0] video_lane_hit_window;
    logic [3:0] video_lane_hit_pulse;

    logic [GAME_COUNT_W-1:0] video_lane_count [0:3];
    logic [SCORE_W-1:0]      video_score;


    // ============================================================
    // DUT
    // ============================================================

    game_video_cdc DUT (
        .game_clk              (game_clk),
        .reset                 (reset),

        .game_lane_active      (game_lane_active),
        .game_lane_hit_window  (game_lane_hit_window),
        .game_lane_hit_pulse   (game_lane_hit_pulse),
        .game_lane_count       (game_lane_count),
        .game_score            (game_score),

        .source_busy           (source_busy),

        .pixel_clk             (pixel_clk),

        .video_lane_active     (video_lane_active),
        .video_lane_hit_window (video_lane_hit_window),
        .video_lane_hit_pulse  (video_lane_hit_pulse),
        .video_lane_count      (video_lane_count),
        .video_score           (video_score)
    );


    // ============================================================
    // Real clock relationship
    //
    // Game:  50 MHz -> 20 ns
    // Pixel: 25 MHz -> 40 ns
    // ============================================================

    initial game_clk = 1'b0;
    always #10 game_clk = ~game_clk;

    initial pixel_clk = 1'b0;
    always #20 pixel_clk = ~pixel_clk;


    // ============================================================
    // Helper
    // ============================================================

    task automatic wait_until_idle;
        integer timeout;
        begin
            timeout = 0;

            while (source_busy && timeout < 30) begin
                @(posedge game_clk);
                timeout = timeout + 1;
            end

            if (source_busy) begin
                $fatal(1, "FAIL: CDC remained busy too long");
            end
        end
    endtask


    task automatic wait_for_video_score(
        input logic [SCORE_W-1:0] expected
    );
        integer timeout;
        begin
            timeout = 0;

            while ((video_score !== expected) && timeout < 30) begin
                @(posedge pixel_clk);
                #1;
                timeout = timeout + 1;
            end

            if (video_score !== expected) begin
                $fatal(
                    1,
                    "FAIL: expected video_score=%0d got=%0d",
                    expected,
                    video_score
                );
            end
        end
    endtask


    // ============================================================
    // Count received hit pulses
    // ============================================================

    integer hit_event_count;

    always_ff @(posedge pixel_clk) begin
        if (reset)
            hit_event_count <= 0;
        else if (|video_lane_hit_pulse)
            hit_event_count <= hit_event_count + 1;
    end


    // ============================================================
    // Test
    // ============================================================

    initial begin

        reset                = 1'b1;

        game_lane_active     = 4'b0000;
        game_lane_hit_window = 4'b0000;
        game_lane_hit_pulse  = 4'b0000;

        game_score = '0;

        for (int i = 0; i < N_LANES; i = i + 1)
            game_lane_count[i] = '0;


        // --------------------------------------------------------
        // Reset
        // --------------------------------------------------------

        repeat (4) @(posedge game_clk);
        repeat (3) @(posedge pixel_clk);

        @(negedge game_clk);
        reset = 1'b0;


        // --------------------------------------------------------
        // TEST 1: transfer ordinary game state
        // --------------------------------------------------------

        @(negedge game_clk);

        game_lane_active     = 4'b0101;
        game_lane_hit_window = 4'b0001;

        game_lane_count[0] = 4'd3;
        game_lane_count[1] = 4'd6;
        game_lane_count[2] = 4'd9;
        game_lane_count[3] = 4'd12;

        game_score = 16'd7;

        wait_for_video_score(16'd7);

        if (video_lane_active !== 4'b0101)
            $fatal(
                1,
                "FAIL: lane_active expected 0101 got %b",
                video_lane_active
            );

        if (video_lane_hit_window !== 4'b0001)
            $fatal(
                1,
                "FAIL: lane_hit_window expected 0001 got %b",
                video_lane_hit_window
            );

        if (video_lane_count[0] !== 4'd3)
            $fatal(1, "FAIL: lane_count[0]");

        if (video_lane_count[1] !== 4'd6)
            $fatal(1, "FAIL: lane_count[1]");

        if (video_lane_count[2] !== 4'd9)
            $fatal(1, "FAIL: lane_count[2]");

        if (video_lane_count[3] !== 4'd12)
            $fatal(1, "FAIL: lane_count[3]");


        // --------------------------------------------------------
        // TEST 2: another snapshot
        // --------------------------------------------------------

        wait_until_idle();

        @(negedge game_clk);

        game_lane_active     = 4'b1010;
        game_lane_hit_window = 4'b1000;
        game_score           = 16'd19;

        game_lane_count[0] = 4'd8;
        game_lane_count[1] = 4'd4;
        game_lane_count[2] = 4'd2;
        game_lane_count[3] = 4'd0;

        wait_for_video_score(16'd19);

        if (video_lane_active !== 4'b1010)
            $fatal(1, "FAIL: second lane_active snapshot");

        if (video_lane_hit_window !== 4'b1000)
            $fatal(1, "FAIL: second hit-window snapshot");

        if (video_lane_count[0] !== 4'd8 ||
            video_lane_count[1] !== 4'd4 ||
            video_lane_count[2] !== 4'd2 ||
            video_lane_count[3] !== 4'd0)
            $fatal(1, "FAIL: second lane-count snapshot");


        // --------------------------------------------------------
        // TEST 3: lane hit event crosses CDC
        // --------------------------------------------------------

        wait_until_idle();

        @(negedge game_clk);

        game_lane_hit_pulse = 4'b0100;

        @(posedge game_clk);
        #1;

        @(negedge game_clk);

        game_lane_hit_pulse = 4'b0000;

        begin
            integer timeout;
            timeout = 0;

            while (
                (video_lane_hit_pulse !== 4'b0100) &&
                timeout < 30
            ) begin
                @(posedge pixel_clk);
                #1;
                timeout = timeout + 1;
            end

            if (video_lane_hit_pulse !== 4'b0100)
                $fatal(
                    1,
                    "FAIL: lane hit pulse did not cross CDC"
                );
        end


        // Must return to zero on next pixel clock.
        @(posedge pixel_clk);
        #1;

        if (video_lane_hit_pulse !== 4'b0000)
            $fatal(
                1,
                "FAIL: video_lane_hit_pulse must be one cycle"
            );


        // --------------------------------------------------------
        // TEST 4: hit occurs while previous snapshot is busy
        //
        // It must be remembered rather than lost.
        // --------------------------------------------------------

        wait_until_idle();

        @(negedge game_clk);

        game_score = 16'd25;

        // Allow the state change to begin a transaction.
        @(posedge game_clk);
        #1;

        // Generate a hit while transaction may still be busy.
        @(negedge game_clk);

        game_lane_hit_pulse = 4'b0010;

        @(posedge game_clk);
        #1;

        @(negedge game_clk);

        game_lane_hit_pulse = 4'b0000;

        // Score snapshot should arrive first/eventually.
        wait_for_video_score(16'd25);

        // Then pending hit must eventually arrive too.
        begin
            integer timeout;
            timeout = 0;

            while (
                (video_lane_hit_pulse !== 4'b0010) &&
                timeout < 40
            ) begin
                @(posedge pixel_clk);
                #1;
                timeout = timeout + 1;
            end

            if (video_lane_hit_pulse !== 4'b0010)
                $fatal(
                    1,
                    "FAIL: pending hit was lost while CDC busy"
                );
        end


        // --------------------------------------------------------
        // Finished
        // --------------------------------------------------------

        repeat (2) @(posedge pixel_clk);

        if (hit_event_count !== 2)
            $fatal(
                1,
                "FAIL: expected 2 video hit events, got %0d",
                hit_event_count
            );

        $display("ALL TESTS PASSED: game_video_cdc_tb");
        $finish;

    end

endmodule
