`timescale 1ns/1ps

module top_level #(
    parameter int VIDEO_IMG_W = 320,
    parameter int VIDEO_IMG_H = 240,
    parameter int VIDEO_VGA_W = 640,
    parameter int VIDEO_VGA_H = 480
) (
    // ============================================================
    // DE1-SoC clock / controls
    // ============================================================
    input  logic        CLOCK_50,
    input  logic [3:0]  KEY,
    input  logic [9:0]  SW,

    // ============================================================
    // WM8731 audio codec
    // ============================================================
    input  logic        AUD_ADCDAT,
    input  logic        AUD_ADCLRCK,
    input  logic        AUD_BCLK,

    output logic        AUD_DACDAT,
    output logic        AUD_XCK,

    output logic        FPGA_I2C_SCLK,
    inout  wire         FPGA_I2C_SDAT,

    // ============================================================
    // VGA
    // ============================================================
    output logic [7:0]  VGA_R,
    output logic [7:0]  VGA_G,
    output logic [7:0]  VGA_B,
    output logic        VGA_CLK,
    output logic        VGA_HS,
    output logic        VGA_VS,
    output logic        VGA_BLANK_N,
    output logic        VGA_SYNC_N,

    // ============================================================
    // Board debug
    // ============================================================
    output logic [9:0]  LEDR,

    output logic [6:0]  HEX0,
    output logic [6:0]  HEX1,
    output logic [6:0]  HEX2,
    output logic [6:0]  HEX3,
    output logic [6:0]  HEX4,
    output logic [6:0]  HEX5
);

    import assignment2_pkg::*;

    // ============================================================
    // PART B LIVE-CHANGE NAVIGATION INDEX
    // ============================================================
    //
    // GAME
    //   Beat period:
    //     THIS FILE -> BEAT_MS
    //     Larger BEAT_MS = slower countdown; smaller = faster.
    //
    //   Hit-window duration:
    //     rtl/game/lane.sv -> HIT_WINDOW_TICKS
    //
    //   Vowel -> lane mapping:
    //     rtl/game/vowel_hit_mapper.sv -> "LIVE CHANGE"
    //
    //   Correct-hit / early-press rules:
    //     rtl/game/game_fsm.sv -> "LIVE CHANGE -- HIT RULE"
    //
    // AUDIO
    //   Voice-gate sensitivity:
    //     rtl/audio/a2/audio_gate.sv -> MARGIN_Q4
    //
    //   R-A2 band boundaries:
    //     rtl/audio/a2/band_energy_8.sv -> BAND_EDGES
    //
    //   R-A4 Mel-band count / locations:
    //     rtl/audio/a2/mel_filterbank_24.sv -> NM / MEL_PTS
    //
    //   Vote length / absolute reject / ambiguity reject:
    //     rtl/audio/a2/audio_features.sv
    //     -> "LIVE-CHANGE QUICK CONFIG -- AUDIO CLASSIFIER"
    //
    //   Actual nearest-template reject equation:
    //     rtl/audio/provided_classifier/classifier.sv -> rej_c
    //
    // VIDEO
    //   Detector rows, spacing, thresholds and R-V mode behaviour:
    //     rtl/video/a2/video_subsystem.sv
    //
    //   VGA view mapping / colours / presentation:
    //     rtl/video/a2/game_video_overlay.sv
    //
    //   Keyboard-lattice false-boundary rejection:
    //     rtl/video/a2/key_mask_generator.sv -> "LIVE CHANGE -- KEYBOARD LATTICE"
    //
    //   R-V4 local adaptive threshold:
    //     rtl/video/a2/local_threshold.sv -> HALF / k_q
    //
    //   R-V3/R-V4 hysteresis / NMS:
    //     rtl/video/a2/hysteresis_profile.sv -> hi / lo / min_gap / adaptive
    //
    // BOARD CONTROLS (wired below into video_subsystem)
    //   SW2:SW1 = VGA view
    //   SW4:SW3 = source image
    //   SW5     = 1-D difference / Sobel selector
    //   SW7:SW6 = video rung/mode
    //   SW0     = selects which threshold parameter KEY1/KEY2 adjust
    //   KEY1/2  = threshold adjustment
    //   KEY3    = threshold defaults restore
    //   KEY0    = global reset
    //
    // HEX DEBUG
    //   HEX5:HEX3 = FFT peak bin
    //   HEX2      = accepted vowel class 0..3, blank when gate/reject says invalid
    //   HEX1:HEX0 = microphone dB level
    //
    // Live-change rule of thumb:
    //   First identify the owning module here, then edit the named parameter
    //   or clearly marked LIVE CHANGE block rather than searching the datapath.
    // ============================================================



    // ============================================================
    // Game configuration
    // ============================================================

    localparam int BEAT_MS          = 500;
    localparam int TIMER_MAX_MS     = 2048;
    localparam int HIT_WINDOW_TICKS = 1;

    localparam logic [3:0] NOTE_START = 4'd3;

    localparam int TIMER_W = $clog2(TIMER_MAX_MS);


    // ============================================================
    // Reset
    //
    // KEY0 is reserved for global reset.
    // The other keys remain available to Advay's video controls.
    // ============================================================

    logic reset_50;

    assign reset_50 = ~KEY[0];


    // ============================================================
    // Clock generation
    // ============================================================

    logic fft_clk;
    logic fft_locked;

    logic pixel_clk;
    logic video_locked;

    logic i2c_clk;
    logic i2c_locked;


    // ------------------------------------------------------------
    // Audio / FFT clock
    //
    // On hardware adc_pll generates 18.432 MHz.
    //
    // The simulator cannot model the Intel PLL primitive directly,
    // so use a behavioural replacement while running system tests.
    // ------------------------------------------------------------

`ifdef VERILATOR

    logic fft_clk_sim = 1'b0;

    always #27.126736
        fft_clk_sim = ~fft_clk_sim;

    assign fft_clk    = fft_clk_sim;
    assign fft_locked = 1'b1;

    assign i2c_clk    = 1'b0;
    assign i2c_locked = 1'b1;

