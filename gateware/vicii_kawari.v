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

// ---------------------------------------------------------------------------
// This file is based on the vicii-kawari distribution
// (https://github.com/randyrossi/vicii-kawari)
// Copyright (c) 2022 Randy Rossi.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

`include "config.vh"
`include "vicii-kawari/hdl/common.vh"

module vicii_kawari #(
  parameter VIDEO_CLK_FREQUENCY = 27_588_750,
  parameter AUDIO_RATE = 48_000
) (
  input clk_dot4x,
  input rst_dot4x,

  input clk_dvi,
  input rst_dvi,

  // If we are generating luma/chroma, add outputs
`ifdef GEN_LUMA_CHROMA
  output luma_sink,    // luma current sink
  output [5:0] luma,   // luma out
  output [5:0] chroma, // chroma out
`endif

`ifdef WITH_EXTENSIONS
`ifdef HAVE_FLASH
  output flash_s,
`endif
`ifdef WITH_SPI
  output spi_d,
  input  spi_q,
  output spi_c,
  output flash_d1,
  output flash_d2,
`endif
`ifdef HAVE_EEPROM
  input cfg_reset,
  output eeprom_s,
`endif
`endif // WITH_EXTENSIONS

  output reset,        // for pulling 6510 reset HIGH
  input reset_req,
  input stall,
  output clk_phi,      // output phi clock for CPU
  output phi2_l,
  output phi2_p,
  output phi2_h,
  output phi2_n,
  output clk_dot_ext,  // dot clock
`ifdef NEED_RGB
  output hsync,        // hsync signal (optional)
  output vsync,        // vsync signal (optional)
`endif
`ifdef GEN_RGB
  output [5:0] red,    // red out for analog RGB
  output [5:0] green,  // green out for analog RGB
  output [5:0] blue,   // blue out for analog RGB
`endif

  input [5:0] adi,     // address (input)
  output [11:0] ado,   // address (output)
  input [7:0] dbi,     // data bus lines (ram/rom)
  output [7:0] dbo,    // data bus lines (ram/rom)
  input [3:0] dbh,     // data bus lines (color)

  input cen,     // chip enable n (LOW=enable, HIGH=disabled)
  input we,     // write enable (LOW=read, HIGH=write)

  output irq,    // irq
  input lp,     // light pen
  output aec,    // aec
  output ba,     // ba
  output ras,    // row address strobe
  output cas,    // column address strobe
  output cas_glitch,
  input cas_glitch_disable,
  output vic_write_db,
  output vic_write_ab

`ifdef WITH_DVI
  ,
  output [9:0] tmds_0,
  output [9:0] tmds_1,
  output [9:0] tmds_2,

  output [10:0] h_count_dvi,
  output  [9:0] v_count_dvi,

  input  [23:0] overlay_pixel,
  input         overlay_pixel_valid,

  input signed [23:0] audio_sample_word_0,
  input signed [23:0] audio_sample_word_1,
  output audio_sample_en
`endif
);

wire active;
wire rst_dvi_i;

`ifdef WITH_SPI
assign flash_d1 = 1'b1;
assign flash_d2 = 1'b1;
`endif

`ifndef GEN_RGB
// When we're not exporting these signals, we still need
// them defined as wires (for DVI for example).
`ifdef NEED_RGB
wire [5:0] red;
wire [5:0] green;
wire [5:0] blue;
`endif
`endif

`ifdef WITH_DVI
`define HAVE_SYNC_MODULE 1

