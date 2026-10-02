`timescale 1ns/1ps
/*
 *  REUSED MODULE -- Lesson 2.3b / Mini-Project 2 (barcode reader), Advay's completed conv3x3.sv.
 *  CHANGES FOR ASSIGNMENT 2: none. A second instance with the smoothing table
 *  [1 2 1; 2 4 2; 1 2 1] (then >> 4) runs before the Sobel instances at R-V4 (video_subsystem.sv);
 *  that is a different parameter K, not a change to this file.
 *
 *  conv3x3.sv -- a 3x3 convolution over a streaming raster image, with two line buffers.
 *
 *  Pixels arrive one per in_valid in raster order (x fastest, then y), with their coordinates.
 *  For every interior pixel the module outputs
 *
 *      out_val = sum over dy,dx of  K[dy][dx] * pixel(y-1+dy, x-1+dx)
 *
 *  i.e. the table K slid over the picture, exactly as the 1-D low-pass in Lesson 4 slides a
 *  table of taps along a signal. The difference is only where the neighbours come from:
 *  the two previous ROWS are kept in two line buffers (inferred dual-port RAM, one entry per
 *  column), and the two previous COLUMNS in a 3-deep shift of "column triples".
 *
 *  Delay: the output for centre (cx, cy) appears when input (cx+1, cy+1) has arrived, plus two
 *  pipeline registers. So the output stream is one row and one column behind the input, and
 *  out_x/out_y carry the CENTRE coordinates so that downstream logic never has to know.
 *
 *  Border policy: interior only. Centres with x = 0, x = W-1, y = 0 or y = H-1 are not output.
 *
 *  Weights are signed 8-bit constants (a parameter, so a different table is a different
 *  instance: Sobel, smoothing, sharpening). With 8-bit pixels and |K| summing to at most 8 the
 *  result fits in 12 bits signed (Sobel: +-4*255 = +-1020). The smoothing table sums to 16, so
 *  its instance uses OW = 13 (16*255 = 4080).
 */
module conv3x3 #(
    parameter int W  = 320,
    parameter int H  = 240,
    parameter int DW = 8,            // pixel width
    parameter int OW = 12,           // output width (signed)
    parameter logic signed [7:0] K [0:2][0:2] = '{'{-1, 0, 1}, '{-2, 0, 2}, '{-1, 0, 1}}   // Sobel Gx
) (
    input  logic                  clk,
    input  logic                  reset,
    input  logic                  in_valid,
    input  logic [DW-1:0]         in_pixel,
    input  logic [$clog2(W)-1:0]  in_x,
    input  logic [$clog2(H)-1:0]  in_y,
    output logic                  out_valid,
    output logic signed [OW-1:0]  out_val,
    output logic [$clog2(W)-1:0]  out_x,
    output logic [$clog2(H)-1:0]  out_y
);
    // ---- two line buffers: lb1 holds row y-1, lb2 holds row y-2 (indexed by column) -------
    logic [DW-1:0] lb1 [0:W-1];
    logic [DW-1:0] lb2 [0:W-1];
    logic [DW-1:0] lb1_q, lb2_q;            // the values at column in_x, read as the pixel arrives

    // Read-before-write on the same address in the same cycle: the read returns the OLD value
    // (rows y-1 and y-2 at this column) and the write stores the new one (row y moves to lb1,
    // row y-1 moves to lb2). Quartus infers a dual-port M10K for each buffer.
    always_ff @(posedge clk) begin
        if (in_valid) begin
            lb1_q   <= lb1[in_x];
            lb2_q   <= lb2[in_x];
            lb1[in_x] <= in_pixel;
            lb2[in_x] <= lb1[in_x];
        end
    end

    // ---- stage 1: the column triple for column in_x, one cycle after the pixel arrived -----
    logic                  s1_valid;
    logic [DW-1:0]         s1_pix;
    logic [$clog2(W)-1:0]  s1_x;
    logic [$clog2(H)-1:0]  s1_y;
    always_ff @(posedge clk) begin
        s1_valid <= in_valid & ~reset;
        s1_pix   <= in_pixel;
        s1_x     <= in_x;
        s1_y     <= in_y;
    end
    // column triple (top, middle, bottom) = rows y-2, y-1, y at column s1_x
    logic [DW-1:0] c_top, c_mid, c_bot;
    assign c_top = lb2_q;
    assign c_mid = lb1_q;
    assign c_bot = s1_pix;

    // ---- stage 2: keep the two previous column triples -> a 3x3 window centred on (x-1, y-1)
    logic [DW-1:0] w [0:2][0:2];             // w[row][col]: col 0 = x-2, col 1 = x-1, col 2 = x
    logic                  s2_valid;
    logic [$clog2(W)-1:0]  s2_x;
    logic [$clog2(H)-1:0]  s2_y;
    always_ff @(posedge clk) begin
        s2_valid <= s1_valid;
        s2_x     <= s1_x;
        s2_y     <= s1_y;
        if (s1_valid) begin
            // Slide the window one column to the left, for all three rows...
            for (int r = 0; r < 3; r++) begin
                w[r][0] <= w[r][1];
                w[r][1] <= w[r][2];
            end
            // ...and put the new column triple into the rightmost column.
            w[0][2] <= c_top;   // row y-2
            w[1][2] <= c_mid;   // row y-1
            w[2][2] <= c_bot;   // row y
        end
    end

    // ---- stage 3: the weighted sum, output only for interior centres --------------------
    logic signed [OW-1:0] acc;
    always_comb begin
        acc = '0;
        for (int r = 0; r < 3; r++) begin
            for (int c = 0; c < 3; c++) begin
                // Pixel: zero-extend to 9 bits, then treat as signed so it stays positive.
                // Both operands are widened to OW bits (sign-extended) before multiplying,
                // so the multiply and the sum are signed and cannot overflow.
                acc = acc + OW'(K[r][c]) * OW'($signed({1'b0, w[r][c]}));
            end
        end
    end
    always_ff @(posedge clk) begin
        // The window holds three real rows and three real columns once s2_x >= 2 and s2_y >= 2.
        out_valid <= s2_valid && (s2_x >= 2) && (s2_y >= 2);
        out_val   <= acc;
        // The window's centre is one column and one row behind the pixel that just arrived.
        out_x     <= s2_x - 1'b1;
        out_y     <= s2_y - 1'b1;
    end
endmodule
