// Implementation of HDMI audio clock regeneration packet
// By Sameer Puri https://github.com/sameer

// See HDMI 1.4b Section 5.3.3
module audio_clock_regeneration_packet
#(
    parameter int AUDIO_RATE = 48e3
)
(
    input logic clk_pixel,
    input logic reset,
    input logic audio_sample_en,
    output logic clk_audio_counter_wrap,
    output logic [23:0] header,
    output logic [55:0] sub_0,
    output logic [55:0] sub_1,
    output logic [55:0] sub_2,
    output logic [55:0] sub_3
);

logic [55:0] sub [3:0];

assign sub_0 = sub[0];
assign sub_1 = sub[1];
assign sub_2 = sub[2];
assign sub_3 = sub[3];

// See Section 7.2.3, values derived from "Other" row in Tables 7-1, 7-2, 7-3.
localparam bit [19:0] N = AUDIO_RATE % 125 == 0 ? 20'(16 * AUDIO_RATE / 125) : AUDIO_RATE % 225 == 0 ? 20'(32 * AUDIO_RATE / 225) : 20'(AUDIO_RATE * 16 / 125);

localparam int CLK_AUDIO_COUNTER_WIDTH = $clog2(N / 128);
localparam bit [CLK_AUDIO_COUNTER_WIDTH-1:0] CLK_AUDIO_COUNTER_END = CLK_AUDIO_COUNTER_WIDTH'(N / 128 - 1);

logic [CLK_AUDIO_COUNTER_WIDTH-1:0] clk_audio_counter;

localparam int CYCLE_TIME_STAMP_COUNTER_WIDTH = 20;

logic [19:0] cycle_time_stamp;
logic [CYCLE_TIME_STAMP_COUNTER_WIDTH-1:0] cycle_time_stamp_counter;

always_ff @(posedge clk_pixel)
begin
    if (reset)
    begin
        clk_audio_counter <= CLK_AUDIO_COUNTER_WIDTH'(0);
        clk_audio_counter_wrap <= 1'b0;

        cycle_time_stamp <= 20'd0;
        cycle_time_stamp_counter <= CYCLE_TIME_STAMP_COUNTER_WIDTH'(0);
    end
    else
    begin
        cycle_time_stamp_counter <= cycle_time_stamp_counter + CYCLE_TIME_STAMP_COUNTER_WIDTH'(1);

        if (audio_sample_en)
        begin
            if (clk_audio_counter == CLK_AUDIO_COUNTER_END)
            begin
                clk_audio_counter <= CLK_AUDIO_COUNTER_WIDTH'(0);
                clk_audio_counter_wrap <= !clk_audio_counter_wrap;

                cycle_time_stamp <= cycle_time_stamp_counter + CYCLE_TIME_STAMP_COUNTER_WIDTH'(1);
                cycle_time_stamp_counter <= CYCLE_TIME_STAMP_COUNTER_WIDTH'(0);
            end
            else
                clk_audio_counter <= clk_audio_counter + 1'd1;
        end
    end
end

// "An HDMI Sink shall ignore bytes HB1 and HB2 of the Audio Clock Regeneration Packet header."
assign header = {8'dX, 8'dX, 8'd1};

// "The four Subpackets each contain the same Audio Clock regeneration Subpacket."
genvar i;
generate
    for (i = 0; i < 4; i++)
    begin: same_packet
        assign sub[i] = {N[7:0], N[15:8], {4'd0, N[19:16]}, cycle_time_stamp[7:0], cycle_time_stamp[15:8], {4'd0, cycle_time_stamp[19:16]}, 8'd0};
    end
endgenerate

endmodule
