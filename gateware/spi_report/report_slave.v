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
// Co-developed by GPT-6.1 Sol
// ---------------------------------------------------------------------------
// Receive-only MCU SPI, mode 1, MSB first.
// ---------------------------------------------------------------------------

`default_nettype none
`timescale 1 ns / 1 ps
module spi_report_slave #(
  parameter DEBUG = 0
) (
  input wire clk,
  input wire reset,

  input wire spi_cs_n,
  input wire spi_clk,
  input wire spi_mosi,
  input wire rd_ack,

  output wire  [7:0] rd_data,
  output wire        not_empty,
  output wire        receiving,
  output wire        irq,
  output wire [31:0] wr_count,
  output wire [31:0] head_info
);

reg [2:0] bit_count;
reg [6:0] shift;
reg       first_byte;
reg       selected;

reg [7:0] byte_data;
reg       byte_toggle;
reg       byte_start;

wire [7:0] byte_in = {shift, spi_mosi};
wire       byte_accept = !spi_cs_n && bit_count == 3'd7 &&
                         (first_byte ? byte_in == 8'h01 : selected);

// SCK itself clocks reception. CS aborts partial bytes and starts target
// decoding afresh; it must not erase a completed byte in the CDC mailbox.
wire packet_reset = reset || spi_cs_n;

always @(negedge spi_clk or posedge packet_reset) begin
  if (packet_reset) begin
    bit_count <= 0;
    shift <= 0;
    first_byte <= 1'b1;
    selected <= 1'b0;

  end else begin
    shift <= byte_in[6:0];
    bit_count <= bit_count + 3'd1;
    if (bit_count == 3'd7 && first_byte) begin
      first_byte <= 1'b0;
      selected <= byte_in == 8'h01;
    end
  end
end

// Toggle CDC retains even a final byte followed immediately by CS high.
// byte_data is stable until the next accepted byte (eight SCK periods).
// Allow at least four system-clock periods between completed bytes.
always @(negedge spi_clk or posedge reset) begin
  if (reset) begin
    byte_data <= 0;
    byte_toggle <= 0;
    byte_start <= 0;

  end else if (byte_accept) begin
    byte_data <= byte_in;
    byte_toggle <= ~byte_toggle;
    byte_start <= first_byte;
  end
end

(* async_reg = "true" *) reg [1:0] byte_sync;
(* async_reg = "true" *) reg [1:0] cs_sync;

reg       byte_seen;
reg [2:0] wr_ptr;
reg [2:0] rd_ptr;
reg [3:0] level;
reg [7:0] packet_starts;
wire [26:0] overruns;

wire wr_en = !reset && (byte_sync[1] != byte_seen);
wire pop   = rd_ack && not_empty;
wire full  = level == 4'd8;

// No reset on the array: synchronous writes and asynchronous reads
// infer one distributed RAM with one write and ONE read port.
(* ram_style = "distributed", syn_ramstyle = "distributed" *)
reg [7:0] mem [0:7];

assign rd_data   = not_empty ? mem[rd_ptr] : 8'd0;
assign not_empty = level != 0;
assign head_info = {overruns, level, not_empty && packet_starts[rd_ptr]};
assign irq       = not_empty;
assign receiving = !cs_sync[0] || !cs_sync[1] ||
                   (byte_sync[0] != byte_seen) || (byte_sync[1] != byte_seen);

generate
  if (DEBUG) begin : debug_counters
    reg [26:0] overrun_count;
    reg [31:0] write_count;

    assign overruns = overrun_count;
    assign wr_count = write_count;

    always @(posedge clk) begin
      if (reset) begin
        overrun_count <= 0;
        write_count <= 0;
      end else begin
        if (wr_en && !pop && full)
          overrun_count <= overrun_count + 27'd1;
        if (wr_en)
          write_count <= write_count + 32'd1;
      end
    end
  end else begin : no_debug_counters
    assign overruns = 27'd0;
    assign wr_count = 32'd0;
  end
endgenerate

always @(posedge clk) begin
  if (reset) begin
    byte_sync <= 0;
    cs_sync <= 2'b11;
    byte_seen <= 0;
    wr_ptr <= 0;
    rd_ptr <= 0;
    level <= 0;
    packet_starts <= 0;

  end else begin
    byte_sync <= {byte_sync[0], byte_toggle};
    cs_sync <= {cs_sync[0], spi_cs_n};
    byte_seen <= byte_sync[1];

    // Full writes overwrite the oldest byte. A simultaneous pop
    // makes room for the write and does not count as an overrun.
    if (pop || (wr_en && full))
        rd_ptr <= rd_ptr + 3'd1;
    if (wr_en && !pop && !full)
        level <= level + 4'd1;
    else if (pop && !wr_en)
        level <= level - 4'd1;

    if (wr_en) begin
      wr_ptr <= wr_ptr + 3'd1;
      packet_starts[wr_ptr] <= byte_start;
    end
  end
end

always @(posedge clk) begin
  if (wr_en)
    mem[wr_ptr] <= byte_data;
end

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
