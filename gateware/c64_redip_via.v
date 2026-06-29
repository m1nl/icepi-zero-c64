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
// this module is just a wrapper for
// reDIP CIA, a MOS 6526/8520/8521 FPGA emulation platform.
// Copyright (C) 2025  Dag Lem <resid@nimrod.no>
// ---------------------------------------------------------------------------

`default_nettype none
`timescale 1 ns / 1 ps
module c64_redip_via (
  input wire clk,
  input wire reset,

  input wire clk_phi,

  input wire cen,
  input wire we,

  input wire [7:0] pa_in,
  input wire [7:0] pb_in,
  input wire       cb1_in,
  input wire       cb2_in,
  input wire       ca1_in,
  input wire       ca2_in,

  output wire [7:0] pa_out,
  output wire [7:0] pb_out,
  output wire       cb1_out,
  output wire       cb2_out,
  output wire       ca2_out,

  output wire [7:0] ddrb,
  output wire [7:0] ddra,
  output wire       ddrcb1,
  output wire       ddrcb2,

  input  wire [3:0] addr,
  input  wire [7:0] din,
  output wire [7:0] dout,

  output wire irq
);

wire irq_n;

assign irq = ~irq_n;

via_core via_core_0 (
  .clk(clk),
  .rst(reset),
  .bus_i_phi2(clk_phi),
  .bus_i_res_n(~reset),
  .bus_i_cs1(~cen),
  .bus_i_cs2_n(cen),
  .bus_i_r_w_n(~we),
  .bus_i_addr(addr),
  .bus_i_data(din),
  .bus_i_ports_pb(pb_in),
  .bus_i_ports_pa(pa_in),
  .bus_i_ports_cb2(cb2_in),
  .bus_i_ports_cb1(cb1_in),
  .bus_i_ports_ca2(ca2_in),
  .bus_i_ports_ca1(ca1_in),
  .bus_o_data(dout),
  .bus_o_ports_pb(pb_out),
  .bus_o_ports_pa(pa_out),
  .bus_o_ports_ddrb(ddrb),
  .bus_o_ports_ddra(ddra),
  .bus_o_ports_cb1(cb1_out),
  .bus_o_ports_cb2(cb2_out),
  .bus_o_ports_ca2(ca2_out),
  .bus_o_ports_ddrcb1(ddrcb1),
  .bus_o_ports_ddrcb2(ddrcb2),
  .bus_o_irq_n(irq_n)
);

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
