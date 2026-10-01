module audio_game_cdc (
    // Audio / classifier clock domain
    input  logic       audio_clk,
    input  logic       reset,
    input  logic       audio_vowel_valid,
    input  logic [1:0] audio_vowel_id,

    // Optional status back to audio side.
    // A new event is accepted only while source_busy == 0.
    output logic       source_busy,

    // 50 MHz game clock domain
    input  logic       game_clk,
    output logic       vowel_valid,
    output logic [1:0] vowel_id
);

    // ============================================================
    // Audio-domain state
    // ============================================================

    logic [1:0] vowel_hold;
    logic       req_toggle;

    logic ack_toggle;

    logic ack_sync_1;
    logic ack_sync_2;


    // ============================================================
    // Game-domain state
    // ============================================================

    logic req_sync_1;
    logic req_sync_2;
    logic req_seen;

    logic [1:0] vowel_sync_1;
    logic [1:0] vowel_sync_2;


    // ============================================================
    // Audio domain
    //
    // Capture the classification result and hold the data stable
    // until the destination acknowledges the transfer.
    // ============================================================

    always_ff @(posedge audio_clk) begin
        if (reset) begin
            vowel_hold <= 2'b00;
            req_toggle <= 1'b0;
        end else begin
            if (audio_vowel_valid && !source_busy) begin
                vowel_hold <= audio_vowel_id;
                req_toggle <= ~req_toggle;
            end
        end
    end


    // ============================================================
    // Synchronise acknowledgement back into audio domain
    // ============================================================

    always_ff @(posedge audio_clk) begin
        if (reset) begin
            ack_sync_1 <= 1'b0;
            ack_sync_2 <= 1'b0;
        end else begin
            ack_sync_1 <= ack_toggle;
            ack_sync_2 <= ack_sync_1;
        end
    end


    // Source is busy while request and acknowledgement differ.
    assign source_busy = (req_toggle != ack_sync_2);


    // ============================================================
    // Synchronise request into game domain
    // ============================================================

    always_ff @(posedge game_clk) begin
        if (reset) begin
            req_sync_1 <= 1'b0;
            req_sync_2 <= 1'b0;
        end else begin
            req_sync_1 <= req_toggle;
            req_sync_2 <= req_sync_1;
        end
    end


    // ============================================================
    // Synchronise held vowel data into game domain
    //
    // vowel_hold remains stable throughout the handshake.
    // Two game-clock stages are used before the value is consumed.
    // ============================================================

    always_ff @(posedge game_clk) begin
        if (reset) begin
            vowel_sync_1 <= 2'b00;
            vowel_sync_2 <= 2'b00;
        end else begin
            vowel_sync_1 <= vowel_hold;
            vowel_sync_2 <= vowel_sync_1;
        end
    end


    // ============================================================
    // Game domain event generation
    //
    // Each new request produces exactly one game-clock pulse.
    // ============================================================

    always_ff @(posedge game_clk) begin
        if (reset) begin
            req_seen   <= 1'b0;
            ack_toggle <= 1'b0;

            vowel_valid <= 1'b0;
            vowel_id    <= 2'b00;
        end else begin
            // Default: vowel_valid is a one-cycle pulse.
            vowel_valid <= 1'b0;

            if (req_sync_2 != req_seen) begin
                vowel_id    <= vowel_sync_2;
                vowel_valid <= 1'b1;

                req_seen   <= req_sync_2;
                ack_toggle <= req_sync_2;
            end
        end
    end

endmodule
