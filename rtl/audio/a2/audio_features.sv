`timescale 1ns/1ps
// =============================================================================
// audio_features.sv  --  NEW, Luke Mouawad, audio subsystem wrapper (FFT side)
// -----------------------------------------------------------------------------
// FFT magnitude stream  ->  feature vector  ->  provided classifier  ->
// frozen Audio -> Game contract (vowel_valid / vowel_id, FFT clock domain).
//
//   RUNG = 1  R-A1  D = 1   feature[0]  = peak bin k (from fft_find_peak)
//   RUNG = 2  R-A2  D = 8   band_energy_8 : feature[b] = sat16(E_b >> BAND_SHIFT)
//   RUNG = 3  R-A3  D = 8   band_energy_8 -> band_normalise : E_b / sum E, Q0.16
//   RUNG = 4  R-A4  D = 24  mel_filterbank_24 -> log2_energy (Q6.10)
//                           -> minus per-frame mean (LOG_MEAN_NORM) + 32768
//   Only D changes between rungs, as the classifier interface requires. The
//   matching templates.svh must be generated for the same RUNG/D.
//
// R-A4 feature format (unsigned 16 bit):
//   L_m        = log2(mel_energy_m), Q6.10 (1 LSB = 1/1024 of a doubling
//                = 0.00588 dB of power), 0 for zero energy
//   mean       = (sum_m L_m * MEAN_MULT) >> 16,  MEAN_MULT = round(2^16/NM)
//   feature[m] = sat_u16(L_m - mean + 32768)       (LOG_MEAN_NORM = 1)
//   A gain g on the microphone adds 2*log2(g) to every L_m and to the mean,
//   so it cancels: 2x amplitude changes each feature by at most 2 LSB.
//
// Gate / classifier / event:
//   voice_active_async (audio_gate, BCLK domain) -> 2-FF synchroniser ->
//   voice_active, which drives the classifier enable.
//   vowel_valid = one-clock pulse on the rising edge of
//                 (classifier result_valid AND NOT reject AND voice_active)
//   vowel_id    = classifier result, registered with vowel_valid and held
//                 until the next event (stable for the audio_game_cdc capture).
//
// Clock/reset domain : FFT clock (18.432 MHz), synchronous active-high reset.
// Latency (R-A4)     : mel +4 clk, log/serialise NM+4 clk, normalise +1 clk
//                      -> feature_valid ~33 clk after the frame's last bin.
// =============================================================================
module audio_features #(
    parameter int RUNG          = 4,
    parameter int N             = 1024,
    parameter int MAG_W         = 33,
    parameter bit BIT_REVERSED  = 1'b1,
    parameter int FW            = 16,
    parameter int NCLASS        = 4,
    parameter int NT            = 4,
    parameter int M             = 5,         // classifier vote length (odd)
    parameter int DMAX          = 65535,     // classifier: reject if nearest distance > DMAX
    parameter int RHO_NUM       = 7,         // classifier: reject if d1/d2 > RHO_NUM/RHO_DEN
    parameter int RHO_DEN       = 10,
    parameter int BAND_SHIFT    = 8,         // R-A2 energy scaling. FFT.v scales by 1/N, so a
                                             // sung harmonic of amplitude a gives |X|^2 ~ (0.27a)^2:
                                             // a 60 dB voice puts ~2^18 in a band -> ~1000 here,
                                             // +36 dB saturates. Calibrate on SignalTap captures.
    parameter bit LOG_MEAN_NORM = 1'b1,      // R-A4 level normalisation
    // derived -- do not override
    parameter int D             = (RUNG == 1) ? 1 : (RUNG == 4) ? 24 : 8
) (
    input  logic                  clk,
    input  logic                  reset,
    // from the reused FFT pitch detector (FFT clock domain). Each rung uses
    // either mag_* or peak_*; the other pair is intentionally unconnected.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [MAG_W-1:0]      mag_sq,
    input  logic                  mag_valid,
    input  logic [9:0]            peak_k,
    input  logic                  peak_valid,
    /* verilator lint_on UNUSEDSIGNAL */
    // from audio_gate (codec BCLK domain, registered)
    input  logic                  voice_active_async,
    // feature vector (also the classifier input)
    output logic [D-1:0][FW-1:0]  feature,
    output logic                  feature_valid,
    // Contract A (FFT clock domain; audio_game_cdc crosses it to 50 MHz)
    output logic                  vowel_valid,
    output logic [1:0]            vowel_id,
    // Contract C debug (FFT clock domain)
    output logic                  voice_active,
    output logic [1:0]            classifier_result,
    output logic                  classifier_result_valid,
    output logic                  classifier_reject,
    output logic [7:0]            confidence
);
    // ---------------- voice_active: BCLK -> FFT clock, 2-FF synchroniser ----
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic va_meta, va_sync;
    always_ff @(posedge clk) begin
        if (reset) begin va_meta <= 1'b0; va_sync <= 1'b0; end
        else       begin va_meta <= voice_active_async; va_sync <= va_meta; end
    end
    assign voice_active = va_sync;

    // ---------------- feature pipeline, selected by RUNG --------------------
    generate
        if (RUNG == 1) begin : g_ra1
            // R-A1: the peak bin itself is the (1-D) feature
            always_ff @(posedge clk) begin
                if (reset) begin feature <= '0; feature_valid <= 1'b0; end
                else begin
                    feature_valid <= peak_valid;
                    if (peak_valid) feature[0] <= FW'(peak_k);
                end
            end

        end else if (RUNG == 2) begin : g_ra2
            logic [7:0][MAG_W+$clog2(N/2)-1:0] band_acc_unused;
            band_energy_8 #(.N(N), .MAG_W(MAG_W), .BIT_REVERSED(BIT_REVERSED),
                            .OUT_SHIFT(BAND_SHIFT)) u_bands (
                .clk, .reset, .mag_sq, .mag_valid,
                .band_acc(band_acc_unused), .feature(feature), .feature_valid(feature_valid));

        end else if (RUNG == 3) begin : g_ra3
            localparam int ACC_W = MAG_W + $clog2(N / 2);
            logic [7:0][ACC_W-1:0] band_acc;
            logic [7:0][15:0]      band_feat_unused;
            logic                  band_valid, norm_busy_unused;
            band_energy_8 #(.N(N), .MAG_W(MAG_W), .BIT_REVERSED(BIT_REVERSED),
                            .OUT_SHIFT(BAND_SHIFT)) u_bands (
                .clk, .reset, .mag_sq, .mag_valid,
                .band_acc(band_acc), .feature(band_feat_unused), .feature_valid(band_valid));
            band_normalise #(.NB(8), .ACC_W(ACC_W)) u_norm (
                .clk, .reset, .band_acc, .in_valid(band_valid),
                .feature(feature), .feature_valid(feature_valid), .busy(norm_busy_unused));

        end else begin : g_ra4
            localparam int NM        = 24;
            localparam int W_F       = 10;
            localparam int MACC_W    = MAG_W + W_F + $clog2(N / 2);
            localparam int L_W       = $clog2(MACC_W) + 10;       // 16 for MAG_W = 33
            localparam int MEAN_MULT = (65536 + NM / 2) / NM;     // 2731
            localparam int IW        = $clog2(NM + 1);

            logic [NM-1:0][MACC_W-1:0] mel_energy;
            logic                      mel_valid;
            mel_filterbank_24 #(.N(N), .MAG_W(MAG_W), .BIT_REVERSED(BIT_REVERSED),
                                .W_F(W_F)) u_mel (
                .clk, .reset, .mag_sq, .mag_valid, .mel_energy, .mel_valid);

            // serialise the 24 energies through one log2 converter
            logic [IW-1:0]     in_idx, out_idx;
            logic              feeding;
            logic [MACC_W-1:0] log_x;
            logic              log_in_valid, log_out_valid;
            logic [L_W-1:0]    log_y;
            logic              log_zero_unused;

            always_comb begin
                log_x = '0;
                for (int m = 0; m < NM; m++) if (in_idx == IW'(m)) log_x = mel_energy[m];
            end
            assign log_in_valid = feeding;

            log2_energy #(.IN_W(MACC_W), .FRAC_W(10)) u_log2 (
                .clk, .reset, .x(log_x), .in_valid(log_in_valid),
                .y(log_y), .out_valid(log_out_valid), .zero(log_zero_unused));

            logic [NM-1:0][L_W-1:0] logmel;
            logic [L_W+IW-1:0]      log_sum;
            logic                   norm_go;

            // mean and normalised features (combinational on the collected frame)
            logic [L_W+IW+16-1:0]    mean_full;
            logic [L_W-1:0]          mean_c;
            logic [NM-1:0][FW-1:0]   norm_c;
            always_comb begin
                mean_full = (L_W+IW+16)'(log_sum) * (L_W+IW+16)'(MEAN_MULT);
                mean_c    = L_W'(mean_full >> 16);
                for (int m = 0; m < NM; m++) begin
                    logic signed [L_W+2:0] v;
                    if (LOG_MEAN_NORM)
                        v = $signed({3'b000, logmel[m]}) - $signed({3'b000, mean_c}) + (L_W+3)'(32768);
                    else
                        v = $signed({3'b000, logmel[m]});
                    if (v < 0)                          norm_c[m] = '0;
                    else if (v > (L_W+3)'(65535))       norm_c[m] = '1;
                    else                                norm_c[m] = FW'(v);
                end
            end

            always_ff @(posedge clk) begin
                if (reset) begin
                    in_idx <= '0; out_idx <= '0; feeding <= 1'b0;
                    logmel <= '0; log_sum <= '0; norm_go <= 1'b0;
                    feature <= '0; feature_valid <= 1'b0;
                end else begin
                    feature_valid <= 1'b0;
                    norm_go       <= 1'b0;
                    // feed
                    if (mel_valid) begin
                        feeding <= 1'b1; in_idx <= '0;
                        out_idx <= '0;   log_sum <= '0;
                    end else if (feeding) begin
                        if (in_idx == IW'(NM - 1)) feeding <= 1'b0;
                        else                       in_idx  <= in_idx + 1'b1;
                    end
                    // collect
                    if (log_out_valid && !mel_valid) begin
                        logmel[out_idx] <= log_y;
                        log_sum         <= log_sum + (L_W+IW)'(log_y);
                        out_idx         <= out_idx + 1'b1;
                        if (out_idx == IW'(NM - 1)) norm_go <= 1'b1;
                    end
                    // normalise
                    if (norm_go) begin
                        feature       <= norm_c;
                        feature_valid <= 1'b1;
                    end
                end
            end
        end
    endgenerate

    // ---------------- provided classifier (unchanged) -----------------------
    classifier #(.D(D), .FW(FW), .NCLASS(NCLASS), .NT(NT), .M(M),
                 .DMAX(DMAX), .RHO_NUM(RHO_NUM), .RHO_DEN(RHO_DEN)) u_classifier (
        .clk          (clk),
        .reset        (reset),
        .feature      (feature),
        .feature_valid(feature_valid),
        .enable       (voice_active),
        .result       (classifier_result),
        .confidence   (confidence),
        .reject       (classifier_reject),
        .result_valid (classifier_result_valid)
    );

    // ---------------- Contract A: one-shot qualified vowel event ------------
    logic qual, qual_d;
    assign qual = classifier_result_valid && !classifier_reject && voice_active;

    always_ff @(posedge clk) begin
        if (reset) begin
            qual_d      <= 1'b0;
            vowel_valid <= 1'b0;
            vowel_id    <= 2'd0;
        end else begin
            qual_d      <= qual;
            vowel_valid <= qual && !qual_d;
            if (qual && !qual_d) vowel_id <= classifier_result;
        end
    end
endmodule
