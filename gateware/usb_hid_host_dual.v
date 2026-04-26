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

`timescale 1ns / 1ps
`default_nettype none
module usb_hid_host_dual #(
  parameter FULL_SPEED = 1,
  parameter MOUSE_SUPPORT = 0
) (
  input wire clk,
  input wire reset,

  input wire usb_clk,
  input wire usb_rst,

  input  wire [1:0] usb_dm_i, usb_dp_i,  // USB D- and D+
  output wire [1:0] usb_dm_o, usb_dp_o,  // USB D- and D+
  output wire [1:0] usb_oe,              // USB OE

  output wire connerr_0,
  output wire connerr_1,

  output wire connected_0,
  output wire connected_1,

  output wire game_l_0,
  output wire game_r_0,
  output wire game_u_0,
  output wire game_d_0,
  output wire game_a_0,
  output wire game_b_0,
  output wire game_x_0,
  output wire game_y_0,
  output wire game_sel_0,
  output wire game_sta_0,

  output wire game_l_1,
  output wire game_r_1,
  output wire game_u_1,
  output wire game_d_1,
  output wire game_a_1,
  output wire game_b_1,
  output wire game_x_1,
  output wire game_y_1,
  output wire game_sel_1,
  output wire game_sta_1,

  output wire       key_report,
  output wire [7:0] key_modifiers,
  output wire [7:0] key_0,
  output wire [7:0] key_1,
  output wire [7:0] key_2,
  output wire [7:0] key_3,

  output wire              mouse_report,
  output wire        [2:0] mouse_btn,
  output wire signed [7:0] mouse_dx,
  output wire signed [7:0] mouse_dy
);

wire       game_l_i [0:1];
wire       game_r_i [0:1];
wire       game_u_i [0:1];
wire       game_d_i [0:1];
wire       game_a_i [0:1];
wire       game_b_i [0:1];
wire       game_x_i [0:1];
wire       game_y_i [0:1];
wire       game_sel_i [0:1];
wire       game_sta_i [0:1];
wire [3:0] game_extra_i [0:1];

wire [7:0] key_modifiers_i [0:1];
wire [7:0] key_0_i [0:1];
wire [7:0] key_1_i [0:1];
wire [7:0] key_2_i [0:1];
wire [7:0] key_3_i [0:1];

wire [2:0] mouse_btn_i [0:1];
wire [7:0] mouse_dx_i [0:1];
wire [7:0] mouse_dy_i [0:1];

wire [63:0] hid_regs_i  [0:1];
wire [1:0]  typ_i       [0:1];

wire [9:0] rom_addr_i [0:1];
wire [3:0] rom_dout_i [0:1];
wire       rom_en_i   [0:1];

wire connerr_i     [0:1];
wire full_report_i [0:1];
wire busy_i        [0:1];

usb_hid_host #(
  .FULL_SPEED(FULL_SPEED),
  .MOUSE_SUPPORT(MOUSE_SUPPORT)
) usb_hid_host_0 (
  .clk(usb_clk),
  .reset(usb_rst),
  .cs(1),
  .usb_dm_i(usb_dm_i[0]),
  .usb_dp_i(usb_dp_i[0]),
  .usb_dm_o(usb_dm_o[0]),
  .usb_dp_o(usb_dp_o[0]),
  .usb_oe(usb_oe[0]),
  .typ(typ_i[0]),
  .rom_addr(rom_addr_i[0]),
  .rom_dout(rom_dout_i[0]),
  .rom_en(rom_en_i[0]),
  .connerr(connerr_i[0]),
  .busy(busy_i[0]),
  .full_report(full_report_i[0]),
  .dbg_hid_report(),
  .dbg_hid_regs(),
  .game_l(game_l_i[0]),
  .game_r(game_r_i[0]),
  .game_u(game_u_i[0]),
  .game_d(game_d_i[0]),
  .game_a(game_a_i[0]),
  .game_b(game_b_i[0]),
  .game_x(game_x_i[0]),
  .game_y(game_y_i[0]),
  .game_sel(game_sel_i[0]),
  .game_sta(game_sta_i[0]),
  .game_extra(game_extra_i[0]),
  .key_modifiers(key_modifiers_i[0]),
  .key_3(key_3_i[0]),
  .key_2(key_2_i[0]),
  .key_1(key_1_i[0]),
  .key_0(key_0_i[0]),
  .mouse_btn(mouse_btn_i[0]),
  .mouse_dx(mouse_dx_i[0]),
  .mouse_dy(mouse_dy_i[0])
);

