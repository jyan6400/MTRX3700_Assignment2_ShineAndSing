module game_video_cdc (
    // ============================================================
    // 50 MHz game clock domain
    // ============================================================

    input  logic game_clk,
    input  logic reset,

    input  logic [3:0] game_lane_active,
    input  logic [3:0] game_lane_hit_window,
    input  logic [3:0] game_lane_hit_pulse,

    input  logic [assignment2_pkg::GAME_COUNT_W-1:0]
                 game_lane_count [0:3],

    input  logic [assignment2_pkg::SCORE_W-1:0]
                 game_score,

    output logic source_busy,

    // ============================================================
    // 25 MHz video / pixel clock domain
    // ============================================================

    input  logic pixel_clk,

    output logic [3:0] video_lane_active,
    output logic [3:0] video_lane_hit_window,
    output logic [3:0] video_lane_hit_pulse,

    output logic [assignment2_pkg::GAME_COUNT_W-1:0]
                 video_lane_count [0:3],

    output logic [assignment2_pkg::SCORE_W-1:0]
                 video_score
);

    import assignment2_pkg::*;


    // ============================================================
    // Game-domain snapshot registers
    //
    // These remain stable for the entire handshake.
    // ============================================================

    logic [3:0] lane_active_hold;
    logic [3:0] lane_hit_window_hold;
    logic [3:0] lane_hit_hold;

    logic [GAME_COUNT_W-1:0] lane_count_hold [0:3];
    logic [SCORE_W-1:0]      score_hold;


    // ============================================================
    // Last state sent
    //
    // Used so we only transfer when something changes.
    // ============================================================

    logic [3:0] last_lane_active;
    logic [3:0] last_lane_hit_window;

    logic [GAME_COUNT_W-1:0] last_lane_count [0:3];
    logic [SCORE_W-1:0]      last_score;


    // ============================================================
    // Hit-event accumulator
    //
    // Hit pulses are one-cycle events in the game domain.
    // Accumulate them while a previous CDC transaction is busy.
    // ============================================================

    logic [3:0] pending_hit;


    // ============================================================
    // Toggle handshake
    // ============================================================

    logic req_toggle;
    logic ack_toggle;

    logic ack_sync_1;
    logic ack_sync_2;

    logic req_sync_1;
    logic req_sync_2;
    logic req_seen;


    // ============================================================
    // Pixel-domain synchronisation registers for bundled data
    // ============================================================

    logic [3:0] lane_active_sync_1;
    logic [3:0] lane_active_sync_2;

    logic [3:0] lane_hit_window_sync_1;
    logic [3:0] lane_hit_window_sync_2;

    logic [3:0] lane_hit_sync_1;
    logic [3:0] lane_hit_sync_2;

    logic [GAME_COUNT_W-1:0] lane_count_sync_1 [0:3];
    logic [GAME_COUNT_W-1:0] lane_count_sync_2 [0:3];

    logic [SCORE_W-1:0] score_sync_1;
    logic [SCORE_W-1:0] score_sync_2;


    // ============================================================
    // Detect a change in level/state information
    // ============================================================

    logic state_changed;

    integer i;

    always_comb begin
        state_changed =
            (game_lane_active     != last_lane_active) ||
            (game_lane_hit_window != last_lane_hit_window) ||
            (game_score           != last_score);

        for (int k = 0; k < N_LANES; k = k + 1) begin
            if (game_lane_count[k] != last_lane_count[k])
                state_changed = 1'b1;
        end
    end


    // ============================================================
    // Synchronise acknowledgement back to game domain
    // ============================================================

    always_ff @(posedge game_clk) begin
        if (reset) begin
            ack_sync_1 <= 1'b0;
            ack_sync_2 <= 1'b0;
        end else begin
            ack_sync_1 <= ack_toggle;
            ack_sync_2 <= ack_sync_1;
        end
    end

    assign source_busy = (req_toggle != ack_sync_2);


    // ============================================================
    // Game-domain snapshot capture
    // ============================================================

    always_ff @(posedge game_clk) begin
        if (reset) begin
            req_toggle <= 1'b0;

            lane_active_hold     <= 4'b0000;
            lane_hit_window_hold <= 4'b0000;
            lane_hit_hold        <= 4'b0000;

            last_lane_active     <= 4'b0000;
            last_lane_hit_window <= 4'b0000;

            score_hold <= '0;
            last_score <= '0;

            pending_hit <= 4'b0000;

            for (i = 0; i < N_LANES; i = i + 1) begin
                lane_count_hold[i] <= '0;
                last_lane_count[i] <= '0;
            end
        end else begin

            // Preserve any hit events which occur while busy.
            pending_hit <= pending_hit | game_lane_hit_pulse;

            // Send a new snapshot whenever:
            //   1. level/state data changed, or
            //   2. at least one hit event is waiting.
            if (
                !source_busy &&
                (
                    state_changed ||
                    (|pending_hit) ||
                    (|game_lane_hit_pulse)
                )
            ) begin

                lane_active_hold     <= game_lane_active;
                lane_hit_window_hold <= game_lane_hit_window;

                // Include both previously pending hits and a hit
                // occurring on this exact game clock cycle.
                lane_hit_hold <= pending_hit | game_lane_hit_pulse;

                score_hold <= game_score;

                last_lane_active     <= game_lane_active;
                last_lane_hit_window <= game_lane_hit_window;
                last_score           <= game_score;

                for (i = 0; i < N_LANES; i = i + 1) begin
                    lane_count_hold[i] <= game_lane_count[i];
                    last_lane_count[i] <= game_lane_count[i];
                end

                pending_hit <= 4'b0000;

                req_toggle <= ~req_toggle;
            end
        end
    end


    // ============================================================
    // Synchronise request toggle into pixel domain
    // ============================================================

    always_ff @(posedge pixel_clk) begin
        if (reset) begin
            req_sync_1 <= 1'b0;
            req_sync_2 <= 1'b0;
        end else begin
            req_sync_1 <= req_toggle;
            req_sync_2 <= req_sync_1;
        end
    end


    // ============================================================
    // Synchronise stable snapshot data into pixel domain
    //
    // The source data remains unchanged until acknowledgement.
    // ============================================================

    integer j;

    always_ff @(posedge pixel_clk) begin
        if (reset) begin
            lane_active_sync_1     <= 4'b0000;
            lane_active_sync_2     <= 4'b0000;

            lane_hit_window_sync_1 <= 4'b0000;
            lane_hit_window_sync_2 <= 4'b0000;

            lane_hit_sync_1        <= 4'b0000;
            lane_hit_sync_2        <= 4'b0000;

            score_sync_1 <= '0;
            score_sync_2 <= '0;

            for (j = 0; j < N_LANES; j = j + 1) begin
                lane_count_sync_1[j] <= '0;
                lane_count_sync_2[j] <= '0;
            end
        end else begin
            lane_active_sync_1 <= lane_active_hold;
            lane_active_sync_2 <= lane_active_sync_1;

            lane_hit_window_sync_1 <= lane_hit_window_hold;
            lane_hit_window_sync_2 <= lane_hit_window_sync_1;

            lane_hit_sync_1 <= lane_hit_hold;
            lane_hit_sync_2 <= lane_hit_sync_1;

            score_sync_1 <= score_hold;
            score_sync_2 <= score_sync_1;

            for (j = 0; j < N_LANES; j = j + 1) begin
                lane_count_sync_1[j] <= lane_count_hold[j];
                lane_count_sync_2[j] <= lane_count_sync_1[j];
            end
        end
    end


    // ============================================================
    // Pixel-domain snapshot update
    //
    // lane_hit_pulse is recreated as a one-pixel-clock pulse.
    // ============================================================

    integer m;

    always_ff @(posedge pixel_clk) begin
        if (reset) begin
            req_seen   <= 1'b0;
            ack_toggle <= 1'b0;

            video_lane_active     <= 4'b0000;
            video_lane_hit_window <= 4'b0000;
            video_lane_hit_pulse  <= 4'b0000;

            video_score <= '0;

            for (m = 0; m < N_LANES; m = m + 1) begin
                video_lane_count[m] <= '0;
            end
        end else begin

            // Hit indication is an event, not a permanent level.
            video_lane_hit_pulse <= 4'b0000;

            if (req_sync_2 != req_seen) begin
                video_lane_active     <= lane_active_sync_2;
                video_lane_hit_window <= lane_hit_window_sync_2;
                video_lane_hit_pulse  <= lane_hit_sync_2;

                video_score <= score_sync_2;

                for (m = 0; m < N_LANES; m = m + 1) begin
                    video_lane_count[m] <= lane_count_sync_2[m];
                end

                req_seen   <= req_sync_2;
                ack_toggle <= req_sync_2;
            end
        end
    end

endmodule
