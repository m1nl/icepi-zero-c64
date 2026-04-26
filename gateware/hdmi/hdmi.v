// Implementation of HDMI Spec v1.4a
// By Sameer Puri https://github.com/sameer
// Converted from SystemVerilog to Verilog

module hdmi
#(
    parameter DVI_OUTPUT = 1'b0,
    parameter IT_CONTENT = 1'b1,
    parameter VIDEO_ID_CODE = 0,
    parameter VIDEO_RATE = 27000000,
    parameter AUDIO_RATE = 48000,
    parameter AUDIO_BIT_WIDTH = 24,
    parameter BIT_WIDTH = VIDEO_ID_CODE < 4 ? 10 : VIDEO_ID_CODE == 4 ? 11 : 12,
    parameter BIT_HEIGHT = VIDEO_ID_CODE == 16 ? 11: 10,
    parameter [BIT_WIDTH-1:0] SCREEN_X_START = 132,
    parameter [BIT_WIDTH-1:0] SCREEN_X_END = 852,
    parameter [BIT_HEIGHT-1:0] SCREEN_Y_START = 16,
    parameter [BIT_HEIGHT-1:0] SCREEN_Y_END = 592,
    parameter [BIT_WIDTH-1:0] FRAME_WIDTH = 882,
    parameter [BIT_HEIGHT-1:0] FRAME_HEIGHT = 624,
    parameter [8*8-1:0] VENDOR_NAME = 64'h556e6b6e6f776e00, // "Unknown" + nulls
    parameter [8*16-1:0] PRODUCT_DESCRIPTION = 128'h46504741000000000000000000000000, // "FPGA" + nulls
    parameter [7:0] SOURCE_DEVICE_INFORMATION = 8'h09 // See README.md or CTA-861-G for the list of valid codes
)
(
    input clk_pixel_x5,
    input clk_pixel,

    // synchronous reset back to 0,0
    input reset,

    input [23:0] rgb,
    input hsync,
    input vsync,
    input [BIT_WIDTH-1:0] cx,
    input [BIT_HEIGHT-1:0] cy,
    input de,

    input [AUDIO_BIT_WIDTH-1:0] audio_sample_word_0,
    input [AUDIO_BIT_WIDTH-1:0] audio_sample_word_1,
    output audio_sample_en,

    output [9:0] tmds_0,
    output [9:0] tmds_1,
    output [9:0] tmds_2
);

reg [2:0] mode;
reg [23:0] video_data;
reg [5:0] control_data;
reg [11:0] data_island_data;