usb_hid_host #(
  .FULL_SPEED(FULL_SPEED),
  .MOUSE_SUPPORT(MOUSE_SUPPORT)
) usb_hid_host_1 (
  .clk(usb_clk),
  .reset(usb_rst),
  .cs(1),
  .usb_dm_i(usb_dm_i[1]),
  .usb_dp_i(usb_dp_i[1]),
  .usb_dm_o(usb_dm_o[1]),
  .usb_dp_o(usb_dp_o[1]),
  .usb_oe(usb_oe[1]),
  .typ(typ_i[1]),
  .rom_addr(rom_addr_i[1]),
  .rom_dout(rom_dout_i[1]),
  .rom_en(rom_en_i[1]),
  .connerr(connerr_i[1]),
  .busy(busy_i[1]),
  .full_report(full_report_i[1]),
  .dbg_hid_report(),
  .dbg_hid_regs(),
  .game_l(game_l_i[1]),
  .game_r(game_r_i[1]),
  .game_u(game_u_i[1]),
  .game_d(game_d_i[1]),
  .game_a(game_a_i[1]),
  .game_b(game_b_i[1]),
  .game_x(game_x_i[1]),
  .game_y(game_y_i[1]),
  .game_sel(game_sel_i[1]),
  .game_sta(game_sta_i[1]),
  .game_extra(game_extra_i[1]),
  .key_modifiers(key_modifiers_i[1]),
  .key_3(key_3_i[1]),
  .key_2(key_2_i[1]),
  .key_1(key_1_i[1]),
  .key_0(key_0_i[1]),
  .mouse_btn(mouse_btn_i[1]),
  .mouse_dx(mouse_dx_i[1]),
  .mouse_dy(mouse_dy_i[1])
);

usb_hid_host_dual_rom #(
  .MEMORY_FILE("../rom/usb_hid_host_rom.mem")
) usb_hid_host_dual_rom_0 (
  .clk(usb_clk),
  .ena(rom_en_i[0]),
  .addra(rom_addr_i[0]),
  .douta(rom_dout_i[0]),
  .enb(rom_en_i[1]),
  .addrb(rom_addr_i[1]),
  .doutb(rom_dout_i[1])
);

cdc_sync #(
  .WIDTH(2)
) cdc_sync_0 (
  .clk_dst(clk),
  .rst_dst(reset),
  .in({(typ_i[0] != 2'b00), (typ_i[1] != 2'b00)}),
  .out({connected_0, connected_1})
);

cdc_pulse cdc_pulse_0 (
  .clk_src(usb_clk),
  .rst_src(usb_rst),
  .clk_dst(clk),
  .rst_dst(reset),
  .in(connerr_i[0]),
  .out(connerr_0)
);

cdc_pulse cdc_pulse_1 (
  .clk_src(usb_clk),
  .rst_src(usb_rst),
  .clk_dst(clk),
  .rst_dst(reset),
  .in(connerr_i[1]),
  .out(connerr_1)
);

wire game_report_busy_0;
reg game_report_src_send_0;

reg full_game_report_strobe_0;

always @(posedge usb_clk)
  if (usb_rst) begin
    game_report_src_send_0 <= 0;
    full_game_report_strobe_0 <= 0;
  end else if (full_report_i[0]) begin
    full_game_report_strobe_0 <= 1;
  end else if (!game_report_src_send_0 && !game_report_busy_0) begin
    game_report_src_send_0 <= full_game_report_strobe_0;
    full_game_report_strobe_0 <= 0;
  end else if (game_report_src_send_0 && !game_report_busy_0)
    game_report_src_send_0 <= 0;

