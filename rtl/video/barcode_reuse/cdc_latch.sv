`timescale 1ns/1ps
/*
 *  REUSED MODULE -- Mini-Project 2 (barcode reader) workspace, rtl/cdc_latch.sv. CHANGES: none.
 *  In A2 it carries the key finder's result bundle (boundaries, kept flags, lanes, mode) from the
 *  50 MHz analysis domain to the 25 MHz display, applied while the source waits at pixel (0,0).
 */
/*
 *  cdc_latch.sv -- carry a bundle of values from one clock domain to another, and update the
 *  destination copy only when the destination says it is safe (for a display: during vertical
 *  blanking, so one frame never shows a mix of old and new values).
 *
 *  Request / acknowledge with toggles (the textbook multi-bit crossing):
 *    source:  when a new bundle arrives and no transfer is in flight, store it in `held` and
 *             flip `req`. Hold `held` still until the destination has taken it. New bundles
 *             that arrive while a transfer is in flight are dropped: for "the latest value"
 *             that is the right behaviour (the next one will go).
 *    dest:    `req` crosses through a two-flop synchroniser. When it differs from `ack` a
 *             bundle is waiting; at the next `update_ok` copy `held` and flip `ack`.
 *    source:  `ack` crosses back through two flops; when it equals `req` the transfer is done.
 *  `held` is never written while the destination may be reading it, because the source waits
 *  for the acknowledge before writing again. That is the property a plain toggle (no ack) lacks
 *  when the source is fast: this design first used one, and with eleven results per frame the
 *  synchronised toggle's parity at blanking was a coin toss.
 */
module cdc_latch #(
    parameter int WIDTH = 32
) (
    input  logic             src_clk,
    input  logic             src_valid,      // pulse: src_data is a new bundle
    input  logic [WIDTH-1:0] src_data,
    output logic             src_busy,       // a transfer is in flight; new bundles are dropped
    input  logic             dst_clk,
    input  logic             dst_reset,
    input  logic             update_ok,      // e.g. vertical blanking
    output logic [WIDTH-1:0] dst_data,
    output logic             dst_updated     // pulse: dst_data changed this cycle
);
    logic [WIDTH-1:0] held;
    logic req = 1'b0, ack;                   // toggles, one in each domain (declaration initialisers = power-up values)
    logic ack_m = 1'b0, ack_s = 1'b0;        // ack synchronised into the source clock
    logic req_m, req_s;                      // req synchronised into the destination clock

    // ---- source side ----
    always_ff @(posedge src_clk) begin
        ack_m <= ack; ack_s <= ack_m;
        if (src_valid && !src_busy) begin held <= src_data; req <= ~req; end
    end
    assign src_busy = (req != ack_s);

    // ---- destination side ----
    always_ff @(posedge dst_clk) begin
        if (dst_reset) begin req_m <= 1'b0; req_s <= 1'b0; ack <= 1'b0; dst_updated <= 1'b0; end
        else begin
            req_m <= req; req_s <= req_m;
            dst_updated <= 1'b0;
            if ((req_s != ack) && update_ok) begin dst_data <= held; ack <= req_s; dst_updated <= 1'b1; end
        end
    end
endmodule
