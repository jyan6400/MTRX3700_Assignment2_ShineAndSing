`timescale 1ns/1ps
/*
 *  video_analysis_tb.sv -- the whole key finder (video_analysis.sv) on the three pictures, in every
 *  mode (R-V1..R-V4) with both edge detectors, checked two ways:
 *
 *   1. EXACT, against a reference the bench computes itself from the picture (plain loops over the
 *      pixel array: smoothing, Sobel / 1-D difference, the profile, the normalisation, the local
 *      threshold, the pickers, the lattice fit and the lanes). Checked: the boundary list, the kept
 *      mask, the spacing, the four lanes, every column of the profile-view stream (n, hi(x), lo(x)),
 *      and every edge-map pixel written in the profile's rows.
 *   2. AGAINST THE PICTURE's true boundaries (memory/pianoN.txt), for the combinations the design is
 *      meant to read: every rung (R-V1..R-V4) with both detectors on the two supplied pictures, and
 *      R-V4 also on the photo-like picture. Every true boundary must be found by the picker within
 *      3 px, the lattice must keep no spurious one, and the four lanes must be four keys whose edges
 *      are true boundaries. (The lattice may drop a keyboard's outer edge when the end key is cut off
 *      or wider than the rest: that key is simply not a lane candidate.) The lower rungs on the photo
 *      are printed and checked to FAIL: that is what R-V4 fixes.
 *
 *  Stops with fatal on the first mismatch; prints ALL TESTS PASSED: video_analysis at the end.
 *  Run from the repository root (reads memory/piano{0,1,2}.hex/.txt).
 */
module video_analysis_tb;
    localparam int W = 320, H = 240, NMAX = 32, AW = 20, NW = 9, XW = 9, YW = 8;
    localparam int Y0 = 150, Y1 = 176;
    localparam int HI = 115, LO = 64, FLOOR = 26, KQ = 102, ABS = 2048, LANE_FIRST = 15;   // 15: the middle four keys
    int lf;                        // the first lane's key for the current result
    int abs_eff;                   // Sobel: x4

    logic clk = 0; always #10 clk = ~clk;
    logic reset = 1;

    // ---- the three pictures and a selector (as video_subsystem does) ----
    logic [$clog2(W*H)-1:0] rom_addr; logic [7:0] q0, q1, q2, rom_q; int pic = 0;
    image_rom #(.W(W), .H(H), .MIF_FILE("memory/piano0.mif"), .HEX_FILE("memory/piano0.hex")) r0 (.clk_a(clk), .addr_a(rom_addr), .q_a(q0), .clk_b(clk), .addr_b('0), .q_b());
    image_rom #(.W(W), .H(H), .MIF_FILE("memory/piano1.mif"), .HEX_FILE("memory/piano1.hex")) r1 (.clk_a(clk), .addr_a(rom_addr), .q_a(q1), .clk_b(clk), .addr_b('0), .q_b());
    image_rom #(.W(W), .H(H), .MIF_FILE("memory/piano2.mif"), .HEX_FILE("memory/piano2.hex")) r2 (.clk_a(clk), .addr_a(rom_addr), .q_a(q2), .clk_b(clk), .addr_b('0), .q_b());
    assign rom_q = (pic == 0) ? q0 : (pic == 1) ? q1 : q2;

    logic edge_sel = 1; logic [1:0] mode = 0;
    logic result_valid, lanes_valid, overflow, res_edge; logic [5:0] bcount, kcount; logic [NMAX*XW-1:0] bounds;
    logic [NMAX-1:0] kept; logic [XW-1:0] spacing; logic [4*XW-1:0] lane_l, lane_r; logic [1:0] res_mode;
    logic [AW-1:0] res_max; logic ew_en, pw_en; logic [$clog2(W*H)-1:0] ew_addr; logic [3:0] ew_data;
    logic [XW-1:0] pw_x; logic [3*NW-1:0] pw_data;
    video_analysis #(.W(W), .H(H), .NMAX(NMAX), .Y0(Y0), .Y1(Y1)) dut (
        .clk, .reset, .rom_addr, .rom_q, .edge_sel, .mode,
        .hi(NW'(HI)), .lo(NW'(LO)), .floor_lvl(NW'(FLOOR)), .k_q(8'(KQ)), .thr_abs(AW'(ABS)), .lane_first(4'(LANE_FIRST)),
        .result_valid, .res_bcount(bcount), .res_bounds(bounds), .res_kept(kept), .res_kcount(kcount),
        .res_spacing(spacing), .res_lanes_valid(lanes_valid), .res_lane_l(lane_l), .res_lane_r(lane_r),
        .res_mode, .res_edge_sel(res_edge), .res_max, .res_overflow(overflow),
        .ew_en, .ew_addr, .ew_data, .pw_en, .pw_x, .pw_data);

    // ---- what the DUT streamed out during the current result ----
    logic [3:0] ew_mem [0:W*H-1];
    logic [3*NW-1:0] pw_mem [0:W-1];
    always @(posedge clk) begin
        if (ew_en) ew_mem[ew_addr] <= ew_data;
        if (pw_en) pw_mem[pw_x] <= pw_data;
    end

    // ================================================================== the reference
    int img [0:2][0:H*W-1];
    logic [7:0] pix8 [0:H*W-1];
    int truth_v [0:2][0:31]; int truth_n [0:2];
    int src [0:H-1][0:W-1];  bit sv [0:H-1][0:W-1];     // picture after optional smoothing, and valid
    int g [0:H-1][0:W-1];    int mg [0:H-1][0:W-1];  bit gv [0:H-1][0:W-1];   // profile value, shown value
    int rp [0:W-1], rn [0:W-1], rt [0:W-1], rhi [0:W-1], rlo [0:W-1];
    int rmax, rthr_n;
    int found[$], keptl[$], rkeptmask[$], rspacing;

    function automatic int iabs(int v); return v < 0 ? -v : v; endfunction

    task automatic ref_edges(input int p, input int md, input bit sob);
        int k3 [0:2][0:2];
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
            end else if (x >= 1 && sv[y][x] && sv[y][x-1]) begin
                g[y][x] = iabs(src[y][x] - src[y][x-1]); gv[y][x] = 1; mg[y][x] = g[y][x];
            end
        end
    endtask

    task automatic ref_profile(input int md, input int kq);
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
            t = (s * kq) >> 10; rt[x] = (t > 511) ? 511 : t;
            if (md == 0) begin
                int w = rt[x] - (rt[x] >> 2);
                rhi[x] = (rt[x] > FLOOR) ? rt[x] : FLOOR;
                rlo[x] = (w > FLOOR) ? w : FLOOR;
            end else begin
                rhi[x] = HI; rlo[x] = LO;
            end
        end
    endtask

    task automatic ref_pick(input int md);
        int gap = (md == 1) ? 10 : 8;
        found.delete();
        if (md <= 1) begin                           // hysteresis on the normalised profile
            int cand[$], strongs[$];
            for (int x = 1; x <= W-2; x++)
                if (rn[x] >= rn[x-1] && rn[x] >= rn[x+1] && rn[x] > rlo[x]) begin
                    cand.push_back(x); if (rn[x] > rhi[x]) strongs.push_back(x);
                end
            if (cand.size() > 64) cand = cand[0:63];
            strongs.delete();
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
        end else if (md == 2) begin                  // peak_pick, raw profile
            int last_v = 0;
            for (int x = 1; x <= W-2; x++)
                if (rp[x] > abs_eff && rp[x] >= rp[x-1] && rp[x] >= rp[x+1]) begin
                    if (found.size() > 0 && x - found[$] < gap) begin
                        if (rp[x] > last_v) begin found[$] = x; last_v = rp[x]; end
                    end else if (found.size() < NMAX) begin found.push_back(x); last_v = rp[x]; end
                end
        end else begin                               // pick_runs, raw profile
            int i = 0;
            while (i < W) begin
                if (rp[i] > abs_eff) begin
                    int j = i, c;
                    while (j < W && rp[j] > abs_eff) j++;
                    c = (i + j - 1) / 2;
                    if (!(found.size() > 0 && c - found[$] < gap) && found.size() < NMAX) found.push_back(c);
                    i = j;
                end else i++;
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

    // ================================================================== checks
    int nfail = 0;
    task automatic fail(input string what);
        $display("FAIL [picture %0d, mode %0d, %s]: %s", pic, mode, edge_sel ? "Sobel" : "1-D", what);
        $fatal(1, "video_analysis_tb: mismatch");
    endtask

    task automatic check_result();
        string s;
        abs_eff = edge_sel ? ABS * 4 : ABS;
        ref_edges(pic, int'(mode), edge_sel);
        ref_profile(int'(mode), KQ);
        ref_pick(int'(mode));
        ref_lattice();
        if (res_mode != mode || res_edge != edge_sel) fail("result was not produced with the setting under test");
        if (res_max != AW'(rmax)) fail($sformatf("profile maximum %0d, reference %0d", res_max, rmax));
        // profile-view stream: every column
        for (int x = 0; x < W; x++) begin
            int en = pw_mem[x][NW-1:0], eh = pw_mem[x][2*NW-1:NW], el = pw_mem[x][3*NW-1:2*NW];
            int wh = (mode >= 2) ? rthr_n : rhi[x], wl = (mode >= 2) ? 0 : rlo[x];
            if (en != rn[x] || eh != wh || el != wl) begin
                fail($sformatf("profile view column %0d: n/hi/lo = %0d/%0d/%0d, reference %0d/%0d/%0d", x, en, eh, el, rn[x], wh, wl));
            end
        end
        // edge map, in the profile's rows
        for (int y = Y0; y <= Y1; y++) for (int x = 0; x < W; x++)
            if (gv[y][x] && int'(ew_mem[y*W + x]) != (mg[y][x] >> 4))
                fail($sformatf("edge map (%0d,%0d) = %0d, reference %0d", x, y, ew_mem[y*W + x], mg[y][x] >> 4));
        // boundaries
        if (int'(bcount) != found.size()) fail($sformatf("%0d boundaries, reference %0d", bcount, found.size()));
        foreach (found[i]) if (int'(bounds[i*XW +: XW]) != found[i])
            fail($sformatf("boundary %0d at %0d, reference %0d", i, bounds[i*XW +: XW], found[i]));
        foreach (rkeptmask[i]) if (kept[i] != rkeptmask[i][0]) fail($sformatf("kept flag of boundary %0d", i));
        if (int'(kcount) != keptl.size()) fail($sformatf("%0d kept, reference %0d", kcount, keptl.size()));
        if (int'(spacing) != rspacing) fail($sformatf("spacing %0d, reference %0d", spacing, rspacing));
        lf = (LANE_FIRST != 15) ? LANE_FIRST : (keptl.size() >= 5) ? (keptl.size() - 5) / 2 : 0;
        if (lanes_valid != (keptl.size() >= lf + 5)) fail("lanes_valid");
        if (lanes_valid) for (int i = 0; i < 4; i++)
            if (int'(lane_l[i*XW +: XW]) != keptl[lf+i] || int'(lane_r[i*XW +: XW]) != keptl[lf+i+1])
                fail($sformatf("lane %0d = [%0d,%0d], reference [%0d,%0d]", i, lane_l[i*XW +: XW], lane_r[i*XW +: XW],
                               keptl[lf+i], keptl[lf+i+1]));
        s = "";
        foreach (found[i]) s = {s, $sformatf(" %0d%s", found[i], rkeptmask[i] ? "" : "x")};
        $display("  picture %0d  %-6s  mode %0d: %2d boundaries (x = dropped by the lattice):%s | spacing %0d | lanes %s",
                 pic, edge_sel ? "Sobel" : "1-D", mode, bcount, s, spacing, lanes_valid ? "ok" : "none");
    endtask

    // the truth: every true boundary within 3 px of a found boundary, no kept boundary away from the
    // truth, and lanes whose edges are true boundaries. Returns whether the picture was read.
    function automatic bit near_truth(input int x);
        for (int t = 0; t < truth_n[pic]; t++) if (iabs(x - truth_v[pic][t]) <= 3) return 1;
        return 0;
    endfunction
    task automatic check_truth(input bit must, output bit ok);
        int hits = 0, extra = 0; bit lanes_ok;
        for (int t = 0; t < truth_n[pic]; t++) begin
            bit hit = 0;
            foreach (found[i]) if (iabs(found[i] - truth_v[pic][t]) <= 3) hit = 1;
            hits += hit;
        end
        foreach (keptl[i]) if (!near_truth(keptl[i])) extra++;
        lanes_ok = lanes_valid;
        if (lanes_valid) for (int i = 0; i < 4; i++)
            if (!near_truth(int'(lane_l[i*XW +: XW])) || !near_truth(int'(lane_r[i*XW +: XW]))) lanes_ok = 0;
        ok = (hits == truth_n[pic]) && (extra == 0) && lanes_ok;
        $display("      truth: %0d of %0d boundaries found, %0d spurious after the lattice fit, lanes %s -> %s",
                 hits, truth_n[pic], extra, lanes_ok ? "on true keys" : "wrong/none", ok ? "READ" : "not read");
        if (must && !ok) fail("the picture's keys were not read");
        if (!must && ok) fail("a lower rung read the photo-like picture: it no longer tests R-V4");
    endtask

    task automatic run_one(input int p, input int md, input bit sob, input bit must_read);
        bit ok;
        pic = p; mode = 2'(md); edge_sel = sob;
        @(posedge clk iff result_valid);             // the result of the sweep already under way
        @(posedge clk iff result_valid);             // a result produced entirely with this setting
        @(posedge clk);
        check_result();
        check_truth(must_read, ok);
    endtask

    initial begin
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
        repeat (5) @(posedge clk); reset = 0;
        $display("R-V4 (smoothing + local-average threshold), both edge detectors, all three pictures:");
        for (int p = 0; p < 3; p++) begin run_one(p, 0, 1, 1); run_one(p, 0, 0, 1); end
        $display("R-V3 (normalise + NMS + two thresholds %0d / %0d of 256): both supplied pictures, not the photo:", HI, LO);
        for (int p = 0; p < 3; p++) begin run_one(p, 1, 1, p < 2); run_one(p, 1, 0, p < 2); end
        $display("R-V2 (peak_pick, absolute threshold %0d, x 4 for Sobel): both supplied pictures, not the photo:", ABS);
        for (int p = 0; p < 3; p++) begin run_one(p, 2, 1, p < 2); run_one(p, 2, 0, p < 2); end
        $display("R-V1 (pick_runs, absolute threshold %0d, x 4 for Sobel): both supplied pictures, not the photo:", ABS);
        for (int p = 0; p < 3; p++) begin run_one(p, 3, 0, p < 2); run_one(p, 3, 1, p < 2); end
        // reset in the middle of a sweep: the next result must be complete and correct
        pic = 2; mode = 0; edge_sel = 1;
        repeat (30000) @(posedge clk);
        reset = 1; repeat (3) @(posedge clk); reset = 0;
        @(posedge clk iff result_valid); @(posedge clk);
        check_result();
        begin bit ok; check_truth(1, ok); end
        $display("  reset mid-sweep: next result complete and correct");
        $display("ALL TESTS PASSED: video_analysis");
        $finish;
    end
endmodule
