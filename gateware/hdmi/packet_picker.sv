// Implementation of HDMI packet choice logic.
// By Sameer Puri https://github.com/sameer

module packet_picker
#(
    parameter int VIDEO_ID_CODE = 4,
    parameter bit IT_CONTENT = 1'b0,
    parameter int AUDIO_BIT_WIDTH = 0,
    parameter int AUDIO_RATE = 0,
    parameter bit [8*8-1:0] VENDOR_NAME = 0,
    parameter bit [8*16-1:0] PRODUCT_DESCRIPTION = 0,
    parameter bit [7:0] SOURCE_DEVICE_INFORMATION = 0
)
(
    input logic clk_pixel,
    input logic reset,
    input logic video_field_end,
    input logic packet_enable,
    input logic [4:0] packet_pixel_counter,
    input logic [AUDIO_BIT_WIDTH-1:0] audio_sample_word_0,
    input logic [AUDIO_BIT_WIDTH-1:0] audio_sample_word_1,
    input logic audio_sample_en,
    output logic [23:0] header,
    output logic [55:0] sub_0,
    output logic [55:0] sub_1,
    output logic [55:0] sub_2,
    output logic [55:0] sub_3
);

// Connect the current packet type's data to the output.
logic [2:0]  packet_type;
logic [23:0] headers [5:0];
logic [55:0] subs [5:0] [3:0];

assign header = headers[packet_type];

assign sub_0 = subs[packet_type][0];
assign sub_1 = subs[packet_type][1];
assign sub_2 = subs[packet_type][2];
assign sub_3 = subs[packet_type][3];

