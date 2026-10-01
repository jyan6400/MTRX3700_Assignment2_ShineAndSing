`timescale 1ns/1ps

module vowel_hit_mapper_tb;

    logic       vowel_valid;
    logic [1:0] vowel_id;
    logic [3:0] vowel_lane_valid;

    vowel_hit_mapper DUT (
        .vowel_valid      (vowel_valid),
        .vowel_id         (vowel_id),
        .vowel_lane_valid (vowel_lane_valid)
    );

    task automatic check_mapping(
        input logic       valid,
        input logic [1:0] id,
        input logic [3:0] expected
    );
        begin
            vowel_valid = valid;
            vowel_id    = id;

            #1;

            if (vowel_lane_valid !== expected) begin
                $fatal(
                    1,
                    "FAIL: valid=%0b id=%0d expected=%b got=%b",
                    valid,
                    id,
                    expected,
                    vowel_lane_valid
                );
            end
        end
    endtask

    initial begin
        vowel_valid = 1'b0;
        vowel_id    = 2'd0;

        // No valid classification -> no lane event
        check_mapping(1'b0, 2'd0, 4'b0000);
        check_mapping(1'b0, 2'd1, 4'b0000);
        check_mapping(1'b0, 2'd2, 4'b0000);
        check_mapping(1'b0, 2'd3, 4'b0000);

        // Valid vowel mappings
        check_mapping(1'b1, 2'd0, 4'b0001); // ee
        check_mapping(1'b1, 2'd1, 4'b0010); // ah
        check_mapping(1'b1, 2'd2, 4'b0100); // oo
        check_mapping(1'b1, 2'd3, 4'b1000); // aw

        // Ensure output clears again
        check_mapping(1'b0, 2'd3, 4'b0000);

        $display("ALL TESTS PASSED: vowel_hit_mapper_tb");
        $finish;
    end

endmodule
