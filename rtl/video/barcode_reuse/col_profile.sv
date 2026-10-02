`timescale 1ns/1ps
/*
 *  REUSED MODULE -- Lesson 2.3c / Mini-Project 2 (barcode reader), Advay's completed col_profile.sv.
 *  CHANGES FOR ASSIGNMENT 2: none. The piano's rows (Y0 = 150, Y1 = 176: below the black keys and
 *  above the bottom of the white keys in both supplied pictures) and X_LAST are parameters set in
 *  video_subsystem.sv.
 *
 *  col_profile.sv -- sum a per-pixel value down each column: a projection of the picture
 *  onto the x axis.
 *
 *  This is the picture-side twin of "sum the FFT power over a band": many numbers become one
 *  number per column, and vertical structure (the sides of keys, the edges of bars) becomes a
 *  spike in a 1-D signal that a peak picker can read. Only rows Y0..Y1 are summed: choosing
 *  them is a design decision (for a piano, the rows below the black keys).
 *
 *  Storage: one accumulator per column in a RAM (W entries). Pixels arrive in raster order,
 *  so consecutive pixels hit different columns and a registered read-modify-write pipeline
 *  has no hazard. Instead of clearing W entries at every frame, each entry carries the FRAME
 *  TAG it was written in: a stale tag reads as zero. That costs one bit per entry and no time.
 *
 *  `done` pulses once per frame, when the last summed pixel (x = X_LAST, y = Y1) has been added.
 *  The read port (rd_x -> rd_val, one cycle later) shows the completed frame. The writer
 *  starts the next frame at row Y0, which for our streams is far more than W cycles later,
 *  so a reader that starts on `done` and walks W entries sees a stable profile. The RAM is
 *  duplicated (RAM_A for the read-modify-write, RAM_B for the reader) because an M10K has
 *  two ports and we need three.
 */
module col_profile #(
    parameter int W  = 320,
    parameter int H  = 240,
    parameter int VW = 12,      // input value width
    parameter int AW = 20,      // accumulator width: VW + log2(rows summed) is enough
    parameter int Y0 = 0,
    parameter int Y1 = H - 1,
    parameter int X_LAST = W - 1   // the last column that arrives in a row (W-2 after an interior-only 3x3 filter)
) (
    input  logic                  clk,
    input  logic                  reset,
    input  logic                  in_valid,
    input  logic [VW-1:0]         in_val,
    input  logic [$clog2(W)-1:0]  in_x,
    input  logic [$clog2(H)-1:0]  in_y,
    input  logic                  frame_start,   // pulse: a new frame begins (flips the tag)
    output logic                  done,          // pulse: this frame's profile is complete
    input  logic [$clog2(W)-1:0]  rd_x,
    output logic [AW-1:0]         rd_val
);
    localparam int EW = AW + 1;                   // {tag, value}
    logic [EW-1:0] ram_a [0:W-1];
    logic [EW-1:0] ram_b [0:W-1];
    logic tag;                                    // the current frame's tag

    always_ff @(posedge clk)
        if (reset) tag <= 1'b0;
        else if (frame_start) tag <= ~tag;

    // ---- stage 1: read the running sum for this column --------------------------------
    logic                  s1_valid;
    logic [VW-1:0]         s1_val;
    logic [$clog2(W)-1:0]  s1_x;
    logic [EW-1:0]         s1_old;
    logic                  s1_last;
    logic in_row;
    // The pixel's row is inside Y0..Y1 (inclusive).
    // Compared as int so that Y0 = 0 does not become an always-true unsigned ">= 0" test.
    assign in_row = (int'(in_y) >= Y0) && (int'(in_y) <= Y1);
    always_ff @(posedge clk) begin
        s1_valid <= in_valid && in_row && ~reset;
        s1_val   <= in_val;
        s1_x     <= in_x;
        s1_old   <= ram_a[in_x];                       // the running sum for this column, {tag, value}
        // The very last pixel that will be summed this frame: bottom row of the window, last column.
        s1_last  <= in_valid && in_row && (int'(in_x) == X_LAST) && (int'(in_y) == Y1);
    end
    // ---- stage 2: add and write back (both copies) ---------------------------------------
    logic [AW-1:0] old_val;
    // The stored value counts only if it was written this frame; a stale tag reads as zero.
    assign old_val = (s1_old[AW] == tag) ? s1_old[AW-1:0] : '0;
    logic [EW-1:0] new_entry;
    assign new_entry = {tag, old_val + AW'(s1_val)};   // the new running sum, stamped with this frame's tag
    always_ff @(posedge clk) begin
        if (s1_valid) begin
            ram_a[s1_x] <= new_entry;
            ram_b[s1_x] <= new_entry;
        end
        done <= s1_last;
    end
    // ---- reader ---------------------------------------------------------------------------
    logic [EW-1:0] rd_q;
    always_ff @(posedge clk) rd_q <= ram_b[rd_x];
    // Same rule for the reader: a stale tag reads as zero.
    assign rd_val = (rd_q[AW] == tag) ? rd_q[AW-1:0] : '0;
endmodule
