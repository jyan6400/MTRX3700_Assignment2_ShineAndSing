`timescale 1ns/1ps
/*
 *  cdc_latch_tb.sv -- REUSED module (Mini-Project 2 cdc_latch.sv), the 50 MHz -> 25 MHz path that carries
 *  the key finder's results to the display. Two asynchronous clocks (50 MHz and 25.17 MHz, so the
 *  phase drifts), a source that publishes a new bundle every 1..3000 clocks, and an update window like
 *  the display's (a short burst once per "frame"). Checked, against the bench's record of what was sent:
 *    - the destination only changes inside update_ok, and dst_updated pulses exactly then
 *    - every bundle that arrives is one that was sent whole (the bundle is its own checksum: the upper
 *      half is the bitwise inverse of the lower, so a mix of two bundles is caught)
 *    - bundles arrive in order, nothing arrives that was not sent, the last one sent always arrives
 *    - a destination reset in the middle
 */
module cdc_latch_tb;
    localparam int WIDTH = 64;
    logic src_clk = 0; always #10 src_clk = ~src_clk;             // 50 MHz
    logic dst_clk = 0; always #19.86 dst_clk = ~dst_clk;          // 25.17 MHz, not a multiple
    logic src_valid = 0, dst_reset = 1, update_ok = 0, src_busy, dst_updated;
    logic [WIDTH-1:0] src_data, dst_data, dst_prev;
    cdc_latch #(.WIDTH(WIDTH)) dut (.*);

    function automatic logic [WIDTH-1:0] bundle(input int k);
        logic [31:0] v; v = 32'(k) * 32'h9E3779B1;
        return {~v, v};
    endfunction
    int sent[$]; int last_seen = -1, updates = 0;

    // destination checker
    always @(posedge dst_clk) begin
        dst_prev <= dst_data;
        if (!dst_reset && dst_updated) begin
            int k; bit found;
            updates++;
            if (dst_data[63:32] != ~dst_data[31:0]) $fatal(1, "FAIL: torn bundle %h", dst_data);
            found = 0;
            foreach (sent[i]) if (bundle(sent[i]) == dst_data) begin k = sent[i]; found = 1; end
            if (!found) $fatal(1, "FAIL: a bundle that was never sent arrived");
            if (k <= last_seen) $fatal(1, "FAIL: bundle %0d arrived after %0d (out of order)", k, last_seen);
            last_seen = k;
        end
    end
    // dst_data only moves in the window, with dst_updated
    logic ok_d;
    always @(posedge dst_clk) ok_d <= update_ok;
    always @(negedge dst_clk) if (!dst_reset && dst_data !== dst_prev && !dst_updated)
        $fatal(1, "FAIL: dst_data changed without dst_updated");
    always @(posedge dst_clk) if (!dst_reset && dst_updated && !ok_d) $fatal(1, "FAIL: updated outside update_ok");

    // the update window: 8 clocks every 400 (a frame)
    int fc = 0;
    always @(posedge dst_clk) begin fc = (fc + 1) % 400; update_ok <= (fc < 8); end

    task automatic publish(input int k);
        @(negedge src_clk); src_valid = 1; src_data = bundle(k); if (!src_busy) sent.push_back(k);
        @(negedge src_clk); src_valid = 0;
    endtask

    initial begin
        repeat (10) @(posedge dst_clk); dst_reset = 0;
        for (int k = 1; k <= 300; k++) begin
            publish(k);
            repeat (1 + $urandom % ((k % 10 == 0) ? 3000 : 300)) @(posedge src_clk);
            // a destination reset: afterwards the latest bundle is delivered again (ack restarts at 0)
            if (k == 150) begin @(negedge dst_clk); dst_reset = 1; repeat (3) @(negedge dst_clk); last_seen = last_seen - 1; dst_reset = 0; end
        end
        // let the last one through
        repeat (4000) @(posedge dst_clk);
        if (last_seen != sent[$]) $fatal(1, "FAIL: the last bundle sent (%0d) never arrived (last seen %0d)", sent[$], last_seen);
        if (updates < 20) $fatal(1, "FAIL: only %0d updates", updates);
        $display("PASS: %0d of %0d bundles accepted crossed whole, in order, only in the window; last one arrived", updates, sent.size());
        $display("ALL TESTS PASSED: cdc_latch");
        $finish;
    end
endmodule
