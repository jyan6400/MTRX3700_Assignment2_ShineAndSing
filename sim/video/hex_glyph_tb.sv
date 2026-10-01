`timescale 1ns/1ps
/*
 *  hex_glyph_tb.sv -- every pixel of a 24 x 40 window around a glyph, for all 16 digits, two scales and
 *  two positions (one at the screen edge), against the bench's own copy of the 3x5 font written as
 *  strings: '#' lit, '.' dark. Nothing outside the 3 x 5 dots may light.
 */
module hex_glyph_tb;
    localparam int XW = 10, YW = 9;
    logic [XW-1:0] px, x0; logic [YW-1:0] py, y0; logic [3:0] digit; logic on1, on4;
    hex_glyph #(.XW(XW), .YW(YW), .SCALE_SH(0)) u1 (.px, .py, .x0, .y0, .digit, .on(on1));
    hex_glyph #(.XW(XW), .YW(YW), .SCALE_SH(2)) u4 (.px, .py, .x0, .y0, .digit, .on(on4));

    // the 3x5 font drawn as rows, top to bottom ('#' lit)
    string font [16] = '{
        /* 0 */ "####.##.##.####",
        /* 1 */ ".#.##..#..#.###",
        /* 2 */ "###..#####..###",
        /* 3 */ "###..####..####",
        /* 4 */ "#.##.####..#..#",
        /* 5 */ "####..###..####",
        /* 6 */ "####..####.####",
        /* 7 */ "###..#..#..#..#",
        /* 8 */ "####.#####.####",
        /* 9 */ "####.####..####",
        /* A */ "####.#####.##.#",
        /* B */ "#..#..####.####",
        /* C */ "####..#..#..###",
        /* D */ "..#..#####.####",
        /* E */ "####..####..###",
        /* F */ "####..####..#.." };

    function automatic bit expect_on(int dx, int dy, int sh, int d);
        int c, r;
        if (dx < 0 || dy < 0) return 0;
        c = dx >> sh; r = dy >> sh;
        if (c >= 3 || r >= 5) return 0;
        return font[d].getc(3 * r + c) == "#";
    endfunction

    initial begin
        int origins [2][2] = '{'{100, 50}, '{0, 0}};
        for (int o = 0; o < 2; o++) for (int d = 0; d < 16; d++) begin
            x0 = XW'(origins[o][0]); y0 = YW'(origins[o][1]); digit = 4'(d);
            for (int dy = -4; dy < 24; dy++) for (int dx = -4; dx < 16; dx++) begin
                if (origins[o][0] + dx < 0 || origins[o][1] + dy < 0) continue;
                px = XW'(origins[o][0] + dx); py = YW'(origins[o][1] + dy); #1;
                if (on1 != expect_on(dx, dy, 0, d)) $fatal(1, "FAIL: digit %h scale 1 at (%0d,%0d): %0d", d, dx, dy, on1);
                if (on4 != expect_on(dx, dy, 2, d)) $fatal(1, "FAIL: digit %h scale 4 at (%0d,%0d): %0d", d, dx, dy, on4);
            end
        end
        $display("PASS: 16 digits x 2 scales x 2 positions, every pixel");
        $display("ALL TESTS PASSED: hex_glyph");
        $finish;
    end
endmodule
