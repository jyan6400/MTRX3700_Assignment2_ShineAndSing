// =============================================================================
// mel_filterbank_24_tb.sv  --  NEW, Luke Mouawad
// Self-checking unit test for mel_filterbank_24.sv (R-A4).
// The Mel points are written out here independently of the RTL default.
//
//   - exact filter ownership: an impulse in every bin k = 0..N-1; checks which
//     filters receive energy, the exact weights, that the two weights of a bin
//     sum to exactly 1.0, and that each weight is within 1 LSB of the ideal
//     triangle (k - lo) / width. Bins outside [pt0, pt25) give nothing.
//   - random spectra with mag_valid gaps: every energy exact vs model
//   - flat spectrum vs ideal floating-point triangles (<0.5 % error)
//   - zero energy, maximum energy (no overflow)
//   - doubled amplitude -> x4 energies exactly
//   - one mel_valid per frame, 4 clocks after the last bin
//   - reset mid-frame re-aligns the bin counter
// =============================================================================
`timescale 1ns/1ps

module mel_filterbank_24_tb;
    localparam int N     = 1024;
    localparam int MAG_W = 33;
    localparam int NM    = 24;
    localparam int W_F   = 10;
    localparam int RS    = 16;
    localparam int ACC_W = MAG_W + W_F + 9;
    localparam longint MAGMAX = (64'd1 << MAG_W) - 1;
    localparam int LAT   = 4;

    // expected Mel points (100-5000 Hz, 24 filters, fs 12 kHz, N 1024)
    localparam int PTS [NM+2] = '{9, 14, 20, 27, 34, 41, 50, 59, 68, 79, 90, 102, 115,
                                  130, 145, 162, 180, 200, 221, 244, 269, 296, 325,
                                  356, 390, 427};

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic                     reset = 1'b1;
    logic [MAG_W-1:0]         mag_sq = '0;
    logic                     mag_valid = 1'b0;
    logic [NM-1:0][ACC_W-1:0] mel_energy;
    logic                     mel_valid;

    mel_filterbank_24 dut (.clk, .reset, .mag_sq, .mag_valid, .mel_energy, .mel_valid);

    function automatic int bitrev10(input int i);
        int r = 0;
        for (int j = 0; j < 10; j++) if (i[j]) r[9-j] = 1'b1;
        return r;
    endfunction

    // weight of bin k in filter m, Q0.W_F  (the hardware's defining formula)
    function automatic longint weight(input int m, input int k);
        int     s = -1;
        longint w, off, rc, r;
        for (int j = 0; j <= NM; j++) if (k >= PTS[j] && k < PTS[j+1]) s = j;
        if (s < 0) return 0;
        w   = PTS[s+1] - PTS[s];
        off = k - PTS[s];
        rc  = ((64'd1 << (W_F + RS)) + w / 2) / w;
        r   = (off * rc) >>> RS;
        if (r >= (1 << W_F)) r = (1 << W_F) - 1;
        if (m == s)     return r;
        if (m == s - 1) return (1 << W_F) - r;
        return 0;
    endfunction

    function automatic real absr(input real v);
        return (v < 0.0) ? -v : v;
    endfunction

    typedef logic [NM-1:0][63:0] vec_t;   // packed: Verilator 5.050 mis-copies queues of unpacked arrays
    vec_t   exp_q [$];
    longint spec [N];
    longint cycle = 0, last_bin_cycle = 0;
    int     n_sent = 0, n_valid = 0;

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (!reset && mel_valid) begin
            vec_t e;
            n_valid++;
            if (exp_q.size() == 0) $fatal(1, "unexpected mel_valid");
            if (cycle != last_bin_cycle + LAT)
                $fatal(1, "mel_valid %0d clocks after last bin, expected %0d", cycle - last_bin_cycle, LAT);
            e = exp_q.pop_front();
            for (int m = 0; m < NM; m++)
                if (longint'(mel_energy[m]) != e[m])
                    $fatal(1, "filter %0d: energy %0d != expected %0d", m, mel_energy[m], e[m]);
        end
    end

    task automatic send_frame(input bit gaps);
        vec_t e;
        for (int m = 0; m < NM; m++) begin
            e[m] = 0;
            for (int k = PTS[m]; k < PTS[m+2]; k++) e[m] += spec[k] * weight(m, k);
        end
        exp_q.push_back(e);
        for (int i = 0; i < N; i++) begin
            mag_sq    <= MAG_W'(spec[bitrev10(i)]);
            mag_valid <= 1'b1;
            @(posedge clk);
            if (i == N - 1) last_bin_cycle = cycle;
            if (gaps && $urandom_range(4, 0) == 0) begin
                mag_valid <= 1'b0;
                repeat ($urandom_range(3, 1)) @(posedge clk);
            end
        end
        mag_valid <= 1'b0;
        n_sent++;
        repeat (LAT + 2) @(posedge clk);
        if (exp_q.size() != 0) $fatal(1, "frame %0d produced no mel_valid", n_sent);
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset <= 1'b0;
        @(posedge clk);

        // ---- weight table sanity against the ideal triangle ----
        for (int k = 0; k < N; k++) begin
            automatic longint tot = 0;
            automatic int     s = -1;
            for (int j = 0; j <= NM; j++) if (k >= PTS[j] && k < PTS[j+1]) s = j;
            for (int m = 0; m < NM; m++) tot += weight(m, k);
            if (s < 0 && tot != 0) $fatal(1, "bin %0d outside the filterbank has weight", k);
            if (s >= 1 && s <= NM - 1 && tot != (1 << W_F))
                $fatal(1, "bin %0d: weights sum to %0d, not 1.0", k, tot);
            if (s >= 0 && s <= NM - 1) begin
                automatic real ideal = real'(k - PTS[s]) / real'(PTS[s+1] - PTS[s]) * real'(1 << W_F);
                if (absr(real'(weight(s, k)) - ideal) > 1.0)
                    $fatal(1, "bin %0d: rising weight %0d vs ideal %f", k, weight(s, k), ideal);
            end
        end

        // ---- exact ownership: impulse in every bin ----
        for (int kk = 0; kk < N; kk++) begin
            for (int k = 0; k < N; k++) spec[k] = 0;
            spec[kk] = 100000 + kk;
            send_frame(1'b0);
        end
        $display("filter ownership verified for all %0d bins", N);

        // ---- zero and maximum energy ----
        for (int k = 0; k < N; k++) spec[k] = 0;
        send_frame(1'b0);
        for (int k = 0; k < N; k++) spec[k] = MAGMAX;
        send_frame(1'b0);

        // ---- flat spectrum vs ideal floating-point triangles ----
        for (int k = 0; k < N; k++) spec[k] = 1 << 20;
        send_frame(1'b0);
        for (int m = 0; m < NM; m++) begin
            automatic real ideal = 0.0, got;
            for (int k = PTS[m]; k < PTS[m+1]; k++) ideal += real'(k - PTS[m]) / real'(PTS[m+1] - PTS[m]);
            for (int k = PTS[m+1]; k < PTS[m+2]; k++) ideal += 1.0 - real'(k - PTS[m+1]) / real'(PTS[m+2] - PTS[m+1]);
            ideal = ideal * real'(1 << 20) * real'(1 << W_F);
            got   = real'(mel_energy[m]);
            if (absr(got - ideal) / ideal > 0.005)
                $fatal(1, "flat spectrum filter %0d: %f vs ideal %f", m, got, ideal);
        end

        // ---- random spectra, and the same at doubled amplitude ----
        for (int f = 0; f < 10; f++) begin
            vec_t first;
            for (int k = 0; k < N; k++) spec[k] = ({$urandom, $urandom} >> $urandom_range(63, 33));
            send_frame(1'b1);
            for (int m = 0; m < NM; m++) first[m] = mel_energy[m];
            for (int k = 0; k < N; k++) spec[k] = spec[k] * 4;
            send_frame(1'b1);
            for (int m = 0; m < NM; m++)
                if (longint'(mel_energy[m]) != 4 * first[m]) $fatal(1, "2x amplitude not x4 energy");
        end

        // ---- reset mid-frame ----
        mag_valid <= 1'b1;
        for (int i = 0; i < 500; i++) begin
            mag_sq <= MAG_W'(999); @(posedge clk);
        end
        mag_valid <= 1'b0;
        reset <= 1'b1; @(posedge clk); reset <= 1'b0; @(posedge clk);
        repeat (LAT + 2) @(posedge clk);
        for (int k = 0; k < N; k++) spec[k] = 3 * k + 5;
        send_frame(1'b0);

        if (n_valid != n_sent) $fatal(1, "%0d mel_valid for %0d frames", n_valid, n_sent);
        $display("%0d frames, one mel_valid each", n_sent);
        $display("ALL TESTS PASSED: mel_filterbank_24");
        $finish;
    end
endmodule
