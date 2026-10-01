`timescale 1ns/1ns
module decimate #(parameter W = 16, DECIMATE_FACTOR = 4) (
    input clk,

    input  logic x_valid,
    output logic x_ready,
    input  logic [W-1:0] x_data,

    output logic y_valid,
    input  logic y_ready,
    output logic [W-1:0] y_data
);

    logic [2*W-1:0] conv_output_data;
    logic conv_output_valid;
    logic conv_output_ready;

    logic [$clog2(DECIMATE_FACTOR)-1:0] decimate_counter = 0;

    low_pass_conv #(.W(2*W), .W_FRAC(W)) u_decimation_filter ( // Use 32 bits, 16 bit fraction.
        .clk(clk),
        .x_data({x_data, {W{1'b0}} }), // Make audio samples the integer part (32 bits, 16 bit fraction).
        .x_valid(x_valid),
        .x_ready(x_ready),
        .y_data(conv_output_data),
        .y_valid(conv_output_valid),
        .y_ready(y_ready)
    );

    always_ff @(posedge clk) begin
        if (conv_output_valid && y_ready) begin
            decimate_counter <= (decimate_counter == DECIMATE_FACTOR-1) ? 0 : decimate_counter + 1; // Count from 0 to DECIMATE_FACTOR-1.
        end
    end

    assign y_data = conv_output_data[2*W-1:W]; // Retrieve the 16 bit integer part for our audio samples.
    assign y_valid = conv_output_valid && (decimate_counter == 0); // Down-sample! Only use every DECIMATE_FACTOR'th sample.

endmodule