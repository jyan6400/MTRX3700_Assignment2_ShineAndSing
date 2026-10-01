`timescale 1ns/1ps
/*
 *  hdiff.sv -- the 1-D edge detector (SW5 = 0).  (NEW, Advay)
 *  The Mini-Project 2 barcode reader has no 1-D edge module (its pipeline is Sobel only), so this is
 *  written for A2, under the name the course's tools/video/video_model.py gives it, from that model's
 *  float twin grad1d():
 *
 *      out_val = | p[x] - p[x-1] |     for x = 1..W-1, every row
 *
 *  the Lesson 4 two-tap convolution slid along a row. No line buffer, no vertical averaging: the
 *  sides of the keys light up, and so does every noisy pixel (the reason R-V2 replaces it).
 *
 *  A2 addition: the previous pixel only counts if it really was the left neighbour (same row,
 *  x - 1). On the raw raster that is every pixel but the first of a row; behind the R-V4 smoothing
 *  stage (whose stream starts each row at x = 1) it stops the first output of a row being the
 *  difference with the end of the row above.
 *
 *  One register of delay; out_x/out_y carry the coordinates of the pixel the difference belongs to,
 *  so the column profile needs no correction for the delay.
 */
module hdiff #(
    parameter int W  = 320,
    parameter int H  = 240,
    parameter int DW = 8
) (
    input  logic                  clk,
    input  logic                  reset,
    input  logic                  in_valid,
    input  logic [DW-1:0]         in_pixel,
    input  logic [$clog2(W)-1:0]  in_x,
    input  logic [$clog2(H)-1:0]  in_y,
    output logic                  out_valid,
    output logic [DW-1:0]         out_val,
    output logic [$clog2(W)-1:0]  out_x,
    output logic [$clog2(H)-1:0]  out_y
);
    logic [DW-1:0]        prev_pix;
    logic [$clog2(W)-1:0] prev_x;
    logic [$clog2(H)-1:0] prev_y;
    logic                 prev_ok;

    logic neighbour;                 // the stored pixel is (in_x - 1, in_y)
    assign neighbour = prev_ok && (in_x != '0) && (prev_x == in_x - 1'b1) && (prev_y == in_y);

    always_ff @(posedge clk) begin
        if (reset) begin
            prev_ok   <= 1'b0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= in_valid && neighbour;
            if (in_valid) begin
                prev_pix <= in_pixel;
                prev_x   <= in_x;
                prev_y   <= in_y;
                prev_ok  <= 1'b1;
            end
        end
        out_val <= (in_pixel > prev_pix) ? (in_pixel - prev_pix) : (prev_pix - in_pixel);
        out_x   <= in_x;
        out_y   <= in_y;
    end
endmodule
