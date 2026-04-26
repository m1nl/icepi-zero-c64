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
module c64_redip_cia #(
  parameter GENERATE_TOD  = 1,
  parameter NTSC          = 0,
  parameter CLK_FREQUENCY = 31_527_777
) (
  input wire clk,
  input wire reset,

  input wire clk_phi,
  input wire phi2_p,
  input wire phi2_n,

  input wire cen,
  input wire we,

  input  wire [3:0] addr,
  input  wire [7:0] din,
  output wire [7:0] dout,

  input  wire [7:0] pa_in,
  output wire [7:0] pa_out,
  output wire [7:0] ddra,

  input  wire [7:0] pb_in,
  output wire [7:0] pb_out,
  output wire [7:0] ddrb,

  input  wire sp_in,
  output wire sp_out,

  input  wire cnt_in,
  output wire cnt_out,

  input  wire flag_n,
  output wire pc_n,

  output wire irq,

  output reg tod_out,
  input wire tod_in,

  input wire cia_model
);

wire tod_clk;

generate
  if (GENERATE_TOD) begin
    localparam integer TOD_INCREMENT = (NTSC ? 120 : 100);
    localparam integer TOD_CNT_WIDTH = $clog2(CLK_FREQUENCY + TOD_INCREMENT + 1);

    reg [TOD_CNT_WIDTH-1:0] tod_cnt;

    always @(posedge clk)
      if (reset) begin
        tod_out <= 1'b0;
        tod_cnt <= 0;

      end else begin
        tod_cnt <= tod_cnt + TOD_INCREMENT[TOD_CNT_WIDTH-1:0];

        if (tod_cnt >= CLK_FREQUENCY) begin
          tod_cnt <= tod_cnt - CLK_FREQUENCY[TOD_CNT_WIDTH-1:0] +
            TOD_INCREMENT[TOD_CNT_WIDTH-1:0];
          tod_out <= ~tod_out;
        end
      end

    assign tod_clk = tod_out;
  end else begin
    assign tod_clk = tod_in;
  end
endgenerate

wire irq_n;

assign irq = ~irq_n;

cia_core cia_core_0 (
  .clk(clk),
  .phi2_up(phi2_p),
  .phi2_dn(phi2_n),
  .rst(reset),
  .cia_model(cia_model),
  .bus_i_phi2(clk_phi),
  .bus_i_res_n(~reset),
  .bus_i_cs_n(cen),
  .bus_i_r_w_n(~we),
  .bus_i_addr(addr),
  .bus_i_data(din),
  .bus_i_pa(pa_in),
  .bus_i_pb(pb_in),
  .bus_i_flag_n(flag_n),
  .bus_i_tod(tod_clk),
  .bus_i_cnt(cnt_in),
  .bus_i_sp(sp_in),
  .bus_o_data(dout),
  .bus_o_ports_pra(pa_out),
  .bus_o_ports_prb(pb_out),
  .bus_o_ports_ddra(ddra),
  .bus_o_ports_ddrb(ddrb),
  .bus_o_pc_n(pc_n),
  .bus_o_cnt(cnt_out),
  .bus_o_sp(sp_out),
  .bus_o_irq_n(irq_n)
);

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
