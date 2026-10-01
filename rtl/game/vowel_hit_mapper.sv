module vowel_hit_mapper (
    input  logic       vowel_valid,
    input  logic [1:0] vowel_id,

    output logic [3:0] vowel_lane_valid
);

    always_comb begin
        vowel_lane_valid = 4'b0000;

        if (vowel_valid) begin
            case (vowel_id)
                2'd0: vowel_lane_valid = 4'b0001; // ee -> lane 0
                2'd1: vowel_lane_valid = 4'b0010; // ah -> lane 1
                2'd2: vowel_lane_valid = 4'b0100; // oo -> lane 2
                2'd3: vowel_lane_valid = 4'b1000; // aw -> lane 3
                default: vowel_lane_valid = 4'b0000;
            endcase
        end
    end

endmodule
