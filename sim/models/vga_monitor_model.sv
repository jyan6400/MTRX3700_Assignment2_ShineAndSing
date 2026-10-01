`timescale 1ns/1ps
/*
 *  REUSED SIMULATION MODEL -- Lesson 3 vga-face workspace, vga_monitor_model.sv. CHANGES: none.
 */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off IMPLICITSTATIC */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off BLKSEQ */
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off SYNCASYNCNET */
// (This file is a simulation model. It is never synthesised, so the lint rules
//  that matter for synthesisable code are relaxed to keep your terminal clean.)
/*
 * ============================================================================
 *  vga_monitor_model.sv  --  Sim model of the University Program "VGA
 *                            Controller" IP core plus the monitor behind it
 * ============================================================================
 *
 *  WHAT IS THIS?
 *  -------------
 *  In hardware, your Avalon-ST source feeds the VGA Controller IP, which feeds
 *  the VGA DAC, which feeds a monitor. None of those three can be simulated by
 *  Verilator as-is (the IP uses Altera memory primitives, the DAC and monitor
 *  are not Verilog at all). This model replaces the whole chain:
 *
 *      your module ==Avalon-ST==> [ VGA Controller ] ==> [ monitor ]
 *                                  ready pattern         frame buffer,
 *                                  sop/eop handling      picture output
 *
 *  It behaves like the real controller (read from the IP's source):
 *    - After reset it sits in a SYNC_FRAME state waiting for `startofpacket`.
 *      While waiting it *consumes and discards* every pixel that arrives
 *      without startofpacket (ready = valid & ~startofpacket). So a source that
 *      never asserts startofpacket, or asserts it late, loses pixels.
 *    - Once the first pixel of a frame is seen it switches to DISPLAY and
 *      accepts one pixel per pixel-clock during the *active* part of the
 *      raster only. During horizontal blanking (H_BLANK clocks per line) and
 *      vertical blanking (V_BLANK lines per frame) `ready` is low. That is the
 *      real back-pressure your source must survive: bursts of 640 accepted
 *      pixels then 160 cycles of nothing, then 45 lines of nothing.
 *    - After the last active pixel it goes back to SYNC_FRAME and waits for the
 *      next startofpacket. A source whose pixel counter did not wrap to 0 keeps
 *      sending pixels without startofpacket, and the screen freezes.
 *
 *  Each accepted pixel is stored *where the beam is* (x,y from the raster
 *  counters), exactly as a monitor would show it. When a frame completes the
 *  model prints it to the terminal as coloured block art and (optionally)
 *  writes it to a .ppm image file you can open, so you SEE what the monitor
 *  would show: a face, a torn face, a shifted face, or nothing.
 *
 *  It also checks the Avalon-ST rules on the way:
 *    - `data` must not change while valid=1 and ready=0 (the transfer has not
 *      happened yet; changing data means a pixel was skipped),
 *    - `endofpacket` must be on the last active pixel, `startofpacket` on the
 *      first,
 *    - `valid` should not drop during active video (the monitor shows garbage
 *      for that pixel; the real core keeps scanning regardless).
 *
 *  The resolution is a parameter so you can simulate a small frame (e.g. 80x60)
 *  in seconds, exactly like overriding a millisecond counter's limit to make
 *  a 50 MHz simulation feasible. The blanking sizes scale with it.
 * ============================================================================
 */
module vga_monitor_model #(
    parameter int    H_RES   = 640,
    parameter int    V_RES   = 480,
    parameter int    H_BLANK = 160,        // pixel clocks of horizontal blanking per line (640x480: 160)
    parameter int    V_BLANK = 45,         // lines of vertical blanking per frame (640x480: 45)
    parameter int    RANDOM_STALL_PCT = 0, // extra random cycles with ready=0 during active video (0..100)
    parameter bit    ASCII_ART = 1,        // print each completed frame to the terminal
    parameter int    ASCII_COLS = 80,      // width of the terminal picture in characters
    parameter bit    COLOUR = 1,           // ANSI colours (set 0 for plain characters)
    parameter string PPM_PREFIX = "frame", // write frame_<n>.ppm files ("" = no files)
    parameter int    MAX_PPM_FILES = 8,
    parameter bit    VERBOSE = 1
) (
    input  logic        clk,        // pixel clock (the VGA Controller runs at 25 MHz for 640x480)
    input  logic        reset,
    // Avalon-ST sink
    input  logic [29:0] data,
    input  logic        startofpacket,
    input  logic        endofpacket,
    input  logic        valid,
    output logic        ready,
    // Observation hooks (for testbenches and marking)
    output int          frames_done,      // completed frames
    output int          errors,           // protocol problems counted
    output int          x_pos,            // raster position of the pixel being accepted this cycle
    output int          y_pos,
    output logic        accept,           // 1 when a pixel is accepted into active video this cycle
    output logic        discard           // 1 when a pixel is consumed and thrown away while waiting for startofpacket
);
    localparam int H_TOTAL = H_RES + H_BLANK;
    localparam int V_TOTAL = V_RES + V_BLANK;
    localparam int N_PIX   = H_RES * V_RES;

    // ---- the frame buffer ("the monitor") --------------------------------------
    logic [23:0] frame [0:N_PIX-1];     // RGB888 of what the screen shows
    logic        frame_written [0:N_PIX-1];
    int          discarded_this_wait = 0;
    int          sop_at_x = -1, sop_at_y = -1;
    int          eop_count = 0, eop_x = -1, eop_y = -1;
    int          missed_pixels = 0;      // active pixels where valid was low
    logic        last_eop = 1'b0;        // endofpacket was seen on the last pixel of the frame
    int          held_violations = 0;    // data changed while valid && !ready

    // ---- raster counters, free running like the real core ------------------------
    int px = 0, ln = 0;
    typedef enum logic {SYNC_FRAME, DISPLAY} mode_t;
    mode_t mode = SYNC_FRAME;
    logic active_region;
    assign active_region = (px < H_RES) && (ln < V_RES);

    logic random_stall = 1'b0;
    always @(posedge clk) random_stall <= (RANDOM_STALL_PCT > 0) && (($urandom() % 100) < RANDOM_STALL_PCT);

    // ready: exactly like altera_up_avalon_video_vga_controller.
    assign ready  = (mode == SYNC_FRAME) ? (valid & ~startofpacket)
                                         : (active_region & ~random_stall);
    assign accept  = (mode == DISPLAY) && ready && valid;
    assign discard = (mode == SYNC_FRAME) && ready && valid;
    assign x_pos = px;
    assign y_pos = ln;

    function automatic logic [23:0] to_rgb(input logic [29:0] d);
        return {d[29:22], d[19:12], d[9:2]};
    endfunction

    // Hold check: remember the data offered while stalled.
    logic [29:0] held_data; logic held_valid = 1'b0;
    logic complete_pending = 1'b0;   // last pixel accepted; report on the next clock so the buffer is up to date

    task automatic clear_frame();
        for (int i = 0; i < N_PIX; i++) begin frame[i] = 24'h000000; frame_written[i] = 1'b0; end
    endtask
    initial begin
        clear_frame();
        frames_done = 0; errors = 0;
    end

    always @(posedge clk) begin
        if (reset) begin
            px <= 0; ln <= 0; mode <= SYNC_FRAME; held_valid <= 1'b0;
            discarded_this_wait <= 0; eop_count <= 0; missed_pixels <= 0;
        end else begin
            if (complete_pending) begin
                complete_pending <= 1'b0;
                frame_complete();
            end
            // --- Avalon-ST hold rule --------------------------------------------------
            if (valid && !ready) begin
                if (held_valid && data != held_data) begin
                    held_violations++; errors++;
                    if (held_violations <= 5)
                        $display("[VGA @%0t] ERROR: data changed from %h to %h while valid=1 and ready=0. No transfer happened, so the source must keep offering the same pixel until ready is high (only advance on a handshake: valid && ready).",
                                 $time, held_data, data);
                end
                held_data <= data; held_valid <= 1'b1;
            end else begin
                held_valid <= 1'b0;
            end

            // --- controller state machine ----------------------------------------------
            case (mode)
            SYNC_FRAME: begin
                if (valid && startofpacket) begin
                    mode <= DISPLAY;
                    if (discarded_this_wait > 0) begin
                        errors++;
                        $display("[VGA @%0t] ERROR: %0d pixel(s) arrived without startofpacket and were thrown away before the frame started. startofpacket must be high together with the FIRST pixel of every frame.",
                                 $time, discarded_this_wait);
                    end
                    discarded_this_wait <= 0;
                    // In the real core the raster restarts with the first accepted pixel at (0,0):
                    px <= 0; ln <= 0;
                    eop_count <= 0; missed_pixels <= 0;
                end else if (valid) begin
                    discarded_this_wait <= discarded_this_wait + 1;
                    if (discarded_this_wait + 1 == N_PIX) begin
                        errors++;
                        $display("[VGA @%0t] ERROR: a whole frame's worth of pixels (%0d) arrived without startofpacket and was thrown away. The controller waits for startofpacket before every frame, so the screen is frozen. After the last pixel (index %0d) the index must wrap to 0 and startofpacket must be high again.",
                                 $time, N_PIX, N_PIX - 1);
                    end
                end
            end
            DISPLAY: begin
                // Raster advance. A random stall models back-pressure from further up
                // the pipeline (a FIFO or another core), so the beam pauses with it:
                // the pixel-to-position mapping stays one to one.
                if (!(active_region && random_stall)) begin
                    if (px == H_TOTAL - 1) begin
                        px <= 0;
                        ln <= (ln == V_TOTAL - 1) ? 0 : ln + 1;
                    end else px <= px + 1;
                end

                if (active_region && !random_stall) begin
                    if (ready && valid) begin
                        frame[ln * H_RES + px]         <= to_rgb(data);
                        frame_written[ln * H_RES + px] <= 1'b1;
                        if (startofpacket && !(px == 0 && ln == 0)) begin
                            errors++;
                            $display("[VGA @%0t] ERROR: startofpacket seen at pixel (x=%0d, y=%0d), but it must only be high on the first pixel of a frame (0,0). Did the pixel index wrap back to 0 too early?",
                                     $time, px, ln);
                        end
                        if (endofpacket) begin
                            eop_count <= eop_count + 1;
                            if (!(px == H_RES - 1 && ln == V_RES - 1)) begin
                                errors++;
                                $display("[VGA @%0t] ERROR: endofpacket seen at pixel (x=%0d, y=%0d) = pixel #%0d, but the frame has %0d pixels so it belongs on pixel #%0d (x=%0d, y=%0d).",
                                         $time, px, ln, ln * H_RES + px, N_PIX, N_PIX - 1, H_RES - 1, V_RES - 1);
                            end
                        end
                    end else begin
                        // The beam is in active video but no pixel was offered: the screen shows junk here.
                        missed_pixels <= missed_pixels + 1;
                        frame_written[ln * H_RES + px] <= 1'b0;
                    end
                    // Last active pixel of the frame: back to waiting for startofpacket.
                    if (px == H_RES - 1 && ln == V_RES - 1) begin
                        mode <= SYNC_FRAME;
                        complete_pending <= 1'b1;
                        last_eop <= valid && ready && endofpacket;
                    end
                end
            end
            endcase
        end
    end

    // ---- frame completion: report + picture -------------------------------------------
    task automatic frame_complete();
        int written = 0;
        frames_done++;
        for (int i = 0; i < N_PIX; i++) if (frame_written[i]) written++;
        if (!last_eop) begin
            errors++;
            $display("[VGA @%0t] ERROR: frame %0d: endofpacket was not high on the last pixel (index %0d). Assert endofpacket together with the last pixel of the frame.", $time, frames_done, N_PIX - 1);
        end
        if (missed_pixels > 0) begin
            errors++;
            $display("[VGA @%0t] ERROR: frame %0d: valid was low for %0d active pixel(s); the monitor shows garbage there and the rest of the image is shifted.", $time, frames_done, missed_pixels);
        end
        if (VERBOSE)
            $display("[VGA @%0t] frame %0d complete: %0d of %0d pixels received.", $time, frames_done, written, N_PIX);
        if (ASCII_ART) print_frame();
        if (PPM_PREFIX != "" && frames_done <= MAX_PPM_FILES) write_ppm($sformatf("%s_%0d.ppm", PPM_PREFIX, frames_done));
        // The next frame starts from a "black" screen so stale pixels are obvious.
        clear_frame();
    endtask

    // ---- terminal picture: 2 pixel rows per text row using the upper-half block ------
    function automatic int ansi_index(input logic [23:0] c);
        // 3-bit colour -> ANSI 0..7 (bit0 = red, bit1 = green, bit2 = blue)
        return (c[23] ? 1 : 0) | (c[15] ? 2 : 0) | (c[7] ? 4 : 0);
    endfunction

    function automatic string dashes(input int n);
        string s = "";
        for (int i = 0; i < n; i++) s = {s, "-"};
        return s;
    endfunction

    task automatic print_frame();
        int cols = (ASCII_COLS < H_RES) ? ASCII_COLS : H_RES;
        int rows = (V_RES * cols) / H_RES;       // keep the aspect ratio (a text cell is ~2:1)
        string line;
        if (rows < 2) rows = 2;
        $display("+%s+", dashes(cols));
        for (int r = 0; r < rows; r += 2) begin
            line = "|";
            for (int c = 0; c < cols; c++) begin
                automatic int x  = (c * H_RES) / cols;
                automatic int y0 = (r * V_RES) / rows;
                automatic int y1 = ((r + 1) * V_RES) / rows;
                automatic logic [23:0] top = frame[y0 * H_RES + x];
                automatic logic [23:0] bot = frame[(y1 < V_RES ? y1 : V_RES - 1) * H_RES + x];
                if (COLOUR)
                    line = {line, $sformatf("\033[3%0d;4%0dm\xE2\x96\x80", ansi_index(top), ansi_index(bot))};
                else begin
                    automatic int lum = (top[23] + top[15] + top[7] + bot[23] + bot[15] + bot[7]);
                    line = {line, lum == 0 ? " " : lum <= 2 ? "." : lum <= 4 ? "+" : "#"};
                end
            end
            $display("%s\033[0m|", line);
        end
        $display("+%s+", dashes(cols));
    endtask

    // ---- .ppm writer (binary P6; open with any image viewer, or convert with ppm_to_png.py)
    task automatic write_ppm(input string name);
        int fd = $fopen(name, "wb");
        if (fd == 0) begin
            $display("[VGA] could not open %s for writing", name);
            return;
        end
        $fwrite(fd, "P6\n%0d %0d\n255\n", H_RES, V_RES);
        for (int i = 0; i < N_PIX; i++)
            $fwrite(fd, "%c%c%c", frame[i][23:16], frame[i][15:8], frame[i][7:0]);
        $fclose(fd);
        if (VERBOSE) $display("[VGA] wrote %s (%0dx%0d)", name, H_RES, V_RES);
    endtask

    // Summary at the end of the simulation.
    final begin
        $display("[VGA] end of simulation: %0d complete frame(s), %0d problem(s) reported.", frames_done, errors);
        if (mode == SYNC_FRAME && discarded_this_wait > 0)
            $display("[VGA] ...and %0d pixel(s) were discarded while waiting for a startofpacket that never came. The screen stayed on the last frame. Did pixel_index wrap back to 0 (with startofpacket) after the last pixel?", discarded_this_wait);
        if (mode == DISPLAY)
            $display("[VGA] ...simulation stopped mid-frame at (x=%0d, y=%0d).", px, ln);
    end

endmodule
