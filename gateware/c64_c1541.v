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
module c64_c1541 #(
  parameter NTSC = 0,
  parameter DRIVE_NUM = 0,
  parameter EXTERNAL_ROM = 0
) (
  input  wire        clk,
  input  wire        reset,

  input  wire        img_mounted,
  input  wire        img_readonly,
  input  wire [31:0] img_size,
  input  wire [15:0] img_id,

  output wire        led,
  output wire        busy,
  output wire        mtr,

  input  wire        iec_atn_i,
  input  wire        iec_data_i,
  input  wire        iec_clk_i,
  output wire        iec_data_o,
  output wire        iec_clk_o,

  output wire [31:0] block_lba,
  output wire  [5:0] block_cnt,
  output wire        block_rd,
  output wire        block_wr,
  input  wire        block_ack,

  output wire [12:0] buff_addr,
  input  wire  [7:0] buff_dout,
  output wire  [7:0] buff_din,
  output wire        buff_we,
  output wire        buff_en,

  output wire        ext_rom_en,
  output wire [13:0] ext_rom_addr,
  input  wire  [7:0] ext_rom_dout
);

wire clk_f;
wire clk_r;

// approximate 16MHz from C64 PAL or NTSC frequency

localparam integer FREQUENCY_NORMALIZED = NTSC ? 135 : 132;
localparam integer GCR_INCREMENT        = NTSC ?  66 :  67;
localparam integer GCR_CNT_WIDTH        = $clog2(FREQUENCY_NORMALIZED + GCR_INCREMENT + 1);

wire gcr_ce;

reg [GCR_CNT_WIDTH-1:0] gcr_ce_cnt  = 0;
reg [3:0]               clock_phase = 0;

assign gcr_ce = (gcr_ce_cnt >= FREQUENCY_NORMALIZED[GCR_CNT_WIDTH-1:0]);

assign clk_r  = (clock_phase == 4'd0) && gcr_ce;
assign clk_f  = (clock_phase == 4'd8) && gcr_ce;

always @(posedge clk) begin
  if (reset) begin
    gcr_ce_cnt  <= 0;
    clock_phase <= 0;

  end else begin
    gcr_ce_cnt <= gcr_ce_cnt + GCR_INCREMENT[GCR_CNT_WIDTH-1:0];

    if (gcr_ce) begin
      clock_phase <= clock_phase + 4'd1;
      gcr_ce_cnt  <= gcr_ce_cnt + GCR_INCREMENT[GCR_CNT_WIDTH-1:0] -
        FREQUENCY_NORMALIZED[GCR_CNT_WIDTH-1:0];
    end
  end
end

wire [14:0] rom_addr;
wire [7:0]  rom_dout;
wire        rom_cs;

generate
  if (EXTERNAL_ROM == 0) begin
    iecdrv_rom #(
      .AW(14),
      .DW(8),
      .MEM_INIT_FILE("mem/c1541_rom_251968_03.mem")
    ) rom (
      .clk(clk),
      .enable(clk_r && rom_cs),
      .addr(rom_addr[13:0]),
      .dout(rom_dout)
    );

  end else begin
    assign ext_rom_addr = rom_addr;
    assign ext_rom_en   = clk_r && rom_cs;
    assign rom_dout     = ext_rom_dout;
  end
endgenerate

wire iec_data, iec_clk;

assign iec_clk_o  = iec_clk  || reset;
assign iec_data_o = iec_data || reset;

wire led_drv;
wire busy_drv;

assign led  = led_drv  && !reset;
assign busy = busy_drv && !reset;

c1541_drv c1541_drv (
  .clk(clk),
  .reset(reset),

  .gcr_ce(gcr_ce),
  .ph2_r(clk_r),
  .ph2_f(clk_f),

  .img_mounted(img_mounted),
  .img_readonly(img_readonly),
  .img_size(img_size),

  .drive_num(DRIVE_NUM),
  .led(led_drv),
  .busy(busy_drv),

  .iec_atn_i(iec_atn_i),
  .iec_data_i(iec_data_i),
  .iec_clk_i(iec_clk_i),
  .iec_data_o(iec_data),
  .iec_clk_o(iec_clk),

  .ext_en(1'b0),

  .rom_addr(rom_addr),
  .rom_data(rom_dout),
  .rom_cs(rom_cs),

  .block_lba(block_lba),
  .block_cnt(block_cnt),
  .block_rd(block_rd),
  .block_wr(block_wr),
  .block_ack(block_ack),

  .img_id(img_id),

  .buff_addr(buff_addr),
  .buff_dout(buff_dout),
  .buff_din(buff_din),
  .buff_we(buff_we),
  .buff_en(buff_en),

  .mtr(mtr)
);

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
