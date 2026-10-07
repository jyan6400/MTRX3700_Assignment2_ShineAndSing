`timescale 1ns/1ps
/*
 *  video_subsystem_tb.sv -- Advay's standalone subsystem test: video_subsystem.sv exactly as top_level
 *  instantiates it (three picture ROMs, the key finder at 50 MHz, the board thresholds, the CDC latch
 *  and dual-clock debug memories, the overlay at 25 MHz) with the mock game (sim/video/mock_game_state.sv)
 *  and the Lesson 3 VGA monitor model (5 % random stalls). Two asynchronous clocks: 50 MHz and 24.94 MHz.
 *  Frames are 320x240 (SH = 0: one screen pixel per picture pixel) so a frame is 106 000 clocks.
 *  Run from the repository root (reads memory/piano{0,1,2}.hex/.txt).
 *
 *  1. THE KEY FINDER, EXACT. For every rung (R-V4, R-V3, R-V1/R-V2) with both edge detectors on all
 *     three pictures the published result is compared with a reference the bench computes itself from
 *     the picture, with plain loops over the pixel array: the smoothing, Sobel / the 1-D difference, the
 *     column profile, the normalisation, the local threshold, the pickers, the lattice fit and the
 *     lanes. Checked: the boundary list, the kept flags, the spacing, the four lanes, the profile
 *     maximum, every column of the profile-view memory (n, hi(x), lo(x)) and every edge-map pixel of
 *     the rows swept so far; and no edge-detector output may ever be written outside the valid picture.
 *     (This is also the test of the 1-D detector, the mode selection, the convolution latency /
 *     coordinates and the stale-column mask.)
 *  2. THE KEY FINDER AGAINST THE PICTURE's true boundaries (memory/pianoN.txt): every rung must read
 *     both supplied pictures -- every true boundary found within 3 px, nothing spurious kept by the
 *     lattice, four lanes whose edges are true boundaries -- and only R-V4 the photo-like picture: the
 *     lower rungs are checked to FAIL on it (that is what R-V4 fixes).
 *  3. THE DISPLAY. For each picture at the default setting: the result crosses into the pixel clock
 *     unchanged (the CDC path), the lanes are the four middle kept keys, and each view is captured,
 *     checked and written as frame_<picture>_<view>.ppm (-> PNG):
 *        game      every lane is coloured from the game state latched for that frame (red in the hit
 *                  window, amber while a note counts down, faint blue when idle), the picture elsewhere;
 *                  the colour fills the real key: up between the black keys (row 100) but not on them,
 *                  and not on the piano's frame above and below the keys
 *        edge map  bright on the kept boundaries, dark in the middle of the keys
 *        profile   the yellow bar is a peak at every kept boundary
 *        masks     the four lane colours inside the four lanes
 *  4. THE BOARD THRESHOLDS (KEY3..1, SW0). A bench-side model of the five values (its own arithmetic,
 *     clamps and step sizes) is updated on every press and compared after every press: one press = one
 *     step even with contact bounce and when held down; SW0 and the mode choose the value; clamps at 0
 *     and 256 (k_q at 255); KEY3 restores every default. The reference of part 1 uses the model's
 *     values, so results with moved thresholds are checked exactly too (the keys reach the pickers).
 *  5. PLAY AND RESET. The game plays for several frames on the photo (a hit flashes a lane green); a
 *     reset of both domains in the middle of a frame recovers. The monitor model must report 0 protocol
 *     problems throughout.
 *  Stops with $fatal on the first mismatch; prints ALL TESTS PASSED: video_subsystem.
 */
module video_subsystem_tb;
    localparam int W = 320, H = 240, SH = 0, H_RES = W << SH, V_RES = H << SH, NMAX = 32, XW = 9, CW = 4;
    localparam int AW = 20, NW = 9, DB = 16;
    localparam int Y0 = 150, Y1 = 176, LANE_FIRST = 15;          // 15: the four middle keys
    localparam int MUST_READ = 1, MUST_FAIL = 0, ANY = 2;
    logic clk50 = 0; always #10    clk50 = ~clk50;
    logic clk25 = 0; always #20.05 clk25 = ~clk25;
    logic reset50 = 1, reset25 = 1;

    logic [1:0] sw_view = 0, sw_image = 0, sw_mode = 0; logic sw_edge = 1, sw_adjust = 0; logic [3:1] key_n = 3'b111;
    logic hold = 0;
    logic [3:0] lane_active, lane_hit_window, lane_hit_pulse; logic [CW-1:0] lane_count [0:3]; logic [15:0] score;
    mock_game_state #(.GAME_COUNT_W(CW), .BEAT(106000)) game (.clk(clk25), .reset(reset25), .hold,
        .lane_active, .lane_count, .lane_hit_window, .lane_hit_pulse, .score);

    logic [29:0] st_data; logic st_sop, st_eop, st_valid, st_ready;
    logic boundary_valid, lanes_valid; logic [5:0] boundary_count; logic [NMAX-1:0][XW-1:0] boundary_x;
    video_subsystem #(.IMG_W(W), .IMG_H(H), .VGA_W(H_RES), .VGA_H(V_RES), .SH(SH), .NMAX(NMAX), .GAME_COUNT_W(CW),
                      .LANE_FIRST(LANE_FIRST), .Y0(Y0), .Y1(Y1), .DB_TICKS(DB)) dut (
        .clk_50(clk50), .reset_50(reset50), .clk_25(clk25), .reset_25(reset25),
        .sw_view, .sw_image, .sw_edge, .sw_mode, .sw_adjust, .key_n,
        .lane_active, .lane_count, .lane_hit_window, .lane_hit_pulse, .score,
        .st_data, .st_startofpacket(st_sop), .st_endofpacket(st_eop), .st_valid, .st_ready,
        .boundary_valid, .boundary_count, .boundary_x, .lanes_valid);
    int frames_done, errors, x_pos, y_pos; logic accept, discard;
    vga_monitor_model #(.H_RES(H_RES), .V_RES(V_RES), .H_BLANK(H_RES/4), .V_BLANK(V_RES/10), .RANDOM_STALL_PCT(5),
                        .ASCII_ART(0), .PPM_PREFIX(""), .VERBOSE(0)) mon (
        .clk(clk25), .reset(reset25), .data(st_data), .startofpacket(st_sop), .endofpacket(st_eop), .valid(st_valid), .ready(st_ready),
        .frames_done, .errors, .x_pos, .y_pos, .accept, .discard);

    function automatic int iabs(int v); return v < 0 ? -v : v; endfunction

    // ================================================================== the bench's model of the thresholds
    int m_hi, m_lo, m_floor, m_kq, m_abs;
    task automatic defaults(); m_hi = 115; m_lo = 64; m_floor = 26; m_kq = 102; m_abs = 2048; endtask
    function automatic int clamp(int v, int lo_v, int hi_v); return (v < lo_v) ? lo_v : (v > hi_v) ? hi_v : v; endfunction
    // what one press should do
    task automatic model_press(input int key);
        int dir;
        if (key == 3) begin defaults(); return; end
        dir = (key == 1) ? 1 : -1;
        case (sw_mode)
            2'd0: if (!sw_adjust) m_kq = clamp(m_kq + 8 * dir, 0, 255); else m_floor = clamp(m_floor + 4 * dir, 0, 256);
            2'd1: if (!sw_adjust) m_hi = clamp(m_hi + 8 * dir, 0, 256); else m_lo = clamp(m_lo + 8 * dir, 0, 256);
            default: m_abs = clamp(m_abs + 256 * dir, 0, (1 << AW) - 1);
        endcase
    endtask
    task automatic check_ctrl(input string what);
        if (int'(dut.hi) != m_hi || int'(dut.lo) != m_lo || int'(dut.floor_lvl) != m_floor || int'(dut.k_q) != m_kq || int'(dut.thr_abs) != m_abs)
            $fatal(1, "FAIL %s: hi/lo/floor/k_q/abs = %0d/%0d/%0d/%0d/%0d, expected %0d/%0d/%0d/%0d/%0d", what,
                   dut.hi, dut.lo, dut.floor_lvl, dut.k_q, dut.thr_abs, m_hi, m_lo, m_floor, m_kq, m_abs);
    endtask
    // a press with bounce: chatter for a few clocks, hold, release with chatter (bounce lasts < DB clocks)
    task automatic press(input int key, input int hold_ticks);
        for (int i = 0; i < 4; i++) begin key_n[key] = 0; repeat (1 + $urandom % 2) @(posedge clk50); key_n[key] = 1; @(posedge clk50); end
        key_n[key] = 0; repeat (hold_ticks * DB) @(posedge clk50);
        for (int i = 0; i < 3; i++) begin key_n[key] = 1; @(posedge clk50); key_n[key] = 0; @(posedge clk50); end
        key_n[key] = 1; repeat (3 * DB) @(posedge clk50);
        model_press(key);
    endtask

    // ================================================================== the reference key finder
    int img [0:2][0:H*W-1];
    logic [7:0] pix8 [0:H*W-1];
    int truth_v [0:2][0:31]; int truth_n [0:2];
    int src [0:H-1][0:W-1];  bit sv [0:H-1][0:W-1];     // picture after optional smoothing, and valid
    int g [0:H-1][0:W-1];    int mg [0:H-1][0:W-1];  bit gv [0:H-1][0:W-1];   // profile value, shown value
    int rp [0:W-1], rn [0:W-1], rt [0:W-1], rhi [0:W-1], rlo [0:W-1];
    int rmax, rthr_n, abs_eff;
    int found[$], keptl[$], rkeptmask[$], rspacing;

    task automatic ref_edges(input int p, input int md, input bit sob);
        // smoothing (R-V4 only)
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
            src[y][x] = img[p][y*W + x]; sv[y][x] = 1;
        end
        if (md == 0) begin
            int gs [0:H-1][0:W-1]; bit gsv [0:H-1][0:W-1];
            for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
                gs[y][x] = 0; gsv[y][x] = 0;
                if (y >= 1 && y <= H-2 && x >= 1 && x <= W-2) begin
                    int acc = 0;
                    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++)
                        acc += ((dy == 0 ? 2 : 1) * (dx == 0 ? 2 : 1)) * img[p][(y+dy)*W + x+dx];
                    gs[y][x] = acc >> 4; gsv[y][x] = 1;
                end
            end
            for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin src[y][x] = gs[y][x]; sv[y][x] = gsv[y][x]; end
        end
        // edges: valid where every input used was valid
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
            g[y][x] = 0; mg[y][x] = 0; gv[y][x] = 0;
            if (sob) begin
                if (y >= 1 && y <= H-2 && x >= 1 && x <= W-2) begin
                    bit ok = 1; int gx = 0, gy = 0;
                    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) begin
                        int wgt = (dy == 0) ? 2 : 1, wgy = (dx == 0) ? 2 : 1;
                        ok &= sv[y+dy][x+dx];
                        gx += dx * wgt * src[y+dy][x+dx];
                        gy += dy * wgy * src[y+dy][x+dx];
                    end
                    if (ok) begin
                        int m = (iabs(gx) + iabs(gy)) >> 2;
                        g[y][x] = iabs(gx); gv[y][x] = 1; mg[y][x] = (m > 255) ? 255 : m;
                    end
                end
            end else if (x >= 1 && sv[y][x] && sv[y][x-1]) begin          // the 1-D difference
                g[y][x] = iabs(src[y][x] - src[y][x-1]); gv[y][x] = 1; mg[y][x] = g[y][x];
            end
        end
    endtask

    task automatic ref_profile(input int md);
        rmax = 0;
        for (int x = 0; x < W; x++) begin
            rp[x] = 0;
            for (int y = Y0; y <= Y1; y++) if (gv[y][x]) rp[x] += g[y][x];
            if (rp[x] > rmax) rmax = rp[x];
        end
        for (int x = 0; x < W; x++) rn[x] = (rmax == 0) ? 0 : (rp[x] * 256) / rmax;
        rthr_n = (rmax == 0 || abs_eff >= 2 * rmax) ? 511 : (abs_eff * 256) / rmax;
        for (int x = 0; x < W; x++) begin
            int s = 0, t;
            for (int j = x - 12; j <= x + 12; j++) if (j >= 0 && j < W) s += rn[j];
            t = (s * m_kq) >> 10; rt[x] = (t > 511) ? 511 : t;
            if (md == 0) begin
                int w = rt[x] - (rt[x] >> 2);
                rhi[x] = (rt[x] > m_floor) ? rt[x] : m_floor;
                rlo[x] = (w > m_floor) ? w : m_floor;
            end else begin
                rhi[x] = m_hi; rlo[x] = m_lo;
            end
        end
    endtask

    task automatic ref_pick(input int md);
        int gap = (md == 1) ? 10 : 8;
        found.delete();
        if (md <= 1) begin                           // hysteresis on the normalised profile (R-V3, R-V4)
            int cand[$], strongs[$];
            for (int x = 1; x <= W-2; x++)
                if (rn[x] >= rn[x-1] && rn[x] >= rn[x+1] && rn[x] > rlo[x]) cand.push_back(x);
            if (cand.size() > 64) cand = cand[0:63];
            foreach (cand[i]) if (rn[cand[i]] > rhi[cand[i]]) strongs.push_back(cand[i]);
            foreach (cand[i]) begin
                bit acc = (rn[cand[i]] > rhi[cand[i]]);
                foreach (strongs[j]) if (iabs(cand[i] - strongs[j]) <= gap) acc = 1;
                if (acc) begin
                    if (found.size() > 0 && cand[i] - found[$] < gap) begin
                        if (rn[cand[i]] > rn[found[$]]) found[$] = cand[i];
                    end else if (found.size() < NMAX) found.push_back(cand[i]);
                end
            end
        end else begin                               // peak_pick on the raw profile (R-V1, R-V2)
            int last_v = 0;
            for (int x = 1; x <= W-2; x++)
                if (rp[x] > abs_eff && rp[x] >= rp[x-1] && rp[x] >= rp[x+1]) begin
                    if (found.size() > 0 && x - found[$] < gap) begin
                        if (rp[x] > last_v) begin found[$] = x; last_v = rp[x]; end
                    end else if (found.size() < NMAX) begin found.push_back(x); last_v = rp[x]; end
                end
        end
    endtask

    task automatic ref_lattice();
        int d[$], s;
        keptl.delete(); rkeptmask.delete(); rspacing = 0;
        foreach (found[i]) rkeptmask.push_back(0);
        if (found.size() == 0) return;
        if (found.size() < 3) begin
            foreach (found[i]) begin keptl.push_back(found[i]); rkeptmask[i] = 1; end
            return;
        end
        for (int i = 0; i + 1 < found.size(); i++) d.push_back(found[i+1] - found[i]);
        d.sort(); s = d[(d.size() - 1) / 2]; rspacing = s;
        keptl.push_back(found[0]); rkeptmask[0] = 1;
        for (int i = 1; i < found.size(); i++) begin
            int dd = found[i] - keptl[$];
            if (iabs(dd - s) < (s >> 2) || 2 * dd > 3 * s) begin keptl.push_back(found[i]); rkeptmask[i] = 1; end
        end
    endtask

    // ================================================================== result checks (50 MHz side)
    int pic, md; bit sob;                             // the setting under test
    task automatic fail(input string what);
        $display("FAIL [picture %0d, mode %0d, %s]: %s", pic, md, sob ? "Sobel" : "1-D", what);
        $fatal(1, "video_subsystem_tb: mismatch");
    endtask
    function automatic bit near_truth(input int x);
        for (int t = 0; t < truth_n[pic]; t++) if (iabs(x - truth_v[pic][t]) <= 3) return 1;
        return 0;
    endfunction

    // the published result against the reference (exact), then against the picture's true boundaries
    task automatic check_result(input int must, output bit ok);
        string s; int lf, hits, extra; bit lanes_ok;
        pic = (sw_image == 2'd3) ? 2 : int'(sw_image); md = int'(sw_mode); sob = sw_edge;
        abs_eff = sob ? m_abs * 4 : m_abs;
        ref_edges(pic, md, sob); ref_profile(md); ref_pick(md); ref_lattice();
        // ---- exact ----
        if (dut.res_mode != sw_mode || dut.res_edge_sel != sw_edge) fail("the result was not produced with the setting under test");
        if (int'(dut.res_max) != rmax) fail($sformatf("profile maximum %0d, reference %0d", dut.res_max, rmax));
        for (int x = 0; x < W; x++) begin             // the profile-view memory: every column
            int en, eh, el, wh, wl;
            en = int'(dut.prof_mem[x][NW-1:0]); eh = int'(dut.prof_mem[x][2*NW-1:NW]); el = int'(dut.prof_mem[x][3*NW-1:2*NW]);
            wh = (md >= 2) ? rthr_n : rhi[x]; wl = (md >= 2) ? 0 : rlo[x];
            if (en != rn[x] || eh != wh || el != wl)
                fail($sformatf("profile view column %0d: n/hi/lo = %0d/%0d/%0d, reference %0d/%0d/%0d", x, en, eh, el, rn[x], wh, wl));
        end
        for (int y = 0; y <= Y1; y++) for (int x = 0; x < W; x++)         // the edge map, every row swept so far
            if (gv[y][x] && int'(dut.edge_mem[y*W + x]) != (mg[y][x] >> 4))
                fail($sformatf("edge map (%0d,%0d) = %0d, reference %0d", x, y, dut.edge_mem[y*W + x], mg[y][x] >> 4));
        if (int'(dut.res_bcount) != found.size()) fail($sformatf("%0d boundaries, reference %0d", dut.res_bcount, found.size()));
        if (int'(boundary_count) != found.size()) fail("boundary_count (contract D)");
        foreach (found[i]) if (int'(boundary_x[i]) != found[i])
            fail($sformatf("boundary %0d at %0d, reference %0d", i, boundary_x[i], found[i]));
        foreach (rkeptmask[i]) if (dut.res_kept[i] != rkeptmask[i][0]) fail($sformatf("kept flag of boundary %0d", i));
        if (int'(dut.res_kcount) != keptl.size()) fail($sformatf("%0d kept, reference %0d", dut.res_kcount, keptl.size()));
        if (int'(dut.res_spacing) != rspacing) fail($sformatf("spacing %0d, reference %0d", dut.res_spacing, rspacing));
        lf = (LANE_FIRST != 15) ? LANE_FIRST : (keptl.size() >= 5) ? (keptl.size() - 5) / 2 : 0;
        if (lanes_valid != (keptl.size() >= lf + 5)) fail("lanes_valid");
        if (lanes_valid) for (int i = 0; i < 4; i++)
            if (int'(dut.res_lane_l[i*XW +: XW]) != keptl[lf+i] || int'(dut.res_lane_r[i*XW +: XW]) != keptl[lf+i+1])
                fail($sformatf("lane %0d = [%0d,%0d], reference [%0d,%0d]", i, dut.res_lane_l[i*XW +: XW], dut.res_lane_r[i*XW +: XW],
                               keptl[lf+i], keptl[lf+i+1]));
        // ---- the truth ----
        hits = 0; extra = 0;
        for (int t = 0; t < truth_n[pic]; t++) begin
            bit hit; hit = 0;
            foreach (found[i]) if (iabs(found[i] - truth_v[pic][t]) <= 3) hit = 1;
            hits += int'(hit);
        end
        foreach (keptl[i]) if (!near_truth(keptl[i])) extra++;
        lanes_ok = lanes_valid;
        if (lanes_valid) for (int i = 0; i < 4; i++)
            if (!near_truth(int'(dut.res_lane_l[i*XW +: XW])) || !near_truth(int'(dut.res_lane_r[i*XW +: XW]))) lanes_ok = 0;
        ok = (hits == truth_n[pic]) && (extra == 0) && lanes_ok;
        s = "";
        foreach (found[i]) s = {s, $sformatf(" %0d%s", found[i], rkeptmask[i] ? "" : "x")};
        $display("  picture %0d %-5s mode %0d:%s | spacing %0d | %0d/%0d true, %0d spurious kept, lanes %s -> %s",
                 pic, sob ? "Sobel" : "1-D", md, s, rspacing, hits, truth_n[pic], extra,
                 lanes_ok ? "on true keys" : "wrong/none", ok ? "READ" : "not read");
        if (must == MUST_READ && !ok) fail("the picture's keys were not read");
        if (must == MUST_FAIL && ok) fail("a lower rung read the photo-like picture: it no longer tests R-V4");
    endtask

    // The edge detectors may only write pixels whose whole window was real picture: never the first
    // pixel of a row from the 1-D difference (its left neighbour would be the end of the row above), nor
    // the border of the smoothed picture. (The column profile takes the same stream.)
    always @(posedge clk50) if (!reset50 && dut.ew_en) begin
        int wx, wy, x_lo, x_hi, y_lo, y_hi; bit sm, sb;
        wx = int'(dut.ew_addr) % W; wy = int'(dut.ew_addr) / W;
        sm = (dut.cfg_mode == 2'd0); sb = dut.cfg_edge;
        x_lo = sm ? 2 : 1;                    x_hi = W - 1 - (sb ? 1 : 0) - (sm ? 1 : 0);
        y_lo = (sm ? 1 : 0) + (sb ? 1 : 0);   y_hi = H - 1 - (sm ? 1 : 0) - (sb ? 1 : 0);
        if (wx < x_lo || wx > x_hi || wy < y_lo || wy > y_hi)
            $fatal(1, "FAIL: edge detector output at (%0d,%0d) with mode %0d, %s: outside the valid picture", wx, wy, dut.cfg_mode, sb ? "Sobel" : "1-D");
    end

    // a result produced entirely with the current switches and thresholds, then check it
    task automatic run_one(input int p, input int mode, input bit sobel_on, input int must);
        bit ok;
        sw_image = 2'(p); sw_mode = 2'(mode); sw_edge = sobel_on;
        @(posedge clk50 iff boundary_valid);         // the result of the sweep already under way
        @(posedge clk50 iff boundary_valid);         // a result produced entirely with this setting
        @(posedge clk50);
        check_result(must, ok);
    endtask

    // ================================================================== the display side
    logic [23:0] cap [0:V_RES-1][0:H_RES-1];
    always @(posedge clk25) if (accept) cap[y_pos][x_pos] <= {st_data[29:22], st_data[19:12], st_data[9:2]};

    task automatic write_ppm(input string name);
        int fd;
        fd = $fopen({"frame_", name, ".ppm"}, "wb");
        $fwrite(fd, "P6\n%0d %0d\n255\n", H_RES, V_RES);
        for (int y = 0; y < V_RES; y++) for (int x = 0; x < H_RES; x++)
            $fwrite(fd, "%c%c%c", cap[y][x][23:16], cap[y][x][15:8], cap[y][x][7:0]);
        $fclose(fd);
    endtask

    // the game state each frame shows: a snapshot at the overlay's frame latch
    typedef struct { bit active [4]; bit window [4]; int count [4]; int flash [4]; int view; } snap_t;
    snap_t cur, snaps[$];
    bit hit_seen [4];
    // the first frame after a reset shows the overlay's reset state
    task automatic reset_snaps();
        cur.view = 0;
        for (int i = 0; i < 4; i++) begin cur.active[i] = 0; cur.window[i] = 0; cur.count[i] = 0; cur.flash[i] = 0; hit_seen[i] = 0; end
        snaps.delete(); snaps.push_back(cur);
    endtask
    always @(posedge clk25) if (!reset25) begin
        if (dut.u_overlay.frame_latch) begin
            cur.view = int'(dut.view_s);
            for (int i = 0; i < 4; i++) begin
                cur.active[i] = lane_active[i]; cur.window[i] = lane_hit_window[i]; cur.count[i] = int'(lane_count[i]);
                if (hit_seen[i] || lane_hit_pulse[i]) cur.flash[i] = 8; else if (cur.flash[i] > 0) cur.flash[i]--;
                hit_seen[i] = 0;
            end
            snaps.push_back(cur);
        end else for (int i = 0; i < 4; i++) if (lane_hit_pulse[i]) hit_seen[i] = 1;
    end
    snap_t shown;                        // the snapshot of the frame most recently completed
    int base = 0, green_seen = 0;
    always @(posedge clk25) if (!reset25 && frames_done > base) begin
        base = frames_done;
        if (snaps.size() > 0) shown = snaps.pop_front();
    end
    task automatic next_frame(); int f; f = frames_done; @(posedge clk25 iff frames_done > f); #1; endtask

    // the display's copy of the result (after the CDC latch)
    function automatic int d_count(); return int'(dut.d_bcount); endfunction
    function automatic int d_bound(int i); return int'(dut.d_bounds[i*XW +: XW]); endfunction
    function automatic bit d_kept(int i); return dut.d_kept[i]; endfunction
    function automatic int d_l(int i); return int'(dut.d_l[i*XW +: XW]); endfunction
    function automatic int d_r(int i); return int'(dut.d_r[i*XW +: XW]); endfunction

    // wait until a result made entirely with the current switches is on the screen, and the overlay has
    // had its two further frames to measure the keys' outlines
    task automatic settle();
        repeat (2) @(posedge clk50 iff boundary_valid);
        repeat (5) next_frame();
    endtask

    // the display holds exactly what the key finder published (the CDC path)
    task automatic check_display();
        if (d_count() != int'(boundary_count)) $fatal(1, "FAIL: the display holds %0d boundaries, the key finder published %0d", d_count(), boundary_count);
        for (int i = 0; i < d_count(); i++) begin
            if (d_bound(i) != int'(boundary_x[i])) $fatal(1, "FAIL: boundary %0d differs across the CDC", i);
            if (d_kept(i) != dut.res_kept[i])      $fatal(1, "FAIL: kept flag %0d differs across the CDC", i);
        end
        if (dut.d_lanes_valid != lanes_valid) $fatal(1, "FAIL: lanes_valid differs across the CDC");
        for (int i = 0; i < 4; i++)
            if (d_l(i) != int'(dut.res_lane_l[i*XW +: XW]) || d_r(i) != int'(dut.res_lane_r[i*XW +: XW])) $fatal(1, "FAIL: lane %0d differs across the CDC", i);
    endtask

    function automatic bit is_grey(input logic [23:0] c); return (c[23:16] == c[15:8]) && (c[15:8] == c[7:0]); endfunction

    task automatic grab(input int view, input string name);
        sw_view = 2'(view);
        repeat (3) next_frame();                             // the view is latched per frame
        if (shown.view != view) $fatal(1, "FAIL: frame shows view %0d, expected %0d", shown.view, view);
        write_ppm(name);
    endtask

    task automatic check_views(input int p);
        int sy;
        sy = Y0 + 1;
        // game view: every lane coloured from the snapshot of the frame shown
        grab(0, $sformatf("p%0d_view0_game", p));
        for (int i = 0; i < 4; i++) begin
            logic [23:0] c; int x, lit, dark;
            x = (d_l(i) + d_r(i)) / 2; c = cap[sy][x];           // the middle of the key, in the analysed rows
            if (shown.flash[i] > 0)    begin if (c[15:8] != 8'd255)                        $fatal(1, "FAIL: lane %0d should flash green: %06h", i, c); end
            else if (shown.window[i])  begin if (c[23:16] != 8'd255 || c[15:8] > 8'd40)     $fatal(1, "FAIL: lane %0d should be red: %06h", i, c); end
            else if (shown.active[i])  begin if (c[7:0] != 8'd0 || c[23:16] <= c[15:8])      $fatal(1, "FAIL: lane %0d should be amber: %06h", i, c); end
            else                       begin if (c[7:0] <= c[23:16])                         $fatal(1, "FAIL: lane %0d should be tinted blue: %06h", i, c); end
            // the colour is the shape of the key: at row 100 (between the black keys) the middle of the key
            // is coloured and the black key beside it is not; the frame above and below the keys is not
            if (is_grey(cap[100][x])) $fatal(1, "FAIL: lane %0d: the key is not coloured up between the black keys (row 100)", i);
            lit = 0; dark = 0;
            for (int xx = d_l(i) + 1; xx < d_r(i); xx++) if (is_grey(cap[100][xx])) dark++; else lit++;
            if (lit < 6 || dark < 3) $fatal(1, "FAIL: lane %0d at row 100: %0d coloured and %0d uncoloured columns -- not the shape of a key beside a black key", i, lit, dark);
            if (!is_grey(cap[2][x]) || !is_grey(cap[H - 8][x])) $fatal(1, "FAIL: lane %0d: colour outside the key (rows 2 / %0d)", i, H - 8);   // (row 2: above the score box)
        end
        // edge map: a kept boundary column is bright in the key rows, a key centre is dark
        grab(1, $sformatf("p%0d_view1_edges", p));
        begin
            int eb, ec, kx, cx;
            kx = d_l(1); cx = (d_l(1) + d_r(1)) / 2; eb = 0; ec = 0;
            for (int y = Y0; y <= Y1; y++) begin
                int m; m = 0;
                for (int dx = -3; dx <= 3; dx++) if (int'(cap[y][kx + dx][7:0]) > m) m = int'(cap[y][kx + dx][7:0]);
                eb += m; ec += int'(cap[y][cx][7:0]);
            end
            if (eb <= 3 * ec || eb < 20 * (Y1 - Y0 + 1)) $fatal(1, "FAIL: edge map: boundary %0d vs key centre %0d", eb / (Y1 - Y0 + 1), ec / (Y1 - Y0 + 1));
        end
        // profile view: at every kept boundary the yellow bar is a peak, well above the bar in the middle
        // of the next key (on the photo's dim left side the peak is low, but still a peak)
        grab(2, $sformatf("p%0d_view2_profile", p));
        for (int i = 0; i + 1 < d_count(); i++) if (d_kept(i)) begin
            int best, mid, hm;
            best = 0; mid = (d_bound(i) + d_bound(i + 1)) / 2;
            for (int dx = -2; dx <= 2; dx++) begin
                int hgt; hgt = 0;
                while (hgt < V_RES / 2 && cap[V_RES - 1 - hgt][d_bound(i) + dx] == 24'hFFD020) hgt++;
                if (hgt > best) best = hgt;
            end
            hm = 0; while (hm < V_RES / 2 && cap[V_RES - 1 - hm][mid] == 24'hFFD020) hm++;
            if (best < 2 * hm + 4) $fatal(1, "FAIL: profile bar at boundary %0d (%0d px) is not a peak over the key centre (%0d px)", d_bound(i), best, hm);
        end
        // mask view: four colours
        grab(3, $sformatf("p%0d_view3_masks", p));
        begin
            logic [23:0] lc [4];
            lc[0] = 24'hE63C3C; lc[1] = 24'h3CC83C; lc[2] = 24'h466EFF; lc[3] = 24'hF0DC28;
            for (int i = 0; i < 4; i++) begin
                if (cap[sy][(d_l(i) + d_r(i)) / 2 + 1] != lc[i]) $fatal(1, "FAIL: mask %0d colour %06h", i, cap[sy][(d_l(i) + d_r(i)) / 2 + 1]);
                if (cap[100][(d_l(i) + d_r(i)) / 2] != lc[i])    $fatal(1, "FAIL: mask %0d is not the whole key (row 100)", i);
            end
        end
        sw_view = 0;
    endtask

    // ================================================================== the test
    initial begin
        bit ok;
        // the pictures and their true boundaries
        for (int p = 0; p < 3; p++) begin
            int fd; string line;
            truth_n[p] = 0;
            $readmemh($sformatf("memory/piano%0d.hex", p), pix8);
            for (int i = 0; i < W*H; i++) img[p][i] = int'(pix8[i]);
            fd = $fopen($sformatf("memory/piano%0d.txt", p), "r");
            if (fd == 0) $fatal(1, "cannot open memory/piano%0d.txt: run tools/video/make_piano_images.py", p);
            while ($fgets(line, fd)) if (line.substr(0, 5) == "edges=") begin
                int v; byte c;
                v = -1;
                for (int pos = 6; pos < line.len(); pos++) begin
                    c = line.getc(pos);
                    if (c >= 8'd48 && c <= 8'd57) v = ((v < 0) ? 0 : v * 10) + int'(c) - 48;
                    else if (v >= 0) begin truth_v[p][truth_n[p]] = v; truth_n[p]++; v = -1; end
                end
                if (v >= 0) begin truth_v[p][truth_n[p]] = v; truth_n[p]++; end
            end
            $fclose(fd);
        end
        defaults();
        reset_snaps();
        repeat (4) @(posedge clk50); reset50 = 0; reset25 = 0;
        repeat (5) @(posedge clk50); check_ctrl("after reset");

        $display("R-V4 (default: all switches down), Sobel: the key finder, the CDC and the four views:");
        for (int p = 0; p < 3; p++) begin
            sw_image = 2'(p); settle();
            check_result(MUST_READ, ok); check_display();
            check_views(p);
        end

        $display("R-V4 (smoothing + local-average threshold), 1-D detector, all three pictures:");
        for (int p = 0; p < 3; p++) run_one(p, 0, 0, MUST_READ);
        $display("R-V3 (normalise + local maxima + two thresholds %0d / %0d of 256): both supplied pictures, not the photo:", m_hi, m_lo);
        for (int p = 0; p < 3; p++) begin run_one(p, 1, 1, (p < 2) ? MUST_READ : MUST_FAIL); run_one(p, 1, 0, (p < 2) ? MUST_READ : MUST_FAIL); end
        sw_view = 2; repeat (3) next_frame(); write_ppm("p2_view2_profile_RV3_fails"); sw_view = 0;
        $display("R-V2 (Sobel) and R-V1 (1-D): peak_pick, absolute threshold %0d (x 4 for Sobel): both supplied pictures, not the photo:", m_abs);
        for (int p = 0; p < 3; p++) begin run_one(p, 2, 1, (p < 2) ? MUST_READ : MUST_FAIL); run_one(p, 2, 0, (p < 2) ? MUST_READ : MUST_FAIL); end
        run_one(0, 3, 1, MUST_READ);                 // SW7..6 = 3 is the same picker as 2

        $display("The board thresholds (KEY3..1, SW0): bounced presses, held keys, clamps, and their effect on the result:");
        sw_image = 0; sw_edge = 1;
        sw_mode = 1; sw_adjust = 0; repeat (4) @(posedge clk50);
        press(1, 2);  check_ctrl("R-V3 hi up");
        press(1, 20); check_ctrl("R-V3 hi up, held for 20 ticks: still one step");
        press(2, 2);  check_ctrl("R-V3 hi down");
        if (m_hi != 123) $fatal(1, "FAIL: the bench's model of hi is %0d", m_hi);
        sw_adjust = 1; repeat (4) @(posedge clk50);
        press(1, 1); press(1, 1); check_ctrl("R-V3 lo up twice");
        run_one(0, 1, 1, ANY);                       // hi 123, lo 80: the result must follow the moved thresholds exactly
        for (int i = 0; i < 14; i++) begin press(2, 1); check_ctrl("R-V3 lo down to the clamp"); end
        if (dut.lo != 0) $fatal(1, "FAIL: lo did not clamp at 0");
        sw_mode = 0; sw_adjust = 0; repeat (4) @(posedge clk50);
        press(2, 1); press(2, 1); check_ctrl("R-V4 k down twice");
        sw_adjust = 1; repeat (4) @(posedge clk50);
        press(1, 1); check_ctrl("R-V4 floor up");
        run_one(2, 0, 1, ANY);                       // k_q 86, floor 30 on the photo: exact
        sw_adjust = 0; repeat (4) @(posedge clk50);
        for (int i = 0; i < 22; i++) begin press(1, 1); check_ctrl("R-V4 k up to the clamp"); end
        if (dut.k_q != 255) $fatal(1, "FAIL: k_q did not clamp at 255");
        sw_mode = 2; repeat (4) @(posedge clk50);
        press(1, 1); press(1, 1); check_ctrl("R-V2 absolute threshold up");
        run_one(0, 2, 1, ANY);                       // thr_abs 2560: exact (and one boundary fewer than at 2048)
        sw_mode = 3; sw_adjust = 0; repeat (4) @(posedge clk50);
        press(2, 1); check_ctrl("absolute threshold down with SW7..6 = 3 (SW0 ignored)");
        sw_mode = 1; sw_adjust = 0; repeat (4) @(posedge clk50);
        for (int i = 0; i < 20; i++) begin press(1, 1); check_ctrl("R-V3 hi up to the clamp"); end
        if (dut.hi != 256) $fatal(1, "FAIL: hi did not clamp at 256");
        press(3, 1); check_ctrl("KEY3 restores the defaults");
        $display("  one step per bounced press, SW0 and the mode select the value, clamps, KEY3 restore");

        // play: several game frames on the photo, checking every one, until a hit has flashed green
        $display("Playing on the photo (R-V4):");
        sw_mode = 0; sw_view = 0; sw_image = 2; sw_edge = 1;
        settle(); check_result(MUST_READ, ok); check_display();
        for (int f = 0; f < 80 && green_seen < 2; f++) begin
            next_frame();
            for (int i = 0; i < 4; i++) begin
                logic [23:0] c;
                c = cap[Y0 + 1][(d_l(i) + d_r(i)) / 2];
                if (shown.flash[i] > 0) begin
                    if (c[15:8] != 8'd255) $fatal(1, "FAIL: frame %0d lane %0d should flash green", frames_done, i);
                    if (green_seen == 0) write_ppm("p2_view0_game_hit");
                    green_seen++;
                end else if (shown.window[i] && c[23:16] != 8'd255) $fatal(1, "FAIL: frame %0d lane %0d should be red", frames_done, i);
            end
        end
        if (green_seen == 0) $fatal(1, "FAIL: no hit was drawn in 80 frames");
        $display("  %0d frames so far, hits drawn", base);
        // reset both domains in the middle of a frame (and in the middle of a sweep)
        wait (y_pos == V_RES / 2);
        reset25 = 1; reset50 = 1; repeat (4) @(posedge clk50);
        reset_snaps(); base = frames_done; reset50 = 0; reset25 = 0;
        settle(); check_result(MUST_READ, ok); check_display();
        $display("  reset mid-frame: recovered, next result complete and correct");
        if (errors != 0) $fatal(1, "FAIL: the monitor model counted %0d protocol problems", errors);
        $display("PASS: every rung x both detectors x three pictures exact; views; thresholds; play; reset; %0d frames, 0 protocol problems", frames_done);
        $display("ALL TESTS PASSED: video_subsystem");
        $finish;
    end
endmodule
