`timescale 1ns/1ps

module rng_tb;

    localparam int OFFSET    = 200;
    localparam int MAX_VALUE = 1223;

    logic clk;

    logic [$clog2(MAX_VALUE)-1:0] random_value;


    rng #(
        .OFFSET(OFFSET),
        .MAX_VALUE(MAX_VALUE),
        .SEED(10'b0000000001)
    ) DUT (
        .clk(clk),
        .random_value(random_value)
    );


    initial clk = 1'b0;
    always #5 clk <= ~clk;


    task automatic step;
        begin
            @(posedge clk);
            #1;
        end
    endtask


    integer i;
    logic [$clog2(MAX_VALUE)-1:0] previous_value;
    logic changed;


    initial begin

        if ($test$plusargs("dump")) begin
            $dumpfile("waveform.fst");
            $dumpvars(0, rng_tb);
        end


        // ================================================================
        // TEST 1
        // Seed=1 plus OFFSET=200 gives initial output 201.
        // ================================================================

        #1;

        if (random_value !== 11'd201)
            $fatal(
                1,
                "FAIL [TEST1 seed]: expected 201 actual=%0d",
                random_value
            );


        // ================================================================
        // TEST 2
        // Verify the first few deterministic LFSR shifts.
        // ================================================================

        step();

        if (random_value !== 11'd202)
            $fatal(
                1,
                "FAIL [TEST2 sequence 1]: expected 202 actual=%0d",
                random_value
            );

        step();

        if (random_value !== 11'd204)
            $fatal(
                1,
                "FAIL [TEST2 sequence 2]: expected 204 actual=%0d",
                random_value
            );

        step();

        if (random_value !== 11'd208)
            $fatal(
                1,
                "FAIL [TEST2 sequence 3]: expected 208 actual=%0d",
                random_value
            );


        // ================================================================
        // TEST 3
        // Output remains within the intended offset LFSR range.
        // ================================================================

        for (i = 0; i < 100; i = i + 1) begin

            step();

            if ((random_value < OFFSET) ||
                (random_value > MAX_VALUE))
                $fatal(
                    1,
                    "FAIL [TEST3 range]: random_value=%0d",
                    random_value
                );

        end


        // ================================================================
        // TEST 4
        // Generator must not be stuck at a single value.
        // ================================================================

        previous_value = random_value;
        changed        = 1'b0;

        for (i = 0; i < 20; i = i + 1) begin

            step();

            if (random_value !== previous_value)
                changed = 1'b1;

            previous_value = random_value;

        end

        if (!changed)
            $fatal(
                1,
                "FAIL [TEST4]: RNG output is stuck"
            );


        $display("ALL TESTS PASSED: rng_tb");
        $finish;

    end

endmodule