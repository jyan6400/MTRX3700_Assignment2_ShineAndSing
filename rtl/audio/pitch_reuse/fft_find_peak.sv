module fft_find_peak #(
    parameter NSamples = 1024,
    parameter W        = 33,
    parameter NBits    = $clog2(NSamples)
) (
    input                        clk,
    input                        reset,
    input  [W-1:0]               mag,
    input                        mag_valid,
    output logic [W-1:0]         peak = 0,
    output logic [NBits-1:0]     peak_k = 0,
    output logic                 peak_valid
);
    logic [NBits-1:0] i = 0, k;
    always_comb for (integer j=0; j<NBits; j=j+1) k[j] = i[NBits-1-j];

    logic [W-1:0]         peak_temp   = 0;
    logic [NBits-1:0]     peak_k_temp = 0;

    always_ff @(posedge clk) begin : find_peak
        peak_valid <= 1'b0;   // default: single-cycle pulse

        if (reset) begin
            i           <= 0;
            peak_temp   <= 0;
            peak_k_temp <= 0;
            peak        <= 0;
            peak_k      <= 0;
            peak_valid  <= 1'b0;
        end else if (mag_valid) begin
            // Compare, ignoring negative k (MSB set) and favouring the first peak
            if ((mag > peak_temp) && (k[NBits-1] == 1'b0)) begin
                peak_temp   <= mag;
                peak_k_temp <= k;
            end

            if (i == NSamples-1) begin
                // End of window: latch outputs and clear for the next one
                peak       <= peak_temp;
                peak_k     <= peak_k_temp;
                peak_valid <= 1'b1;

                i           <= 0;
                peak_temp   <= 0;
                peak_k_temp <= 0;
            end else begin
                i <= i + 1;
            end
        end else begin
            // Stream paused: restart the window
            i         <= 0;
            peak_temp <= 0;
        end
    end
endmodule
