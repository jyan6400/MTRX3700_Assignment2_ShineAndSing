module vowel_hit_mapper (
    input  logic       vowel_valid,
    input  logic [1:0] vowel_id,

    output logic [3:0] vowel_lane_valid
);

    import assignment2_pkg::*;

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
