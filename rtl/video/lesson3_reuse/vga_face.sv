/*
 *  REUSED MODULE (reference) -- Lesson 3 Task "VGA Face", Advay's completed vga_face.sv, unchanged.
 *  It is NOT compiled into the Assignment 2 design: its Avalon-ST video source pattern (a pixel index
 *  that advances only on valid && ready, a registered ROM read addressed with the NEXT pixel, the wrap
 *  at the end of the frame with startofpacket / endofpacket) is what Mini-Project 2's display.sv and
 *  then rtl/video/a2/game_video_overlay.sv are built on. Kept here so the reuse chain can be traced.
 */
module vga_face #(
    parameter int H_RES = 640,   // Frame size in pixels. The VGA Controller IP needs 640x480, but a testbench can
    parameter int V_RES = 480    //   override these to simulate a small frame in seconds (same idea as shrinking a millisecond counter).
) (
    input  logic        clk,
    input  logic        reset,
    input  logic [1:0]  face_select,     // 0: Happy, 1: Neutral, 2: Angry

    // Avalon-ST Interface:
    output logic [29:0] data,            // Data output to VGA (8 data bits + 2 padding bits for each colour Red, Green and Blue = 30 bits)
    output logic        startofpacket,   // Start of packet signal
    output logic        endofpacket,     // End of packet signal
    output logic        valid,           // Data valid signal
    input  logic        ready            // Data ready signal from VGA Module
);
    typedef enum logic [1:0] {Happy=2'd0, Neutral=2'd1, Angry=2'd2} face_t; // Define an enum type for readability (optional).

    localparam NumPixels     = H_RES * V_RES; // Total number of pixels in a frame (640x480 = 307200 on the real screen)
    localparam NumColourBits = 3;         // We are using a 3-bit colour space to fit 3 images within the 3.970 Mbits of BRAM on our FPGA.

    // Image ROMs:
    (* ram_init_file = "happy.mif" *)   logic [NumColourBits-1:0] happy_face   [NumPixels]; // The ram_init_file is a Quartus-only directive
    (* ram_init_file = "neutral.mif" *) logic [NumColourBits-1:0] neutral_face [NumPixels]; //   specifying the name of the initialisation file,
    (* ram_init_file = "angry.mif" *)   logic [NumColourBits-1:0] angry_face   [NumPixels]; //   and Verilator will ignore it.

    `ifdef VERILATOR
    initial begin : memset /* The 'ifdef VERILATOR' means this initial block is ignored in Quartus. The .hex files must be H_RES x V_RES pixels: */
        $readmemh("happy.hex", happy_face);
        $readmemh("neutral.hex", neutral_face);
        $readmemh("angry.hex", angry_face);
    end
    `endif

    logic [$clog2(NumPixels)-1:0] pixel_index = 0, pixel_index_next; // The pixel counter/index (19 bits for 640x480). Set pixel_index_next in an always_comb block.
                                                    // Set pixel_index <= pixel_index_next in an always_ff block.

    logic [NumColourBits-1:0] happy_face_q, neutral_face_q, angry_face_q; // Registers for reading from each ROM.

    logic read_enable; // Need to have a read enable signal for the BRAM
    assign read_enable = reset | (valid & ready); // If reset, read the first pixel value. If valid&ready (handshake), read the next pixel value for the next handshake.

    always_ff @(posedge clk) begin : bram_read // This block is for correctly inferring BRAM in Quartus - we need read registers!
        if (read_enable) begin
            happy_face_q   <= happy_face[pixel_index_next];
            neutral_face_q <= neutral_face[pixel_index_next];
            angry_face_q   <= angry_face[pixel_index_next];
        end
    end

    // Select which face's pixel to stream. A default case is included so no latch is inferred
    // (face_select == 2'd3 is unused, so fall back to the happy face).
    logic [NumColourBits-1:0] current_pixel;
    always_comb begin : face_mux
        case (face_select)
            Happy:   current_pixel = happy_face_q;
            Neutral: current_pixel = neutral_face_q;
            Angry:   current_pixel = angry_face_q;
            default: current_pixel = happy_face_q;
        endcase
    end

    // We stream continuously: a pixel is always available except while in reset.
    assign valid = ~reset;

    assign startofpacket = pixel_index == 0;         // Start of frame
    assign endofpacket = pixel_index == NumPixels-1; // End of frame

    // Each 1-bit colour channel is replicated to 8 bits, then padded with 2 zero bits:
    // {Red(8), 2'b00, Green(8), 2'b00, Blue(8), 2'b00}. Bit 2 = Red, bit 1 = Green, bit 0 = Blue.
    assign data = { {8{current_pixel[2]}}, 2'b00,    // Red   + padding
                    {8{current_pixel[1]}}, 2'b00,    // Green + padding
                    {8{current_pixel[0]}}, 2'b00 };  // Blue  + padding

    // What the index *would* become next: wrap back to 0 after the last pixel of the frame,
    // so the next frame starts cleanly (a missing wrap gives a frozen screen).
    assign pixel_index_next = reset                  ? '0 :
                              (pixel_index == NumPixels-1) ? '0 :
                                                         pixel_index + 1'b1;

    always_ff @(posedge clk) begin : pixel_counter
        if (reset)
            pixel_index <= '0;                 // Reset: restart at the first pixel of the frame.
        else if (valid && ready)
            pixel_index <= pixel_index_next;   // Only advance on a handshake, else hold (back-pressure).
    end

endmodule
