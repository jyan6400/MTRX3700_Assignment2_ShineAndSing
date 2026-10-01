`timescale 1ns/1ps
/*
 *  pick_runs_tb.sv -- the R-V1 run picker (a2/pick_runs.sv, new for A2), against the notebook's
 *  pick_runs() recomputed by the bench: every run above thr is one boundary at its centre
 *  (first + last) / 2; a centre closer than min_gap to the previous one is dropped.
 *  Directed: a run touching column 0, a run touching column W-1, a one-column run in the last column,
 *  two runs closer than min_gap (the two sides of one key gap). Then 300 random profiles.
 */
module pick_runs_tb;
    localparam int W = 64, NMAX = 32;
    logic clk = 0; always #10 clk = ~clk;
    logic reset = 1, start = 0, busy, done; logic [19:0] thr; logic [5:0] min_gap, rd_x; logic [19:0] rd_val;
    logic [5:0] count; logic [4:0] idx; logic [5:0] pos_of;
    logic [19:0] prof [0:W-1];
    always_ff @(posedge clk) rd_val <= prof[rd_x];
    pick_runs #(.W(W), .AW(20), .NMAX(NMAX)) dut (.*);

    int expect_pos[$];
    task automatic reference(input int t, input int gap);
        int i = 0;
        expect_pos.delete();
        while (i < W) begin
            if (prof[i] > t) begin
                int j = i, c;
                while (j < W && prof[j] > t) j++;
                c = (i + j - 1) / 2;
                if (!(expect_pos.size() > 0 && c - expect_pos[$] < gap) && expect_pos.size() < NMAX) expect_pos.push_back(c);
                i = j;
            end else i++;
        end
    endtask
    task automatic run(input int gap);
        min_gap = 6'(gap); @(negedge clk); start = 1; @(negedge clk); start = 0;
        wait (done); @(negedge clk);
        reference(thr, gap);
        if (count != 6'(expect_pos.size())) $fatal(1, "FAIL: min_gap %0d thr %0d: %0d runs, expected %0d", gap, thr, count, expect_pos.size());
        foreach (expect_pos[i]) begin
            idx = 5'(i); #1;
            if (pos_of != 6'(expect_pos[i])) $fatal(1, "FAIL: run %0d at %0d, expected %0d", i, pos_of, expect_pos[i]);
        end
    endtask
    initial begin
        repeat (3) @(posedge clk); reset = 0;
        for (int i = 0; i < W; i++) prof[i] = 10;
        prof[0] = 500; prof[1] = 500; prof[2] = 500;                       // touches column 0: centre 1
        prof[20] = 500; prof[21] = 500; prof[25] = 500; prof[26] = 500;    // two sides of one gap: 20, 25
        prof[W-1] = 500;                                                   // one column at the end
        thr = 100;
        run(8);  if (count != 3) $fatal(1, "FAIL: directed: %0d runs with min_gap 8 (25 must merge into 20)", count);
        run(3);  if (count != 4) $fatal(1, "FAIL: directed: %0d runs with min_gap 3", count);
        prof[W-2] = 500; run(3);                                           // a run reaching the last column
        $display("PASS: directed runs (edges of the profile, two sides of one gap)");
        for (int k = 0; k < 300; k++) begin
            for (int i = 0; i < W; i++) prof[i] = 20'($urandom % 1000);
            thr = 20'($urandom % 1000);
            run(1 + $urandom % 10);
        end
        $display("PASS: 300 random profiles match the reference");
        $display("ALL TESTS PASSED: pick_runs");
        $finish;
    end
endmodule
