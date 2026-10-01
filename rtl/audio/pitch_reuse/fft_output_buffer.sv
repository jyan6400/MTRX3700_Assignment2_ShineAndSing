// This is a helper debugging module designed to help read out the FFT magnitude result with SignalTap Logic Analyser.
// The `readout_data` should stream captured FFT magnitude input out in natural ordering.
// By plotting the `readout_data` bitvector in SignalTap live, you can see an intuitive frequency plot.
module fft_output_buffer #(
    parameter NSamples,
    parameter W,
    parameter NBits    = $clog2(NSamples)

) (
    input                        clk,
    input                        reset,
    input  [W-1:0]               mag,
    input                        mag_valid,
	 (* preserve *) (* noprune *) output logic                 [W-1:0] readout_data
);
    logic [NBits-1:0] i = 0, k;
    always_comb for (integer j=0; j<NBits; j=j+1) k[j] = i[NBits-1-j]; // bit-reversed index
	 
	 logic [W-1:0] ram_result [NSamples/2]; // Only store positive k (i[0]==0), so half of the FFT output.
	 (* preserve *) (* noprune *) logic en_readout;

    always_ff @(posedge clk) begin : store_result
        if (reset) begin
            i <= 0;
				en_readout <= 0;
        end else if (mag_valid) begin
            if (!i[0]) begin
				   ram_result[k] <= mag;
				end
				if (i == NSamples-1) begin
					 en_readout <= 1'b1;
					 i <= 0;
				end
				else begin
				    i <= i + 1;
				end
        end
        else begin
            i <= 0;
				en_readout <= 0;
        end
    end
	 
	 (* preserve *) (* noprune *) logic [$clog2(NSamples/2):0] readout_i;
	 
	 always_ff @(posedge clk) begin : readout_count
	   if (en_readout) begin
		    readout_i <= 1'b0;
	   end else if (readout_i < NSamples/2) begin
		    readout_i <= readout_i + 1;
	   end
		readout_data <= {ram_result[readout_i], {12{1'b0}}};
	 end
		
endmodule
