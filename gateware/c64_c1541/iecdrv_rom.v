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
module iecdrv_rom #(
  parameter AW            = 10,
  parameter DW            = 32,
  parameter MEM_INIT_FILE = ""
) (
  input  wire clk,
  input  wire enable,

  input  wire [AW-1:0] addr,
  output reg  [DW-1:0] dout
);

localparam integer DEPTH = (1<<AW);

reg [DW-1:0] mem[0:DEPTH-1];
reg [AW-1:0] addr_i;

initial begin
  if (MEM_INIT_FILE != "") begin
    $readmemh(MEM_INIT_FILE, mem);
  end
end

always @(posedge clk)
  if (enable)
      addr_i <= addr;

always @(*)
  dout = mem[addr_i];

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