`else

    adc_pll u_audio_pll (
        .areset (reset_50),
        .inclk0 (CLOCK_50),
        .c0     (fft_clk),
        .locked (fft_locked)
    );


    i2c_pll u_i2c_pll (
        .areset (reset_50),
        .inclk0 (CLOCK_50),
        .c0     (i2c_clk),
        .locked (i2c_locked)
    );

`endif


    // ------------------------------------------------------------
    // Video clock: 50 MHz -> 25 MHz
    //
    // video_pll already contains its own Verilator stand-in.
    // ------------------------------------------------------------

    video_pll u_video_pll (
        .refclk   (CLOCK_50),
        .rst      (reset_50),
        .outclk_0 (pixel_clk),
        .locked   (video_locked)
    );


    // ============================================================
    // WM8731 configuration
    // ============================================================

`ifndef VERILATOR

    set_audio_encoder u_audio_config (
        .i2c_clk  (i2c_clk),
        .I2C_SCLK (FPGA_I2C_SCLK),
        .I2C_SDAT (FPGA_I2C_SDAT)
    );

`else

    // The system simulation does not need to exercise the external
    // I2C configuration transaction.
    assign FPGA_I2C_SCLK = 1'b1;
    assign FPGA_I2C_SDAT = 1'bz;

`endif


    // WM8731 master clock.
    assign AUD_XCK = fft_clk;

    // Audio playback is not used by Shine & Sing.
    assign AUD_DACDAT = 1'b0;


    // ============================================================
    // Clock-domain reset qualification
    // ============================================================

    logic reset_fft;
    logic reset_25;

    assign reset_fft = reset_50 | ~fft_locked;
    assign reset_25  = reset_50 | ~video_locked;


    // ============================================================
    // MICROPHONE INPUT
    // ============================================================

    logic        mic_valid;
    logic [15:0] mic_sample;


    mic_load #(
        .N(AUDIO_SAMPLE_W)
    ) u_mic_load (
        .bclk        (AUD_BCLK),
        .adclrc      (AUD_ADCLRCK),
        .adcdat      (AUD_ADCDAT),

        .valid       (mic_valid),
        .sample_data (mic_sample)
    );


    // ============================================================
    // AUDIO GATE / LEVEL
    // ============================================================

    logic        gate_voice_active;
    logic [6:0]  level_db_audio;

    logic [31:0] audio_level;
    logic [31:0] noise_floor;


    audio_gate u_audio_gate (
        .clk          (AUD_BCLK),
        .reset        (reset_50),

        .sample       ($signed(mic_sample)),
        .sample_valid (mic_valid),

        .voice_active (gate_voice_active),
        .level_db     (level_db_audio),

        .level        (audio_level),
        .noise_floor  (noise_floor)
    );


    // ============================================================
    // FFT / PITCH DETECTION
    // ============================================================

    logic [9:0]  peak_k;
    logic        peak_valid;

    logic [32:0] mag_sq;
    logic        mag_valid;


    fft_pitch_detect #(
        .NSamples (FFT_N),
        .W        (AUDIO_SAMPLE_W)
    ) u_fft_pitch (
        .audio_clk          (AUD_BCLK),
        .fft_clk            (fft_clk),
        .reset              (reset_fft),

        .audio_input_data   (mic_sample),
        .audio_input_valid  (mic_valid),

        .pitch_output_data  (peak_k),
        .pitch_output_valid (peak_valid),

        .mag_sq             (mag_sq),
        .mag_valid          (mag_valid)
    );


    // ============================================================
    // R-A4 FEATURES + CLASSIFIER
    // ============================================================

    logic [23:0][15:0] feature;
    logic               feature_valid;

    logic               audio_vowel_valid;
    logic [1:0]         audio_vowel_id;

    logic               fft_voice_active;

    logic [1:0]         classifier_result;
    logic               classifier_result_valid;
    logic               classifier_reject;
    logic [7:0]         confidence;


    audio_features #(
        .RUNG  (4),
        .N     (FFT_N),
        .MAG_W (33)
    ) u_audio_features (
        .clk                     (fft_clk),
        .reset                   (reset_fft),

        .mag_sq                  (mag_sq),
        .mag_valid               (mag_valid),

        .peak_k                  (peak_k),
        .peak_valid              (peak_valid),

        .voice_active_async      (gate_voice_active),

        .feature                 (feature),
        .feature_valid           (feature_valid),

        .vowel_valid             (audio_vowel_valid),
        .vowel_id                (audio_vowel_id),

        .voice_active            (fft_voice_active),

        .classifier_result       (classifier_result),
        .classifier_result_valid (classifier_result_valid),
        .classifier_reject       (classifier_reject),
        .confidence              (confidence)
    );


    // ============================================================
    // AUDIO -> GAME CDC
    //
    // FFT domain -> 50 MHz game domain
    // ============================================================

    logic       vowel_valid;
    logic [1:0] vowel_id;

    logic       audio_game_busy;


    audio_game_cdc u_audio_game_cdc (
        .audio_clk         (fft_clk),
        .reset             (reset_50),

        .audio_vowel_valid (audio_vowel_valid),
        .audio_vowel_id    (audio_vowel_id),

        .source_busy       (audio_game_busy),

        .game_clk          (CLOCK_50),

        .vowel_valid       (vowel_valid),
        .vowel_id          (vowel_id)
    );


    // ============================================================
    // VOWEL -> LANE MAPPING
    // ============================================================

    logic [3:0] vowel_lane_valid;


    vowel_hit_mapper u_vowel_mapper (
        .vowel_valid      (vowel_valid),
        .vowel_id         (vowel_id),

        .vowel_lane_valid (vowel_lane_valid)
    );


    // ============================================================
    // MUSICAL BEAT TIMER
    // ============================================================

    logic [TIMER_W-1:0] beat_timer_value;

    logic beat_tick;
    logic beat_timer_reset;


    assign beat_tick =
        !reset_50 &&
        (beat_timer_value == '0);


    assign beat_timer_reset =
        reset_50 ||
        beat_tick;


    timer #(
        .MAX_MS      (TIMER_MAX_MS),
        .CLKS_PER_MS (50_000)
    ) u_beat_timer (
        .clk         (CLOCK_50),
        .reset       (beat_timer_reset),

        .up          (1'b0),

        .start_value (TIMER_W'(BEAT_MS)),
        .enable      (1'b1),

        .timer_value (beat_timer_value)
    );


    // ============================================================
    // NOTE SCHEDULER
    //
    // First integration implementation:
    //
    //      lane 0 -> lane 1 -> lane 2 -> lane 3 -> repeat
    //
    // Keeping this deterministic makes board integration much
    // easier. The scheduler can later be replaced without changing
    // the game, CDC or video interfaces.
    // ============================================================

    logic [1:0] spawn_lane;
    logic       spawn_valid;


    always_ff @(posedge CLOCK_50) begin

        if (reset_50) begin
            spawn_lane <= 2'd0;
        end

        else if (beat_tick) begin
            spawn_lane <= spawn_lane + 2'd1;
        end

    end


    assign spawn_valid = beat_tick;


    // ============================================================
    // GAME FSM
    // ============================================================

    logic [3:0] lane_spawn;
    logic [3:0] lane_clear;

    logic [3:0] valid_hit;
    logic [3:0] lane_hit_pulse;

    logic [3:0] lane_active;
    logic [3:0] lane_zero;
    logic [3:0] lane_expired;

    logic [GAME_COUNT_W-1:0] lane_count [0:3];


    game_fsm u_game_fsm (
        .clk         (CLOCK_50),
        .reset       (reset_50),

        // Assignment 2 replaces the old A1 physical-key event
        // with the classifier-derived one-cycle lane event.
        .button_edge (vowel_lane_valid),

        .lane_active (lane_active),
        .lane_zero   (lane_zero),

        .spawn_valid (spawn_valid),
        .spawn_lane  (spawn_lane),

        .lane_spawn  (lane_spawn),
        .lane_clear  (lane_clear),

        .valid_hit   (valid_hit),
        .hit_pulse   (lane_hit_pulse)
    );


    // ============================================================
    // FOUR GAME LANES
    // ============================================================

    genvar lane_i;

    generate

        for (
            lane_i = 0;
            lane_i < N_LANES;
            lane_i = lane_i + 1
        ) begin : GEN_GAME_LANES

            lane #(
                .HIT_WINDOW_TICKS(HIT_WINDOW_TICKS)
            ) u_lane (
                .clk           (CLOCK_50),
                .reset         (reset_50),

                .tick          (beat_tick),

                .spawn         (lane_spawn[lane_i]),
                .start_value   (NOTE_START),
                .clear         (lane_clear[lane_i]),

                .active        (lane_active[lane_i]),
                .at_zero       (lane_zero[lane_i]),
                .expired       (lane_expired[lane_i]),

                .display_value (lane_count[lane_i])
            );

        end

    endgenerate


    // ============================================================
    // SCORE
    // ============================================================

    logic [6:0]  score_7;
    logic [15:0] game_score;


    score u_score (
        .clk       (CLOCK_50),
        .reset     (reset_50),

        .valid_hit (valid_hit),

        .score     (score_7)
    );


    assign game_score = {
        9'd0,
        score_7
    };


    // ============================================================
    // GAME -> VIDEO CDC
    //
    // 50 MHz game domain -> 25 MHz pixel domain
    // ============================================================

    logic [3:0] video_lane_active;
    logic [3:0] video_lane_hit_window;
    logic [3:0] video_lane_hit_pulse;

    logic [GAME_COUNT_W-1:0]
        video_lane_count [0:3];

    logic [SCORE_W-1:0]
        video_score;

    logic game_video_busy;


    game_video_cdc u_game_video_cdc (
        .game_clk              (CLOCK_50),
        .reset                 (reset_50),

        .game_lane_active      (lane_active),

        .game_lane_hit_window  (lane_zero),

        .game_lane_hit_pulse   (lane_hit_pulse),

        .game_lane_count       (lane_count),

        .game_score            (game_score),

        .source_busy           (game_video_busy),

        .pixel_clk             (pixel_clk),

        .video_lane_active     (video_lane_active),

        .video_lane_hit_window (video_lane_hit_window),

        .video_lane_hit_pulse  (video_lane_hit_pulse),

        .video_lane_count      (video_lane_count),

        .video_score           (video_score)
    );


    // ============================================================
    // VIDEO SUBSYSTEM
    // ============================================================

    localparam int VIDEO_NMAX = 32;
    localparam int VIDEO_X_W  = $clog2(VIDEO_IMG_W);


    logic [29:0] video_data;

    logic video_sop;
    logic video_eop;
    logic video_valid;
    logic video_ready;


    logic boundary_valid;

    logic [$clog2(VIDEO_NMAX+1)-1:0]
        boundary_count;

    logic [VIDEO_NMAX-1:0][VIDEO_X_W-1:0]
        boundary_x;

    logic lanes_valid;


    video_subsystem #(
        .IMG_W (VIDEO_IMG_W),
        .IMG_H (VIDEO_IMG_H),
        .VGA_W (VIDEO_VGA_W),
        .VGA_H (VIDEO_VGA_H),
        .NMAX  (VIDEO_NMAX)
    ) u_video (
        .clk_50          (CLOCK_50),
        .reset_50        (reset_50),

        .clk_25          (pixel_clk),
        .reset_25        (reset_25),

        // Advay's board controls.
        .sw_view         (SW[2:1]),
        .sw_image        (SW[4:3]),
        .sw_edge         (SW[5]),
        .sw_mode         (SW[7:6]),
        .sw_adjust       (SW[0]),

        .key_n           (KEY[3:1]),

        // Frozen Game -> Video contract.
        .lane_active     (video_lane_active),
        .lane_count      (video_lane_count),

        .lane_hit_window (video_lane_hit_window),

        .lane_hit_pulse  (video_lane_hit_pulse),

        .score           (video_score),

        // Avalon-ST video stream.
        .st_data          (video_data),

        .st_startofpacket (video_sop),

        .st_endofpacket   (video_eop),

        .st_valid         (video_valid),

        .st_ready         (video_ready),

        // Debug only.
        .boundary_valid   (boundary_valid),

        .boundary_count   (boundary_count),

        .boundary_x       (boundary_x),

        .lanes_valid      (lanes_valid)
    );


    // ============================================================
    // VGA SINK
    //
    // During Verilator simulation we do not instantiate the
    // Platform Designer VGA system.
    //
    // Advay's Avalon-ST stream is simply always accepted instead.
    // ============================================================

`ifdef VERILATOR

    assign video_ready = 1'b1;

    assign VGA_R       = '0;
    assign VGA_G       = '0;
    assign VGA_B       = '0;

    assign VGA_CLK     = pixel_clk;

    assign VGA_HS      = 1'b0;
    assign VGA_VS      = 1'b0;

    assign VGA_BLANK_N = 1'b0;
    assign VGA_SYNC_N  = 1'b0;

