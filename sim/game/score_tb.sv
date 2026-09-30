`timescale 1ns/1ps

module score_tb;

    logic       clk;
    logic       reset;
    logic [3:0] valid_hit;

    logic [6:0] score;


    score DUT (
        .clk(clk),
        .reset(reset),
        .valid_hit(valid_hit),
        .score(score)
    );


    initial clk = 1'b0;
    always #5 clk <= ~clk;


    task automatic step;
        begin
            @(posedge clk);
            #1;
        end
    endtask


    task automatic check_score (
        input logic [6:0] expected,
        input string      what
    );
        begin

            if (score !== expected)
                $fatal(
                    1,
                    "FAIL [%s]: expected score=%0d actual=%0d",
                    what,
                    expected,
                    score
                );

        end
    endtask


    task automatic apply_hits (
        input logic [3:0] hits
    );
        begin

            valid_hit = hits;

            @(posedge clk);
            #1;

            valid_hit = 4'b0000;

        end
    endtask


    integer i;

    initial begin

        if ($test$plusargs("dump")) begin
            $dumpfile("waveform.fst");
            $dumpvars(0, score_tb);
        end

        reset     = 1'b1;
        valid_hit = 4'b0000;


        // ================================================================
        // TEST 1
        // Reset score to zero.
        // ================================================================

        step();

        check_score(
            7'd0,
            "TEST1 reset"
        );

        reset = 1'b0;


        // ================================================================
        // TEST 2
        // One hit = +1.
        // ================================================================

        apply_hits(4'b0001);

        check_score(
            7'd1,
            "TEST2 one hit"
        );


        // ================================================================
        // TEST 3
        // Two simultaneous hits = +2.
        // ================================================================

        apply_hits(4'b0101);

        check_score(
            7'd3,
            "TEST3 two hits"
        );


        // ================================================================
        // TEST 4
        // No hit leaves score unchanged.
        // ================================================================

        repeat (3) step();

        check_score(
            7'd3,
            "TEST4 no hit"
        );


        // ================================================================
        // TEST 5
        // Four simultaneous hits = +4.
        // ================================================================

        apply_hits(4'b1111);

        check_score(
            7'd7,
            "TEST5 four hits"
        );


        // ================================================================
        // TEST 6
        // Build score from 7 to 95.
        // ================================================================

        for (i = 0; i < 22; i = i + 1)
            apply_hits(4'b1111);

        check_score(
            7'd95,
            "TEST6 score 95"
        );


        // ================================================================
        // TEST 7
        // Four additional hits reach 99.
        // ================================================================

        apply_hits(4'b1111);

        check_score(
            7'd99,
            "TEST7 score 99"
        );


        // ================================================================
        // TEST 8
        // Score saturates at 99.
        // ================================================================

        apply_hits(4'b1111);

        check_score(
            7'd99,
            "TEST8 four-hit overflow"
        );

        apply_hits(4'b0001);

        check_score(
            7'd99,
            "TEST8 one-hit overflow"
        );


        // ================================================================
        // TEST 9
        // Reset after reaching 99 returns score to zero.
        // ================================================================

        reset = 1'b1;

        step();

        check_score(
            7'd0,
            "TEST9 reset from 99"
        );


        $display("ALL TESTS PASSED: score_tb");
        $finish;

    end

endmodule