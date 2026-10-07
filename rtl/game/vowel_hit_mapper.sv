module vowel_hit_mapper (
    input  logic       vowel_valid,
    input  logic [1:0] vowel_id,

    output logic [3:0] vowel_lane_valid
);

    import assignment2_pkg::*;


    // ========================================================================
    // LIVE CHANGE -- VOWEL -> LANE MAPPING
    // ========================================================================
    // Class IDs are defined in assignment2_pkg:
    //   VOWEL_EE = ee ("see")
    //   VOWEL_AH = ah ("car")
    //   VOWEL_OO = oo ("boot")
    //   VOWEL_AW = aw ("law")
    //
    // Current one-hot mapping:
    //   ee -> lane 0 -> 0001
    //   ah -> lane 1 -> 0010
    //   oo -> lane 2 -> 0100
    //   aw -> lane 3 -> 1000
    //
    // To change which lane a vowel controls, change only the corresponding
    // one-hot value below. The classifier does not need to be retrained.
    // ========================================================================

    always_comb begin
        vowel_lane_valid = 4'b0000;

        if (vowel_valid) begin
            case (vowel_id)
                VOWEL_EE: vowel_lane_valid = 4'b0001;
                VOWEL_AH: vowel_lane_valid = 4'b0010;
                VOWEL_OO: vowel_lane_valid = 4'b0100;
                VOWEL_AW: vowel_lane_valid = 4'b1000;
                default:  vowel_lane_valid = 4'b0000;
            endcase
        end
    end

endmodule
