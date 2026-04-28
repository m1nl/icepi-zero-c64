`default_nettype none
`timescale 1ns / 1ps
module c1541_gcr_tb_top (
  input wire clk,
  input wire reset,
  input wire ce,

  output wire [7:0] dout,
  input  wire [7:0] din,
  input  wire       mode,
  input  wire       mtr,
  input  wire [1:0] freq,
  output wire       sync_n,
  output wire       byte_n,
  input  wire       wps_n,

  input wire [6:0]  track,
  input wire        busy,
  input wire        img_mounted,

  input wire [15:0] disk_id,

  output wire [12:0] buff_addr,
  input  wire [7:0]  buff_dout,
  output wire [7:0]  buff_din,
  output wire        buff_we,
  output wire        buff_en
);

c1541_gcr c1541_gcr_inst (
  .clk(clk),
  .reset(reset),
  .ce(ce),
  .dout(dout),
  .din(din),
  .mode(mode),
  .mtr(mtr),
  .freq(freq),
  .sync_n(sync_n),
  .byte_n(byte_n),
  .track(track),
  .busy(busy),
  .img_mounted(img_mounted),
  .wps_n(wps_n),
  .disk_id(disk_id),
  .buff_addr(buff_addr),
  .buff_dout(buff_dout),
  .buff_din(buff_din),
  .buff_we(buff_we),
  .buff_en(buff_en)
);

endmodule
`default_nettype wire
