`timescale 1ns / 1ps

// ============================================================================
// TESTBENCH - HEART RATE MONITOR
// ============================================================================
//
// Sampling rate:
//     250 Hz
//
// Beat intervals:
//     200, 195, 205, 210, 198, 202 samples
//
// Expected:
//
//     beat_count    = 7
//     last_interval = 202
//     avg_interval  = 201
//     bpm           = 74
//     min_bpm       = 71
//     max_bpm       = 76
//     sample_count  = 1215
//
// The R peak is 3 samples wide.
// Only the rising edge must generate beat_detected.
// ============================================================================

module tb_heart_rate_monitor;

    // ------------------------------------------------------------------------
    // Clock and reset
    // ------------------------------------------------------------------------

    reg clk;
    reg rst;

    // ------------------------------------------------------------------------
    // Control
    // ------------------------------------------------------------------------

    reg clear;
    reg start;
    reg stop;

    // ------------------------------------------------------------------------
    // Input
    // ------------------------------------------------------------------------

    reg [15:0] sample;
    reg        sample_valid;

    reg [31:0] sample_rate;
    reg [15:0] threshold;

    // ------------------------------------------------------------------------
    // Outputs
    // ------------------------------------------------------------------------

    wire [15:0] bpm;
    wire [15:0] min_bpm;
    wire [15:0] max_bpm;

    wire [31:0] beat_count;
    wire [31:0] last_interval;
    wire [31:0] avg_interval;
    wire [31:0] sample_count;

    wire beat_detected;
    wire bpm_valid;
    wire processing_done;
    wire busy;

    // ------------------------------------------------------------------------
    // Test variables
    // ------------------------------------------------------------------------

    integer errors;
    integer i;

    integer test_intervals [0:5];

    // ------------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------------

    heart_rate_monitor #(
        .SAMPLE_WIDTH  (16),
        .COUNTER_WIDTH (32),
        .REFRACTORY    (50)
    )
    dut
    (
        .clk              (clk),
        .rst              (rst),

        .clear            (clear),
        .start            (start),
        .stop             (stop),

        .sample           (sample),
        .sample_valid     (sample_valid),

        .sample_rate      (sample_rate),
        .threshold        (threshold),

        .bpm              (bpm),
        .min_bpm          (min_bpm),
        .max_bpm          (max_bpm),

        .beat_count       (beat_count),
        .last_interval    (last_interval),
        .avg_interval     (avg_interval),
        .sample_count     (sample_count),

        .beat_detected    (beat_detected),
        .bpm_valid        (bpm_valid),
        .processing_done  (processing_done),
        .busy             (busy)
    );

    // ------------------------------------------------------------------------
    // 100 MHz clock
    // ------------------------------------------------------------------------

    always #5 clk = ~clk;

    // ------------------------------------------------------------------------
    // Send one sample
    //
    // sample_valid is high for one complete clock period.
    // ------------------------------------------------------------------------

    task send_sample;
        input [15:0] value;

        begin

            @(negedge clk);

            sample = value;

            sample_valid = 1'b1;

            @(negedge clk);

            sample_valid = 1'b0;

        end
    endtask

    // ------------------------------------------------------------------------
    // Send one ECG R peak
    //
    // 0
    // 40000 <- rising crossing / beat
    // 40000
    // 40000
    // 0
    // ------------------------------------------------------------------------

    task send_beat;

        begin

            send_sample(16'd0);

            send_sample(16'd40000);

            send_sample(16'd40000);

            send_sample(16'd40000);

            send_sample(16'd0);

        end

    endtask

    // ------------------------------------------------------------------------
    // Generate exact interval between rising threshold crossings.
    // ------------------------------------------------------------------------

    task wait_interval;

        input integer interval_value;

        integer j;

        begin

            // Three samples have already occurred after the previous
            // rising edge inside send_beat().
            //
            // Therefore:
            //
            //   3 + (interval - 4) + 1 = interval
            //
            // samples separate the two rising edges.

            for (j = 0;
                 j < interval_value - 4;
                 j = j + 1)
            begin
                send_sample(16'd0);
            end

            // Next rising edge
            send_sample(16'd40000);
            send_sample(16'd40000);
            send_sample(16'd40000);
            send_sample(16'd0);

        end

    endtask

    // ------------------------------------------------------------------------
    // START pulse
    // ------------------------------------------------------------------------

    task pulse_start;

        begin

            @(negedge clk);

            start = 1'b1;

            @(negedge clk);

            start = 1'b0;

        end

    endtask

    // ------------------------------------------------------------------------
    // STOP pulse
    // ------------------------------------------------------------------------

    task pulse_stop;

        begin

            @(negedge clk);

            stop = 1'b1;

            @(negedge clk);

            stop = 1'b0;

        end

    endtask

    // ------------------------------------------------------------------------
    // MAIN TEST
    // ------------------------------------------------------------------------

    initial
    begin

        // ---------------------------------------------------------------
        // Interval sequence
        // ---------------------------------------------------------------

        test_intervals[0] = 200;
        test_intervals[1] = 195;
        test_intervals[2] = 205;
        test_intervals[3] = 210;
        test_intervals[4] = 198;
        test_intervals[5] = 202;

        errors = 0;

        // ---------------------------------------------------------------
        // Initial values
        // ---------------------------------------------------------------

        clk = 1'b0;

        rst = 1'b0;

        clear = 1'b0;
        start = 1'b0;
        stop  = 1'b0;

        sample = 16'd0;
        sample_valid = 1'b0;

        sample_rate = 32'd250;

        threshold = 16'd30000;

        // ---------------------------------------------------------------
        // Reset
        // ---------------------------------------------------------------

        #30;

        rst = 1'b1;

        // ---------------------------------------------------------------
        // Start acquisition
        // ---------------------------------------------------------------

        pulse_start();

        // ---------------------------------------------------------------
        // First beat
        // ---------------------------------------------------------------

        send_beat();

        // ---------------------------------------------------------------
        // Six variable intervals
        // ---------------------------------------------------------------

        for (i = 0; i < 6; i = i + 1)
        begin
            wait_interval(test_intervals[i]);
        end

        // ---------------------------------------------------------------
        // Stop acquisition
        // ---------------------------------------------------------------

        pulse_stop();

        // Give STOP time to propagate
        repeat (3)
            @(posedge clk);

        // ---------------------------------------------------------------
        // REPORT
        // ---------------------------------------------------------------

        $display("");
        $display("============================================================");
        $display("       HEART RATE MONITOR - TEST RESULTS");
        $display("============================================================");

        $display("Beat count       : %0d", beat_count);
        $display("Last interval    : %0d", last_interval);
        $display("Average interval : %0d", avg_interval);
        $display("Average BPM      : %0d", bpm);
        $display("Minimum BPM      : %0d", min_bpm);
        $display("Maximum BPM      : %0d", max_bpm);
        $display("Sample count     : %0d", sample_count);

        $display("Busy             : %0d", busy);
        $display("BPM valid        : %0d", bpm_valid);
        $display("Processing done  : %0d", processing_done);

        $display("============================================================");

        // ---------------------------------------------------------------
        // CHECK BEAT COUNT
        // ---------------------------------------------------------------

        if (beat_count != 32'd7)
        begin
            $display(
                "ERROR: beat_count expected=7 got=%0d",
                beat_count
            );

            errors = errors + 1;
        end
        else
        begin
            $display("PASS: beat_count = 7");
        end

        // ---------------------------------------------------------------
        // CHECK LAST INTERVAL
        // ---------------------------------------------------------------

        if (last_interval != 32'd202)
        begin
            $display(
                "ERROR: last_interval expected=202 got=%0d",
                last_interval
            );

            errors = errors + 1;
        end
        else
        begin
            $display("PASS: last_interval = 202");
        end

        // ---------------------------------------------------------------
        // CHECK AVERAGE INTERVAL
        // ---------------------------------------------------------------

        if (avg_interval != 32'd201)
        begin
            $display(
                "ERROR: avg_interval expected=201 got=%0d",
                avg_interval
            );

            errors = errors + 1;
        end
        else
        begin
            $display("PASS: avg_interval = 201");
        end

        // ---------------------------------------------------------------
        // CHECK AVERAGE BPM
        // ---------------------------------------------------------------

        if (bpm != 16'd74)
        begin
            $display(
                "ERROR: bpm expected=74 got=%0d",
                bpm
            );

            errors = errors + 1;
        end
        else
        begin
            $display("PASS: bpm = 74");
        end

        // ---------------------------------------------------------------
        // CHECK MIN BPM
        // ---------------------------------------------------------------

        if (min_bpm != 16'd71)
        begin
            $display(
                "ERROR: min_bpm expected=71 got=%0d",
                min_bpm
            );

            errors = errors + 1;
        end
        else
        begin
            $display("PASS: min_bpm = 71");
        end

        // ---------------------------------------------------------------
        // CHECK MAX BPM
        // ---------------------------------------------------------------

        if (max_bpm != 16'd76)
        begin
            $display(
                "ERROR: max_bpm expected=76 got=%0d",
                max_bpm
            );

            errors = errors + 1;
        end
        else
        begin
            $display("PASS: max_bpm = 76");
        end

        // ---------------------------------------------------------------
        // CHECK BPM VALID
        // ---------------------------------------------------------------

        if (!bpm_valid)
        begin
            $display(
                "ERROR: bpm_valid expected=1 got=0"
            );

            errors = errors + 1;
        end
        else
        begin
            $display("PASS: bpm_valid = 1");
        end

        // ---------------------------------------------------------------
        // CHECK BUSY
        // ---------------------------------------------------------------

        if (busy != 1'b0)
        begin
            $display(
                "ERROR: busy expected=0 after STOP got=%0d",
                busy
            );

            errors = errors + 1;
        end
        else
        begin
            $display("PASS: busy = 0 after STOP");
        end

        // ---------------------------------------------------------------
        // CHECK PROCESSING DONE
        // ---------------------------------------------------------------

        if (!processing_done)
        begin
            $display(
                "ERROR: processing_done expected=1 got=0"
            );

            errors = errors + 1;
        end
        else
        begin
            $display("PASS: processing_done = 1");
        end

        // ---------------------------------------------------------------
        // CHECK SAMPLE COUNT
        //
        // First send_beat:
        //     5 samples
        //
        // Intervals:
        //     200 + 195 + 205 + 210 + 198 + 202 = 1210
        //
        // Total:
        //     5 + 1210 = 1215
        // ---------------------------------------------------------------

        if (sample_count != 32'd1215)
        begin
            $display(
                "ERROR: sample_count expected=1215 got=%0d",
                sample_count
            );

            errors = errors + 1;
        end
        else
        begin
            $display("PASS: sample_count = 1215");
        end

        // ---------------------------------------------------------------
        // FINAL RESULT
        // ---------------------------------------------------------------

        $display("");
        $display("============================================================");

        if (errors == 0)
        begin
            $display("                 ALL TESTS PASSED");
        end
        else
        begin
            $display(
                "                 TEST FAILED: %0d error(s)",
                errors
            );
        end

        $display("============================================================");
        $display("");

        $finish;

    end

endmodule