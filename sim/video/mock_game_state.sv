`timescale 1ns/1ps
/*
 *  mock_game_state.sv -- SIMULATION ONLY. A stand-in for Jason's game that drives the frozen Game -> Video
 *  contract, so the video subsystem can be tested (and its PNG evidence made) without any game RTL.
 *
 *  Every BEAT clocks a beat counter b advances. Lane i has phase p = (b + 5 i) mod 20:
 *    p = 0..14   a note is on the lane, lane_count = 15 - p (counting down 15 .. 1)
 *    p = 15      the hit window: lane_hit_window[i] = 1, lane_count = 0
 *    p = 16..19  idle
 *  The four lanes are 5 beats apart, so at most one lane is ever in its hit window (the A1 rule).
 *  At the end of every other window the mock "sings" the right vowel: a one-clock lane_hit_pulse and
 *  score + 1. `hold` freezes everything (for a still frame). Runs in the 25 MHz pixel domain, as the
 *  signals do after game_video_cdc.
 */
module mock_game_state #(
    parameter int GAME_COUNT_W = assignment2_pkg::GAME_COUNT_W,
    parameter int BEAT         = 40000
) (
    input  logic                    clk,
    input  logic                    reset,
    input  logic                    hold,
    output logic [3:0]              lane_active,
    output logic [GAME_COUNT_W-1:0] lane_count [0:3],
    output logic [3:0]              lane_hit_window,
    output logic [3:0]              lane_hit_pulse,
    output logic [15:0]             score
);
    int b, t;
    int notes [0:3];
    always_ff @(posedge clk) begin
        lane_hit_pulse <= '0;
        if (reset) begin
            b <= 0; t <= 0; score <= '0;
            for (int i = 0; i < 4; i++) notes[i] <= 0;
        end else if (!hold) begin
            if (t == BEAT - 1) begin
                t <= 0;
                b <= b + 1;
                for (int i = 0; i < 4; i++) if ((b + 5 * i) % 20 == 15) begin      // this lane's window ends now
                    notes[i] <= notes[i] + 1;
                    if (notes[i] % 2 == 0) begin lane_hit_pulse[i] <= 1'b1; score <= score + 1'b1; end
                end
            end else t <= t + 1;
        end
    end
    always_comb for (int i = 0; i < 4; i++) begin
        int p;
        p = (b + 5 * i) % 20;
        lane_active[i]     = (p <= 15);
        lane_hit_window[i] = (p == 15);
        lane_count[i]      = (p <= 14) ? GAME_COUNT_W'(15 - p) : '0;
    end
endmodule
