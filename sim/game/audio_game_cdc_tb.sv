`timescale 1ns/1ps

module audio_game_cdc_tb;

    import assignment2_pkg::*;

    logic audio_clk;
    logic game_clk;
    logic reset;

    logic       audio_vowel_valid;
    logic [1:0] audio_vowel_id;

    logic source_busy;

    logic       vowel_valid;
    logic [1:0] vowel_id;

    integer pulse_count;


    // ============================================================
    // DUT
    // ============================================================

    audio_game_cdc DUT (
        .audio_clk         (audio_clk),
        .reset             (reset),

        .audio_vowel_valid (audio_vowel_valid),
        .audio_vowel_id    (audio_vowel_id),

        .source_busy       (source_busy),

        .game_clk          (game_clk),
        .vowel_valid       (vowel_valid),
        .vowel_id          (vowel_id)
    );


    // ============================================================
    // Asynchronous clocks
    //
    // Deliberately unrelated periods for CDC simulation.
    // ============================================================

    initial audio_clk = 1'b0;
    always #7 audio_clk = ~audio_clk;

    initial game_clk = 1'b0;
    always #5 game_clk = ~game_clk;


    // ============================================================
    // Count destination pulses
    // ============================================================

    always_ff @(posedge game_clk) begin
        if (reset) begin
            pulse_count <= 0;
        end else if (vowel_valid) begin
            pulse_count <= pulse_count + 1;
        end
    end


    // ============================================================
    // Send one source-domain classification
    // ============================================================

    task automatic send_audio_vowel(
        input logic [1:0] id
    );
        begin
            // Wait until previous handshake has completed.
            while (source_busy)
                @(posedge audio_clk);

            @(negedge audio_clk);

            audio_vowel_id    = id;
            audio_vowel_valid = 1'b1;

            @(posedge audio_clk);
            #1;

            @(negedge audio_clk);

            audio_vowel_valid = 1'b0;
        end
    endtask


    // ============================================================
    // Wait for destination event and verify it
    // ============================================================

    task automatic expect_game_vowel(
        input logic [1:0] expected_id
    );
        integer timeout;
        begin
            timeout = 0;

            while (!vowel_valid && timeout < 20) begin
                @(posedge game_clk);
                #1;
                timeout = timeout + 1;
            end

            if (!vowel_valid) begin
                $fatal(
                    1,
                    "FAIL: timeout waiting for vowel_valid, expected id=%0d",
                    expected_id
                );
            end

            if (vowel_id !== expected_id) begin
                $fatal(
                    1,
                    "FAIL: expected vowel_id=%0d, got=%0d",
                    expected_id,
                    vowel_id
                );
            end

            // Confirm pulse lasts only one game-clock cycle.
            @(posedge game_clk);
            #1;

            if (vowel_valid !== 1'b0) begin
                $fatal(
                    1,
                    "FAIL: vowel_valid must be a one-cycle pulse"
                );
            end
        end
    endtask


    // ============================================================
    // Test sequence
    // ============================================================

    initial begin
        reset             = 1'b1;
        audio_vowel_valid = 1'b0;
        audio_vowel_id    = VOWEL_EE;

        repeat (4) @(posedge game_clk);
        repeat (3) @(posedge audio_clk);

        @(negedge audio_clk);
        reset = 1'b0;


        // --------------------------------------------------------
        // Test ee
        // --------------------------------------------------------

        send_audio_vowel(VOWEL_EE);
        expect_game_vowel(VOWEL_EE);


        // --------------------------------------------------------
        // Test ah
        // --------------------------------------------------------

        send_audio_vowel(VOWEL_AH);
        expect_game_vowel(VOWEL_AH);


        // --------------------------------------------------------
        // Test oo
        // --------------------------------------------------------

        send_audio_vowel(VOWEL_OO);
        expect_game_vowel(VOWEL_OO);


        // --------------------------------------------------------
        // Test aw
        // --------------------------------------------------------

        send_audio_vowel(VOWEL_AW);
        expect_game_vowel(VOWEL_AW);


        // --------------------------------------------------------
        // Test repeated identical values.
        //
        // A toggle handshake must still generate separate events
        // even if vowel_id itself does not change.
        // --------------------------------------------------------

        send_audio_vowel(VOWEL_EE);
        expect_game_vowel(VOWEL_EE);

        send_audio_vowel(VOWEL_EE);
        expect_game_vowel(VOWEL_EE);


        // --------------------------------------------------------
        // Verify exact number of destination events
        // --------------------------------------------------------

        // Allow pulse counter NBA update to settle.
        @(posedge game_clk);
        #1;

        if (pulse_count !== 6) begin
            $fatal(
                1,
                "FAIL: expected 6 destination pulses, got %0d",
                pulse_count
            );
        end


        $display("ALL TESTS PASSED: audio_game_cdc_tb");
        $finish;
    end

endmodule
