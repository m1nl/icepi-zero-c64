/////////////////////////////////////////////////////////////////////////
//
// c1541_track
// Copyright (c) 2016 Sorgelig
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the Lesser GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
/////////////////////////////////////////////////////////////////////////

// Heavily reworked by m1nl for Icepi Zero C64 project
// SPDX-License-Identifier: GPL-3.0-or-later

`default_nettype none
`timescale 1 ns / 1 ps
module c1541_track (
  input wire         clk,
  input wire         reset,

  output wire [31:0] block_lba,
  output wire  [5:0] block_cnt,
  output reg         block_rd,
  output reg         block_wr,
  input  wire        block_ack,

  input  wire        save_track,
  input  wire        img_mounted,
  input  wire  [6:0] track,
  output wire        busy
);

reg [6:0] track_r;

reg [5:0] track_next;
reg [5:0] track_current;

reg [9:0] lba;
reg [9:0] len;

reg save_track_r;
reg update;

assign block_lba = {22'b0, lba};
assign block_cnt = len[5:0];

assign busy = block_wr || block_rd || (track_current != track_next);

reg [9:0] start_sectors [0:40];

initial begin
  $readmemh("mem/start_sectors.mem", start_sectors);
end

// early detection of track change
always @(*) begin
  track_next = track_current;

  if (!track[0])
    track_next = track[6:1];
  else if (track > track_r)
    track_next = track_current + 1;
  else if (track < track_r)
    track_next = track_current - 1;
end

always @(posedge clk) begin
  track_r <= track;

  if (img_mounted)
    update <= 1;

  if (reset) begin
    track_current <= 0;
    update        <= 1;

    block_rd <= 0;
    block_wr <= 0;

  end else if (block_ack) begin
    block_rd <= 0;
    block_wr <= 0;

  end else if (!block_wr && !block_rd) begin
    save_track_r <= save_track;

    if ((save_track_r != save_track) && !(&track[6:1])) begin
      len      <= start_sectors[track_current + 1] - start_sectors[track_current];
      lba      <= start_sectors[track_current];
      block_wr <= 1;

    end else if ((track_current != track_next) || update) begin
      track_current <= track_next;
      update        <= 0;

      len      <= start_sectors[track_next + 1] - start_sectors[track_next];
      lba      <= start_sectors[track_next];
      block_rd <= 1;
    end
  end
end

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
