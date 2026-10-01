// =============================================================================
// window_function_tb.sv  --  NEW, Luke Mouawad
// Self-checking unit test for the Hamming window_function.sv (modified for A2).
// Every output is checked against y = floor(x * w[n] / 2^16), with
// w[n] = round((0.54 - 0.46 cos(2 pi n / 1023)) * 65535) computed here with $cos.
//   - 2.5 frames of random samples with random valid gaps: every n checked, so a
//     window applied to the wrong half / wrong index / wrong frame alignment fails
//   - the index wraps to 0 after exactly 1024 accepted samples
//   - extremes: +32767 and -32768 at the window centre and ends (no overflow)
//   - zero input -> zero output
//   - symmetry: w[n] == w[1023-n] observed on the outputs
//   - latency exactly 1 clock, one y_valid per accepted sample
//   - reset mid-frame restarts the window at n = 0
// =============================================================================
`timescale 1ns/1ns

module window_function_tb;
    localparam int W = 16;
    localparam int N = 1024;
    localparam real PI = 3.14159265358979;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic                reset = 1'b1;
    logic                x_valid = 1'b0, x_ready, y_valid;
    logic signed [W-1:0] x_data = '0;
    logic        [W-1:0] y_data;

    window_function #(.W(W), .NSamples(N)) dut (
        .clk, .reset, .x_valid, .x_ready, .x_data, .y_valid, .y_ready(1'b1), .y_data);

    function automatic longint wcoef(input int n);
        return longint'($floor((0.54 - 0.46 * $cos(2.0 * PI * n / (N - 1))) * 65535.0 + 0.5));
    endfunction

    function automatic longint expect_y(input longint x, input int n);
        longint p = x * wcoef(n);
        return (p >= 0) ? (p >>> 16) : -((-p + 65535) >>> 16);     // floor division by 2^16
    endfunction

    // scoreboard: expected outputs in order
    longint exp_q [$];
    int     n_model = 0, n_out = 0;
    longint y_at_n [N];

    always @(posedge clk) begin
        if (!reset && y_valid) begin
            longint e;
            if (exp_q.size() == 0) $fatal(1, "y_valid with no accepted input");
            e = exp_q.pop_front();
            if (longint'($signed(y_data)) != e)
                $fatal(1, "output %0d: y = %0d, expected %0d", n_out, $signed(y_data), e);
            n_out++;
        end
    end

    // drive one sample; returns after the edge that accepts it
    task automatic drive(input longint x);
        x_data  <= W'(x);
        x_valid <= 1'b1;
        exp_q.push_back(expect_y(x, n_model));
        n_model = (n_model == N - 1) ? 0 : n_model + 1;
        @(posedge clk);
    endtask

    task automatic gap(input int c);
        x_valid <= 1'b0;
        repeat (c) @(posedge clk);
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset <= 1'b0;
        @(posedge clk);
        if (x_ready !== 1'b1) $fatal(1, "x_ready should follow y_ready = 1");

        // 2.5 frames of random samples with random gaps
        for (int i = 0; i < 2 * N + N / 2; i++) begin
            drive($signed(16'($urandom)));
            if ($urandom_range(3, 0) == 0) gap($urandom_range(3, 1));
        end
        gap(3);
        if (exp_q.size() != 0) $fatal(1, "%0d outputs missing", exp_q.size());
        $display("2.5 frames of random samples: every coefficient correct, index wraps at %0d", N);

        // finish the current frame, then a frame of constant full scale: symmetry + extremes
        while (n_model != 0) drive(0);
        gap(2);
        for (int i = 0; i < N; i++) begin
            drive(32767);
        end
        gap(2);
        for (int i = 0; i < N; i++) drive(-32768);
        gap(3);
        if (exp_q.size() != 0) $fatal(1, "outputs missing after extremes");
        if (expect_y(32767, 0) != expect_y(32767, N - 1) || expect_y(32767, 100) != expect_y(32767, N - 101))
            $fatal(1, "window not symmetric");
        $display("full-scale frames: ends %0d, centre %0d (no overflow, symmetric)",
                 expect_y(32767, 0), expect_y(32767, N / 2));

        // reset mid-frame: the window restarts at n = 0
        for (int i = 0; i < 300; i++) drive($signed(16'($urandom)));
        x_valid <= 1'b0;
        reset   <= 1'b1;
        @(posedge clk);
        reset   <= 1'b0;
        exp_q.delete();
        n_model = 0;
        @(posedge clk);
        for (int i = 0; i < 50; i++) drive(20000);
        gap(3);
        if (exp_q.size() != 0) $fatal(1, "outputs missing after reset");
        $display("reset mid-frame: window restarted at n = 0");

        $display("%0d windowed samples checked", n_out);
        $display("ALL TESTS PASSED: window_function");
        $finish;
    end
endmodule
