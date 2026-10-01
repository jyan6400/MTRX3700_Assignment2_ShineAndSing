`timescale 1ns/1ps
// =============================================================================
// band_energy_8.sv  --  NEW, Luke Mouawad, R-A2 (energy in eight bands)
// -----------------------------------------------------------------------------
// Accumulates the FFT magnitude-squared stream of one frame into NB = 8 bands.
//
//   Input stream : one |X_k|^2 per mag_valid, N per frame, in FFT output order.
//                  The bin index k is recovered with an internal counter i:
//                  k = bitrev(i) when BIT_REVERSED = 1 (radix-2^2 SDF FFT
//                  output order), k = i otherwise. Gaps in mag_valid are fine.
//   Ownership    : band b owns bins BAND_EDGES[b] <= k < BAND_EDGES[b+1]
//                  (lower edge inclusive, upper edge exclusive). Bins outside
//                  [BAND_EDGES[0], BAND_EDGES[NB]) -- the mirrored half
//                  k >= N/2 and the Nyquist bin 512 -- are ignored.
//   Output       : band_acc[b]  raw energy sum, ACC_W bits, never overflows
//                  feature[b]   = saturate16(band_acc[b] >> OUT_SHIFT)
//                  feature_valid: one-clock pulse per completed frame, one
//                  clock after the frame's last bin; outputs held until the
//                  next frame completes.
//
// Default edges = tools/audio/audio_model.py band_energies(): 8 equal bands of
// 64 bins (750 Hz) over 0-6 kHz, BAND_EDGES[b] = 64*b (print with rtl_tables()).
//   band : 0     1       2        3        4        5        6        7
//   bins : 0-63  64-127  128-191  192-255  256-319  320-383  384-447  448-511
//   Hz   : 0-750 ...                                                  5250-6000
// Bin 0 (DC) is kept as in the model; the WM8731 ADC high-pass removes the DC.
//
// Clock/reset domain : FFT clock (18.432 MHz), synchronous active-high reset.
// Reset clears the partial frame and the bin counter (frame re-alignment).
// =============================================================================
module band_energy_8 #(
    parameter int N            = 1024,
    parameter int MAG_W        = 33,
    parameter bit BIT_REVERSED = 1'b1,
    parameter int NB           = 8,
    parameter logic [NB:0][9:0] BAND_EDGES =
        {10'd512, 10'd448, 10'd384, 10'd320, 10'd256, 10'd192, 10'd128, 10'd64, 10'd0},
    parameter int OUT_SHIFT    = 8,              // see BAND_SHIFT in audio_features.sv
    parameter int ACC_W        = MAG_W + $clog2(N / 2)
) (
    input  logic                        clk,
    input  logic                        reset,
    input  logic [MAG_W-1:0]            mag_sq,
    input  logic                        mag_valid,
    output logic [NB-1:0][ACC_W-1:0]    band_acc,
    output logic [NB-1:0][15:0]         feature,
    output logic                        feature_valid
);
    localparam int KW = $clog2(N);

    logic [KW-1:0] i_cnt, k;
    always_comb begin
        for (int j = 0; j < KW; j++)
            k[j] = BIT_REVERSED ? i_cnt[KW-1-j] : i_cnt[j];
    end

    // one-hot band ownership of the current bin
    logic [NB-1:0] own;
    always_comb begin
        for (int b = 0; b < NB; b++)
            own[b] = (k >= KW'(BAND_EDGES[b])) && (k < KW'(BAND_EDGES[b+1]));
    end

    logic [NB-1:0][ACC_W-1:0] acc, sum;
    always_comb begin
        for (int b = 0; b < NB; b++)
            sum[b] = acc[b] + (own[b] ? ACC_W'(mag_sq) : '0);
    end

    function automatic logic [15:0] sat16(input logic [ACC_W-1:0] v);
        logic [ACC_W-1:0] s;
        s = v >> OUT_SHIFT;
        return (s > ACC_W'(16'hFFFF)) ? 16'hFFFF : s[15:0];
    endfunction

    always_ff @(posedge clk) begin
        if (reset) begin
            i_cnt         <= '0;
            acc           <= '0;
            band_acc      <= '0;
            feature       <= '0;
            feature_valid <= 1'b0;
        end else begin
            feature_valid <= 1'b0;
            if (mag_valid) begin
                i_cnt <= i_cnt + 1'b1;                 // wraps at N (power of two)
                if (i_cnt == KW'(N - 1)) begin         // last bin of the frame
                    for (int b = 0; b < NB; b++) begin
                        band_acc[b] <= sum[b];
                        feature[b]  <= sat16(sum[b]);
                    end
                    acc           <= '0;
                    feature_valid <= 1'b1;
                end else begin
                    acc <= sum;
                end
            end
        end
    end
endmodule
