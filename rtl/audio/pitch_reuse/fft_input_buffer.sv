module fft_input_buffer #(
    parameter W = 16,
    parameter NSamples = 1024
) (
     input                clk,
     input                reset,
     input                audio_clk,

     input  logic         audio_input_valid,
     output logic         audio_input_ready,
     input  logic [W:0]   audio_input_data,

     output logic [W-1:0] fft_input,
     output logic         fft_input_valid
);
    logic fft_read;
    logic full, wr_full;
    async_fifo u_fifo (.aclr(reset),
                        .data(audio_input_data),.wrclk(audio_clk),.wrreq(audio_input_valid),.wrfull(wr_full),
                        .q(fft_input),          .rdclk(clk),      .rdreq(fft_read),         .rdfull(full)    );
    assign audio_input_ready = !wr_full;

    assign fft_input_valid = fft_read;

    // Counter for the 1024-sample burst read
    logic [$clog2(NSamples)-1:0] n;

    // Read while the FIFO is full, and keep reading until the counter wraps
    assign fft_read = full | (n != 0);

    always_ff @(posedge clk) begin : fifo_flush
        if (reset) begin
            n <= 0;
        end else if (fft_read) begin
            n <= n + 1;   // wraps back to 0 after NSamples counts
        end
    end

endmodule
