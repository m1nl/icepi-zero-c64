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
module c64_bus_arbiter (
  input  wire        vic_clk_dot4x,
  input  wire        vic_phi2_n,
  input  wire        vic_reset,
  input  wire [11:0] vic_ado,
  input  wire        vic_ras,
  input  wire        vic_cas,
  input  wire        vic_cas_glitch,
  input  wire        vic_write_db,
  input  wire        vic_write_ab,
  input  wire        vic_aec,
  input  wire        vic_ba,
  output reg         vic_we,
  output reg  [5:0]  vic_adi,
  output reg  [7:0]  vic_dbi,
  input  wire [7:0]  vic_dbo,
  output reg  [3:0]  vic_dbh,
  output reg         vic_cen,

  input  wire        cpu_reset,
  input  wire [15:0] cpu_addr,
  output reg  [7:0]  cpu_din,
  input  wire [7:0]  cpu_dout,
  input  wire [5:0]  cpu_pout,
  output reg  [5:0]  cpu_pin,
  input  wire        cpu_we,
  input  wire [15:0] cpu_pc,
  input wire         cpu_irq,
  input wire         cpu_nmi,

  output reg  [9:0]  ram_color_addr,
  output reg  [3:0]  ram_color_din,
  input  wire [3:0]  ram_color_dout,
  output reg         ram_color_select,
  output reg         ram_color_we,

  output reg  [15:0] ram_addr,
  input  wire [7:0]  ram_dout,
  output reg  [7:0]  ram_din,
  output reg         ram_we,
  output reg         ram_enable,
  input  wire        ram_ready,
  output reg         ram_select,

  output reg  [12:0] rom_basic_addr,
  output reg         rom_basic_enable,
  input  wire        rom_basic_ready,
  input  wire [7:0]  rom_basic_dout,
  output reg         rom_basic_select,

  output reg  [12:0] rom_kernal_addr,
  output reg         rom_kernal_enable,
  input  wire        rom_kernal_ready,
  input  wire [7:0]  rom_kernal_dout,
  output reg         rom_kernal_select,

  output reg  [11:0] rom_char_addr,
  output reg         rom_char_enable,
  input  wire        rom_char_ready,
  input  wire [7:0]  rom_char_dout,
  output reg         rom_char_select,

  output reg  [8:0]  sid_addr,
  input  wire [7:0]  sid_dout,
  output reg  [7:0]  sid_din,
  output reg         sid_cen,
  output reg         sid_we,

  output reg  [3:0]  cia1_addr,
  input  wire [7:0]  cia1_dout,
  output reg  [7:0]  cia1_din,
  output reg         cia1_cen,
  output reg         cia1_we,

  output reg  [3:0]  cia2_addr,
  input  wire [7:0]  cia2_dout,
  output reg  [7:0]  cia2_din,
  output reg         cia2_cen,
  output reg         cia2_we,
  output wire [7:0]  cia2_pa_in,
  input  wire [7:0]  cia2_pa_out,
  input  wire [7:0]  cia2_ddra,

  input  wire        cart_present,
  input  wire        cart_game,
  input  wire        cart_exrom,
  output reg         cart_io1_cen,
  output reg         cart_io2_cen,
  output wire        cart_roml,
  output wire        cart_romh,
  input  wire [7:0]  cart_dout,
  output reg  [7:0]  cart_din,
  output wire        cart_ba,
  output reg         cart_we,
  output reg  [15:0] cart_addr,

  output reg         roml_select,
  output reg         romh_select,

  input  wire        cass_sense_n,
  output reg         cass_motor_n,

  output wire        game,
  output wire        exrom,
  output wire        loram,
  output wire        hiram,
  output wire        charen,

  output wire        sdram_pending,

  output wire        iec_data_out,
  output wire        iec_clk_out,
  output wire        iec_atn_out,

  input  wire        iec_data_in,
  input  wire        iec_clk_in,
  input  wire        iec_atn_in,

  output wire        c1541_iec_atn_out,
  output wire        c1541_iec_data_out,
  output wire        c1541_iec_clk_out,

  input  wire        c1541_iec_data_in,
  input  wire        c1541_iec_clk_in,

  input  wire        va_delay,
  input  wire        iec_master_disconnect
);

