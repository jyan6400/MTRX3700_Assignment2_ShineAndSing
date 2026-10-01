`timescale 1ns/1ps
/*
 *  conv3x3_tb.sv -- REUSED/ADAPTED regression: Mini-Project 2's tb/tb_conv3x3.sv (16x12 picture, a
 *  vertical edge, Sobel Gx = 4 x (200 - 40) at the two columns beside it, interior only, coordinates
 *  carried), extended for Assignment 2:
 *    - $fatal on the first mismatch and "ALL TESTS PASSED" (A2 test rules)
 *    - every output compared with a 3x3 sum the bench computes itself from its own copy of the picture
 *    - a second instance with the R-V4 smoothing table [1 2 1; 2 4 2; 1 2 1] on a random picture
 *    - the latency: the output for centre (cx, cy) must appear exactly when input (cx+1, cy+1) has
 *      arrived plus 3 clocks, and carry (cx, cy) -- what "account for the delay" relies on
 *    - gaps in in_valid (the output must not change with them)
 */
module conv3x3_tb;
    localparam int W = 16, H = 12;
    logic clk = 0; always #10 clk = ~clk;
    logic reset = 1, in_valid = 0; logic [7:0] in_pixel; logic [3:0] in_x; logic [3:0] in_y;
    logic out_valid; logic signed [11:0] out_val; logic [3:0] out_x, out_y;
    logic g_valid;   logic signed [12:0] g_val;   logic [3:0] g_x, g_y;
    conv3x3 #(.W(W), .H(H)) dut (.*);
    conv3x3 #(.W(W), .H(H), .OW(13), .K('{'{8'sd1, 8'sd2, 8'sd1}, '{8'sd2, 8'sd4, 8'sd2}, '{8'sd1, 8'sd2, 8'sd1}})) dut_g (
        .clk, .reset, .in_valid, .in_pixel, .in_x, .in_y, .out_valid(g_valid), .out_val(g_val), .out_x(g_x), .out_y(g_y));

    int pic [0:H-1][0:W-1];
    int arrival [0:H-1][0:W-1];       // clock at which pixel (x, y) was presented
    int cyc = 0; always @(posedge clk) cyc++;
    int n_sobel = 0, n_gauss = 0, n_edge = 0;
    bit random_picture = 0;

    function automatic int conv_ref(input int cxx, input int cyy, input bit gauss);
        int acc = 0;
        for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++)
            acc += (gauss ? ((r == 1 ? 2 : 1) * (c == 1 ? 2 : 1))           // [1 2 1; 2 4 2; 1 2 1]
                          : ((c - 1) * (r == 1 ? 2 : 1))) * pic[cyy - 1 + r][cxx - 1 + c];   // Sobel Gx
        return acc;
    endfunction

    always @(posedge clk) begin
        if (out_valid) begin
            int e;
            e = conv_ref(out_x, out_y, 0);
            n_sobel++;
            if (out_x < 1 || out_x > W-2 || out_y < 1 || out_y > H-2) $fatal(1, "FAIL: border centre (%0d,%0d) was output", out_x, out_y);
            if (out_val != e) $fatal(1, "FAIL: Sobel centre (%0d,%0d) = %0d, expected %0d", out_x, out_y, out_val, e);
            if (cyc != arrival[out_y+1][out_x+1] + 3)
                $fatal(1, "FAIL: centre (%0d,%0d) came out %0d clocks after (x+1,y+1) arrived, expected 3", out_x, out_y, cyc - arrival[out_y+1][out_x+1]);
            if (!random_picture && (out_x == 7 || out_x == 8) && out_val != 4 * (200 - 40)) $fatal(1, "FAIL: edge column %0d = %0d", out_x, out_val);
            if (!random_picture && out_val != 0) n_edge++;
        end
        if (g_valid) begin
            int e;
            e = conv_ref(g_x, g_y, 1);
            n_gauss++;
            if (g_val != e) $fatal(1, "FAIL: smoothing centre (%0d,%0d) = %0d, expected %0d", g_x, g_y, g_val, e);
        end
    end

    task automatic send_frame(input bit gaps);
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
            @(negedge clk); in_valid = 1; in_pixel = 8'(pic[y][x]); in_x = 4'(x); in_y = 4'(y); arrival[y][x] = cyc + 1;
            if (gaps && x == W-1 && y % 3 == 0) begin @(negedge clk); in_valid = 0; end   // a gap now and then
        end
        @(negedge clk); in_valid = 0; repeat (6) @(posedge clk);
    endtask

    initial begin
        repeat (3) @(posedge clk); reset = 0;
        // 1. the Mini-Project 2 picture: dark left, bright right, edge at x = 8 (no gaps: exact latency check)
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) pic[y][x] = (x < 8) ? 40 : 200;
        send_frame(0);
        if (n_sobel != (W-2)*(H-2)) $fatal(1, "FAIL: %0d outputs, expected %0d", n_sobel, (W-2)*(H-2));
        if (n_edge != 2*(H-2)) $fatal(1, "FAIL: %0d nonzero outputs, expected only the two edge columns", n_edge);
        // 2. a random picture (full 0..255 range: the largest positive and negative sums)
        random_picture = 1; n_sobel = 0; n_gauss = 0;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) pic[y][x] = ($urandom % 4 == 0) ? 255 : ($urandom % 256);
        send_frame(0);
        if (n_sobel != (W-2)*(H-2) || n_gauss != (W-2)*(H-2)) $fatal(1, "FAIL: output counts %0d / %0d", n_sobel, n_gauss);
        $display("PASS: Sobel and smoothing tables match the reference on every interior centre, latency 3 clocks");
        $display("ALL TESTS PASSED: conv3x3");
        $finish;
    end
endmodule
