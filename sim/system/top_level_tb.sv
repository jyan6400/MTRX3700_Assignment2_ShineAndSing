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
    logic [1:0] target_lane;
    logic [1:0] wrong_lane;


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
    // ROM content and image selection: known-independent HEX samples.
    // The address is (x=100, y=160): 160*320+100=51300.
    // Expected 8-bit pixels come from memory/piano{0,1,2}.hex.
    // Run only in simulation; synthesised RTL is untouched.
    // ============================================================
    task automatic verify_selected_picture(
        input logic [1:0] picture_id,
        input logic [7:0] expected_grey
    );
        integer cycles;
        bit seen;
        SW[4:3] = picture_id;
        // Allow the two-stage asynchronous-switch synchroniser to settle.
        repeat (12) @(negedge CLOCK_50);
        if (DUT.u_video.img50 !== picture_id)
            $fatal(1, "ROM selector mismatch: requested %0d, got %0d",
                   picture_id, DUT.u_video.img50);
        seen = 0;
        // Analyse port A continuously raster-scans the 320x240 image.
        for (cycles = 0; cycles < 170_000 && !seen; cycles++) begin
            @(negedge CLOCK_50);
            if (DUT.u_video.ra_addr == 17'd51300) begin
                @(posedge CLOCK_50);
                #1; // ROM q_a is registered on this clock edge.
                if (DUT.u_video.ra_q !== expected_grey)
                    $fatal(1, "ROM image %0d at (100,160): got %02h, expected %02h",
                           picture_id, DUT.u_video.ra_q, expected_grey);
                seen = 1;
            end
        end
        if (!seen)
            $fatal(1, "ROM image %0d: raster never requested pixel (100,160)", picture_id);
        $display("  PASS: piano%0d selected, pixel (100,160) = 0x%02h",
                 picture_id, expected_grey);
    endtask

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

    task automatic wait_target_lane_active;

        int timeout;

        begin

            timeout = 0;

            while (
                !DUT.lane_active[target_lane] &&
                timeout < 20
            ) begin

                @(posedge CLOCK_50);

                timeout = timeout + 1;

            end


            if (timeout >= 20) begin

                $fatal(
                    1,
                    "Selected lane did not become active"
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

    task automatic advance_target_lane_to_hit_window;

        int beats;

        begin

            beats = 0;

            while (
                !DUT.lane_zero[target_lane] &&
                beats < 10
            ) begin

                pulse_beat();

                beats = beats + 1;

            end


            if (beats >= 10) begin

                $fatal(
                    1,
                    "Selected lane never reached its hit window"
                );

            end


            if (!DUT.lane_active[target_lane]) begin

                $fatal(
                    1,
                    "Selected lane became inactive before hit window"
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
        // TEST 3B: verify all three picture ROMs with independent
        //          expected pixels and the actual SW[4:3] mux.
        // --------------------------------------------------------
        $display("TEST 3B: picture ROM content and selection (3 images)");
        verify_selected_picture(2'd0, 8'hC0); // piano0.hex, address 51300
        verify_selected_picture(2'd1, 8'hFF); // piano1.hex, address 51300
        verify_selected_picture(2'd2, 8'h51); // piano2.hex, address 51300
        SW[4:3] = 2'd0; // restore default image
        wait_sys_cycles(12);

        // --------------------------------------------------------
        // TEST 4:
        // First beat spawns exactly one randomly selected lane.
        // --------------------------------------------------------

        $display(
            "TEST 4: pseudo-random lane spawn"
        );

        // LIVE CHANGE -- RANDOM NOTE TEST
        // Check that the integration exposes the two LFSR selector
        // bits and that the selected lane is not permanently fixed.
        // This test does NOT demand a particular pseudo-random order.
        begin
            logic [3:0] seen_lanes;
            seen_lanes = 4'b0000;

            repeat (32) begin
                @(negedge CLOCK_50);
                if (DUT.spawn_lane !== DUT.random_value[1:0]) begin
                    $fatal(1, "RNG lane mapping does not match LFSR bits");
                end
                seen_lanes[DUT.spawn_lane] = 1'b1;
            end

            if (seen_lanes !== 4'b1111) begin
                $fatal(1, "RNG did not visit all four lanes: %b", seen_lanes);
            end
        end

        // The RNG is free-running, so capture its lane selection
        // immediately before the forced beat clock edge.
        @(negedge CLOCK_50);
        force DUT.beat_tick = 1'b1;
        target_lane = DUT.spawn_lane;
        wrong_lane  = target_lane ^ 2'd1;
        @(posedge CLOCK_50);
        #1;
        release DUT.beat_tick;
        @(posedge CLOCK_50);
        #1;

        if (!$onehot(DUT.lane_active) ||
            DUT.lane_active[target_lane] !== 1'b1) begin
            $fatal(1, "RNG spawn failed: lane=%0d active=%b",
                   target_lane, DUT.lane_active);
        end

        $display("  PASS: RNG selected lane %0d", target_lane);


        // --------------------------------------------------------
        // TEST 5:
        // Correct vowel too early must NOT score.
        //
        // The selected lane has just spawned and should not yet
        // be in its hit window.
        // --------------------------------------------------------

        $display(
            "TEST 5: early vowel does not score"
        );


        if (DUT.lane_zero[target_lane]) begin

            $fatal(
                1,
                "Selected lane unexpectedly already in hit window"
            );

        end


        inject_audio_vowel(target_lane);

        expect_game_vowel(target_lane);

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
        // Advance the selected lane until it reaches the hit window.
        // --------------------------------------------------------

        $display(
            "TEST 6: lane reaches hit window"
        );


        advance_target_lane_to_hit_window();


        if (
            !DUT.lane_zero[target_lane]
        ) begin

            $fatal(
                1,
                "Selected lane was not in hit window"
            );

        end


        $display(
            "  PASS: target lane reached hit window"
        );


        // --------------------------------------------------------
        // TEST 7:
        // Wrong vowel must not score.
        //
        // Use a different vowel/lane from the selected target.
        // --------------------------------------------------------

        $display(
            "TEST 7: wrong vowel does not score"
        );


        inject_audio_vowel(wrong_lane);

        expect_game_vowel(wrong_lane);

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
            !DUT.lane_active[target_lane]
        ) begin

            $fatal(
                1,
                "Wrong vowel unexpectedly cleared target lane"
            );

        end


        $display(
            "  PASS: wrong vowel rejected"
        );


        // --------------------------------------------------------
        // TEST 8:
        // Correct vowel event while target lane is in its hit window.
        // --------------------------------------------------------

        $display(
            "TEST 8: correct vowel scores"
        );


        inject_audio_vowel(target_lane);

        expect_game_vowel(target_lane);

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

        // --------------------------------------------------------
        // TEST 12: RNG output spans all four possible lane IDs.
        // This is a source-level integration sanity check; the
        // standalone rng_tb additionally checks the LFSR sequence.
        // --------------------------------------------------------
        $display("TEST 12: RNG drives all four lane IDs");
        begin
            logic [3:0] seen;
            seen = 4'b0000;
            repeat (32) begin
                @(negedge CLOCK_50);
                seen[DUT.spawn_lane] = 1'b1;
            end
            if (seen !== 4'b1111)
                $fatal(1, "RNG lane coverage incomplete: %b", seen);
        end
        $display("  PASS: all four RNG lane IDs observed");


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
