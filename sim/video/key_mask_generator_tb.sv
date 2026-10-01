`timescale 1ns/1ps
/*
 *  key_mask_generator_tb.sv -- boundaries -> spacing -> lattice fit -> four lanes, against the notebook's
 *  template_fit() recomputed by the bench (integer version). Directed cases:
 *    picture 1's list (11 boundaries 30 px apart)            -> lanes = keys 3..6 exactly
 *    the photo's list with the shadow edge at 82              -> 82 dropped, lanes unchanged
 *    a missed boundary (a gap of 2 keys)                      -> kept (d > 1.5 s), lanes still counted on
 *    too few boundaries for LANE_FIRST + 5                    -> lanes_valid = 0
 *    fewer than 3 boundaries, none                            -> no spacing, all kept, no lanes
 *    lane_first = 0 and 5
 *    lane_first = 15 (the default: the four middle keys) on the two supplied pictures' real lists: picture
 *      1 -> keys 2..5 (68..197); picture 2, whose wide last key is off the lattice -> keys 1..4 (61..209);
 *      and on 4 boundaries -> no lanes
 *  Then 300 random lists (sorted, random spacing, random spurious and missing boundaries).
 */
module key_mask_generator_tb;
    localparam int W = 320, NMAX = 32, XW = 9;
    logic clk = 0; always #10 clk = ~clk;
    logic reset = 1, start = 0; logic [3:0] lane_first = 3; logic [5:0] count; logic [4:0] idx; logic [XW-1:0] pos_of;
    logic busy, done, lanes_valid; logic [5:0] bcount, kcount; logic [NMAX*XW-1:0] bounds; logic [NMAX-1:0] kept_mask;
    logic [XW-1:0] spacing; logic [4*XW-1:0] lane_l, lane_r;
    int list[$];
    assign pos_of = XW'((int'(idx) < list.size()) ? list[idx] : 0);
    key_mask_generator #(.W(W), .NMAX(NMAX)) dut (.*);

    int keep[$], keepmask[$], s;
    task automatic reference();
        int d[$];
        keep.delete(); keepmask.delete(); s = 0;
        foreach (list[i]) keepmask.push_back(0);
        if (list.size() == 0) return;
        if (list.size() < 3) begin foreach (list[i]) begin keep.push_back(list[i]); keepmask[i] = 1; end return; end
        for (int i = 0; i + 1 < list.size(); i++) d.push_back(list[i+1] - list[i]);
        d.sort(); s = d[(d.size() - 1) / 2];
        keep.push_back(list[0]); keepmask[0] = 1;
        for (int i = 1; i < list.size(); i++) begin
            int dd, dev;
            dd = list[i] - keep[$]; dev = (dd > s) ? dd - s : s - dd;
            if (dev < (s >> 2) || 2 * dd > 3 * s) begin keep.push_back(list[i]); keepmask[i] = 1; end
        end
    endtask

    int lf;
    task automatic run(input string what);
        count = 6'(list.size());
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        wait (done); @(negedge clk);
        reference();
        if (int'(bcount) != list.size()) $fatal(1, "FAIL %s: bcount %0d", what, bcount);
        foreach (list[i]) if (int'(bounds[i*XW +: XW]) != list[i]) $fatal(1, "FAIL %s: bounds[%0d]", what, i);
        if (int'(spacing) != s) $fatal(1, "FAIL %s: spacing %0d, expected %0d", what, spacing, s);
        if (int'(kcount) != keep.size()) $fatal(1, "FAIL %s: %0d kept, expected %0d", what, kcount, keep.size());
        foreach (keepmask[i]) if (kept_mask[i] != keepmask[i][0]) $fatal(1, "FAIL %s: kept flag %0d", what, i);
        lf = (lane_first != 4'hF) ? int'(lane_first) : (keep.size() >= 5) ? (keep.size() - 5) / 2 : 0;
        if (int'(lanes_valid) != int'(keep.size() >= lf + 5)) $fatal(1, "FAIL %s: lanes_valid = %0d", what, lanes_valid);
        if (lanes_valid) for (int i = 0; i < 4; i++) begin
            int el, er;
            el = keep[lf + i]; er = keep[lf + i + 1];
            if (int'(lane_l[i*XW +: XW]) != el || int'(lane_r[i*XW +: XW]) != er)
                $fatal(1, "FAIL %s: lane %0d = [%0d, %0d], expected [%0d, %0d]", what, i, lane_l[i*XW +: XW], lane_r[i*XW +: XW], el, er);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk); reset = 0;
        list = '{12, 38, 68, 98, 128, 158, 188, 218, 248, 278, 308};            run("picture 1");
        if (lane_l[XW-1:0] != 98 || lane_r[4*XW-1 -: XW] != 218) $fatal(1, "FAIL: picture 1 lanes are not keys 3..6");
        list = '{12, 41, 71, 82, 102, 132, 161, 192, 222, 252, 281, 308};       run("photo with shadow edge");
        if (kept_mask[3] || lane_l[XW-1:0] != 102) $fatal(1, "FAIL: the shadow edge at 82 was not dropped");
        list = '{10, 40, 70, 100, 160, 190, 220, 250};                          run("missed boundary");
        if (!kept_mask[4]) $fatal(1, "FAIL: the boundary after a missed one was dropped");
        list = '{10, 40, 70, 100, 130, 160, 190};                               run("too few for 4 lanes");
        if (lanes_valid) $fatal(1, "FAIL: lanes from 7 boundaries with LANE_FIRST = 3");
        list = '{50, 90};                                                        run("two");
        list = {};                                                               run("none");
        lane_first = 0; list = '{10, 40, 70, 100, 130};                          run("lane_first 0");
        lane_first = 5; list = '{17, 39, 61, 83, 105, 127, 149, 171, 193, 215, 237, 259, 281, 303}; run("lane_first 5, picture 2");
        lane_first = 15; list = '{9, 35, 68, 100, 133, 165, 197, 229, 261, 293, 309}; run("middle keys, supplied picture 1");
        if (!lanes_valid || lane_l[XW-1:0] != 68 || lane_r[4*XW-1 -: XW] != 197) $fatal(1, "FAIL: picture 1 middle lanes are not 68..197");
        list = '{20, 61, 100, 137, 171, 209, 250, 299};                          run("middle keys, supplied picture 2");
        if (kept_mask[7] || !lanes_valid || lane_l[XW-1:0] != 61 || lane_r[4*XW-1 -: XW] != 209) $fatal(1, "FAIL: picture 2 middle lanes are not 61..209");
        list = '{10, 40, 70, 100};                                               run("middle keys, too few");
        if (lanes_valid) $fatal(1, "FAIL: lanes from 4 boundaries");
        $display("PASS: directed lists (lattice, shadow edge, missed boundary, too few, lane_first, middle keys)");
        for (int k = 0; k < 300; k++) begin
            int x, sp, n;
            lane_first = ($urandom % 4 == 0) ? 4'hF : 4'($urandom % 6);
            list.delete(); sp = 12 + $urandom % 30; x = $urandom % 20; n = 0;
            while (x < W && n < NMAX) begin
                int j;
                if ($urandom % 10 != 0) begin list.push_back(x); n++; end                  // sometimes missed
                if ($urandom % 8 == 0 && n < NMAX && x + sp / 3 < W) begin list.push_back(x + 1 + $urandom % (sp / 3)); n++; end   // spurious
                j = int'($urandom % 5) - 2;
                x = x + sp + j;
            end
            begin int tmp[$]; tmp = list; tmp.sort(); list = tmp; end
            run($sformatf("random %0d", k));
        end
        $display("PASS: 300 random boundary lists");
        $display("ALL TESTS PASSED: key_mask_generator");
        $finish;
    end
endmodule
