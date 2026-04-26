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
module cdc_pulse (
  input  wire clk_src,
  input  wire rst_src,
  input  wire clk_dst,
  input  wire rst_dst,
  input  wire in,
  output wire out
);

reg toggle_src;

always @(posedge clk_src or posedge rst_src) begin
  if (rst_src)
    toggle_src <= 1'b0;
  else if (in)
    toggle_src <= ~toggle_src;
end

(* ASYNC_REG = "TRUE" *) reg stage1;
(* ASYNC_REG = "TRUE" *) reg stage2;
reg stage3;

always @(posedge clk_dst or posedge rst_dst) begin
  if (rst_dst) begin
    stage1 <= 1'b0;
    stage2 <= 1'b0;
    stage3 <= 1'b0;
  end else begin
    stage1 <= toggle_src;
    stage2 <= stage1;
    stage3 <= stage2;
  end
end

assign out = stage2 ^ stage3;

endmodule
// vim:ts=2 sw=2 tw=120 et
