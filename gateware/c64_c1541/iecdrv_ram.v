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
  parameter AW = 10,
  parameter DW = 32
) (
  input  wire clk,
  input  wire we,

  input  wire [AW-1:0] addr,
  input  wire [DW-1:0] din,
  output reg  [DW-1:0] dout
);

localparam integer DEPTH = (1<<AW);

reg [DW-1:0] mem[0:DEPTH-1];

always @(posedge clk) begin
  if (we) begin
    mem[addr] <= din;
    dout      <= din;
  end else
    dout <= mem[addr];
end

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
