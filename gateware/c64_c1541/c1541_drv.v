//-------------------------------------------------------------------------------
//
// Reworked and adapted to MiSTer by Sorgelig@MiSTer (07.09.2018)
//
// Commodore 1541 to SD card by Dar (darfpga@aol.fr)
// http://darfpga.blogspot.fr
//
// c1541_logic  from : Mark McDougall
// via6522      from : Gideon Zweijtzer  <gideon.zweijtzer@gmail.com>
// c1541_track  from : Sorgelig@MiSTer
//
// c1541_logic  modified for : slow down CPU (EOI ack missed by real c64)
//                           : remove iec internal OR wired
//                           : synched atn_in (sometime no IRQ with real c64)
//
// Input clk 32MHz
//
//-------------------------------------------------------------------------------

// Heavily reworked by m1nl for Icepi Zero C64 project
// SPDX-License-Identifier: GPL-3.0-or-later

`default_nettype none
`timescale 1 ns / 1 ps
module c1541_drv (
  input  wire        clk,
  input  wire        reset,

  input  wire        gcr_ce,
  input  wire        ph2_r,
  input  wire        ph2_f,

  input  wire        img_mounted,
  input  wire        img_readonly,
  input  wire [31:0] img_size,
  input  wire [15:0] img_id,

  input  wire  [1:0] drive_num,
  output wire        led,
  output wire        busy,
  output wire        mtr,

  input  wire        iec_atn_i,
  input  wire        iec_data_i,
  input  wire        iec_clk_i,
  output wire        iec_data_o,
  output wire        iec_clk_o,

  // parallel bus
  input  wire  [7:0] par_data_i,
  input  wire        par_stb_i,
  output wire  [7:0] par_data_o,
  output wire        par_stb_o,
  input  wire        ext_en,

  output wire [14:0] rom_addr,
  input  wire  [7:0] rom_data,
  output wire        rom_cs,

  output wire [31:0] block_lba,
  output wire  [5:0] block_cnt,
  output wire        block_rd,
  output wire        block_wr,
  input  wire        block_ack,

  output wire [12:0] buff_addr,
  input  wire  [7:0] buff_dout,
  output wire  [7:0] buff_din,
  output wire        buff_we,
  output wire        buff_en
);

assign led = act;

reg        present    = 0;
reg        readonly   = 1;
reg        disk_ready = 0;
reg [15:0] disk_id    = 16'b0;
reg [24:0] ch_timeout = 25'h1FFFFFF;

always @(posedge clk) begin
  if (reset || img_mounted) begin
    present    <= img_size != 32'd0;
    readonly   <= img_readonly;
    disk_ready <= 0;
    disk_id    <= img_id;
    ch_timeout <= 25'h1FFFFFF;

  end else if (ch_timeout == 25'd0)
    disk_ready <= present;
  else if (gcr_ce)
    ch_timeout <= ch_timeout - 25'd1;
end

wire       mode;  // read / write
wire [1:0] stp;
wire       act;
wire [1:0] freq;
wire       wps_n = ~readonly ^ ch_timeout[23];
wire       track_delay;

reg [6:0] track;

c1541_logic c1541_logic (
  .clk(clk),
  .reset(reset),

  .ph2_r(ph2_r),
  .ph2_f(ph2_f),

  // serial bus
  .iec_clk_in(iec_clk_i),
  .iec_data_in(iec_data_i),
  .iec_atn_in(iec_atn_i),
  .iec_clk_out(iec_clk_o),
  .iec_data_out(iec_data_o),

  .ext_en(ext_en),
  .rom_addr(rom_addr),
  .rom_data(rom_data),
  .rom_cs(rom_cs),

  // parallel bus
  .par_data_in(par_data_i),
  .par_stb_in(par_stb_i),
  .par_data_out(par_data_o),
  .par_stb_out(par_stb_o),

  // drive-side interface
  .ds(drive_num),
  .din(gcr_do),
  .dout(gcr_di),
  .mode(mode),
  .stp(stp),
  .mtr(mtr),
  .freq(freq),
  .sync_n(gcr_sync_n),
  .byte_n(gcr_byte_n),
  .wps_n(wps_n),
  .tr00_sense_n(|track),
  .act(act)
);

wire [7:0] gcr_di;
wire [7:0] gcr_do;

wire gcr_sync_n;
wire gcr_byte_n;

c1541_gcr c1541_gcr (
  .clk(clk),
  .reset(reset),
  .ce(gcr_ce),

  .dout(gcr_do),
  .din(gcr_di),
  .mode(mode),
  .mtr(mtr),
  .freq(freq),
  .wps_n(wps_n),
  .sync_n(gcr_sync_n),
  .byte_n(gcr_byte_n),
  .busy(busy || !disk_ready || track_delay),

  .img_mounted(img_mounted),
  .disk_id(disk_id),
  .track(track),

  .buff_addr(buff_addr),
  .buff_dout(buff_dout),
  .buff_din(buff_din),
  .buff_we(buff_we),
  .buff_en(buff_en)
);

c1541_track c1541_track (
  .clk(clk),
  .reset(reset),

  .block_lba(block_lba),
  .block_cnt(block_cnt),
  .block_rd(block_rd),
  .block_wr(block_wr),
  .block_ack(block_ack),

  .save_track(save_track),
  .img_mounted(img_mounted),
  .track(track),
  .busy(busy)
);

reg [6:0] track_next;

reg track_modified;
reg save_track;

always @(*) begin
  track_next = track;

  case ({track[1:0], stp})
    4'b0001, 4'b0110, 4'b1011, 4'b1100:
      if (track < 84) track_next = track + 1;
    4'b0011, 4'b0100, 4'b1001, 4'b1110:
      if (track >  0) track_next = track - 1;
    default: ;
  endcase
end

localparam integer TRACK_DELAY         = 1000;  // 1 ms, in 1MHz ticks
localparam integer DELAY_COUNTER_WIDTH = $clog2(TRACK_DELAY);

reg [DELAY_COUNTER_WIDTH-1:0] delay_counter;

always @(posedge clk) begin
  if (reset || img_mounted)
    delay_counter <= 0;
  else if (track_next != track)
    delay_counter <= TRACK_DELAY[DELAY_COUNTER_WIDTH-1:0];
  else if (ph2_r && delay_counter != 0)
    delay_counter <= delay_counter - 1;
end

assign track_delay = (delay_counter != 0);

always @(posedge clk) begin
  if (reset) begin
    track          <= 0;
    track_modified <= 0;

  end else if (img_mounted) begin
    track_modified <= 0;

  end else if (disk_ready) begin
    track <= track_next;

    if (track_modified || buff_we) begin
      track_modified <= 1;

      if (track != track_next || !act) begin
        save_track     <= !save_track;
        track_modified <= 0;
      end
    end
  end
end

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
