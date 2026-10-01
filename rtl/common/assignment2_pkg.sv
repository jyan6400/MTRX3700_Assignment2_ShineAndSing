package assignment2_pkg;

    // Clock domains
    localparam int unsigned SYS_CLK_HZ    = 50_000_000;
    localparam int unsigned AUDIO_BCLK_HZ = 3_072_000;
    localparam int unsigned FFT_CLK_HZ    = 18_432_000;
    localparam int unsigned PIXEL_CLK_HZ  = 25_000_000;

    // Audio sampling / FFT
    localparam int unsigned AUDIO_SAMPLE_W = 16;
    localparam int unsigned AUDIO_FS_IN    = 48_000;
    localparam int unsigned AUDIO_FS_FFT   = 12_000;
    localparam int unsigned FFT_N          = 1024;
    localparam int unsigned FFT_BIN_W      = 10;

    // Classifier / features
    localparam int unsigned N_VOWELS       = 4;
    localparam int unsigned CLASSIFIER_D   = 24;
    localparam int unsigned CLASSIFIER_FW  = 16;
    localparam int unsigned N_ENERGY_BANDS = 8;
    localparam int unsigned N_MEL_BANDS    = 24;

    // Vowel IDs
    localparam logic [1:0] VOWEL_EE = 2'd0;
    localparam logic [1:0] VOWEL_AH = 2'd1;
    localparam logic [1:0] VOWEL_OO = 2'd2;
    localparam logic [1:0] VOWEL_AW = 2'd3;

    // Game
    localparam int unsigned N_LANES      = 4;
    localparam int unsigned GAME_COUNT_W = 4;
    localparam int unsigned SCORE_W      = 16;

    // Source image / VGA
    localparam int unsigned IMG_W = 320;
    localparam int unsigned IMG_H = 240;
    localparam int unsigned PIX_W = 8;

    localparam int unsigned VGA_W = 640;
    localparam int unsigned VGA_H = 480;

    localparam int unsigned X_W = $clog2(IMG_W);
    localparam int unsigned Y_W = $clog2(IMG_H);

endpackage
