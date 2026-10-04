`timescale 1ns/1ps

module top_level_tb;

    // ============================================================
    // Board inputs
    // ============================================================

    logic       CLOCK_50;
    logic [3:0] KEY;
    logic [9:0] SW;

    logic AUD_ADCDAT;
    logic AUD_ADCLRCK;
    logic AUD_BCLK;


    // ============================================================
    // Board outputs
    // ============================================================

    logic AUD_DACDAT;
    logic AUD_XCK;

    logic FPGA_I2C_SCLK;
    tri   FPGA_I2C_SDAT;

    logic [7:0] VGA_R;
    logic [7:0] VGA_G;
    logic [7:0] VGA_B;

    logic VGA_CLK;
    logic VGA_HS;
    logic VGA_VS;
    logic VGA_BLANK_N;
    logic VGA_SYNC_N;

    logic [9:0] LEDR;

    logic [6:0] HEX0;
    logic [6:0] HEX1;
    logic [6:0] HEX2;
    logic [6:0] HEX3;
    logic [6:0] HEX4;
    logic [6:0] HEX5;

    integer audio_frame_count;
    integer video_frame_count;


    // ============================================================
    // DUT
    // ============================================================

    top_level #(
        .VIDEO_IMG_W (320),
        .VIDEO_IMG_H (240),
        .VIDEO_VGA_W (32),
        .VIDEO_VGA_H (24)
    ) DUT (
        .CLOCK_50      (CLOCK_50),
        .KEY           (KEY),
        .SW            (SW),

        .AUD_ADCDAT    (AUD_ADCDAT),
        .AUD_ADCLRCK   (AUD_ADCLRCK),
        .AUD_BCLK      (AUD_BCLK),

        .AUD_DACDAT    (AUD_DACDAT),
        .AUD_XCK       (AUD_XCK),

        .FPGA_I2C_SCLK (FPGA_I2C_SCLK),
        .FPGA_I2C_SDAT (FPGA_I2C_SDAT),

        .VGA_R         (VGA_R),
        .VGA_G         (VGA_G),
        .VGA_B         (VGA_B),

        .VGA_CLK       (VGA_CLK),
        .VGA_HS        (VGA_HS),
        .VGA_VS        (VGA_VS),
        .VGA_BLANK_N   (VGA_BLANK_N),
        .VGA_SYNC_N    (VGA_SYNC_N),

        .LEDR          (LEDR),

        .HEX0          (HEX0),
        .HEX1          (HEX1),
        .HEX2          (HEX2),
        .HEX3          (HEX3),
        .HEX4          (HEX4),
        .HEX5          (HEX5)
    );


    // ============================================================
    // Clock generation
    // ============================================================

    initial begin
        CLOCK_50 = 1'b0;

        forever #10
            CLOCK_50 = ~CLOCK_50;
    end


    // Accelerated WM8731 clocks for whole-system simulation.
    //
    // Keep the hardware relationship:
    //
    //     BCLK : ADCLRCK = 64 : 1
    //
    // but run both clocks much faster than the board so that several
    // real audio frames can traverse the DSP pipeline in a short test.
    //
    initial begin
        AUD_BCLK = 1'b0;

        forever #2.5
            AUD_BCLK = ~AUD_BCLK;
    end


    initial begin
        AUD_ADCLRCK = 1'b0;

        forever #160
            AUD_ADCLRCK = ~AUD_ADCLRCK;
    end


    // A deterministic zero-valued microphone stream is sufficient
    // for the whole-system frame-flow test. Classifier/game behaviour
    // is still tested deterministically by injecting a classifier event
    // at the source side of audio_game_cdc.
    initial begin
        AUD_ADCDAT = 1'b0;
    end


    // ============================================================
    // Whole-system frame monitors
    // ============================================================

    // One feature_valid pulse represents one completed audio feature
    // frame produced by the real FFT/feature pipeline.
    always @(posedge DUT.fft_clk) begin

        if (DUT.reset_50) begin
            audio_frame_count <= 0;
        end

        else if (DUT.feature_valid) begin
            audio_frame_count <= audio_frame_count + 1;
        end

    end


    // Count completed reduced-size Avalon-ST video frames.
    always @(posedge DUT.pixel_clk) begin

        if (DUT.reset_50) begin
            video_frame_count <= 0;
        end

        else if (
            DUT.video_valid &&
            DUT.video_eop
        ) begin
            video_frame_count <= video_frame_count + 1;
        end

    end


    // ============================================================
    // Utility tasks
    // ============================================================

    task automatic wait_sys_cycles (
        input int cycles
    );

        repeat (cycles)
            @(posedge CLOCK_50);

    endtask


    // ------------------------------------------------------------
    // Wait until several real audio feature frames have traversed
    // the integrated audio DSP pipeline.
    // ------------------------------------------------------------

    task automatic wait_for_audio_frames (
        input int target_frames
    );

        int timeout;

        begin

            timeout = 0;

            while (
                audio_frame_count < target_frames &&
                timeout < 1_000_000
            ) begin

                @(posedge CLOCK_50);

                timeout = timeout + 1;

            end


            if (audio_frame_count < target_frames) begin

                $fatal(
                    1,
                    "Audio frame timeout: expected %0d frames, observed %0d",
                    target_frames,
                    audio_frame_count
                );

            end

        end

    endtask


    // ------------------------------------------------------------
    // Wait until several complete reduced-size video frames have
    // traversed the integrated video pipeline.
    // ------------------------------------------------------------

    task automatic wait_for_video_frames (
        input int target_frames
    );

        int timeout;

        begin

            timeout = 0;

            while (
                video_frame_count < target_frames &&
                timeout < 1_000_000
            ) begin

                @(posedge CLOCK_50);

                timeout = timeout + 1;

            end


            if (video_frame_count < target_frames) begin

                $fatal(
                    1,
                    "Video frame timeout: expected %0d frames, observed %0d",
                    target_frames,
                    video_frame_count
                );

            end

        end

    endtask


    // ------------------------------------------------------------
    // Generate one artificial musical beat.
    //
    // The real hardware beat timer uses 500 ms, which would make
    // this system-level simulation unnecessarily slow.
    //
    // We therefore override beat_tick for exactly one 50 MHz cycle.
    // ------------------------------------------------------------

    task automatic pulse_beat;

        begin

            @(negedge CLOCK_50);

            force DUT.beat_tick = 1'b1;

            @(posedge CLOCK_50);
            #1;

            release DUT.beat_tick;

            @(posedge CLOCK_50);

        end

    endtask


    // ------------------------------------------------------------
    // Inject one classifier result on the AUDIO side of the
    // audio_game_cdc.
    //
    // This deliberately enters BEFORE the CDC so that the system
    // test still exercises the real audio -> game crossing.
    //
    // vowel_id:
    //
    //   0 = ee
    //   1 = ah
    //   2 = oo
    //   3 = aw
    // ------------------------------------------------------------

    task automatic inject_audio_vowel (
        input logic [1:0] id
    );

        int timeout;

        begin

            // Do not send another event while the CDC source side
            // reports itself busy.

            timeout = 0;

            while (
                DUT.audio_game_busy &&
                timeout < 100
            ) begin

                @(posedge DUT.fft_clk);

                timeout = timeout + 1;

            end


            if (timeout >= 100) begin

                $fatal(
                    1,
                    "audio_game_cdc source remained busy"
                );

            end


            // Present ID before valid so both are stable when the
            // audio-domain side samples the event.

            @(negedge DUT.fft_clk);

            force DUT.audio_vowel_id =
                id;

            force DUT.audio_vowel_valid =
                1'b1;


            @(posedge DUT.fft_clk);
            #1;


            @(negedge DUT.fft_clk);

            force DUT.audio_vowel_valid =
                1'b0;


            @(posedge DUT.fft_clk);
            #1;


            release DUT.audio_vowel_valid;
            release DUT.audio_vowel_id;

        end

    endtask


    // ------------------------------------------------------------
    // Wait for audio_game_cdc to produce its one-cycle game-domain
    // vowel event.
    // ------------------------------------------------------------

    task automatic expect_game_vowel (
        input logic [1:0] expected_id
    );

        int timeout;

        begin

            timeout = 0;

            while (
                !DUT.vowel_valid &&
                timeout < 100
            ) begin

                @(posedge CLOCK_50);

                timeout = timeout + 1;

            end


            if (timeout >= 100) begin

                $fatal(
                    1,
                    "Timed out waiting for vowel_valid"
                );

            end


            if (
                DUT.vowel_id !==
                expected_id
            ) begin

                $fatal(
                    1,
                    "CDC vowel mismatch: expected %0d, got %0d",
                    expected_id,
                    DUT.vowel_id
                );

            end


            // vowel_valid must be a one-cycle game-domain event.

            @(posedge CLOCK_50);
            #1;

            if (DUT.vowel_valid) begin

                $fatal(
                    1,
                    "vowel_valid lasted more than one game clock"
                );

            end

        end

    endtask


    // ------------------------------------------------------------
    // Wait for lane 0 to become active.
    // ------------------------------------------------------------

    task automatic wait_lane0_active;

        int timeout;

        begin

            timeout = 0;

            while (
                !DUT.lane_active[0] &&
                timeout < 20
            ) begin

                @(posedge CLOCK_50);

                timeout = timeout + 1;

            end


            if (timeout >= 20) begin

                $fatal(
                    1,
                    "Lane 0 did not become active"
                );

            end

        end

    endtask


    // ------------------------------------------------------------
    // Advance the game using synthetic beats until lane 0 reaches
    // its hit window.
    //
    // This avoids hard-coding assumptions about the exact number
    // of lane state transitions.
    // ------------------------------------------------------------

    task automatic advance_lane0_to_hit_window;

        int beats;

        begin

            beats = 0;

            while (
                !DUT.lane_zero[0] &&
                beats < 10
            ) begin

                pulse_beat();

                beats = beats + 1;

            end


            if (beats >= 10) begin

                $fatal(
                    1,
                    "Lane 0 never reached its hit window"
                );

            end


            if (!DUT.lane_active[0]) begin

                $fatal(
                    1,
                    "Lane 0 became inactive before hit window"
                );

            end

        end

    endtask


    // ------------------------------------------------------------
    // Wait for score.
    // ------------------------------------------------------------

    task automatic wait_for_score (
        input logic [15:0] expected_score
    );

        int timeout;

        begin

            timeout = 0;

            while (
                DUT.game_score !==
                expected_score &&
                timeout < 100
            ) begin

                @(posedge CLOCK_50);

                timeout = timeout + 1;

            end


            if (timeout >= 100) begin

                $fatal(
                    1,
                    "Score timeout: expected %0d, got %0d",
                    expected_score,
                    DUT.game_score
                );

            end

        end

    endtask


    // ------------------------------------------------------------
    // Wait for game_video_cdc to transport the score into the
    // pixel clock domain.
    // ------------------------------------------------------------

    task automatic wait_for_video_score (
        input logic [15:0] expected_score
    );

        int timeout;

        begin

            timeout = 0;

            while (
                DUT.video_score !==
                expected_score &&
                timeout < 200
            ) begin

                @(posedge DUT.pixel_clk);

                timeout = timeout + 1;

            end


            if (timeout >= 200) begin

                $fatal(
                    1,
                    "Game->video CDC timeout: expected score %0d, got %0d",
                    expected_score,
                    DUT.video_score
                );

            end

        end

    endtask


    // ============================================================
    // Main test
    // ============================================================

    initial begin

        $display(
            "Starting top_level integration test"
        );


        // --------------------------------------------------------
        // Initial board state
        // --------------------------------------------------------

        KEY = 4'b1111;
        SW  = 10'b0;


        // --------------------------------------------------------
        // TEST 1:
        // Reset clears game state.
        // --------------------------------------------------------

        $display(
            "TEST 1: reset"
        );


        // KEY0 active low.

        KEY[0] = 1'b0;

        wait_sys_cycles(6);

        KEY[0] = 1'b1;

        wait_sys_cycles(10);


        if (
            DUT.game_score !==
            16'd0
        ) begin

            $fatal(
                1,
                "Score was not zero after reset"
            );

        end


        if (
            DUT.lane_active !==
            4'b0000
        ) begin

            $fatal(
                1,
                "Lanes were not clear after reset: %b",
                DUT.lane_active
            );

        end


        $display(
            "  PASS: reset cleared score and lanes"
        );


        // --------------------------------------------------------
        // TEST 2:
        // Several real audio frames traverse the integrated DSP path.
        // --------------------------------------------------------

        $display(
            "TEST 2: several audio frames"
        );


        wait_for_audio_frames(3);


        $display(
            "  PASS: observed %0d audio feature frames",
            audio_frame_count
        );


        // --------------------------------------------------------
        // TEST 3:
        // Several reduced-size frames traverse the video subsystem.
        // --------------------------------------------------------

        $display(
            "TEST 3: several reduced-size video frames"
        );


        wait_for_video_frames(3);


        $display(
            "  PASS: observed %0d reduced-size video frames",
            video_frame_count
        );


        // --------------------------------------------------------
        // TEST 4:
        // First beat spawns lane 0.
        // --------------------------------------------------------

        $display(
            "TEST 4: deterministic lane spawn"
        );


        pulse_beat();

        wait_lane0_active();


        if (
            DUT.lane_active[0] !==
            1'b1
        ) begin

            $fatal(
                1,
                "Expected lane 0 to spawn first"
            );

        end


        $display(
            "  PASS: lane 0 spawned"
        );


        // --------------------------------------------------------
        // TEST 5:
        // Correct vowel too early must NOT score.
        //
        // lane 0 has just spawned and therefore should not yet be
        // in its hit window.
        // --------------------------------------------------------

        $display(
            "TEST 5: early vowel does not score"
        );


        if (DUT.lane_zero[0]) begin

            $fatal(
                1,
                "Lane 0 unexpectedly already in hit window"
            );

        end


        inject_audio_vowel(2'd0);

        expect_game_vowel(2'd0);

        wait_sys_cycles(5);


        if (
            DUT.game_score !==
            16'd0
        ) begin

            $fatal(
                1,
                "Early correct vowel incorrectly scored"
            );

        end


        $display(
            "  PASS: early vowel rejected"
        );


        // --------------------------------------------------------
        // TEST 6:
        // Advance lane 0 until it reaches the hit window.
        // --------------------------------------------------------

        $display(
            "TEST 6: lane reaches hit window"
        );


        advance_lane0_to_hit_window();


        if (
            !DUT.lane_zero[0]
        ) begin

            $fatal(
                1,
                "Lane 0 was not in hit window"
            );

        end


        $display(
            "  PASS: lane 0 reached hit window"
        );


        // --------------------------------------------------------
        // TEST 7:
        // Wrong vowel must not score.
        //
        // Use aw/lane 3 while lane 0 is the target.
        // --------------------------------------------------------

        $display(
            "TEST 7: wrong vowel does not score"
        );


        inject_audio_vowel(2'd3);

        expect_game_vowel(2'd3);

        wait_sys_cycles(5);


        if (
            DUT.game_score !==
            16'd0
        ) begin

            $fatal(
                1,
                "Wrong vowel incorrectly scored"
            );

        end


        if (
            !DUT.lane_active[0]
        ) begin

            $fatal(
                1,
                "Wrong vowel unexpectedly cleared lane 0"
            );

        end


        $display(
            "  PASS: wrong vowel rejected"
        );


        // --------------------------------------------------------
        // TEST 8:
        // Correct ee event while lane 0 is in its hit window.
        // --------------------------------------------------------

        $display(
            "TEST 8: correct vowel scores"
        );


        inject_audio_vowel(2'd0);

        expect_game_vowel(2'd0);

        wait_for_score(16'd1);


        $display(
            "  PASS: score incremented to 1"
        );


        // --------------------------------------------------------
        // TEST 9:
        // A single classifier event must not repeatedly score.
        // --------------------------------------------------------

        $display(
            "TEST 9: no duplicate scoring"
        );


        wait_sys_cycles(20);


        if (
            DUT.game_score !==
            16'd1
        ) begin

            $fatal(
                1,
                "Single vowel event caused duplicate score: %0d",
                DUT.game_score
            );

        end


        $display(
            "  PASS: score remained 1"
        );


        // --------------------------------------------------------
        // TEST 10:
        // Game state crosses into the 25 MHz video domain.
        // --------------------------------------------------------

        $display(
            "TEST 10: game-to-video CDC"
        );


        wait_for_video_score(16'd1);


        if (
            DUT.video_score !==
            16'd1
        ) begin

            $fatal(
                1,
                "Video domain score mismatch"
            );

        end


        $display(
            "  PASS: score reached video domain"
        );


        // --------------------------------------------------------
        // TEST 11:
        // Full reset after activity clears game and propagates.
        // --------------------------------------------------------

        $display(
            "TEST 11: reset after gameplay"
        );


        KEY[0] = 1'b0;

        wait_sys_cycles(6);

        KEY[0] = 1'b1;

        wait_sys_cycles(10);


        if (
            DUT.game_score !==
            16'd0
        ) begin

            $fatal(
                1,
                "Gameplay reset did not clear score"
            );

        end


        if (
            DUT.lane_active !==
            4'b0000
        ) begin

            $fatal(
                1,
                "Gameplay reset did not clear lanes"
            );

        end


        wait_for_video_score(16'd0);


        $display(
            "  PASS: reset propagated through game/video path"
        );


        // ========================================================
        // Finished
        // ========================================================

        $display(
            "ALL TESTS PASSED: top_level_tb"
        );

        $finish;

    end


    // ============================================================
    // Global timeout
    // ============================================================

    initial begin

        #20_000_000;

        $fatal(
            1,
            "top_level_tb global timeout"
        );

    end


endmodule
