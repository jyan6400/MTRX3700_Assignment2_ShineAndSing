`timescale 1ns/1ps
/*
 *  hex_glyph.sv -- one hexadecimal digit as a 3x5 dot font, drawn at any position and scale: the
 *  score and the debug readouts on the VGA screen.  (NEW, Advay: no digit-drawing module was in the
 *  Mini-Project 2 workspace.)
 *
 *  `on` is 1 when screen pixel (px, py) is a lit dot of `digit` drawn with its top-left corner at
 *  (x0, y0), each font dot being 2^SCALE_SH x 2^SCALE_SH screen pixels. The glyph occupies
 *  3 x 5 dots; leave one dot of space between digits (a pitch of 4 dots). Purely combinational.
 */
module hex_glyph #(
    parameter int XW       = 10,       // screen x width (640 needs 10)
    parameter int YW       = 9,        // screen y width (480 needs 9)
    parameter int SCALE_SH = 2         // dot size = 2^SCALE_SH pixels
) (
    input  logic [XW-1:0] px,
    input  logic [YW-1:0] py,
    input  logic [XW-1:0] x0,
    input  logic [YW-1:0] y0,
    input  logic [3:0]    digit,
    output logic          on
);
    // 5 rows of 3 dots, top row first; in each row bit 2 is the left dot
    function automatic logic [14:0] font(input logic [3:0] d);
        case (d)
            4'h0: return 15'b111_101_101_101_111;
            4'h1: return 15'b010_110_010_010_111;
            4'h2: return 15'b111_001_111_100_111;
            4'h3: return 15'b111_001_111_001_111;
            4'h4: return 15'b101_101_111_001_001;
            4'h5: return 15'b111_100_111_001_111;
            4'h6: return 15'b111_100_111_101_111;
            4'h7: return 15'b111_001_001_001_001;
            4'h8: return 15'b111_101_111_101_111;
            4'h9: return 15'b111_101_111_001_111;
            4'hA: return 15'b111_101_111_101_101;
            4'hB: return 15'b100_100_111_101_111;
            4'hC: return 15'b111_100_100_100_111;
            4'hD: return 15'b001_001_111_101_111;
            4'hE: return 15'b111_100_111_100_111;
            default: return 15'b111_100_111_100_100;
        endcase
    endfunction

    logic [XW:0] dx;  logic [YW:0] dy;              // one bit wider: negative when left of / above the glyph
    assign dx = {1'b0, px} - {1'b0, x0};
    assign dy = {1'b0, py} - {1'b0, y0};
    logic [XW:0] col; logic [YW:0] row;
    assign col = dx >> SCALE_SH;
    assign row = dy >> SCALE_SH;
    logic [14:0] f;
    assign f = font(digit);
    always_comb begin
        on = 1'b0;
        if (!dx[XW] && !dy[YW] && col < 3 && row < 5)
            on = f[14 - (3 * int'(row) + int'(col))];
    end
endmodule
