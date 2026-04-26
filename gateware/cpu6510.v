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

// this module wraps either 6502N CPU core by Gideon Zweijtzer
// or T65 (multiple authors, listed in T65/T65.vhd)

`default_nettype none
`timescale 1 ns / 1 ps
module cpu6510 #(
  parameter CPU_MODEL = 1
) (
  input  wire clk,
  input  wire reset,

  input  wire rdy,
  input  wire irq,
  input  wire nmi,
  output wire nmi_ack,

  input  wire clk_phi,
  input  wire phi2_l,
  input  wire phi2_n,

  input  wire [ 7:0] din,
  output wire [ 7:0] dout,
  output wire [15:0] addr,
  output wire        we,

  input  wire [5:0] pin,
  output wire [5:0] pout,

  output wire [15:0] pc
);

wire access_io;
wire select_pdir;

wire rdy_latched;
wire irq_latched;
wire nmi_latched;

wire [7:0] din_i;
wire       rw_i;

reg rdy_r = 1'b0;
reg irq_r = 1'b0;
reg nmi_r = 1'b0;

reg [7:0] din_r;
reg [5:0] pin_r;

reg [5:0] pdir   = 6'b000000;
reg [5:0] pout_i = 6'b111111;

assign access_io   = (addr[15:1] == 15'b0);
assign select_pdir = (addr[0]    == 1'b0);

assign din_i = (we)          ? dout :
               (!access_io)  ? din_r :
               (select_pdir) ? {2'b0, pdir} : {2'b0, pout};

assign pout = (pout_i & pdir) | (pin_r & ~pdir);

assign we = !rw_i;

always @(posedge clk) begin
  if (reset) begin
    rdy_r <= 1'b0;
    irq_r <= 1'b0;
    nmi_r <= 1'b0;
  end else if (phi2_n) begin
    rdy_r <= rdy;
    irq_r <= irq;
    nmi_r <= nmi;

    din_r <= din;
    pin_r <= pin;
  end
end

assign rdy_latched = clk_phi ? rdy : rdy_r;
assign irq_latched = clk_phi ? irq : irq_r;
assign nmi_latched = clk_phi ? nmi : nmi_r;

always @(posedge clk) begin
  if (reset) begin
    pdir   <= 6'b000000;
    pout_i <= 6'b111111;
  end else if (clk_phi && we && access_io) begin
    if (select_pdir)
      pdir <= dout[5:0];
    else
      pout_i <= dout[5:0];
  end
end

generate
  if (CPU_MODEL) begin : CPU_6502N
    proc_core cpu (
      .clock(clk),
      .clock_en(phi2_l),
      .reset(reset),
      .ready(rdy_latched),
      .irq_n(~irq_latched),
      .nmi_n(~nmi_latched),
      .so_n(1'b1),
      .addr_out(addr),
      .data_in(din_i),
      .data_out(dout),
      .read_write_n(rw_i),
      .interrupt_ack(nmi_ack),
      .pc_out(pc)
    );
  end else begin : CPU_T65
    assign pc = 15'b0;

    T65 cpu (
      .Mode(2'b00),
      .Res_n(~reset),
      .Enable(phi2_l),
      .Clk(clk),
      .Rdy(rdy_latched),
      .Abort_n(1'b1),
      .IRQ_n(~irq_latched),
      .NMI_n(~nmi_latched),
      .SO_n(1'b1),
      .R_W_n(rw_i),
      .A(addr),
      .DI(din_i),
      .DO(dout),
      .NMI_ack(nmi_ack)
    );
  end
endgenerate

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
