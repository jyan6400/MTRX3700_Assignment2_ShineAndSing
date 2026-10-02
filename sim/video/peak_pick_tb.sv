`timescale 1ns/1ps
/*
 *  peak_pick_tb.sv -- REUSED/ADAPTED regression: Mini-Project 2's tb/tb_peak_pick.sv (peaks at 10, 12
 *  -- two sides of one gap --, a plateau at 30/31, 50, noise below thr; min_gap 1 keeps all five,
 *  min_gap 4 keeps 10, 30, 50), extended for Assignment 2: $fatal on the first mismatch, "ALL TESTS
 *  PASSED", and 200 random profiles compared with a reference picker the bench computes (the R-V2
 *  picker in video_subsystem.sv), including closely spaced false peaks and profiles with more than
 *  NMAX peaks.
 */
module peak_pick_tb;
    localparam int W = 64, NMAX = 32;
    logic clk = 0; always #10 clk = ~clk;
    logic reset = 1, start = 0, busy, done; logic [19:0] thr; logic [5:0] min_gap, rd_x; logic [19:0] rd_val;
    logic [5:0] count; logic [4:0] idx; logic [5:0] pos_of;
    logic [19:0] prof [0:W-1];
    always_ff @(posedge clk) rd_val <= prof[rd_x];          // the one-cycle read latency of col_profile
    peak_pick #(.W(W), .AW(20), .NMAX(NMAX)) dut (.*);

    int expect_pos[$];
    task automatic reference(input int t, input int gap);
        int last_v = 0;
        expect_pos.delete();
        for (int x = 1; x <= W-2; x++)
            if (prof[x] > t && prof[x] >= prof[x-1] && prof[x] >= prof[x+1]) begin
                if (expect_pos.size() > 0 && x - expect_pos[$] < gap) begin
                    if (prof[x] > last_v) begin expect_pos[$] = x; last_v = prof[x]; end
                end else if (expect_pos.size() < NMAX) begin expect_pos.push_back(x); last_v = prof[x]; end
            end
    endtask
    task automatic run(input int gap);
        min_gap = 6'(gap); @(negedge clk); start = 1; @(negedge clk); start = 0;
        wait (done); @(negedge clk);
        reference(thr, gap);
        if (count != 6'(expect_pos.size())) $fatal(1, "FAIL: min_gap %0d: %0d peaks, expected %0d", gap, count, expect_pos.size());
        foreach (expect_pos[i]) begin
            idx = 5'(i); #1;
            if (pos_of != 6'(expect_pos[i])) $fatal(1, "FAIL: min_gap %0d: peak %0d at %0d, expected %0d", gap, i, pos_of, expect_pos[i]);
        end
    endtask
    initial begin
        for (int i = 0; i < W; i++) prof[i] = 20'd5 + 20'(i % 3);   // noise below threshold
        prof[10] = 900; prof[12] = 800; prof[30] = 700; prof[31] = 700; prof[50] = 950; prof[51] = 400;
        thr = 100;
        repeat (3) @(posedge clk); reset = 0;
        run(1); if (count != 5) $fatal(1, "FAIL: the Mini-Project 2 case: %0d peaks with min_gap 1", count);
        run(4); if (count != 3) $fatal(1, "FAIL: the Mini-Project 2 case: %0d peaks with min_gap 4", count);
        $display("PASS: the Mini-Project 2 cases (5 peaks, then 10/30/50)");
        for (int k = 0; k < 200; k++) begin
            for (int i = 0; i < W; i++) prof[i] = 20'($urandom % ((k % 3 == 0) ? 64 : 1000));
            if (k % 5 == 0) for (int i = 0; i < W; i += 2) prof[i] = 20'(500 + $urandom % 10);   // > NMAX peaks
            thr = 20'($urandom % 600);
            run(1 + $urandom % 9);
        end
        $display("PASS: 200 random profiles match the reference picker");
        $display("ALL TESTS PASSED: peak_pick");
        $finish;
    end
endmodule
