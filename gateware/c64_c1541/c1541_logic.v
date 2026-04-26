//-------------------------------------------------------------------------------
//
// Reworked and adapted to MiSTer by Sorgelig@MiSTer (07.09.2018)
//
//-------------------------------------------------------------------------------

// Heavily reworked by m1nl for Icepi Zero C64 project
// SPDX-License-Identifier: GPL-3.0-or-later

`default_nettype none
`timescale 1 ns / 1 ps
module c1541_logic #(
  parameter CPU_MODEL = 1
) (
  input wire clk,
  input wire reset,

  input wire ph2_r,
  input wire ph2_f,

  // serial bus
  input  wire iec_clk_in,
  input  wire iec_data_in,
  input  wire iec_atn_in,
  output wire iec_clk_out,
  output wire iec_data_out,

  input wire ext_en,

  output wire [14:0] rom_addr,
  input  wire [ 7:0] rom_data,
  output wire        rom_cs,

  // parallel bus
  input  wire [7:0] par_data_in,
  input  wire       par_stb_in,
  output wire [7:0] par_data_out,
  output wire       par_stb_out,

  // drive-side interface
  input  wire [1:0] ds,            // device select
  input  wire [7:0] din,           // disk read data
  output wire [7:0] dout,          // disk write data
  output wire       mode,          // read/write
  output wire [1:0] stp,           // stepper motor control
  output wire       mtr,           // spindle motor on/off
  output wire [1:0] freq,          // motor frequency
  input  wire       sync_n,        // reading SYNC bytes
  input  wire       byte_n,        // byte ready
  input  wire       wps_n,         // write-protect sense
  input  wire       tr00_sense_n,  // track 0 sense
  output wire       act            // activity LED
);

wire [15:0] cpu_a;
wire [ 7:0] cpu_do;
wire        cpu_rw;
wire        cpu_irq_n;
wire        cpu_so_n;

assign cpu_irq_n = ~(uc1_irq | uc3_irq);
assign cpu_so_n  = byte_n | ~soe;

wire [ 7:0] ram_do;

assign rom_addr = cpu_a[14:0];
assign rom_cs   = cpu_a[15];

// same decoder as on real HW
wire [3:0] ls42   = {cpu_a[15], cpu_a[12:10]};
wire       ram_cs = ls42 == 0 || ls42 == 1;
wire       uc1_cs = ls42 == 6;
wire       uc3_cs = ls42 == 7;

wire [7:0] cpu_di =
  !cpu_rw ? cpu_do :
   ram_cs ? ram_do :
   uc1_cs ? uc1_do :
   uc3_cs ? uc3_do :
   rom_cs ? rom_data :
   8'hFF;

