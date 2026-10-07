`timescale 1ns/1ps
/*
 *  game_video_overlay_tb.sv -- the VGA source on its own, at a small size (a 64x48 picture pixel-doubled
 *  to 128x96), driven by mocked analysis results and a mocked game (no game RTL needed), into the
 *  Lesson 3 VGA monitor model with 20 % random back-pressure. Checked on every frame:
 *
 *    protocol    the monitor model's rules: startofpacket on (0,0), endofpacket on the last pixel, data
 *                held while valid && !ready (the random stalls hit odd pixels: display.sv's one-ahead
 *                read would fail here), no missing pixels; vblank only while presenting pixel (0,0)
 *    game view   each lane's colour from the game state latched at the previous frame's end:
 *                idle tint, a note's amber brightening with lane_count, red in the hit window, green for
 *                FLASH_FRAMES frames after a hit pulse; the picture untouched outside the lanes; the
 *                "no keys" marker when lanes_valid = 0
 *    key shape   the mocked picture is a small keyboard (white keys, dark gaps, black keys over some
 *                gaps, a dark frame above and below, one bright patch in the frame). The bench works
 *                out each lane's key itself -- white level, top and bottom down the centre column, the
 *                5/8 rule -- and checks that the colour is on the key and nowhere else: beside a black
 *                key yes, on the black key no, below the analysed rows yes, on the gap, in the frame and
 *                on the bright patch above the key no. For the first two frames after the lanes change
 *                the plain band of analysed rows must be drawn instead.
 *    digits      the overlay's own 3x5 dot font: every pixel of every dot of the 5-digit score, with
 *                scores that between them show all ten digits; the vowel id written on each lane; the
 *                readout digits in the debug views
 *    mid-frame   the game state and the view are changed in the middle of a frame: that frame must show
 *                none of it, the next one all of it
 *    edge view   every probed pixel = the edge map value, replicated to 8 bits
 *    profile     the bar, the high and low threshold lines and the kept/dropped boundary lines
 *    masks       the four lane colours and the boundary lines
 *    reset       a reset in the middle of a frame: the source restarts cleanly at (0,0)
 *  Every expected value is computed by the bench (its own font, colour rules and memories).
 */
module game_video_overlay_tb;
    localparam int W = 64, H = 48, SH = 1, H_RES = W << SH, V_RES = H << SH, NMAX = 8, NW = 9, XW = 6;
    localparam int MY0 = 20, MY1 = 35, FLASH = 3, CW = 4, CMAX = 15, GH = V_RES / 2;
    logic clk = 0; always #20 clk = ~clk;
    logic reset = 1;

    // ---- mocked memories (one clock of read latency, like the M10Ks) ----
    // the picture: a small keyboard. Rows 6..41 are keys (white 200..215, a dark gap every 8 columns,
    // black keys in rows 6..18 two columns either side of the gaps at 16, 32 and 48); rows 0..5 and
    // 42..47 are the dark frame. Three things to catch a wrong outline: a bright patch in the frame above
    // lane 3's key (columns 46..47, rows 1..3), one touching the bottom of that key (columns 41..42, rows
    // 42..44), and a mid-grey smudge on lane 2's key (columns 38..39, rows 36..38: under 5/8 of white).
    function automatic bit black_at(int sx);
        int m, gcol;
        m = sx % 8;
        if (m >= 1 && m <= 2)      gcol = sx - m;
        else if (m >= 6)           gcol = sx + 8 - m;
        else                       return 0;
        return (gcol == 16) || (gcol == 32) || (gcol == 48);
    endfunction
    function automatic int grey_at(int sx, int sy);
        if (sy < 6)                    return (sx >= 46 && sx <= 47 && sy >= 1 && sy <= 3) ? 250 : 20 + ((sx + sy) & 7);
        if (sy > 41)                   return (sx >= 41 && sx <= 42 && sy <= 44) ? 250 : 30 + ((sx * 3 + sy) & 7);
        if (sx % 8 == 0)               return 40;
        if (sx >= 38 && sx <= 39 && sy >= 36 && sy <= 38) return 100;
        if (sy <= 18 && black_at(sx))  return 12 + (sy & 3);
        return 200 + ((sx * 3 + sy * 5) & 15);
    endfunction
    function automatic int edge_at(int sx, int sy);   return (sx ^ sy) & 15; endfunction
    function automatic int n_at(int sx);              return (sx * 7) % 200; endfunction
    function automatic int hi_at(int sx);             return 150 + (sx % 5); endfunction
    function automatic int lo_at(int sx);             return 60; endfunction
    logic [$clog2(W*H)-1:0] src_addr; logic [7:0] grey; logic [3:0] edge4; logic [XW-1:0] prof_x; logic [3*NW-1:0] prof_data;
    always_ff @(posedge clk) begin
        grey      <= 8'(grey_at(int'(src_addr) % W, int'(src_addr) / W));
        edge4     <= 4'(edge_at(int'(src_addr) % W, int'(src_addr) / W));
        prof_data <= {NW'(lo_at(prof_x)), NW'(hi_at(prof_x)), NW'(n_at(prof_x))};
    end

    // ---- mocked analysis results: boundaries every 8 columns, one dropped, lanes = keys 1..4 ----
    int bl [7] = '{8, 16, 24, 28, 32, 40, 48};             // 28 is off the lattice
    logic [3:0] res_bcount = 7; logic [NMAX*XW-1:0] res_bounds; logic [NMAX-1:0] res_kept = 8'b111_0111;
    logic res_lanes_valid = 0; logic [4*XW-1:0] res_lane_l, res_lane_r; logic [1:0] res_mode = 0; logic res_edge_sel = 1;
    int ll [4] = '{16, 24, 32, 40}, lr [4] = '{24, 32, 40, 48};
    initial begin
        res_bounds = '0;
        for (int i = 0; i < 7; i++) res_bounds[i*XW +: XW] = XW'(bl[i]);
        for (int i = 0; i < 4; i++) begin res_lane_l[i*XW +: XW] = XW'(ll[i]); res_lane_r[i*XW +: XW] = XW'(lr[i]); end
    end

    // ---- mocked game ----
    logic [1:0] view_sel = 0;
    logic [3:0] lane_active = 0, lane_hit_window = 0, lane_hit_pulse = 0; logic [CW-1:0] lane_count [0:3]; logic [15:0] score = 0;
    initial for (int i = 0; i < 4; i++) lane_count[i] = '0;

    logic [29:0] data; logic sop, eop, valid, ready, vblank, frame_latch;
    game_video_overlay #(.H_RES(H_RES), .V_RES(V_RES), .W(W), .H(H), .SH(SH), .NMAX(NMAX), .NW(NW), .GAME_COUNT_W(CW),
                         .MASK_Y0(MY0), .MASK_Y1(MY1), .FLASH_FRAMES(FLASH)) dut (
        .clk, .reset, .view_sel, .src_addr, .grey, .edge4, .prof_x, .prof_data,
        .res_bcount(4'(res_bcount)), .res_bounds, .res_kept, .res_lanes_valid, .res_lane_l, .res_lane_r, .res_mode, .res_edge_sel,
        .lane_active, .lane_count, .lane_hit_window, .lane_hit_pulse, .score,
        .data, .startofpacket(sop), .endofpacket(eop), .valid, .ready, .vblank, .frame_latch);
    int frames_done, errors, x_pos, y_pos; logic accept, discard;
    vga_monitor_model #(.H_RES(H_RES), .V_RES(V_RES), .H_BLANK(H_RES/4), .V_BLANK(V_RES/10), .RANDOM_STALL_PCT(20),
                        .ASCII_ART(0), .PPM_PREFIX(""), .VERBOSE(0)) mon (
        .clk, .reset, .data, .startofpacket(sop), .endofpacket(eop), .valid, .ready,
        .frames_done, .errors, .x_pos, .y_pos, .accept, .discard);

    // ---- capture what the monitor shows ----
    logic [23:0] cap [0:V_RES-1][0:H_RES-1];
    always @(posedge clk) if (accept) cap[y_pos][x_pos] <= {data[29:22], data[19:12], data[9:2]};
    always @(posedge clk) if (!reset && vblank != sop) $fatal(1, "FAIL: vblank must mean 'presenting pixel (0,0)'");

    // ---- the bench's model of the frame registers: a snapshot at every frame_latch ----
    typedef struct { int view; bit lanes; int age; bit active [4]; bit window [4]; int count [4]; int flash [4]; int score; } snap_t;
    snap_t cur, snaps[$];
    bit hit_seen [4];
    bit lanes_loaded;                 // the lane positions have been latched since the reset
    task automatic reset_model();
        cur.view = 0; cur.lanes = 0; cur.score = 0; cur.age = 0; lanes_loaded = 0;
        for (int i = 0; i < 4; i++) begin cur.active[i] = 0; cur.window[i] = 0; cur.count[i] = 0; cur.flash[i] = 0; hit_seen[i] = 0; end
        snaps.delete(); snaps.push_back(cur);
    endtask
    always @(posedge clk) if (!reset) begin
        if (frame_latch) begin
            // frames since the lanes last changed (the positions themselves change once, after a reset)
            if ((res_lanes_valid != cur.lanes) || !lanes_loaded) cur.age = 0;
            else if (cur.age < 2) cur.age++;
            lanes_loaded = 1;
            cur.view = int'(view_sel); cur.lanes = res_lanes_valid; cur.score = int'(score);
            for (int i = 0; i < 4; i++) begin
                cur.active[i] = lane_active[i]; cur.window[i] = lane_hit_window[i]; cur.count[i] = int'(lane_count[i]);
                if (hit_seen[i] || lane_hit_pulse[i]) cur.flash[i] = FLASH; else if (cur.flash[i] > 0) cur.flash[i]--;
                hit_seen[i] = 0;
            end
            snaps.push_back(cur);
        end else for (int i = 0; i < 4; i++) if (lane_hit_pulse[i]) hit_seen[i] = 1;
    end

    // ---- expected colours ----
    // the 3x5 font drawn as rows, top to bottom ('#' lit), digits 0..9
    string font [10] = '{ "####.##.##.####", ".#.##..#..#.###", "###..#####..###", "###..####..####",
                          "#.##.####..#..#", "####..###..####", "####..####.####", "###..#..#..#..#",
                          "####.#####.####", "####.####..####" };
    function automatic logic [23:0] rgb(int r, int g, int b); return {8'(r), 8'(g), 8'(b)}; endfunction
    function automatic int sat8(int v); return (v > 255) ? 255 : (v < 0) ? 0 : v; endfunction

    // ---- the bench's own idea of each lane's key ----
    localparam int YM = (MY0 + MY1) / 2;
    int k_ref [4], k_top [4], k_bot [4]; bit k_ok [4];
    function automatic bit white_for(int i, int sx, int sy); return grey_at(sx, sy) * 8 >= k_ref[i] * 5; endfunction
    task automatic find_keys();
        for (int i = 0; i < 4; i++) begin
            int c, sum, start; bit run, seen, fin;
            c = (ll[i] + lr[i]) / 2; sum = 0;
            for (int yy = YM - 4; yy < YM + 4; yy++) sum += grey_at(c, yy);
            k_ref[i] = sum / 8;
            run = 0; seen = 0; fin = 0; start = 0; k_ok[i] = 0;
            for (int yy = 0; yy < H && !fin; yy++) begin
                if (white_for(i, c, yy)) begin
                    if (!run) begin start = yy; run = 1; end
                    if (yy == YM) seen = 1;
                end else begin
                    if (run && seen) begin k_top[i] = start; k_bot[i] = yy - 1; k_ok[i] = 1; fin = 1; end
                    else if (yy == YM) fin = 1;
                    run = 0;
                end
            end
            if (!fin && run && seen) begin k_top[i] = start; k_bot[i] = H - 1; k_ok[i] = 1; end
        end
    endtask
    // is picture pixel (sx, sy) drawn as lane i in a frame with snapshot s?
    function automatic bit in_key(snap_t s, int i, int sx, int sy);
        if (!s.lanes || sx <= ll[i] || sx >= lr[i]) return 0;
        if (s.age == 2 && k_ok[i]) return (sy >= k_top[i]) && (sy <= k_bot[i]) && white_for(i, sx, sy);
        return (sy >= MY0) && (sy <= MY1);
    endfunction
    // the colour of picture pixel (sx, sy) in the game view (away from the score, labels and marker)
    function automatic logic [23:0] game_px(snap_t s, int sx, int sy);
        int gr, lvl;
        gr = grey_at(sx, sy);
        for (int i = 0; i < 4; i++) if (in_key(s, i, sx, sy)) begin
            if (s.flash[i] > 0)   return rgb(gr >> 2, 255, gr >> 2);
            if (s.window[i])      return rgb(255, gr >> 3, gr >> 3);
            if (s.active[i]) begin lvl = CMAX - s.count[i]; return rgb(sat8(64 + lvl * 180 / CMAX), sat8(40 + lvl * 150 / CMAX), 0); end
            return rgb(gr - (gr >> 3), gr - (gr >> 3), gr);
        end
        return rgb(gr, gr, gr);
    endfunction

    int nfail = 0;
    task automatic expect_px(input int x, input int y, input logic [23:0] want, input string what);
        if (cap[y][x] !== want)
            $fatal(1, "FAIL frame %0d (view %0d) %s at (%0d,%0d): %06h, expected %06h", frames_done, snaps[0].view, what, x, y, cap[y][x], want);
    endtask
    function automatic int hgt(int v); int h; h = (v * GH) >> 8; return (h > V_RES - 1) ? V_RES - 1 : h; endfunction

    task automatic check_frame(input snap_t s);
        int sy;
        sy = MY0 + 1;                                     // the top row of the lanes: away from the labels
        case (s.view)
            0: begin
                for (int i = 0; i < 4; i++) begin
                    int c; int px [12][2];
                    c = (ll[i] + lr[i]) / 2;
                    px[0] = '{c, sy};               // the analysed rows, centre of the key
                    px[1] = '{ll[i] + 3, sy};       // the analysed rows, towards the left edge
                    px[2] = '{c, 17};               // beside a black key: key when the shape is drawn
                    px[3] = '{ll[i] + 1, 17};       // lanes 0 and 2: on the black key itself
                    px[4] = '{lr[i] - 1, 17};       // lanes 1 and 3: on the black key itself
                    px[5] = '{c, 39};               // below the analysed rows, still on the key
                    px[6] = '{c, 44};               // the frame under the keys
                    px[7] = '{ll[i], sy};           // the gap on the lane's left boundary
                    px[8] = '{46, 2};               // the bright patch above lane 3's key
                    px[9] = '{41, 42};              // the bright patch touching the bottom of lane 3's key
                    px[10] = '{38, 37};             // the mid-grey smudge on lane 2's key: not key white
                    px[11] = '{37, 37};             //  ... and the white pixel next to it
                    foreach (px[k]) begin
                        expect_px(px[k][0] << SH, px[k][1] << SH, game_px(s, px[k][0], px[k][1]), $sformatf("lane %0d, probe %0d (age %0d)", i, k, s.age));
                        expect_px((px[k][0] << SH) + 1, (px[k][1] << SH) + 1, game_px(s, px[k][0], px[k][1]), $sformatf("lane %0d, probe %0d (2x2 block)", i, k));
                    end
                    // the model itself must say what the picture was built to show
                    if (s.lanes && s.age == 2) begin
                        if (!in_key(s, i, c, 17) || !in_key(s, i, c, 39) || in_key(s, i, c, 44) || in_key(s, i, c, 5))
                            $fatal(1, "FAIL: bench key model, lane %0d: top %0d bottom %0d", i, k_top[i], k_bot[i]);
                        if (in_key(s, i, (i % 2 == 0) ? ll[i] + 1 : lr[i] - 1, 17)) $fatal(1, "FAIL: bench key model colours a black key");
                        if (in_key(s, 3, 46, 2) || in_key(s, 3, 41, 42)) $fatal(1, "FAIL: bench key model colours a patch outside the key");
                        if (in_key(s, 2, 38, 37) || !in_key(s, 2, 37, 37)) $fatal(1, "FAIL: bench key model and the mid-grey smudge");
                    end
                end
                begin int sx; sx = ll[0] + 2; expect_px(sx << SH, (MY0 - 3) << SH, rgb(grey_at(sx, MY0 - 3), grey_at(sx, MY0 - 3), grey_at(sx, MY0 - 3)), "picture above the lanes"); end
                expect_px(H_RES - 2, 2, s.lanes ? rgb(grey_at((H_RES - 2) >> SH, 1), grey_at((H_RES - 2) >> SH, 1), grey_at((H_RES - 2) >> SH, 1)) : rgb(255, 0, 0), "no-keys marker");
                for (int d = 0; d < 5; d++) begin
                    int digit, p10; p10 = 1; for (int k = 0; k < 4 - d; k++) p10 *= 10;
                    digit = (s.score / p10) % 10;
                    // every pixel of every 4x4 dot, and the dark column between two digits
                    for (int r = 0; r < 5; r++) for (int c = 0; c < 3; c++) for (int oy = 0; oy < 4; oy++) for (int ox = 0; ox < 4; ox++)
                        expect_px(8 + d * 16 + c * 4 + ox, 8 + r * 4 + oy,
                                  (font[digit].getc(3 * r + c) == "#") ? rgb(255, 220, 40) : rgb(16, 16, 16),
                                  $sformatf("score digit %0d (%0d)", d, digit));
                    for (int oy = 0; oy < 20; oy++) expect_px(8 + d * 16 + 13, 8 + oy, rgb(16, 16, 16), "gap between score digits");
                end
                // the vowel id on each lane: lit dots are black, the rest keeps the lane's colour
                if (s.lanes) for (int i = 0; i < 4; i++) for (int r = 0; r < 5; r++) for (int c = 0; c < 3; c++) begin
                    int lx, ly;
                    lx = ((ll[i] + lr[i]) << SH) / 2 - 3 + c * 2; ly = ((MY1 + 1) << SH) - 14 + r * 2;
                    if (font[i].getc(3 * r + c) == "#") expect_px(lx, ly, rgb(0, 0, 0), $sformatf("lane %0d label", i));
                    else if (cap[ly][lx] === 24'h000000) $fatal(1, "FAIL frame %0d: lane %0d label has a dot at row %0d col %0d that the font does not", frames_done, i, r, c);
                end
            end
            1: for (int k = 0; k < 40; k++) begin
                   int sx, syy, e;
                   sx = 24 + (k * 7) % 38; syy = 12 + (k * 5) % 34; e = edge_at(sx, syy);
                   expect_px(sx << SH, syy << SH, rgb(e * 17, e * 17, e * 17), "edge map");
               end
            2: begin
                for (int sx = 30; sx < 62; sx += 3) begin
                    int hn, hh, hl;
                    hn = hgt(n_at(sx)); hh = hgt(hi_at(sx)); hl = hgt(lo_at(sx));
                    if (hn > 0 && hl > 1 && hh > 1) expect_px(sx << SH, V_RES - 1, rgb(255, 208, 32), $sformatf("profile bar, column %0d", sx));
                    expect_px(sx << SH, V_RES - 1 - hh, rgb(255, 32, 32), $sformatf("high threshold, column %0d", sx));
                    if (hl + 1 < hh - 1) expect_px(sx << SH, V_RES - 1 - hl, rgb(255, 140, 0), $sformatf("low threshold, column %0d", sx));
                end
                expect_px(40 << SH, 26, rgb(0, 200, 0), "kept boundary line");
                expect_px(28 << SH, 26, rgb(200, 0, 200), "dropped boundary line");
            end
            default: begin
                logic [23:0] lc [4];
                lc[0] = rgb(230, 60, 60); lc[1] = rgb(60, 200, 60); lc[2] = rgb(70, 110, 255); lc[3] = rgb(240, 220, 40);
                for (int i = 0; i < 4; i++) begin
                    int c, mx [4][2];
                    c = (ll[i] + lr[i]) / 2 + 1;                 // (one column off the centre: column 28 is a boundary line)
                    mx[0] = '{ll[i] + 3, sy}; mx[1] = '{c, 39}; mx[2] = '{c, 44}; mx[3] = '{(i % 2 == 0) ? ll[i] + 1 : lr[i] - 1, 17};
                    foreach (mx[k]) begin
                        int gr; gr = grey_at(mx[k][0], mx[k][1]) >> 3;
                        expect_px(mx[k][0] << SH, mx[k][1] << SH, in_key(s, i, mx[k][0], mx[k][1]) ? lc[i] : rgb(gr, gr, gr), $sformatf("mask %0d, probe %0d (age %0d)", i, k, s.age));
                    end
                end
                expect_px(8 << SH, 90, rgb(128, 128, 128), "kept boundary in the mask view");          // row 45: the frame,
                expect_px(28 << SH, 90, rgb(140, 0, 140), "dropped boundary in the mask view");        //  below every key
            end
        endcase
        if (s.view != 0) begin                            // readout: mode digit (0) at (6,6), dots of 2x2
            for (int r = 0; r < 5; r++) for (int c = 0; c < 3; c++)
                expect_px(6 + c * 2, 6 + r * 2, (font[0].getc(3 * r + c) == "#") ? rgb(255, 255, 255) : rgb(0, 0, 0), "readout mode digit");
        end
    endtask

    // ---- the frame loop: every completed frame is checked against its snapshot ----
    int base = 0, checked = 0;
    always @(posedge clk) if (!reset && frames_done > base) begin
        snap_t s;
        base = frames_done;
        if (snaps.size() == 0) $fatal(1, "FAIL: a frame completed without a snapshot");
        s = snaps.pop_front();
        #1 check_frame(s);
        checked++;
    end

    // the mocked inputs change on the falling edge, never on the edge the overlay samples them
    task automatic next_frame(); @(posedge clk iff frame_latch); @(negedge clk); endtask
    task automatic mid_frame();  wait (y_pos == V_RES / 2); @(negedge clk); endtask

    initial begin
        find_keys();
        for (int i = 0; i < 4; i++) begin
            if (!k_ok[i] || k_top[i] != 6 || k_bot[i] != 41) $fatal(1, "FAIL: bench key model, lane %0d: ok %0d top %0d bottom %0d", i, k_ok[i], k_top[i], k_bot[i]);
        end
        reset_model();
        repeat (5) @(posedge clk); reset = 0;
        next_frame();                                           // frame 1: plain picture, no lanes
        res_lanes_valid = 1;
        next_frame();
        // idle lanes, a score
        score = 16'd12345; mid_frame(); next_frame();
        score = 16'd6789;  mid_frame(); next_frame();            // "06789": with 12345, all ten digits
        // notes counting down on lanes 1 and 2, a hit window on lane 0; lane 3 idle
        lane_active = 4'b0110; lane_count[1] = 15; lane_count[2] = 4; lane_hit_window = 4'b0001;
        mid_frame(); next_frame();
        // change everything in the middle of the frame: that frame must not show it
        mid_frame(); lane_count[1] = 0; lane_count[2] = 9; lane_hit_window = 4'b0000; lane_active = 4'b1110; score = 16'd99;
        view_sel = 0; next_frame();
        // a hit on lane 3 (single-clock pulse, mid-frame): green for FLASH frames
        mid_frame(); @(negedge clk); lane_hit_pulse = 4'b1000; @(negedge clk); lane_hit_pulse = 0; score = 16'd100;
        repeat (FLASH + 2) next_frame();
        // the debug views
        view_sel = 1; mid_frame(); next_frame(); next_frame();
        view_sel = 2; mid_frame(); next_frame(); next_frame();
        view_sel = 3; mid_frame(); next_frame(); next_frame();
        res_lanes_valid = 0; next_frame(); next_frame();          // masks disappear
        view_sel = 0; next_frame(); next_frame();                  // "no keys" marker
        res_lanes_valid = 1;
        // reset in the middle of a frame
        mid_frame(); @(negedge clk); reset = 1; repeat (3) @(negedge clk);
        reset_model(); base = frames_done; reset = 0;
        repeat (3) next_frame();
        repeat (2) @(posedge clk iff frames_done > base);
        if (errors != 0) $fatal(1, "FAIL: the monitor model counted %0d protocol errors", errors);
        if (checked < 20) $fatal(1, "FAIL: only %0d frames checked", checked);
        $display("PASS: %0d frames checked (game, edge, profile, mask views; mid-frame changes; hit flash; reset), 0 protocol errors with 20 %% stalls", checked);
        $display("ALL TESTS PASSED: game_video_overlay");
        $finish;
    end
endmodule
