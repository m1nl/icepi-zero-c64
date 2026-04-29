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
module c64_top #(
  parameter SDRAM_BANK = 2'b11,
  parameter C1541_EXTERNAL_ROM = 1,
  parameter SYS_CLK_FREQUENCY = 31_527_777,
  parameter TMDS_CLK_FREQUENCY = 27_588_750
) (
  input wire clk,
  input wire rst,
  input wire vic_reset_req,
  input wire cpu_reset_req,
  input wire cpu_pause_req,

  // SDRAM port (p0_* interface)
  output  reg [23:0] mem_cmd_addr,
  output  reg        mem_cmd_we,
  output  reg        mem_cmd_valid,
  input  wire        mem_cmd_ready,
  output  reg [15:0] mem_wdata,
  output  reg  [1:0] mem_wdata_we,
  input  wire        mem_wdata_ready,
  input  wire [15:0] mem_rdata,
  input  wire        mem_rdata_valid,

  // LEDs
  output wire [4:0] leds,

  // TMDS
  input  wire       tmds_clk,
  input  wire       tmds_rst,
  output wire [9:0] tmds_0,
  output wire [9:0] tmds_1,
  output wire [9:0] tmds_2,

  // USB port
  input  wire usb_clk,
  input  wire usb_rst,
  inout  wire usb_dp_0,
  inout  wire usb_dn_0,
  output wire usb_pullup_dp_0,
  output wire usb_pullup_dn_0,
  inout  wire usb_dp_1,
  inout  wire usb_dn_1,
  output wire usb_pullup_dp_1,
  output wire usb_pullup_dn_1,

  // Flags
  input  wire [15:0] flags,

  // IEC serial bus
  output wire iec_data_out,
  output wire iec_clk_out,
  output wire iec_atn_out,
  input  wire iec_data_in,
  input  wire iec_clk_in,
  input  wire iec_atn_in,

  // 1541 drive ROM
  output wire        drive_rom_en,
  output wire [11:0] drive_rom_addr,
  input  wire [31:0] drive_rom_dout,

  // 1541 drive shared memory
  output wire        drive_shmem_en,
  output wire [10:0] drive_shmem_addr,
  output wire [31:0] drive_shmem_din,
  input  wire [31:0] drive_shmem_dout,
  output reg   [3:0] drive_shmem_we,

  // Block device
  output wire [31:0] block_lba,
  output wire  [5:0] block_cnt,
  output wire        block_rd,
  output wire        block_wr,
  input  wire        block_ack,

  // Floppy disk image
  input  wire        img_mounted,
  input  wire        img_readonly,
  input  wire [31:0] img_size,
  input  wire [15:0] img_id,

  // Video overlay
  input  wire [23:0] overlay_pixel,
  output wire [10:0] overlay_pixel_x,
  output wire  [9:0] overlay_pixel_y,
  input  wire        overlay_pixel_valid,

  // HID key report
  output wire       hid_key_report_out,
  output wire [7:0] hid_key_modifiers_out,
  output wire [7:0] hid_key_0_out,

  // Tape
  input  wire       tape_play_toggle,
  output wire       tape_cass_sense_n,
  output wire       tape_cass_motor_n,
  input  wire [7:0] tap_fifo_rd_data,
  input  wire       tap_fifo_rd_valid,
  output wire       tap_fifo_rd_en,

  // PS2 emulation
  output wire       ps2_fifo_rd_en,
  input  wire [7:0] ps2_fifo_rd_data,
  input  wire       ps2_fifo_rd_valid,

  // Other
  output wire       kbd_overlay_pulse,
  output wire       kbd_reset_pulse,
  output wire       kbd_tape_play_pulse
);

// ---------------------------------------------------------------------------
// vicii_kawari_0
// ---------------------------------------------------------------------------

wire        vic_cpu_reset;
wire        vic_stall;
wire        vic_clk_phi;
wire        vic_phi2_l;
wire        vic_phi2_p;
wire        vic_phi2_h;
wire        vic_phi2_n;
wire        vic_hsync;
wire        vic_vsync;
wire  [5:0] vic_adi;
wire [11:0] vic_ado;
wire  [7:0] vic_dbi;
wire  [7:0] vic_dbo;
wire  [3:0] vic_dbh;
wire        vic_cen;
wire        vic_we;
wire        vic_irq;
wire        vic_aec;
wire        vic_ba;
wire        vic_ras;
wire        vic_cas;
wire        vic_cas_glitch;
wire        vic_write_db;
wire        vic_write_ab;
wire        vic_clk_usb;
wire        vic_rst_dvi;
wire [10:0] vic_h_count_dvi;
wire  [9:0] vic_v_count_dvi;
wire        vic_overlay_pixel_valid;
wire        vic_audio_sample_en;

