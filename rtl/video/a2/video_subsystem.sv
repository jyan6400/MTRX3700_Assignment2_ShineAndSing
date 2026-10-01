`timescale 1ns/1ps
/*
 *  video_subsystem.sv -- Advay's whole subsystem as one block for top_level.sv.  (NEW, Advay)
 *
 *     SW4..3 --sync--> image select (both clocks)
 *     CLOCK_50 domain:  image ROMs port A -> video_analysis (key finder) -> result bundle
 *                       video_controls (KEY3..1, SW0 -> thresholds)
 *                       edge map (write port), profile view (write port)
 *        | cdc_latch: request/acknowledge handshake, applied while the source waits at pixel (0,0)
 *        | edge map and profile view: dual-clock RAMs (debug views; the picture is static, so a frame
 *        |   can only show a mixed map in the frame in which SW4..3 / SW5 / SW7..6 were moved)
 *     25 MHz domain:    image ROMs port B -> game_video_overlay -> Avalon-ST -> vga_sink (qsys, in top)
 *                       game state from game_video_cdc (Jason) -> overlay
 *
 *  Clock-domain crossings (every one): switches -> two-flop synchronisers (the shared
 *  rtl/common/synchroniser.v, one per bit, in the clock that uses the switch); KEYs -> two-flop
 *  synchronisers + debounce (video_controls); results -> cdc_latch; edge map / profile view ->
 *  dual-clock RAM (write 50 MHz, read 25 MHz; one-frame tearing only while a switch moves). The game
 *  state must already be in the 25 MHz domain (Game -> Video contract, game_video_cdc).
 *
 *  Board mapping (top_level connects the pins):
 *    SW2..SW1 view      0 game, 1 edge map, 2 profile + thresholds, 3 key masks
 *    SW4..SW3 picture   0 supplied piano (memory/piano0), 1 second piano (piano1), 2 tutor's photo (piano2)
 *    SW5      edge      0 1-D difference, 1 Sobel
 *    SW7..SW6 mode      0 R-V4 (default, all down), 1 R-V3, 2 R-V2, 3 R-V1   (video_analysis.sv)
 *    SW0, KEY3..KEY1    threshold adjustment (video_controls.sv)
 *    KEY0               reset (top_level synchronises it into both clocks)
 *
 *  Sizes default to the frozen constants in rtl/common/assignment2_pkg.sv (IMG_W x IMG_H source
 *  picture, VGA_W x VGA_H screen, GAME_COUNT_W, SCORE_W); a testbench may override them.
 */
module video_subsystem #(
    parameter int    IMG_W      = assignment2_pkg::IMG_W,         // source picture (320 x 240)
    parameter int    IMG_H      = assignment2_pkg::IMG_H,
    parameter int    VGA_W      = assignment2_pkg::VGA_W,         // screen (640 x 480) = picture << SH
    parameter int    VGA_H      = assignment2_pkg::VGA_H,
    parameter int    SH         = 1,
    parameter int    NMAX       = 32,
    parameter int    GAME_COUNT_W = assignment2_pkg::GAME_COUNT_W,
    parameter int    LANE_FIRST = 15,      // 15: the four middle keys found; 0..14: lane 0 is that white key
    parameter int    DB_TICKS   = 65536,
    parameter int    GAP        = 2048,
    parameter string MIF0 = "memory/piano0.mif", HEX0 = "memory/piano0.hex",
    parameter string MIF1 = "memory/piano1.mif", HEX1 = "memory/piano1.hex",
    parameter string MIF2 = "memory/piano2.mif", HEX2 = "memory/piano2.hex"
) (
    input  logic                     clk_50,
    input  logic                     reset_50,      // synchronous to clk_50, active high
    input  logic                     clk_25,
    input  logic                     reset_25,      // synchronous to clk_25, active high
    // switches and keys, raw from the pins
    input  logic [1:0]               sw_view,       // SW2..SW1
    input  logic [1:0]               sw_image,      // SW4..SW3
    input  logic                     sw_edge,       // SW5
    input  logic [1:0]               sw_mode,       // SW7..SW6
    input  logic                     sw_adjust,     // SW0
    input  logic [3:1]               key_n,         // KEY3..KEY1, active low
    // game state, already in the 25 MHz domain (Game -> Video contract)
    input  logic [3:0]               lane_active,
    input  logic [GAME_COUNT_W-1:0]  lane_count [0:3],
    input  logic [3:0]               lane_hit_window,
    input  logic [3:0]               lane_hit_pulse,
    input  logic [assignment2_pkg::SCORE_W-1:0] score,
    // Avalon-ST video source (25 MHz) -> vga_sink.video_in
    output logic [29:0]              st_data,
    output logic                     st_startofpacket,
    output logic                     st_endofpacket,
    output logic                     st_valid,
    input  logic                     st_ready,
    // Contract D, for debug only (50 MHz): the boundary list of the last result
    output logic                     boundary_valid,
    output logic [$clog2(NMAX+1)-1:0] boundary_count,
    output logic [NMAX-1:0][$clog2(IMG_W)-1:0] boundary_x,   // boundary_x[i] = source x of boundary i
    output logic                     lanes_valid
);
    localparam int W = IMG_W, H = IMG_H, H_RES = VGA_W, V_RES = VGA_H;
    localparam int XW = $clog2(W);
    localparam int AW = 20, NW = 9;
    localparam int CW = $clog2(NMAX) + 1;

    // ------------------------------------------------------------------ synchronisers
    // 50 MHz (analysis): picture, edge detector, mode;  25 MHz (display): picture, view
    logic [1:0] img50, img25, view_s, mode_s;
    logic       edge_s;
    for (genvar i = 0; i < 2; i++) begin : g_sync2
        synchroniser u_img50 (.clk(clk_50), .x(sw_image[i]), .y(img50[i]));
        synchroniser u_mode  (.clk(clk_50), .x(sw_mode[i]),  .y(mode_s[i]));
        synchroniser u_img25 (.clk(clk_25), .x(sw_image[i]), .y(img25[i]));
        synchroniser u_view  (.clk(clk_25), .x(sw_view[i]),  .y(view_s[i]));
    end
    synchroniser u_edge (.clk(clk_50), .x(sw_edge), .y(edge_s));

    // ------------------------------------------------------------------ the pictures (one M10K ROM each, two clocks)
    logic [$clog2(W*H)-1:0] ra_addr, rb_addr;
    logic [7:0] qa0, qa1, qa2, qb0, qb1, qb2, ra_q, rb_q;
    image_rom #(.W(W), .H(H), .MIF_FILE(MIF0), .HEX_FILE(HEX0)) u_rom0 (.clk_a(clk_50), .addr_a(ra_addr), .q_a(qa0), .clk_b(clk_25), .addr_b(rb_addr), .q_b(qb0));
    image_rom #(.W(W), .H(H), .MIF_FILE(MIF1), .HEX_FILE(HEX1)) u_rom1 (.clk_a(clk_50), .addr_a(ra_addr), .q_a(qa1), .clk_b(clk_25), .addr_b(rb_addr), .q_b(qb1));
    image_rom #(.W(W), .H(H), .MIF_FILE(MIF2), .HEX_FILE(HEX2)) u_rom2 (.clk_a(clk_50), .addr_a(ra_addr), .q_a(qa2), .clk_b(clk_25), .addr_b(rb_addr), .q_b(qb2));
    assign ra_q = (img50 == 2'd0) ? qa0 : (img50 == 2'd1) ? qa1 : qa2;     // 3 selects the photo too
    assign rb_q = (img25 == 2'd0) ? qb0 : (img25 == 2'd1) ? qb1 : qb2;

    // ------------------------------------------------------------------ 50 MHz: controls and the key finder
    logic [NW-1:0] hi, lo, floor_lvl; logic [7:0] k_q; logic [AW-1:0] thr_abs;
    video_controls #(.AW(AW), .NW(NW), .DB_TICKS(DB_TICKS)) u_ctrl (.clk(clk_50), .reset(reset_50),
        .key_n, .sw_sel(sw_adjust), .mode(mode_s), .hi, .lo, .floor_lvl, .k_q, .thr_abs);

    logic result_valid, r_lanes_valid, r_edge, r_ovf; logic [CW-1:0] r_bcount, r_kcount;
    logic [NMAX*XW-1:0] r_bounds; logic [NMAX-1:0] r_kept; logic [XW-1:0] r_spacing;
    logic [4*XW-1:0] r_l, r_r; logic [1:0] r_mode; logic [AW-1:0] r_max;
    logic ew_en, pw_en; logic [$clog2(W*H)-1:0] ew_addr; logic [3:0] ew_data; logic [XW-1:0] pw_x; logic [3*NW-1:0] pw_data;
    video_analysis #(.W(W), .H(H), .NMAX(NMAX), .AW(AW), .NW(NW), .GAP(GAP)) u_analysis (
        .clk(clk_50), .reset(reset_50), .rom_addr(ra_addr), .rom_q(ra_q),
        .edge_sel(edge_s), .mode(mode_s), .hi, .lo, .floor_lvl, .k_q, .thr_abs, .lane_first(4'(LANE_FIRST)),
        .result_valid, .res_bcount(r_bcount), .res_bounds(r_bounds), .res_kept(r_kept), .res_kcount(r_kcount),
        .res_spacing(r_spacing), .res_lanes_valid(r_lanes_valid), .res_lane_l(r_l), .res_lane_r(r_r),
        .res_mode(r_mode), .res_edge_sel(r_edge), .res_max(r_max), .res_overflow(r_ovf),
        .ew_en, .ew_addr, .ew_data, .pw_en, .pw_x, .pw_data);

    assign boundary_valid = result_valid;
    assign boundary_count = r_bcount;
    assign boundary_x     = r_bounds;
    assign lanes_valid    = r_lanes_valid;

    // ------------------------------------------------------------------ debug-view memories (dual clock)
    logic [3:0] edge_mem [0:W*H-1];
    logic [3:0] edge_q;
    always_ff @(posedge clk_50) if (ew_en) edge_mem[ew_addr] <= ew_data;
    always_ff @(posedge clk_25) edge_q <= edge_mem[rb_addr];

    logic [3*NW-1:0] prof_mem [0:W-1];
    logic [3*NW-1:0] prof_q;
    logic [XW-1:0]   prof_rx;
    always_ff @(posedge clk_50) if (pw_en) prof_mem[pw_x] <= pw_data;
    always_ff @(posedge clk_25) prof_q <= prof_mem[prof_rx];

    // ------------------------------------------------------------------ results into the pixel clock
    localparam int RW = CW + NMAX*XW + NMAX + 1 + 8*XW + 2 + 1;
    logic [RW-1:0] bundle_src, bundle_dst; logic vblank, updated, busy;
    assign bundle_src = {r_bcount, r_bounds, r_kept, r_lanes_valid, r_l, r_r, r_mode, r_edge};
    cdc_latch #(.WIDTH(RW)) u_latch (.src_clk(clk_50), .src_valid(result_valid), .src_data(bundle_src), .src_busy(busy),
        .dst_clk(clk_25), .dst_reset(reset_25), .update_ok(vblank), .dst_data(bundle_dst), .dst_updated(updated));
    logic [CW-1:0] d_bcount; logic [NMAX*XW-1:0] d_bounds; logic [NMAX-1:0] d_kept; logic d_lanes_valid;
    logic [4*XW-1:0] d_l, d_r; logic [1:0] d_mode; logic d_edge;
    assign {d_bcount, d_bounds, d_kept, d_lanes_valid, d_l, d_r, d_mode, d_edge} = bundle_dst;

    // ------------------------------------------------------------------ 25 MHz: the picture on the monitor
    logic frame_latch;
    game_video_overlay #(.H_RES(H_RES), .V_RES(V_RES), .W(W), .H(H), .SH(SH), .NMAX(NMAX), .NW(NW),
                         .GAME_COUNT_W(GAME_COUNT_W)) u_overlay (
        .clk(clk_25), .reset(reset_25), .view_sel(view_s),
        .src_addr(rb_addr), .grey(rb_q), .edge4(edge_q), .prof_x(prof_rx), .prof_data(prof_q),
        .res_bcount(d_bcount), .res_bounds(d_bounds), .res_kept(d_kept), .res_lanes_valid(d_lanes_valid),
        .res_lane_l(d_l), .res_lane_r(d_r), .res_mode(d_mode), .res_edge_sel(d_edge),
        .lane_active, .lane_count, .lane_hit_window, .lane_hit_pulse, .score,
        .data(st_data), .startofpacket(st_startofpacket), .endofpacket(st_endofpacket), .valid(st_valid), .ready(st_ready),
        .vblank, .frame_latch);

    logic unused_ok;
    assign unused_ok = &{1'b0, r_kcount, r_spacing, r_max, r_ovf, updated, busy, frame_latch};
endmodule
