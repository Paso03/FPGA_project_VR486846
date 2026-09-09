`timescale 1ns / 1ps

// ============================================================================
// HEART RATE MONITOR
// ============================================================================
//
// Input:
//   sample         : ECG sample, unsigned
//   sample_valid   : pulse indicating a new sample
//   sample_rate    : sampling frequency [samples/s]
//   threshold      : threshold used for beat detection
//
// Control:
//   clear          : reset acquisition/statistics
//   start          : start a new acquisition
//   stop           : stop acquisition
//
// Beat detection:
//   rising threshold crossing:
//       sample >= threshold
//       previous_sample < threshold
//
// Statistics:
//   beat_count      : total detected beats
//   last_interval   : samples between latest two beats
//   avg_interval    : integer average of measured intervals
//   bpm             : 60*Fs / avg_interval
//   min_bpm         : minimum instantaneous BPM
//   max_bpm         : maximum instantaneous BPM
//   sample_count    : number of processed samples
//
// No floating-point arithmetic is used.
// ============================================================================

module heart_rate_monitor #(
    parameter integer SAMPLE_WIDTH  = 16,
    parameter integer COUNTER_WIDTH = 32,
    parameter integer REFRACTORY    = 50
)(
    input wire clk,
    input wire rst,

    input wire clear,
    input wire start,
    input wire stop,

    input wire [SAMPLE_WIDTH-1:0] sample,
    input wire sample_valid,

    input wire [31:0] sample_rate,
    input wire [SAMPLE_WIDTH-1:0] threshold,

    output reg [15:0] bpm,
    output reg [15:0] min_bpm,
    output reg [15:0] max_bpm,

    output reg [COUNTER_WIDTH-1:0] beat_count,
    output reg [COUNTER_WIDTH-1:0] last_interval,
    output reg [COUNTER_WIDTH-1:0] avg_interval,
    output reg [COUNTER_WIDTH-1:0] sample_count,

    output reg beat_detected,
    output reg bpm_valid,
    output reg processing_done,
    output reg busy
);

    // ------------------------------------------------------------------------
    // Control edge detection
    // ------------------------------------------------------------------------

    reg sample_valid_d;
    reg start_d;
    reg stop_d;

    wire sample_pulse;
    wire start_pulse;
    wire stop_pulse;

    assign sample_pulse = sample_valid && !sample_valid_d;
    assign start_pulse  = start && !start_d;
    assign stop_pulse   = stop  && !stop_d;

    // ------------------------------------------------------------------------
    // Threshold / beat detection
    // ------------------------------------------------------------------------

    reg previous_above;

    wire above_threshold;
    wire rising_edge;

    assign above_threshold = (sample >= threshold);

    assign rising_edge =
        above_threshold && !previous_above;

    // ------------------------------------------------------------------------
    // Counters and statistics
    // ------------------------------------------------------------------------

    reg [COUNTER_WIDTH-1:0] interval_counter;

    reg [COUNTER_WIDTH-1:0] interval_sum;

    reg [COUNTER_WIDTH-1:0] interval_count;

    reg [COUNTER_WIDTH-1:0] refractory_counter;

    reg first_beat_seen;

    // ------------------------------------------------------------------------
    // Temporary arithmetic registers
    // ------------------------------------------------------------------------

    reg [63:0] new_interval_sum;
    reg [63:0] new_interval_count;
    reg [63:0] new_avg_interval;

    reg [63:0] current_bpm;
    reg [63:0] new_avg_bpm;

    // ------------------------------------------------------------------------
    // Main sequential logic
    // ------------------------------------------------------------------------

    always @(posedge clk or negedge rst)
    begin

        // ====================================================================
        // RESET
        // ====================================================================

        if (!rst)
        begin
            sample_valid_d     <= 1'b0;
            start_d            <= 1'b0;
            stop_d             <= 1'b0;

            previous_above     <= 1'b0;

            interval_counter   <= {COUNTER_WIDTH{1'b0}};
            interval_sum       <= {COUNTER_WIDTH{1'b0}};
            interval_count     <= {COUNTER_WIDTH{1'b0}};
            refractory_counter <= {COUNTER_WIDTH{1'b0}};

            first_beat_seen    <= 1'b0;

            bpm                <= 16'd0;
            min_bpm            <= 16'd0;
            max_bpm            <= 16'd0;

            beat_count         <= {COUNTER_WIDTH{1'b0}};
            last_interval      <= {COUNTER_WIDTH{1'b0}};
            avg_interval       <= {COUNTER_WIDTH{1'b0}};
            sample_count       <= {COUNTER_WIDTH{1'b0}};

            beat_detected      <= 1'b0;
            bpm_valid          <= 1'b0;
            processing_done    <= 1'b0;
            busy               <= 1'b0;
        end

        else
        begin

            // ----------------------------------------------------------------
            // Save previous control states
            // ----------------------------------------------------------------

            sample_valid_d <= sample_valid;
            start_d        <= start;
            stop_d         <= stop;

            // beat_detected is a one-clock pulse
            beat_detected <= 1'b0;

            // =================================================================
            // CLEAR
            // =================================================================

            if (clear)
            begin
                previous_above     <= 1'b0;

                interval_counter   <= {COUNTER_WIDTH{1'b0}};
                interval_sum       <= {COUNTER_WIDTH{1'b0}};
                interval_count     <= {COUNTER_WIDTH{1'b0}};
                refractory_counter <= {COUNTER_WIDTH{1'b0}};

                first_beat_seen    <= 1'b0;

                bpm                <= 16'd0;
                min_bpm             <= 16'd0;
                max_bpm             <= 16'd0;

                beat_count         <= {COUNTER_WIDTH{1'b0}};
                last_interval      <= {COUNTER_WIDTH{1'b0}};
                avg_interval       <= {COUNTER_WIDTH{1'b0}};
                sample_count       <= {COUNTER_WIDTH{1'b0}};

                bpm_valid          <= 1'b0;
                processing_done    <= 1'b0;
                busy               <= 1'b0;
            end

            else
            begin

                // =============================================================
                // START
                // =============================================================

                if (start_pulse)
                begin
                    previous_above     <= 1'b0;

                    interval_counter   <= {COUNTER_WIDTH{1'b0}};
                    interval_sum       <= {COUNTER_WIDTH{1'b0}};
                    interval_count     <= {COUNTER_WIDTH{1'b0}};
                    refractory_counter <= {COUNTER_WIDTH{1'b0}};

                    first_beat_seen    <= 1'b0;

                    bpm                <= 16'd0;
                    min_bpm             <= 16'd0;
                    max_bpm             <= 16'd0;

                    beat_count         <= {COUNTER_WIDTH{1'b0}};
                    last_interval      <= {COUNTER_WIDTH{1'b0}};
                    avg_interval       <= {COUNTER_WIDTH{1'b0}};
                    sample_count       <= {COUNTER_WIDTH{1'b0}};

                    bpm_valid          <= 1'b0;
                    processing_done    <= 1'b0;

                    busy               <= 1'b1;
                end

                else
                begin

                    // =========================================================
                    // STOP
                    // =========================================================

                    if (stop_pulse)
                    begin
                        busy            <= 1'b0;
                        processing_done <= 1'b1;
                    end

                    // =========================================================
                    // ACQUISITION
                    // =========================================================

                    if (busy && sample_pulse)
                    begin

                        // -----------------------------------------------------
                        // Count every processed sample
                        // -----------------------------------------------------

                        sample_count <= sample_count + 1'b1;

                        // -----------------------------------------------------
                        // Refractory period
                        // -----------------------------------------------------

                        if (refractory_counter > 0)
                        begin
                            refractory_counter <=
                                refractory_counter - 1'b1;
                        end

                        // -----------------------------------------------------
                        // BEAT DETECTION
                        // -----------------------------------------------------

                        if (rising_edge &&
                            (refractory_counter == 0))
                        begin

                            beat_detected <= 1'b1;

                            beat_count <=
                                beat_count + 1'b1;

                            refractory_counter <= REFRACTORY;

                            // =================================================
                            // FIRST BEAT
                            // =================================================

                            if (!first_beat_seen)
                            begin

                                first_beat_seen <= 1'b1;

                                interval_counter <=
                                    {COUNTER_WIDTH{1'b0}};
                            end

                            // =================================================
                            // SECOND OR LATER BEAT
                            // =================================================

                            else
                            begin

                                // -------------------------------------------------
                                // Current interval
                                // -------------------------------------------------

                                last_interval <=
                                    interval_counter + 1'b1;

                                // -------------------------------------------------
                                // New accumulated interval sum
                                // -------------------------------------------------

                                new_interval_sum =
                                    interval_sum
                                    + interval_counter
                                    + 1'b1;

                                interval_sum <=
                                    new_interval_sum[COUNTER_WIDTH-1:0];

                                // -------------------------------------------------
                                // New interval count
                                // -------------------------------------------------

                                new_interval_count =
                                    interval_count + 1'b1;

                                interval_count <=
                                    new_interval_count[COUNTER_WIDTH-1:0];

                                // -------------------------------------------------
                                // Average interval
                                // -------------------------------------------------

                                new_avg_interval =
                                    new_interval_sum /
                                    new_interval_count;

                                avg_interval <=
                                    new_avg_interval[
                                        COUNTER_WIDTH-1:0
                                    ];

                                // -------------------------------------------------
                                // Instantaneous BPM
                                // -------------------------------------------------

                                current_bpm =
                                    (64'd60 * sample_rate) /
                                    (interval_counter + 1'b1);

                                // -------------------------------------------------
                                // Average BPM
                                //
                                // BPM is calculated from average interval.
                                // -------------------------------------------------

                                if (new_avg_interval != 0)
                                begin

                                    new_avg_bpm =
                                        (64'd60 * sample_rate) /
                                        new_avg_interval;

                                    bpm <=
                                        new_avg_bpm[15:0];

                                    bpm_valid <= 1'b1;
                                end

                                // -------------------------------------------------
                                // Minimum / maximum instantaneous BPM
                                // -------------------------------------------------

                                if (interval_count == 0)
                                begin

                                    min_bpm <=
                                        current_bpm[15:0];

                                    max_bpm <=
                                        current_bpm[15:0];

                                end

                                else
                                begin

                                    if (current_bpm[15:0] < min_bpm)
                                    begin
                                        min_bpm <=
                                            current_bpm[15:0];
                                    end

                                    if (current_bpm[15:0] > max_bpm)
                                    begin
                                        max_bpm <=
                                            current_bpm[15:0];
                                    end

                                end

                                // -------------------------------------------------
                                // Start measuring next interval
                                // -------------------------------------------------

                                interval_counter <=
                                    {COUNTER_WIDTH{1'b0}};

                            end
                        end

                        // =====================================================
                        // NORMAL SAMPLE
                        // =====================================================

                        else if (first_beat_seen)
                        begin
                            interval_counter <=
                                interval_counter + 1'b1;
                        end

                        // -----------------------------------------------------
                        // Save current threshold state
                        // -----------------------------------------------------

                        previous_above <= above_threshold;

                    end
                end
            end
        end
    end

endmodule
