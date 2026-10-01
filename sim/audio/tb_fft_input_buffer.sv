`timescale 1 ns / 1 ns
module tb_fft_input_buffer;

    localparam NSamples = 1024;
    localparam W        = 16;

    localparam TCLK  = 50;  // 20 MHz.
    localparam TBCLK = 300; // x6 slower: 3.33 MHz

    logic clk = 0, audio_clk = 0;    //  Master Clock
    
    always #(TCLK/2)  clk       = ~clk;
    always #(TBCLK/2) audio_clk = ~audio_clk;
	 
    logic reset = 1'b1;

	logic         audio_input_valid;
	logic         audio_input_ready;
	logic [W-1:0] audio_input_data;
	
    logic [W-1:0] di_re;
    logic di_en;

    fft_input_buffer #(.W(W), .NSamples(NSamples)) u_fft_input_buffer (
        .clk(clk), 
        .reset(reset), 
        .audio_clk(audio_clk), 
        .audio_input_valid(audio_input_valid), 
        .audio_input_ready(audio_input_ready), 
        .audio_input_data(audio_input_data), 
        .fft_input(di_re), 
        .fft_input_valid(di_en)
    );

    logic [W-1:0] input_signal [NSamples];
    initial $readmemh("test_waveform.hex", input_signal);

    logic start = 1'b0; // Use a start flag.
    initial begin : test_procedure
        $dumpfile("waveform.vcd");
        $dumpvars();
        $display("");
        reset = 1'b1;
        #(TCLK*5);
        reset = 1'b0;
        #(TCLK*5);
        start = 1'b1;
        repeat (3) @(negedge di_en);
        #(TCLK*100);
        $finish();
    end

    initial #(TCLK*20000) $error("Test taking too long! Was di_en set high during FFT read and then set low after all 1024 values were read? Did you reset the counters for the next FFT window?");

    // Input Driver
    integer i = 0, next_i;
    assign next_i = i < NSamples-1 ? i + 1 : 0;
    always_ff @(posedge audio_clk) begin : driver
        audio_input_valid <= 1'b0;
        audio_input_data <= input_signal[i];
        if (start) begin
            audio_input_valid <= 1'b1;
            if (audio_input_valid && audio_input_ready) begin
                audio_input_data <= input_signal[next_i];
                i <= next_i;
            end
        end
    end

    // Output checks:
    integer n_count = 0, n_count_next;
    logic incorrect_value = 0, incorrect_duration = 0;
    assign n_count_next = di_en ? n_count+1 : 0;
    always_ff @(posedge clk) begin : monitor
        n_count <= n_count_next;
        if (!di_en && n_count > 0 && n_count < 1024) $display("Error: fft_input_valid high for %0d cycles, but should be high for consecutive 1024 cycles per FFT window.", n_count);
        if (!incorrect_duration && n_count > 1024) begin
            incorrect_duration = 1;
            $display("Error: fft_input_valid high for %0d cycles. This is more than the 1024 cycles required for the FFT window!\n", n_count);
        end
        if (!incorrect_value && di_en && di_re != input_signal[n_count]) begin
            $display("Error: Output #%0d from FIFO is %h, but should be %h.\nTo debug: check your waveforms for the first value of fft_input when fft_input_valid goes high. Use ./simulate.sh and gtkwave waveform.vcd.\n", n_count, di_re, input_signal[n_count]);
            incorrect_value = 1;
        end
    end

endmodule
