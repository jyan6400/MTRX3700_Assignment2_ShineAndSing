`timescale 1ns/1ns
/*
 *  low_pass_conv.sv -- the 41-tap anti-alias FIR before decimation, computed with ONE multiplier.
 *
 *  Same ports and same arithmetic as the Lesson 4 parallel version (41 multipliers, 78 DSP blocks on the
 *  DE1-SoC: every DSP block the chip has, minus the FFT's). Here the taps are walked one per clock:
 *  a new sample arrives every 64 bit-clocks (48 kHz at 3.072 MHz) and the 41 multiply-accumulates take 43.
 *
 *      y[n] = sum_{i=0..40} h[i] * x[n-i]            h: 16-bit fraction, |h| < 2^15
 *
 *  x_data is {sample, 16'b0} (integer part = the 16-bit sample), so only the top W-W_FRAC bits are
 *  multiplied and the product needs one 16 x 18 multiplier: one DSP block. Latency 43 clocks instead of 2.
 *
 *  Samples must arrive at least N + 2 = 43 clocks apart (they arrive 64 apart here). A sample that
 *  arrives sooner restarts the walk and the previous output is lost; simulation reports it.
 */
module low_pass_conv #(parameter W = 32, W_FRAC = 16) (
    input clk,

    input  logic x_valid,
    output logic x_ready,
    input  logic [W-1:0] x_data,

    output logic y_valid,
    input  logic y_ready,
    output logic [W-1:0] y_data
);
    assign x_ready = y_ready;

    localparam int N  = 41;
    localparam int XW = W - W_FRAC;          // integer bits of the sample (16)
    localparam int CW = 18;                  // coefficient bits kept (signed; the taps fit in 17)
    // Impulse response: (32-bit, 16-bit frac, 2's complement) -- unchanged from Lesson 4
    localparam logic [W-1:0] h [0:N-1] = '{32'h00000000, 32'h00000014, 32'h0000003f, 32'h00000050, 32'h00000000, 32'hffffff0b, 32'hfffffd56, 32'hfffffb08, 32'hfffff8a1, 32'hfffff6ee, 32'hfffff6f3, 32'hfffff9b5, 32'h00000000, 32'h00000a2d, 32'h000017f4, 32'h00002860, 32'h000039e3, 32'h00004a8b, 32'h0000584b, 32'h0000615d, 32'h00006488, 32'h0000615d, 32'h0000584b, 32'h00004a8b, 32'h000039e3, 32'h00002860, 32'h000017f4, 32'h00000a2d, 32'h00000000, 32'hfffff9b5, 32'hfffff6f3, 32'hfffff6ee, 32'hfffff8a1, 32'hfffffb08, 32'hfffffd56, 32'hffffff0b, 32'h00000000, 32'h00000050, 32'h0000003f, 32'h00000014, 32'h00000000};

    // the last N samples (integer part only)
    logic signed [XW-1:0] shift_reg [0:N-1];
    always_ff @(posedge clk) if (x_valid & x_ready) begin
        shift_reg[0] <= signed'(x_data[W-1 -: XW]);
        for (int i = 1; i < N; i++) shift_reg[i] <= shift_reg[i-1];
    end

    // walk the taps: one product per clock, accumulated; the sum is published after the last tap
    logic [$clog2(N)-1:0] tap = '0, tap_q = '0;
    logic running = 1'b0, prod_valid = 1'b0, done = 1'b0;
    logic signed [XW+CW-1:0] prod;
    logic signed [XW+CW+$clog2(N)-1:0] acc;
    always_ff @(posedge clk) begin
        if (x_valid & x_ready) begin running <= 1'b1; tap <= '0; end          // (re)start on every new sample
`ifndef SYNTHESIS
        if (x_valid & x_ready & running) $error("low_pass_conv: a sample arrived before the last one was filtered (need %0d clocks between samples)", N + 2);
`endif
        else if (running) begin
            if (tap == N-1) running <= 1'b0; else tap <= tap + 1'b1;
        end
        prod       <= shift_reg[tap] * signed'(h[tap][CW-1:0]);              // the one multiplier
        prod_valid <= running;
        tap_q      <= tap;
        if (prod_valid) acc <= (tap_q == 0) ? prod : acc + prod;
        done       <= prod_valid && (tap_q == N-1);
    end

    // output: sum(x*h) in the W-bit frame the decimator expects (the filtered sample is its top XW bits)
    always_ff @(posedge clk) begin
        if (y_ready) y_valid <= 1'b0;
        if (done) begin y_data <= W'(acc); y_valid <= 1'b1; end
    end
endmodule
