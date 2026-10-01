`timescale 1ns/1ps
/*
 *  profile_normalise_tb.sv -- n[x] = floor(p[x] * 256 / max), thr_n = floor(thr * 256 / max) (511 if
 *  thr >= 2 max), checked against the bench's own arithmetic through both outputs (the read port and
 *  the stream), for:
 *    flat zero profile (max = 0: all zero, thr_n = 511), flat constant (all 256),
 *    one strong edge (256 there, small elsewhere), a 20-bit maximum, and 100 random profiles
 *    including a threshold just below and at 2 x max.
 *  Also: exactly one stream write per column, and done once per start.
 */
module profile_normalise_tb;
    localparam int W = 64, AW = 20, NW = 9;
    logic clk = 0; always #10 clk = ~clk;
    logic reset = 1, start = 0; logic [AW-1:0] thr_abs;
    logic [5:0] src_rd_x, rd_x; logic [AW-1:0] src_rd_val; logic busy, done; logic [AW-1:0] max_val; logic [NW-1:0] thr_n;
    logic out_wr; logic [5:0] out_x; logic [NW-1:0] out_val; logic [NW-1:0] rd_val;
    logic [AW-1:0] prof [0:W-1];
    always_ff @(posedge clk) src_rd_val <= prof[src_rd_x];
    profile_normalise #(.W(W), .AW(AW), .NW(NW)) dut (.*);

    int streamed [0:W-1]; int nwrites = 0, ndone = 0;
    always @(posedge clk) begin
        if (out_wr) begin streamed[out_x] = int'(out_val); nwrites++; end
        if (done) ndone++;
    end

    task automatic run(input string what);
        int mx = 0, e, et;
        foreach (prof[i]) if (int'(prof[i]) > mx) mx = int'(prof[i]);
        nwrites = 0; ndone = 0;
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        wait (done); @(negedge clk); @(negedge clk);
        if (ndone != 1) $fatal(1, "FAIL %s: %0d done pulses", what, ndone);
        if (nwrites != W) $fatal(1, "FAIL %s: %0d stream writes, expected %0d", what, nwrites, W);
        if (int'(max_val) != mx) $fatal(1, "FAIL %s: max %0d, expected %0d", what, max_val, mx);
        et = (mx == 0 || longint'(thr_abs) >= 2 * longint'(mx)) ? 511 : int'((longint'(thr_abs) * 256) / mx);
        if (int'(thr_n) != et) $fatal(1, "FAIL %s: thr_n %0d, expected %0d (thr %0d, max %0d)", what, thr_n, et, thr_abs, mx);
        for (int x = 0; x < W; x++) begin
            e = (mx == 0) ? 0 : int'((longint'(prof[x]) * 256) / mx);
            @(negedge clk); rd_x = 6'(x); @(negedge clk);
            if (int'(rd_val) != e)   $fatal(1, "FAIL %s: n[%0d] = %0d, expected %0d", what, x, rd_val, e);
            if (streamed[x] != e)    $fatal(1, "FAIL %s: streamed n[%0d] = %0d, expected %0d", what, x, streamed[x], e);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk); reset = 0;
        foreach (prof[i]) prof[i] = 0;           thr_abs = 100;   run("flat zero");
        foreach (prof[i]) prof[i] = 777;         thr_abs = 777;   run("flat constant");
        foreach (prof[i]) prof[i] = 20'(i % 7); prof[30] = 42180; thr_abs = 16384; run("one strong edge");
        foreach (prof[i]) prof[i] = 20'($urandom % (1 << AW)); prof[5] = (1 << AW) - 1; thr_abs = 20'((1 << AW) - 1); run("20-bit maximum");
        for (int k = 0; k < 100; k++) begin
            int mx = 0;
            foreach (prof[i]) begin prof[i] = 20'($urandom % ((k % 4 == 0) ? 50 : 60000)); if (int'(prof[i]) > mx) mx = int'(prof[i]); end
            case (k % 3)
                0: thr_abs = 20'($urandom % 60000);
                1: thr_abs = (mx == 0) ? 0 : 20'(2 * mx - 1);     // just below saturation: quotient 511
                default: thr_abs = 20'(2 * mx);                   // saturates
            endcase
            run($sformatf("random %0d", k));
        end
        $display("PASS: flat, one edge, 20-bit maximum and 100 random profiles; stream and read port agree");
        $display("ALL TESTS PASSED: profile_normalise");
        $finish;
    end
endmodule
