// =============================================================================
// log2_energy_tb.sv  --  NEW, Luke Mouawad
// Self-checking unit test for log2_energy.sv. Three instances:
//   A: IN_W=48, FRAC_W=10  (R-A4 log-Mel configuration)
//   B: IN_W=24, FRAC_W=8   (audio_gate dB configuration)
//   C: IN_W=32, FRAC_W=10  (INT_W exactly full -> exercises saturation)
// Each checks, against log2 computed in the testbench with real arithmetic:
//   - zero energy (x = 0 -> y = 0, zero = 1) and x = 1
//   - every exact power of two (y = p << FRAC_W exactly)
//   - maximum energy (all ones) incl. saturation for instance C
//   - 4000 random values spread over the whole dynamic range, |err| <= 1 LSB
//   - monotonic sweep across LUT segment boundaries
//   - fixed LATENCY with back-to-back inputs and random bubbles
//   - reset clears the pipeline (no stale out_valid)
// =============================================================================
`timescale 1ns/1ps

module log2_check #(
    parameter int IN_W   = 48,
    parameter int FRAC_W = 10,
    parameter string NAME = "A"
) (
    input  logic clk,
    output logic done
);
    localparam int INT_W   = $clog2(IN_W);
    localparam int Y_W     = INT_W + FRAC_W;
    localparam int LATENCY = 3;
    localparam longint YMAX = (64'd1 << Y_W) - 1;

    logic              reset = 1'b1;
    logic [IN_W-1:0]   x = '0;
    logic              in_valid = 1'b0;
    logic [Y_W-1:0]    y;
    logic              out_valid, zero;

    log2_energy #(.IN_W(IN_W), .FRAC_W(FRAC_W)) dut (
        .clk, .reset, .x, .in_valid, .y, .out_valid, .zero);

    // ---------------- scoreboard --------------------------------------------
    logic [IN_W-1:0] exp_x [$];
    longint          exp_t [$];
    longint          cycle = 0;
    int              n_checked = 0;
    logic [Y_W-1:0]  prev_y = '0;
    logic            have_prev = 1'b0;
    logic            mono_mode = 1'b0;

    function automatic longint expected_code(input logic [IN_W-1:0] xv, output bit exact_pow2);
        real    l;
        longint e;
        exact_pow2 = ($countones(xv) == 1);
        if (xv == '0) return 0;
        l = $ln(real'(xv)) / $ln(2.0);
        e = longint'($floor(l * real'(1 << FRAC_W) + 0.5));
        if (e > YMAX) e = YMAX;
        return e;
    endfunction

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (!reset && out_valid) begin
            logic [IN_W-1:0] xv;
            longint          t0, e, diff;
            bit              p2;
            if (exp_x.size() == 0)
                $fatal(1, "[%s] out_valid with no pending input (stale pipeline)", NAME);
            xv = exp_x.pop_front();
            t0 = exp_t.pop_front();
            if (cycle - t0 != LATENCY)
                $fatal(1, "[%s] latency %0d != %0d for x=%0d", NAME, cycle - t0, LATENCY, xv);
            e = expected_code(xv, p2);
            diff = longint'(y) - e;
            if (xv == '0) begin
                if (y != '0 || zero !== 1'b1)
                    $fatal(1, "[%s] x=0: y=%0d zero=%b, expected 0/1", NAME, y, zero);
            end else begin
                if (zero !== 1'b0)
                    $fatal(1, "[%s] zero flag set for x=%0d", NAME, xv);
                if (p2 && diff != 0)
                    $fatal(1, "[%s] power of two x=%0d: y=%0d expected exactly %0d", NAME, xv, y, e);
                if (diff > 1 || diff < -1)
                    $fatal(1, "[%s] x=%0d: y=%0d expected %0d (+/-1 LSB)", NAME, xv, y, e);
            end
            if (mono_mode && have_prev && y < prev_y)
                $fatal(1, "[%s] not monotonic: x=%0d y=%0d < previous %0d", NAME, xv, y, prev_y);
            prev_y    <= y;
            have_prev <= mono_mode;
            n_checked <= n_checked + 1;
        end
        if (!mono_mode) have_prev <= 1'b0;
    end

    task automatic drive(input logic [IN_W-1:0] xv);
        x        <= xv;
        in_valid <= 1'b1;
        exp_x.push_back(xv);
        exp_t.push_back(cycle + 1);     // sampled at the next edge
        @(posedge clk);                 // in_valid stays high for back-to-back
    endtask

    task automatic idle(input int n);
        in_valid <= 1'b0;
        repeat (n) @(posedge clk);
    endtask

    task automatic flush();
        idle(LATENCY + 2);
        if (exp_x.size() != 0) $fatal(1, "[%s] %0d outputs never arrived", NAME, exp_x.size());
    endtask

    initial begin
        done = 1'b0;
        repeat (3) @(posedge clk);
        reset <= 1'b0;
        @(posedge clk);

        // zero energy, 1, all powers of two, maximum energy
        drive('0);
        drive(IN_W'(1));
        for (int p = 0; p < IN_W; p++) drive(IN_W'(1) << p);
        drive('1);
        flush();

        // random values over the full dynamic range, back-to-back + bubbles
        for (int i = 0; i < 4000; i++) begin
            logic [IN_W-1:0] r;
            r = {$urandom, $urandom, $urandom};
            r = r >> ($urandom_range(IN_W - 1, 0));
            drive(r);
            if ($urandom_range(3, 0) == 0) idle(1);         // bubble
        end
        flush();

        // monotonic sweep through LUT segment boundaries around 2^12
        mono_mode <= 1'b1;
        @(posedge clk);
        for (int i = 4096; i < 4096 + 3000; i++) drive(IN_W'(i));
        flush();
        mono_mode <= 1'b0;

        // reset in the middle of a burst: nothing may come out afterwards
        drive(IN_W'(12345));
        x <= IN_W'(777);                // in_valid still high from drive()
        reset <= 1'b1;
        exp_x.delete(); exp_t.delete();
        @(posedge clk);
        in_valid <= 1'b0;
        @(posedge clk);
        reset <= 1'b0;
        repeat (LATENCY + 3) begin
            @(posedge clk);
            if (out_valid) $fatal(1, "[%s] out_valid after reset", NAME);
        end

        $display("[%s] IN_W=%0d FRAC_W=%0d: %0d conversions checked", NAME, IN_W, FRAC_W, n_checked);
        done = 1'b1;
    end
endmodule

module log2_energy_tb;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic done_a, done_b, done_c;
    log2_check #(.IN_W(48), .FRAC_W(10), .NAME("A_logmel")) u_a (.clk, .done(done_a));
    log2_check #(.IN_W(24), .FRAC_W(8),  .NAME("B_gate"))   u_b (.clk, .done(done_b));
    log2_check #(.IN_W(32), .FRAC_W(10), .NAME("C_sat"))    u_c (.clk, .done(done_c));

    initial begin
        wait (done_a && done_b && done_c);
        $display("ALL TESTS PASSED: log2_energy");
        $finish;
    end
    initial begin
        #50ms $fatal(1, "timeout");
    end
endmodule
