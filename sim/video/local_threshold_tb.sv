`timescale 1ns/1ps
/*
 *  local_threshold_tb.sv -- t[x] = min(511, (k_q * sum_{j=x-12..x+12} n[j]) >> 10), n = 0 outside the
 *  profile, checked on every column against the bench's own sum, for: a flat profile (the window
 *  shrinks at the two ends), one spike (the threshold is a 25-column plateau around it), a step
 *  (the "shadow": the threshold follows the lower half down), saturation (k_q = 255 on a full
 *  profile), k_q = 0, and 50 random profiles with random k_q.
 */
module local_threshold_tb;
    localparam int W = 80, NW = 9, TW = 9, HALF = 12;
    logic clk = 0; always #10 clk = ~clk;
    logic reset = 1, start = 0; logic [7:0] k_q;
    logic [6:0] src_rd_x, rd_x; logic [NW-1:0] src_rd_val; logic busy, done; logic [TW-1:0] rd_val;
    logic [NW-1:0] n [0:W-1];
    always_ff @(posedge clk) src_rd_val <= n[src_rd_x];
    local_threshold #(.W(W), .NW(NW), .TW(TW), .HALF(HALF)) dut (.*);

    task automatic run(input string what);
        int s, e;
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        wait (done); @(negedge clk);
        for (int x = 0; x < W; x++) begin
            s = 0;
            for (int j = x - HALF; j <= x + HALF; j++) if (j >= 0 && j < W) s += int'(n[j]);
            e = (s * int'(k_q)) >> 10; if (e > 511) e = 511;
            @(negedge clk); rd_x = 7'(x); @(negedge clk);
            if (int'(rd_val) != e) $fatal(1, "FAIL %s: t[%0d] = %0d, expected %0d (sum %0d, k_q %0d)", what, x, rd_val, e, s, k_q);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk); reset = 0;
        k_q = 102;
        foreach (n[i]) n[i] = 100;                      run("flat");
        foreach (n[i]) n[i] = 0; n[40] = 256;           run("one spike");
        foreach (n[i]) n[i] = (i < 40) ? 30 : 120;      run("step (shadow)");
        k_q = 255; foreach (n[i]) n[i] = 256;           run("saturation");
        k_q = 0;                                        run("k = 0");
        for (int k = 0; k < 50; k++) begin
            k_q = 8'($urandom);
            foreach (n[i]) n[i] = 9'($urandom % 257);
            run($sformatf("random %0d", k));
        end
        $display("PASS: moving average of 25 columns x k_q / 1024 on every column (ends, spike, step, saturation, random)");
        $display("ALL TESTS PASSED: local_threshold");
        $finish;
    end
endmodule
