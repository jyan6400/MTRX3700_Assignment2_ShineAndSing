`timescale 1ns/1ps
/*
 *  hysteresis_profile_tb.sv -- NMS + two thresholds + min_gap, against the notebook's pick_nms_hyst()
 *  recomputed by the bench (per-column hi/lo, NC-candidate limit):
 *    directed (constant thresholds hi 179, lo 90, min_gap 10):
 *      a strong peak                                      -> kept
 *      a weak peak (between lo and hi) 6 px from a strong -> accepted, then merged into the stronger
 *      a weak peak exactly min_gap after a strong one     -> kept separately (the other side of the gap)
 *      a weak peak far from any strong one                -> rejected (a bump in the noise)
 *      closely spaced false peaks below lo                -> never candidates
 *      a plateau (two equal columns)                      -> one boundary, the first column
 *    adaptive (R-V4): per-column hi = max(t, floor), lo = max(t - t/4, floor), checked on the profile-
 *      view stream too; a "shadowed" half where the peaks are under the constant thresholds but over
 *      the local ones
 *    overflow: more than NC candidates sets cand_overflow and keeps the first NC
 *    300 random profiles in both modes.
 */
module hysteresis_profile_tb;
    localparam int W = 96, NW = 9, NC = 16, NMAX = 8;
    logic clk = 0; always #10 clk = ~clk;
    logic reset = 1, start = 0, adaptive = 0; logic [NW-1:0] hi = 179, lo = 90, floor_lvl = 26; logic [6:0] min_gap = 10;
    logic [6:0] rd_x; logic [NW-1:0] n_val, t_val; logic busy, done, cand_overflow;
    logic [3:0] count; logic [2:0] idx; logic [6:0] pos_of;
    logic dsp_wr; logic [6:0] dsp_x; logic [NW-1:0] dsp_n, dsp_hi, dsp_lo;
    logic [NW-1:0] n [0:W-1], t [0:W-1];
    always_ff @(posedge clk) begin n_val <= n[rd_x]; t_val <= t[rd_x]; end
    hysteresis_profile #(.W(W), .NW(NW), .NC(NC), .NMAX(NMAX)) dut (.*);

    function automatic int hi_at(int x);
        if (!adaptive) return int'(hi);
        return (int'(t[x]) > int'(floor_lvl)) ? int'(t[x]) : int'(floor_lvl);
    endfunction
    function automatic int lo_at(int x);
        int w;
        if (!adaptive) return int'(lo);
        w = int'(t[x]) - (int'(t[x]) >> 2);
        return (w > int'(floor_lvl)) ? w : int'(floor_lvl);
    endfunction

    int dsp_seen [0:W-1];
    always @(posedge clk) if (dsp_wr) begin
        if (int'(dsp_n) != int'(n[dsp_x]) || int'(dsp_hi) != hi_at(dsp_x) || int'(dsp_lo) != lo_at(dsp_x))
            $fatal(1, "FAIL: profile-view stream at %0d: %0d/%0d/%0d, expected %0d/%0d/%0d", dsp_x, dsp_n, dsp_hi, dsp_lo,
                   n[dsp_x], hi_at(dsp_x), lo_at(dsp_x));
        dsp_seen[dsp_x]++;
    end

    int expect_pos[$]; bit expect_ovf;
    task automatic reference();
        int cand[$], strongs[$], g;
        g = int'(min_gap);
        expect_pos.delete(); expect_ovf = 0;
        for (int x = 1; x <= W-2; x++)
            if (n[x] >= n[x-1] && n[x] >= n[x+1] && int'(n[x]) > lo_at(x)) begin
                if (cand.size() < NC) cand.push_back(x); else expect_ovf = 1;
            end
        foreach (cand[i]) if (int'(n[cand[i]]) > hi_at(cand[i])) strongs.push_back(cand[i]);
        foreach (cand[i]) begin
            bit acc;
            acc = (int'(n[cand[i]]) > hi_at(cand[i]));
            foreach (strongs[j]) if ((cand[i] - strongs[j] <= g) && (strongs[j] - cand[i] <= g)) acc = 1;
            if (acc) begin
                if (expect_pos.size() > 0 && cand[i] - expect_pos[$] < g) begin
                    if (n[cand[i]] > n[expect_pos[$]]) expect_pos[$] = cand[i];
                end else if (expect_pos.size() < NMAX) expect_pos.push_back(cand[i]);
            end
        end
    endtask

    task automatic run(input string what);
        foreach (dsp_seen[i]) dsp_seen[i] = 0;
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        wait (done); @(negedge clk);
        reference();
        foreach (dsp_seen[i]) if (dsp_seen[i] != 1) $fatal(1, "FAIL %s: column %0d streamed %0d times", what, i, dsp_seen[i]);
        if (cand_overflow != expect_ovf) $fatal(1, "FAIL %s: cand_overflow = %0d", what, cand_overflow);
        if (int'(count) != expect_pos.size()) $fatal(1, "FAIL %s: %0d boundaries, expected %0d", what, count, expect_pos.size());
        foreach (expect_pos[i]) begin
            idx = 3'(i); #1;
            if (int'(pos_of) != expect_pos[i]) $fatal(1, "FAIL %s: boundary %0d at %0d, expected %0d", what, i, pos_of, expect_pos[i]);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk); reset = 0;
        // ---- directed, R-V3 constants
        foreach (n[i]) begin n[i] = 9'(i % 3 == 0 ? 40 : 30); t[i] = 0; end   // closely spaced false peaks below lo
        n[10] = 256;                       // strong
        n[16] = 150;                       // weak, 6 px after a strong one: accepted, merged into 10
        n[30] = 200;                       // strong
        n[40] = 120;                       // weak, exactly min_gap after 30: kept
        n[60] = 150;                       // weak, alone: rejected
        n[80] = 220; n[81] = 220;          // plateau: one boundary at 80
        run("directed");
        if (count != 4) $fatal(1, "FAIL directed: %0d boundaries", count);
        begin
            int want [4] = '{10, 30, 40, 80};
            for (int i = 0; i < 4; i++) begin idx = 3'(i); #1; if (int'(pos_of) != want[i]) $fatal(1, "FAIL directed: boundary %0d at %0d, want %0d", i, pos_of, want[i]); end
        end
        $display("PASS: strong kept, weak beside strong kept/merged, lone weak rejected, false peaks ignored, plateau = 1");
        // ---- adaptive: a shadowed left half (peaks of 60) under 0.35, but over its own local average
        adaptive = 1; min_gap = 8;
        foreach (n[i]) n[i] = 9'((i < 48) ? 6 : 20);
        for (int x = 10; x < 96; x += 16) n[x] = (x < 48) ? 9'd60 : 9'd240;
        for (int x = 0; x < W; x++) begin
            int s;
            s = 0;
            for (int j = x - 12; j <= x + 12; j++) if (j >= 0 && j < W) s += int'(n[j]);
            t[x] = 9'(((s * 102) >> 10) > 511 ? 511 : ((s * 102) >> 10));
        end
        run("adaptive, shadowed half");
        if (count != 6) $fatal(1, "FAIL adaptive: %0d boundaries, expected all 6 (3 in the shadow)", count);
        $display("PASS: adaptive thresholds find the peaks in the shadowed half");
        // ---- overflow
        adaptive = 0; min_gap = 2;
        foreach (n[i]) n[i] = (i % 2) ? 9'd200 : 9'd10;
        run("overflow");
        if (!cand_overflow) $fatal(1, "FAIL: no overflow with %0d candidates", W / 2);
        $display("PASS: more than NC candidates flags cand_overflow");
        // ---- random
        for (int k = 0; k < 300; k++) begin
            adaptive = k[0]; min_gap = 7'(1 + $urandom % 12);
            hi = 9'(60 + $urandom % 200); lo = 9'($urandom % 120); floor_lvl = 9'($urandom % 60);
            foreach (n[i]) begin n[i] = 9'($urandom % 257); t[i] = 9'($urandom % 400); end
            if (k % 7 == 0) foreach (n[i]) n[i] = 9'(n[i] >> 3);
            run($sformatf("random %0d", k));
        end
        $display("PASS: 300 random profiles, both modes");
        $display("ALL TESTS PASSED: hysteresis_profile");
        $finish;
    end
endmodule
