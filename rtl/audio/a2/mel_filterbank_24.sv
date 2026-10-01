`timescale 1ns/1ps
// =============================================================================
// mel_filterbank_24.sv  --  NEW, Luke Mouawad, R-A4 (24 Mel-spaced bands)
// -----------------------------------------------------------------------------
// Triangular Mel filterbank applied to the FFT magnitude-squared stream.
//
//   Points      : MEL_PTS[0..NM+1], FFT bins equally spaced on the Mel scale
//                 = tools/audio/audio_model.py mel_bank(nf=24, fmin=100, fmax=6000):
//                   mel(f) = 2595*log10(1 + f/700)
//                   f_j    = mel^-1( mel(100) + j*(mel(6000)-mel(100))/25 ), j = 0..25
//                   MEL_PTS[j] = round(f_j * N / fs), N = 1024, fs = 12000
//                 (print with audio_model.rtl_tables())
//   Filter m    : rises on  [MEL_PTS[m],   MEL_PTS[m+1])  weight 0 -> 1
//                 falls on  [MEL_PTS[m+1], MEL_PTS[m+2])  weight 1 -> 0
//   A bin k in segment s (MEL_PTS[s] <= k < MEL_PTS[s+1]) therefore feeds
//                 filter s   with the rising weight   r         (if s <= NM-1)
//                 filter s-1 with the falling weight  1.0 - r   (if s >= 1)
//   Weight      : r = ((k - MEL_PTS[s]) * RECIP[s]) >> RS,  unsigned Q0.W_F
//                 RECIP[s] = round(2^(W_F+RS) / width[s]),  a constant per
//                 segment (no divider in hardware); r = floor(off/width) +-1 LSB.
//   Energy      : mel_energy[m] = sum_k weight_m(k) * |X_k|^2,  Q(MAG).W_F,
//                 ACC_W = MAG_W + W_F + 9 bits: cannot overflow (every bin
//                 contributes at most 1.0 in total to its two filters).
//
//   Input order : internal bin counter, k = bitrev(i) when BIT_REVERSED = 1.
//   Pipeline    : A register input | B weight | C multiply | D accumulate.
//                 mel_valid pulses 4 clocks after the frame's last bin; one
//                 pulse per N mag_valid; mel_energy held until the next frame.
//
// Why Mel (R-A4): the wide overlapping triangles above ~1 kHz each span
// several voice harmonics, so the vector follows the formant envelope rather
// than individual harmonics -> less sensitive to the sung pitch. The log and
// the per-frame mean removal (audio_features.sv) remove recording level.
//
// Resources: one 33x11 multiplier (DSP), one 6x26 multiplier, 24 x 52-bit
// accumulators + 24 x 52-bit output registers.
// Clock/reset domain : FFT clock, synchronous active-high reset.
// =============================================================================
module mel_filterbank_24 #(
    parameter int N            = 1024,
    parameter int MAG_W        = 33,
    parameter bit BIT_REVERSED = 1'b1,
    parameter int NM           = 24,
    parameter logic [NM+1:0][9:0] MEL_PTS =
        {10'd512, 10'd465, 10'd423, 10'd383, 10'd347, 10'd314, 10'd284, 10'd256,
         10'd230, 10'd206, 10'd185, 10'd165, 10'd146, 10'd130, 10'd114, 10'd100,
         10'd87,  10'd75,  10'd64,  10'd54,  10'd45,  10'd36,  10'd28,  10'd21,
         10'd15,  10'd9},
    parameter int W_F          = 10,             // weight fraction bits
    parameter int RS           = 16,             // extra reciprocal bits
    parameter int ACC_W        = MAG_W + W_F + $clog2(N / 2)
) (
    input  logic                     clk,
    input  logic                     reset,
    input  logic [MAG_W-1:0]         mag_sq,
    input  logic                     mag_valid,
    output logic [NM-1:0][ACC_W-1:0] mel_energy,
    output logic                     mel_valid
);
    localparam int KW   = $clog2(N);
    localparam int SW   = $clog2(NM + 2);
    localparam int RW   = W_F + RS + 1;          // reciprocal width
    localparam int OFFW = 10;
    localparam int WT_W = W_F + 1;               // weight incl. 1.0
    localparam int P_W  = MAG_W + WT_W;

    function automatic logic [RW-1:0] recip(input int w);
        return RW'(((64'd1 << (W_F + RS)) + 64'(w / 2)) / 64'(w));
    endfunction

    // ---------------- bin counter -----------------------------------------
    logic [KW-1:0] i_cnt, k_c;
    always_comb for (int j = 0; j < KW; j++) k_c[j] = BIT_REVERSED ? i_cnt[KW-1-j] : i_cnt[j];

    // ---------------- stage A: register the bin -----------------------------
    logic [MAG_W-1:0] mag_a;
    logic [KW-1:0]    k_a;
    logic             v_a, last_a;

    // segment lookup (combinational on stage A)
    logic [SW-1:0]    s_c;
    logic             inr_c;
    logic [OFFW-1:0]  off_c;
    logic [RW-1:0]    rcp_c;
    always_comb begin
        s_c   = '0;
        for (int j = 1; j <= NM + 1; j++)
            if (k_a >= KW'(MEL_PTS[j])) s_c = s_c + 1'b1;
        inr_c = (k_a >= KW'(MEL_PTS[0])) && (k_a < KW'(MEL_PTS[NM+1]));
        off_c = '0;
        rcp_c = '0;
        for (int j = 0; j <= NM; j++)
            if (s_c == SW'(j)) begin
                off_c = OFFW'(k_a) - OFFW'(MEL_PTS[j]);
                rcp_c = recip(int'(MEL_PTS[j+1]) - int'(MEL_PTS[j]));
            end
    end

    // ---------------- stage B: rising weight -------------------------------
    logic [OFFW+RW-1:0] wprod_c;
    logic [WT_W-1:0]    r_b;
    logic [SW-1:0]      s_b;
    logic               inr_b, v_b, last_b;
    logic [MAG_W-1:0]   mag_b;
    assign wprod_c = (OFFW+RW)'(off_c) * (OFFW+RW)'(rcp_c);

    // ---------------- stage C: weighted energies ----------------------------
    logic [P_W-1:0]   pu_c, pfull_c;
    logic [P_W-1:0]   pu_q, pd_q;
    logic [SW-1:0]    s_q;
    logic             inr_q, v_q, last_q;
    always_comb begin
        pu_c    = P_W'(mag_b) * P_W'(r_b);
        pfull_c = P_W'(mag_b) << W_F;
    end

    // ---------------- stage D: accumulate -----------------------------------
    logic [NM-1:0][ACC_W-1:0] acc, acc_n;
    always_comb begin
        for (int m = 0; m < NM; m++) begin
            acc_n[m] = acc[m];
            if (v_q && inr_q && s_q == SW'(m))     acc_n[m] = acc[m] + ACC_W'(pu_q);
            if (v_q && inr_q && s_q == SW'(m + 1)) acc_n[m] = acc[m] + ACC_W'(pd_q);
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            i_cnt  <= '0;
            v_a    <= 1'b0; last_a <= 1'b0; mag_a <= '0; k_a <= '0;
            v_b    <= 1'b0; last_b <= 1'b0; mag_b <= '0; r_b <= '0; s_b <= '0; inr_b <= 1'b0;
            v_q    <= 1'b0; last_q <= 1'b0; pu_q  <= '0; pd_q <= '0; s_q <= '0; inr_q <= 1'b0;
            acc        <= '0;
            mel_energy <= '0;
            mel_valid  <= 1'b0;
        end else begin
            // A
            v_a    <= mag_valid;
            last_a <= mag_valid && (i_cnt == KW'(N - 1));
            if (mag_valid) begin
                i_cnt <= i_cnt + 1'b1;
                mag_a <= mag_sq;
                k_a   <= k_c;
            end
            // B
            v_b    <= v_a;
            last_b <= last_a;
            mag_b  <= mag_a;
            s_b    <= s_c;
            inr_b  <= inr_c;
            r_b    <= ((wprod_c >> RS) >= (OFFW+RW)'(1 << W_F)) ? WT_W'((1 << W_F) - 1)
                                                                 : WT_W'(wprod_c >> RS);
            // C
            v_q    <= v_b;
            last_q <= last_b;
            s_q    <= s_b;
            inr_q  <= inr_b;
            pu_q   <= pu_c;
            pd_q   <= pfull_c - pu_c;
            // D
            mel_valid <= 1'b0;
            if (v_q && last_q) begin
                mel_energy <= acc_n;
                acc        <= '0;
                mel_valid  <= 1'b1;
            end else begin
                acc <= acc_n;
            end
        end
    end
endmodule
