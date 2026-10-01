// =============================================================================
// band_energy_8_tb.sv  --  NEW, Luke Mouawad
// Self-checking unit test for band_energy_8.sv (R-A2).
//
// Instance A: default configuration (bit-reversed FFT order, default edges).
// Instance B: natural order, different edges, OUT_SHIFT = 4.
// The expected ownership table is written out independently here (not read
// from the DUT), so a band edge that is off by one bin fails.
//
//   - exact bin ownership: an impulse in every bin k = 0..N-1, one per frame
//     (covers every band edge, DC, and the mirrored half k >= N/2)
//   - random spectra with random mag_valid gaps: band_acc exact, feature =
//     saturate(band_acc >> OUT_SHIFT)
//   - zero energy, maximum energy (no accumulator overflow, feature saturates)
//   - doubled amplitude (x4 energy) -> x4 band energies exactly
//   - exactly one feature_valid per frame, one clock after the last bin
//   - reset mid-frame re-aligns the bin counter
// =============================================================================
`timescale 1ns/1ps

module band_check #(
    parameter bit BIT_REVERSED = 1'b1,
    parameter logic [8:0][9:0] BAND_EDGES =
        {10'd512, 10'd448, 10'd384, 10'd320, 10'd256, 10'd192, 10'd128, 10'd64, 10'd0},
    parameter int OUT_SHIFT = 16,
    parameter int EXP_LO [8] = '{0, 64, 128, 192, 256, 320, 384, 448},      // first bin of band
    parameter int EXP_HI [8] = '{63, 127, 191, 255, 319, 383, 447, 511},    // last bin of band
    parameter string NAME = "A",
    parameter bit FULL_SWEEP = 1'b1
) (
    input  logic clk,
    output logic done
);
    localparam int N     = 1024;
    localparam int MAG_W = 33;
    localparam int NB    = 8;
    localparam int ACC_W = MAG_W + 9;
    localparam longint MAGMAX = (64'd1 << MAG_W) - 1;

    logic                     reset = 1'b1;
    logic [MAG_W-1:0]         mag_sq = '0;
    logic                     mag_valid = 1'b0;
    logic [NB-1:0][ACC_W-1:0] band_acc;
    logic [NB-1:0][15:0]      feature;
    logic                     feature_valid;

    band_energy_8 #(.N(N), .MAG_W(MAG_W), .BIT_REVERSED(BIT_REVERSED),
                    .BAND_EDGES(BAND_EDGES), .OUT_SHIFT(OUT_SHIFT)) dut (
        .clk, .reset, .mag_sq, .mag_valid, .band_acc, .feature, .feature_valid);

    function automatic int bitrev10(input int i);
        int r = 0;
        for (int j = 0; j < 10; j++) if (i[j]) r[9-j] = 1'b1;
        return r;
    endfunction

    function automatic int band_of(input int k);    // independent expectation
        for (int b = 0; b < NB; b++) if (k >= EXP_LO[b] && k <= EXP_HI[b]) return b;
        return -1;
    endfunction

    typedef logic [NB-1:0][63:0] vec_t;   // packed: Verilator 5.050 mis-copies queues of unpacked arrays
    vec_t   exp_q [$];
    longint spec [N];
    longint cycle = 0, last_bin_cycle = 0;
    int     n_frames_sent = 0, n_valid = 0;

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (!reset && feature_valid) begin
            vec_t   e;
            longint f;
            n_valid <= n_valid + 1;
            if (exp_q.size() == 0) $fatal(1, "[%s] unexpected feature_valid", NAME);
            if (cycle != last_bin_cycle + 1)
                $fatal(1, "[%s] feature_valid not one clock after the last bin", NAME);
            e = exp_q.pop_front();
            for (int b = 0; b < NB; b++) begin
                f = e[b] >> OUT_SHIFT;
                if (f > 65535) f = 65535;
                if (longint'(band_acc[b]) != e[b])
                    $fatal(1, "[%s] band %0d: acc %0d != expected %0d", NAME, b, band_acc[b], e[b]);
                if (longint'(feature[b]) != f)
                    $fatal(1, "[%s] band %0d: feature %0d != expected %0d", NAME, b, feature[b], f);
            end
        end
    end

    task automatic send_frame(input bit gaps);
        vec_t e;
        for (int b = 0; b < NB; b++) e[b] = 0;
        for (int k = 0; k < N; k++) begin
            int b = band_of(k);
            if (b >= 0) e[b] += spec[k];
        end
        exp_q.push_back(e);
        for (int i = 0; i < N; i++) begin
            int k = BIT_REVERSED ? bitrev10(i) : i;
            mag_sq    <= MAG_W'(spec[k]);
            mag_valid <= 1'b1;
            @(posedge clk);
            if (i == N - 1) last_bin_cycle = cycle;   // edge that sampled the last bin
            if (gaps && $urandom_range(4, 0) == 0) begin
                mag_valid <= 1'b0;
                repeat ($urandom_range(3, 1)) @(posedge clk);
            end
        end
        mag_valid <= 1'b0;
        n_frames_sent++;
        repeat (2) @(posedge clk);
        if (exp_q.size() != 0) $fatal(1, "[%s] frame %0d produced no feature_valid", NAME, n_frames_sent);
    endtask

    initial begin
        done = 1'b0;
        repeat (3) @(posedge clk);
        reset <= 1'b0;
        @(posedge clk);

        // exact ownership of every bin
        for (int kk = 0; kk < N; kk++) begin
            if (!FULL_SWEEP && !(kk < 4 || kk > N - 3 || band_of(kk) != band_of(kk - 1)
                                 || band_of(kk) != band_of(kk + 1))) continue;
            for (int k = 0; k < N; k++) spec[k] = 0;
            spec[kk] = 1000 + kk;
            send_frame(1'b0);
        end
        $display("[%s] bin ownership verified", NAME);

        // zero energy
        for (int k = 0; k < N; k++) spec[k] = 0;
        send_frame(1'b0);

        // maximum energy
        for (int k = 0; k < N; k++) spec[k] = MAGMAX;
        send_frame(1'b0);

        // random spectra with gaps, then the same spectrum doubled in amplitude
        for (int f = 0; f < 12; f++) begin
            for (int k = 0; k < N; k++)
                spec[k] = {$urandom, $urandom} >> $urandom_range(63, 31);
            send_frame(1'b1);
            for (int k = 0; k < N; k++) spec[k] = spec[k] >> 3;   // keep x4 in range
            send_frame(1'b1);
            for (int k = 0; k < N; k++) spec[k] = spec[k] * 4;    // 2x amplitude
            send_frame(1'b1);
        end

        // reset mid-frame: counter re-aligns, next frame still exact
        mag_valid <= 1'b1;
        for (int i = 0; i < 300; i++) begin
            mag_sq <= MAG_W'(123); @(posedge clk);
        end
        mag_valid <= 1'b0;
        reset <= 1'b1; @(posedge clk); reset <= 1'b0; @(posedge clk);
        for (int k = 0; k < N; k++) spec[k] = k * 7 + 1;
        send_frame(1'b0);

        repeat (3) @(posedge clk);
        if (n_valid != n_frames_sent)
            $fatal(1, "[%s] %0d feature_valid pulses for %0d frames", NAME, n_valid, n_frames_sent);
        $display("[%s] %0d frames, one feature_valid each", NAME, n_frames_sent);
        done = 1'b1;
    end
endmodule

module band_energy_8_tb;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic done_a, done_b;

    band_check #(.NAME("A_bitrev_default")) u_a (.clk, .done(done_a));

    band_check #(
        .BIT_REVERSED(1'b0),
        .BAND_EDGES({10'd500, 10'd400, 10'd300, 10'd200, 10'd100, 10'd50, 10'd20, 10'd10, 10'd5}),
        .OUT_SHIFT(4),
        .EXP_LO('{5, 10, 20, 50, 100, 200, 300, 400}),
        .EXP_HI('{9, 19, 49, 99, 199, 299, 399, 499}),
        .NAME("B_natural"), .FULL_SWEEP(1'b0)) u_b (.clk, .done(done_b));

    initial begin
        wait (done_a && done_b);
        $display("ALL TESTS PASSED: band_energy_8");
        $finish;
    end
endmodule
