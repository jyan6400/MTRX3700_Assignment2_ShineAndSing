`timescale 1ns/1ps
/*
 *  game_video_overlay.sv -- the VGA picture: the game and the three debug views, as an Avalon-ST video
 *  source for the University Program VGA Controller.  (NEW, Advay; built from Mini-Project 2's
 *  display.sv, which is Lesson 3's vga_face.sv with a picture ROM behind it.)
 *
 *  View (SW2..SW1), latched once per frame:
 *    0  the game   the picture; each of the four lanes (the white keys key_mask_generator chose) is
 *                  lit from the game state: a note darkens its key to amber and brightens it as
 *                  lane_count counts down; the hit window turns the key red; a hit flashes it green
 *                  for FLASH_FRAMES frames; an idle lane has a faint blue tint. The colour fills the
 *                  WHOLE KEY, in its real shape (see "the shape of a key" below). The vowel id (0 ee,
 *                  1 ah, 2 oo, 3 aw) is written on each lane, the score top-left (5 decimal digits).
 *    1  edge map   brightness = the selected edge detector's strength (the analysis side writes it)
 *    2  profile    the normalised column profile as yellow bars, the high threshold in red and the low
 *                  one in orange (at R-V4 these are the local-average curves; at R-V1/R-V2 the single
 *                  absolute threshold), and every detected boundary as a vertical line: green when the
 *                  lattice fit kept it, magenta when it was dropped
 *    3  key masks  the four keys in four colours on a dim picture, boundaries as in view 2
 *  Views 1..3 carry a small readout top-left: mode, edge detector, number of boundaries.
 *
 *  THE SHAPE OF A KEY (KEY_SHAPE = 1). The key finder gives each lane's left and right boundary
 *  (columns); the rest of the key's outline is read here from the picture itself, as it is displayed:
 *    white level   the mean of 8 pixels down the lane's centre column in the middle of the analysed
 *                  rows (MASK_Y0..MASK_Y1 are white key by construction)
 *    "key white"   a pixel at least 5/8 as bright as that level (a black key, the gap between two
 *                  keys and the piano's frame are all far darker; 5/8 leaves room for a lighting
 *                  gradient across the key and for noise)
 *    top, bottom   going down the centre column, the first and last row of the unbroken run of
 *                  key-white pixels that passes through the analysed rows
 *    the key       every key-white pixel between the lane's two boundaries and between top and bottom
 *  So the colour follows the key round the black keys and stops at the gaps and at the key's two ends,
 *  and nothing about the keys is typed in. The white level is measured during one frame and used in
 *  the next, the top and bottom are found during that frame and used in the one after (the picture is
 *  static, so the frames are identical). For the first two frames after the lanes change -- and
 *  whenever no such run is found -- the lane is drawn as before: the plain band of rows
 *  MASK_Y0..MASK_Y1. KEY_SHAPE = 0 keeps the band always.
 *
 *  Clock / reset: the 25 MHz pixel clock, synchronous active-high reset. Everything that comes in
 *  here is already in this clock domain: the analysis results through cdc_latch, the game state
 *  through Jason's game_video_cdc. The frame never shows a mix of two states: every input is copied
 *  into frame registers when the frame's last pixel is accepted, and nothing drawn in a frame reads
 *  the inputs directly.
 *
 *  Avalon-ST, the Lesson 3 rules: a pixel index that advances only on a handshake (valid && ready),
 *  startofpacket on (0,0), endofpacket on the last pixel, valid whenever not in reset.
 *  CHANGE from display.sv (documented): display.sv read its ROM one pixel ahead unconditionally, so
 *  while the controller stalled on an odd x the ROM output moved on to the next picture pixel and the
 *  offered data changed with valid=1 and ready=0 (the monitor model's "held data" rule). Here every
 *  memory is addressed with the pixel that WILL be presented next clock -- the next one on a
 *  handshake, the same one otherwise -- so the data is constant for as long as it is offered.
 *
 *  Memories read from outside (one clock latency, addressed from the same next-pixel address):
 *    src_addr -> grey (picture ROM, port B) and edge4 (edge map);  prof_x -> prof_data {lo, hi, n}.
 *  The picture is W x H; each stored pixel is shown as a 2^SH x 2^SH block (SH = 1: 320x240 -> 640x480).
 */
module game_video_overlay #(
    parameter int H_RES        = assignment2_pkg::VGA_W,   // screen
    parameter int V_RES        = assignment2_pkg::VGA_H,
    parameter int W            = assignment2_pkg::IMG_W,   // source picture
    parameter int H            = assignment2_pkg::IMG_H,
    parameter int SH           = 1,        // screen = picture << SH
    parameter int NMAX         = 32,
    parameter int NW           = 9,
    parameter int GAME_COUNT_W = assignment2_pkg::GAME_COUNT_W,
    parameter int MASK_Y0      = 150,      // the analysed rows (the profile's rows: white keys below the
    parameter int MASK_Y1      = 176,      //  black ones); at least 8 of them
    parameter int KEY_SHAPE    = 1,        // 1: colour the whole key in its real shape; 0: only those rows
    parameter int FLASH_FRAMES = 8,
    parameter int SCORE_SH     = 2,        // score digits: 3x5 dots of 4x4 pixels
    parameter int HUD_SH       = 1         // readout digits in the debug views
) (
    input  logic                       clk,
    input  logic                       reset,
    input  logic [1:0]                 view_sel,
    // memories
    output logic [$clog2(W*H)-1:0]     src_addr,
    input  logic [7:0]                 grey,
    input  logic [3:0]                 edge4,
    output logic [$clog2(W)-1:0]       prof_x,
    input  logic [3*NW-1:0]            prof_data,
    // analysis results (pixel domain, from cdc_latch)
    input  logic [$clog2(NMAX):0]      res_bcount,
    input  logic [NMAX*$clog2(W)-1:0]  res_bounds,
    input  logic [NMAX-1:0]            res_kept,
    input  logic                       res_lanes_valid,
    input  logic [4*$clog2(W)-1:0]     res_lane_l,
    input  logic [4*$clog2(W)-1:0]     res_lane_r,
    input  logic [1:0]                 res_mode,
    input  logic                       res_edge_sel,
    // game state (pixel domain, the frozen Game -> Video contract)
    input  logic [3:0]                 lane_active,
    input  logic [GAME_COUNT_W-1:0]    lane_count [0:3],
    input  logic [3:0]                 lane_hit_window,
    input  logic [3:0]                 lane_hit_pulse,
    input  logic [assignment2_pkg::SCORE_W-1:0] score,
    // Avalon-ST source
    output logic [29:0]                data,
    output logic                       startofpacket,
    output logic                       endofpacket,
    output logic                       valid,
    input  logic                       ready,
    // frame timing
    output logic                       vblank,        // the source is waiting at pixel (0,0)
    output logic                       frame_latch    // pulse: the last pixel was accepted, inputs copied
);
    localparam int XW  = $clog2(W);
    localparam int SXW = $clog2(H_RES);
    localparam int SYW = $clog2(V_RES);
    localparam int CMAX = (1 << GAME_COUNT_W) - 1;
    localparam int GH  = V_RES / 2;                     // profile graph height (screen rows)

    // ==========================================================================
    // LIVE-CHANGE CONFIGURATION -- VGA PRESENTATION
    // --------------------------------------------------------------------------
    // Keep presentation-only changes here.  These constants do NOT alter the
    // detector, lane geometry, game FSM or CDC paths.
    //
    // SW2:SW1 view mapping.  To remap a switch value, change these IDs or the
    // final case statement near "LIVE-CHANGE TARGET: VIEW MUX".
    localparam logic [1:0] VIEW_GAME    = 2'd0;
    localparam logic [1:0] VIEW_EDGE    = 2'd1;
    localparam logic [1:0] VIEW_PROFILE = 2'd2;
    localparam logic [1:0] VIEW_MASKS   = 2'd3;

    // Game-view colours.  RGB is 8 bits/channel before conversion to VGA 10:10:10.
    localparam logic [23:0] RGB_HIT_FLASH   = {8'd64,  8'd255, 8'd64};
    localparam logic [23:0] RGB_HIT_WINDOW  = {8'd255, 8'd32,  8'd32};
    localparam logic [23:0] RGB_LABEL       = {8'd0,   8'd0,   8'd0};
    localparam logic [23:0] RGB_SCORE_BG    = {8'd16,  8'd16,  8'd16};
    localparam logic [23:0] RGB_SCORE_FG    = {8'd255, 8'd220, 8'd40};
    localparam logic [23:0] RGB_NO_LANES    = {8'd255, 8'd0,   8'd0};

    // Profile/debug colours.
    localparam logic [23:0] RGB_BOUND_KEEP  = {8'd0,   8'd200, 8'd0};
    localparam logic [23:0] RGB_BOUND_DROP  = {8'd200, 8'd0,   8'd200};
    localparam logic [23:0] RGB_PROFILE_BAR = {8'd255, 8'd208, 8'd32};
    localparam logic [23:0] RGB_THRESH_LO   = {8'd255, 8'd140, 8'd0};
    localparam logic [23:0] RGB_THRESH_HI   = {8'd255, 8'd32,  8'd32};
    localparam logic [23:0] RGB_HUD_BG      = {8'd0,   8'd0,   8'd0};
    localparam logic [23:0] RGB_HUD_FG      = {8'd255, 8'd255, 8'd255};

    // Key-mask view lane colours -- the easiest Part-B colour-change targets.
    localparam logic [23:0] RGB_MASK_LANE0  = {8'd230, 8'd60,  8'd60};
    localparam logic [23:0] RGB_MASK_LANE1  = {8'd60,  8'd200, 8'd60};
    localparam logic [23:0] RGB_MASK_LANE2  = {8'd70,  8'd110, 8'd255};
    localparam logic [23:0] RGB_MASK_LANE3  = {8'd240, 8'd220, 8'd40};
    localparam logic [23:0] RGB_MASK_KEEP   = {8'd128, 8'd128, 8'd128};
    localparam logic [23:0] RGB_MASK_DROP   = {8'd140, 8'd0,   8'd140};
    // ==========================================================================

    // ------------------------------------------------------------------ raster position
    logic [SXW-1:0] x, nx;
    logic [SYW-1:0] y, ny;
    logic last_pixel, adv;
    assign last_pixel = (int'(x) == H_RES - 1) && (int'(y) == V_RES - 1);
    assign adv        = valid && ready;
    always_comb begin
        if (reset)                      begin nx = '0; ny = '0; end
        else if (!adv)                  begin nx = x;  ny = y;  end
        else if (last_pixel)            begin nx = '0; ny = '0; end
        else if (int'(x) == H_RES - 1)  begin nx = '0; ny = y + 1'b1; end
        else                            begin nx = x + 1'b1; ny = y; end
    end
    always_ff @(posedge clk) begin x <= nx; y <= ny; end

    // every memory is addressed with the pixel presented next clock
    logic [XW-1:0] nsx; logic [$clog2(H)-1:0] nsy;
    assign nsx      = XW'(nx >> SH);
    assign nsy      = ($clog2(H))'(ny >> SH);
    assign src_addr = ($clog2(W*H))'(nsy) * ($clog2(W*H))'(W) + ($clog2(W*H))'(nsx);
    assign prof_x   = nsx;

    // the presented pixel in picture coordinates
    logic [XW-1:0] cx; logic [$clog2(H)-1:0] cy;
    assign cx = XW'(x >> SH);
    assign cy = ($clog2(H))'(y >> SH);

    // ------------------------------------------------------------------ score -> decimal (free running)
    // double dabble, 16 shifts, restarted continuously on the live score; the last finished conversion
    // is copied into the frame registers with everything else
    logic [15:0] dd_bin; logic [19:0] dd_bcd, bcd_done; logic [4:0] dd_step;
    always_ff @(posedge clk) begin
        if (reset) begin dd_step <= '0; bcd_done <= '0; dd_bin <= '0; dd_bcd <= '0; end
        else if (dd_step == 5'd0) begin dd_bin <= 16'(score); dd_bcd <= '0; dd_step <= 5'd1; end
        else begin
            /* verilator lint_off UNUSEDSIGNAL */
            logic [19:0] adj;                            // bit 19 shifts out (score < 100000)
            /* verilator lint_on UNUSEDSIGNAL */
            for (int d = 0; d < 5; d++) adj[d*4 +: 4] = (dd_bcd[d*4 +: 4] >= 4'd5) ? dd_bcd[d*4 +: 4] + 4'd3 : dd_bcd[d*4 +: 4];
            dd_bcd <= {adj[18:0], dd_bin[15]};
            dd_bin <= {dd_bin[14:0], 1'b0};
            if (dd_step == 5'd16) begin bcd_done <= {adj[18:0], dd_bin[15]}; dd_step <= 5'd0; end
            else dd_step <= dd_step + 1'b1;
        end
    end

    // ------------------------------------------------------------------ frame registers
    assign frame_latch = adv && last_pixel;
    logic [1:0]            f_view;
    logic                  f_lanes_valid;
    logic [XW-1:0]         f_l [0:3], f_r [0:3];
    logic [$clog2(NMAX):0] f_bcount;
    logic [XW-1:0]         f_b [0:NMAX-1];
    logic [NMAX-1:0]       f_kept;
    logic [1:0]            f_mode;
    logic                  f_edge;
    logic [3:0]            f_active, f_window;
    logic [GAME_COUNT_W-1:0] f_count [0:3];
    // Precompute countdown colours once per frame, not once per pixel.
    // This moves the multiply/divide logic before the frame registers.
    logic [7:0] f_amber_r [0:3], f_amber_g [0:3];
    logic [19:0]           f_bcd;
    logic [3:0]            hit_seen;
    logic [$clog2(FLASH_FRAMES+1)-1:0] f_flash [0:3];

    always_ff @(posedge clk) begin
        if (reset) begin
            f_view <= '0; f_lanes_valid <= 1'b0; f_bcount <= '0; f_kept <= '0; f_mode <= '0; f_edge <= 1'b1;
            f_active <= '0; f_window <= '0; f_bcd <= '0; hit_seen <= '0;
            for (int i = 0; i < 4; i++) begin f_l[i] <= '0; f_r[i] <= '0; f_count[i] <= '0; f_amber_r[i] <= 8'd0; f_amber_g[i] <= 8'd0; f_flash[i] <= '0; end
            for (int i = 0; i < NMAX; i++) f_b[i] <= '0;
        end else begin
            hit_seen <= frame_latch ? 4'b0 : (hit_seen | lane_hit_pulse);
            if (frame_latch) begin
                f_view <= view_sel; f_lanes_valid <= res_lanes_valid; f_bcount <= res_bcount; f_kept <= res_kept;
                f_mode <= res_mode; f_edge <= res_edge_sel;
                f_active <= lane_active; f_window <= lane_hit_window; f_bcd <= bcd_done;
                for (int i = 0; i < 4; i++) begin
                    f_l[i]     <= res_lane_l[i*XW +: XW];
                    f_r[i]     <= res_lane_r[i*XW +: XW];
                    f_count[i] <= lane_count[i];
                    // Same integer expression as the original pixel combinational logic.
                    // Values are in range 64..244 (R), 40..190 (G): no saturation needed.
                    f_amber_r[i] <= 8'(64 + ((CMAX - int'(lane_count[i])) * 180) / CMAX);
                    f_amber_g[i] <= 8'(40 + ((CMAX - int'(lane_count[i])) * 150) / CMAX);
                    if (hit_seen[i] || lane_hit_pulse[i]) f_flash[i] <= ($clog2(FLASH_FRAMES+1))'(FLASH_FRAMES);
                    else if (f_flash[i] != '0)           f_flash[i] <= f_flash[i] - 1'b1;
                end
                for (int i = 0; i < NMAX; i++) f_b[i] <= res_bounds[i*XW +: XW];
            end
        end
    end

    // ------------------------------------------------------------------ the shape of each lane's key
    localparam int YW     = $clog2(H);
    localparam int YM     = (MASK_Y0 + MASK_Y1) / 2;      // the middle analysed row: certainly white key
    localparam int REF_Y0 = YM - 4;                       // the 8 rows whose mean is the key's white level

    // frame registers: what the frame being drawn uses
    logic [7:0]    f_ref [0:3];                           // white level
    logic [YW-1:0] f_top [0:3], f_bot [0:3];              // first and last row of the key
    logic [3:0]    f_shape;                               // top/bottom were found
    logic [1:0]    f_age;                                 // frames since the lanes last changed, up to 2

    // is the presented pixel "key white" for lane i:  grey >= 5/8 of the lane's white level
    logic [3:0] key_white;
    always_comb for (int i = 0; i < 4; i++)
        key_white[i] = ({grey, 3'b000} >= (11'(f_ref[i]) * 11'd5));

    // measured during the frame, down the centre column of each lane: one sample per picture pixel
    // (the first screen pixel of its 2^SH x 2^SH block), taken when that pixel is accepted
    logic [XW-1:0] lane_c [0:3];
    logic          block_first;
    logic [3:0]    at_c;
    assign block_first = ((int'(x) & ((1 << SH) - 1)) == 0) && ((int'(y) & ((1 << SH) - 1)) == 0);
    always_comb for (int i = 0; i < 4; i++) begin
        lane_c[i] = XW'((32'(f_l[i]) + 32'(f_r[i])) >> 1);
        at_c[i]   = adv && block_first && (cx == lane_c[i]);
    end
    logic [10:0]   m_sum [0:3];                           // sum of the 8 white-level pixels
    logic [3:0]    m_run, m_seen, m_done, m_found;        // in a run / the run reached row YM / finished / found
    logic [YW-1:0] m_start [0:3], m_top [0:3], m_bot [0:3];

    logic lanes_changed;                                  // the result being latched has other lanes
    always_comb begin
        lanes_changed = (res_lanes_valid != f_lanes_valid);
        for (int i = 0; i < 4; i++)
            if ((res_lane_l[i*XW +: XW] != f_l[i]) || (res_lane_r[i*XW +: XW] != f_r[i])) lanes_changed = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            f_age <= '0; f_shape <= '0; m_run <= '0; m_seen <= '0; m_done <= '0; m_found <= '0;
            for (int i = 0; i < 4; i++) begin
                f_ref[i] <= '0; f_top[i] <= '0; f_bot[i] <= '0;
                m_sum[i] <= '0; m_start[i] <= '0; m_top[i] <= '0; m_bot[i] <= '0;
            end
        end else if (frame_latch) begin
            // the frame is complete: its measurements become the next frame's registers
            f_age <= lanes_changed ? 2'd0 : (f_age == 2'd2) ? 2'd2 : f_age + 2'd1;
            for (int i = 0; i < 4; i++) begin
                f_ref[i] <= m_sum[i][10:3];
                if (m_found[i]) begin                                   // the run ended inside the picture
                    f_top[i] <= m_top[i];   f_bot[i] <= m_bot[i];   f_shape[i] <= 1'b1;
                end else if (!m_done[i] && m_seen[i] && m_run[i]) begin // the run reaches the last row
                    f_top[i] <= m_start[i]; f_bot[i] <= YW'(H - 1); f_shape[i] <= 1'b1;
                end else
                    f_shape[i] <= 1'b0;
                m_sum[i] <= '0;
            end
            m_run <= '0; m_seen <= '0; m_done <= '0; m_found <= '0;
        end else begin
            for (int i = 0; i < 4; i++) if (at_c[i]) begin
                if ((int'(cy) >= REF_Y0) && (int'(cy) < REF_Y0 + 8)) m_sum[i] <= m_sum[i] + 11'(grey);
                if (!m_done[i]) begin
                    if (key_white[i]) begin
                        if (!m_run[i]) begin m_start[i] <= cy; m_run[i] <= 1'b1; end
                        if (int'(cy) == YM) m_seen[i] <= 1'b1;
                    end else begin
                        if (m_run[i] && m_seen[i]) begin                // the run through row YM ends here
                            m_top[i] <= m_start[i]; m_bot[i] <= cy - 1'b1; m_found[i] <= 1'b1; m_done[i] <= 1'b1;
                        end else if (int'(cy) == YM)                    // row YM itself is not white: no shape
                            m_done[i] <= 1'b1;
                        m_run[i] <= 1'b0;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------ what is under the presented pixel
    logic in_rows;
    assign in_rows = (int'(cy) >= MASK_Y0) && (int'(cy) <= MASK_Y1);
    logic [3:0] in_lane;
    always_comb for (int i = 0; i < 4; i++) begin
        in_lane[i] = 1'b0;
        if (f_lanes_valid && (cx > f_l[i]) && (cx < f_r[i])) begin
            if ((KEY_SHAPE != 0) && (f_age == 2'd2) && f_shape[i])
                in_lane[i] = (cy >= f_top[i]) && (cy <= f_bot[i]) && key_white[i];     // the key itself
            else
                in_lane[i] = in_rows;                                                    // the plain band
        end
    end

    logic on_bound, on_kept;
    always_comb begin
        on_bound = 1'b0; on_kept = 1'b0;
        for (int i = 0; i < NMAX; i++)
            if ((32'(i) < 32'(f_bcount)) && (f_b[i] == cx)) begin on_bound = 1'b1; on_kept = f_kept[i]; end
    end

    // profile graph: height above the bottom of the screen, and each value's height
    logic [NW-1:0] pn, phi, plo;
    assign {plo, phi, pn} = prof_data;
    function automatic int hgt(input logic [NW-1:0] v);
        int h;
        h = (int'(v) * GH) >> 8;
        return (h > V_RES - 1) ? V_RES - 1 : h;
    endfunction
    int hy, h_n, h_hi, h_lo;
    always_comb begin
        hy   = V_RES - 1 - int'(y);
        h_n  = hgt(pn);
        h_hi = hgt(phi);
        h_lo = hgt(plo);
    end
    // the threshold curves are drawn joined: each column's line runs from its own height to the height
    // of the column on its left, so a steep local-average curve reads as a line, not as dashes
    logic [NW-1:0] prev_hi, prev_lo;
    always_ff @(posedge clk) begin
        if (reset || (adv && (nx == '0)))               begin prev_hi <= '0;  prev_lo <= '0;  end   // new row
        else if (adv && (XW'(nx >> SH) != cx))          begin prev_hi <= phi; prev_lo <= plo; end   // new column
    end
    int hp_hi, hp_lo;
    always_comb begin
        hp_hi = (x == '0) ? h_hi : hgt(prev_hi);
        hp_lo = (x == '0) ? h_lo : hgt(prev_lo);
    end
    function automatic logic between(input int v, input int a, input int b);
        return (v >= ((a < b) ? a : b) - 1) && (v <= ((a > b) ? a : b) + 1);
    endfunction
    logic on_bar, on_hi, on_lo;
    assign on_bar = (hy < h_n);
    assign on_hi  = between(hy, h_hi, hp_hi);
    assign on_lo  = (plo != '0) && between(hy, h_lo, hp_lo);

    // ------------------------------------------------------------------ text
    // A 3 x 5 dot font for the decimal digits (5 rows of 3 dots, top row first; in each row the left
    // dot is the high bit). Everything written on the screen is a decimal digit: the score, the vowel
    // id on each lane and the debug readout.
    function automatic logic [14:0] font(input logic [3:0] d);
        case (d)
            4'd0: return 15'b111_101_101_101_111;
            4'd1: return 15'b010_110_010_010_111;
            4'd2: return 15'b111_001_111_100_111;
            4'd3: return 15'b111_001_111_001_111;
            4'd4: return 15'b101_101_111_001_001;
            4'd5: return 15'b111_100_111_001_111;
            4'd6: return 15'b111_100_111_101_111;
            4'd7: return 15'b111_001_001_001_001;
            4'd8: return 15'b111_101_111_101_111;
            4'd9: return 15'b111_101_111_001_111;
            default: return 15'd0;                           // not a decimal digit: nothing drawn
        endcase
    endfunction
    // Is screen pixel (px, py) a lit dot of `digit` drawn with its top-left corner at (x0, y0), each
    // font dot being 2^sh x 2^sh pixels? (dx, dy are one bit wider: their top bit is set when the pixel
    // is left of / above the glyph.)
    function automatic logic glyph_on(input logic [SXW-1:0] px, input logic [SYW-1:0] py,
                                      input logic [SXW-1:0] x0, input logic [SYW-1:0] y0,
                                      input logic [3:0] digit, input int sh);
        logic [SXW:0] dx, col; logic [SYW:0] dy, row; logic [14:0] f;
        dx  = {1'b0, px} - {1'b0, x0};
        dy  = {1'b0, py} - {1'b0, y0};
        col = dx >> sh;
        row = dy >> sh;
        f   = font(digit);
        if (!dx[SXW] && !dy[SYW] && col < 3 && row < 5) return f[14 - (3 * int'(row) + int'(col))];
        return 1'b0;
    endfunction

    // score: 5 digits at (8, 8) in the game view, on a dark box
    localparam int SP = 4 << SCORE_SH;                    // digit pitch
    logic [4:0] score_dot;
    genvar d_score;
    generate
        for (d_score = 0; d_score < 5; d_score = d_score + 1) begin : g_score
            assign score_dot[d_score] = glyph_on(
                x,
                y,
                SXW'(8 + d_score * SP),
                SYW'(8),
                f_bcd[(4-d_score)*4 +: 4],
                SCORE_SH
            );
        end
    endgenerate
    logic in_score_box;
    assign in_score_box = (int'(x) >= 4) && (int'(x) < 12 + 5 * SP) && (int'(y) >= 4) && (int'(y) < 12 + (5 << SCORE_SH));
    // lane labels: the vowel id, centred on each lane, at the bottom of the lit rows
    localparam int LD = 1 << HUD_SH;
    logic [3:0] label_dot;
    genvar i_label;
    generate
        for (i_label = 0; i_label < 4; i_label = i_label + 1) begin : g_label
            logic [SXW-1:0] lx;
            assign lx = SXW'(((32'(f_l[i_label]) + 32'(f_r[i_label])) << SH) / 2 - (3 * LD) / 2);
            assign label_dot[i_label] = glyph_on(
                x,
                y,
                lx,
                SYW'(((MASK_Y1 + 1) << SH) - 7 * LD),
                4'(i_label),
                HUD_SH
            );
        end
    endgenerate
    // readout in the debug views: mode, edge detector, boundaries (decimal)
    logic [3:0] bc_tens, bc_ones;
    assign bc_tens = 4'(32'(f_bcount) / 10);
    assign bc_ones = 4'(32'(f_bcount) % 10);
    logic [3:0] hud_dot;
    logic [3:0] hud_digit [0:3];
    assign hud_digit[0] = {2'b00, f_mode};
    assign hud_digit[1] = {3'b000, f_edge};
    assign hud_digit[2] = bc_tens;
    assign hud_digit[3] = bc_ones;
    genvar d_hud;
    generate
        for (d_hud = 0; d_hud < 4; d_hud = d_hud + 1) begin : g_hud
            assign hud_dot[d_hud] = glyph_on(
                x,
                y,
                SXW'(6 + d_hud * 4 * LD + ((d_hud >= 2) ? 2 * LD : 0)),
                SYW'(6),
                hud_digit[d_hud],
                HUD_SH
            );
        end
    endgenerate
    logic in_hud_box;
    assign in_hud_box = (int'(x) >= 2) && (int'(x) < 10 + 18 * LD) && (int'(y) >= 2) && (int'(y) < 10 + 5 * LD);

    // ==========================================================================
    // LIVE-CHANGE TARGET: VIEW RENDERING / COLOURS
    // --------------------------------------------------------------------------
    // All four display modes are intentionally kept together here so a live
    // change to a view or colour can be found from one heading.  The algorithmic
    // state above is read-only from this point onward.
    function automatic logic [7:0] sat8(input int v);
        return (v > 255) ? 8'd255 : (v < 0) ? 8'd0 : 8'(v);
    endfunction

    logic [7:0] r, g, b;
    always_comb begin
        // Default: untouched greyscale source picture.
        {r, g, b} = {grey, grey, grey};

        // ======================================================================
        // LIVE-CHANGE TARGET: VIEW MUX (SW2:SW1)
        // ======================================================================
        case (f_view)
            VIEW_GAME: begin
                // --------------------------------------------------------------
                // LIVE-CHANGE TARGET: GAME VIEW
                // --------------------------------------------------------------
                for (int i = 0; i < 4; i++) if (in_lane[i]) begin
                    if (f_flash[i] != '0) begin
                        // Keep the original behaviour: green channel fixed high,
                        // red/blue retain one quarter of source brightness.
                        r = grey >> 2;
                        g = RGB_HIT_FLASH[15:8];
                        b = grey >> 2;
                    end else if (f_window[i]) begin
                        // Hit window: red with a little source-dependent G/B.
                        r = RGB_HIT_WINDOW[23:16];
                        g = grey >> 3;
                        b = grey >> 3;
                    end else if (f_active[i]) begin
                        // Countdown: amber gets brighter as count approaches zero.
                        r = f_amber_r[i];
                        g = f_amber_g[i];
                        b = 8'd0;
                    end else begin
                        // Idle lane: retain the original faint blue tint by
                        // reducing R/G while leaving B at source brightness.
                        r = grey - (grey >> 3);
                        g = grey - (grey >> 3);
                    end

                    if (label_dot[i]) {r, g, b} = RGB_LABEL;
                end

                if (!f_lanes_valid && (int'(x) >= H_RES - 24) && (int'(y) < 16))
                    {r, g, b} = RGB_NO_LANES;

                if (in_score_box) begin
                    {r, g, b} = RGB_SCORE_BG;
                    if (|score_dot) {r, g, b} = RGB_SCORE_FG;
                end
            end

            VIEW_EDGE: begin
                // --------------------------------------------------------------
                // LIVE-CHANGE TARGET: EDGE VIEW
                // --------------------------------------------------------------
                // 4-bit edge strength expanded to 8 bits for monochrome display.
                {r, g, b} = {{edge4, edge4}, {edge4, edge4}, {edge4, edge4}};
            end

            VIEW_PROFILE: begin
                // --------------------------------------------------------------
                // LIVE-CHANGE TARGET: PROFILE + THRESHOLD VIEW
                // --------------------------------------------------------------
                {r, g, b} = {grey >> 2, grey >> 2, grey >> 2};
                if (on_bound) begin
                    if (on_kept) {r, g, b} = RGB_BOUND_KEEP;
                    else         {r, g, b} = RGB_BOUND_DROP;
                end
                if (on_bar) {r, g, b} = RGB_PROFILE_BAR;
                if (on_lo)  {r, g, b} = RGB_THRESH_LO;
                if (on_hi)  {r, g, b} = RGB_THRESH_HI;
            end

            VIEW_MASKS: begin
                // --------------------------------------------------------------
                // LIVE-CHANGE TARGET: KEY-MASK VIEW / LANE COLOURS
                // --------------------------------------------------------------
                {r, g, b} = {grey >> 3, grey >> 3, grey >> 3};
                if (on_bound) begin
                    if (on_kept) {r, g, b} = RGB_MASK_KEEP;
                    else         {r, g, b} = RGB_MASK_DROP;
                end
                if (in_lane[0]) {r, g, b} = RGB_MASK_LANE0;
                if (in_lane[1]) {r, g, b} = RGB_MASK_LANE1;
                if (in_lane[2]) {r, g, b} = RGB_MASK_LANE2;
                if (in_lane[3]) {r, g, b} = RGB_MASK_LANE3;
            end

            default: begin
                // Defensive fallback if f_view is ever X/out of range in sim.
                {r, g, b} = {grey, grey, grey};
            end
        endcase

        // Common debug HUD for every non-game view.
        if ((f_view != VIEW_GAME) && in_hud_box) begin
            {r, g, b} = RGB_HUD_BG;
            if (|hud_dot) {r, g, b} = RGB_HUD_FG;
        end
    end

    assign data          = {r, 2'b00, g, 2'b00, b, 2'b00};
    assign valid         = ~reset;
    assign startofpacket = (x == '0) && (y == '0);
    assign endofpacket   = last_pixel;
    assign vblank        = (x == '0) && (y == '0);
endmodule
