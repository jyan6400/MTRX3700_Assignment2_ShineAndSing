`timescale 1ns/1ps
/*
 *  video_subsystem_tb.sv -- Advay's standalone subsystem test: video_subsystem.sv exactly as top_level
 *  instantiates it (three picture ROMs, the key finder at 50 MHz, the controls, the CDC latch and
 *  dual-clock debug memories, the overlay at 25 MHz) with the mock game (sim/video/mock_game_state.sv)
 *  and the Lesson 3 VGA monitor model (5 % random stalls). Two asynchronous clocks: 50 MHz and 24.94 MHz.
 *  Frames are 320x240 (SH = 0: one screen pixel per picture pixel) so a frame is 106 000 clocks.
 *
 *  For each picture (SW4..3 = 0, 1, 2) at the default setting (R-V4, Sobel, all switches down):
 *    - the result crosses into the display (the CDC path) and the boundaries the display draws are the
 *      ones the key finder produced
 *    - every true key boundary (memory/pianoN.txt) is found within 3 px, nothing spurious is kept
 *    - the four lanes are the four middle kept keys (LANE_FIRST = 15) and their edges are true boundaries
 *    - each view is captured and checked, and written as frame_<picture>_<view>.ppm (-> PNG):
 *        game      every lane is coloured from the game state latched for that frame (red in the hit
 *                  window, amber while a note counts down, faint blue when idle), the picture elsewhere
 *        edge map  bright on the kept boundaries, dark in the middle of the keys
 *        profile   the yellow bar reaches up at every kept boundary
 *        masks     the four lane colours inside the four lanes
 *  Then: SW5 = 0 (1-D) at R-V4 still reads the photo; the rungs below (R-V3 on the photo) are shown
 *  failing, as the specification says they do; KEY1 moves a threshold (visible in the profile view);
 *  the game plays for several frames (a hit flashes a lane green); a reset of both domains in the
 *  middle of a frame recovers. The monitor model must report 0 protocol problems throughout.
 *  Prints ALL TESTS PASSED: video_subsystem.
 */
module video_subsystem_tb;
    localparam int W = 320, H = 240, SH = 0, H_RES = W << SH, V_RES = H << SH, NMAX = 32, XW = 9, CW = 4;
    localparam int LANE_FIRST = 15, MY0 = 150, MY1 = 176;
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
                      .LANE_FIRST(LANE_FIRST), .DB_TICKS(16)) dut (
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

    // ---- capture ----
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

    // ---- the game state each frame shows: a snapshot at the overlay's frame latch ----
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

    // ---- truth ----
    int truth_v [0:2][0:31]; int truth_n [0:2];
    task automatic read_truth();
        for (int p = 0; p < 3; p++) begin
            int fd, v; string line; byte c;
            truth_n[p] = 0;
            fd = $fopen($sformatf("memory/piano%0d.txt", p), "r");
            if (fd == 0) $fatal(1, "cannot open memory/piano%0d.txt", p);
            while ($fgets(line, fd)) if (line.substr(0, 5) == "edges=") begin
                v = -1;
                for (int i = 6; i < line.len(); i++) begin
                    c = line.getc(i);
                    if (c >= 8'd48 && c <= 8'd57) v = ((v < 0) ? 0 : v * 10) + int'(c) - 48;
                    else if (v >= 0) begin truth_v[p][truth_n[p]] = v; truth_n[p]++; v = -1; end
                end
                if (v >= 0) begin truth_v[p][truth_n[p]] = v; truth_n[p]++; end
            end
            $fclose(fd);
        end
    endtask
    function automatic int iabs(int v); return v < 0 ? -v : v; endfunction

    // the display's copy of the result (after the CDC latch)
    function automatic int d_count(); return int'(dut.d_bcount); endfunction
    function automatic int d_bound(int i); return int'(dut.d_bounds[i*XW +: XW]); endfunction
    function automatic bit d_kept(int i); return dut.d_kept[i]; endfunction
    function automatic int d_l(int i); return int'(dut.d_l[i*XW +: XW]); endfunction
    function automatic int d_r(int i); return int'(dut.d_r[i*XW +: XW]); endfunction

    // wait until a result made entirely with the current switches is on the screen
    task automatic settle();
        repeat (2) @(posedge clk50 iff boundary_valid);
        repeat (3) next_frame();
    endtask

    task automatic check_truth(input int p, input bit must, output bit ok);
        int kept[$], hits, extra, lf;
        string s;
        for (int i = 0; i < d_count(); i++) if (d_kept(i)) kept.push_back(d_bound(i));
        // the display holds exactly what the analysis published (the CDC path)
        if (d_count() != int'(boundary_count)) $fatal(1, "FAIL: the display holds %0d boundaries, the analysis published %0d", d_count(), boundary_count);
        for (int i = 0; i < d_count(); i++) if (d_bound(i) != int'(boundary_x[i])) $fatal(1, "FAIL: boundary %0d differs across the CDC", i);
        hits = 0; extra = 0;
        for (int t = 0; t < truth_n[p]; t++) begin bit h; h = 0; for (int i = 0; i < d_count(); i++) if (iabs(d_bound(i) - truth_v[p][t]) <= 3) h = 1; hits += h; end
        foreach (kept[i]) begin bit n; n = 0; for (int t = 0; t < truth_n[p]; t++) if (iabs(kept[i] - truth_v[p][t]) <= 3) n = 1; if (!n) extra++; end
        lf = (LANE_FIRST != 15) ? LANE_FIRST : (kept.size() >= 5) ? (kept.size() - 5) / 2 : 0;
        s = ""; for (int i = 0; i < d_count(); i++) s = {s, $sformatf(" %0d%s", d_bound(i), d_kept(i) ? "" : "x")};
        $display("    picture %0d mode %0d %s: boundaries%s -> %0d/%0d true found, %0d spurious, lanes %s",
                 p, sw_mode, sw_edge ? "Sobel" : "1-D", s, hits, truth_n[p], extra, lanes_valid ? "valid" : "none");
        ok = (hits == truth_n[p]) && (extra == 0) && lanes_valid;
        if (must && !ok) $fatal(1, "FAIL: picture %0d was not read", p);
        if (must) for (int i = 0; i < 4; i++)
            if (d_l(i) != kept[lf + i] || d_r(i) != kept[lf + i + 1]) $fatal(1, "FAIL: lane %0d is not key %0d", i, lf + i);
    endtask

    task automatic grab(input int view, input string name);
        sw_view = 2'(view);
        repeat (3) next_frame();                             // the view is latched per frame
        if (shown.view != view) $fatal(1, "FAIL: frame shows view %0d, expected %0d", shown.view, view);
        write_ppm(name);
    endtask

    task automatic check_views(input int p);
        int sy;
        sy = MY0 + 1;
        // game view, a still frame (hold the game so the frame and its snapshot agree for the check)
        grab(0, $sformatf("p%0d_view0_game", p));
        for (int i = 0; i < 4; i++) begin
            logic [23:0] c; int x;
            x = d_l(i) + 2; c = cap[sy][x];
            if (shown.flash[i] > 0)    begin if (c[15:8] != 8'd255)                        $fatal(1, "FAIL: lane %0d should flash green: %06h", i, c); end
            else if (shown.window[i])  begin if (c[23:16] != 8'd255 || c[15:8] > 8'd40)     $fatal(1, "FAIL: lane %0d should be red: %06h", i, c); end
            else if (shown.active[i])  begin if (c[7:0] != 8'd0 || c[23:16] <= c[15:8])      $fatal(1, "FAIL: lane %0d should be amber: %06h", i, c); end
            else                       begin if (c[7:0] <= c[23:16])                         $fatal(1, "FAIL: lane %0d should be tinted blue: %06h", i, c); end
        end
        if (cap[MY0 - 20][d_l(0) + 2][23:16] != cap[MY0 - 20][d_l(0) + 2][7:0]) $fatal(1, "FAIL: the picture above the lanes is not grey");
        // edge map: a kept boundary column is bright in the key rows, a key centre is dark
        grab(1, $sformatf("p%0d_view1_edges", p));
        begin
            int eb, ec, kx, cx;
            kx = d_l(1); cx = (d_l(1) + d_r(1)) / 2; eb = 0; ec = 0;
            for (int y = MY0; y <= MY1; y++) begin
                int m; m = 0;
                for (int dx = -3; dx <= 3; dx++) if (int'(cap[y][kx + dx][7:0]) > m) m = int'(cap[y][kx + dx][7:0]);
                eb += m; ec += int'(cap[y][cx][7:0]);
            end
            if (eb <= 3 * ec || eb < 20 * (MY1 - MY0 + 1)) $fatal(1, "FAIL: edge map: boundary %0d vs key centre %0d", eb / (MY1 - MY0 + 1), ec / (MY1 - MY0 + 1));
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
            for (int i = 0; i < 4; i++) if (cap[sy][(d_l(i) + d_r(i)) / 2 + 1] != lc[i]) $fatal(1, "FAIL: mask %0d colour %06h", i, cap[sy][(d_l(i) + d_r(i)) / 2 + 1]);
        end
        sw_view = 0;
    endtask

    initial begin
        bit ok;
        read_truth();
        reset_snaps();
        repeat (4) @(posedge clk50); reset50 = 0; reset25 = 0;
        $display("R-V4 (default: all switches down), Sobel:");
        for (int p = 0; p < 3; p++) begin
            sw_image = 2'(p); settle();
            check_truth(p, 1, ok);
            check_views(p);
        end
        $display("R-V4 with the 1-D detector (SW5 = 0) on the photo:");
        sw_edge = 0; sw_image = 2; settle(); check_truth(2, 1, ok);
        sw_edge = 1;
        $display("R-V3 (SW7..6 = 1): reads the two supplied pianos, not the photo (why R-V4 exists):");
        sw_mode = 1;
        sw_image = 0; settle(); check_truth(0, 1, ok);
        sw_image = 1; settle(); check_truth(1, 1, ok);
        sw_image = 2; settle(); check_truth(2, 0, ok);
        if (ok) $fatal(1, "FAIL: R-V3 read the photo -- the test picture no longer exercises R-V4");
        sw_view = 2; repeat (3) next_frame(); write_ppm("p2_view2_profile_RV3_fails");
        // KEY1 raises the high threshold by one step (8/256): the profile view's red line moves up
        begin
            int hi_before, hi_after;
            hi_before = int'(dut.u_ctrl.hi);
            key_n[1] = 0; repeat (200) @(posedge clk50); key_n[1] = 1; repeat (200) @(posedge clk50);
            hi_after = int'(dut.u_ctrl.hi);
            if (hi_after != hi_before + 8) $fatal(1, "FAIL: KEY1 in R-V3 moved hi from %0d to %0d", hi_before, hi_after);
            $display("    KEY1: high threshold %0d -> %0d", hi_before, hi_after);
            key_n[3] = 0; repeat (200) @(posedge clk50); key_n[3] = 1; repeat (200) @(posedge clk50);
            if (int'(dut.u_ctrl.hi) != 115) $fatal(1, "FAIL: KEY3 did not restore the defaults");
        end
        sw_mode = 0; sw_view = 0;
        // play: several game frames on the photo, checking every one, until a hit has flashed green
        $display("Playing on the photo (R-V4):");
        settle();
        for (int f = 0; f < 80 && green_seen < 2; f++) begin
            next_frame();
            for (int i = 0; i < 4; i++) begin
                logic [23:0] c;
                c = cap[MY0 + 1][d_l(i) + 2];
                if (shown.flash[i] > 0) begin
                    if (c[15:8] != 8'd255) $fatal(1, "FAIL: frame %0d lane %0d should flash green", frames_done, i);
                    if (green_seen == 0) write_ppm("p2_view0_game_hit");
                    green_seen++;
                end else if (shown.window[i] && c[23:16] != 8'd255) $fatal(1, "FAIL: frame %0d lane %0d should be red", frames_done, i);
                else if (shown.window[i] && green_seen == 0 && f > 3) write_ppm("p2_view0_game_sing_now");
            end
        end
        if (green_seen == 0) $fatal(1, "FAIL: no hit was drawn in 80 frames");
        $display("    %0d frames played, hits drawn", base);
        // reset both domains in the middle of a frame
        wait (y_pos == V_RES / 2);
        reset25 = 1; reset50 = 1; repeat (4) @(posedge clk50);
        reset_snaps(); base = frames_done; reset50 = 0; reset25 = 0;
        settle(); check_truth(2, 1, ok);
        $display("    reset mid-frame: recovered");
        if (errors != 0) $fatal(1, "FAIL: the monitor model counted %0d protocol problems", errors);
        $display("PASS: all three pictures read at the default setting, 4 views each, rungs, controls, play, reset; %0d frames, 0 protocol problems", frames_done);
        $display("ALL TESTS PASSED: video_subsystem");
        $finish;
    end
endmodule
