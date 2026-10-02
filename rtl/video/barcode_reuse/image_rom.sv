`timescale 1ns/1ps
/*
 *  REUSED MODULE -- Mini-Project 2 (barcode reader) workspace, rtl/image_rom.sv (Lesson 3's image
 *  memory, made dual-clock). CHANGES: none. Three instances in video_subsystem.sv: piano0/1/2.
 */
/*
 *  image_rom.sv -- a 320x240 8-bit greyscale picture in on-chip memory (M10K), with TWO read ports on
 *  two clocks: port A for the analysis (50 MHz sweep), port B for the display (25 MHz pixel clock).
 *  An M10K has two ports, so one copy of the picture serves both; two copies would double the memory
 *  (a picture is 614 kbit, 15 % of the chip). Quartus fills it from the .mif (the ram_init_file
 *  attribute) and infers a dual-clock ROM; simulators read the .hex twin (tools/make_barcode.py
 *  writes both, tools/mif_to_hex.py converts).
 */
module image_rom #(
    parameter int    W        = 320,
    parameter int    H        = 240,
    parameter string MIF_FILE = "barcode.mif",
    parameter string HEX_FILE = "barcode.hex"
) (
    input  logic                     clk_a,
    input  logic [$clog2(W*H)-1:0]   addr_a,
    output logic [7:0]               q_a,
    input  logic                     clk_b,
    input  logic [$clog2(W*H)-1:0]   addr_b,
    output logic [7:0]               q_b
);
    (* ram_init_file = MIF_FILE *) logic [7:0] mem [0:W*H-1];
`ifdef VERILATOR
    initial $readmemh(HEX_FILE, mem);
`elsif MODEL_TECH
    initial $readmemh(HEX_FILE, mem);
`endif
    always_ff @(posedge clk_a) q_a <= mem[addr_a];
    always_ff @(posedge clk_b) q_b <= mem[addr_b];
endmodule