wire signed [23:0] sid_audio_sample_word_0;
wire signed [23:0] sid_audio_sample_word_1;

vicii_kawari #(
  .VIDEO_CLK_FREQUENCY(TMDS_CLK_FREQUENCY),
  .AUDIO_RATE(48_000)
) video_kawari_0 (
  .clk_dot4x           (clk),
  .rst_dot4x           (rst),
  .reset               (vic_cpu_reset),
  .reset_req           (vic_reset_req),
  .stall               (vic_stall),
  .clk_phi             (vic_clk_phi),
  .phi2_l              (vic_phi2_l),
  .phi2_p              (vic_phi2_p),
  .phi2_h              (vic_phi2_h),
  .phi2_n              (vic_phi2_n),
  .clk_dot_ext         (),
  .hsync               (vic_hsync),
  .vsync               (vic_vsync),
  .adi                 (vic_adi),
  .ado                 (vic_ado),
  .dbi                 (vic_dbi),
  .dbo                 (vic_dbo),
  .dbh                 (vic_dbh),
  .cen                 (vic_cen),
  .we                  (vic_we),
  .irq                 (vic_irq),
  .lp                  (1'b0),
  .aec                 (vic_aec),
  .ba                  (vic_ba),
  .ras                 (vic_ras),
  .cas                 (vic_cas),
  .cas_glitch          (vic_cas_glitch),
  .cas_glitch_disable  (1'b1),
  .vic_write_db        (vic_write_db),
  .vic_write_ab        (vic_write_ab),
  .clk_dvi             (tmds_clk),
  .rst_dvi             (tmds_rst),
  .tmds_0              (tmds_0),
  .tmds_1              (tmds_1),
  .tmds_2              (tmds_2),
  .h_count_dvi         (vic_h_count_dvi),
  .v_count_dvi         (vic_v_count_dvi),
  .overlay_pixel       (overlay_pixel),
  .overlay_pixel_valid (vic_overlay_pixel_valid),
  .audio_sample_word_0 (sid_audio_sample_word_0),
  .audio_sample_word_1 (sid_audio_sample_word_1),
  .audio_sample_en     (vic_audio_sample_en)
);

assign overlay_pixel_x = vic_h_count_dvi;
assign overlay_pixel_y = vic_v_count_dvi;

assign vic_overlay_pixel_valid = overlay_pixel_valid && flags[6];

// ---------------------------------------------------------------------------
// cpu6510_0
// ---------------------------------------------------------------------------

wire        cpu_reset;
wire [15:0] cpu_addr;
wire  [7:0] cpu_din;
wire  [7:0] cpu_dout;
wire  [5:0] cpu_pin;
wire  [5:0] cpu_pout;
wire        cpu_we;
wire [15:0] cpu_pc;
wire        cpu_irq;
wire        cpu_nmi;
wire        cpu_nmi_ack;
reg         cpu_paused;

cpu6510 #(
  .CPU_MODEL(1)
) cpu6510_0 (
  .clk     (clk),
  .reset   (cpu_reset),
  .clk_phi (vic_clk_phi),
  .phi2_l  (vic_phi2_l),
  .phi2_n  (vic_phi2_n && !vic_stall),
  .rdy     (vic_ba && !cpu_paused),
  .irq     (cpu_irq),
  .nmi     (cpu_nmi),
  .nmi_ack (cpu_nmi_ack),
  .din     (cpu_din),
  .dout    (cpu_dout),
  .addr    (cpu_addr),
  .we      (cpu_we),
  .pin     (cpu_pin),
  .pout    (cpu_pout),
  .pc      (cpu_pc)
);

// ---------------------------------------------------------------------------
// c64_redip_sid_0
// ---------------------------------------------------------------------------

wire [8:0] sid_addr;
wire [7:0] sid_din;
wire [7:0] sid_dout;
wire       sid_cen;
wire       sid_we;
wire       sid_model     = flags[1];
wire       sid_dual      = flags[2];
wire       sid_pan       = flags[3];
wire       sid_auto_mono = flags[4];
wire       sid_pot_x;
wire       sid_pot_y;

c64_redip_sid c64_redip_sid_0 (
  .clk                 (clk),
  .reset               (cpu_reset),
  .clk_phi             (vic_clk_phi),
  .phi2_n              (vic_phi2_n && !vic_stall),
  .clk_sample          (tmds_clk),
  .reset_sample        (tmds_rst),
  .cen                 (sid_cen),
  .we                  (sid_we),
  .addr                (sid_addr),
  .din                 (sid_din),
  .dout                (sid_dout),
  .audio_sample_en     (vic_audio_sample_en),
  .audio_sample_word_0 (sid_audio_sample_word_0),
  .audio_sample_word_1 (sid_audio_sample_word_1),
  .sid_model           (sid_model),
  .sid_dual            (sid_dual),
  .sid_pan             (sid_pan),
  .sid_auto_mono       (sid_auto_mono),
  .pot_x               (sid_pot_x),
  .pot_y               (sid_pot_y)
);

// ---------------------------------------------------------------------------
// c64_redip_cia_0  (CIA1, GENERATE_TOD=1)
// ---------------------------------------------------------------------------

wire [3:0] cia1_addr;
wire [7:0] cia1_din;
wire [7:0] cia1_dout;
wire       cia1_cen;
wire       cia1_we;
wire [7:0] cia1_pa_in;
wire [7:0] cia1_pa_out;
wire [7:0] cia1_ddra;
wire [7:0] cia1_pb_in;
wire [7:0] cia1_pb_out;
wire [7:0] cia1_ddrb;
wire       cia1_irq;
wire       cia1_tod_out;
wire       cia1_flag_n;
wire       cia1_model = flags[0];

c64_redip_cia #(
  .GENERATE_TOD(1),
  .CLK_FREQUENCY(SYS_CLK_FREQUENCY)
) c64_redip_cia_0 (
  .clk       (clk),
  .reset     (cpu_reset),
  .clk_phi   (vic_clk_phi),
  .phi2_p    (vic_phi2_p && !vic_stall),
  .phi2_n    (vic_phi2_n && !vic_stall),
  .cen       (cia1_cen),
  .we        (cia1_we),
  .addr      (cia1_addr),
  .din       (cia1_din),
  .dout      (cia1_dout),
  .pa_in     (cia1_pa_in),
  .pa_out    (cia1_pa_out),
  .ddra      (cia1_ddra),
  .pb_in     (cia1_pb_in),
  .pb_out    (cia1_pb_out),
  .ddrb      (cia1_ddrb),
  .sp_in     (1'b1),
  .sp_out    (),
  .cnt_in    (1'b1),
  .cnt_out   (),
  .flag_n    (cia1_flag_n),
  .pc_n      (),
  .irq       (cia1_irq),
  .tod_out   (cia1_tod_out),
  .tod_in    (1'b0),
  .cia_model (cia1_model)
);

// ---------------------------------------------------------------------------
// c64_redip_cia_1  (CIA2, GENERATE_TOD=0)
// ---------------------------------------------------------------------------

wire [3:0] cia2_addr;
wire [7:0] cia2_din;
wire [7:0] cia2_dout;
wire       cia2_cen;
wire       cia2_we;
wire [7:0] cia2_pa_in;
wire [7:0] cia2_pa_out;
wire [7:0] cia2_ddra;
wire       cia2_irq;
wire       cia2_model = flags[0];

c64_redip_cia #(
  .GENERATE_TOD(0),
  .CLK_FREQUENCY(SYS_CLK_FREQUENCY)
) c64_redip_cia_1 (
  .clk       (clk),
  .reset     (cpu_reset),
  .clk_phi   (vic_clk_phi),
  .phi2_p    (vic_phi2_p && !vic_stall),
  .phi2_n    (vic_phi2_n && !vic_stall),
  .cen       (cia2_cen),
  .we        (cia2_we),
  .addr      (cia2_addr),
  .din       (cia2_din),
  .dout      (cia2_dout),
  .pa_in     (cia2_pa_in),
  .pa_out    (cia2_pa_out),
  .ddra      (cia2_ddra),
  .pb_in     (8'h00),
  .pb_out    (),
  .ddrb      (),
  .sp_in     (1'b1),
  .sp_out    (),
  .cnt_in    (1'b1),
  .cnt_out   (),
  .flag_n    (1'b1),
  .pc_n      (),
  .irq       (cia2_irq),
  .tod_out   (),
  .tod_in    (cia1_tod_out),
  .cia_model (cia2_model)
);

// ---------------------------------------------------------------------------
// c64_keyboard_0
// ---------------------------------------------------------------------------

wire       kbd_restore_toggle;
wire       kbd_freeze_pulse;
wire       joy_pot_x;
wire       joy_pot_y;
wire [9:0] joy_a;
wire [9:0] joy_b;
wire       hid_key_report;
wire [7:0] hid_key_modifiers;
wire       hid_key_alt;
wire [7:0] hid_key_0;
wire [7:0] hid_key_1;
wire [7:0] hid_key_2;
wire [7:0] hid_key_3;

c64_keyboard c64_keyboard_0 (
  .clk                  (clk),
  .reset                (cpu_reset),
  .enable               (!flags[6] && !hid_key_alt),
  .pa_out               (cia1_pa_out),
  .pa_in                (cia1_pa_in),
  .ddra                 (cia1_ddra),
  .pb_out               (cia1_pb_out),
  .pb_in                (cia1_pb_in),
  .ddrb                 (cia1_ddrb),
  .restore_toggle       (kbd_restore_toggle),
  .restore_toggle_ack   (cpu_nmi_ack),
  .tape_play_pulse      (kbd_tape_play_pulse),
  .overlay_pulse        (kbd_overlay_pulse),
  .reset_pulse          (kbd_reset_pulse),
  .freeze_pulse         (kbd_freeze_pulse),
  .pot_x                (joy_pot_x),
  .pot_y                (joy_pot_y),
  .joy_emulation        (flags[11:10]),
  .joy_invert           (flags[7]),
  .joy_button_space     (flags[8]),
  .joy_keyboard_control (flags[9]),
  .joy_a                (joy_a),
  .joy_b                (joy_b),
  .hid_key_report       (hid_key_report),
  .hid_key_modifiers    (hid_key_modifiers),
  .hid_key_0            (hid_key_0),
  .hid_key_1            (hid_key_1),
  .hid_key_2            (hid_key_2),
  .hid_key_3            (hid_key_3),
  .ps2_fifo_rd_en       (ps2_fifo_rd_en),
  .ps2_fifo_rd_data     (ps2_fifo_rd_data),
  .ps2_fifo_rd_valid    (ps2_fifo_rd_valid)
);

assign sid_pot_x = joy_pot_x;
assign sid_pot_y = joy_pot_y;

// ---------------------------------------------------------------------------
// c64_tape_0
// ---------------------------------------------------------------------------

wire tape_act;

c64_tape c64_tape_0 (
  .clk                  (clk),
  .reset                (cpu_reset),
  .phi2_l               (vic_phi2_l),
  .tap_fifo_rd_data     (tap_fifo_rd_data),
  .tap_fifo_rd_valid    (tap_fifo_rd_valid),
  .tap_fifo_rd_en       (tap_fifo_rd_en),
  .tape_play_toggle     (tape_play_toggle),
  .cass_sense_n         (tape_cass_sense_n),
  .cass_read            (cia1_flag_n),
  .cass_motor_n         (tape_cass_motor_n),
  .act                  (tape_act)
);

// ---------------------------------------------------------------------------
// c64_c1541_0
// ---------------------------------------------------------------------------

wire c1541_led;
wire c1541_busy;
wire c1541_mtr;

wire c1541_iec_atn_out;
wire c1541_iec_data_out;
wire c1541_iec_clk_out;
wire c1541_iec_data_in;
wire c1541_iec_clk_in;

wire        c1541_rom_en;
wire [13:0] c1541_rom_addr;
reg   [7:0] c1541_rom_dout;

wire [12:0] buff_addr;
reg   [7:0] buff_dout;
wire  [7:0] buff_din;
wire        buff_we;
wire        buff_en;

c64_c1541 #(
  .EXTERNAL_ROM(C1541_EXTERNAL_ROM)
) c64_c1541_0 (
  .clk          (clk),
  .reset        (cpu_reset),
  .img_mounted  (img_mounted),
  .img_readonly (img_readonly),
  .img_size     (img_size),
  .img_id       (img_id),
  .led          (c1541_led),
  .busy         (c1541_busy),
  .mtr          (c1541_mtr),
  .iec_atn_i    (c1541_iec_atn_out),
  .iec_data_i   (c1541_iec_data_out),
  .iec_clk_i    (c1541_iec_clk_out),
  .iec_data_o   (c1541_iec_data_in),
  .iec_clk_o    (c1541_iec_clk_in),
  .block_lba    (block_lba),
  .block_cnt    (block_cnt),
  .block_rd     (block_rd),
  .block_wr     (block_wr),
  .block_ack    (block_ack),
  .buff_addr    (buff_addr),
  .buff_dout    (buff_dout),
  .buff_din     (buff_din),
  .buff_we      (buff_we),
  .buff_en      (buff_en),
  .ext_rom_en   (c1541_rom_en),
  .ext_rom_addr (c1541_rom_addr),
  .ext_rom_dout (c1541_rom_dout)
);

assign drive_rom_en   = c1541_rom_en;
assign drive_rom_addr = c1541_rom_addr[13:2];

always @(*) begin
  case (c1541_rom_addr[1:0])
    2'b00: begin
      c1541_rom_dout = drive_rom_dout[7:0];
    end
    2'b01: begin
      c1541_rom_dout = drive_rom_dout[15:8];
    end
    2'b10: begin
      c1541_rom_dout = drive_rom_dout[23:16];
    end
    2'b11: begin
      c1541_rom_dout = drive_rom_dout[31:24];
    end
  endcase
end

assign drive_shmem_en   = buff_en;
assign drive_shmem_addr = buff_addr[12:2];
assign drive_shmem_din  = {buff_din, buff_din, buff_din, buff_din};

always @(*) begin
  drive_shmem_we = 4'b0000;

  case (buff_addr[1:0])
    2'b00: begin
      buff_dout = drive_shmem_dout[7:0];
      drive_shmem_we[0] = buff_we;
    end
    2'b01: begin
      buff_dout = drive_shmem_dout[15:8];
      drive_shmem_we[1] = buff_we;
    end
    2'b10: begin
      buff_dout = drive_shmem_dout[23:16];
      drive_shmem_we[2] = buff_we;
    end
    2'b11: begin
      buff_dout = drive_shmem_dout[31:24];
      drive_shmem_we[3] = buff_we;
    end
  endcase
end

// ---------------------------------------------------------------------------
// usb_hid_host_dual_0
// ---------------------------------------------------------------------------

wire [1:0] usb_dm_i_bus;
wire [1:0] usb_dp_i_bus;
wire [1:0] usb_dm_o_bus;
wire [1:0] usb_dp_o_bus;
wire [1:0] usb_oe_bus;

wire [1:0] usb_connected;

assign usb_pullup_dp_0 = 1'b0;
assign usb_pullup_dn_0 = 1'b0;
assign usb_pullup_dp_1 = 1'b0;
assign usb_pullup_dn_1 = 1'b0;

assign usb_dm_i_bus = {usb_dn_1, usb_dn_0};
assign usb_dp_i_bus = {usb_dp_1, usb_dp_0};

assign usb_dn_0 = usb_oe_bus[0] ? usb_dm_o_bus[0] : 1'bz;
assign usb_dp_0 = usb_oe_bus[0] ? usb_dp_o_bus[0] : 1'bz;
assign usb_dn_1 = usb_oe_bus[1] ? usb_dm_o_bus[1] : 1'bz;
assign usb_dp_1 = usb_oe_bus[1] ? usb_dp_o_bus[1] : 1'bz;

usb_hid_host_dual usb_hid_host_dual_0 (
  .clk           (clk),
  .reset         (cpu_reset),
  .usb_clk       (usb_clk),
  .usb_rst       (usb_rst),
  .usb_dm_i      (usb_dm_i_bus),
  .usb_dp_i      (usb_dp_i_bus),
  .usb_dm_o      (usb_dm_o_bus),
  .usb_dp_o      (usb_dp_o_bus),
  .usb_oe        (usb_oe_bus),
  .connerr_0     (),
  .connerr_1     (),
  .connected_0   (usb_connected[0]),
  .connected_1   (usb_connected[1]),
  .game_u_0      (joy_a[0]),
  .game_d_0      (joy_a[1]),
  .game_l_0      (joy_a[2]),
  .game_r_0      (joy_a[3]),
  .game_a_0      (joy_a[4]),
  .game_b_0      (joy_a[5]),
  .game_x_0      (joy_a[6]),
  .game_y_0      (joy_a[7]),
  .game_sel_0    (joy_a[8]),
  .game_sta_0    (joy_a[9]),
  .game_u_1      (joy_b[0]),
  .game_d_1      (joy_b[1]),
  .game_l_1      (joy_b[2]),
  .game_r_1      (joy_b[3]),
  .game_a_1      (joy_b[4]),
  .game_b_1      (joy_b[5]),
  .game_x_1      (joy_b[6]),
  .game_y_1      (joy_b[7]),
  .game_sel_1    (joy_b[8]),
  .game_sta_1    (joy_b[9]),
  .key_report    (hid_key_report),
  .key_modifiers (hid_key_modifiers),
  .key_0         (hid_key_0),
  .key_1         (hid_key_1),
  .key_2         (hid_key_2),
  .key_3         (hid_key_3),
  .mouse_report  (),
  .mouse_btn     (),
  .mouse_dx      (),
  .mouse_dy      ()
);

assign hid_key_report_out = hid_key_report && (flags[6] || hid_key_alt) &&
  (hid_key_1 == 0 && hid_key_2 == 0 && hid_key_3 == 0);

assign hid_key_modifiers_out = hid_key_modifiers;
assign hid_key_alt           = |(hid_key_modifiers & 8'h44);
assign hid_key_0_out         = hid_key_0;

// ---------------------------------------------------------------------------
// c64_action_replay_0
// ---------------------------------------------------------------------------

wire [14:0] rom_ar_addr;
wire        rom_ar_enable;
reg         rom_ar_ready;
reg  [7:0]  rom_ar_dout;
wire        rom_ar_select;

wire        ar_nmi;
wire        ar_irq;
wire        ar_freeze;

wire        sdram_pending;

c64_action_replay c64_action_replay_0 (
  .clk           (clk),
  .reset         (cpu_reset),
  .phi2_p        (vic_phi2_p && !vic_stall),
  .phi2_h        (vic_phi2_h),
  .phi2_n        (vic_phi2_n && !vic_stall),
  .addr          (cart_addr),
  .din           (cart_din),
  .dout          (cart_dout),
  .we            (cart_we),
  .ba            (cart_ba),
  .exrom         (cart_exrom),
  .game          (cart_game),
  .freeze        (ar_freeze),
  .roml          (cart_roml),
  .romh          (cart_romh),
  .io1_cen       (cart_io1_cen),
  .io2_cen       (cart_io2_cen),
  .nmi           (ar_nmi),
  .irq           (ar_irq),
  .sdram_pending (sdram_pending),
  .rom_addr      (rom_ar_addr),
  .rom_enable    (rom_ar_enable),
  .rom_ready     (rom_ar_ready),
  .rom_dout      (rom_ar_dout),
  .rom_select    (rom_ar_select)
);

// ---------------------------------------------------------------------------
// c64_bus_arbiter_0
// ---------------------------------------------------------------------------

wire [9:0]  ram_color_addr;
wire [3:0]  ram_color_din;
wire [3:0]  ram_color_dout;
wire        ram_color_select;
wire        ram_color_we;

wire [15:0] ram_addr;
reg  [7:0]  ram_dout;
wire [7:0]  ram_din;
wire        ram_we;
wire        ram_enable;
reg         ram_ready;
wire        ram_select;

wire [12:0] rom_basic_addr;
wire        rom_basic_enable;
reg         rom_basic_ready;
reg  [7:0]  rom_basic_dout;
wire        rom_basic_select;

wire [12:0] rom_kernal_addr;
wire        rom_kernal_enable;
reg         rom_kernal_ready;
reg  [7:0]  rom_kernal_dout;
wire        rom_kernal_select;

wire [11:0] rom_char_addr;
wire        rom_char_enable;
reg         rom_char_ready;
reg  [7:0]  rom_char_dout;
wire        rom_char_select;

wire        cart_game;
wire        cart_exrom;
wire        cart_io1_cen;
wire        cart_io2_cen;
wire        cart_roml;
wire        cart_romh;
wire  [7:0] cart_dout;
wire  [7:0] cart_din;
wire        cart_ba;
wire        cart_we;
wire [15:0] cart_addr;
reg         cart_present;

wire        roml_select;
wire        romh_select;

wire        vic_game;
wire        vic_exrom;
wire        vic_loram;
wire        vic_hiram;
wire        vic_charen;

c64_bus_arbiter c64_bus_arbiter_0 (
  .vic_clk_dot4x  (clk),
  .vic_reset      (vic_reset_req || rst),
  .vic_phi2_n     (vic_phi2_n && !vic_stall),
  .vic_ado        (vic_ado),
  .vic_ras        (vic_ras),
  .vic_cas        (vic_cas),
  .vic_cas_glitch (vic_cas_glitch),
  .vic_write_db   (vic_write_db),
  .vic_write_ab   (vic_write_ab),
  .vic_aec        (vic_aec),
  .vic_ba         (vic_ba),
  .vic_we         (vic_we),
  .vic_adi        (vic_adi),
  .vic_dbi        (vic_dbi),
  .vic_dbo        (vic_dbo),
  .vic_dbh        (vic_dbh),
  .vic_cen        (vic_cen),

  .cpu_reset (cpu_reset),
  .cpu_addr  (cpu_addr),
  .cpu_din   (cpu_din),
  .cpu_dout  (cpu_dout),
  .cpu_pout  (cpu_pout),
  .cpu_pin   (cpu_pin),
  .cpu_we    (cpu_we),
  .cpu_pc    (cpu_pc),
  .cpu_irq   (cpu_irq),
  .cpu_nmi   (cpu_nmi),

  .ram_color_addr   (ram_color_addr),
  .ram_color_din    (ram_color_din),
  .ram_color_dout   (ram_color_dout),
  .ram_color_select (ram_color_select),
  .ram_color_we     (ram_color_we),

  .ram_addr   (ram_addr),
  .ram_dout   (ram_dout),
  .ram_din    (ram_din),
  .ram_we     (ram_we),
  .ram_enable (ram_enable),
  .ram_ready  (ram_ready),
  .ram_select (ram_select),

  .rom_basic_addr   (rom_basic_addr),
  .rom_basic_enable (rom_basic_enable),
  .rom_basic_ready  (rom_basic_ready),
  .rom_basic_dout   (rom_basic_dout),
  .rom_basic_select (rom_basic_select),

  .rom_kernal_addr   (rom_kernal_addr),
  .rom_kernal_enable (rom_kernal_enable),
  .rom_kernal_ready  (rom_kernal_ready),
  .rom_kernal_dout   (rom_kernal_dout),
  .rom_kernal_select (rom_kernal_select),

  .rom_char_addr   (rom_char_addr),
  .rom_char_enable (rom_char_enable),
  .rom_char_ready  (rom_char_ready),
  .rom_char_dout   (rom_char_dout),
  .rom_char_select (rom_char_select),

  .sid_addr (sid_addr),
  .sid_dout (sid_dout),
  .sid_din  (sid_din),
  .sid_cen  (sid_cen),
  .sid_we   (sid_we),

  .cia1_addr (cia1_addr),
  .cia1_dout (cia1_dout),
  .cia1_din  (cia1_din),
  .cia1_cen  (cia1_cen),
  .cia1_we   (cia1_we),

  .cia2_addr   (cia2_addr),
  .cia2_dout   (cia2_dout),
  .cia2_din    (cia2_din),
  .cia2_cen    (cia2_cen),
  .cia2_we     (cia2_we),
  .cia2_pa_in  (cia2_pa_in),
  .cia2_pa_out (cia2_pa_out),
  .cia2_ddra   (cia2_ddra),

  .cart_present (cart_present),
  .cart_game    (cart_game),
  .cart_exrom   (cart_exrom),
  .cart_io1_cen (cart_io1_cen),
  .cart_io2_cen (cart_io2_cen),
  .cart_roml    (cart_roml),
  .cart_romh    (cart_romh),
  .cart_dout    (cart_dout),
  .cart_din     (cart_din),
  .cart_ba      (cart_ba),
  .cart_we      (cart_we),
  .cart_addr    (cart_addr),

  .roml_select (roml_select),
  .romh_select (romh_select),

  .cass_sense_n (tape_cass_sense_n),
  .cass_motor_n (tape_cass_motor_n),

  .game   (vic_game),
  .exrom  (vic_exrom),
  .loram  (vic_loram),
  .hiram  (vic_hiram),
  .charen (vic_charen),

  .sdram_pending (sdram_pending),

  .iec_data_out (iec_data_out),
  .iec_clk_out  (iec_clk_out),
  .iec_atn_out  (iec_atn_out),
  .iec_data_in  (iec_data_in),
  .iec_clk_in   (iec_clk_in),
  .iec_atn_in   (iec_atn_in),

  .c1541_iec_atn_out  (c1541_iec_atn_out),
  .c1541_iec_data_out (c1541_iec_data_out),
  .c1541_iec_clk_out  (c1541_iec_clk_out),
  .c1541_iec_data_in  (c1541_iec_data_in),
  .c1541_iec_clk_in   (c1541_iec_clk_in),

  .va_delay              (flags[5]),
  .iec_master_disconnect (flags[13])
);

always @(posedge clk) begin
  if (cpu_reset)
    cart_present <= flags[12];
end

// ---------------------------------------------------------------------------
// c64_ram_color_0
// ---------------------------------------------------------------------------

c64_ram #(
  .AW(10),
  .DW(4)
) c64_ram_color_0 (
  .clk    (clk),
  .enable (ram_color_select && sdram_pending),  // not needed but saves power
  .we     (ram_color_we),
  .addr   (ram_color_addr),
  .din    (ram_color_din),
  .dout   (ram_color_dout)
);

// ---------------------------------------------------------------------------
// Reset logic
// ---------------------------------------------------------------------------

reg cpu_reset_i = 1'b1;
reg cpu_reset_pending = 1'b1;

always @(posedge clk) begin
  if (rst)
    cpu_reset_pending <= 1'b1;
  else if (cpu_reset_req)
    cpu_reset_pending <= 1'b1;
  else if (vic_phi2_n)
    cpu_reset_pending <= 1'b0;
end

always @(posedge clk) begin
  if (rst)
    cpu_reset_i <= 1'b1;
  else if (vic_phi2_n)
    cpu_reset_i <= cpu_reset_pending;
end

assign cpu_reset = cpu_reset_i || vic_cpu_reset || rst;

// ---------------------------------------------------------------------------
// IRQ / NMI logic
// ---------------------------------------------------------------------------

assign cpu_irq = cia1_irq | vic_irq | (ar_irq && cart_present);
assign cpu_nmi = cia2_irq | kbd_restore_toggle | (ar_nmi && cart_present);

// ---------------------------------------------------------------------------
// Action Replay freeze
// ---------------------------------------------------------------------------

assign ar_freeze = kbd_freeze_pulse;

// ---------------------------------------------------------------------------
// RAM / ROM to SDRAM mapping
// ---------------------------------------------------------------------------

reg [18:0] mem_addr;
reg        mem_raddr_lsb;

always @(*) begin
  ram_ready        = 0;
  rom_char_ready   = 0;
  rom_kernal_ready = 0;
  rom_basic_ready  = 0;
  rom_ar_ready     = 0;

  mem_addr = {3'b000, 16'b0};

  mem_cmd_valid = 0;
  mem_cmd_we    = 0;

  mem_cmd_we    = ram_we && ram_select;
  mem_wdata     = {ram_din, ram_din};
  mem_wdata_we  = ram_addr[0] ? 2'b10 : 2'b01;

  if (ram_select) begin
    mem_cmd_valid = ram_enable;
    mem_addr      = {3'b000, ram_addr};
    ram_ready     = mem_cmd_ready;

  end else if (rom_char_select) begin
    mem_cmd_valid  = rom_char_enable;
    mem_addr       = {3'b001, 4'b0, rom_char_addr};
    rom_char_ready = mem_cmd_ready;

  end else if (rom_kernal_select) begin
    mem_cmd_valid    = rom_kernal_enable;
    mem_addr         = {3'b010, 3'b0, rom_kernal_addr};
    rom_kernal_ready = mem_cmd_ready;

  end else if (rom_basic_select) begin
    mem_cmd_valid   = rom_basic_enable;
    mem_addr        = {3'b011, 3'b0, rom_basic_addr};
    rom_basic_ready = mem_cmd_ready;

  end else if (rom_ar_select) begin
    mem_cmd_valid = rom_ar_enable;
    mem_addr      = {3'b100, 1'b0, rom_ar_addr};
    rom_ar_ready  = mem_cmd_ready;
  end

  mem_cmd_addr = {SDRAM_BANK, 4'b0, mem_addr[18:1]};

  ram_dout        = mem_raddr_lsb ? mem_rdata[15:8] : mem_rdata[7:0];
  rom_char_dout   = mem_raddr_lsb ? mem_rdata[15:8] : mem_rdata[7:0];
  rom_kernal_dout = mem_raddr_lsb ? mem_rdata[15:8] : mem_rdata[7:0];
  rom_basic_dout  = mem_raddr_lsb ? mem_rdata[15:8] : mem_rdata[7:0];
  rom_ar_dout     = mem_raddr_lsb ? mem_rdata[15:8] : mem_rdata[7:0];
end

wire mem_rdata_valid_combined;

reg mem_rdata_valid_r = 1'b1;

always @(posedge clk) begin
  if (cpu_reset)
    mem_rdata_valid_r <= 1'b1;
  else if (mem_rdata_valid)
    mem_rdata_valid_r <= 1'b1;
  else if (mem_cmd_valid && mem_cmd_ready && !mem_cmd_we) begin
    mem_rdata_valid_r <= 0;
    mem_raddr_lsb     <= mem_addr[0];
  end
end

assign mem_rdata_valid_combined = mem_rdata_valid || mem_rdata_valid_r;

assign vic_stall = !mem_rdata_valid_combined && (vic_phi2_n || vic_phi2_p);

// ---------------------------------------------------------------------------
// Other
// ---------------------------------------------------------------------------

reg [2:0] led_dim_counter;
reg [4:0] leds_r;

always @(posedge clk) begin
  if (rst) begin
    led_dim_counter <= 0;
    leds_r          <= 5'b0;

  end else if (vic_phi2_p) begin
    led_dim_counter <= led_dim_counter + 1;
    leds_r          <= 5'b0;

    if (led_dim_counter == 0)
      leds_r <= {usb_connected[0] || usb_connected[1], tape_act,
        c1541_led, vic_stall || cpu_paused, !cpu_reset && !vic_reset_req};
  end
end

always @(posedge clk) begin
  if (rst)
    cpu_paused <= 1'b0;
  else if (vic_phi2_n && !cpu_we)
    cpu_paused <= cpu_pause_req;
end

assign leds = leds_r;

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