generate
  if (CPU_MODEL) begin : CPU_6502
    proc_core cpu (
      .clock(clk),
      .clock_en(ph2_f),
      .reset(reset),
      .ready(1'b1),
      .irq_n(cpu_irq_n),
      .nmi_n(1'b1),
      .so_n(cpu_so_n),
      .addr_out(cpu_a),
      .data_in(cpu_di),
      .data_out(cpu_do),
      .read_write_n(cpu_rw),
      .interrupt_ack(),
      .pc_out()
    );
  end else begin : CPU_T65
    T65 cpu (
      .mode(2'b00),
      .res_n(~reset),
      .enable(ph2_f),
      .clk(clk),
      .rdy(1'b1),
      .abort_n(1'b1),
      .irq_n(cpu_irq_n),
      .nmi_n(1'b1),
      .so_n(cpu_so_n),
      .r_w_n(cpu_rw),
      .A(cpu_a),
      .DI(cpu_di),
      .DO(cpu_do)
    );
  end
endgenerate

iecdrv_ram #(
  .DW(8),
  .AW(11)
) ram (
  .clk(clk),
  .enable(ph2_r & ram_cs),
  .we(~cpu_rw & ram_cs),
  .addr(cpu_a[10:0]),
  .din(cpu_do),
  .dout(ram_do)
);

// UC1 (VIA6522) signals
wire [7:0] uc1_do;
wire       uc1_irq;
wire [7:0] uc1_pa_o;
wire [7:0] uc1_pa_oe;
wire       uc1_ca2_o;
wire       uc1_ca2_oe;
wire [7:0] uc1_pb_o;
wire [7:0] uc1_pb_oe;
wire       uc1_cb1_o;
wire       uc1_cb1_oe;
wire       uc1_cb2_o;
wire       uc1_cb2_oe;

assign iec_data_out = ~(uc1_pb_o[1] | ~uc1_pb_oe[1]) & ~((uc1_pb_o[4] | ~uc1_pb_oe[4]) ^ ~iec_atn_in);
assign iec_clk_out  = ~(uc1_pb_o[3] | ~uc1_pb_oe[3]);

assign par_stb_out  = uc1_ca2_o | ~uc1_ca2_oe;
assign par_data_out = uc1_pa_o | ~uc1_pa_oe;

iecdrv_via6522 uc1 (
  .clock(clk),
  .rising(ph2_r),
  .falling(ph2_f),
  .reset(reset),

  .addr(cpu_a[3:0]),
  .wen(~cpu_rw & uc1_cs),
  .ren(cpu_rw & uc1_cs),
  .data_in(cpu_do),
  .data_out(uc1_do),

  .port_a_o(uc1_pa_o),
  .port_a_t(uc1_pa_oe),
  .port_a_i((ext_en ? par_data_in : {7'h7F, tr00_sense_n}) & (uc1_pa_o | ~uc1_pa_oe)),

  .port_b_o(uc1_pb_o),
  .port_b_t(uc1_pb_oe),
  .port_b_i({~iec_atn_in, ds, 2'b11, ~iec_clk_in, 1'b1, ~iec_data_in} & (uc1_pb_o | ~uc1_pb_oe)),

  .ca1_i(~iec_atn_in),

  .ca2_o(uc1_ca2_o),
  .ca2_t(uc1_ca2_oe),
  .ca2_i(uc1_ca2_o | ~uc1_ca2_oe),

  .cb1_o(uc1_cb1_o),
  .cb1_t(uc1_cb1_oe),
  .cb1_i((ext_en ? par_stb_in : 1'b1) & (uc1_cb1_o | ~uc1_cb1_oe)),

  .cb2_o(uc1_cb2_o),
  .cb2_t(uc1_cb2_oe),
  .cb2_i(uc1_cb2_o | ~uc1_cb2_oe),

  .irq(uc1_irq)
);

// UC3 (VIA6522) signals
wire [7:0] uc3_do;
wire       uc3_irq;
wire [7:0] uc3_pa_o;
wire [7:0] uc3_pa_oe;
wire       uc3_ca2_o;
wire       uc3_ca2_oe;
wire [7:0] uc3_pb_o;
wire [7:0] uc3_pb_oe;
wire       uc3_cb1_o;
wire       uc3_cb1_oe;
wire       uc3_cb2_o;
wire       uc3_cb2_oe;
wire       soe;

assign soe  = uc3_ca2_o | ~uc3_ca2_oe;
assign dout = uc3_pa_o | ~uc3_pa_oe;
assign mode = uc3_cb2_o | ~uc3_cb2_oe;

assign stp  = uc3_pb_o[1:0] | ~uc3_pb_oe[1:0];
assign mtr  = uc3_pb_o[2] | ~uc3_pb_oe[2];
assign act  = uc3_pb_o[3] | ~uc3_pb_oe[3];
assign freq = uc3_pb_o[6:5] | ~uc3_pb_oe[6:5];

iecdrv_via6522 uc3 (
  .clock  (clk),
  .rising (ph2_r),
  .falling(ph2_f),
  .reset  (reset),

  .addr(cpu_a[3:0]),
  .wen(~cpu_rw & uc3_cs),
  .ren(cpu_rw & uc3_cs),
  .data_in(cpu_do),
  .data_out(uc3_do),

  .port_a_o(uc3_pa_o),
  .port_a_t(uc3_pa_oe),
  .port_a_i(din & (uc3_pa_o | ~uc3_pa_oe)),

  .port_b_o(uc3_pb_o),
  .port_b_t(uc3_pb_oe),
  .port_b_i({sync_n, 2'b11, wps_n, 4'b1111} & (uc3_pb_o | ~uc3_pb_oe)),

  .ca1_i(cpu_so_n),

  .ca2_o(uc3_ca2_o),
  .ca2_t(uc3_ca2_oe),
  .ca2_i(uc3_ca2_o | ~uc3_ca2_oe),

  .cb1_o(uc3_cb1_o),
  .cb1_t(uc3_cb1_oe),
  .cb1_i(uc3_cb1_o | ~uc3_cb1_oe),

  .cb2_o(uc3_cb2_o),
  .cb2_t(uc3_cb2_oe),
  .cb2_i(uc3_cb2_o | ~uc3_cb2_oe),

  .irq(uc3_irq)
);

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
