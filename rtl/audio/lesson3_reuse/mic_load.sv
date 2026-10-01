`timescale 1ps/1ps
module mic_load #(parameter N=16) (
	input bclk, // Assume a 18.432 MHz clock
    input adclrc,
	input adcdat,
    // No ready signal nor handshake: as this module streams live audio data, it cannot be stalled, therefore we only have the valid signal.
    output logic valid,
    output logic [N-1:0] sample_data
);
    // Assume that i2c has already configured the CODEC for LJ data, MSB-first and N-bit samples.

    // Rising edge detect on ADCLRC to sense left channel
    logic redge_adclrc, adclrc_q; 
    always_ff @(posedge  bclk) begin : adclrc_rising_edge_ff
        adclrc_q <= adclrc;
    end
    assign redge_adclrc = ~adclrc_q & adclrc; // rising edge detected!

    logic [N-1:0] temp_rx_data;        // Shift-in register: MSB first.
    logic [7:0]   bit_index = 0;       // Which bit of the word this edge carries (8 bits covers any sensible N).
    logic         receiving = 1'b0;    // High only while the left channel word is being received.

    initial valid = 1'b0;

    always_ff @(posedge bclk) begin : lj_receive
        valid <= 1'b0; // Default: `valid` is a single-cycle pulse.

        if (redge_adclrc) begin
            // First rising edge after ADCLRC rose: this edge carries the MSB.
            temp_rx_data[N-1] <= adcdat;
            bit_index         <= 8'd1;
            receiving         <= 1'b1;
        end
        else if (receiving) begin
            temp_rx_data[(N-1)-bit_index] <= adcdat;

            if (bit_index == N-1) begin
                // This edge completes the word. Take the LSB straight from the line:
                // temp_rx_data[0] is only written at *this* edge, so it is one edge behind.
                sample_data <= {temp_rx_data[N-1:1], adcdat};
                valid       <= 1'b1;
                receiving   <= 1'b0; // Ignore the remaining bits and the whole right channel.
            end

            bit_index <= bit_index + 1'b1;
        end
    end

endmodule