wire [23:0] rgb = {{red, 2'b00}, {green, 2'b00}, {blue, 2'b00}};

cdc_sync cdc_sync_0 (
  .clk_dst(clk_dvi),
  .rst_dst(rst_dvi),
  .in(reset),
  .out(rst_dvi_i)
);

wire [23:0] pixel = overlay_pixel_valid ? overlay_pixel : rgb;

hdmi #(
  .DVI_OUTPUT(1'b0),
  .IT_CONTENT(1'b1),
  .VIDEO_ID_CODE(17),
  .VIDEO_RATE(VIDEO_CLK_FREQUENCY),
  .AUDIO_RATE(AUDIO_RATE),
  .AUDIO_BIT_WIDTH(24),
  .BIT_WIDTH(10),
  .BIT_HEIGHT(10),
  .SCREEN_X_START(132),
  .SCREEN_X_END(852),
  .SCREEN_Y_START(16),
  .SCREEN_Y_END(592),
  .FRAME_WIDTH(882),
  .FRAME_HEIGHT(624),
  .VENDOR_NAME(64'h4336340000000000), // "C64" + nulls
  .PRODUCT_DESCRIPTION(128'h43363400000000000000000000000000), // "C64" + nulls
  .AUDIO_BIT_WIDTH(24),
  .VIDEO_RATE(27586806),
  .AUDIO_RATE(48000),
  .SOURCE_DEVICE_INFORMATION(8'h08)
) hdmi_0 (
  .clk_pixel(clk_dvi),
  .reset(rst_dvi || rst_dvi_i),

  .rgb(pixel),
  .hsync(hsync),
  .vsync(vsync),
  .cx(h_count_dvi),
  .cy(v_count_dvi),
  .de(active),

  .tmds_0(tmds_0),
  .tmds_1(tmds_1),
  .tmds_2(tmds_2),

  .audio_sample_word_0(audio_sample_word_0),
  .audio_sample_word_1(audio_sample_word_1),
  .audio_sample_en(audio_sample_en)
);

`endif

`ifdef OUTPUT_DOT_CLOCK
// NOTE: This hack will only work breadbins that use
// 8701 clock ICs and that IC MUST be removed.
// i.e. 250425 250466
// This will NOT currently work on short board motherboards
// The unit with this hack should NEVER be plugged into a
// motherboard without the clock circuit being disabled.
reg[3:0] dot_clock_shift = 4'b1100;

always @(posedge clk_dot4x) dot_clock_shift <= {dot_clock_shift[2:0], dot_clock_shift[3]};

assign clk_dot_ext = dot_clock_shift[3];
`else
assign clk_dot_ext = 1'b0;
`endif

// Instantiate the vicii with our clocks and pins.
vicii vic_inst (
  .rst(reset),
  .rst_req(reset_req || rst_dot4x),
`ifdef HIRES_RESET
  .cpu_reset_i(~reset),
`endif
  .standard_sw(1'b1), // 1 = pal, 0 = ntsc
`ifdef WITH_EXTENSIONS
  .spi_lock(1'b0),
  .extensions_lock(1'b0),
  .persistence_lock(1'b0),
`ifdef HAVE_FLASH
  .flash_s(flash_s),
`endif
`ifdef HAVE_EEPROM
  .cfg_reset(cfg_reset),
  .eeprom_s(eeprom_s),
`endif
`ifdef WITH_SPI
  .spi_d(spi_d),
  .spi_q(spi_q),
  .spi_c(spi_c),
`endif
`endif // WITH_EXTENSIONS
  .clk_dot4x(clk_dot4x),
  .stall(stall),
  .clk_phi(clk_phi),
  .phi2_l(phi2_l),
  .phi2_p(phi2_p),
  .phi2_h(phi2_h),
  .phi2_n(phi2_n),
`ifdef NEED_RGB
  .active(active),
  .hsync(hsync),
  .vsync(vsync),
  .red(red),
  .green(green),
  .blue(blue),
`endif
`ifdef HAVE_SYNC_MODULE
  .clk_dvi(clk_dvi),
  .rst_dvi(rst_dvi || rst_dvi_i),
  .h_count_dvi(h_count_dvi),
  .v_count_dvi(v_count_dvi),
`endif
  .clk_col16x(1'b0),
  .adi(adi),
  .ado(ado),
  .dbi({dbh, dbi}),
  .dbo(dbo),
  .ce(cen),
  .rw(~we),
  .aec(aec),
  .irq(irq),
  .lp(lp),
  .ba_d2(ba),
  .ras(ras),
  .cas(cas),
  .cas_glitch(cas_glitch),
  .cas_glitch_disable(cas_glitch_disable),
  .vic_write_db(vic_write_db),
  .vic_write_ab(vic_write_ab)
);

endmodule
// vim:ts=2 sw=2 tw=120 et
