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
 *                  for FLASH_FRAMES frames; an idle lane has a faint blue tint. The vowel id (0 ee,
 *                  1 ah, 2 oo, 3 aw) is written on each lane, the score top-left (5 decimal digits).
 *    1  edge map   brightness = the selected edge detector's strength (the analysis side writes it)
 *    2  profile    the normalised column profile as yellow bars, the high threshold in red and the low
 *                  one in orange (at R-V4 these are the local-average curves; at R-V1/R-V2 the single
 *                  absolute threshold), and every detected boundary as a vertical line: green when the
 *                  lattice fit kept it, magenta when it was dropped
 *    3  key masks  the four lanes in four colours on a dim picture, boundaries as in view 2
 *  Views 1..3 carry a small readout top-left: mode, edge detector, number of boundaries.
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
    parameter int MASK_Y0      = 150,      // picture rows the lanes are drawn over (the profile's rows:
    parameter int MASK_Y1      = 176,      //  the white keys below the black ones)
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
    logic [19:0]           f_bcd;
    logic [3:0]            hit_seen;
    logic [$clog2(FLASH_FRAMES+1)-1:0] f_flash [0:3];

    always_ff @(posedge clk) begin
        if (reset) begin
            f_view <= '0; f_lanes_valid <= 1'b0; f_bcount <= '0; f_kept <= '0; f_mode <= '0; f_edge <= 1'b1;
            f_active <= '0; f_window <= '0; f_bcd <= '0; hit_seen <= '0;
            for (int i = 0; i < 4; i++) begin f_l[i] <= '0; f_r[i] <= '0; f_count[i] <= '0; f_flash[i] <= '0; end
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
                    if (hit_seen[i] || lane_hit_pulse[i]) f_flash[i] <= ($clog2(FLASH_FRAMES+1))'(FLASH_FRAMES);
                    else if (f_flash[i] != '0)           f_flash[i] <= f_flash[i] - 1'b1;
                end
                for (int i = 0; i < NMAX; i++) f_b[i] <= res_bounds[i*XW +: XW];
            end
        end
    end

    // ------------------------------------------------------------------ what is under the presented pixel
    logic in_rows;
    assign in_rows = (int'(cy) >= MASK_Y0) && (int'(cy) <= MASK_Y1);
    logic [3:0] in_lane;
    always_comb for (int i = 0; i < 4; i++)
        in_lane[i] = f_lanes_valid && in_rows && (cx > f_l[i]) && (cx < f_r[i]);

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
    for (genvar d = 0; d < 5; d++) begin : g_score
        assign score_dot[d] = glyph_on(x, y, SXW'(8 + d * SP), SYW'(8), f_bcd[(4-d)*4 +: 4], SCORE_SH);
    end
    logic in_score_box;
    assign in_score_box = (int'(x) >= 4) && (int'(x) < 12 + 5 * SP) && (int'(y) >= 4) && (int'(y) < 12 + (5 << SCORE_SH));
    // lane labels: the vowel id, centred on each lane, at the bottom of the lit rows
    localparam int LD = 1 << HUD_SH;
    logic [3:0] label_dot;
    for (genvar i = 0; i < 4; i++) begin : g_label
        logic [SXW-1:0] lx;
        assign lx = SXW'(((32'(f_l[i]) + 32'(f_r[i])) << SH) / 2 - (3 * LD) / 2);
        assign label_dot[i] = glyph_on(x, y, lx, SYW'(((MASK_Y1 + 1) << SH) - 7 * LD), 4'(i), HUD_SH);
    end
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
    for (genvar d = 0; d < 4; d++) begin : g_hud
        assign hud_dot[d] = glyph_on(x, y, SXW'(6 + d * 4 * LD + ((d >= 2) ? 2 * LD : 0)), SYW'(6), hud_digit[d], HUD_SH);
    end
    logic in_hud_box;
    assign in_hud_box = (int'(x) >= 2) && (int'(x) < 10 + 18 * LD) && (int'(y) >= 2) && (int'(y) < 10 + 5 * LD);

    // ------------------------------------------------------------------ colour
    function automatic logic [7:0] sat8(input int v);
        return (v > 255) ? 8'd255 : (v < 0) ? 8'd0 : 8'(v);
    endfunction
    logic [7:0] r, g, b;
    always_comb begin
        {r, g, b} = {grey, grey, grey};
        case (f_view)
            2'd0: begin                                               // ---- the game
                for (int i = 0; i < 4; i++) if (in_lane[i]) begin
                    int lvl;
                    lvl = CMAX - int'(f_count[i]);
                    if (f_flash[i] != '0)      begin r = grey >> 2; g = 8'd255; b = grey >> 2; end   // hit
                    else if (f_window[i])      begin r = 8'd255; g = grey >> 3; b = grey >> 3; end   // sing now
                    else if (f_active[i])      begin                                               // note counting down
                        r = sat8(64 + (lvl * 180) / CMAX); g = sat8(40 + (lvl * 150) / CMAX); b = 8'd0;
                    end else                   begin r = grey - (grey >> 3); g = grey - (grey >> 3); end // idle: faint blue
                    if (label_dot[i]) begin r = 8'd0; g = 8'd0; b = 8'd0; end
                end
                if (!f_lanes_valid && (int'(x) >= H_RES - 24) && (int'(y) < 16)) begin r = 8'd255; g = 8'd0; b = 8'd0; end
                if (in_score_box) begin
                    {r, g, b} = {8'd16, 8'd16, 8'd16};
                    if (|score_dot) {r, g, b} = {8'd255, 8'd220, 8'd40};
                end
            end
            2'd1: begin                                               // ---- edge map
                {r, g, b} = {{edge4, edge4}, {edge4, edge4}, {edge4, edge4}};
            end
            2'd2: begin                                               // ---- profile + thresholds
                {r, g, b} = {grey >> 2, grey >> 2, grey >> 2};
                if (on_bound) begin
                    if (on_kept) {r, g, b} = {8'd0, 8'd200, 8'd0};
                    else         {r, g, b} = {8'd200, 8'd0, 8'd200};
                end
                if (on_bar) {r, g, b} = {8'd255, 8'd208, 8'd32};
                if (on_lo)  {r, g, b} = {8'd255, 8'd140, 8'd0};
                if (on_hi)  {r, g, b} = {8'd255, 8'd32, 8'd32};
            end
            default: begin                                            // ---- key masks
                {r, g, b} = {grey >> 3, grey >> 3, grey >> 3};
                if (on_bound) begin
                    if (on_kept) {r, g, b} = {8'd128, 8'd128, 8'd128};
                    else         {r, g, b} = {8'd140, 8'd0, 8'd140};
                end
                if (in_lane[0]) {r, g, b} = {8'd230, 8'd60,  8'd60};
                if (in_lane[1]) {r, g, b} = {8'd60,  8'd200, 8'd60};
                if (in_lane[2]) {r, g, b} = {8'd70,  8'd110, 8'd255};
                if (in_lane[3]) {r, g, b} = {8'd240, 8'd220, 8'd40};
            end
        endcase
        if (f_view != 2'd0 && in_hud_box) begin
            {r, g, b} = {8'd0, 8'd0, 8'd0};
            if (|hud_dot) {r, g, b} = {8'd255, 8'd255, 8'd255};
        end
    end

    assign data          = {r, 2'b00, g, 2'b00, b, 2'b00};
    assign valid         = ~reset;
    assign startofpacket = (x == '0) && (y == '0);
    assign endofpacket   = last_pixel;
    assign vblank        = (x == '0) && (y == '0);
endmodule
