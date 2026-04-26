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

// based on DC_blocker module from MiSTer iir_filter.v

`default_nettype none
`timescale 1 ns / 1 ps
module dc_blocker (
  input  wire clk,
  input  wire reset,
  input  wire in_valid,
  output wire in_ready,
  input  wire out_ready,
  output reg  out_valid,

  input  wire signed [19:0] in,
  output wire signed [19:0] out
);

// First-order IIR DC blocker:
//   y[n] = x[n] - x[n-1] + alpha * y[n-1]
//   alpha = 1 - 2^-10
//   Corner: ~fs * 2^-10 / (2*pi) ~= 7.4 Hz at 48 kHz
//
// y_acc is 22-bit to provide 2 guard bits against feedback accumulation.

reg signed [19:0] x_prev;
reg signed [21:0] y_acc;

// alpha * y[n-1] = y[n-1] - y[n-1] >> 10
wire signed [21:0] alpha_y = y_acc - {{10{y_acc[21]}}, y_acc[21:10]};

// y[n] = x[n] - x[n-1] + alpha*y[n-1]
wire signed [21:0] y_next = {{2{in[19]}},   in}
                          - {{2{x_prev[19]}}, x_prev}
                          + alpha_y;

// Saturate to 20-bit signed range if guard bits indicate overflow
wire overflow = (y_next[21] != y_next[20]);
wire signed [21:0] y_sat = y_next[21] ? 22'sh200000 : 22'sh1fffff;

assign in_ready = !out_valid || out_ready;

always @(posedge clk) begin
  if (reset) begin
    x_prev <= 0;
    y_acc  <= 0;

  end else begin
    if (in_valid && in_ready) begin
      x_prev <= in;
      y_acc  <= overflow ? y_sat : y_next;
    end
    // out_valid: set when new sample computed, clear when consumed
    // if both happen same cycle, new sample wins
    if (in_valid && in_ready)
      out_valid <= 1'b1;
    else if (out_ready)
      out_valid <= 1'b0;
  end
end

assign out = y_acc[19:0];

endmodule
`default_nettype wire
