`timescale 1ns/1ps
/*
 *  REUSED MODULE -- Mini-Project 2 (barcode reader) workspace, rtl/raster_source.sv. CHANGES: none.
 *  In A2 it sweeps the selected piano picture for video_subsystem.sv (GAP = 2048).
 */
/*
 *  raster_source.sv -- sweep the picture out of its ROM as a pixel stream with coordinates,
 *  one pixel per clock, then pause, then sweep again. This is the "analysis" stream: it runs in
 *  its own clock domain at full speed and does not care about the monitor. (The display has its
 *  own copy of the ROM and its own sweep, paced by the VGA controller.)
 *
 *  frame_start pulses one clock before the first pixel; the gap between sweeps (GAP clocks)
 *  gives the downstream picker and decoder time to run on the finished profile.
 */
module raster_source #(
    parameter int W   = 320,
    parameter int H   = 240,
    parameter int GAP = 2048
) (
    input  logic                     clk,
    input  logic                     reset,
    output logic [$clog2(W*H)-1:0]   rom_addr,
    input  logic [7:0]               rom_q,          // one cycle after rom_addr
    output logic                     frame_start,
    output logic                     out_valid,
    output logic [7:0]               out_pixel,
    output logic [$clog2(W)-1:0]     out_x,
    output logic [$clog2(H)-1:0]     out_y
);
    logic [$clog2(W)-1:0] x;  logic [$clog2(H)-1:0] y;
    logic [$clog2(GAP):0] gap;
    logic sweeping;
    // Three steps, one clock each: the address for (x,y) goes out; the ROM answers; the pixel is presented
    // with its coordinates. So (x,y) travel with their pixel through two registers.
    assign rom_addr = ($clog2(W*H))'(y) * W + x;
    logic                 v1;  logic [$clog2(W)-1:0] x1;  logic [$clog2(H)-1:0] y1;
    always_ff @(posedge clk) begin
        frame_start <= 1'b0;
        if (reset) begin x <= '0; y <= '0; sweeping <= 1'b0; gap <= '0; end
        else if (!sweeping) begin
            if (gap == GAP) begin gap <= '0; sweeping <= 1'b1; x <= '0; y <= '0; frame_start <= 1'b1; end
            else gap <= gap + 1'b1;
        end else begin
            if (x == W-1) begin
                x <= '0;
                if (y == H-1) begin y <= '0; sweeping <= 1'b0; end else y <= y + 1'b1;
            end else x <= x + 1'b1;
        end
        // step 2: the ROM is answering for (x1, y1)
        v1 <= sweeping & ~reset; x1 <= x; y1 <= y;
        // step 3: present the pixel with the coordinates it was fetched for
        out_valid <= v1; out_pixel <= rom_q; out_x <= x1; out_y <= y1;
    end
endmodule
