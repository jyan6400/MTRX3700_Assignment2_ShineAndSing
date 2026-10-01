`timescale 1ns/1ps
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
 *  wm8731_model.sv  --  Behavioural simulation model of the WM8731 audio CODEC
 * ============================================================================
 *
 *  WHAT IS THIS?
 *  -------------
 *  A *simulation model* (or "sim model") is a piece of Verilog that pretends to
 *  be a chip that is NOT inside your FPGA. It is never synthesised. Its only job
 *  is to answer the question your testbench cannot otherwise answer:
 *
 *        "If I wired my design to the real chip, what would the chip do?"
 *
 *  The real WM8731 sits on the DE1-SoC PCB next to the FPGA. You cannot put a
 *  probe inside it to see whether it *understood* the I2C bytes you sent it.
 *  This model can: it decodes every I2C transaction exactly the way the
 *  datasheet says the chip does, keeps the same registers with the same reset
 *  values, and prints what it understood in plain English. Once the registers
 *  say "active, master mode, left-justified, 16-bit", it starts producing the
 *  BCLK / ADCLRC / ADCDAT audio stream with the exact timing from the datasheet
 *  figures, so the same model can be the *stimulus* for your I2S/LJ receiver.
 *
 *  The model is written from the WM8731 datasheet (Wolfson, PD Rev 4.0):
 *    - 2-wire (I2C) control interface: p.42-44, Figure 34, Table 25.
 *    - Register map and reset values:   Tables 29-30, p.46-51.
 *    - Audio interface timing:          Figures 26-28, p.33-35.
 *    - Master mode clocking:            p.36 ("BCLK output at 64 x fs").
 *    - Sample rate table:               Tables 17-22, p.38-41.
 *  Board-level facts (DE1-SoC schematic sheet 18): CSB=0 and MODE=0 are wired
 *  to ground, so the 7-bit I2C address is 0x1A (write byte 0x34), 2-wire mode.
 *
 *  FIDELITY (what is and is not modelled)
 *  ---------------------------------------
 *  Modelled:      I2C write protocol incl. START/STOP/ACK rules, address check,
 *                 register file + reset, "both channels" mirror bits, master
 *                 mode BCLK/LRC/ADCDAT generation for LJ, I2S and RJ formats and
 *                 all word lengths, DAC data capture on DACDAT, sample-rate
 *                 decoding from the Sampling Control register.
 *  NOT modelled:  analogue anything (volumes, mic boost, filters only affect the
 *                 printed description), slave mode (MS=0) audio interface,
 *                 USB clocking mode, DSP format, 3-wire SPI control mode,
 *                 electrical timing limits of the I2C bus.
 *  Like every model, it is only as correct as our reading of the datasheet.
 *  The configuration sequence used in this course has been verified on the
 *  real DE1-SoC hardware, and this model was checked against that sequence.
 *
 *  HOW TO USE
 *  ----------
 *    wm8731_model codec (
 *        .i2c_scl(I2C_SCLK), .i2c_sda(I2C_SDAT),       // 2-wire control bus
 *        .xck(AUD_XCK), .bclk(AUD_BCLK),               // clocks (XCK in, BCLK out)
 *        .adclrc(AUD_ADCLRCK), .adcdat(AUD_ADCDAT),    // ADC stream out
 *        .daclrc(AUD_DACLRCK), .dacdat(AUD_DACDAT),    // DAC stream in
 *        .adc_left(sample_l), .adc_right(sample_r),    // "what the microphone hears"
 *        .frame_start(frame_start),                    // pulse: load the next sample
 *        .dac_left(), .dac_right(), .dac_valid()       // what the DAC would play
 *    );
 *  The I2C bus needs a pull-up in the testbench:   pullup(I2C_SDAT);
 *  Call codec.print_summary() at the end of the simulation for a readable
 *  description of the state the chip ended up in.
 *
 *  The two halves can be used separately:
 *    - wm8731_control_if : the I2C slave + register file (Task 2.1)
 *    - wm8731_dai        : the audio-interface generator, configured directly
 *                          from register values (Task 2.2, no I2C needed)
 * ============================================================================
 */

package wm8731_pkg;

    // Register addresses (7-bit), datasheet Table 30.
    localparam logic [6:0] R_LEFT_LINE_IN   = 7'h00;
    localparam logic [6:0] R_RIGHT_LINE_IN  = 7'h01;
    localparam logic [6:0] R_LEFT_HP_OUT    = 7'h02;
    localparam logic [6:0] R_RIGHT_HP_OUT   = 7'h03;
    localparam logic [6:0] R_ANALOGUE_PATH  = 7'h04;
    localparam logic [6:0] R_DIGITAL_PATH   = 7'h05;
    localparam logic [6:0] R_POWER_DOWN     = 7'h06;
    localparam logic [6:0] R_DAI_FORMAT     = 7'h07;
    localparam logic [6:0] R_SAMPLING_CTRL  = 7'h08;
    localparam logic [6:0] R_ACTIVE         = 7'h09;
    localparam logic [6:0] R_RESET          = 7'h0F;

    // Reset values of R0..R9 (Table 29). R15 is write-only.
    localparam logic [8:0] RESET_VALUE [0:9] = '{9'h097, 9'h097, 9'h079, 9'h079, 9'h00A,
                                                9'h008, 9'h09F, 9'h00A, 9'h000, 9'h000};

    // Digital Audio Interface Format (R7) field values.
    localparam logic [1:0] FORMAT_RJ  = 2'b00;
    localparam logic [1:0] FORMAT_LJ  = 2'b01;
    localparam logic [1:0] FORMAT_I2S = 2'b10;
    localparam logic [1:0] FORMAT_DSP = 2'b11;

    function automatic string reg_name(input logic [6:0] a);
        case (a)
            R_LEFT_LINE_IN:  return "R0  Left Line In";
            R_RIGHT_LINE_IN: return "R1  Right Line In";
            R_LEFT_HP_OUT:   return "R2  Left Headphone Out";
            R_RIGHT_HP_OUT:  return "R3  Right Headphone Out";
            R_ANALOGUE_PATH: return "R4  Analogue Audio Path Control";
            R_DIGITAL_PATH:  return "R5  Digital Audio Path Control";
            R_POWER_DOWN:    return "R6  Power Down Control";
            R_DAI_FORMAT:    return "R7  Digital Audio Interface Format";
            R_SAMPLING_CTRL: return "R8  Sampling Control";
            R_ACTIVE:        return "R9  Active Control";
            R_RESET:         return "R15 Reset";
            default:         return $sformatf("R%0d (reserved)", a);
        endcase
    endfunction

    function automatic string onoff(input logic b);
        return b ? "on" : "off";
    endfunction

    function automatic int iwl_bits(input logic [1:0] iwl);
        case (iwl)
            2'b00: return 16;
            2'b01: return 20;
            2'b10: return 24;
            default: return 32;
        endcase
    endfunction

    function automatic string format_name(input logic [1:0] f);
        case (f)
            FORMAT_RJ:  return "Right-Justified";
            FORMAT_LJ:  return "Left-Justified";
            FORMAT_I2S: return "I2S";
            default:    return "DSP";
        endcase
    endfunction

    // Sample rate implied by R8 for a given MCLK (Tables 17-22, normal mode only).
    // Returns 0 if the combination is not in the datasheet tables.
    function automatic real sample_rate_hz(input logic [8:0] r8, input real mclk_hz);
        logic usb  = r8[0];
        logic bosr = r8[1];
        logic [3:0] sr = r8[5:2];
        real base;
        if (usb) return 0.0;                       // USB mode not modelled
        base = mclk_hz / (bosr ? 384.0 : 256.0);   // 48 kHz family; 44.1 kHz family uses the same ratios with 11.2896/16.9344 MHz
        case (sr)
            4'b0000, 4'b0001, 4'b0010, 4'b0011, 4'b1000, 4'b1001, 4'b1010, 4'b1011: return base;  // 48 / 44.1 kHz (the mixed ADC/DAC 8 kHz codes report the 48k side)
            4'b0110, 4'b1110: return base * 2.0 / 3.0;   // 32 kHz
            4'b0111, 4'b1111: return base * 2.0;         // 96 / 88.2 kHz
            default: return 0.0;
        endcase
    endfunction

    // Human readable decode of a register write (Table 30).
    function automatic string decode(input logic [6:0] a, input logic [8:0] d);
        case (a)
            R_LEFT_LINE_IN, R_RIGHT_LINE_IN:
                return $sformatf("volume code %0d (%0.1f dB), mute-to-ADC %s%s",
                                 d[4:0], -34.5 + 1.5 * d[4:0], onoff(d[7]),
                                 d[8] ? ", copied to both channels" : "");
            R_LEFT_HP_OUT, R_RIGHT_HP_OUT:
                return $sformatf("headphone volume code %0d (%s), zero-cross %s%s",
                                 d[6:0], d[6:0] < 7'h30 ? "mute" : $sformatf("%0d dB", int'(d[6:0]) - 121),
                                 onoff(d[7]), d[8] ? ", copied to both channels" : "");
            R_ANALOGUE_PATH:
                return $sformatf("MICBOOST=%0d MUTEMIC=%0d INSEL=%s BYPASS=%0d DACSEL=%0d SIDETONE=%0d SIDEATT=-%0ddB",
                                 d[0], d[1], d[2] ? "microphone" : "line-in", d[3], d[4], d[5], 6 + 3 * d[7:6]);
            R_DIGITAL_PATH:
                return $sformatf("ADC high-pass filter %s, de-emphasis code %0d, DAC soft mute %s, HPOR=%0d",
                                 d[0] ? "disabled" : "enabled", d[2:1], onoff(d[3]), d[4]);
            R_POWER_DOWN:
                return $sformatf("powered down: line-in=%0d mic=%0d ADC=%0d DAC=%0d outputs=%0d osc=%0d clkout=%0d POWEROFF=%0d",
                                 d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]);
            R_DAI_FORMAT:
                return $sformatf("format=%s, word length=%0d bits, LRP=%0d, LRSWAP=%0d, %s mode, BCLK %s",
                                 format_name(d[1:0]), iwl_bits(d[3:2]), d[4], d[5],
                                 d[6] ? "MASTER" : "slave", d[7] ? "inverted" : "not inverted");
            R_SAMPLING_CTRL:
                return $sformatf("%s mode, BOSR=%0d (%s), SR=%b, CLKIDIV2=%0d, CLKODIV2=%0d",
                                 d[0] ? "USB" : "normal", d[1],
                                 d[0] ? (d[1] ? "272fs" : "250fs") : (d[1] ? "384fs" : "256fs"),
                                 d[5:2], d[6], d[7]);
            R_ACTIVE:
                return d[0] ? "interface ACTIVE" : "interface inactive";
            R_RESET:
                return "device reset (all registers back to defaults)";
            default:
                return "reserved register, ignored";
        endcase
    endfunction

endpackage


/*
 * ----------------------------------------------------------------------------
 *  wm8731_control_if : the 2-wire (I2C) slave and the register file.
 * ----------------------------------------------------------------------------
 *  This is written the same way you write an I2C *master*: watch the bus,
 *  react to edges. The roles are just mirrored:
 *    - the master drives SDA while SCL is low and the slave samples SDA on the
 *      rising edge of SCL,
 *    - after every 8 bits the slave gets one SCL pulse to pull SDA low (ACK).
 *  START = SDA falls while SCL is high.  STOP = SDA rises while SCL is high.
 *  Anything else that changes SDA while SCL is high is a protocol error.
 *
 *  Verilator note: SDA is an open-drain bus. Each device only ever drives it
 *  LOW or lets go (high impedance, 'z'); the pull-up resistor makes it 1 when
 *  nobody drives. The testbench must include `pullup(I2C_SDAT);` (or an
 *  equivalent) for the bus to read as 1 when released.
 * ----------------------------------------------------------------------------
 */
module wm8731_control_if #(
    parameter logic [6:0] I2C_ADDR = 7'h1A,     // CSB pin = 0 on the DE1-SoC
    parameter bit         VERBOSE  = 1,         // print every accepted register write
    parameter realtime    T_HOLD   = 200ns,     // data hold after SCL falls (datasheet t10 <= 900 ns)
    parameter realtime    T_FILTER = 50ns       // input glitch filter: pulses shorter than this are ignored
) (
    input  logic scl,
    inout  wire  sda,
    // Register file, visible to the audio-interface model and to testbenches:
    output logic [8:0] regs [0:9],
    // Bookkeeping that testbenches / marking can inspect:
    output int   write_count,       // accepted register writes since time 0
    output int   error_count,       // protocol errors seen
    output int   nack_count         // bytes the model refused to acknowledge
);
    import wm8731_pkg::*;

    // ---- open-drain driver -------------------------------------------------
    logic sda_drive_low = 1'b0;
    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    // ---- input glitch filter -----------------------------------------------
    // Real I2C slaves ignore spikes on SCL/SDA (the I2C spec requires a 50 ns
    // filter in fast mode). A master built from `scl = scl_idle | ~clk` produces
    // a zero-width spike on SCL at the clock edge where scl_idle changes, which
    // the physical chip never sees. So: only accept a level that lasts T_FILTER.
    logic scl_f = 1'b1, sda_f = 1'b1;
    always @(scl) begin
        #(T_FILTER);
        if (scl_f !== scl && scl !== 1'bx) scl_f = scl;
    end
    always @(sda) begin
        #(T_FILTER);
        if (sda_f !== (sda === 1'b0 ? 1'b0 : 1'b1)) sda_f = (sda === 1'b0 ? 1'b0 : 1'b1);
    end

    // ---- register file -----------------------------------------------------
    function automatic void reset_registers();
        for (int i = 0; i < 10; i++) regs[i] = RESET_VALUE[i];
    endfunction
    initial begin
        reset_registers();
        write_count = 0; error_count = 0; nack_count = 0;
    end

    // Order in which registers were written (so a checker can verify e.g.
    // that Active was set last). -1 = never written.
    int write_order [0:15];
    initial for (int i = 0; i < 16; i++) write_order[i] = -1;
    // Full log of accepted writes, in order (for testbenches / marking).
    logic [6:0] log_reg [$];
    logic [8:0] log_val [$];

    // ---- bus bookkeeping ---------------------------------------------------
    logic       in_frame   = 1'b0;   // between START and STOP
    logic       addressed  = 1'b0;   // the address byte matched us (and was a write)
    logic       acking     = 1'b0;   // the current SCL pulse is the ACK clock
    int         bit_cnt    = 0;      // bits received in the current byte
    int         byte_idx   = 0;      // 0 = address byte, 1 = first data byte, 2 = second
    logic [7:0] shift      = '0;
    logic [7:0] byte1      = '0;

    function automatic void protocol_error(input string msg);
        error_count++;
        $display("[WM8731 @%0t] PROTOCOL ERROR: %s", $time, msg);
    endfunction

    // START: SDA falls while SCL is high.
    always @(negedge sda_f) begin
        if (scl_f === 1'b1) begin
            if (in_frame && bit_cnt != 0)
                protocol_error($sformatf("START condition in the middle of a byte (%0d bits received). SDA must only change while SCL is low.", bit_cnt));
            else if (in_frame && VERBOSE)
                $display("[WM8731 @%0t] repeated START", $time);
            else if (VERBOSE)
                $display("[WM8731 @%0t] START", $time);
            in_frame  = 1'b1;
            addressed = 1'b0;
            acking    = 1'b0;
            bit_cnt   = 0;
            byte_idx  = 0;
        end
    end

    // STOP: SDA rises while SCL is high.
    always @(posedge sda_f) begin
        if (scl_f === 1'b1 && in_frame) begin
            if (bit_cnt != 0 && addressed && byte_idx == 3) begin
                // A complete register write was already received; extra SCL
                // pulses before the STOP are harmless (the chip just resets).
                if (VERBOSE) $display("[WM8731 @%0t] STOP (note: %0d extra SCL pulse(s) after the last ACK were ignored)", $time, bit_cnt);
            end
            else if (bit_cnt != 0)
                protocol_error($sformatf("STOP condition in the middle of a byte (%0d bits received). SDA must only change while SCL is low.", bit_cnt));
            else if (addressed && byte_idx != 3)
                protocol_error($sformatf("STOP after only %0d data byte(s). A register write needs 2 data bytes (7-bit register address + 9-bit value).", byte_idx - 1));
            else if (VERBOSE)
                $display("[WM8731 @%0t] STOP", $time);
            in_frame  = 1'b0;
            addressed = 1'b0;
            acking    = 1'b0;
            bit_cnt   = 0;
        end
    end

    // Data bits are sampled on the rising edge of SCL.
    always @(posedge scl_f) begin
        if (in_frame && !acking) begin
            shift   = {shift[6:0], sda_f};
            bit_cnt = bit_cnt + 1;
        end
    end

    // Byte boundaries and the ACK clock are handled on the falling edge of SCL.
    always @(negedge scl_f) begin
        if (!in_frame) begin
            // nothing to do
        end
        else if (acking) begin
            // The ACK clock has just finished: release the bus.
            #(T_HOLD);
            sda_drive_low = 1'b0;
            acking = 1'b0;
        end
        else if (bit_cnt == 8) begin
            // A full byte is in. Decide whether to acknowledge it.
            logic ack;
            ack = process_byte(shift);
            bit_cnt = 0;
            byte_idx = byte_idx + 1;
            // Give the master a moment to release SDA, then check it did.
            #(T_HOLD);
            if (ack) begin
                if (sda === 1'b0)
                    protocol_error("the master is still driving SDA low during the ACK clock, so the slave cannot acknowledge. Release SDA (sda_set = 1) in the ACK states.");
                sda_drive_low = 1'b1;
            end else begin
                nack_count++;
            end
            acking = 1'b1;
        end
    end

    // Returns 1 to ACK the byte, 0 to NACK it.
    function automatic logic process_byte(input logic [7:0] b);
        case (byte_idx)
            0: begin
                if (b[7:1] != I2C_ADDR) begin
                    $display("[WM8731 @%0t] address byte 0x%02X is not mine (0x%02X = 0x%02X<<1 | W). Ignoring everything until the next START (no ACK).",
                             $time, b, {I2C_ADDR, 1'b0}, I2C_ADDR);
                    addressed = 1'b0;
                    in_frame  = 1'b0;   // datasheet: "return to the idle condition and wait for a new start condition"
                    return 1'b0;
                end
                if (b[0] == 1'b1) begin
                    $display("[WM8731 @%0t] address 0x%02X with R/W=1 (read). The WM8731 is a write-only device and does not respond to reads (no ACK).", $time, b);
                    addressed = 1'b0;
                    in_frame  = 1'b0;
                    return 1'b0;
                end
                addressed = 1'b1;
                if (VERBOSE) $display("[WM8731 @%0t] addressed: 0x%02X (7-bit address 0x%02X, write) -> ACK", $time, b, b[7:1]);
                return 1'b1;
            end
            1: begin
                if (!addressed) return 1'b0;
                byte1 = b;
                if (VERBOSE) $display("[WM8731 @%0t] byte 1 = %b : register address %0d (%b), data bit 8 = %b -> ACK", $time, b, b[7:1], b[7:1], b[0]);
                return 1'b1;
            end
            2: begin
                if (!addressed) return 1'b0;
                if (VERBOSE) $display("[WM8731 @%0t] byte 2 = %b : data bits 7..0 -> ACK", $time, b);
                write_register(byte1[7:1], {byte1[0], b});
                return 1'b1;
            end
            default: begin
                if (!addressed) return 1'b0;
                protocol_error("extra data byte after a complete register write. The WM8731 needs a new START + address for every register (datasheet p.44).");
                return 1'b1;
            end
        endcase
    endfunction

    function automatic void write_register(input logic [6:0] a, input logic [8:0] d);
        write_count++;
        log_reg.push_back(a);
        log_val.push_back(d);
        if (a < 10) write_order[int'(a)] = write_count;
        else if (a == R_RESET) write_order[15] = write_count;
        $display("[WM8731 @%0t] WRITE %s <= 9'b%b (0x%03h): %s", $time, reg_name(a), d, d, decode(a, d));
        case (a)
            R_RESET: begin
                reset_registers();
            end
            R_LEFT_LINE_IN:  begin regs[0] = d; if (d[8]) regs[1] = {1'b0, d[7:0]}; end
            R_RIGHT_LINE_IN: begin regs[1] = d; if (d[8]) regs[0] = {1'b0, d[7:0]}; end
            R_LEFT_HP_OUT:   begin regs[2] = d; if (d[8]) regs[3] = {1'b0, d[7:0]}; end
            R_RIGHT_HP_OUT:  begin regs[3] = d; if (d[8]) regs[2] = {1'b0, d[7:0]}; end
            R_DAI_FORMAT, R_SAMPLING_CTRL: begin
                if (regs[9][0])
                    $display("[WM8731 @%0t]   note: %s changed while the interface is ACTIVE. The datasheet recommends clearing Active before changing format or sampling registers (p.45).", $time, reg_name(a));
                regs[int'(a)] = d;
            end
            default: begin
                if (a < 10) regs[int'(a)] = d;
                else $display("[WM8731 @%0t]   note: register %0d does not exist; write ignored.", $time, a);
            end
        endcase
    endfunction

endmodule


/*
 * ----------------------------------------------------------------------------
 *  wm8731_dai : the Digital Audio Interface in MASTER mode.
 * ----------------------------------------------------------------------------
 *  Once the register file says ACTIVE=1 and MS=1 the chip drives:
 *    - BCLK   = 64 x fs. With BOSR=1 (384fs) that is XCK/6, with BOSR=0 (256fs)
 *               it is XCK/4. (Datasheet p.36: "BCLK output at 64 x base frequency".)
 *    - ADCLRC = fs, 50:50, toggling on the FALLING edge of BCLK. One period is
 *               64 BCLKs = 32 per channel.
 *    - ADCDAT = the sample bits, MSB first, changing on the FALLING edge of
 *               BCLK (so the receiver samples on the RISING edge).
 *        Left-Justified (Fig. 26): MSB on the first rising BCLK edge after the
 *               ADCLRC transition; LRC high = left channel (LRP=0).
 *        I2S (Fig. 27):            MSB one BCLK later; LRC low = left channel.
 *        Right-Justified (Fig. 28): LSB on the rising edge just before the
 *               next ADCLRC transition.
 *  Bits after the word are driven 0 (the datasheet leaves them unspecified).
 *  Before ACTIVE=1 all outputs are held low ("outputs default low", p.36).
 *
 *  The testbench supplies what the microphone "hears" on adc_left/adc_right
 *  (24-bit signed, the ADC's native width; shorter word lengths use the top
 *  bits). The sample is latched at the start of every frame and `frame_start`
 *  pulses for one BCLK so the testbench knows when to present the next one.
 * ----------------------------------------------------------------------------
 */
module wm8731_dai #(
    parameter bit VERBOSE = 1,
    parameter int MCLK_HZ = 18_432_000   // only used for the printed sample-rate summary
) (
    input  logic xck,                    // MCLK from the FPGA (AUD_XCK)
    input  logic [8:0] regs [0:9],       // register file (from wm8731_control_if, or constants)

    output logic bclk,
    output logic adclrc,
    output logic adcdat,
    output logic daclrc,
    input  logic dacdat,

    input  logic signed [23:0] adc_left,
    input  logic signed [23:0] adc_right,
    output logic frame_start,

    output logic signed [23:0] dac_left,
    output logic signed [23:0] dac_right,
    output logic dac_valid
);
    import wm8731_pkg::*;

    // ---- decode the registers we care about --------------------------------
    logic [1:0] format;  logic [1:0] iwl;  logic lrp, ms, bclkinv;
    logic usb, bosr, active, adc_powered;
    assign format      = regs[7][1:0];
    assign iwl         = regs[7][3:2];
    assign lrp         = regs[7][4];
    assign ms          = regs[7][6];
    assign bclkinv     = regs[7][7];
    assign usb         = regs[8][0];
    assign bosr        = regs[8][1];
    assign active      = regs[9][0];
    assign adc_powered = ~regs[6][2] & ~regs[6][7];  // ADCPD=0 and POWEROFF=0

    int word_bits;
    assign word_bits = iwl_bits(iwl);

    logic running;   // the interface is producing clocks
    assign running = active && ms && !usb;

    // ---- one-time warnings --------------------------------------------------
    logic warned_slave = 0, warned_usb = 0, warned_dsp = 0, warned_pd = 0;
    always @(posedge active) begin
        if (!ms && !warned_slave) begin
            warned_slave = 1;
            $display("[WM8731-DAI @%0t] Active with MS=0 (slave mode): BCLK and LRC would have to be driven by the FPGA. Slave mode is not modelled; outputs stay low.", $time);
        end
        if (usb && !warned_usb) begin
            warned_usb = 1;
            $display("[WM8731-DAI @%0t] USB clocking mode is not modelled; outputs stay low.", $time);
        end
        if (format == FORMAT_DSP && !warned_dsp) begin
            warned_dsp = 1;
            $display("[WM8731-DAI @%0t] DSP format is not modelled; the stream will look like Left-Justified.", $time);
        end
        if (!adc_powered && !warned_pd) begin
            warned_pd = 1;
            $display("[WM8731-DAI @%0t] note: interface active but the ADC is powered down (R6 ADCPD=%0d, POWEROFF=%0d). Real hardware would stream silence.", $time, regs[6][2], regs[6][7]);
        end
        if (running && VERBOSE)
            $display("[WM8731-DAI @%0t] interface ACTIVE: %s, %0d-bit words, master mode, BCLK = XCK/%0d = %0.0f Hz, fs = %0.0f Hz (MCLK %0.3f MHz, %s)",
                     $time, format_name(format), word_bits, bosr ? 6 : 4,
                     real'(MCLK_HZ) / (bosr ? 6.0 : 4.0), sample_rate_hz(regs[8], real'(MCLK_HZ)),
                     real'(MCLK_HZ) / 1.0e6, bosr ? "384fs" : "256fs");
    end

    // ---- BCLK: divide XCK by 4 or 6 ------------------------------------------
    int  xck_cnt = 0;
    logic bclk_int = 1'b0;
    always @(posedge xck) begin
        if (!running) begin
            xck_cnt  <= 0;
            bclk_int <= 1'b0;
        end else if (xck_cnt == (bosr ? 2 : 1)) begin
            xck_cnt  <= 0;
            bclk_int <= ~bclk_int;
        end else begin
            xck_cnt <= xck_cnt + 1;
        end
    end
    assign bclk = bclkinv ? ~bclk_int : bclk_int;

    // ---- frame position: 0..63 BCLKs per LRC period ----------------------------
    int slot = 0;                       // 0..31 left half, 32..63 right half
    logic started = 1'b0;               // first frame after activation has been set up
    always @(negedge running) started <= 1'b0;
    logic [31:0] word_l, word_r;        // MSB-aligned words being shifted out
    logic lrc_left_level;
    assign lrc_left_level = (format == FORMAT_I2S) ? lrp : ~lrp;  // which LRC level means "left"

    function automatic logic [31:0] to_word(input logic signed [23:0] s);
        // MSB-align the 24-bit sample into the word length; IWL=32 carries 24 bits + 8 zeros.
        return {s, 8'b0};
    endfunction

    // Which bit of the current word is on the line for this slot (-1 = none).
    function automatic int bit_for_slot(input int s);
        int pos = s % 32;
        case (format)
            FORMAT_I2S: return (pos >= 1 && pos <= word_bits) ? pos - 1 : -1;
            FORMAT_RJ:  return (pos >= 32 - word_bits) ? pos - (32 - word_bits) : -1;
            default:    return (pos < word_bits) ? pos : -1;              // LJ (and DSP approximated)
        endcase
    endfunction

    // Everything the chip drives changes on the FALLING edge of BCLK.
    always @(negedge bclk_int or negedge running or posedge running) begin
        if (!running) begin
            slot        <= 0;
            adclrc      <= 1'b0;
            adcdat      <= 1'b0;
            frame_start <= 1'b0;
        end else if (running && !bclk_int && slot == 0 && !started) begin
            // First frame after activation: LRC goes to "left" and the MSB is put on the line.
            started     <= 1'b1;
            word_l      <= to_word(adc_left);
            word_r      <= to_word(adc_right);
            adclrc      <= lrc_left_level;
            adcdat      <= (bit_for_slot(0) >= 0) ? to_word(adc_left)[31 - bit_for_slot(0)] : 1'b0;
            frame_start <= 1'b1;
        end else begin
            automatic int next_slot = (slot == 63) ? 0 : slot + 1;
            automatic int b;
            slot <= next_slot;
            if (next_slot == 0) begin
                // New frame: latch what the microphone hears right now.
                word_l      <= to_word(adc_left);
                word_r      <= to_word(adc_right);
                frame_start <= 1'b1;
            end else begin
                frame_start <= 1'b0;
            end
            adclrc <= (next_slot < 32) ? lrc_left_level : ~lrc_left_level;
            b = bit_for_slot(next_slot);
            if (b < 0)
                adcdat <= 1'b0;
            else if (next_slot < 32)
                adcdat <= (next_slot == 0) ? to_word(adc_left)[31 - b] : word_l[31 - b];
            else
                adcdat <= word_r[31 - b];
        end
    end
    assign daclrc = adclrc;   // same generator in master mode

    // ---- DAC data capture (what the FPGA sends to be played) --------------------
    logic [31:0] dac_shift_l = '0, dac_shift_r = '0;
    initial begin dac_left = '0; dac_right = '0; dac_valid = 1'b0; end
    always @(posedge bclk_int) begin
        if (running) begin
            automatic int b = bit_for_slot(slot);
            dac_valid <= 1'b0;
            if (b >= 0) begin
                if (slot < 32) dac_shift_l[31 - b] <= dacdat;
                else           dac_shift_r[31 - b] <= dacdat;
            end
            if (slot == 63) begin
                dac_left  <= dac_shift_l[31:8];
                dac_right <= {dac_shift_r[31:9], dacdat};
                dac_valid <= 1'b1;
            end
        end
    end

endmodule


/*
 * ----------------------------------------------------------------------------
 *  wm8731_model : the whole chip (control interface + audio interface).
 * ----------------------------------------------------------------------------
 */
module wm8731_model #(
    parameter bit VERBOSE = 1,
    parameter int MCLK_HZ = 18_432_000
) (
    // 2-wire control interface (FPGA_I2C_SCLK / FPGA_I2C_SDAT on the DE1-SoC)
    input  logic i2c_scl,
    inout  wire  i2c_sda,
    // Digital audio interface
    input  logic xck,       // AUD_XCK   (MCLK, driven by the FPGA)
    output logic bclk,      // AUD_BCLK  (driven by the chip in master mode)
    output logic adclrc,    // AUD_ADCLRCK
    output logic adcdat,    // AUD_ADCDAT
    output logic daclrc,    // AUD_DACLRCK
    input  logic dacdat,    // AUD_DACDAT
    // Test hooks
    input  logic signed [23:0] adc_left,
    input  logic signed [23:0] adc_right,
    output logic frame_start,
    output logic signed [23:0] dac_left,
    output logic signed [23:0] dac_right,
    output logic dac_valid
);
    import wm8731_pkg::*;

    logic [8:0] regs [0:9];
    int write_count, error_count, nack_count;

    wm8731_control_if #(.VERBOSE(VERBOSE)) ctrl (
        .scl(i2c_scl), .sda(i2c_sda), .regs(regs),
        .write_count(write_count), .error_count(error_count), .nack_count(nack_count)
    );

    wm8731_dai #(.VERBOSE(VERBOSE), .MCLK_HZ(MCLK_HZ)) dai (
        .xck(xck), .regs(regs),
        .bclk(bclk), .adclrc(adclrc), .adcdat(adcdat), .daclrc(daclrc), .dacdat(dacdat),
        .adc_left(adc_left), .adc_right(adc_right), .frame_start(frame_start),
        .dac_left(dac_left), .dac_right(dac_right), .dac_valid(dac_valid)
    );

    // Print a readable description of the chip state.
    task automatic print_summary();
        $display("---------------------------------------------------------------");
        $display("WM8731 model state at %0t: %0d register write(s) accepted, %0d protocol error(s), %0d byte(s) not acknowledged.",
                 $time, write_count, error_count, nack_count);
        for (int i = 0; i < 10; i++)
            $display("  %-34s = 0x%03h  %s", reg_name(7'(i)), regs[i], decode(7'(i), regs[i]));
        $display("  => Audio interface %s. Format %s, %0d-bit, %s mode.",
                 regs[9][0] ? "ACTIVE" : "inactive", format_name(regs[7][1:0]), iwl_bits(regs[7][3:2]),
                 regs[7][6] ? "MASTER" : "slave");
        $display("  => Sample rate with MCLK = %0.3f MHz: %0.0f Hz.", real'(MCLK_HZ) / 1.0e6, sample_rate_hz(regs[8], real'(MCLK_HZ)));
        $display("  => ADC input: %s, mic %s, ADC %s, mic pre-amp %s.",
                 regs[4][2] ? "MICROPHONE" : "line-in", regs[4][1] ? "MUTED" : "unmuted",
                 regs[6][2] ? "powered DOWN" : "powered up", regs[6][1] ? "powered DOWN" : "powered up");
        $display("---------------------------------------------------------------");
    endtask

    // Check that the chip is configured for microphone input the way the
    // course expects. Prints each problem found; returns the number of problems.
    function automatic int check_mic_input_config(input bit expect_lj = 1, input int expect_bits = 16, input int expect_fs = 48000);
        int problems = 0;
        if (!regs[9][0])        begin problems++; $display("  [config] R9 Active is 0: the audio interface is switched off, no BCLK/ADCDAT will be produced."); end
        if (!regs[7][6])        begin problems++; $display("  [config] R7 MS=0: the chip is in slave mode and would wait for the FPGA to drive BCLK/LRC. This course uses master mode (MS=1)."); end
        if (expect_lj && regs[7][1:0] != FORMAT_LJ) begin problems++; $display("  [config] R7 FORMAT=%b: expected Left-Justified (01), got %s.", regs[7][1:0], format_name(regs[7][1:0])); end
        if (iwl_bits(regs[7][3:2]) != expect_bits)  begin problems++; $display("  [config] R7 IWL: expected %0d-bit words, got %0d-bit.", expect_bits, iwl_bits(regs[7][3:2])); end
        if (!regs[4][2])        begin problems++; $display("  [config] R4 INSEL=0: the ADC is listening to line-in, not the microphone."); end
        if (regs[4][1])         begin problems++; $display("  [config] R4 MUTEMIC=1: the microphone is muted."); end
        if (regs[6][1])         begin problems++; $display("  [config] R6 MICPD=1: the microphone pre-amp is powered down."); end
        if (regs[6][2])         begin problems++; $display("  [config] R6 ADCPD=1: the ADC is powered down."); end
        if (regs[6][7])         begin problems++; $display("  [config] R6 POWEROFF=1: the whole chip is powered off."); end
        if (int'(sample_rate_hz(regs[8], real'(MCLK_HZ))) != expect_fs) begin problems++; $display("  [config] R8 with MCLK %0.3f MHz gives fs = %0.0f Hz, expected %0d Hz. Check BOSR (384fs for 18.432 MHz, 256fs for 12.288 MHz) and SR.", real'(MCLK_HZ) / 1.0e6, sample_rate_hz(regs[8], real'(MCLK_HZ)), expect_fs); end
        if (ctrl.write_order[9] >= 0) begin
            for (int i = 0; i < 9; i++)
                if (ctrl.write_order[i] > ctrl.write_order[9]) begin
                    problems++;
                    $display("  [config] %s was written AFTER R9 Active. The datasheet says to set Active last (p.57).", reg_name(7'(i)));
                end
        end
        if (problems == 0) $display("  [config] OK: configured for %0d-bit %s microphone input at %0d Hz, master mode.", expect_bits, format_name(regs[7][1:0]), expect_fs);
        return problems;
    endfunction

endmodule
