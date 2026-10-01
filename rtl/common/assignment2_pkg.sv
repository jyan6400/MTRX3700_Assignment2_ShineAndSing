package assignment2_pkg;

    parameter int AUDIO_SAMPLE_W = 16;
    parameter int AUDIO_FS_IN    = 48000;
    parameter int AUDIO_FS_FFT   = 12000;

    parameter int FFT_N          = 1024;

    parameter int SYS_CLK_HZ     = 50_000_000;
    parameter int AUDIO_BCLK_HZ  = 3_072_000;
    parameter int FFT_CLK_HZ     = 18_432_000;
    parameter int PIXEL_CLK_HZ   = 25_000_000;

    parameter int N_VOWELS       = 4;
    parameter int N_LANES        = 4;

    parameter logic [1:0] VOWEL_EE = 2'd0;
    parameter logic [1:0] VOWEL_AH = 2'd1;
    parameter logic [1:0] VOWEL_OO = 2'd2;
    parameter logic [1:0] VOWEL_AW = 2'd3;

    parameter int CLASSIFIER_FW = 16;
    parameter int CLASSIFIER_D  = 24;

endpackage