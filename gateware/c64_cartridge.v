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
module c64_cartridge (
  input wire clk,
  input wire reset,
  input wire phi2_p,
  input wire phi2_h,
  input wire sdram_pending,

  input wire [15:0] cart_flags,

  input  wire [15:0] addr,
  input  wire  [7:0] din,
  output wire  [7:0] dout,

  input wire we,
  input wire ba,

  output reg exrom,
  output reg game,

  input wire freeze,
  input wire roml,
  input wire romh,
  input wire io1_cen,
  input wire io2_cen,

  output wire nmi,
  output wire irq,

  output wire io2_we_valid,

  output wire [20:0] rom_addr,
  output reg         rom_enable,
  input  wire        rom_ready,
  input  wire [7:0]  rom_dout,
  output wire        rom_select,

  output wire [14:0] ram_addr,
  output reg         ram_enable,
  output wire        ram_we,
  input  wire        ram_ready,
  input  wire [7:0]  ram_dout,
  output wire        ram_select
);

wire [7:0] cart_id;
wire       cart_exrom;
wire       cart_game;

assign {cart_game, cart_exrom, cart_id} = {cart_flags[9], cart_flags[8], cart_flags[7:0]};

reg [7:0] reg_0_init;
reg [7:0] reg_1_init;

reg [7:0] reg_0;
reg [7:0] reg_1;

reg [7:0] bank_lo;
reg [7:0] bank_hi;

wire       io_select;
wire [7:0] io_dout;

wire ar_enable = (cart_id == 8'd1 || cart_id == 8'd36);

wire ar_exrom;
wire ar_game;

wire ar_irq;
wire ar_nmi;

wire ar_io2_we_valid;

wire [7:0] ar_dout;

wire [16:0] ar_rom_addr;
wire        ar_rom_select;

wire [14:0] ar_ram_addr;
wire        ar_ram_we;
wire        ar_ram_select;

