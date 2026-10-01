`timescale 1ns/1ps
/*
 *  REUSED MODULE -- Lesson 3 / Mini-Project 2, rtl/video_pll.sv (50 MHz -> 25 MHz pixel clock).
 *  CHANGES: none. Instantiated in top_level.sv (Jason); its output is video_subsystem's clk_25.
 */
/*
 *  video_pll.sv -- 50 MHz in, 25 MHz pixel clock out, using the PLL Intel FPGA IP.
 *
 *  The same altera_pll instantiation that the IP Parameter Editor generates
 *  (Task 1.2), written out by hand so the project has no wizard files, exactly
 *  like adc_pll.sv in the mic-input project. The VGA Controller in vga.qsys (or vga_text.qsys)
 *  is configured for 640x480, whose pixel clock is 25.175 MHz nominal; 25 MHz
 *  is what the University Program cores use and every monitor accepts it.
 *
 *  Simulators cannot run the PLL primitive without Intel's libraries, so in
 *  simulation (Verilator, or ModelSim via its MODEL_TECH define) the module
 *  becomes a behavioural stand-in: a clock generator at the same frequency.
 */
module video_pll (
    input  wire refclk,     // 50 MHz
    input  wire rst,
    output wire outclk_0,   // 25 MHz
    output wire locked
);
`ifdef VERILATOR
    `define VIDEO_PLL_SIM_STANDIN
`elsif MODEL_TECH
    `define VIDEO_PLL_SIM_STANDIN     // ModelSim predefines MODEL_TECH
`endif
`ifdef VIDEO_PLL_SIM_STANDIN
    logic clk_sim;
    initial clk_sim = 1'b0;
    always #(20ns) clk_sim = ~clk_sim;   // 25 MHz
    assign outclk_0 = clk_sim;
    assign locked   = 1'b1;
`else
    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(1),
        .output_clock_frequency0("25.000000 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst      (rst),
        .outclk   ({outclk_0}),
        .locked   (locked),
        .fboutclk ( ),
        .fbclk    (1'b0),
        .refclk   (refclk)
    );
`endif
endmodule
