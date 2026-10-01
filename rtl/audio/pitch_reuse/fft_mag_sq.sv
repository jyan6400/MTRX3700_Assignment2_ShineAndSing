module fft_mag_sq #(
    parameter W = 16
) (
    input                clk,
    input                reset,
    input                fft_valid,
    input        [W-1:0] fft_imag,
    input        [W-1:0] fft_real,
    output logic [W*2:0] mag_sq,
    output logic         mag_valid
);

    logic signed [W*2-1:0] multiply_stage_real, multiply_stage_imag;
    logic signed [W*2:0]   add_stage;

    // Valid shift register: tracks data through the 2 pipeline stages
    logic [1:0] valid_sr;

    always_ff @(posedge clk) begin
        if (reset) begin
            multiply_stage_real <= '0;
            multiply_stage_imag <= '0;
            add_stage           <= '0;
            valid_sr            <= 2'b00;
        end else begin
            // Stage 1: the two squares
            multiply_stage_real <= signed'(fft_real) * signed'(fft_real);
            multiply_stage_imag <= signed'(fft_imag) * signed'(fft_imag);

            // Stage 2: sum them
            add_stage <= signed'(multiply_stage_real) + signed'(multiply_stage_imag);

            // Valid travels alongside the data, one register per stage
            valid_sr <= {valid_sr[0], fft_valid};
        end
    end

    assign mag_sq    = add_stage;
    assign mag_valid = valid_sr[1];

endmodule
