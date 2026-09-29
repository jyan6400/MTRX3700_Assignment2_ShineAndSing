// =============================================================================
// band_normalise_tb.sv  --  NEW, Luke Mouawad
// Self-checking unit test for band_normalise.sv (R-A3).
//   - 300 random band vectors over the full dynamic range: every feature equals
//     min(65535, floor(band * 2^16 / total)) computed here
//   - zero energy (total = 0) -> all zero
//   - all energy in one band -> 65535 there, 0 elsewhere (saturation)
//   - maximum energy in every band -> 8192 each (no overflow in total/remainder)
//   - doubled amplitude (every band x4) -> bit-identical vector
//   - in_valid while busy is ignored; exactly one feature_valid per accepted frame
//   - reset in the middle of a division -> no output, next frame correct
// =============================================================================
`timescale 1ns/1ps

module band_normalise_tb;
    localparam int NB    = 8;
    localparam int ACC_W = 42;
    localparam longint AMAX = (64'd1 << ACC_W) - 1;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic                     reset = 1'b1;
    logic [NB-1:0][ACC_W-1:0] band_acc = '0;
    logic                     in_valid = 1'b0;
    logic [NB-1:0][15:0]      feature;
    logic                     feature_valid, busy;

    band_normalise #(.NB(NB), .ACC_W(ACC_W)) dut (
        .clk, .reset, .band_acc, .in_valid, .feature, .feature_valid, .busy);

    int n_valid = 0;
    always @(posedge clk) if (!reset && feature_valid) n_valid++;

    typedef longint vec_t [NB];
    logic [NB-1:0][15:0] last_feature;

    function automatic longint expect_f(input vec_t v, input int b);
        longint tot = 0, q;
        for (int j = 0; j < NB; j++) tot += v[j];
        if (tot == 0) return 0;
        q = (v[b] <<< 16) / tot;      // v[b] < 2^42 -> product < 2^58
        return (q > 65535) ? 65535 : q;
    endfunction

    task automatic run(input vec_t v, input bit poke_busy = 0);
        int start = n_valid, waited = 0;
        for (int b = 0; b < NB; b++) band_acc[b] <= ACC_W'(v[b]);
        in_valid <= 1'b1;
        @(posedge clk);
        in_valid <= 1'b0;
        @(posedge clk);
        if (poke_busy) begin                          // new data while busy: ignored
            repeat (20) @(posedge clk);
            if (!busy) $fatal(1, "busy not asserted during division");
            for (int b = 0; b < NB; b++) band_acc[b] <= ACC_W'(b + 1);
            in_valid <= 1'b1; @(posedge clk);
            in_valid <= 1'b0; @(posedge clk);
        end
        while (!feature_valid) begin
            @(posedge clk);
            if (++waited > 400) $fatal(1, "no feature_valid");
        end
        for (int b = 0; b < NB; b++) begin
            longint e = expect_f(v, b);
            if (longint'(feature[b]) != e)
                $fatal(1, "band %0d: feature %0d != expected %0d (v=%0d)", b, feature[b], e, v[b]);
        end
        last_feature = feature;
        repeat (300) @(posedge clk);                  // any duplicate would appear here
        if (n_valid != start + 1)
            $fatal(1, "%0d feature_valid pulses for one frame", n_valid - start);
    endtask

    vec_t v, v2;

    initial begin
        repeat (3) @(posedge clk);
        reset <= 1'b0;
        @(posedge clk);

        // zero energy
        for (int b = 0; b < NB; b++) v[b] = 0;
        run(v);

        // all energy in one band, for each band
        for (int s = 0; s < NB; s++) begin
            for (int b = 0; b < NB; b++) v[b] = (b == s) ? 64'd987654321 : 0;
            run(v);
            if (feature[s] != 16'hFFFF) $fatal(1, "single band %0d not saturated", s);
        end

        // maximum energy everywhere
        for (int b = 0; b < NB; b++) v[b] = AMAX;
        run(v);
        for (int b = 0; b < NB; b++)
            if (feature[b] != 16'd8192) $fatal(1, "max energy: band %0d = %0d", b, feature[b]);

        // random vectors, each followed by the same vector at 2x amplitude
        for (int t = 0; t < 150; t++) begin
            automatic int sh = $urandom_range(40, 0);
            for (int b = 0; b < NB; b++) v[b] = ({$urandom, $urandom} & AMAX) >> $urandom_range(39, 0) >> 2;
            if ($urandom_range(3, 0) == 0) v[$urandom_range(NB - 1, 0)] = 0;
            for (int b = 0; b < NB; b++) v[b] = v[b] >> (sh / 4);
            run(v, (t % 25) == 0);
            begin
                automatic logic [NB-1:0][15:0] f1 = last_feature;
                for (int b = 0; b < NB; b++) v2[b] = v[b] * 4;
                run(v2);
                if (last_feature != f1) $fatal(1, "2x amplitude changed the normalised vector");
            end
        end

        // reset during a division
        for (int b = 0; b < NB; b++) band_acc[b] <= ACC_W'(1000 * (b + 1));
        in_valid <= 1'b1; @(posedge clk);
        in_valid <= 1'b0; repeat (40) @(posedge clk);
        reset <= 1'b1; @(posedge clk); reset <= 1'b0;
        begin
            automatic int n_before = n_valid;
            repeat (300) @(posedge clk);
            if (n_valid != n_before) $fatal(1, "output after reset mid-division");
            if (busy) $fatal(1, "busy after reset");
        end
        for (int b = 0; b < NB; b++) v[b] = 11 * (b + 3);
        run(v);

        $display("%0d normalised frames checked", n_valid);
        $display("ALL TESTS PASSED: band_normalise");
        $finish;
    end
endmodule
