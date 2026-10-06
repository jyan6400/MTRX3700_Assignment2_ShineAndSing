`timescale 1ns/1ps
/*
 *  video_subsystem.sv -- the integrated video path: the reused image-processing modules and the five
 *  new A2 modules connected into the key finder, the board-adjustable thresholds, the crossing into the
 *  pixel clock and the VGA overlay. It is what video_subsystem_tb tests, and one block for
 *  top_level.sv to instantiate.  (NEW, Advay: the A2 successor of Mini-Project 2's barcode_reader.sv +
 *  top-level wiring, with the bar decoder removed and the R-V1..R-V4 stages added.)
 *
 *     SW4..3 --sync--> image select (both clocks)
 *     CLOCK_50 domain:  image ROMs port A -> raster_source -> [smoothing conv3x3, R-V4]
 *                         -> 1-D difference (SW5 = 0) | sobel (SW5 = 1) -> col_profile (rows Y0..Y1)
 *                         -> profile_normalise -> local_threshold -> picker selected by SW7..6
 *                         -> key_mask_generator -> result bundle
 *                       KEY3..1, SW0 -> the thresholds
 *                       edge map (write port), profile view (write port)
 *        | cdc_latch: request/acknowledge handshake, applied while the source waits at pixel (0,0)
 *        | edge map and profile view: dual-clock RAMs (debug views; the picture is static, so a frame
 *        |   can only show a mixed map in the frame in which SW4..3 / SW5 / SW7..6 were moved). The
 *        |   display side reads each location once and holds it, and changes picture only between
 *        |   frames, so an offered pixel never changes while the VGA controller stalls.
 *     25 MHz domain:    image ROMs port B -> game_video_overlay -> Avalon-ST -> vga_sink (qsys, in top)
 *                       game state from game_video_cdc (Jason) -> overlay
 *
 *  THE RUNGS (SW7..SW6 = mode; SW5 picks the edge detector in every mode):
 *    mode  rung       picker                                                       smoothing  min_gap
 *     0    R-V4       hysteresis_profile, hi/lo from the local average (+ floor)    yes        8
 *     1    R-V3       hysteresis_profile, constant hi/lo on the normalised profile  no         10
 *    2, 3  R-V1/R-V2  peak_pick on the raw profile, one absolute threshold          no         8
 *                     (SW5 = 0: the 1-D difference = R-V1;  SW5 = 1: Sobel = R-V2)
 *  The absolute threshold is given in 1-D units and multiplied by 4 for Sobel (the gain of its 1-2-1
 *  weights), so one setting serves both detectors (default 2048, x 4 = 8192).
 *
 *  THE 1-D EDGE DETECTOR is |p[x] - p[x-1]| along a row: one register and a subtractor, written in
 *  this file (the Mini-Project 2 barcode reader is Sobel-only, so there was no module to reuse). The
 *  previous pixel only counts if it really was the left neighbour (same row, x - 1): on the raw raster
 *  that is every pixel but the first of a row; behind the smoothing stage (whose rows start at x = 1)
 *  it stops a row's first output being the difference with the end of the row above.
 *
 *  ROWS Y0..Y1 = 150..176: below the black keys and above the bottom of the white keys in BOTH supplied
 *  pictures (picture 1's white keys run to row 216, picture 2's -- letterboxed -- only to row 179,
 *  under which is the dark frame), with a row of margin for the 3x3 windows. The overlay draws the
 *  lanes over the same rows.
 *
 *  LATENCY / POSITIONS: every convolution stage carries the CENTRE coordinates of its output with the
 *  value (conv3x3's out_x/out_y), so the column profile is indexed by the true picture column whatever
 *  the pipeline delay: that is how the Sobel and smoothing delays are accounted for in the boundary
 *  positions. With smoothing on, the Sobel window at centres x = 1, x = W-2, y = 1 and y = H-2 would
 *  include a column/row the smoothing stage never produced, so those centres are masked out.
 *  col_profile's X_LAST is W-4: the last column that arrives in every mode is W-2 (1-D), W-2 (Sobel),
 *  W-3 (smoothed Sobel); `done` fires at most 2 clocks before those columns are written, and
 *  profile_normalise reads them W-3 clocks later.
 *
 *  TIMING BUDGET per sweep (W = 320, H = 240): a sweep is 76 800 + GAP clocks (1.6 ms). After the
 *  profile's last row the post-processing takes about 5 000 clocks (normalise 4 200, the threshold
 *  340, the picker 330..450, the key masks < 100), finishing long before the next sweep reaches row Y0
 *  (and before its frame_start flips the profile's tag, 22 000 clocks away). The mode and the edge
 *  detector are latched at the start of each sweep and the thresholds when the post-processing
 *  starts, so a result is always from one consistent setting.
 *
 *  THE THRESHOLDS ON THE BOARD (R-V3: "thresholds controllable from free board inputs"):
 *    KEY1 raises the selected value, KEY2 lowers it, KEY3 restores every default; SW0 selects:
 *      mode              SW0 = 0                         SW0 = 1
 *      0     R-V4        k   (k_q, step 8 = +-0.2 x)      floor   (step 4 = 1.6 %)
 *      1     R-V3        hi  (step 8 = 3.1 % of max)      lo      (step 8)
 *      2, 3  R-V1/R-V2   thr_abs (step 256, 1-D units)    thr_abs
 *    Defaults (chosen with tools/video/hw_model.py on the two supplied pictures: at these values every
 *    rung reads both of them, and only R-V4 also reads the photo-like picture): hi = 115 (0.45),
 *    lo = 64 (0.25), floor = 26 (0.10), k_q = 102 (k = 2.5 over 25 columns), thr_abs = 2048.
 *    The keys are active low and bounce: each goes through the shared synchroniser.v, is sampled every
 *    DB_TICKS clocks (2^16 = 1.3 ms at 50 MHz, longer than a bounce), and a press is the sample going
 *    from up to down.
 *
 *  CLOCK-DOMAIN CROSSINGS (every one): switches and keys -> rtl/common/synchroniser.v (one per bit, in
 *  the clock that uses it); results -> cdc_latch; edge map / profile view -> dual-clock RAM (write
 *  50 MHz, read 25 MHz). The game state must already be in the 25 MHz domain (Game -> Video contract,
 *  game_video_cdc). Resets are synchronous and active high, one per clock.
 *
 *  BOARD MAPPING (top_level connects the pins):
 *    SW2..SW1 view      0 game, 1 edge map, 2 profile + thresholds, 3 key masks
 *    SW4..SW3 picture   0 supplied picture 1 (memory/piano0), 1 supplied picture 2 (piano1),
 *                       2 (and 3) the tutor's photograph (piano2)
 *    SW5      edge      0 1-D difference, 1 Sobel
 *    SW7..SW6 mode      0 R-V4 (default, all down), 1 R-V3, 2 or 3 R-V1/R-V2
 *    SW0, KEY3..KEY1    threshold adjustment
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
    parameter int    NMAX       = 32,      // most boundaries kept
    parameter int    NC         = 64,      // most candidate peaks (hysteresis_profile)
    parameter int    GAME_COUNT_W = assignment2_pkg::GAME_COUNT_W,
    parameter int    LANE_FIRST = 15,      // 15: the four middle keys found; 0..14: lane 0 is that white key
    parameter int    Y0         = 150,     // rows summed into the profile, and drawn as lanes
    parameter int    Y1         = 176,
    parameter int    GAP_RV3    = 10,      // min_gap at R-V3
    parameter int    GAP_RV4    = 8,       // min_gap at R-V4 and R-V1/R-V2
    parameter int    DB_TICKS   = 65536,   // key sampling period, clocks
    parameter int    GAP        = 2048,    // clocks between two sweeps of the picture
    parameter int    HI_DEF     = 115,     // threshold defaults (KEY3)
    parameter int    LO_DEF     = 64,
    parameter int    FLOOR_DEF  = 26,
    parameter int    KQ_DEF     = 102,
    parameter int    ABS_DEF    = 2048,
    parameter string MIF0 = "../memory/piano0.mif", HEX0 = "../memory/piano0.hex",
    parameter string MIF1 = "../memory/piano1.mif", HEX1 = "../memory/piano1.hex",
    parameter string MIF2 = "../memory/piano2.mif", HEX2 = "../memory/piano2.hex"
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
    localparam int YW = $clog2(H);
    localparam int PW = $clog2(W*H);           // picture address
    localparam int AW = 20;                    // profile sum
    localparam int NW = 9;                     // normalised profile, 0..256
    localparam int IW = $clog2(NMAX);
    localparam int CW = $clog2(NMAX) + 1;

    // ================================================================== switch synchronisers
    // 50 MHz (analysis): picture, edge detector, mode, SW0;  25 MHz (display): picture, view
    logic [1:0] img50, img25, view_s, mode_s;
    logic       edge_s, sel_s;
    genvar i_sync;
    generate
        for (i_sync = 0; i_sync < 2; i_sync = i_sync + 1) begin : g_sync2
            synchroniser u_img50 (.clk(clk_50), .x(sw_image[i_sync]), .y(img50[i_sync]));
            synchroniser u_mode  (.clk(clk_50), .x(sw_mode[i_sync]),  .y(mode_s[i_sync]));
            synchroniser u_img25 (.clk(clk_25), .x(sw_image[i_sync]), .y(img25[i_sync]));
            synchroniser u_view  (.clk(clk_25), .x(sw_view[i_sync]),  .y(view_s[i_sync]));
        end
    endgenerate
    synchroniser u_edge (.clk(clk_50), .x(sw_edge),   .y(edge_s));
    synchroniser u_sel  (.clk(clk_50), .x(sw_adjust), .y(sel_s));

    // ================================================================== the pictures (one M10K ROM each, two clocks)
    logic [PW-1:0] ra_addr, rb_addr;
    logic [7:0] qa0, qa1, qa2, qb0, qb1, qb2, ra_q, rb_q;
    image_rom #(.W(W), .H(H), .MIF_FILE(MIF0), .HEX_FILE(HEX0)) u_rom0 (.clk_a(clk_50), .addr_a(ra_addr), .q_a(qa0), .clk_b(clk_25), .addr_b(rb_addr), .q_b(qb0));
    image_rom #(.W(W), .H(H), .MIF_FILE(MIF1), .HEX_FILE(HEX1)) u_rom1 (.clk_a(clk_50), .addr_a(ra_addr), .q_a(qa1), .clk_b(clk_25), .addr_b(rb_addr), .q_b(qb1));
    image_rom #(.W(W), .H(H), .MIF_FILE(MIF2), .HEX_FILE(HEX2)) u_rom2 (.clk_a(clk_50), .addr_a(ra_addr), .q_a(qa2), .clk_b(clk_25), .addr_b(rb_addr), .q_b(qb2));
    assign ra_q = (img50 == 2'd0) ? qa0 : (img50 == 2'd1) ? qa1 : qa2;     // 3 selects the photo too
    // The display changes picture only between frames (like every other input of the overlay): a
    // switch moved while the VGA controller is stalling must not change the pixel being offered.
    logic [1:0] img_f; logic frame_latch;
    always_ff @(posedge clk_25) if (reset_25 || frame_latch) img_f <= img25;
    assign rb_q = (img_f == 2'd0) ? qb0 : (img_f == 2'd1) ? qb1 : qb2;

    // ================================================================== the thresholds (KEY3..1, SW0)
    logic [NW-1:0] hi, lo, floor_lvl; logic [7:0] k_q; logic [AW-1:0] thr_abs;

    logic [3:1] kn_s, k_s;                            // keys: synchronised, then 1 = pressed
    genvar i_key;
    generate
        for (i_key = 1; i_key <= 3; i_key = i_key + 1) begin : g_key
            synchroniser u_key (.clk(clk_50), .x(key_n[i_key]), .y(kn_s[i_key]));
        end
    endgenerate
    assign k_s = ~kn_s;

    logic [$clog2(DB_TICKS):0] tick_cnt;              // slow sampling = debounce
    logic tick;
    assign tick = (32'(tick_cnt) == DB_TICKS - 1);
    always_ff @(posedge clk_50) begin
        if (reset_50 || tick) tick_cnt <= '0;
        else tick_cnt <= tick_cnt + 1'b1;
    end
    logic [3:1] k_smp, press;
    always_ff @(posedge clk_50) begin
        press <= '0;
        if (reset_50) k_smp <= '0;
        else if (tick) begin
            k_smp <= k_s;
            press <= k_s & ~k_smp;                    // was up at the last sample, down now
        end
    end

    function automatic logic [NW-1:0] up(input logic [NW-1:0] v, input int step);       // clamps at 256
        return (32'(v) + step > 256) ? NW'(256) : NW'(32'(v) + step);
    endfunction
    function automatic logic [NW-1:0] down(input logic [NW-1:0] v, input int step);     // clamps at 0
        return (32'(v) < step) ? '0 : NW'(32'(v) - step);
    endfunction
    always_ff @(posedge clk_50) begin
        if (reset_50 || press[3]) begin
            hi <= NW'(HI_DEF); lo <= NW'(LO_DEF); floor_lvl <= NW'(FLOOR_DEF); k_q <= 8'(KQ_DEF); thr_abs <= AW'(ABS_DEF);
        end else if (press[1] || press[2]) begin
            case (mode_s)
                2'd0: if (!sel_s) begin
                          if (press[1]) k_q <= (k_q > 8'd247) ? 8'd255 : k_q + 8'd8;
                          else          k_q <= (k_q < 8'd8)   ? 8'd0   : k_q - 8'd8;
                      end else begin
                          if (press[1]) floor_lvl <= up(floor_lvl, 4);
                          else          floor_lvl <= down(floor_lvl, 4);
                      end
                2'd1: if (!sel_s) begin
                          if (press[1]) hi <= up(hi, 8);
                          else          hi <= down(hi, 8);
                      end else begin
                          if (press[1]) lo <= up(lo, 8);
                          else          lo <= down(lo, 8);
                      end
                default: begin
                          if (press[1]) thr_abs <= (thr_abs > {AW{1'b1}} - AW'(256)) ? {AW{1'b1}} : thr_abs + AW'(256);
                          else          thr_abs <= (thr_abs < AW'(256)) ? '0 : thr_abs - AW'(256);
                      end
            endcase
        end
    end

    // ================================================================== 50 MHz: the key finder
    // ------------------------------------------------------------------ sweep
    logic frame_start, px_valid; logic [7:0] px; logic [XW-1:0] px_x; logic [YW-1:0] px_y;
    raster_source #(.W(W), .H(H), .GAP(GAP)) u_src (.clk(clk_50), .reset(reset_50), .rom_addr(ra_addr), .rom_q(ra_q),
        .frame_start, .out_valid(px_valid), .out_pixel(px), .out_x(px_x), .out_y(px_y));

    logic [1:0] cfg_mode;  logic cfg_edge;            // the setting of the sweep under way
    always_ff @(posedge clk_50)
        if (reset_50) begin cfg_mode <= 2'd0; cfg_edge <= 1'b1; end
        else if (frame_start) begin cfg_mode <= mode_s; cfg_edge <= edge_s; end
    logic smooth_on;
    assign smooth_on = (cfg_mode == 2'd0);

    // ------------------------------------------------------------------ R-V4 smoothing (conv3x3, 2nd table)
    logic g_valid; logic signed [12:0] g_val; logic [XW-1:0] g_x; logic [YW-1:0] g_y;
    conv3x3 #(.W(W), .H(H), .DW(8), .OW(13),
              .K('{'{8'sd1, 8'sd2, 8'sd1}, '{8'sd2, 8'sd4, 8'sd2}, '{8'sd1, 8'sd2, 8'sd1}})) u_smooth (
        .clk(clk_50), .reset(reset_50), .in_valid(px_valid), .in_pixel(px), .in_x(px_x), .in_y(px_y),
        .out_valid(g_valid), .out_val(g_val), .out_x(g_x), .out_y(g_y));

    logic s_valid; logic [7:0] s_pix; logic [XW-1:0] s_x; logic [YW-1:0] s_y;
    always_comb begin
        if (smooth_on) begin s_valid = g_valid;  s_pix = g_val[11:4]; s_x = g_x;  s_y = g_y;  end   // /16, 0..255
        else           begin s_valid = px_valid; s_pix = px;          s_x = px_x; s_y = px_y; end
    end

    // ------------------------------------------------------------------ edge detectors (both run; SW5 selects)
    // Sobel: two conv3x3 instances (sobel.sv)
    logic sb_valid; logic [11:0] sb_gx, sb_gy; logic [12:0] sb_mag; logic [XW-1:0] sb_x; logic [YW-1:0] sb_y;
    sobel #(.W(W), .H(H)) u_sobel (.clk(clk_50), .reset(reset_50), .in_valid(s_valid), .in_pixel(s_pix), .in_x(s_x), .in_y(s_y),
        .out_valid(sb_valid), .out_gx(sb_gx), .out_gy(sb_gy), .out_mag(sb_mag), .out_x(sb_x), .out_y(sb_y));

    // 1-D: |p[x] - p[x-1]|, one register of delay, coordinates carried with the value
    logic hd_valid; logic [7:0] hd_val; logic [XW-1:0] hd_x; logic [YW-1:0] hd_y;
    logic [7:0] hd_prev; logic [XW-1:0] hd_prev_x; logic [YW-1:0] hd_prev_y; logic hd_prev_ok;
    logic hd_neighbour;                               // the stored pixel is (s_x - 1, s_y)
    assign hd_neighbour = hd_prev_ok && (s_x != '0) && (hd_prev_x == s_x - 1'b1) && (hd_prev_y == s_y);
    always_ff @(posedge clk_50) begin
        if (reset_50) begin
            hd_prev_ok <= 1'b0;
            hd_valid   <= 1'b0;
        end else begin
            hd_valid <= s_valid && hd_neighbour;
            if (s_valid) begin
                hd_prev    <= s_pix;
                hd_prev_x  <= s_x;
                hd_prev_y  <= s_y;
                hd_prev_ok <= 1'b1;
            end
        end
        hd_val <= (s_pix > hd_prev) ? (s_pix - hd_prev) : (hd_prev - s_pix);
        hd_x   <= s_x;
        hd_y   <= s_y;
    end

    logic sb_inside;          // with smoothing on, the smoothed picture's own border is masked
    assign sb_inside = !smooth_on ||
                       ((int'(sb_x) >= 2) && (int'(sb_x) <= W - 3) && (int'(sb_y) >= 2) && (int'(sb_y) <= H - 3));

    logic e_valid; logic [11:0] e_val; logic [7:0] e_show; logic [XW-1:0] e_x; logic [YW-1:0] e_y;
    always_comb begin
        if (cfg_edge) begin
            e_valid = sb_valid && sb_inside; e_val = sb_gx; e_x = sb_x; e_y = sb_y;
            e_show  = (sb_mag[12:2] > 11'd255) ? 8'd255 : sb_mag[9:2];          // |Gx|+|Gy| / 4
        end else begin
            e_valid = hd_valid; e_val = {4'd0, hd_val}; e_x = hd_x; e_y = hd_y;
            e_show  = hd_val;
        end
    end

    // R-V0: the edge map for view 1, 4 bits per pixel (one write per edge-detector output pixel)
    logic ew_en; logic [PW-1:0] ew_addr; logic [3:0] ew_data;
    always_ff @(posedge clk_50) begin
        ew_en   <= e_valid && !reset_50;
        ew_addr <= PW'(e_y) * PW'(W) + PW'(e_x);
        ew_data <= e_show[7:4];
    end

    // ------------------------------------------------------------------ column profile
    logic prof_done; logic [XW-1:0] prof_rd_x; logic [AW-1:0] prof_rd_val;
    col_profile #(.W(W), .H(H), .VW(12), .AW(AW), .Y0(Y0), .Y1(Y1), .X_LAST(W-4)) u_prof (
        .clk(clk_50), .reset(reset_50), .in_valid(e_valid), .in_val(e_val), .in_x(e_x), .in_y(e_y), .frame_start,
        .done(prof_done), .rd_x(prof_rd_x), .rd_val(prof_rd_val));

    // the setting latched for the result being computed
    logic [1:0] r_mode; logic r_edge;
    logic [NW-1:0] r_hi, r_lo, r_floor; logic [7:0] r_kq; logic [AW-1:0] r_abs;
    logic [XW-1:0] r_gap;

    // Columns the current setting never writes read as 0. col_profile's frame tag is one bit, so a
    // column written two sweeps ago with a different edge detector (e.g. x = W-1 by the 1-D difference,
    // then never by Sobel) would read back as fresh -- the Lesson 2.3c lab question. Every column inside
    // the range below is written on every summed row, so its tag is always current.
    //   1-D: x = 1..W-1   Sobel: 1..W-2   smoothed 1-D: 2..W-2   smoothed Sobel: 2..W-3
    logic [XW-1:0] prof_rd_x_q; logic [AW-1:0] prof_val;
    int col_lo, col_hi;
    always_comb begin
        col_lo = (r_mode == 2'd0) ? 2 : 1;
        col_hi = W - 1 - (r_edge ? 1 : 0) - ((r_mode == 2'd0) ? 1 : 0);
    end
    always_ff @(posedge clk_50) prof_rd_x_q <= prof_rd_x;
    assign prof_val = ((int'(prof_rd_x_q) >= col_lo) && (int'(prof_rd_x_q) <= col_hi)) ? prof_rd_val : '0;

    // ------------------------------------------------------------------ R-V3: normalise
    logic nz_start, nz_busy, nz_done; logic [XW-1:0] nz_src_x, nz_rd_x; logic [NW-1:0] nz_rd_val, thr_n;
    logic [AW-1:0] max_val; logic nz_wr; logic [XW-1:0] nz_wx; logic [NW-1:0] nz_wv;
    profile_normalise #(.W(W), .AW(AW), .NW(NW)) u_norm (.clk(clk_50), .reset(reset_50), .start(nz_start), .thr_abs(r_abs),
        .src_rd_x(nz_src_x), .src_rd_val(prof_val), .busy(nz_busy), .done(nz_done), .max_val, .thr_n,
        .out_wr(nz_wr), .out_x(nz_wx), .out_val(nz_wv), .rd_x(nz_rd_x), .rd_val(nz_rd_val));

    // ------------------------------------------------------------------ R-V4: local threshold
    logic lt_start, lt_busy, lt_done; logic [XW-1:0] lt_src_x, lt_rd_x; logic [NW-1:0] lt_rd_val;
    local_threshold #(.W(W), .NW(NW), .TW(NW), .HALF(12)) u_lthr (.clk(clk_50), .reset(reset_50), .start(lt_start), .k_q(r_kq),
        .src_rd_x(lt_src_x), .src_rd_val(nz_rd_val), .busy(lt_busy), .done(lt_done),
        .rd_x(lt_rd_x), .rd_val(lt_rd_val));

    // ------------------------------------------------------------------ pickers
    // R-V3 / R-V4: local maxima + two thresholds + min_gap (it always runs: it also streams the profile view)
    logic hy_start, hy_busy, hy_done, hy_ovf; logic [XW-1:0] hy_rd_x; logic [CW-1:0] hy_count;
    logic [IW-1:0] km_idx; logic [XW-1:0] hy_pos;
    logic hy_dwr; logic [XW-1:0] hy_dx; logic [NW-1:0] hy_dn, hy_dhi, hy_dlo;
    hysteresis_profile #(.W(W), .NW(NW), .NC(NC), .NMAX(NMAX)) u_hyst (.clk(clk_50), .reset(reset_50), .start(hy_start),
        .adaptive(r_mode == 2'd0), .hi(r_hi), .lo(r_lo), .floor_lvl(r_floor), .min_gap(r_gap),
        .rd_x(hy_rd_x), .n_val(nz_rd_val), .t_val(lt_rd_val),
        .busy(hy_busy), .done(hy_done), .count(hy_count), .idx(km_idx), .pos_of(hy_pos), .cand_overflow(hy_ovf),
        .dsp_wr(hy_dwr), .dsp_x(hy_dx), .dsp_n(hy_dn), .dsp_hi(hy_dhi), .dsp_lo(hy_dlo));

    // R-V1 / R-V2: the reused peak picker on the raw profile, one absolute threshold
    logic pk_start, pk_busy, pk_done; logic [XW-1:0] pk_rd_x, pk_pos; logic [CW-1:0] pk_count;
    peak_pick #(.W(W), .AW(AW), .NMAX(NMAX)) u_peak (.clk(clk_50), .reset(reset_50), .start(pk_start), .thr(r_abs), .min_gap(r_gap),
        .rd_x(pk_rd_x), .rd_val(prof_val), .busy(pk_busy), .done(pk_done), .count(pk_count), .idx(km_idx), .pos_of(pk_pos));

    // read-port sharing: the profile RAM (normalise, then peak_pick), the normalised RAM
    // (local threshold, then hysteresis); the threshold RAM is read by hysteresis only
    assign prof_rd_x = nz_busy ? nz_src_x : pk_rd_x;
    assign nz_rd_x   = lt_busy ? lt_src_x : hy_rd_x;
    assign lt_rd_x   = hy_rd_x;

    // ------------------------------------------------------------------ key masks
    logic km_start, km_busy, km_done; logic [CW-1:0] sel_count; logic [XW-1:0] sel_pos;
    logic [CW-1:0] km_bcount, km_kcount; logic [NMAX*XW-1:0] km_bounds; logic [NMAX-1:0] km_kept;
    logic [XW-1:0] km_spacing; logic km_lanes_valid; logic [4*XW-1:0] km_l, km_r;
    assign sel_count = r_mode[1] ? pk_count : hy_count;
    assign sel_pos   = r_mode[1] ? pk_pos   : hy_pos;
    key_mask_generator #(.W(W), .NMAX(NMAX)) u_keys (.clk(clk_50), .reset(reset_50), .start(km_start), .lane_first(4'(LANE_FIRST)),
        .count(sel_count), .idx(km_idx), .pos_of(sel_pos), .busy(km_busy), .done(km_done),
        .bcount(km_bcount), .bounds(km_bounds), .kept_mask(km_kept), .kcount(km_kcount), .spacing(km_spacing),
        .lanes_valid(km_lanes_valid), .lane_l(km_l), .lane_r(km_r));

    // ------------------------------------------------------------------ sequencer and the result
    // results: stable from one result_valid pulse to the next
    logic result_valid, res_lanes_valid, res_edge_sel, res_overflow; logic [CW-1:0] res_bcount, res_kcount;
    logic [NMAX*XW-1:0] res_bounds; logic [NMAX-1:0] res_kept; logic [XW-1:0] res_spacing;
    logic [4*XW-1:0] res_lane_l, res_lane_r; logic [1:0] res_mode; logic [AW-1:0] res_max;

    typedef enum logic [2:0] {P_IDLE, P_NORM, P_THR, P_HYST, P_KEYS, P_PUB} pstate_t;
    pstate_t ps;
    logic lt_fin, pick_fin;
    always_ff @(posedge clk_50) begin
        nz_start <= 1'b0; lt_start <= 1'b0; hy_start <= 1'b0; pk_start <= 1'b0;
        km_start <= 1'b0; result_valid <= 1'b0;
        if (reset_50) begin
            ps <= P_IDLE; res_bcount <= '0; res_lanes_valid <= 1'b0; res_kcount <= '0; res_kept <= '0;
            res_bounds <= '0; res_lane_l <= '0; res_lane_r <= '0; res_spacing <= '0; res_mode <= '0;
            res_edge_sel <= 1'b1; res_max <= '0; res_overflow <= 1'b0;
        end else case (ps)
            P_IDLE: if (prof_done) begin
                r_mode <= cfg_mode; r_edge <= cfg_edge;
                r_hi <= hi; r_lo <= lo; r_floor <= floor_lvl; r_kq <= k_q;
                // Sobel's 1-2-1 weights give 4x the 1-D difference on a clean edge: one setting, both detectors
                r_abs <= cfg_edge ? (thr_abs << 2) : thr_abs;
                r_gap <= (cfg_mode == 2'd1) ? XW'(GAP_RV3) : XW'(GAP_RV4);
                nz_start <= 1'b1;
                ps <= P_NORM;
            end
            P_NORM: if (nz_done) begin
                lt_start <= 1'b1;
                pk_start <= r_mode[1];
                lt_fin <= 1'b0; pick_fin <= !r_mode[1];
                ps <= P_THR;
            end
            P_THR: begin
                if (lt_done) lt_fin <= 1'b1;
                if (pk_done) pick_fin <= 1'b1;
                if ((lt_fin || lt_done) && (pick_fin || pk_done)) begin
                    hy_start <= 1'b1;
                    ps <= P_HYST;
                end
            end
            P_HYST: if (hy_done) begin km_start <= 1'b1; ps <= P_KEYS; end
            P_KEYS: if (km_done) ps <= P_PUB;
            P_PUB: begin
                res_bcount <= km_bcount; res_bounds <= km_bounds; res_kept <= km_kept; res_kcount <= km_kcount;
                res_spacing <= km_spacing; res_lanes_valid <= km_lanes_valid; res_lane_l <= km_l; res_lane_r <= km_r;
                res_mode <= r_mode; res_edge_sel <= r_edge; res_max <= max_val; res_overflow <= hy_ovf && !r_mode[1];
                result_valid <= 1'b1;
                ps <= P_IDLE;
            end
            default: ps <= P_IDLE;
        endcase
    end

    assign boundary_valid = result_valid;
    assign boundary_count = res_bcount;
    assign boundary_x     = res_bounds;
    assign lanes_valid    = res_lanes_valid;

    // ------------------------------------------------------------------ the profile view stream
    // (x, {lo, hi, n}) once per column per result: the normalised profile with the thresholds the picker
    // used -- hi(x)/lo(x) from hysteresis (R-V3/R-V4), the absolute threshold in the same units (R-V1/R-V2)
    logic pw_en; logic [XW-1:0] pw_x; logic [3*NW-1:0] pw_data;
    always_ff @(posedge clk_50) begin
        pw_en   <= hy_dwr && !reset_50;
        pw_x    <= hy_dx;
        pw_data <= r_mode[1] ? {{NW{1'b0}}, thr_n, hy_dn} : {hy_dlo, hy_dhi, hy_dn};
    end

    // ================================================================== debug-view memories (dual clock)
    // The 50 MHz side rewrites these memories every sweep (with the same values unless a switch has
    // just moved). The display reads a location once, when the overlay moves on to it, and then holds
    // the value: a pixel offered to a stalling VGA controller never changes under it.
    logic [3:0] edge_mem [0:W*H-1];
    logic [3:0] edge_q;
    logic [PW-1:0] rb_addr_q;
    always_ff @(posedge clk_50) if (ew_en) edge_mem[ew_addr] <= ew_data;
    always_ff @(posedge clk_25) begin
        rb_addr_q <= rb_addr;
        if (reset_25 || rb_addr != rb_addr_q) edge_q <= edge_mem[rb_addr];
    end

    logic [3*NW-1:0] prof_mem [0:W-1];
    logic [3*NW-1:0] prof_q;
    logic [XW-1:0]   prof_rx, prof_rx_q;
    always_ff @(posedge clk_50) if (pw_en) prof_mem[pw_x] <= pw_data;
    always_ff @(posedge clk_25) begin
        prof_rx_q <= prof_rx;
        if (reset_25 || prof_rx != prof_rx_q) prof_q <= prof_mem[prof_rx];
    end

    // ================================================================== results into the pixel clock
    localparam int RW = CW + NMAX*XW + NMAX + 1 + 8*XW + 2 + 1;
    logic [RW-1:0] bundle_src, bundle_dst; logic vblank, updated, busy;
    assign bundle_src = {res_bcount, res_bounds, res_kept, res_lanes_valid, res_lane_l, res_lane_r, res_mode, res_edge_sel};
    cdc_latch #(.WIDTH(RW)) u_latch (.src_clk(clk_50), .src_valid(result_valid), .src_data(bundle_src), .src_busy(busy),
        .dst_clk(clk_25), .dst_reset(reset_25), .update_ok(vblank), .dst_data(bundle_dst), .dst_updated(updated));
    logic [CW-1:0] d_bcount; logic [NMAX*XW-1:0] d_bounds; logic [NMAX-1:0] d_kept; logic d_lanes_valid;
    logic [4*XW-1:0] d_l, d_r; logic [1:0] d_mode; logic d_edge;
    assign {d_bcount, d_bounds, d_kept, d_lanes_valid, d_l, d_r, d_mode, d_edge} = bundle_dst;

    // ================================================================== 25 MHz: the picture on the monitor
    game_video_overlay #(.H_RES(H_RES), .V_RES(V_RES), .W(W), .H(H), .SH(SH), .NMAX(NMAX), .NW(NW),
                         .GAME_COUNT_W(GAME_COUNT_W), .MASK_Y0(Y0), .MASK_Y1(Y1)) u_overlay (
        .clk(clk_25), .reset(reset_25), .view_sel(view_s),
        .src_addr(rb_addr), .grey(rb_q), .edge4(edge_q), .prof_x(prof_rx), .prof_data(prof_q),
        .res_bcount(d_bcount), .res_bounds(d_bounds), .res_kept(d_kept), .res_lanes_valid(d_lanes_valid),
        .res_lane_l(d_l), .res_lane_r(d_r), .res_mode(d_mode), .res_edge_sel(d_edge),
        .lane_active, .lane_count, .lane_hit_window, .lane_hit_pulse, .score,
        .data(st_data), .startofpacket(st_startofpacket), .endofpacket(st_endofpacket), .valid(st_valid), .ready(st_ready),
        .vblank, .frame_latch);

    // outputs of the blocks above that nothing here needs
    logic unused_ok;
    assign unused_ok = &{1'b0, g_val[12], g_val[3:0], sb_gy, sb_mag[1:0], e_show[3:0], nz_wr, nz_wx, nz_wv,
                         hy_busy, pk_busy, km_busy, res_kcount, res_spacing, res_max, res_overflow,
                         updated, busy};
endmodule
