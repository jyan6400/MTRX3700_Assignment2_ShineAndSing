// =============================================================================
// audio_subsystem_tb.sv  --  NEW, Luke Mouawad
// Standalone audio subsystem test: FFT |X_k|^2 frames -> audio_features (R-A4)
// -> provided classifier -> vowel_valid / vowel_id. No game or video RTL.
//
// Stimulus: synthetic voiced vowels, one 1024-bin |X_k|^2 frame each, streamed
// in the FFT's bit-reversed output order. Each frame is a harmonic comb at the
// sung pitch F0, shaped by the vowel's first three formants (ee, ah, oo, aw),
// with Hamming-window main-lobe leakage (+-2 bins) and a -6 dB/octave tilt.
//
// Two passes (sim/audio/run_audio_tests.sh runs both):
//   +enrol=<file> : ENROLMENT, the simulation twin of the SignalTap enrolment.
//                   Each vowel is sung at NT = 4 pitches (110, 140, 170, 200 Hz);
//                   the RTL's own feature vectors are written to <file> as a
//                   templates.svh for the provided classifier (template t is
//                   class t / NT, the order classifier.sv expects).
//   (default)     : TEST, with the classifier compiled against those templates.
//
// Checks (all expectations computed here):
//   1. silence / gate low : features still produced, but vowel_valid never
//                           fires while voice_active is low (HEX2 blank)
//   2. one feature_valid per frame, for every frame sent (incl. after reset)
//   3. doubled amplitude  : every log-Mel feature within 3 LSB (R-A3/R-A4)
//   4. shifted pitch      : the 200 Hz and 220 Hz versions of each vowel are
//                           still nearest (L1) to their own 150 Hz reference
//                           (R-A4 pitch robustness); distances printed
//   5. vowels differ      : every pair of 150 Hz references is far apart
//   6. Contract A         : every cycle, vowel_valid == rising edge of
//                           (result_valid & !reject & voice_active), and
//                           vowel_id == classifier result at that event;
//                           accept and reject counts reported
//   6b. classifier accept : each vowel sung at 155 Hz and 185 Hz (pitches that
//                           were not enrolled), loud and quiet, is named
//                           correctly after the vote; accepts are counted
//   6c. classifier reject : frames with the gate closed are rejected (reject=1)
//                           and produce no event
//   7. gate drop          : after voice_active falls (2-FF sync), no events
//   8. reset mid-frame    : re-aligns, next frame gives exactly one vector
// =============================================================================
`timescale 1ns/1ps

module audio_subsystem_tb;
    localparam int N     = 1024;
    localparam int FS    = 12000;
    localparam int MAG_W = 33;
    localparam int D     = 24;
    localparam int FW    = 16;
    localparam real PI   = 3.14159265358979;
    localparam int GAP   = 3000;          // idle clocks between frames (classifier time)

    logic clk = 1'b0;
    always #27.127 clk = ~clk;            // 18.432 MHz FFT clock

    logic                  reset = 1'b1;
    logic [MAG_W-1:0]      mag_sq = '0;
    logic                  mag_valid = 1'b0;
    logic                  voice_active_async = 1'b0;
    logic [D-1:0][FW-1:0]  feature;
    logic                  feature_valid;
    logic                  vowel_valid;
    logic [1:0]            vowel_id;
    logic                  voice_active;
    logic [1:0]            classifier_result;
    logic                  classifier_result_valid, classifier_reject;
    logic [7:0]            confidence;

    audio_features #(.RUNG(4), .N(N), .MAG_W(MAG_W)) dut (
        .clk, .reset, .mag_sq, .mag_valid,
        .peak_k(10'd0), .peak_valid(1'b0),
        .voice_active_async,
        .feature, .feature_valid,
        .vowel_valid, .vowel_id,
        .voice_active, .classifier_result, .classifier_result_valid,
        .classifier_reject, .confidence);

    // ------------------------------------------------------------ vowel model
    // formants (Hz) and bandwidths (Hz) per vowel: 0 ee, 1 ah, 2 oo, 3 aw
    localparam real FMT [4][3] = '{'{270.0, 2290.0, 3010.0}, '{730.0, 1090.0, 2440.0},
                                   '{300.0,  870.0, 2240.0}, '{570.0,  840.0, 2410.0}};
    localparam real BWD [4][3] = '{'{60.0, 90.0, 120.0}, '{80.0, 90.0, 120.0},
                                   '{60.0, 80.0, 120.0}, '{70.0, 80.0, 120.0}};
    localparam real LEAK [5]   = '{0.02, 0.3, 1.0, 0.3, 0.02};
    localparam string VNAME [4] = '{"ee", "ah", "oo", "aw"};

    real spec [N];

    task automatic make_spec(input int v, input real f0, input real amp);
        for (int k = 0; k < N; k++) spec[k] = 0.0;
        for (int h = 1; h * f0 < 5500.0; h++) begin
            real f, env;
            int  k0;
            f   = h * f0;
            env = 0.0;
            for (int i = 0; i < 3; i++)
                env += 1.0 / (1.0 + ((f - FMT[v][i]) / BWD[v][i]) ** 2);
            env = env / (1.0 + f / 1000.0);
            k0  = int'($floor(f * N / FS + 0.5));
            for (int d = -2; d <= 2; d++)
                if (k0 + d >= 0 && k0 + d < N / 2)
                    spec[k0 + d] += LEAK[d + 2] * env * env * real'(1 << 28);
        end
        // quantise at unit gain, then apply the power gain amp^2 to the integer
        // spectrum -- what a linear FFT delivers for an amplitude-scaled input
        for (int k = 0; k < N; k++) spec[k] = $floor(spec[k]) * amp * amp;
    endtask

    function automatic int bitrev10(input int i);
        int r = 0;
        for (int j = 0; j < 10; j++) if (i[j]) r[9-j] = 1'b1;
        return r;
    endfunction

    // ------------------------------------------------------------ frame driver
    int frames_sent = 0, fv_count = 0;
    logic [D-1:0][FW-1:0] last_feat;
    always @(posedge clk) if (!reset && feature_valid) begin
        fv_count++;
        last_feat = feature;
    end

    task automatic send_frame();
        mag_valid <= 1'b1;
        for (int i = 0; i < N; i++) begin
            mag_sq <= MAG_W'(longint'($floor(spec[bitrev10(i)])));
            @(posedge clk);
        end
        mag_valid <= 1'b0;
        frames_sent++;
        repeat (GAP) @(posedge clk);
        if (fv_count != frames_sent)
            $fatal(1, "%0d feature_valid pulses for %0d frames", fv_count, frames_sent);
    endtask

    task automatic features_of(input int v, input real f0, input real amp,
                               output logic [D-1:0][FW-1:0] f);
        make_spec(v, f0, amp);
        send_frame();
        f = last_feat;
    endtask

    function automatic longint l1(input logic [D-1:0][FW-1:0] a, input logic [D-1:0][FW-1:0] b);
        longint s = 0;
        for (int m = 0; m < D; m++) s += (a[m] > b[m]) ? (a[m] - b[m]) : (b[m] - a[m]);
        return s;
    endfunction

    // ------------------------------------------------------------ Contract A monitor
    logic qual_prev = 1'b0;
    int   n_results_gated = 0;
    int   n_results = 0, n_accept = 0, n_reject = 0, n_events = 0, n_events_gated = 0;
    always @(posedge clk) begin
        if (reset) qual_prev <= 1'b0;
        else begin
            automatic logic qual = classifier_result_valid && !classifier_reject && voice_active;
            if (classifier_result_valid) begin
                n_results++;
                if (!voice_active) n_results_gated++;
                if (classifier_reject) n_reject++; else n_accept++;
            end
            qual_prev <= qual;
        end
    end

    logic       exp_valid_q = 1'b0;
    logic [1:0] exp_id_q = 2'd0;
    always @(posedge clk) begin
        if (reset) begin
            exp_valid_q <= 1'b0;
        end else begin
            automatic logic qual = classifier_result_valid && !classifier_reject && voice_active;
            if (vowel_valid !== exp_valid_q)
                $fatal(1, "vowel_valid=%b but expected %b (rule: result_valid & !reject & voice_active, one-shot)",
                       vowel_valid, exp_valid_q);
            if (vowel_valid && vowel_id !== exp_id_q)
                $fatal(1, "vowel_id=%0d but classifier said %0d", vowel_id, exp_id_q);
            if (vowel_valid) begin
                n_events++;
                if (!voice_active) n_events_gated++;
            end
            exp_valid_q <= qual && !qual_prev;
            if (qual && !qual_prev) exp_id_q <= classifier_result;
        end
    end

    // ------------------------------------------------------------ test sequence
    logic [D-1:0][FW-1:0] ref150 [4];
    logic [D-1:0][FW-1:0] f;

    // ------------------------------------------------------------ enrolment pass
    localparam int  NT_ENROL = 4;
    localparam real F0_ENROL [NT_ENROL] = '{110.0, 140.0, 170.0, 200.0};
    string enrol_file;

    task automatic enrol(input string fname);
        int fd;
        fd = $fopen(fname, "w");
        if (fd == 0) $fatal(1, "cannot write %s", fname);
        $fwrite(fd, "// templates.svh -- GENERATED by sim/audio/audio_subsystem_tb.sv +enrol\n");
        $fwrite(fd, "// Synthetic vowels (formant model) through the RTL feature pipeline, RUNG 4 (D = 24 log-Mel).\n");
        $fwrite(fd, "// Template t is class t / NT: 0 ee, 1 ah, 2 oo, 3 aw; NT = 4 pitches 110/140/170/200 Hz.\n");
        $fwrite(fd, "// For the board, replace with train_templates.py output from a SignalTap capture of real voices.\n");
        $fwrite(fd, "localparam logic [D-1:0][FW-1:0] TEMPLATES [0:NCLASS*NT-1] = '{\n");
        for (int v = 0; v < 4; v++)
            for (int p = 0; p < NT_ENROL; p++) begin
                logic [D-1:0][FW-1:0] t;
                features_of(v, F0_ENROL[p], 1.0, t);
                $fwrite(fd, "    {");
                for (int m = D - 1; m >= 0; m--) $fwrite(fd, "16'd%0d%s", t[m], (m == 0) ? "" : ", ");
                $fwrite(fd, "}%s   // t%0d %s %0.0f Hz\n", (v == 3 && p == NT_ENROL - 1) ? "" : ",",
                        v * NT_ENROL + p, VNAME[v], F0_ENROL[p]);
            end
        $fwrite(fd, "};\n");
        $fclose(fd);
    endtask

    // ------------------------------------------------------------ classifier result tracking
    int         run_accept = 0;
    logic [1:0] last_voted = 2'd0;
    always @(posedge clk)
        if (!reset && classifier_result_valid && !classifier_reject) begin
            run_accept++;
            last_voted = classifier_result;
        end

    initial begin
        repeat (5) @(posedge clk);
        reset <= 1'b0;
        repeat (5) @(posedge clk);

        if ($value$plusargs("enrol=%s", enrol_file)) begin
            enrol(enrol_file);
            $display("ENROLLED: %0d templates written to %s", 4 * NT_ENROL, enrol_file);
            $finish;
        end

        // 1. gate low: frames processed, never an event
        for (int v = 0; v < 4; v++) begin
            features_of(v, 150.0, 1.0, ref150[v]);
            features_of(v, 150.0, 1.0, f);
            if (f != ref150[v]) $fatal(1, "same frame gave different features");
        end
        if (n_events != 0) $fatal(1, "vowel_valid fired while voice_active was low");
        $display("1. gate low: %0d frames, 0 vowel events", frames_sent);

        // 5. references are distinct
        for (int a = 0; a < 4; a++)
            for (int b = a + 1; b < 4; b++)
                if (l1(ref150[a], ref150[b]) < 20000)
                    $fatal(1, "%s and %s features too similar (L1 %0d)", VNAME[a], VNAME[b], l1(ref150[a], ref150[b]));

        // 3. doubled amplitude
        for (int v = 0; v < 4; v++) begin
            features_of(v, 150.0, 2.0, f);
            for (int m = 0; m < D; m++)
                if ((f[m] > ref150[v][m] ? f[m] - ref150[v][m] : ref150[v][m] - f[m]) > 3)
                    $fatal(1, "%s 2x amplitude: feature %0d moved %0d -> %0d", VNAME[v], m, ref150[v][m], f[m]);
            $display("3. %s at 2x amplitude: L1 change %0d (max 3 per feature)", VNAME[v], l1(f, ref150[v]));
        end

        // 4. shifted pitch: nearest reference must be the same vowel
        for (int v = 0; v < 4; v++) begin
            automatic real pitches [2] = '{200.0, 220.0};
            for (int p = 0; p < 2; p++) begin
                automatic longint dmin = -1, dself = 0;
                automatic int     best = -1;
                features_of(v, pitches[p], 1.0, f);
                for (int u = 0; u < 4; u++) begin
                    automatic longint d = l1(f, ref150[u]);
                    if (u == v) dself = d;
                    if (dmin < 0 || d < dmin) begin dmin = d; best = u; end
                end
                $display("4. %s at %0.0f Hz: L1 to own 150 Hz ref %0d, nearest = %s",
                         VNAME[v], pitches[p], dself, VNAME[best]);
                if (best != v) $fatal(1, "%s at %0.0f Hz is nearest to %s", VNAME[v], pitches[p], VNAME[best]);
            end
        end

        // 6. gate high: sing every vowel, check Contract A on every result
        voice_active_async <= 1'b1;
        repeat (10) @(posedge clk);
        // 6b. classifier accept: unenrolled pitches, loud and quiet
        begin
            automatic real pitches [2] = '{155.0, 185.0};
            for (int p = 0; p < 2; p++)
                for (int v = 0; v < 4; v++) begin
                    run_accept = 0;
                    for (int r = 0; r < 7; r++) begin
                        make_spec(v, pitches[p], (r % 2) ? 2.0 : 1.0);
                        send_frame();
                    end
                    $display("6b. sang %s at %0.0f Hz for 7 frames: %0d accepted, voted %s",
                             VNAME[v], pitches[p], run_accept, VNAME[last_voted]);
                    if (run_accept < 4) $fatal(1, "%s at %0.0f Hz: only %0d of 7 frames accepted", VNAME[v], pitches[p], run_accept);
                    if (last_voted != 2'(v)) $fatal(1, "%s at %0.0f Hz was named %s", VNAME[v], pitches[p], VNAME[last_voted]);
                end
        end
        // a clearly higher note than any enrolled (probe 6), reported for the report
        for (int v = 0; v < 4; v++) begin
            run_accept = 0;
            for (int r = 0; r < 5; r++) begin make_spec(v, 240.0, 1.0); send_frame(); end
            $display("    info: %s at 240 Hz (above the enrolled 110-200 Hz): %0d/5 accepted, voted %s",
                     VNAME[v], run_accept, VNAME[last_voted]);
        end
        if (n_results == 0) $fatal(1, "classifier produced no result while enabled");
        $display("6. gate high: %0d classifier results (%0d accept, %0d reject) -> %0d vowel events",
                 n_results, n_accept, n_reject, n_events);

        // 7. gate drops while a frame is in flight (result arrives after the
        //    gate closed): the event must be suppressed, then no more events
        make_spec(1, 150.0, 1.0);
        mag_valid <= 1'b1;
        for (int i = 0; i < N; i++) begin
            mag_sq <= MAG_W'(longint'($floor(spec[bitrev10(i)])));
            @(posedge clk);
        end
        mag_valid <= 1'b0;
        @(posedge clk iff feature_valid);           // classifier has its input ...
        voice_active_async <= 1'b0;                 // ... and the singer stops
        frames_sent++;
        repeat (GAP) @(posedge clk);
        if (fv_count != frames_sent) $fatal(1, "missing feature_valid for in-flight frame");
        $display("7. gate closed mid-classification: %0d result(s) after close, 0 events",
                 n_results_gated);
        repeat (5) @(posedge clk);
        begin
            automatic int e0 = n_events;
            automatic int rj0 = n_reject, rs0 = n_results;
            for (int r = 0; r < 4; r++) begin make_spec(r, 150.0, 1.0); send_frame(); end
            if (n_events != e0) $fatal(1, "vowel event after the gate closed");
            if (n_results - rs0 != 4 || n_reject - rj0 != 4)
                $fatal(1, "6c. gate closed: expected 4 rejected results, got %0d results / %0d rejects",
                       n_results - rs0, n_reject - rj0);
            $display("6c. gate closed: 4 frames, 4 rejected results (classifier reject path), 0 events");
        end
        if (n_events_gated != 0) $fatal(1, "vowel_valid with voice_active low");
        $display("7. gate low again: no events");

        // 8. reset mid-frame
        make_spec(0, 150.0, 1.0);
        mag_valid <= 1'b1;
        for (int i = 0; i < 400; i++) begin mag_sq <= MAG_W'(1000); @(posedge clk); end
        mag_valid <= 1'b0;
        reset <= 1'b1; repeat (3) @(posedge clk); reset <= 1'b0;
        fv_count = 0; frames_sent = 0;
        repeat (5) @(posedge clk);
        features_of(0, 150.0, 1.0, f);
        if (f != ref150[0]) $fatal(1, "features after reset differ from reference");
        $display("8. reset mid-frame: realigned, features identical to reference");

        $display("ALL TESTS PASSED: audio_subsystem");
        $finish;
    end
endmodule
