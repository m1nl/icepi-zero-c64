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
module cdc_handshake #(
  parameter WIDTH        = 8,
  parameter EXTERNAL_ACK = 0
) (
  input  wire             clk_src,
  input  wire             rst_src,
  input  wire [WIDTH-1:0] data_in,
  input  wire             send,
  output wire             busy,

  input  wire             clk_dst,
  input  wire             rst_dst,
  output reg  [WIDTH-1:0] data_out,
  output reg              valid,
  input  wire             ack_in
);

reg              req_src;
reg  [WIDTH-1:0] data_hold;

(* ASYNC_REG = "TRUE" *) reg req_dst_s1;
(* ASYNC_REG = "TRUE" *) reg req_dst_s2;

(* ASYNC_REG = "TRUE" *) reg ack_src_s1;
(* ASYNC_REG = "TRUE" *) reg ack_src_s2;

reg ack_dst;

assign busy = req_src ^ ack_src_s2;

always @(posedge clk_src or posedge rst_src) begin
  if (rst_src) begin
    req_src    <= 1'b0;
    data_hold  <= {WIDTH{1'b0}};
    ack_src_s1 <= 1'b0;
    ack_src_s2 <= 1'b0;
  end else begin
    ack_src_s1 <= ack_dst;
    ack_src_s2 <= ack_src_s1;
    if (send && !busy) begin
      data_hold <= data_in;
      req_src   <= ~req_src;
    end
  end
end

always @(posedge clk_dst or posedge rst_dst) begin
  if (rst_dst) begin
    req_dst_s1 <= 1'b0;
    req_dst_s2 <= 1'b0;
    ack_dst    <= 1'b0;
    data_out   <= {WIDTH{1'b0}};
    valid      <= 1'b0;
  end else begin
    req_dst_s1 <= req_src;
    req_dst_s2 <= req_dst_s1;
    if (req_dst_s2 != ack_dst && !valid) begin
      data_out <= data_hold;
      valid    <= 1'b1;
    end else if (valid && (!EXTERNAL_ACK || ack_in)) begin
      valid   <= 1'b0;
      ack_dst <= ~ack_dst;
    end
  end
end

endmodule
// vim:ts=2 sw=2 tw=120 et