// NULL packet
// "An HDMI Sink shall ignore bytes HB1 and HB2 of the Null Packet Header and all bytes of the Null Packet Body."
assign headers[0] = {8'dX, 8'dX, 8'd0};
assign subs[0][0] = 56'dX;
assign subs[0][1] = 56'dX;
assign subs[0][2] = 56'dX;
assign subs[0][3] = 56'dX;

// Audio Clock Regeneration Packet
logic clk_audio_counter_wrap;
audio_clock_regeneration_packet #(.AUDIO_RATE(AUDIO_RATE)) audio_clock_regeneration_packet (.clk_pixel(clk_pixel), .reset(reset), .audio_sample_en(audio_sample_en), .clk_audio_counter_wrap(clk_audio_counter_wrap), .header(headers[1]), .sub_0(subs[1][0]), .sub_1(subs[1][1]), .sub_2(subs[1][2]), .sub_3(subs[1][3]));

// Audio Sample packet
localparam bit [3:0] SAMPLING_FREQUENCY = AUDIO_RATE == 32000 ? 4'b0011
    : AUDIO_RATE == 44100 ? 4'b0000
    : AUDIO_RATE == 88200 ? 4'b1000
    : AUDIO_RATE == 176400 ? 4'b1100
    : AUDIO_RATE == 48000 ? 4'b0010
    : AUDIO_RATE == 96000 ? 4'b1010
    : AUDIO_RATE == 192000 ? 4'b1110
    : 4'bXXXX;
localparam int AUDIO_BIT_WIDTH_COMPARATOR = AUDIO_BIT_WIDTH < 20 ? 20 : AUDIO_BIT_WIDTH == 20 ? 25 : AUDIO_BIT_WIDTH < 24 ? 24 : AUDIO_BIT_WIDTH == 24 ? 29 : -1;
localparam bit [2:0] WORD_LENGTH = 3'(AUDIO_BIT_WIDTH_COMPARATOR - AUDIO_BIT_WIDTH);
localparam bit WORD_LENGTH_LIMIT = AUDIO_BIT_WIDTH <= 20 ? 1'b0 : 1'b1;

logic sample_buffer_current = 1'b0;
logic [1:0] samples_count = 2'd0;
logic [23:0] audio_sample_word_buffer [1:0] [3:0] [1:0];

logic sample_buffer_used = 1'b0;
logic sample_buffer_ready = 1'b0;

always_ff @(posedge clk_pixel)
begin
    if (sample_buffer_used)
        sample_buffer_ready <= 1'b0;

    if (audio_sample_en)
    begin
        audio_sample_word_buffer[sample_buffer_current][samples_count][0] <=  24'(audio_sample_word_0)<<(24-AUDIO_BIT_WIDTH);
        audio_sample_word_buffer[sample_buffer_current][samples_count][1] <=  24'(audio_sample_word_1)<<(24-AUDIO_BIT_WIDTH);

        if (samples_count == 2'd3)
        begin
            samples_count <= 2'd0;
            sample_buffer_ready <= 1'b1;
            sample_buffer_current <= !sample_buffer_current;
        end
        else
            samples_count <= samples_count + 1'd1;
    end
end

logic [23:0] audio_sample_word_packet [3:0] [1:0];
logic [3:0] audio_sample_word_present_packet;

logic [7:0] frame_counter = 8'd0;
int k;
always_ff @(posedge clk_pixel)
begin
    if (reset)
    begin
        frame_counter <= 8'd0;
    end
    else if (packet_pixel_counter == 5'd31 && packet_type == 3'd2) // Keep track of current IEC 60958 frame
    begin
        frame_counter <= frame_counter + 8'd4;
        if (frame_counter >= 8'd192)
            frame_counter <= frame_counter - 8'd192;
    end
end

audio_sample_packet #(.SAMPLING_FREQUENCY(SAMPLING_FREQUENCY), .WORD_LENGTH({{WORD_LENGTH[0], WORD_LENGTH[1], WORD_LENGTH[2]}, WORD_LENGTH_LIMIT})) audio_sample_packet (.frame_counter(frame_counter), .valid_bit_0(2'b00), .valid_bit_1(2'b00), .valid_bit_2(2'b00), .valid_bit_3(2'b00), .user_data_bit_0(2'b00), .user_data_bit_1(2'b00), .user_data_bit_2(2'b00), .user_data_bit_3(2'b00), .audio_sample_word_0_0(audio_sample_word_packet[0][0]), .audio_sample_word_1_0(audio_sample_word_packet[1][0]), .audio_sample_word_2_0(audio_sample_word_packet[2][0]), .audio_sample_word_3_0(audio_sample_word_packet[3][0]), .audio_sample_word_0_1(audio_sample_word_packet[0][1]), .audio_sample_word_1_1(audio_sample_word_packet[1][1]), .audio_sample_word_2_1(audio_sample_word_packet[2][1]), .audio_sample_word_3_1(audio_sample_word_packet[3][1]), .audio_sample_word_present(audio_sample_word_present_packet), .header(headers[2]), .sub_0(subs[2][0]), .sub_1(subs[2][1]), .sub_2(subs[2][2]), .sub_3(subs[2][3]));

auxiliary_video_information_info_frame #(
    .VIDEO_ID_CODE(7'(VIDEO_ID_CODE)),
    .IT_CONTENT(IT_CONTENT)
) auxiliary_video_information_info_frame(.header(headers[3]), .sub_0(subs[3][0]), .sub_1(subs[3][1]), .sub_2(subs[3][2]), .sub_3(subs[3][3]));

source_product_description_info_frame #(.VENDOR_NAME(VENDOR_NAME), .PRODUCT_DESCRIPTION(PRODUCT_DESCRIPTION), .SOURCE_DEVICE_INFORMATION(SOURCE_DEVICE_INFORMATION)) source_product_description_info_frame(.header(headers[4]), .sub_0(subs[4][0]), .sub_1(subs[4][1]), .sub_2(subs[4][2]), .sub_3(subs[4][3]));

audio_info_frame audio_info_frame(.header(headers[5]), .sub_0(subs[5][0]), .sub_1(subs[5][1]), .sub_2(subs[5][2]), .sub_3(subs[5][3]));

// "A Source shall always transmit... [an InfoFrame] at least once per two Video Fields"
logic audio_info_frame_sent = 1'b0;
logic auxiliary_video_information_info_frame_sent = 1'b0;
logic source_product_description_info_frame_sent = 1'b0;
logic last_clk_audio_counter_wrap = 1'b0;
always_ff @(posedge clk_pixel)
begin
    if (sample_buffer_used)
        sample_buffer_used <= 1'b0;

    if (reset || video_field_end)
    begin
        audio_info_frame_sent <= 1'b0;
        auxiliary_video_information_info_frame_sent <= 1'b0;
        source_product_description_info_frame_sent <= 1'b0;
        packet_type <= 3'd0;
    end
    else if (packet_enable)
    begin
        if (last_clk_audio_counter_wrap ^ clk_audio_counter_wrap)
        begin
            packet_type <= 3'd1;
            last_clk_audio_counter_wrap <= clk_audio_counter_wrap;
        end
        else if (sample_buffer_ready)
        begin
            packet_type <= 3'd2;
            audio_sample_word_packet[0][0] <= audio_sample_word_buffer[!sample_buffer_current][0][0];
            audio_sample_word_packet[1][0] <= audio_sample_word_buffer[!sample_buffer_current][1][0];
            audio_sample_word_packet[2][0] <= audio_sample_word_buffer[!sample_buffer_current][2][0];
            audio_sample_word_packet[3][0] <= audio_sample_word_buffer[!sample_buffer_current][3][0];

            audio_sample_word_packet[0][1] <= audio_sample_word_buffer[!sample_buffer_current][0][1];
            audio_sample_word_packet[1][1] <= audio_sample_word_buffer[!sample_buffer_current][1][1];
            audio_sample_word_packet[2][1] <= audio_sample_word_buffer[!sample_buffer_current][2][1];
            audio_sample_word_packet[3][1] <= audio_sample_word_buffer[!sample_buffer_current][3][1];

            audio_sample_word_present_packet <= 4'b1111;
            sample_buffer_used <= 1'b1;
        end
        else if (!audio_info_frame_sent)
        begin
            packet_type <= 3'd5;
            audio_info_frame_sent <= 1'b1;
        end
        else if (!auxiliary_video_information_info_frame_sent)
        begin
            packet_type <= 3'd3;
            auxiliary_video_information_info_frame_sent <= 1'b1;
        end
        else if (!source_product_description_info_frame_sent)
        begin
            packet_type <= 3'd4;
            source_product_description_info_frame_sent <= 1'b1;
        end
        else
            packet_type <= 3'd0;
    end
end

endmodule
