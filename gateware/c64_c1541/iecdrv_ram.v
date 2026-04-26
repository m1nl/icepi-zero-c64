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
module iecdrv_ram #(
  parameter AW      = 10,
  parameter DW      = 32,
  parameter PATTERN = 0,
  parameter DELAY   = 0
) (
  input  wire clk,
  input  wire enable,
  input  wire we,

  input  wire [AW-1:0] addr,
  input  wire [DW-1:0] din,
  output reg  [DW-1:0] dout
);

localparam integer DEPTH = (1<<AW);

reg [DW-1:0] mem[0:DEPTH-1];

generate
  if (PATTERN) begin
    integer i;
    initial begin
      mem[0] = {DW{1'b0}};
      mem[1] = {DW{1'b0}};

      for (i = 2; i < DEPTH; i = i + 1) begin
        if (((i - 2) % 8) < 4)
          mem[i] = {DW{1'b1}};
        else
          mem[i] = {DW{1'b0}};
      end
    end
  end
endgenerate

generate
  if (DELAY == 0) begin
    // No delay - original behavior
    always @(posedge clk)
      if (enable)
        if (we)
          mem[addr] <= din;
        else
          dout <= mem[addr];

  end else begin
    // SRAM delay implementation with single counter
    reg [$clog2(DELAY)-1:0] delay_counter;
    reg [AW-1:0] latched_addr;

    // SRAM-like behavior with delay
    always @(posedge clk) begin
      if (enable) begin
        latched_addr <= addr;

        if (we)
          mem[addr] <= din;
        else if (addr != latched_addr) begin
          delay_counter <= DELAY - 1;
        end else if (delay_counter > 0) begin
          delay_counter <= delay_counter - 1;
        end else
          dout <= mem[latched_addr];
      end
    end
  end
endgenerate

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