always @(*) begin
  reg_0_init = 8'd0;
  reg_1_init = 8'd0;

  exrom = 1'b1;
  game  = 1'b1;

  io2_we_valid = 1'b0;

  bank_lo = 8'd0;
  bank_hi = 8'd1;

  case (cart_id)
    8'd0: begin
      exrom = cart_exrom;
      game  = cart_game;
    end
    8'd1,
    8'd36: begin  // Action Replay, Retro Replay
      exrom = ar_exrom;
      game  = ar_game;

      io2_we_valid = ar_io2_we_valid;
    end
    8'd4: begin  // Simons Basic
      reg_0_init[0] = cart_game;

      exrom = cart_exrom;
      game  = reg_0[0];
    end
    8'd5: begin  // Ocean Type 1
      exrom = cart_exrom;
      game  = cart_game;

      bank_lo = {1'b0, reg_0[5:0], 1'b0};
      bank_hi = {1'b0, reg_0[5:0], 1'b0};
    end
    8'd15: begin  // C64GS 8k
      exrom = cart_exrom;
      game  = cart_game;

      bank_lo = {1'b0, reg_0[5:0], 1'b0};
    end
    8'd17: begin  // Dinamic
       exrom = cart_exrom;
       game  = cart_game;

       bank_lo = {3'b0, reg_0[3:0], 1'b0};
    end
    8'd19: begin  // Magic Desk
      reg_0_init[7] = cart_exrom;

      exrom = reg_0[7];
      game  = cart_game;

      bank_lo = {reg_0[6:0], 1'b0};
    end
    8'd32,
    8'd33: begin  // EasyFlash
      reg_1_init[1] = !cart_exrom;

      exrom = !reg_1[1];
      game  = reg_1[2] ? !reg_1[1] : cart_game;

      io2_we_valid = 1'b1;

      bank_lo = {1'b0, reg_0[5:0], 1'b0};
      bank_hi = {1'b0, reg_0[5:0], 1'b1};
    end
    8'd60: begin  // GMod2
      reg_0_init[6] = cart_exrom;

      exrom = reg_0[6];
      game  = cart_game;

      bank_lo = {1'b0, reg_0[5:0], 1'b0};
    end
    8'd85: begin  // Magic Desk 2
      reg_0_init[7] = cart_exrom && cart_game;

      exrom = reg_0[7];
      game  = reg_0[7];

      bank_lo = {reg_0[6:0], 1'b0};
      bank_hi = {reg_0[6:0], 1'b1};
    end
    default: ;
  endcase
end

always @(posedge clk) begin
  if (reset) begin
    reg_0 <= reg_0_init;
    reg_1 <= reg_1_init;

  end else if (!io1_cen && phi2_h) begin
    case (cart_id)
      8'd4: begin  // Simons Basic
        if (we)
          reg_0 <= reg_0_init;
        else
          reg_0 <= 8'h01;
      end
      8'd15: begin  // C64GS
        if (we)
          reg_0 <= addr[7:0];
        else
          reg_0 <= reg_0_init;
      end
      8'd17: begin  // Dinamic
        if (!we)
          reg_0 <= addr[7:0];
      end
      default: begin
        if (we) begin
          if (addr[7:0] == 8'h00)
            reg_0 <= din;
          else
            reg_1 <= din;
        end
      end
    endcase
  end
end

assign irq = ar_enable ? ar_irq : 1'b0;
assign nmi = ar_enable ? ar_nmi : 1'b0;

assign io_select = !io1_cen;
assign io_dout   = !addr[0] ? reg_0 : reg_1;

assign rom_select = ar_enable ? ar_rom_select : (!romh || !roml);
assign rom_addr   = ar_enable ? {4'b0, ar_rom_addr}   :
                        !romh ? {bank_hi, addr[12:0]} :
                        !roml ? {bank_lo, addr[12:0]} : 21'hXXXX;

// expose RAM in $DF00 by default (required for EasyFlash)
assign ram_select = ar_enable ? ar_ram_select : !io2_cen;
assign ram_we     = ar_enable ? ar_ram_we : we && io2_we_valid;
assign ram_addr   = ar_enable ? ar_ram_addr : {7'b0, addr[7:0]};

assign dout = ar_enable  ? ar_dout  :
              io_select  ? io_dout  :
              rom_select ? rom_dout :
              ram_select ? ram_dout : 8'hXX;

always @(posedge clk) begin
  if (reset) begin
    rom_enable <= 1'b0;
    ram_enable <= 1'b0;

  end else begin
    if (rom_enable && rom_ready)
      rom_enable <= 1'b0;

    if (sdram_pending)
      rom_enable <= rom_select;

    if (ram_enable && ram_ready)
      ram_enable <= 1'b0;

    if (sdram_pending)
      ram_enable <= ram_select;
  end
end

c64_action_replay c64_action_replay_0 (
  .clk(clk),
  .reset(reset),
  .enable(ar_enable),
  .phi2_p(phi2_p),
  .phi2_h(phi2_h),

  .addr(addr),
  .din(din),
  .dout(ar_dout),

  .we(we),
  .ba(ba),

  .exrom(ar_exrom),
  .game(ar_game),

  .freeze(freeze),
  .roml(roml),
  .romh(romh),
  .io1_cen(io1_cen),
  .io2_cen(io2_cen),
  .io2_we_valid(ar_io2_we_valid),

  .nmi(ar_nmi),
  .irq(ar_irq),

  .rom_addr(ar_rom_addr),
  .rom_dout(rom_dout),
  .rom_select(ar_rom_select),

  .ram_addr(ar_ram_addr),
  .ram_we(ar_ram_we),
  .ram_dout(ram_dout),
  .ram_select(ar_ram_select)
);

endmodule

module c64_action_replay (
  input wire clk,
  input wire reset,
  input wire enable,
  input wire phi2_p,
  input wire phi2_h,

  input  wire [15:0] addr,
  input  wire  [7:0] din,
  output wire  [7:0] dout,

  input wire we,
  input wire ba,

  output wire exrom,
  output wire game,

  input wire freeze,
  input wire roml,
  input wire romh,
  input wire io1_cen,
  input wire io2_cen,

  output wire nmi,
  output wire irq,

  output wire io2_we_valid,

  output wire [16:0] rom_addr,
  input  wire [7:0]  rom_dout,
  output wire        rom_select,

  output wire [14:0] ram_addr,
  output wire        ram_we,
  input  wire [7:0]  ram_dout,
  output wire        ram_select
);

wire reset_n;
wire freeze_pending_n;

wire u6a_q;
wire u6b_qn;

wire u7c_out;
wire u7d_out;

reg freeze_pending;

assign reset_n          = !reset;
assign freeze_pending_n = !freeze_pending;

LS74_D_FF u6a (
  .clk(clk),
  .en(freeze_pending && phi2_h),
  .d(1'b1),
  .pr_n(1'b1),
  .clr_n(reset_n && u6b_qn),
  .q(u6a_q),
  .qn()
);

LS74_D_FF u6b (
  .clk(clk),
  .en(u5_q[2]),
  .d(1'b1),
  .pr_n(1'b1),
  .clr_n(reset_n && u7c_out),
  .q(),
  .qn(u6b_qn)
);

assign nmi = u6a_q;
assign irq = u6a_q;

wire [3:0] u5_q;

LS163_4BIT_COUNTER u5 (
  .clk(clk),
  .clr_n(1'b1),
  .load_n(u6a_q && ba),
  .enp(phi2_p),
  .ent(phi2_p),
  .d(4'b0000),
  .q(u5_q),
  .rco()
);

wire [7:0] io_dout;
wire       io_select;

wire [7:0] u4a_q;
wire [7:0] u4a_d;

// https://rr.c64.org/wiki/CyberpunX_Replay_Manual
// $de00 write: This register is reset to $00 on a hard reset if not in flash
//              mode. If in flash mode, it is set to $02 in order to prevent the
//              computer from starting the normal cartridge.
//
//              Bit 7 - controls bank-address 15 for ROM banking
//              Bit 6 - must be set once to "1" after a successful freeze in order to set the correct memory map
//                      and enable Bits 0 and 1 of this register. Otherwise no effect.
//              Bit 5 - switches between ROM and RAM: 0=ROM, 1=RAM
//              Bit 4 - controls bank-address 14 for ROM and RAM banking
//              Bit 3 - controls bank-address 13 for ROM and RAM banking
//              Bit 2 - Setting this bit will disable further write accesses to all registers & reset the c64 memory map
//                      to standard, as if there is no cartridge installed at all.
//              Bit 1 controls the EXROM line: A 0 will assert it, a 1 will deassert it.
//              Bit 0 controls the GAME  line: A 1 asserts the line, a 0 will deassert it.

LS273_D_FF_8BIT u4 (
  .clk(clk),
  .en(we && phi2_h && io_select && enable),
  .clr_n(freeze_pending_n && reset_n),
  .d(u4a_d),
  .q(u4a_q)
);

assign io2_we_valid = !u4a_q[2] && u4a_q[5];

assign u4a_d = (addr[0] == 1'b0) ? din : {din[7], u4a_q[6:5], din[4:3], u4a_q[2:0]};

wire [7:0] u4b_q;

// https://rr.c64.org/wiki/CyberpunX_Replay_Manual
// $de01 write: Extended control register. If not in Flash mode, this register
//              can only be written to once. If in Flash mode, the REUcomp bit
//              cannot be set, but the register will not be disabled by the
//              first write. Bit 5 is always set to 0 if not in flash mode.
//
//              Bit 7 - bank-address 15 for ROM (mirror of $de00)
//              Bit 6 - REU compatibility bit. 0=standard memory map
//                                             1=REU compatible memory map
//              Bit 5 - bank-address 16 for ROM (only in flash mode)
//              Bit 4 - bank-address 14 for RAM and ROM (mirror of $de00)
//              Bit 3 - bank-address 13 for RAM and ROM (mirror of $de00)
//              Bit 2 - NoFreeze   (1 disables Freeze function)
//              Bit 1 - AllowBank  (1 allows banking of RAM in $df00/$de02 area)
//              Bit 0 - enable accessory connector (SilverSurfer).

LS273_D_FF_8BIT u4a (
  .clk(clk),
  .en(we && phi2_h && io_select && enable && addr[0] == 1'b1),
  .clr_n(reset_n),
  .d(din),
  .q(u4b_q)
);

// https://rr.c64.org/wiki/CyberpunX_Replay_Manual
// $de00 read or $de01 read:
//              Bit 7 - feedback of banking bit 15
//              Bit 6 - 1=REU compatible memory map active
//              Bit 5 - feedback of banking bit 16
//              Bit 4 - feedback of banking bit 14
//              Bit 3 - feedback of banking bit 13
//              Bit 2 - 1=Freeze button pressed
//              Bit 1 - feedback of AllowBank bit
//              Bit 0 - 1=Flashmode active (jumper set)

assign io_dout = {u4a_q[7], u4b_q[6], 1'b0, u4a_q[4:3], 1'b0, u4b_q[1], 1'b0};

assign u7c_out = ~(u4a_q[6]);
assign u7d_out = ~(io1_cen || u4a_q[2]);

assign io_select = u7d_out && addr[7:1] == 7'b0;

wire o1, o2, o3, o4;
wire pla_oe;

assign pla_oe = !u4a_q[2];

c64_action_replay_pla u3_pla (
  .addr({reset_n && u6b_qn, addr[14], addr[15], addr[13], (io2_cen || u4b_q[6]) && io1_cen, u4a_q[0], u4a_q[1], u4a_q[5]}),
  .o1(o1),
  .o2(o2),
  .o3(o3),
  .o4(o4)
);

assign ram_select = (pla_oe ? !o2 : 1'b0) && !io_select;
assign ram_we     = we;
assign ram_addr   = {u4b_q[1] ? u4a_q[4:3] : 2'b00, addr[12:0]};

wire rom_oe;

assign rom_oe     = !romh || !roml || (!io2_cen && !u4b_q[6]) || !io1_cen;
assign rom_select = (pla_oe ? !o1 : 1'b0) && rom_oe && !io_select;
assign rom_addr   = {u4a_q[7], u4a_q[4:3], 1'b0, addr[12:0]};

assign dout = io_select  ? io_dout  :  // $DE00 / $DE01 read
              ram_select ? ram_dout :
              rom_select ? rom_dout : 8'hXX;

assign game  = pla_oe ? o3 : 1'b1;
assign exrom = pla_oe ? o4 : 1'b1;

always @(posedge clk) begin
  if (reset || !enable)
    freeze_pending <= 1'b0;
  else if (freeze && !u4b_q[2])
    freeze_pending <= 1'b1;
  else if (phi2_h)
    freeze_pending <= 1'b0;
end

endmodule

module LS163_4BIT_COUNTER (
  input wire clk,
  input wire clr_n,
  input wire load_n,
  input wire enp,
  input wire ent,
  input wire [3:0] d,
  output reg [3:0] q,
  output wire rco
);

always @(posedge clk) begin
  if (!clr_n)
    q <= 4'b0;
  else if (!load_n)
    q <= d;
  else if (enp && ent)
    q <= q + 1;
end

assign rco = (q == 4'b1111) && ent;

endmodule

module LS273_D_FF_8BIT (
  input wire clk,
  input wire en,
  input wire clr_n,
  input wire [7:0] d,
  output reg [7:0] q
);

always @(posedge clk) begin
  if (!clr_n)
    q <= 8'b0;
  else if (en)
    q <= d;
end

endmodule

module LS74_D_FF (
  input wire clk,
  input wire en,
  input wire d,
  input wire pr_n,
  input wire clr_n,
  output reg q,
  output wire qn
);

always @(posedge clk) begin
  if (!pr_n)
    q <= 1'b1;
  else if (!clr_n)
    q <= 1'b0;
  else if (en)
    q <= d;
end

assign qn = !q;

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