cdc_handshake #(
  .EXTERNAL_ACK(0),
  .WIDTH(10)
) cdc_handshake_0 (
  .clk_src(usb_clk),
  .rst_src(usb_rst),
  .data_in({game_l_i[0], game_r_i[0], game_u_i[0] || game_extra_i[0][0], game_d_i[0] || game_extra_i[0][2],
    game_a_i[0] || game_extra_i[0][3], game_b_i[0] || game_extra_i[0][1], game_x_i[0], game_y_i[0],
    game_sel_i[0], game_sta_i[0]}),
  .send(game_report_src_send_0),
  .busy(game_report_busy_0),
  .clk_dst(clk),
  .rst_dst(reset),
  .data_out({game_l_0, game_r_0, game_u_0, game_d_0, game_a_0, game_b_0, game_x_0, game_y_0, game_sel_0, game_sta_0}),
  .valid(),
  .ack_in(1'b0)
);

wire game_report_busy_1;
reg game_report_src_send_1;

reg full_game_report_strobe_1;

always @(posedge usb_clk)
  if (usb_rst) begin
    game_report_src_send_1 <= 0;
    full_game_report_strobe_1 <= 0;
  end else if (full_report_i[1]) begin
    full_game_report_strobe_1 <= 1;
  end else if (!game_report_src_send_1 && !game_report_busy_1) begin
    game_report_src_send_1 <= full_game_report_strobe_1;
    full_game_report_strobe_1 <= 0;
  end else if (game_report_src_send_1 && !game_report_busy_1)
    game_report_src_send_1 <= 0;

cdc_handshake #(
  .EXTERNAL_ACK(0),
  .WIDTH(10)
) cdc_handshake_1 (
  .clk_src(usb_clk),
  .rst_src(usb_rst),
  .data_in({game_l_i[1], game_r_i[1], game_u_i[1] || game_extra_i[1][0], game_d_i[1] || game_extra_i[1][2],
    game_a_i[1] || game_extra_i[1][3], game_b_i[1] || game_extra_i[1][1], game_x_i[1], game_y_i[1],
    game_sel_i[1], game_sta_i[1]}),
  .send(game_report_src_send_1),
  .busy(game_report_busy_1),
  .clk_dst(clk),
  .rst_dst(reset),
  .data_out({game_l_1, game_r_1, game_u_1, game_d_1, game_a_1, game_b_1, game_x_1, game_y_1, game_sel_1, game_sta_1}),
  .valid(),
  .ack_in(1'b0)
);

wire key_device_num;

assign key_device_num = typ_i[0] == 1 ? 0 :
                        typ_i[1] == 1 ? 1 : 0;

wire key_report_busy;
reg key_report_src_send;

reg full_key_report_strobe;

always @(posedge usb_clk)
  if (usb_rst) begin
    key_report_src_send <= 0;
    full_key_report_strobe <= 0;
  end else if (full_report_i[key_device_num]) begin
    full_key_report_strobe <= 1;
  end else if (!key_report_src_send && !key_report_busy) begin
    key_report_src_send <= full_key_report_strobe;
    full_key_report_strobe <= 0;
  end else if (key_report_src_send && !key_report_busy)
    key_report_src_send <= 0;

cdc_handshake #(
  .EXTERNAL_ACK(0),
  .WIDTH(40)
) cdc_handshake_2 (
  .clk_src(usb_clk),
  .rst_src(usb_rst),
  .data_in({key_modifiers_i[key_device_num], key_0_i[key_device_num],
    key_1_i[key_device_num], key_2_i[key_device_num], key_3_i[key_device_num]}),
  .send(key_report_src_send),
  .busy(key_report_busy),
  .clk_dst(clk),
  .rst_dst(reset),
  .data_out({key_modifiers, key_0, key_1, key_2, key_3}),
  .valid(key_report),
  .ack_in(1'b0)
);

generate
  if (MOUSE_SUPPORT) begin
    wire mouse_device_num;

    assign mouse_device_num = typ_i[0] == 2 ? 0 :
                              typ_i[1] == 2 ? 1 : 0;

    wire mouse_report_busy;
    reg mouse_report_src_send;

    reg full_mouse_report_strobe = 1;

    always @(posedge usb_clk)
      if (usb_rst) begin
        mouse_report_src_send <= 0;
        full_mouse_report_strobe <= 1;
      end else if (full_report_i[mouse_device_num]) begin
        full_mouse_report_strobe <= 1;
      end else if (!mouse_report_src_send && !mouse_report_busy) begin
        mouse_report_src_send <= full_mouse_report_strobe;
        full_mouse_report_strobe <= 0;
      end else if (mouse_report_src_send && !mouse_report_busy)
        mouse_report_src_send <= 0;

    cdc_handshake #(
      .EXTERNAL_ACK(0),
      .WIDTH(19)
    ) cdc_handshake_3 (
      .clk_src(usb_clk),
      .rst_src(usb_rst),
      .data_in({mouse_btn_i[mouse_device_num], mouse_dx_i[mouse_device_num],
        mouse_dy_i[mouse_device_num]}),
      .send(mouse_report_src_send),
      .busy(mouse_report_busy),
      .clk_dst(clk),
      .rst_dst(reset),
      .data_out({mouse_btn, mouse_dx, mouse_dy}),
      .valid(mouse_report),
      .ack_in(1'b0)
    );

  end else begin

    assign mouse_report = 0;
    assign mouse_btn = 3'b0;
    assign mouse_dx = 8'b0;
    assign mouse_dy = 8'b0;
  end
endgenerate

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
