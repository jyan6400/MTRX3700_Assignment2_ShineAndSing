`timescale 1ns/1ps
/*
 *  video_analysis.sv -- the key finder: every image-processing stage of R-V0..R-V4, in the 50 MHz
 *  analysis clock domain.  (NEW, Advay: the A2 successor of Mini-Project 2's barcode_reader.sv, with
 *  the bar decoder removed and the R-V2..R-V4 stages added.)
 *
 *    image ROM -> raster_source -> [smoothing conv3x3, R-V4] -> hdiff (SW5=0) | sobel (SW5=1)
 *              -> col_profile (rows Y0..Y1) -> profile_normalise -> local_threshold
 *              -> picker selected by `mode` -> key_mask_generator -> result bundle (-> cdc_latch)
 *
 *    mode  rung   picker                                                    smoothing  min_gap
 *     0    R-V4   hysteresis_profile, hi/lo from the local average (+floor)  yes        8
 *     1    R-V3   hysteresis_profile, constant hi/lo on the normalised profile no       10
 *     2    R-V2   peak_pick on the raw profile, absolute threshold            no        8
 *     3    R-V1   pick_runs on the raw profile, absolute threshold            no        8
 *  (SW5 picks the edge detector in every mode; R-V1 is "1-D + pick_runs", R-V2 "Sobel + peak_pick".)
 *  The absolute threshold is given in 1-D units and multiplied by 4 for Sobel (the gain of its 1-2-1
 *  weights, as in the barcode workspace), so one setting serves both detectors (default 2048 x 4 = 8192).
 *
 *  Rows Y0..Y1 = 150..176: below the black keys and above the bottom of the white keys in BOTH supplied
 *  pictures (picture 1's white keys run to row 216, picture 2's -- letterboxed -- only to row 179,
 *  under which is the dark frame), with a row of margin for the 3x3 windows.
 *
 *  Latency / positions: every convolution stage carries the CENTRE coordinates of its output with the
 *  value (conv3x3's out_x/out_y, hdiff's out_x/out_y), so the column profile is indexed by the true
 *  picture column whatever the pipeline delay: that is how the Sobel and smoothing delays are
 *  accounted for in the boundary positions. With smoothing on, the Sobel window at centres x = 1,
 *  x = W-2, y = 1 and y = H-2 would include a column/row the smoothing stage never produced, so those
 *  centres are masked out (the smoothed picture's own border).
 *
 *  col_profile's X_LAST is W-4: the last column that arrives in every mode is W-2 (1-D), W-2
 *  (Sobel), W-3 (smoothed Sobel); `done` fires at most 2 clocks before those columns are written, and
 *  profile_normalise reads them W-3 clocks later.
 *
 *  Timing budget per sweep (W = 320, H = 240): a sweep is 76 800 + GAP clocks (1.6 ms). After the
 *  profile's last row (Y1 = 176) the post-processing takes about 5 000 clocks (normalise 4 200, the
 *  threshold 340, the picker 330..450, the key masks < 100), finishing long before the next sweep
 *  reaches row Y0 (and before its frame_start flips the profile's tag, 22 000 clocks away).
 *
 *  Controls (mode, edge_sel) are latched at the start of each sweep, the thresholds when the
 *  post-processing starts, so a result is always from one consistent setting. They arrive already in
 *  this clock domain (video_subsystem synchronises the switches; video_controls runs on this clock).
 */
module video_analysis #(
    parameter int W    = assignment2_pkg::IMG_W,
    parameter int H    = assignment2_pkg::IMG_H,
    parameter int NMAX = 32,
    parameter int NC   = 64,
    parameter int AW   = 20,
    parameter int NW   = 9,
    parameter int Y0   = 150,
    parameter int Y1   = 176,
    parameter int GAP  = 2048,
    parameter int GAP_RV3 = 10,
    parameter int GAP_RV4 = 8
) (
    input  logic                       clk,
    input  logic                       reset,
    // the picture (one read port of the selected image ROM: address out, pixel one clock later)
    output logic [$clog2(W*H)-1:0]     rom_addr,
    input  logic [7:0]                 rom_q,
    // controls
    input  logic                       edge_sel,     // 0 = 1-D difference, 1 = Sobel   (SW5)
    input  logic [1:0]                 mode,         // picker / rung, table above      (SW7..SW6)
    input  logic [NW-1:0]              hi,
    input  logic [NW-1:0]              lo,
    input  logic [NW-1:0]              floor_lvl,
    input  logic [7:0]                 k_q,
    input  logic [AW-1:0]              thr_abs,      // R-V1/R-V2, in 1-D units (x4 for Sobel)
    input  logic [3:0]                 lane_first,
    // results: stable from one result_valid pulse to the next
    output logic                       result_valid,
    output logic [$clog2(NMAX):0]      res_bcount,
    output logic [NMAX*$clog2(W)-1:0]  res_bounds,
    output logic [NMAX-1:0]            res_kept,
    output logic [$clog2(NMAX):0]      res_kcount,
    output logic [$clog2(W)-1:0]       res_spacing,
    output logic                       res_lanes_valid,
    output logic [4*$clog2(W)-1:0]     res_lane_l,
    output logic [4*$clog2(W)-1:0]     res_lane_r,
    output logic [1:0]                 res_mode,
    output logic                       res_edge_sel,
    output logic [AW-1:0]              res_max,
    output logic                       res_overflow,
    // the edge map, for the display's view 1 (one write per edge-detector output pixel)
    output logic                       ew_en,
    output logic [$clog2(W*H)-1:0]     ew_addr,
    output logic [3:0]                 ew_data,
    // the profile view: (x, {lo, hi, n}) once per column per result
    output logic                       pw_en,
    output logic [$clog2(W)-1:0]       pw_x,
    output logic [3*NW-1:0]            pw_data
);
    localparam int XW = $clog2(W);
    localparam int YW = $clog2(H);
    localparam int IW = $clog2(NMAX);

    // ------------------------------------------------------------------ sweep
    logic frame_start, px_valid; logic [7:0] px; logic [XW-1:0] px_x; logic [YW-1:0] px_y;
    raster_source #(.W(W), .H(H), .GAP(GAP)) u_src (.clk, .reset, .rom_addr, .rom_q, .frame_start,
        .out_valid(px_valid), .out_pixel(px), .out_x(px_x), .out_y(px_y));

    logic [1:0] cfg_mode;  logic cfg_edge;
    always_ff @(posedge clk)
        if (reset) begin cfg_mode <= 2'd0; cfg_edge <= 1'b1; end
        else if (frame_start) begin cfg_mode <= mode; cfg_edge <= edge_sel; end
    logic smooth_on;
    assign smooth_on = (cfg_mode == 2'd0);

    // ------------------------------------------------------------------ R-V4 smoothing (conv3x3, 2nd table)
    logic g_valid; logic signed [12:0] g_val; logic [XW-1:0] g_x; logic [YW-1:0] g_y;
    conv3x3 #(.W(W), .H(H), .DW(8), .OW(13),
              .K('{'{8'sd1, 8'sd2, 8'sd1}, '{8'sd2, 8'sd4, 8'sd2}, '{8'sd1, 8'sd2, 8'sd1}})) u_smooth (
        .clk, .reset, .in_valid(px_valid), .in_pixel(px), .in_x(px_x), .in_y(px_y),
        .out_valid(g_valid), .out_val(g_val), .out_x(g_x), .out_y(g_y));

    logic s_valid; logic [7:0] s_pix; logic [XW-1:0] s_x; logic [YW-1:0] s_y;
    always_comb begin
        if (smooth_on) begin s_valid = g_valid;  s_pix = g_val[11:4]; s_x = g_x;  s_y = g_y;  end   // /16, 0..255
        else           begin s_valid = px_valid; s_pix = px;          s_x = px_x; s_y = px_y; end
    end

    // ------------------------------------------------------------------ edge detectors (both run; SW5 selects)
    logic sb_valid; logic [11:0] sb_gx, sb_gy; logic [12:0] sb_mag; logic [XW-1:0] sb_x; logic [YW-1:0] sb_y;
    sobel #(.W(W), .H(H)) u_sobel (.clk, .reset, .in_valid(s_valid), .in_pixel(s_pix), .in_x(s_x), .in_y(s_y),
        .out_valid(sb_valid), .out_gx(sb_gx), .out_gy(sb_gy), .out_mag(sb_mag), .out_x(sb_x), .out_y(sb_y));
    logic hd_valid; logic [7:0] hd_val; logic [XW-1:0] hd_x; logic [YW-1:0] hd_y;
    hdiff #(.W(W), .H(H)) u_hdiff (.clk, .reset, .in_valid(s_valid), .in_pixel(s_pix), .in_x(s_x), .in_y(s_y),
        .out_valid(hd_valid), .out_val(hd_val), .out_x(hd_x), .out_y(hd_y));

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

    // the edge map for view 1: 4 bits per pixel
    always_ff @(posedge clk) begin
        ew_en   <= e_valid && !reset;
        ew_addr <= ($clog2(W*H))'(e_y) * ($clog2(W*H))'(W) + ($clog2(W*H))'(e_x);
        ew_data <= e_show[7:4];
    end

    // ------------------------------------------------------------------ column profile
    logic prof_done; logic [XW-1:0] prof_rd_x; logic [AW-1:0] prof_rd_val;
    col_profile #(.W(W), .H(H), .VW(12), .AW(AW), .Y0(Y0), .Y1(Y1), .X_LAST(W-4)) u_prof (
        .clk, .reset, .in_valid(e_valid), .in_val(e_val), .in_x(e_x), .in_y(e_y), .frame_start,
        .done(prof_done), .rd_x(prof_rd_x), .rd_val(prof_rd_val));

    // latched per result
    logic [1:0] r_mode; logic r_edge;
    logic [NW-1:0] r_hi, r_lo, r_floor; logic [7:0] r_kq; logic [AW-1:0] r_abs; logic [3:0] r_lane_first;
    logic [XW-1:0] r_gap;

    // ------------------------------------------------------------------ R-V3: normalise
    logic nz_start, nz_busy, nz_done; logic [XW-1:0] nz_src_x, nz_rd_x; logic [NW-1:0] nz_rd_val, thr_n;
    logic [AW-1:0] max_val; logic nz_wr; logic [XW-1:0] nz_wx; logic [NW-1:0] nz_wv;
    profile_normalise #(.W(W), .AW(AW), .NW(NW)) u_norm (.clk, .reset, .start(nz_start), .thr_abs(r_abs),
        .src_rd_x(nz_src_x), .src_rd_val(prof_val), .busy(nz_busy), .done(nz_done), .max_val, .thr_n,
        .out_wr(nz_wr), .out_x(nz_wx), .out_val(nz_wv), .rd_x(nz_rd_x), .rd_val(nz_rd_val));

    // ------------------------------------------------------------------ R-V4: local threshold
    logic lt_start, lt_busy, lt_done; logic [XW-1:0] lt_src_x, lt_rd_x; logic [NW-1:0] lt_rd_val;
    local_threshold #(.W(W), .NW(NW), .TW(NW), .HALF(12)) u_lthr (.clk, .reset, .start(lt_start), .k_q(r_kq),
        .src_rd_x(lt_src_x), .src_rd_val(nz_rd_val), .busy(lt_busy), .done(lt_done),
        .rd_x(lt_rd_x), .rd_val(lt_rd_val));

    // ------------------------------------------------------------------ pickers
    logic hy_start, hy_busy, hy_done, hy_ovf; logic [XW-1:0] hy_rd_x; logic [$clog2(NMAX):0] hy_count;
    logic [IW-1:0] km_idx; logic [XW-1:0] hy_pos;
    logic hy_dwr; logic [XW-1:0] hy_dx; logic [NW-1:0] hy_dn, hy_dhi, hy_dlo;
    hysteresis_profile #(.W(W), .NW(NW), .NC(NC), .NMAX(NMAX)) u_hyst (.clk, .reset, .start(hy_start),
        .adaptive(r_mode == 2'd0), .hi(r_hi), .lo(r_lo), .floor_lvl(r_floor), .min_gap(r_gap),
        .rd_x(hy_rd_x), .n_val(nz_rd_val), .t_val(lt_rd_val),
        .busy(hy_busy), .done(hy_done), .count(hy_count), .idx(km_idx), .pos_of(hy_pos), .cand_overflow(hy_ovf),
        .dsp_wr(hy_dwr), .dsp_x(hy_dx), .dsp_n(hy_dn), .dsp_hi(hy_dhi), .dsp_lo(hy_dlo));

    logic pk_start, pk_busy, pk_done; logic [XW-1:0] pk_rd_x, pk_pos; logic [$clog2(NMAX):0] pk_count;
    peak_pick #(.W(W), .AW(AW), .NMAX(NMAX)) u_peak (.clk, .reset, .start(pk_start), .thr(r_abs), .min_gap(r_gap),
        .rd_x(pk_rd_x), .rd_val(prof_val), .busy(pk_busy), .done(pk_done), .count(pk_count), .idx(km_idx), .pos_of(pk_pos));

    logic pr_start, pr_busy, pr_done; logic [XW-1:0] pr_rd_x, pr_pos; logic [$clog2(NMAX):0] pr_count;
    pick_runs #(.W(W), .AW(AW), .NMAX(NMAX)) u_runs (.clk, .reset, .start(pr_start), .thr(r_abs), .min_gap(r_gap),
        .rd_x(pr_rd_x), .rd_val(prof_val), .busy(pr_busy), .done(pr_done), .count(pr_count), .idx(km_idx), .pos_of(pr_pos));

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
    always_ff @(posedge clk) prof_rd_x_q <= prof_rd_x;
    assign prof_val = ((int'(prof_rd_x_q) >= col_lo) && (int'(prof_rd_x_q) <= col_hi)) ? prof_rd_val : '0;

    // read-port sharing: the profile RAM (normalise, then one raw picker), the normalised RAM
    // (local threshold, then hysteresis); the threshold RAM is read by hysteresis only
    assign prof_rd_x = nz_busy ? nz_src_x : (pk_busy ? pk_rd_x : pr_rd_x);
    assign nz_rd_x   = lt_busy ? lt_src_x : hy_rd_x;
    assign lt_rd_x   = hy_rd_x;

    // ------------------------------------------------------------------ key masks
    logic km_start, km_busy, km_done; logic [$clog2(NMAX):0] sel_count; logic [XW-1:0] sel_pos;
    logic [$clog2(NMAX):0] km_bcount, km_kcount; logic [NMAX*XW-1:0] km_bounds; logic [NMAX-1:0] km_kept;
    logic [XW-1:0] km_spacing; logic km_lanes_valid; logic [4*XW-1:0] km_l, km_r;
    always_comb begin
        case (r_mode)
            2'd2:    begin sel_count = pk_count; sel_pos = pk_pos; end
            2'd3:    begin sel_count = pr_count; sel_pos = pr_pos; end
            default: begin sel_count = hy_count; sel_pos = hy_pos; end
        endcase
    end
    key_mask_generator #(.W(W), .NMAX(NMAX)) u_keys (.clk, .reset, .start(km_start), .lane_first(r_lane_first),
        .count(sel_count), .idx(km_idx), .pos_of(sel_pos), .busy(km_busy), .done(km_done),
        .bcount(km_bcount), .bounds(km_bounds), .kept_mask(km_kept), .kcount(km_kcount), .spacing(km_spacing),
        .lanes_valid(km_lanes_valid), .lane_l(km_l), .lane_r(km_r));

    // ------------------------------------------------------------------ sequencer
    typedef enum logic [2:0] {P_IDLE, P_NORM, P_THR, P_HYST, P_KEYS, P_PUB} pstate_t;
    pstate_t ps;
    logic lt_fin, pick_fin;
    always_ff @(posedge clk) begin
        nz_start <= 1'b0; lt_start <= 1'b0; hy_start <= 1'b0; pk_start <= 1'b0; pr_start <= 1'b0;
        km_start <= 1'b0; result_valid <= 1'b0;
        if (reset) begin
            ps <= P_IDLE; res_bcount <= '0; res_lanes_valid <= 1'b0; res_kcount <= '0; res_kept <= '0;
            res_bounds <= '0; res_lane_l <= '0; res_lane_r <= '0; res_spacing <= '0; res_mode <= '0;
            res_edge_sel <= 1'b1; res_max <= '0; res_overflow <= 1'b0;
        end else case (ps)
            P_IDLE: if (prof_done) begin
                r_mode <= cfg_mode; r_edge <= cfg_edge;
                r_hi <= hi; r_lo <= lo; r_floor <= floor_lvl; r_kq <= k_q;
                // Sobel's 1-2-1 weights give 4x the 1-D difference on a clean edge: one setting, both detectors
                r_abs <= cfg_edge ? (thr_abs << 2) : thr_abs;
                r_lane_first <= lane_first;
                r_gap <= (cfg_mode == 2'd1) ? XW'(GAP_RV3) : XW'(GAP_RV4);
                nz_start <= 1'b1;
                ps <= P_NORM;
            end
            P_NORM: if (nz_done) begin
                lt_start <= 1'b1;
                pk_start <= (r_mode == 2'd2);
                pr_start <= (r_mode == 2'd3);
                lt_fin <= 1'b0; pick_fin <= !(r_mode[1]);
                ps <= P_THR;
            end
            P_THR: begin
                if (lt_done) lt_fin <= 1'b1;
                if (pk_done || pr_done) pick_fin <= 1'b1;
                if ((lt_fin || lt_done) && (pick_fin || pk_done || pr_done)) begin
                    hy_start <= 1'b1;                // always run: it also streams the profile view
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

    // outputs of reused/new blocks that this wrapper does not need
    logic unused_ok;
    assign unused_ok = &{1'b0, g_val[12], g_val[3:0], sb_gy, sb_mag[1:0], e_show[3:0], nz_wr, nz_wx, nz_wv,
                         hy_busy, pr_busy, km_busy};

    // ------------------------------------------------------------------ the profile view stream
    // normalised profile with the thresholds the picker used: hi(x)/lo(x) from hysteresis (R-V3/R-V4),
    // the absolute threshold in the same units (R-V1/R-V2, a single line)
    always_ff @(posedge clk) begin
        pw_en   <= hy_dwr && !reset;
        pw_x    <= hy_dx;
        pw_data <= r_mode[1] ? {{NW{1'b0}}, thr_n, hy_dn} : {hy_dlo, hy_dhi, hy_dn};
    end
endmodule
