`timescale 1ns/1ps
// REUSED from Lesson 4 (Luke). ONE CHANGE for A2, per the README reuse rule:
//   intended_device_family "Cyclone IV E" (DE2-115) -> "Cyclone V" (the DE1-SoC we build for),
//   as the original comment instructs. Behaviour unchanged; tb_fft_input_buffer re-run and passes.

module async_fifo (
    input  wire        aclr,

    // Write side (audio_clk domain)
    input  wire [15:0] data,
    input  wire        wrclk,
    input  wire        wrreq,
    output wire        wrfull,

    // Read side (system clk domain)
    output wire [15:0] q,
    input  wire        rdclk,
    input  wire        rdreq,
    output wire        rdfull
);

    dcfifo #(
        .intended_device_family ("Cyclone V"),     // DE1-SoC (was "Cyclone IV E" for the DE2-115)
        .lpm_type               ("dcfifo"),
        .lpm_width              (16),
        .lpm_numwords           (1024),
        .lpm_widthu             (10),
        .lpm_showahead          ("ON"),
        .overflow_checking      ("ON"),
        .underflow_checking     ("ON"),
        .clocks_are_synchronized("FALSE"),
        .rdsync_delaypipe       (4),
        .wrsync_delaypipe       (4),
        .use_eab                ("ON"),
        .write_aclr_synch       ("OFF"),
        .read_aclr_synch        ("OFF"),
        .add_usedw_msb_bit      ("OFF")
    ) u_dcfifo (
        .aclr    (aclr),
        .data    (data),
        .wrclk   (wrclk),
        .wrreq   (wrreq),
        .wrfull  (wrfull),
        .q       (q),
        .rdclk   (rdclk),
        .rdreq   (rdreq),
        .rdfull  (rdfull),
        // Unused outputs
        .rdempty (),
        .wrempty (),
        .rdusedw (),
        .wrusedw (),
        .eccstatus ()
    );

endmodule
