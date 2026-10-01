`timescale 1ns/1ps
// =============================================================================
// band_normalise.sv  --  NEW, Luke Mouawad, R-A3 (normalised band energies)
// -----------------------------------------------------------------------------
// Divides every band energy by the total energy of the frame:
//
//      total      = sum_b band_acc[b]                      (ACC_W+3 bits, exact)
//      feature[b] = min(65535, floor(band_acc[b] * 2^16 / total))   unsigned Q0.16
//      total == 0 -> every feature = 0
//
// The result is the fraction of the frame's energy in each band, so a gain g
// on the microphone (energy x g^2) cancels exactly: 2x amplitude gives the
// same feature vector (bit-exact, since floor(4b*2^16 / 4T) = floor(b*2^16/T)).
// Only a band holding all the energy (fraction 1.0 = 65536) saturates.
//
// Implementation: one restoring divider shared by the 8 bands, one quotient
// bit per clock, 17 quotient bits per band (band <= total so q <= 2^16):
//      LATENCY = 1 (total) + NB * 17 + 1 = 138 clocks for NB = 8,
// far below the 1.5 M FFT clocks in one 85 ms frame. in_valid while busy is
// ignored (cannot happen at one frame per 85 ms). Remainder register is
// ACC_W+4 bits (holds < 2*total), so there is no truncation anywhere: the
// only loss is the floor of the quotient.
//
// Clock/reset domain : FFT clock, synchronous active-high reset.
// Handshake          : in_valid (pulse, from band_energy_8.feature_valid) ->
//                      feature_valid (pulse); feature held until the next.
// =============================================================================
module band_normalise #(
    parameter int NB    = 8,
    parameter int ACC_W = 42
) (
    input  logic                     clk,
    input  logic                     reset,
    input  logic [NB-1:0][ACC_W-1:0] band_acc,
    input  logic                     in_valid,
    output logic [NB-1:0][15:0]      feature,
    output logic                     feature_valid,
    output logic                     busy
);
    localparam int TOT_W = ACC_W + $clog2(NB);
    localparam int REM_W = TOT_W + 1;
    localparam int QB    = 17;                   // quotient bits 16..0

    typedef enum logic [1:0] {IDLE, SUM, DIV} state_t;
    state_t state;

    logic [NB-1:0][ACC_W-1:0] bands;             // latched inputs
    logic [TOT_W-1:0]         total;
    logic [REM_W-1:0]         rem;
    logic [QB-1:0]            q;
    logic [$clog2(NB)-1:0]    b_idx;
    logic [$clog2(QB)-1:0]    bit_idx;

    logic [TOT_W-1:0] total_c;
    always_comb begin
        total_c = '0;
        for (int b = 0; b < NB; b++) total_c += TOT_W'(bands[b]);
    end

    // one restoring step: shift in, compare, subtract
    logic [REM_W-1:0] trial;
    logic             ge;
    always_comb begin
        trial = (bit_idx == $clog2(QB)'(QB - 1)) ? rem : (rem << 1);
        ge    = (trial >= REM_W'(total));
    end

    assign busy = (state != IDLE);

    always_ff @(posedge clk) begin
        if (reset) begin
            state         <= IDLE;
            bands         <= '0;
            total         <= '0;
            rem           <= '0;
            q             <= '0;
            b_idx         <= '0;
            bit_idx       <= '0;
            feature       <= '0;
            feature_valid <= 1'b0;
        end else begin
            feature_valid <= 1'b0;
            case (state)
                IDLE: if (in_valid) begin
                    bands <= band_acc;
                    state <= SUM;
                end
                SUM: begin
                    total   <= total_c;
                    b_idx   <= '0;
                    bit_idx <= $clog2(QB)'(QB - 1);
                    rem     <= REM_W'(bands[0]);
                    q       <= '0;
                    state   <= DIV;
                end
                DIV: begin
                    rem <= ge ? (trial - REM_W'(total)) : trial;
                    q   <= {q[QB-2:0], ge};
                    if (bit_idx != '0) begin
                        bit_idx <= bit_idx - 1'b1;
                    end else begin
                        // quotient complete for band b_idx
                        if (total == '0)          feature[b_idx] <= 16'd0;
                        else if (q[QB-2] /*q16*/) feature[b_idx] <= 16'hFFFF;
                        else                      feature[b_idx] <= {q[QB-3:0], ge};
                        if (b_idx == $clog2(NB)'(NB - 1)) begin
                            feature_valid <= 1'b1;
                            state         <= IDLE;
                        end else begin
                            b_idx   <= b_idx + 1'b1;
                            bit_idx <= $clog2(QB)'(QB - 1);
                            rem     <= REM_W'(bands[b_idx + 1'b1]);
                            q       <= '0;
                        end
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
