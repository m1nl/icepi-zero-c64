// ---------------------------------------------------------------------------
// Copyright 2026 Mateusz Nalewajski
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// this module is just a wrapper and TMDS CDC for
// reDIP SID, a MOS 6581/8580 SID FPGA emulation platform.
// Copyright (C) 2022 - 2023  Dag Lem <resid@nimrod.no>
// ---------------------------------------------------------------------------

`default_nettype none
`timescale 1 ns / 1 ps
module c64_redip_sid (
  input wire clk,
  input wire reset,

  input wire clk_phi,
  input wire phi2_n,

  input wire clk_sample,
  input wire reset_sample,

  input wire cen,
  input wire we,

  input  wire [8:0] addr,
  input  wire [7:0] din,
  output wire [7:0] dout,

  input  wire               audio_sample_en,
  output wire signed [23:0] audio_sample_word_0,
  output wire signed [23:0] audio_sample_word_1,

  input wire sid_model,
  input wire sid_dual,
  input wire sid_auto_mono,

  input wire pot_x,
  input wire pot_y
);

// audio output

wire [39:0] audio_sample_word;

assign audio_sample_word_0 = {audio_sample_word[19: 0], 4'b0};
assign audio_sample_word_1 = {audio_sample_word[39:20], 4'b0};

// audio sampling

wire signed [19:0] wave_0;
wire signed [19:0] wave_1;

wire signed [19:0] wave_0_tmds;
wire signed [19:0] wave_1_tmds;

wire wave_0_tmds_ready;
wire wave_1_tmds_ready;

wire wave_0_tmds_valid;
wire wave_1_tmds_valid;

wire wave_0_src_busy;
wire wave_1_src_busy;

reg wave_0_src_send;
reg wave_1_src_send;

always @(posedge clk)
  if (reset)
    wave_0_src_send <= 1'b0;
  else if (!wave_0_src_send && phi2_n)
    wave_0_src_send <= 1'b1;
  else if (wave_0_src_send && !wave_0_src_busy)
    wave_0_src_send <= 1'b0;

always @(posedge clk)
  if (reset)
    wave_1_src_send <= 1'b0;
  else if (!wave_1_src_send && phi2_n)
    wave_1_src_send <= 1'b1;
  else if (wave_1_src_send && !wave_1_src_busy)
    wave_1_src_send <= 1'b0;

cdc_handshake #(
  .EXTERNAL_ACK(1),
  .WIDTH(20)
) cdc_handshake_0 (
  .clk_src(clk),
  .rst_src(reset),
  .data_in(wave_0),
  .send(wave_0_src_send),
  .busy(wave_0_src_busy),
  .clk_dst(clk_sample),
  .rst_dst(reset_sample),
  .data_out(wave_0_tmds),
  .valid(wave_0_tmds_valid),
  .ack_in(wave_0_tmds_ready)
);

cdc_handshake #(
  .EXTERNAL_ACK(1),
  .WIDTH(20)
) cdc_handshake_1 (
  .clk_src(clk),
  .rst_src(reset),
  .data_in(wave_1),
  .send(wave_1_src_send),
  .busy(wave_1_src_busy),
  .clk_dst(clk_sample),
  .rst_dst(reset_sample),
  .data_out(wave_1_tmds),
  .valid(wave_1_tmds_valid),
  .ack_in(wave_1_tmds_ready)
);

dc_blocker dc_blocker_0 (
  .clk(clk_sample),
  .reset(reset_sample),
  .in_valid(wave_0_tmds_valid),
  .in_ready(wave_0_tmds_ready),
  .out_ready(audio_sample_en),
  .out_valid(),
  .in(wave_0_tmds),
  .out(audio_sample_word[19:0])
);

dc_blocker dc_blocker_1 (
  .clk(clk_sample),
  .reset(reset_sample),
  .in_valid(wave_1_tmds_valid),
  .in_ready(wave_1_tmds_ready),
  .out_ready(audio_sample_en),
  .out_valid(),
  .in(wave_1_tmds),
  .out(audio_sample_word[39:20])
);

// address and data bus handling

localparam integer MONO_TIMEOUT     = 200_000; // in phi2 ticks (~200ms)
localparam integer MONO_TIMER_WIDTH = $clog2(MONO_TIMEOUT);

wire a5a8_bus_write_access;

assign a5a8_bus_write_access = !cen && we && (addr[5] || addr[8]) && (addr[4:0] != 5'h18 || din[3:0] != 4'b0000);

wire cen_latched;
wire we_latched;

wire [8:0] addr_latched;
wire [7:0] din_latched;

reg cen_r;
reg we_r;

reg [8:0] addr_r;
reg [7:0] din_r;

reg [MONO_TIMER_WIDTH-1:0] mono_timer;

always @(posedge clk)
  if (reset) begin
    cen_r <= 1'b1;
    we_r  <= 1'b0;

    mono_timer <= 0;

  end else if (phi2_n) begin
    cen_r <= cen;
    we_r  <= we;

    addr_r <= addr;
    din_r  <= din;

    if (a5a8_bus_write_access)
      mono_timer <= MONO_TIMEOUT[MONO_TIMER_WIDTH-1:0];
    else if (mono_timer > 0)
      mono_timer <= mono_timer - 17'd1;
  end

assign cen_latched = clk_phi ? cen : cen_r;
assign we_latched  = clk_phi ? we  : we_r;

assign addr_latched = clk_phi ? addr : addr_r;
assign din_latched  = clk_phi ? din  : din_r;

// mono control

wire sid_mono;

assign sid_mono = !sid_dual || (mono_timer == 0 && sid_auto_mono);

sid_api sid_api_0 (
  .clk(clk),
  .bus_res(reset),
  .bus_phi2(clk_phi),
  .bus_phi2_n(phi2_n),
  .bus_addr(addr_latched[4:0]),
  .a5(addr_latched[5]),
  .a8(addr_latched[8]),
  .bus_data(din_latched),
  .data_o(dout),
  .cs_n(cen_latched),
  .cs_io1_n(1'b1),
  .bus_r_w_n(~we_latched),
  .audio_o_left(wave_0),
  .audio_o_right(wave_1),
  .sid_model(sid_model),
  .sid_mono(sid_mono),
  .sid_variants(1'b1),
  .pot_charged({pot_y, pot_x}),
  .audio_i_left(24'b0),
  .audio_i_right(24'b0)
);

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
