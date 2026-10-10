`timescale 1ns/1ps
module top_level_codec_tb;
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



    // WM8731 is the sole driver of the serial audio pins.
    logic signed [23:0] adc_left = 24'sh400000;
    logic signed [23:0] adc_right = -24'sh200000;
    logic frame_start;
    logic signed [23:0] dac_left, dac_right;
    logic dac_valid;
    wire codec_daclrc;
    pullup(FPGA_I2C_SDAT);

    wm8731_model #(.VERBOSE(0)) codec (
        .i2c_scl(FPGA_I2C_SCLK), .i2c_sda(FPGA_I2C_SDAT),
        .xck(AUD_XCK), .bclk(AUD_BCLK),
        .adclrc(AUD_ADCLRCK), .adcdat(AUD_ADCDAT),
        .daclrc(codec_daclrc), .dacdat(AUD_DACDAT),
        .adc_left(adc_left), .adc_right(adc_right),
        .frame_start(frame_start),
        .dac_left(dac_left), .dac_right(dac_right), .dac_valid(dac_valid)
    );

    initial begin
        CLOCK_50 = 0;
        forever #10 CLOCK_50 = ~CLOCK_50;
    end

    int codec_frames = 0;
    int decoded_samples = 0;
    int nonzero_samples = 0;
    logic [15:0] last_sample = 0;
    int changed_samples = 0;

    always @(posedge frame_start) begin
        codec_frames <= codec_frames + 1;
        // Use two different nonzero 16-bit-aligned patterns in successive frames.
        adc_left <= (codec_frames[0]) ? 24'sh400000 : -24'sh300000;
    end

    always @(posedge DUT.mic_valid) begin
        decoded_samples <= decoded_samples + 1;
        if (DUT.mic_sample != 0) nonzero_samples <= nonzero_samples + 1;
        if (decoded_samples > 0 && DUT.mic_sample != last_sample)
            changed_samples <= changed_samples + 1;
        last_sample <= DUT.mic_sample;
    end

    initial begin
        KEY = 4'b1110; // Assert active-low reset
        SW = 10'b0;
        repeat (12) @(posedge CLOCK_50);
        KEY[0] = 1'b1;

        // I2C: 11 commands, ~3.6 ms at a 100 kHz controller bit clock.
        wait (codec.write_count >= 11);
        repeat (4) @(posedge CLOCK_50);
        codec.print_summary();
        if (codec.check_mic_input_config(1,16,48000) != 0)
            $fatal(1,"WM8731 configuration mismatch");
        if (codec.error_count != 0 || codec.nack_count != 0)
            $fatal(1,"WM8731 I2C errors: protocol=%0d NACK=%0d",
                   codec.error_count, codec.nack_count);
        $display("PASS: I2C config: %0d writes", codec.write_count);

        wait (decoded_samples >= 8);
        if (codec_frames < 8 || nonzero_samples < 4 || changed_samples < 1)
            $fatal(1,"Audio receive: codec frames=%0d samples=%0d nonzero=%0d changed=%0d",
                   codec_frames,decoded_samples,nonzero_samples,changed_samples);
        $display("PASS: codec -> mic_load: frames=%0d samples=%0d nonzero=%0d changed=%0d",
                 codec_frames,decoded_samples,nonzero_samples,changed_samples);
        $display("CODEC INTEGRATION TEST PASSED at %0t",$time);
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1,"Codec integration global timeout: writes=%0d samples=%0d",codec.write_count,decoded_samples);
    end
endmodule