generate
    if (!DVI_OUTPUT)
    begin: true_hdmi_output
        reg video_guard;
        reg video_preamble;
        always @(posedge clk_pixel)
        begin
            if (reset)
            begin
                video_guard <= 0;
                video_preamble <= 0;
            end
            else
            begin
                video_guard <= cx >= (SCREEN_X_START - 2) && cx < SCREEN_X_START && cy >= SCREEN_Y_START && cy < SCREEN_Y_END;
                video_preamble <= cx >= (SCREEN_X_START - 10) && cx < (SCREEN_X_START - 2) && cy >= SCREEN_Y_START && cy < SCREEN_Y_END;
            end
        end

        reg data_island_sync;
        reg data_island_guard;
        reg data_island_trail;
        reg data_island_preamble;
        reg data_island_period;
        reg [4:0] data_island_offset;

        wire data_island_period_instantaneous;
        wire video_field_end;
        wire packet_enable;

        // See Section 5.2.3.1
        localparam [BIT_WIDTH-1:0] MAX_NUM_PACKETS_ALONGSIDE = (SCREEN_X_START + (FRAME_WIDTH - SCREEN_X_END) /* VD period */ - 2 /* V guard */ - 8 /* V preamble */ - 4 /* Min V control period */ - 2 /* DI trailing guard */ - 2 /* DI leading guard */ - 8 /* DI preamable */ - 4 /* Min DI control period */) / 32;
        localparam [4:0] NUM_PACKETS_ALONGSIDE = (MAX_NUM_PACKETS_ALONGSIDE > 18) ? 5'd18 : MAX_NUM_PACKETS_ALONGSIDE[4:0];

        localparam [BIT_WIDTH-1:0] DATA_ISLAND_PREAMBLE_START = (SCREEN_X_END + 4) % FRAME_WIDTH;
        localparam [BIT_WIDTH-1:0] DATA_ISLAND_PREAMBLE_END = (SCREEN_X_END + 12) % FRAME_WIDTH;

        localparam [BIT_WIDTH-1:0] DATA_ISLAND_GUARD_START = (SCREEN_X_END + 12) % FRAME_WIDTH;
        localparam [BIT_WIDTH-1:0] DATA_ISLAND_GUARD_END = (SCREEN_X_END + 14) % FRAME_WIDTH;

        localparam [BIT_WIDTH-1:0] DATA_ISLAND_START = (SCREEN_X_END + 14) % FRAME_WIDTH;
        localparam [BIT_WIDTH-1:0] DATA_ISLAND_END = (SCREEN_X_END + 14 + NUM_PACKETS_ALONGSIDE * 32) % FRAME_WIDTH;

        localparam [BIT_WIDTH-1:0] DATA_ISLAND_TRAIL_START = (SCREEN_X_END + 14 + NUM_PACKETS_ALONGSIDE * 32) % FRAME_WIDTH;
        localparam [BIT_WIDTH-1:0] DATA_ISLAND_TRAIL_END = (SCREEN_X_END + 14 + NUM_PACKETS_ALONGSIDE * 32 + 2) % FRAME_WIDTH;

        assign data_island_period_instantaneous = data_island_sync &&
            NUM_PACKETS_ALONGSIDE > 0 && (
            DATA_ISLAND_END > DATA_ISLAND_START ?
                cx >= DATA_ISLAND_START && cx < DATA_ISLAND_END :
                cx >= DATA_ISLAND_START || cx < DATA_ISLAND_END);

        assign video_field_end = cx == (SCREEN_X_END - 1) && cy == (SCREEN_Y_END - 1);

        assign packet_enable = data_island_period_instantaneous &&
           data_island_offset == 0;

        always @(posedge clk_pixel)
        begin
            if (reset)
            begin
                data_island_sync <= 0;
                data_island_preamble <= 0;
                data_island_guard <= 0;
                data_island_trail <= 0;
                data_island_period <= 0;
                data_island_offset <= 5'd0;
            end
            else
            begin
                if (video_field_end)
                    data_island_sync <= 1;

                data_island_preamble <= data_island_sync && NUM_PACKETS_ALONGSIDE > 0 && (
                    DATA_ISLAND_PREAMBLE_END > DATA_ISLAND_PREAMBLE_START ?
                        cx >= DATA_ISLAND_PREAMBLE_START && cx < DATA_ISLAND_PREAMBLE_END :
                        cx >= DATA_ISLAND_PREAMBLE_START || cx < DATA_ISLAND_PREAMBLE_END);

                data_island_guard <= data_island_sync && NUM_PACKETS_ALONGSIDE > 0 && (
                    DATA_ISLAND_GUARD_END > DATA_ISLAND_GUARD_START ?
                        cx >= DATA_ISLAND_GUARD_START && cx < DATA_ISLAND_GUARD_END :
                        cx >= DATA_ISLAND_GUARD_START || cx < DATA_ISLAND_GUARD_END);

                data_island_period <= data_island_period_instantaneous;

                data_island_trail <= data_island_sync && NUM_PACKETS_ALONGSIDE > 0 && (
                    DATA_ISLAND_TRAIL_END > DATA_ISLAND_TRAIL_START ?
                        cx >= DATA_ISLAND_TRAIL_START && cx < DATA_ISLAND_TRAIL_END :
                        cx >= DATA_ISLAND_TRAIL_START || cx < DATA_ISLAND_TRAIL_END);

                if (data_island_period_instantaneous)
                    data_island_offset <= data_island_offset + 5'd1;
            end
        end

        // See Section 5.2.3.4
        wire [23:0] header;
        wire [55:0] sub_0, sub_1, sub_2, sub_3;
        wire [4:0] packet_pixel_counter;

        packet_picker #(
            .VIDEO_ID_CODE(VIDEO_ID_CODE),
            .IT_CONTENT(IT_CONTENT),
            .AUDIO_RATE(AUDIO_RATE),
            .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
            .VENDOR_NAME(VENDOR_NAME),
            .PRODUCT_DESCRIPTION(PRODUCT_DESCRIPTION),
            .SOURCE_DEVICE_INFORMATION(SOURCE_DEVICE_INFORMATION)
        ) packet_picker_inst (
            .clk_pixel(clk_pixel),
            .audio_sample_en(audio_sample_en),
            .reset(reset),
            .video_field_end(video_field_end),
            .packet_enable(packet_enable),
            .packet_pixel_counter(packet_pixel_counter),
            .audio_sample_word_0(audio_sample_word_0),
            .audio_sample_word_1(audio_sample_word_1),
            .header(header),
            .sub_0(sub_0),
            .sub_1(sub_1),
            .sub_2(sub_2),
            .sub_3(sub_3)
        );

        wire [8:0] packet_data;
        packet_assembler packet_assembler_inst (
            .clk_pixel(clk_pixel),
            .reset(reset),
            .data_island_period(data_island_period),
            .header(header),
            .sub_0(sub_0),
            .sub_1(sub_1),
            .sub_2(sub_2),
            .sub_3(sub_3),
            .packet_data(packet_data),
            .counter(packet_pixel_counter)
        );

        reg data_island_first;

        always @(posedge clk_pixel)
        begin
            if (reset)
            begin
                mode <= 3'd2;
                video_data <= 24'd0;
                control_data <= 6'd0;
                data_island_data <= 12'd0;
                data_island_first <= 0;
            end
            else
            begin
                mode <= (data_island_guard || data_island_trail) ? 3'd4 : data_island_period ? 3'd3 : video_guard ? 3'd2 : de ? 3'd1 : 3'd0;
                video_data <= rgb;
                control_data <= {{1'b0, data_island_preamble}, {1'b0, video_preamble || data_island_preamble}, {vsync, hsync}}; // ctrl3, ctrl2, ctrl1, ctrl0, vsync, hsync
                data_island_data[11:4] <= packet_data[8:1];
                data_island_data[3] <= !data_island_first;
                data_island_data[2] <= packet_data[0];
                data_island_data[1:0] <= {vsync, hsync};

                if (data_island_guard)
                    data_island_first <= 1;
                if (data_island_period)
                    data_island_first <= 0;
            end
        end

        localparam integer AUDIO_CLOCK_COUNTER_WIDTH = $clog2(VIDEO_RATE + AUDIO_RATE + 1);

        reg [AUDIO_CLOCK_COUNTER_WIDTH-1:0] audio_clock_counter;

        assign audio_sample_en = audio_clock_counter >= VIDEO_RATE[AUDIO_CLOCK_COUNTER_WIDTH-1:0];

        always @(posedge clk_pixel) begin
            if (reset) begin
                audio_clock_counter <= 0;
            end else begin
                audio_clock_counter <= audio_clock_counter + AUDIO_RATE[AUDIO_CLOCK_COUNTER_WIDTH-1:0];

                if (audio_sample_en)
                    audio_clock_counter <= audio_clock_counter + AUDIO_RATE[AUDIO_CLOCK_COUNTER_WIDTH-1:0] -
                        VIDEO_RATE[AUDIO_CLOCK_COUNTER_WIDTH-1:0];
            end
        end
    end
    else // DVI_OUTPUT = 1
    begin: dvi_output
        assign audio_sample_en = 1'b0;

        always @(posedge clk_pixel)
        begin
            if (reset)
            begin
                mode <= 3'd0;
                video_data <= 24'd0;
                control_data <= 6'd0;
            end
            else
            begin
                mode <= de ? 3'd1 : 3'd0;
                video_data <= rgb;
                control_data <= {4'b0000, {vsync, hsync}}; // ctrl3, ctrl2, ctrl1, ctrl0, vsync, hsync
            end
        end
    end
endgenerate

// TMDS code production.
tmds_channel #(.CN(0)) tmds_channel_0 (
    .clk_pixel(clk_pixel),
    .video_data(video_data[7:0]),
    .data_island_data(data_island_data[3:0]),
    .control_data(control_data[1:0]),
    .mode(mode),
    .tmds(tmds_0)
);

tmds_channel #(.CN(1)) tmds_channel_1 (
    .clk_pixel(clk_pixel),
    .video_data(video_data[15:8]),
    .data_island_data(data_island_data[7:4]),
    .control_data(control_data[3:2]),
    .mode(mode),
    .tmds(tmds_1)
);

tmds_channel #(.CN(2)) tmds_channel_2 (
    .clk_pixel(clk_pixel),
    .video_data(video_data[23:16]),
    .data_island_data(data_island_data[11:8]),
    .control_data(control_data[5:4]),
    .mode(mode),
    .tmds(tmds_2)
);

endmodule
