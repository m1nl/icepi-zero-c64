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

`default_nettype none
`timescale 1 ns / 1 ps
module c64_action_replay (
  input wire clk,
  input wire reset,
  input wire phi2_p,
  input wire phi2_h,
  input wire phi2_n,

  input  wire [15:0] addr,
  input  wire  [7:0] din,
  output wire  [7:0] dout,

  input wire we,
  input wire ba,

  output wire exrom,
  output wire game,

  input wire freeze,
  input wire roml,
  input wire romh,
  input wire io1_cen,
  input wire io2_cen,

  output wire nmi,
  output wire irq,

  input wire sdram_pending,

  output wire [14:0] rom_addr,
  output reg         rom_enable,
  input  wire        rom_ready,
  input  wire [7:0]  rom_dout,
  output wire        rom_select
);

wire reset_n;
wire freeze_pending_n;

wire u6a_q;
wire u6b_qn;

wire u7c_out;
wire u7d_out;

reg freeze_pending;

assign reset_n          = !reset;
assign freeze_pending_n = !freeze_pending;

always @(posedge clk) begin
  if (reset)
    freeze_pending <= 1'b0;
  else if (phi2_h)
    freeze_pending <= 1'b0;
  else if (freeze)
    freeze_pending <= 1'b1;
end

LS74_D_FF u6a (
  .clk(clk),
  .en(freeze_pending && phi2_h),
  .d(1'b1),
  .pr_n(1'b1),
  .clr_n(reset_n && u6b_qn),
  .q(u6a_q),
  .qn()
);

LS74_D_FF u6b (
  .clk(clk),
  .en(u5_q[2]),
  .d(1'b1),
  .pr_n(1'b1),
  .clr_n(reset_n && u7c_out),
  .q(),
  .qn(u6b_qn)
);

assign nmi = u6a_q;
assign irq = 1'b0;

wire [3:0] u5_q;

LS163_4BIT_COUNTER u5 (
  .clk(clk),
  .clr_n(1'b1),
  .load_n(u6a_q && ba),
  .enp(phi2_p),
  .ent(phi2_p),
  .d(4'b0000),
  .q(u5_q),
  .rco()
);

wire [7:0] u4_q;

LS273_D_FF_8BIT u4 (
  .clk(clk),
  .en(u7d_out && we && phi2_h),
  .clr_n(freeze_pending_n && reset_n),
  .d(din),
  .q(u4_q)
);

assign u7c_out = ~(u4_q[6]);
assign u7d_out = ~(io1_cen || u4_q[2]);

wire o1, o2, o3, o4;
wire pla_oe;

assign pla_oe = !u4_q[2];

c64_action_replay_pla u3_pla (
  .addr({reset_n && u6b_qn, addr[14], addr[15], addr[13], io2_cen, u4_q[0], u4_q[1], u4_q[5]}),
  .o1(o1),
  .o2(o2),
  .o3(o3),
  .o4(o4)
);

assign game  = pla_oe ? o3 : 1'b1;
assign exrom = pla_oe ? o4 : 1'b1;

wire ram_en;
wire ram_select;
wire ram_we;

wire [12:0] ram_addr;
wire  [7:0] ram_dout;

assign ram_select = pla_oe ? !o2 : 1'b0;
assign ram_we     = we;
assign ram_addr   = addr[12:0];
assign ram_en     = ram_we ? phi2_n : phi2_h;

c64_ram #(
  .DW(8),
  .AW(13)
) ram (
  .clk(clk),
  .addr(ram_addr),
  .din(din),
  .dout(ram_dout),
  .enable(ram_select && ram_en && !reset),
  .we(ram_we)
);

wire rom_oe;

assign rom_select = pla_oe ? !o1 && rom_oe : 1'b0;
assign rom_oe     = ~(romh && roml && io2_cen);

assign rom_addr = {u4_q[4:3], addr[12:0]};

assign dout = !io1_cen   ? u4_q     :
              ram_select ? ram_dout :
              rom_select ? rom_dout : 8'hXX;

always @(posedge clk) begin
  if (reset) begin
    rom_enable <= 1'b0;

  end else begin
    if (rom_enable && rom_ready)
      rom_enable <= 1'b0;

    if (sdram_pending)
      rom_enable <= rom_select;
  end
end

endmodule

module LS163_4BIT_COUNTER (
  input wire clk,
  input wire clr_n,
  input wire load_n,
  input wire enp,
  input wire ent,
  input wire [3:0] d,
  output reg [3:0] q,
  output wire rco
);

always @(posedge clk) begin
  if (!clr_n)
    q <= 4'b0;
  else if (!load_n)
    q <= d;
  else if (enp && ent)
    q <= q + 1;
end

assign rco = (q == 4'b1111) && ent;

endmodule

module LS273_D_FF_8BIT (
  input wire clk,
  input wire en,
  input wire clr_n,
  input wire [7:0] d,
  output reg [7:0] q
);

always @(posedge clk) begin
  if (!clr_n)
    q <= 8'b0;
  else if (en)
    q <= d;
end

endmodule

module LS74_D_FF (
  input wire clk,
  input wire en,
  input wire d,
  input wire pr_n,
  input wire clr_n,
  output reg q,
  output wire qn
);

always @(posedge clk) begin
  if (!pr_n)
    q <= 1'b1;
  else if (!clr_n)
    q <= 1'b0;
  else if (en)
    q <= d;
end

assign qn = !q;

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
