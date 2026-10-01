`timescale 1ns/1ps
/*
 *  video_controls_tb.sv -- KEY3..KEY1 + SW0 -> thresholds. A bench-side model of the registers (its own
 *  arithmetic, clamps and step sizes) is updated on every press and compared with the DUT after every
 *  press. Checked:
 *    defaults after reset; one press = one step even with contact bounce (the key chatters for less than
 *    a debounce tick) and when held down; SW0 and the mode choose the value; clamps at 0 and 256
 *    (k_q at 0 and 255, thr_abs at 0); KEY3 restores every default.
 *  DB_TICKS is shortened to 16 clocks so the bench runs in milliseconds; bounce lasts < 16 clocks.
 */
module video_controls_tb;
    localparam int AW = 20, NW = 9, DB = 16;
    logic clk = 0; always #10 clk = ~clk;
    logic reset = 1; logic [3:1] key_n = 3'b111; logic sw_sel = 0; logic [1:0] mode = 0;
    logic [NW-1:0] hi, lo, floor_lvl; logic [7:0] k_q; logic [AW-1:0] thr_abs;
    video_controls #(.AW(AW), .NW(NW), .DB_TICKS(DB)) dut (.*);

    int m_hi, m_lo, m_floor, m_kq, m_abs;
    task automatic defaults(); m_hi = 115; m_lo = 64; m_floor = 26; m_kq = 102; m_abs = 2048; endtask
    task automatic check(input string what);
        if (int'(hi) != m_hi || int'(lo) != m_lo || int'(floor_lvl) != m_floor || int'(k_q) != m_kq || int'(thr_abs) != m_abs)
            $fatal(1, "FAIL %s: hi/lo/floor/k_q/abs = %0d/%0d/%0d/%0d/%0d, expected %0d/%0d/%0d/%0d/%0d", what,
                   hi, lo, floor_lvl, k_q, thr_abs, m_hi, m_lo, m_floor, m_kq, m_abs);
    endtask
    // the model: what one press should do
    function automatic int clamp(int v, int lo_v, int hi_v); return (v < lo_v) ? lo_v : (v > hi_v) ? hi_v : v; endfunction
    task automatic model(input int key);
        int dir;
        if (key == 3) begin defaults(); return; end
        dir = (key == 1) ? 1 : -1;
        case (mode)
            2'd0: if (!sw_sel) m_kq = clamp(m_kq + 8 * dir, 0, 255); else m_floor = clamp(m_floor + 4 * dir, 0, 256);
            2'd1: if (!sw_sel) m_hi = clamp(m_hi + 8 * dir, 0, 256); else m_lo = clamp(m_lo + 8 * dir, 0, 256);
            default: m_abs = clamp(m_abs + 256 * dir, 0, (1 << AW) - 1);
        endcase
    endtask
    // a press with bounce: chatter for a few clocks, hold, release with chatter
    task automatic press(input int key, input int hold_ticks);
        for (int i = 0; i < 4; i++) begin key_n[key] = 0; repeat (1 + $urandom % 2) @(posedge clk); key_n[key] = 1; @(posedge clk); end
        key_n[key] = 0; repeat (hold_ticks * DB) @(posedge clk);
        for (int i = 0; i < 3; i++) begin key_n[key] = 1; @(posedge clk); key_n[key] = 0; @(posedge clk); end
        key_n[key] = 1; repeat (3 * DB) @(posedge clk);
        model(key);
    endtask

    initial begin
        defaults();
        repeat (5) @(posedge clk); reset = 0; repeat (5) @(posedge clk);
        check("after reset");
        mode = 1; sw_sel = 0; repeat (4) @(posedge clk);
        press(1, 2); check("R-V3 hi up");
        press(1, 20); check("R-V3 hi up, held for 20 ticks: still one step");
        press(2, 2); check("R-V3 hi down");
        sw_sel = 1; repeat (4) @(posedge clk);
        for (int i = 0; i < 14; i++) begin press(2, 1); check("R-V3 lo down to the clamp"); end
        if (lo != 0) $fatal(1, "FAIL: lo did not clamp at 0");
        mode = 0; sw_sel = 0; repeat (4) @(posedge clk);
        for (int i = 0; i < 20; i++) begin press(1, 1); check("R-V4 k up to the clamp"); end
        if (k_q != 255) $fatal(1, "FAIL: k_q did not clamp at 255");
        sw_sel = 1; repeat (4) @(posedge clk);
        press(1, 1); check("R-V4 floor up");
        mode = 2; repeat (4) @(posedge clk);
        press(1, 1); press(1, 1); check("R-V2 absolute threshold up");
        mode = 3; sw_sel = 0; repeat (4) @(posedge clk);
        press(2, 1); check("R-V1 absolute threshold down (SW0 ignored)");
        mode = 1; sw_sel = 0; repeat (4) @(posedge clk);
        for (int i = 0; i < 20; i++) begin press(1, 1); check("R-V3 hi up to the clamp"); end
        if (hi != 256) $fatal(1, "FAIL: hi did not clamp at 256");
        press(3, 1); check("KEY3 restores the defaults");
        reset = 1; @(posedge clk); reset = 0; @(posedge clk); check("reset");
        $display("PASS: bounced presses give one step, SW0 and mode select the value, clamps, KEY3 restore");
        $display("ALL TESTS PASSED: video_controls");
        $finish;
    end
endmodule
