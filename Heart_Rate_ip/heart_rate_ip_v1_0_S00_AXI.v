`timescale 1 ns / 1 ps

module heart_rate_ip_v1_0_S00_AXI #
(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5
)
(
    // Global Clock Signal
    input wire S_AXI_ACLK,

    // Global Reset Signal. Active LOW
    input wire S_AXI_ARESETN,

    // Write address channel
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,
    input wire [2 : 0] S_AXI_AWPROT,
    input wire S_AXI_AWVALID,
    output wire S_AXI_AWREADY,

    // Write data channel
    input wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,
    input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
    input wire S_AXI_WVALID,
    output wire S_AXI_WREADY,

    // Write response channel
    output wire [1 : 0] S_AXI_BRESP,
    output wire S_AXI_BVALID,
    input wire S_AXI_BREADY,

    // Read address channel
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,
    input wire [2 : 0] S_AXI_ARPROT,
    input wire S_AXI_ARVALID,
    output wire S_AXI_ARREADY,

    // Read data channel
    output wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,
    output wire [1 : 0] S_AXI_RRESP,
    output wire S_AXI_RVALID,
    input wire S_AXI_RREADY
);

    // =========================================================================
    // AXI4-Lite internal signals
    // =========================================================================

    reg [C_S_AXI_ADDR_WIDTH-1 : 0] axi_awaddr;
    reg axi_awready;
    reg axi_wready;

    reg [1 : 0] axi_bresp;
    reg axi_bvalid;

    reg [C_S_AXI_ADDR_WIDTH-1 : 0] axi_araddr;
    reg axi_arready;

    reg [C_S_AXI_DATA_WIDTH-1 : 0] axi_rdata;
    reg [1 : 0] axi_rresp;
    reg axi_rvalid;

    reg aw_en;

    // =========================================================================
    // Address decoding
    //
    // 32-bit AXI data
    // 4 bytes per register
    //
    // ADDR_LSB = 2
    //
    // We need 4 address bits to select up to 16 locations:
    //
    // 0x00 -> selector 0
    // 0x04 -> selector 1
    // ...
    // 0x2C -> selector 11
    //
    // Therefore:
    // OPT_MEM_ADDR_BITS = 3
    // =========================================================================

    localparam integer ADDR_LSB = 2;
    localparam integer OPT_MEM_ADDR_BITS = 3;

    // =========================================================================
    // AXI registers
    //
    // 0x00 CONTROL
    // 0x04 SAMPLE
    // 0x08 STATUS
    // 0x0C BPM
    // 0x10 BEAT_COUNT
    // 0x14 LAST_INTERVAL
    // 0x18 AVG_INTERVAL
    // 0x1C MIN_BPM
    // 0x20 MAX_BPM
    // 0x24 SAMPLE_COUNT
    // 0x28 THRESHOLD
    // 0x2C SAMPLE_RATE
    // =========================================================================

    reg [31:0] slv_reg0;
    reg [31:0] slv_reg1;
    reg [31:0] slv_reg2;
    reg [31:0] slv_reg3;
    reg [31:0] slv_reg4;
    reg [31:0] slv_reg5;
    reg [31:0] slv_reg6;
    reg [31:0] slv_reg7;
    reg [31:0] slv_reg8;
    reg [31:0] slv_reg9;
    reg [31:0] slv_reg10;
    reg [31:0] slv_reg11;

    wire slv_reg_wren;
    wire slv_reg_rden;

    reg [C_S_AXI_DATA_WIDTH-1 : 0] reg_data_out;

    integer byte_index;

    // =========================================================================
    // Heart Rate Monitor wires
    // =========================================================================

    wire [15:0] hr_bpm;
    wire [15:0] hr_min_bpm;
    wire [15:0] hr_max_bpm;

    wire [31:0] hr_beat_count;
    wire [31:0] hr_last_interval;
    wire [31:0] hr_avg_interval;
    wire [31:0] hr_sample_count;

    wire hr_beat_detected;
    wire hr_bpm_valid;
    wire hr_processing_done;
    wire hr_busy;

    // =========================================================================
    // AXI outputs
    // =========================================================================

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;

    assign S_AXI_BRESP  = axi_bresp;
    assign S_AXI_BVALID = axi_bvalid;

    assign S_AXI_ARREADY = axi_arready;

    assign S_AXI_RDATA  = axi_rdata;
    assign S_AXI_RRESP  = axi_rresp;
    assign S_AXI_RVALID = axi_rvalid;

    // =========================================================================
    // AXI WRITE ADDRESS READY
    // =========================================================================

    always @(posedge S_AXI_ACLK)
    begin
        if (S_AXI_ARESETN == 1'b0)
        begin
            axi_awready <= 1'b0;
            aw_en       <= 1'b1;
        end
        else
        begin
            if (~axi_awready &&
                S_AXI_AWVALID &&
                S_AXI_WVALID &&
                aw_en)
            begin
                axi_awready <= 1'b1;
                aw_en       <= 1'b0;
            end
            else if (S_AXI_BREADY && axi_bvalid)
            begin
                aw_en       <= 1'b1;
                axi_awready <= 1'b0;
            end
            else
            begin
                axi_awready <= 1'b0;
            end
        end
    end

    // =========================================================================
    // LATCH WRITE ADDRESS
    // =========================================================================

    always @(posedge S_AXI_ACLK)
    begin
        if (S_AXI_ARESETN == 1'b0)
        begin
            axi_awaddr <= 0;
        end
        else
        begin
            if (~axi_awready &&
                S_AXI_AWVALID &&
                S_AXI_WVALID &&
                aw_en)
            begin
                axi_awaddr <= S_AXI_AWADDR;
            end
        end
    end

    // =========================================================================
    // AXI WRITE DATA READY
    // =========================================================================

    always @(posedge S_AXI_ACLK)
    begin
        if (S_AXI_ARESETN == 1'b0)
        begin
            axi_wready <= 1'b0;
        end
        else
        begin
            if (~axi_wready &&
                S_AXI_WVALID &&
                S_AXI_AWVALID &&
                aw_en)
            begin
                axi_wready <= 1'b1;
            end
            else
            begin
                axi_wready <= 1'b0;
            end
        end
    end

    // =========================================================================
    // WRITE ENABLE
    // =========================================================================

    assign slv_reg_wren =
        axi_wready &&
        S_AXI_WVALID &&
        axi_awready &&
        S_AXI_AWVALID;

    // =========================================================================
    // REGISTER WRITE LOGIC
    //
    // Only:
    //   slv_reg0  CONTROL
    //   slv_reg1  SAMPLE
    //   slv_reg10 THRESHOLD
    //   slv_reg11 SAMPLE_RATE
    //
    // are writable through AXI.
    //
    // slv_reg2 ... slv_reg9 are generated by the hardware core.
    // =========================================================================

    always @(posedge S_AXI_ACLK)
    begin
        if (S_AXI_ARESETN == 1'b0)
        begin
            // CONTROL
            slv_reg0 <= 32'd0;

            // SAMPLE
            slv_reg1 <= 32'd0;

            // STATUS
            slv_reg2 <= 32'd0;

            // BPM
            slv_reg3 <= 32'd0;

            // BEAT_COUNT
            slv_reg4 <= 32'd0;

            // LAST_INTERVAL
            slv_reg5 <= 32'd0;

            // AVG_INTERVAL
            slv_reg6 <= 32'd0;

            // MIN_BPM
            slv_reg7 <= 32'd0;

            // MAX_BPM
            slv_reg8 <= 32'd0;

            // SAMPLE_COUNT
            slv_reg9 <= 32'd0;

            // THRESHOLD
            slv_reg10 <= 32'd30000;

            // SAMPLE_RATE
            slv_reg11 <= 32'd250;
        end
        else
        begin

            // -----------------------------------------------------------------
            // SOFTWARE-WRITABLE REGISTERS
            // -----------------------------------------------------------------

            if (slv_reg_wren)
            begin

                case (
                    axi_awaddr[
                        ADDR_LSB + OPT_MEM_ADDR_BITS :
                        ADDR_LSB
                    ]
                )

                    // ---------------------------------------------------------
                    // 0x00 CONTROL
                    // ---------------------------------------------------------

                    4'h0:
                    begin
                        for (
                            byte_index = 0;
                            byte_index <= (C_S_AXI_DATA_WIDTH/8)-1;
                            byte_index = byte_index + 1
                        )
                        begin
                            if (S_AXI_WSTRB[byte_index] == 1'b1)
                            begin
                                slv_reg0[
                                    (byte_index*8) +: 8
                                ] <= S_AXI_WDATA[
                                    (byte_index*8) +: 8
                                ];
                            end
                        end
                    end

                    // ---------------------------------------------------------
                    // 0x04 SAMPLE
                    // ---------------------------------------------------------

                    4'h1:
                    begin
                        for (
                            byte_index = 0;
                            byte_index <= (C_S_AXI_DATA_WIDTH/8)-1;
                            byte_index = byte_index + 1
                        )
                        begin
                            if (S_AXI_WSTRB[byte_index] == 1'b1)
                            begin
                                slv_reg1[
                                    (byte_index*8) +: 8
                                ] <= S_AXI_WDATA[
                                    (byte_index*8) +: 8
                                ];
                            end
                        end
                    end

                    // ---------------------------------------------------------
                    // 0x08 STATUS - READ ONLY
                    // ---------------------------------------------------------

                    4'h2:
                    begin
                    end

                    // ---------------------------------------------------------
                    // 0x0C BPM - READ ONLY
                    // ---------------------------------------------------------

                    4'h3:
                    begin
                    end

                    // ---------------------------------------------------------
                    // 0x10 BEAT_COUNT - READ ONLY
                    // ---------------------------------------------------------

                    4'h4:
                    begin
                    end

                    // ---------------------------------------------------------
                    // 0x14 LAST_INTERVAL - READ ONLY
                    // ---------------------------------------------------------

                    4'h5:
                    begin
                    end

                    // ---------------------------------------------------------
                    // 0x18 AVG_INTERVAL - READ ONLY
                    // ---------------------------------------------------------

                    4'h6:
                    begin
                    end

                    // ---------------------------------------------------------
                    // 0x1C MIN_BPM - READ ONLY
                    // ---------------------------------------------------------

                    4'h7:
                    begin
                    end

                    // ---------------------------------------------------------
                    // 0x20 MAX_BPM - READ ONLY
                    // ---------------------------------------------------------

                    4'h8:
                    begin
                    end

                    // ---------------------------------------------------------
                    // 0x24 SAMPLE_COUNT - READ ONLY
                    // ---------------------------------------------------------

                    4'h9:
                    begin
                    end

                    // ---------------------------------------------------------
                    // 0x28 THRESHOLD
                    // ---------------------------------------------------------

                    4'hA:
                    begin
                        for (
                            byte_index = 0;
                            byte_index <= (C_S_AXI_DATA_WIDTH/8)-1;
                            byte_index = byte_index + 1
                        )
                        begin
                            if (S_AXI_WSTRB[byte_index] == 1'b1)
                            begin
                                slv_reg10[
                                    (byte_index*8) +: 8
                                ] <= S_AXI_WDATA[
                                    (byte_index*8) +: 8
                                ];
                            end
                        end
                    end

                    // ---------------------------------------------------------
                    // 0x2C SAMPLE_RATE
                    // ---------------------------------------------------------

                    4'hB:
                    begin
                        for (
                            byte_index = 0;
                            byte_index <= (C_S_AXI_DATA_WIDTH/8)-1;
                            byte_index = byte_index + 1
                        )
                        begin
                            if (S_AXI_WSTRB[byte_index] == 1'b1)
                            begin
                                slv_reg11[
                                    (byte_index*8) +: 8
                                ] <= S_AXI_WDATA[
                                    (byte_index*8) +: 8
                                ];
                            end
                        end
                    end

                    default:
                    begin
                    end

                endcase

            end

            // -----------------------------------------------------------------
            // HARDWARE-GENERATED REGISTERS
            // -----------------------------------------------------------------

            // STATUS
            //
            // bit 0 = BUSY
            // bit 1 = BEAT_DETECTED
            // bit 2 = BPM_VALID
            // bit 3 = PROCESSING_DONE
            //
            slv_reg2 <= {
                28'd0,
                hr_processing_done,
                hr_bpm_valid,
                hr_beat_detected,
                hr_busy
            };

            // BPM
            slv_reg3 <= {
                16'd0,
                hr_bpm
            };

            // BEAT_COUNT
            slv_reg4 <= hr_beat_count;

            // LAST_INTERVAL
            slv_reg5 <= hr_last_interval;

            // AVG_INTERVAL
            slv_reg6 <= hr_avg_interval;

            // MIN_BPM
            slv_reg7 <= {
                16'd0,
                hr_min_bpm
            };

            // MAX_BPM
            slv_reg8 <= {
                16'd0,
                hr_max_bpm
            };

            // SAMPLE_COUNT
            slv_reg9 <= hr_sample_count;

        end
    end

    // =========================================================================
    // AXI WRITE RESPONSE
    // =========================================================================

    always @(posedge S_AXI_ACLK)
    begin
        if (S_AXI_ARESETN == 1'b0)
        begin
            axi_bvalid <= 1'b0;
            axi_bresp  <= 2'b00;
        end
        else
        begin
            if (axi_awready &&
                S_AXI_AWVALID &&
                ~axi_bvalid &&
                axi_wready &&
                S_AXI_WVALID)
            begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b00;
            end
            else
            begin
                if (S_AXI_BREADY && axi_bvalid)
                begin
                    axi_bvalid <= 1'b0;
                end
            end
        end
    end

    // =========================================================================
    // AXI READ ADDRESS READY
    // =========================================================================

    always @(posedge S_AXI_ACLK)
    begin
        if (S_AXI_ARESETN == 1'b0)
        begin
            axi_arready <= 1'b0;
            axi_araddr  <= 32'b0;
        end
        else
        begin
            if (~axi_arready && S_AXI_ARVALID)
            begin
                axi_arready <= 1'b1;
                axi_araddr  <= S_AXI_ARADDR;
            end
            else
            begin
                axi_arready <= 1'b0;
            end
        end
    end

    // =========================================================================
    // READ ENABLE
    // =========================================================================

    assign slv_reg_rden =
        axi_arready &&
        S_AXI_ARVALID &&
        ~axi_rvalid;

    // =========================================================================
    // AXI READ VALID
    // =========================================================================

    always @(posedge S_AXI_ACLK)
    begin
        if (S_AXI_ARESETN == 1'b0)
        begin
            axi_rvalid <= 1'b0;
            axi_rresp  <= 2'b00;
        end
        else
        begin
            if (axi_arready &&
                S_AXI_ARVALID &&
                ~axi_rvalid)
            begin
                axi_rvalid <= 1'b1;
                axi_rresp  <= 2'b00;
            end
            else if (axi_rvalid && S_AXI_RREADY)
            begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    // =========================================================================
    // READ DECODER
    // =========================================================================

    always @(*)
    begin
        case (
            axi_araddr[
                ADDR_LSB + OPT_MEM_ADDR_BITS :
                ADDR_LSB
            ]
        )

            4'h0:
                reg_data_out = slv_reg0;

            4'h1:
                reg_data_out = slv_reg1;

            4'h2:
                reg_data_out = slv_reg2;

            4'h3:
                reg_data_out = slv_reg3;

            4'h4:
                reg_data_out = slv_reg4;

            4'h5:
                reg_data_out = slv_reg5;

            4'h6:
                reg_data_out = slv_reg6;

            4'h7:
                reg_data_out = slv_reg7;

            4'h8:
                reg_data_out = slv_reg8;

            4'h9:
                reg_data_out = slv_reg9;

            4'hA:
                reg_data_out = slv_reg10;

            4'hB:
                reg_data_out = slv_reg11;

            default:
                reg_data_out = 32'd0;

        endcase
    end

    // =========================================================================
    // READ DATA
    // =========================================================================

    always @(posedge S_AXI_ACLK)
    begin
        if (S_AXI_ARESETN == 1'b0)
        begin
            axi_rdata <= 32'd0;
        end
        else
        begin
            if (slv_reg_rden)
            begin
                axi_rdata <= reg_data_out;
            end
        end
    end

    // =========================================================================
    // HEART RATE MONITOR CORE
    // =========================================================================

    heart_rate_monitor #(
        .SAMPLE_WIDTH  (16),
        .COUNTER_WIDTH (32),
        .REFRACTORY    (50)
    )
    heart_rate_monitor_inst
    (
        .clk              (S_AXI_ACLK),
        .rst              (S_AXI_ARESETN),

        .clear            (slv_reg0[1]),
        .start            (slv_reg0[2]),
        .stop             (slv_reg0[3]),

        .sample           (slv_reg1[15:0]),
        .sample_valid     (slv_reg0[0]),

        .sample_rate      (slv_reg11),
        .threshold        (slv_reg10[15:0]),

        .bpm              (hr_bpm),
        .min_bpm          (hr_min_bpm),
        .max_bpm          (hr_max_bpm),

        .beat_count       (hr_beat_count),
        .last_interval    (hr_last_interval),
        .avg_interval     (hr_avg_interval),
        .sample_count     (hr_sample_count),

        .beat_detected    (hr_beat_detected),
        .bpm_valid        (hr_bpm_valid),
        .processing_done  (hr_processing_done),
        .busy             (hr_busy)
    );

endmodule