wire [11:0] vic_addr;

wire va15, va14;

wire vic_select_rom_char;
wire vic_select_romh;

reg ras_locked;
reg cas_locked;

reg [15:0] vic_ram_addr;
reg  [7:0] vic_addr_i;

reg  [1:0] va1514;

assign {va15, va14} = ~(~cia2_ddra[1:0] | cia2_pa_out[1:0]);  // weak pull-up

assign vic_select_rom_char = {va14, vic_ado[5:4]} == 3'b001;
assign vic_select_romh     = vic_ado[5:4] == 2'b11;
assign vic_addr            = vic_ras ? vic_ado : {vic_ado[11:8], vic_addr_i};

assign sdram_pending = !vic_ras && !vic_cas && ras_locked && !cas_locked;

always @(posedge vic_clk_dot4x) begin
  if (cpu_reset || vic_reset) begin
    ram_enable        <= 1'b0;
    rom_basic_enable  <= 1'b0;
    rom_kernal_enable <= 1'b0;
    rom_char_enable   <= 1'b0;

    va1514 <= 2'b0;

    ras_locked <= 1'b0;
    cas_locked <= 1'b0;

  end else begin
    // handle U26 flip-flop
    if (vic_ras && !vic_aec)
      vic_addr_i <= vic_ado[7:0];

    // this simulates delayed change for U14 output
    if (!vic_cas && !vic_aec)
      va1514 <= ~(~cia2_ddra[1:0] | cia2_pa_out[1:0]);  // weak pull-up

    // clear registered enable signals when ready
    if (ram_ready)
      ram_enable <= 1'b0;

    if (rom_basic_ready)
      rom_basic_enable <= 1'b0;

    if (rom_kernal_ready)
      rom_kernal_enable <= 1'b0;

    if (rom_char_ready)
      rom_char_enable <= 1'b0;

    // clear ras_locked once RAS is asserted
    if (vic_ras)
      ras_locked <= 1'b0;

    // clear cas_locked once CAS is asserted or SDRAM is not selected (CASRAM)
    if (vic_cas)
      cas_locked <= 1'b0;

    // lock row address
    if (!vic_ras && !ras_locked) begin
      ras_locked <= 1'b1;

      if (!vic_aec)
        vic_ram_addr[7:0] <= vic_ado[7:0];
    end

    // lock column address and strobe
    if (sdram_pending) begin
      cas_locked <= 1'b1;

      ram_enable        <= ram_select;
      rom_basic_enable  <= rom_basic_select;
      rom_kernal_enable <= rom_kernal_select;
      rom_char_enable   <= rom_char_select;

      if (!vic_aec) begin
        vic_ram_addr[13:8] <= vic_ado[5:0];

        // glitch happens when bits going through U14 flip
        vic_ram_addr[15:14] <= va_delay && ((va1514 ^ {va15, va14}) == 2'b11) && (va15 != va14) ? 2'b11 : {va15, va14};
      end
    end
  end
end

// serial port

wire cia2_iec_data_in;
wire cia2_iec_clk_in;
wire cia2_iec_atn_in;

wire cia2_iec_data_out;
wire cia2_iec_clk_out;

// CIA2 has pull-up, when PA is configured as input and inverter pulls line low
assign cia2_iec_data_in = (cia2_ddra[5] ? !cia2_pa_out[5] : 1'b0) || iec_master_disconnect;
assign cia2_iec_clk_in  = (cia2_ddra[4] ? !cia2_pa_out[4] : 1'b0) || iec_master_disconnect;
assign cia2_iec_atn_in  = (cia2_ddra[3] ? !cia2_pa_out[3] : 1'b0) || iec_master_disconnect;

assign iec_data_out = c1541_iec_data_in && cia2_iec_data_in;
assign iec_clk_out  = c1541_iec_clk_in && cia2_iec_clk_in;
assign iec_atn_out  = cia2_iec_atn_in;

reg iec_data;
reg iec_clk;
reg iec_atn;

// break long combinatorial logic; sync to FPGA domain
always @(posedge vic_clk_dot4x) begin
  iec_data <= iec_data_in;
  iec_clk  <= iec_clk_in;
  iec_atn  <= iec_atn_in;
end

assign c1541_iec_data_out = iec_data;
assign c1541_iec_clk_out  = iec_clk;
assign c1541_iec_atn_out  = iec_atn;

assign cia2_iec_data_out = iec_data || iec_master_disconnect;
assign cia2_iec_clk_out  = iec_clk || iec_master_disconnect;

assign cia2_pa_in = {cia2_iec_data_out, cia2_iec_clk_out,
  (~cia2_ddra[5:3] | cia2_pa_out[5:3]), (~cia2_ddra[2:0] | cia2_pa_out[2:0])};

// bus logic

reg [7:0] vic_last_bus;
reg [7:0] cpu_last_bus;
reg [7:0] last_bus;

reg [7:0] bus;

reg io_enable;

always @(posedge vic_clk_dot4x)
  last_bus <= bus;

always @(*) begin
  bus = last_bus;

  if (cpu_reset || vic_reset) begin
    /* no-op */
  end else if (cpu_we && vic_aec)
    bus = cpu_dout;
  else if (rom_basic_select)
    bus = rom_basic_dout;
  else if (rom_kernal_select)
    bus = rom_kernal_dout;
  else if (rom_char_select)
    bus = rom_char_dout;
  else if (roml_select && cart_present)
    bus = cart_dout;
  else if (romh_select && cart_present)
    bus = cart_dout;
  else if (ram_color_select && vic_aec)
    bus[3:0] = ram_color_dout;
  else if (ram_select)
    bus = ram_dout;
  else if (io_enable) begin
    if (vic_write_db)
      bus = vic_dbo;
    else if (!sid_cen)
      bus = sid_dout;
    else if (!cia1_cen)
      bus = cia1_dout;
    else if (!cia2_cen)
      bus = cia2_dout;
    else if ((!cart_io1_cen || !cart_io2_cen) && cart_present)
      bus = cart_dout;
  end
end

assign game  = cart_game  || !cart_present;
assign exrom = cart_exrom || !cart_present;

assign loram  = cpu_pout[0];
assign hiram  = cpu_pout[1];
assign charen = cpu_pout[2];

wire [3:0] cpu_addr_msn;
wire [3:0] cpu_addr_io;

assign cpu_addr_msn = cpu_addr[15:12];
assign cpu_addr_io  = cpu_addr[11:8];

assign cart_roml = !roml_select || !cart_present;
assign cart_romh = !romh_select || !cart_present;

assign cart_ba = vic_ba && cart_present;

// address decoding

always @(*) begin
  cpu_din  = bus;
  vic_dbi  = bus;
  vic_dbh  = bus[3:0];
  sid_din  = cpu_dout;  // only CPU writes to SID, helps with timing
  cia1_din = cpu_dout;  // only CPU writes to CIA, helps with timing
  cia2_din = cpu_dout;  // only CPU writes to CIA, helps with timing
  cart_din = bus;

  vic_adi   = cpu_addr[5:0];
  sid_addr  = cpu_addr[8:0];
  cia1_addr = cpu_addr[3:0];
  cia2_addr = cpu_addr[3:0];

  io_enable = 1'b0;

  vic_we  = 1'b0;
  sid_we  = 1'b0;
  cia1_we = 1'b0;
  cia2_we = 1'b0;

  vic_cen  = 1'b1;
  sid_cen  = 1'b1;
  cia1_cen = 1'b1;
  cia2_cen = 1'b1;

  cart_io1_cen = 1'b1;
  cart_io2_cen = 1'b1;

  ram_color_din = bus[3:0];
  ram_din       = cpu_dout;  // only CPU writes to RAM, helps with timing

  rom_basic_addr  = cpu_addr[12:0];
  rom_kernal_addr = cpu_addr[12:0];
  rom_char_addr   = cpu_addr[11:0];
  ram_color_addr  = cpu_addr[9:0];
  ram_addr        = cpu_addr;
  cart_addr       = cpu_addr;

  ram_color_we = 1'b0;
  ram_we       = 1'b0;
  cart_we      = 1'b0;

  rom_basic_select  = 1'b0;
  rom_kernal_select = 1'b0;
  rom_char_select   = 1'b0;
  roml_select       = 1'b0;
  romh_select       = 1'b0;
  ram_color_select  = 1'b0;
  ram_select        = 1'b0;

  cass_motor_n = cpu_pout[5];
  cpu_pin      = {1'b1, cass_sense_n, 4'b1111};

  if (cpu_reset || vic_reset) begin
    /* no-op */
  end else if (!vic_write_ab) begin
    vic_we  = cpu_we;
    sid_we  = cpu_we;
    cia1_we = cpu_we;
    cia2_we = cpu_we;

    ram_color_we = !vic_cas && cpu_we;  // mimic real PLA behaviour
    ram_we       = cpu_we;
    cart_we      = cpu_we && cart_present;

    casez ({game, exrom, charen, hiram, loram})
      5'b10111,  /* fall-through */
      5'b11111,  /* fall-through */
      5'b00111: begin
        if (cpu_we) begin
          if (cpu_addr_msn == 4'hd) begin
            io_enable = 1'b1;
          end else begin
            ram_select = 1'b1;
          end
        end else if (cpu_addr_msn == 4'hf || cpu_addr_msn == 4'he) begin
          rom_kernal_select = 1'b1;
        end else if (cpu_addr_msn == 4'hd) begin
          if (vic_ba) begin
            io_enable = 1'b1;
          end else begin
            ram_select = 1'b1;
          end
        end else if ((cpu_addr_msn == 4'hb || cpu_addr_msn == 4'ha) && game) begin
          rom_basic_select = 1'b1;
        end else if ((cpu_addr_msn == 4'hb || cpu_addr_msn == 4'ha) && !game) begin
          romh_select = 1'b1;
        end else if ((cpu_addr_msn == 4'h9 || cpu_addr_msn == 4'h8) && !exrom) begin
          roml_select = 1'b1;
        end else begin
          ram_select = 1'b1;
        end
      end
      5'b10011,  /* fall-through */
      5'b11011,  /* fall-through */
      5'b00011: begin
        if (cpu_we) begin
          ram_select = 1'b1;
        end else if (cpu_addr_msn == 4'hf || cpu_addr_msn == 4'he) begin
          rom_kernal_select = 1'b1;
        end else if (cpu_addr_msn == 4'hd) begin
          rom_char_select = 1'b1;
        end else if ((cpu_addr_msn == 4'hb || cpu_addr_msn == 4'ha) && game) begin
          rom_basic_select = 1'b1;
        end else if ((cpu_addr_msn == 4'hb || cpu_addr_msn == 4'ha) && !game) begin
          romh_select = 1'b1;
        end else if ((cpu_addr_msn == 4'h9 || cpu_addr_msn == 4'h8) && !exrom) begin
          roml_select = 1'b1;
        end else begin
          ram_select = 1'b1;
        end
      end
      5'b00110: begin
        if (cpu_we) begin
          if (cpu_addr_msn == 4'hd) begin
            io_enable = 1'b1;
          end else begin
            ram_select = 1'b1;
          end
        end else if (cpu_addr_msn == 4'hf || cpu_addr_msn == 4'he) begin
          rom_kernal_select = 1'b1;
        end else if (cpu_addr_msn == 4'hd) begin
          if (vic_ba) begin
            io_enable = 1'b1;
          end else begin
            ram_select = 1'b1;
          end
        end else if (cpu_addr_msn == 4'hb || cpu_addr_msn == 4'ha) begin
          romh_select = 1'b1;
        end else begin
          ram_select = 1'b1;
        end
      end
      5'b00010: begin
        if (cpu_we) begin
          ram_select = 1'b1;
        end else if (cpu_addr_msn == 4'hf || cpu_addr_msn == 4'he) begin
          rom_kernal_select = 1'b1;
        end else if (cpu_addr_msn == 4'hd) begin
          rom_char_select = 1'b1;
        end else if (cpu_addr_msn == 4'hb || cpu_addr_msn == 4'ha) begin
          romh_select = 1'b1;
        end else begin
          ram_select = 1'b1;
        end
      end
      5'b1z101,  /* fall-through */
      5'b00101: begin
        if (cpu_we) begin
          if (cpu_addr_msn == 4'hd) begin
            io_enable = 1'b1;
          end else begin
            ram_select = 1'b1;
          end
        end else if (cpu_addr_msn == 4'hd) begin
          if (vic_ba) begin
            io_enable = 1'b1;
          end else begin
            ram_select = 1'b1;
          end
        end else begin
          ram_select = 1'b1;
        end
      end
      5'b1z001: begin
        if (cpu_we) begin
          ram_select = 1'b1;
        end else if (cpu_addr_msn == 4'hd) begin
          rom_char_select = 1'b1;
        end else begin
          ram_select = 1'b1;
        end
      end
      5'b1z110: begin
        if (cpu_we) begin
          if (cpu_addr_msn == 4'hd) begin
            io_enable = 1'b1;
          end else begin
            ram_select = 1'b1;
          end
        end else if (cpu_addr_msn == 4'hf || cpu_addr_msn == 4'he) begin
          rom_kernal_select = 1'b1;
        end else if (cpu_addr_msn == 4'hd) begin
          if (vic_ba) begin
            io_enable = 1'b1;
          end else begin
            ram_select = 1'b1;
          end
        end else begin
          ram_select = 1'b1;
        end
      end
      5'b1z010: begin
        if (cpu_we) begin
          ram_select = 1'b1;
        end else if (cpu_addr_msn == 4'hf || cpu_addr_msn == 4'he) begin
          rom_kernal_select = 1'b1;
        end else if (cpu_addr_msn == 4'hd) begin
          rom_char_select = 1'b1;
        end else begin
          ram_select = 1'b1;
        end
      end
      5'b1zz00,  /* fall-through */
      5'b00z00,  /* fall-through */
      5'b00001: begin
        ram_select = 1'b1;
      end
      5'b01zzz: begin
        if (cpu_we) begin
          if (cpu_addr_msn == 4'hf || cpu_addr_msn == 4'he) begin
            romh_select = 1'b1;
          end else if (cpu_addr_msn == 4'hd) begin
            io_enable = 1'b1;
          end else if (cpu_addr_msn == 4'h9 || cpu_addr_msn == 4'h8) begin
            roml_select = 1'b1;
          end else if (cpu_addr_msn == 4'h0) begin
            ram_select = 1'b1;
          end
        end else if (cpu_addr_msn == 4'hf || cpu_addr_msn == 4'he) begin
          romh_select = 1'b1;
        end else if (cpu_addr_msn == 4'hd) begin
          if (vic_ba) begin
            io_enable = 1'b1;
          end else begin
            ram_select = 1'b1;
          end
        end else if (cpu_addr_msn == 4'h9 || cpu_addr_msn == 4'h8) begin
          roml_select = 1'b1;
        end else if (cpu_addr_msn == 4'h0) begin
          ram_select = 1'b1;
        end
      end
      default: begin
        /* no-op */
      end
    endcase

    if (io_enable) begin
      case (cpu_addr_io)
        4'h0,  /* fall-through */
        4'h1,  /* fall-through */
        4'h2,  /* fall-through */
        4'h3: begin
          vic_cen = 1'b0;
        end
        4'h4,  /* fall-through */
        4'h5,  /* fall-through */
        4'h6,  /* fall-through */
        4'h7: begin
          sid_cen = 1'b0;
        end
        4'h8,  /* fall-through */
        4'h9,  /* fall-through */
        4'ha,  /* fall-through */
        4'hb: begin
          ram_color_select = 1'b1;
        end
        4'hc: begin
          cia1_cen = 1'b0;
        end
        4'hd: begin
          cia2_cen = 1'b0;
        end
        4'he: begin
          if (cart_present)
            cart_io1_cen = 1'b0;
        end
        4'hf: begin
          if (cart_present)
            cart_io2_cen = 1'b0;
        end
        default: ;  /* read last bus state */
      endcase
    end

  end else begin
    vic_dbh = ram_color_dout;

    rom_char_addr  = vic_addr;
    cart_addr      = {4'b0, vic_addr};
    ram_color_addr = vic_addr[9:0];
    ram_addr       = vic_ram_addr;

    ram_color_select = 1'b1;

    if (!game && exrom) begin
      if (vic_select_romh) begin
        romh_select = 1'b1;
      end else begin
        ram_select = 1'b1;
      end
    end else begin
      if (vic_select_rom_char) begin
        rom_char_select = 1'b1;
      end else begin
        ram_select = 1'b1;
      end
    end
  end
end

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
