`timescale 1ps/1ps
module fft_pitch_detect_tb;

    localparam NSamples = 1024;
    localparam W        = 16;

    localparam TCLK_50  = 20_000;  // 50 MHz (20 ns) for main clock
    localparam TXCK     = 54_253;  // 18.432 MHz (54.253 ns) for FFT clock (roughly 54.253ns period)
    localparam TBCLK    = TXCK * 6; // 3.072 MHz for audio clock (AUD_BCLK)

    // Clock generation
    logic fft_clk = 0;
    logic bclk = 0;
    logic reset = 1;

    always #(TXCK/2) fft_clk = ~fft_clk;
    always #(TBCLK/2) bclk = ~bclk;

    // DUT signals
    logic [W-1:0] audio_input_data;
    logic audio_input_valid;
    logic [$clog2(NSamples)-1:0] pitch_output_data;
    logic pitch_output_valid;

    // DUT instantiation
    fft_pitch_detect #(
        .NSamples(NSamples),
        .W(W)
    ) DUT (
        .audio_clk(bclk),
        .fft_clk(fft_clk),
        .reset(reset),
        .audio_input_data(audio_input_data),
        .audio_input_valid(audio_input_valid),
        .pitch_output_data(pitch_output_data),
        .pitch_output_valid(pitch_output_valid)
    );

    // Test waveform storage
    logic [W-1:0] input_signal [NSamples];
    initial $readmemh("test_waveform.hex", input_signal);

    logic start = 1'b0; // Use a start flag.
    initial begin : test_procedure
        $dumpfile("waveform.vcd");
        $dumpvars();
        reset = 1'b1;
        #(TXCK*5);
        reset = 1'b0;
        #(TXCK*5);
        start = 1'b1;
        repeat (5) @(negedge pitch_output_valid);
        #(TXCK*100);
        if (frames_ok == 5) $display("ALL TESTS PASSED: fft_pitch_detect_tb");
        else $fatal(1, "FAILED: %0d of 5 frames had the right peak", frames_ok);
        $finish();
    end

    // Input Driver
    integer i = 0, next_i;
    assign next_i = i < NSamples-1 ? i + 1 : 0;
    // one sample every CLKS_PER_SAMPLE bit clocks, as the codec delivers them (64 = 48 kHz at 3.072 MHz)
    localparam int CLKS_PER_SAMPLE = 64;
    integer pace = 0;
    always_ff @(posedge bclk) begin : driver
        audio_input_valid <= 1'b0;
        audio_input_data <= input_signal[i];
        if (start) begin
            pace <= (pace == CLKS_PER_SAMPLE-1) ? 0 : pace + 1;
            if (pace == 0) begin
                audio_input_valid <= 1'b1;
                audio_input_data <= input_signal[i];
                i <= next_i;
            end
        end
    end

    // Monitor for pitch output
    logic [$clog2(NSamples)-1:0] output_check;
    integer pitch_changes = 0;
    integer output_i = 0;
    integer frames_ok = 0;
    always_ff @(posedge fft_clk) begin : monitor
        if (pitch_output_valid) begin
            $display("frame %0d: peak bin k = %0d (%0.1f Hz)", output_i + 1, pitch_output_data, pitch_output_data * 12000.0 / NSamples);
            if (pitch_output_data == 84) frames_ok++;                       // test_waveform.hex is a 1 kHz tone: bin 85.3 -> 84 or 85
            else if (pitch_output_data == 85) frames_ok++;
            else $display("FAIL: expected k = 84 or 85 for the 1 kHz test tone");
            output_check <= pitch_output_data;
            output_i     <= output_i < NSamples-1 ? output_i + 1 : 0;
        end
    end

    // Timeout watchdog
    initial begin
        #(64'd3_000_000_000_000);  // 3 s timeout in ps (samples are paced at the real rate)
        $error("Timeout: Test took too long!");
        $finish();
    end

endmodule
