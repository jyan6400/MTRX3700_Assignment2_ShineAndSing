`timescale 1ns/1ps
/*
 *  col_profile_tb.sv -- REUSED/ADAPTED regression: Mini-Project 2's tb/tb_col_profile.sv (sum over rows
 *  Y0..Y1 only; a second frame must start from zero -- the tag trick; one done per frame), extended for
 *  Assignment 2: $fatal on the first mismatch, "ALL TESTS PASSED", a third frame with random values
 *  checked against a sum the bench computes, and the piano's own row window (150..176) on a
 *  full-width picture with X_LAST = W-4, as video_analysis.sv instantiates it.
 */
module col_profile_tb;
    localparam int W = 16, H = 8, Y0 = 2, Y1 = 5;
    logic clk = 0; always #10 clk = ~clk;
    logic reset = 1, in_valid = 0, frame_start = 0, done; logic [11:0] in_val; logic [3:0] in_x; logic [2:0] in_y;
    logic [3:0] rd_x; logic [19:0] rd_val;
    col_profile #(.W(W), .H(H), .VW(12), .AW(20), .Y0(Y0), .Y1(Y1)) dut (.*);

    // the piano configuration
    localparam int PW = 320, PH = 240, PY0 = 150, PY1 = 176;
    logic p_valid = 0, p_fs = 0, p_done; logic [11:0] p_val; logic [8:0] p_x, p_rdx; logic [7:0] p_y; logic [19:0] p_rdv;
    col_profile #(.W(PW), .H(PH), .VW(12), .AW(20), .Y0(PY0), .Y1(PY1), .X_LAST(PW-4)) dut_p (.clk, .reset,
        .in_valid(p_valid), .in_val(p_val), .in_x(p_x), .in_y(p_y), .frame_start(p_fs), .done(p_done), .rd_x(p_rdx), .rd_val(p_rdv));

    int vals [0:H-1][0:W-1];
    task automatic frame();
        @(negedge clk); frame_start = 1; @(negedge clk); frame_start = 0;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
            @(negedge clk); in_valid = 1; in_val = 12'(vals[y][x]); in_x = 4'(x); in_y = 3'(y);
        end
        @(negedge clk); in_valid = 0;
    endtask
    task automatic check();
        repeat (4) @(posedge clk);
        for (int x = 0; x < W; x++) begin
            int e = 0;
            for (int y = Y0; y <= Y1; y++) e += vals[y][x];
            @(negedge clk); rd_x = 4'(x); @(negedge clk);
            if (rd_val != 20'(e)) $fatal(1, "FAIL: column %0d = %0d, expected %0d", x, rd_val, e);
        end
    endtask
    int dones = 0; always @(posedge clk) if (done) dones++;
    int pdones = 0; always @(posedge clk) if (p_done) pdones++;

    initial begin
        repeat (3) @(posedge clk); reset = 0;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) vals[y][x] = 10 + x;  frame(); check();
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) vals[y][x] = 3 + x;   frame(); check();   // smaller: a leak shows
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) vals[y][x] = $urandom % 1021;  frame(); check();
        if (dones != 3) $fatal(1, "FAIL: %0d done pulses, expected 3", dones);
        $display("PASS: rows %0d..%0d only, restarts each frame, one done per frame", Y0, Y1);

        // the piano window: an interior-only stream (x = 1..W-2) of |Gx| = 1020 in column 100, 7 elsewhere
        @(negedge clk); p_fs = 1; @(negedge clk); p_fs = 0;
        for (int y = 1; y < PH - 1; y++) for (int x = 1; x < PW - 1; x++) begin
            @(negedge clk); p_valid = 1; p_x = 9'(x); p_y = 8'(y); p_val = (x == 100) ? 12'd1020 : 12'd7;
        end
        @(negedge clk); p_valid = 0; repeat (4) @(posedge clk);
        if (pdones != 1) $fatal(1, "FAIL: piano window: %0d done pulses", pdones);
        for (int x = 0; x < PW; x++) begin
            int e;
            e = (x == 0 || x == PW-1) ? 0 : (PY1 - PY0 + 1) * ((x == 100) ? 1020 : 7);
            @(negedge clk); p_rdx = 9'(x); @(negedge clk);
            if (p_rdv != 20'(e)) $fatal(1, "FAIL: piano column %0d = %0d, expected %0d", x, p_rdv, e);
        end
        $display("PASS: piano rows %0d..%0d, %0d rows x 1020 = %0d fits AW = 20, done with X_LAST = W-4", PY0, PY1, PY1-PY0+1, (PY1-PY0+1)*1020);
        $display("ALL TESTS PASSED: col_profile");
        $finish;
    end
endmodule
