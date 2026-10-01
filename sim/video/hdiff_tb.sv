`timescale 1ns/1ps
/*
 *  hdiff_tb.sv -- the 1-D edge detector (a2/hdiff.sv, new for A2). Checks, against values the
 *  bench computes from its own picture:
 *    - out_val = |p[x] - p[x-1]| with the coordinates of p[x], one clock after p[x]
 *    - nothing for x = 0 (no left neighbour), nothing across a row boundary
 *    - a stream that starts each row at x = 1 (as the R-V4 smoothing stage's does): nothing for x = 1
 *    - gaps in in_valid do not break the pairing
 */
module hdiff_tb;
    localparam int W = 20, H = 6;
    logic clk = 0; always #10 clk = ~clk;
    logic reset = 1, in_valid = 0; logic [7:0] in_pixel; logic [4:0] in_x; logic [2:0] in_y;
    logic out_valid; logic [7:0] out_val; logic [4:0] out_x; logic [2:0] out_y;
    hdiff #(.W(W), .H(H)) dut (.*);

    int pic [0:H-1][0:W-1];
    int first_x = 0, outs = 0;
    always @(posedge clk) if (out_valid) begin
        int e;
        outs++;
        if (int'(out_x) <= first_x) $fatal(1, "FAIL: output for x = %0d, the first pixel of its row", out_x);
        e = pic[out_y][out_x] - pic[out_y][out_x-1]; if (e < 0) e = -e;
        if (int'(out_val) != e) $fatal(1, "FAIL: (%0d,%0d) = %0d, expected %0d", out_x, out_y, out_val, e);
    end
    task automatic stream(input int x0, input int x1, input bit gaps);
        for (int y = 0; y < H; y++) for (int x = x0; x <= x1; x++) begin
            @(negedge clk); in_valid = 1; in_pixel = 8'(pic[y][x]); in_x = 5'(x); in_y = 3'(y);
            if (gaps && ($urandom % 4 == 0)) begin @(negedge clk); in_valid = 0; end
        end
        @(negedge clk); in_valid = 0; repeat (3) @(posedge clk);
    endtask
    initial begin
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) pic[y][x] = $urandom % 256;
        repeat (3) @(posedge clk); reset = 0;
        first_x = 0; outs = 0; stream(0, W-1, 0);
        if (outs != H*(W-1)) $fatal(1, "FAIL: %0d outputs, expected %0d", outs, H*(W-1));
        first_x = 0; outs = 0; stream(0, W-1, 1);
        if (outs != H*(W-1)) $fatal(1, "FAIL: with gaps, %0d outputs, expected %0d", outs, H*(W-1));
        first_x = 1; outs = 0; stream(1, W-2, 1);                  // the smoothed stream's rows
        if (outs != H*(W-3)) $fatal(1, "FAIL: interior stream, %0d outputs, expected %0d", outs, H*(W-3));
        $display("PASS: |p[x]-p[x-1]| with coordinates, first pixel of each row skipped, gaps harmless");
        $display("ALL TESTS PASSED: hdiff");
        $finish;
    end
endmodule