`else

    vga_sink u_vga_sink (
        .clk_clk (
            pixel_clk
        ),

        .reset_reset_n (
            ~reset_25
        ),

        .video_in_data (
            video_data
        ),

        .video_in_startofpacket (
            video_sop
        ),

        .video_in_endofpacket (
            video_eop
        ),

        .video_in_valid (
            video_valid
        ),

        .video_in_ready (
            video_ready
        ),

        .vga_CLK (
            VGA_CLK
        ),

        .vga_HS (
            VGA_HS
        ),

        .vga_VS (
            VGA_VS
        ),

        .vga_BLANK (
            VGA_BLANK_N
        ),

        .vga_SYNC (
            VGA_SYNC_N
        ),

        .vga_R (
            VGA_R
        ),

        .vga_G (
            VGA_G
        ),

        .vga_B (
            VGA_B
        )
    );

`endif


    // ============================================================
    // DEBUG SIGNAL SAMPLING
    //
    // These are board-display/debug signals only and are not used
    // by functional game logic.
    // ============================================================

    logic [9:0] peak_meta;
    logic [9:0] peak_50;

    logic [6:0] db_meta;
    logic [6:0] db_50;

    logic [1:0] class_meta;
    logic [1:0] class_50;

    logic voice_meta;
    logic voice_50;

    logic reject_meta;
    logic reject_50;


    always_ff @(posedge CLOCK_50) begin

        if (reset_50) begin

            peak_meta <= '0;
            peak_50   <= '0;

            db_meta <= '0;
            db_50   <= '0;

            class_meta <= '0;
            class_50   <= '0;

            voice_meta <= 1'b0;
            voice_50   <= 1'b0;

            reject_meta <= 1'b0;
            reject_50   <= 1'b0;

        end

        else begin

            peak_meta <= peak_k;
            peak_50   <= peak_meta;

            db_meta <= level_db_audio;
            db_50   <= db_meta;

            class_meta <= classifier_result;
            class_50   <= class_meta;

            voice_meta <= fft_voice_active;
            voice_50   <= voice_meta;

            reject_meta <= classifier_reject;
            reject_50   <= reject_meta;

        end

    end


    // ============================================================
    // Seven-segment decoder
    //
    // DE1-SoC HEX displays are active low.
    // ============================================================

    function automatic logic [6:0]
        seven_seg (
            input logic [3:0] digit
        );

        case (digit)

            4'd0:
                seven_seg = 7'b1000000;

            4'd1:
                seven_seg = 7'b1111001;

            4'd2:
                seven_seg = 7'b0100100;

            4'd3:
                seven_seg = 7'b0110000;

            4'd4:
                seven_seg = 7'b0011001;

            4'd5:
                seven_seg = 7'b0010010;

            4'd6:
                seven_seg = 7'b0000010;

            4'd7:
                seven_seg = 7'b1111000;

            4'd8:
                seven_seg = 7'b0000000;

            4'd9:
                seven_seg = 7'b0010000;

            default:
                seven_seg = 7'b1111111;

        endcase

    endfunction


    // ============================================================
    // HEX debug display
    //
    // HEX5..HEX3 = peak FFT bin 000..511
    // HEX2        = vowel 0..3 or blank
    // HEX1..HEX0  = microphone dB level
    //
    // This matches the frozen README board interface.
    // ============================================================

    logic [3:0] peak_hundreds;
    logic [3:0] peak_tens;
    logic [3:0] peak_ones;

    logic [3:0] db_tens;
    logic [3:0] db_ones;


    always_comb begin

        peak_hundreds =
            peak_50 / 100;

        peak_tens =
            (peak_50 % 100) / 10;

        peak_ones =
            peak_50 % 10;


        db_tens =
            db_50 / 10;

        db_ones =
            db_50 % 10;


        HEX5 =
            seven_seg(peak_hundreds);

        HEX4 =
            seven_seg(peak_tens);

        HEX3 =
            seven_seg(peak_ones);


        if (
            voice_50 &&
            !reject_50
        ) begin

            HEX2 =
                seven_seg(
                    {2'b00, class_50}
                );

        end

        else begin

            HEX2 =
                7'b1111111;

        end


        HEX1 =
            seven_seg(db_tens);

        HEX0 =
            seven_seg(db_ones);

    end


    // ============================================================
    // Microphone level LED bar
    // ============================================================

    always_comb begin

        for (
            int led_i = 0;
            led_i < 10;
            led_i = led_i + 1
        ) begin

            LEDR[led_i] =
                (
                    db_50 >=
                    ((led_i + 1) * 9)
                );

        end

    end


endmodule
