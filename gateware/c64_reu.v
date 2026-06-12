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

// this implementation is based on reu.vhd from MiST C64 core

`default_nettype none
`timescale 1 ns / 1 ps

module c64_reu (
  input  wire        clk,
  input  wire        rst,
  input  wire        phi2_p,       // CPU clock enable (rising edge of PHI2)
  input  wire        phi2_h,       // CPU clock enable (PHI2 high)
  input  wire        phi2_n,       // CPU clock enable (falling edge of PHI2)
  input  wire        phi2_l,       // CPU clock enable (PHI2 low)
  input  wire        vic_ba,

  // CPU-side bus (from/to c64_bus_arbiter)
  input  wire  [3:0] reu_addr,     // cpu_addr[3:0]
  input  wire  [7:0] reu_din,      // cpu_dout / DMA read data
  output reg   [7:0] reu_dout,     // register read / DMA write data
  input  wire        reu_we,       // cpu_we
  input  wire        reu_cen,      // chip-select from bus arbiter

  output reg  [15:0] reu_dma_addr,
  output reg         reu_dma_we,
  output wire        reu_dma_active,

  // FF00 DMA trigger
  input              ff00_trigger,

  // IRQ to CPU
  output wire        irq,

  // SDRAM interface - transaction happens when valid && ready;
  // valid must be deasserted right after ready to avoid repeat;
  // reu_mem_rvalid indicates reu_mem_dout is valid (read data)
  output reg  [21:0] reu_mem_addr,
  output reg   [7:0] reu_mem_din,
  input  wire  [7:0] reu_mem_dout,
  output reg         reu_mem_we,
  output reg         reu_mem_valid,
  input  wire        reu_mem_ready,
  input  wire        reu_mem_rvalid
);

//
// REU register file  ($DF00 .. $DF0A)
//
// $DF00  R    Status
// $DF01  R/W  Command      [7]=Execute [5]=Autoload [4]=FF00-decode [1:0]=Type
// $DF02  R/W  C64 base address lo
// $DF03  R/W  C64 base address hi
// $DF04  R/W  Expansion address lo
// $DF05  R/W  Expansion address mid
// $DF06  R/W  Expansion address bank (bits[2:0])
// $DF07  R/W  Transfer length lo
// $DF08  R/W  Transfer length hi
// $DF09  R/W  Interrupt mask
// $DF0A  R/W  Address control  [7]=C64 addr fixed  [6]=REU addr fixed

reg  [3:0] r_addr;       // latched REU address
reg  [1:0] r_int;        // $DF00  bit1=End-of-Block  bit0=Fault/Verify
reg  [7:0] r_cmd;        // $DF01
reg [15:0] r_c64_addr;   // $DF02-03
reg [21:0] r_exp_addr;   // $DF04-06
reg [15:0] r_xfer_len;   // $DF07-08
reg  [2:0] r_int_mask;   // $DF09
reg  [1:0] r_addr_ctrl;  // $DF0A  [1]=C64 addr fixed  [0]=REU addr fixed

// shadow registers reloaded from r_* on AUTOLOAD after transfer
reg [15:0] r_c64_addr_shadow;
reg [21:0] r_exp_addr_shadow;
reg [15:0] r_xfer_len_shadow;

//
// IRQ output
//
assign irq = r_int_mask[2] &
             ((r_int[1] & r_int_mask[1]) |
              (r_int[0] & r_int_mask[0]));

//
// FSM states
//
// Transfer type encoding (r_cmd[1:0]):
//   2'b00  C64 -> REU   cycle: READ_C64 -> WRITE_REU
//   2'b01  REU -> C64   cycle: READ_REU -> READ_REU_D -> WRITE_C64
//   2'b10  SWAP         cycle: READ_C64 -> READ_REU -> READ_REU_D -> WRITE_C64 -> WRITE_REU
//   2'b11  VERIFY       cycle: READ_C64 -> READ_REU -> READ_REU_D (compare, loop)
//
// C64 cycle (phi2-bound), two edges per beat:
//   phi2_p + BA: drive reu_dma_addr (+ reu_dma_we + reu_dout for writes), set c64_bus_valid
//   phi2_n     : latch reu_din (reads) / deassert reu_dma_we (writes), clear c64_bus_valid
//
// REU cycle (free-running), split into command and data phases:
//   ST_READ_REU  : assert reu_mem_valid; on reu_mem_ready deassert and go to ST_READ_REU_D
//   ST_READ_REU_D: wait for reu_mem_rvalid; capture reu_mem_dout, advance, decide next state
//   ST_WRITE_REU : assert reu_mem_valid+we; on reu_mem_ready deassert, advance, decide next state
//
localparam ST_IDLE       = 3'd0;
localparam ST_READ_C64   = 3'd1;
localparam ST_READ_REU   = 3'd2;
localparam ST_READ_REU_D = 3'd3;
localparam ST_WRITE_C64  = 3'd4;
localparam ST_WRITE_REU  = 3'd5;
localparam ST_DONE       = 3'd6;

reg [2:0] state;

// c64_bus_valid: set on phi2_p when address is driven, cleared on phi2_n
reg       c64_bus_valid;

// per-beat data buffers
reg [7:0] r_c64_data;   // data latched from C64 bus
reg [7:0] r_reu_data;   // data latched from REU memory

wire [1:0] xfer_type = r_cmd[1:0];

assign reu_dma_active = (state != ST_IDLE);

reg vic_ba2;
reg vic_ba3;

always @(posedge clk) begin
  if (phi2_n) begin
    vic_ba2 <= vic_ba;
    vic_ba3 <= vic_ba2 || vic_ba;
  end
end

initial begin
  r_int             = 2'b00;
  r_cmd             = 8'h10;
  r_c64_addr        = 16'd0;
  r_exp_addr        = 22'd0;
  r_xfer_len        = 16'd0;
  r_int_mask        = 3'b000;
  r_addr_ctrl       = 2'b00;
  r_c64_addr_shadow = 16'd0;
  r_exp_addr_shadow = 22'd0;
  r_xfer_len_shadow = 16'd0;

  c64_bus_valid     = 1'b0;
  reu_dma_addr      = 16'd0;
  reu_dma_we        = 1'b0;
  reu_mem_addr      = 22'd0;
  reu_mem_din       = 8'd0;
  reu_mem_we        = 1'b0;
  reu_mem_valid     = 1'b0;

  r_c64_data        = 8'd0;
  r_reu_data        = 8'd0;
end

// reu_dout: register file during idle / DMA write data to C64 during WRITE_C64
always @(*) begin
  if (state == ST_WRITE_C64) begin
    reu_dout = r_reu_data;
  end else begin
    reu_dout = 8'hff;
    case (reu_addr)
      4'h0: reu_dout = {irq, r_int, 1'b1, 4'b0000};
      4'h1: reu_dout = r_cmd;
      4'h2: reu_dout = r_c64_addr[7:0];
      4'h3: reu_dout = r_c64_addr[15:8];
      4'h4: reu_dout = r_exp_addr[7:0];
      4'h5: reu_dout = r_exp_addr[15:8];
      4'h6: reu_dout = {2'b11, r_exp_addr[21:16]};
      4'h7: reu_dout = r_xfer_len[7:0];
      4'h8: reu_dout = r_xfer_len[15:8];
      4'h9: reu_dout = {r_int_mask, 5'h1f};
      4'ha: reu_dout = {r_addr_ctrl, 6'h3f};
      default: ;
    endcase
  end
end

always @(posedge clk) begin
  if (rst) begin
    r_int             <= 2'b00;
    r_cmd             <= 8'h10;
    r_c64_addr        <= 16'd0;
    r_exp_addr        <= 22'd0;
    r_xfer_len        <= 16'd0;
    r_int_mask        <= 3'b000;
    r_addr_ctrl       <= 2'b00;
    r_c64_addr_shadow <= 16'd0;
    r_exp_addr_shadow <= 22'd0;
    r_xfer_len_shadow <= 16'd0;

    c64_bus_valid     <= 1'b0;
    reu_dma_addr      <= 16'd0;
    reu_dma_we        <= 1'b0;
    reu_mem_addr      <= 22'd0;
    reu_mem_din       <= 8'd0;
    reu_mem_we        <= 1'b0;
    reu_mem_valid     <= 1'b0;

    r_c64_data        <= 8'd0;
    r_reu_data        <= 8'd0;

    state             <= ST_IDLE;

  end else begin
    // -----------------------------------------------------------------------
    // Register file write / read side-effects (CPU side, phi2_h)
    // -----------------------------------------------------------------------
    if (!reu_cen) begin
      r_addr <= reu_addr;

      if (reu_we && phi2_h) begin
        case (reu_addr)
          4'h1: r_cmd <= reu_din;
          4'h2: begin r_c64_addr <= {r_c64_addr_shadow[15:8], reu_din};       r_c64_addr_shadow[7:0]   <= reu_din;      end
          4'h3: begin r_c64_addr <= {reu_din, r_c64_addr_shadow[7:0]};        r_c64_addr_shadow[15:8]  <= reu_din;      end
          4'h4: begin r_exp_addr[15:0] <= {r_exp_addr_shadow[15:8], reu_din}; r_exp_addr_shadow[7:0]   <= reu_din;      end
          4'h5: begin r_exp_addr[15:0] <= {reu_din, r_exp_addr_shadow[7:0]};  r_exp_addr_shadow[15:8]  <= reu_din;      end
          4'h6: begin r_exp_addr[21:16] <= reu_din[5:0];                      r_exp_addr_shadow[21:16] <= reu_din[5:0]; end
          4'h7: begin r_xfer_len <= {r_xfer_len_shadow[15:8], reu_din};       r_xfer_len_shadow[7:0]   <= reu_din;      end
          4'h8: begin r_xfer_len <= {reu_din, r_xfer_len_shadow[7:0]};        r_xfer_len_shadow[15:8]  <= reu_din;      end
          4'h9: r_int_mask <= reu_din[7:5];
          4'ha: r_addr_ctrl <= reu_din[7:6];
          default: ;
        endcase
      end

      if (!reu_we && phi2_n) begin
        // clear status flags on read of $DF00 at the end of phi2 cycle
        if (reu_addr == 4'h0)
          r_int <= 2'b00;
      end
    end

    // -----------------------------------------------------------------------
    // Main state machine
    // -----------------------------------------------------------------------
    case (state)

      // -- IDLE: waiting for execute bit ------------------------------------
      ST_IDLE: begin
        if (phi2_n && r_cmd[7]) begin
          // bit4=0: FF00-decode active, arm and wait for $FF00 write
          // bit4=1: FF00-decode off, start immediately
          if (r_cmd[4] || ff00_trigger)
            state <= (xfer_type == 2'b00) ? ST_READ_C64 : ST_READ_REU;
        end
      end

      // -- READ C64: C64 cycle, phi2-bound ----------------------------------
      // phi2_p + BA: drive reu_dma_addr, set c64_bus_valid
      // phi2_n     : latch reu_din -> r_c64_data, clear c64_bus_valid, go next
      //
      // Types using this state: 00 (C64->REU), 10 (SWAP), 11 (VERIFY)
      // c64_addr advances for all except SWAP (SWAP advances in WRITE_C64)
      ST_READ_C64: begin
        if (vic_ba && phi2_p && !c64_bus_valid) begin
          reu_dma_addr <= r_c64_addr;
          c64_bus_valid <= 1'b1;
        end
        if (phi2_n && c64_bus_valid) begin
          r_c64_data    <= reu_din;
          c64_bus_valid <= 1'b0;
          if (!r_addr_ctrl[1] && xfer_type != 2'b10)
            r_c64_addr <= r_c64_addr + 1;
          case (xfer_type)
            2'b00: state <= ST_WRITE_REU;  // C64->REU: write to REU
            2'b10: state <= ST_READ_REU;   // SWAP: read REU next
            2'b11: begin                   // VERIFY: compare data, read REU
              if (r_xfer_len == 16'd1)
                state <= ST_DONE;
              else begin
                r_xfer_len <= r_xfer_len - 1;
                state <= ST_READ_REU;
              end
              if (reu_mem_dout != reu_din) begin
                r_int[0] <= 1'b1;
                state    <= ST_DONE;
              end
            end
            default: state <= ST_DONE;
          endcase
        end
      end

      // -- READ REU: command phase ------------------------------------------
      // Assert reu_mem_valid; on reu_mem_ready deassert and move to data phase.
      // Memory controller accepts the request and will return data later via rvalid.
      ST_READ_REU: begin
        if (!reu_mem_valid) begin
          reu_mem_addr  <= r_exp_addr;
          reu_mem_we    <= 1'b0;
          reu_mem_valid <= 1'b1;
        end
        if (reu_mem_valid && reu_mem_ready) begin
          reu_mem_valid <= 1'b0;
          state         <= ST_READ_REU_D;
        end
      end

      // -- READ_REU_D: data phase -------------------------------------------
      // Wait for reu_mem_rvalid; capture data, advance exp_addr, decide next.
      //
      // Types: 01 (REU->C64), 10 (SWAP), 11 (VERIFY)
      // exp_addr advances for 01 and 11; for SWAP it is deferred to WRITE_REU
      ST_READ_REU_D: begin
        if (reu_mem_rvalid) begin
          r_reu_data <= reu_mem_dout;
          case (xfer_type)
            2'b01: begin  // REU->C64: advance exp_addr, then write to C64
              if (!r_addr_ctrl[0]) r_exp_addr <= r_exp_addr + 1;
              state <= ST_WRITE_C64;
            end
            2'b10: begin  // SWAP: exp_addr deferred to WRITE_REU, write to C64
              state <= ST_WRITE_C64;
            end
            2'b11: begin  // VERIFY: advance exp_addr, then read from C64
              if (!r_addr_ctrl[0]) r_exp_addr <= r_exp_addr + 1;
              state <= ST_READ_C64;
            end
            default: state <= ST_DONE;
          endcase
        end
      end

      // -- WRITE C64: C64 cycle, phi2-bound ---------------------------------
      // phi2_p + BA: drive reu_dma_addr + reu_dma_we, set c64_bus_valid
      //              reu_dout outputs r_reu_data combinationally
      // phi2_n     : deassert reu_dma_we, clear c64_bus_valid, advance c64_addr, go next
      //
      // Types using this state: 01 (REU->C64), 10 (SWAP)
      ST_WRITE_C64: begin
        if (vic_ba3 && phi2_p && !c64_bus_valid) begin
          reu_dma_addr <= r_c64_addr;
          reu_dma_we   <= 1'b1;
          c64_bus_valid <= 1'b1;
        end
        if (phi2_n && c64_bus_valid) begin
          reu_dma_we    <= 1'b0;
          c64_bus_valid <= 1'b0;
          if (!r_addr_ctrl[1]) r_c64_addr <= r_c64_addr + 1;
          case (xfer_type)
            2'b01: begin  // REU->C64: len decrement, loop or done
              if (r_xfer_len == 16'd1)
                state <= ST_DONE;
              else begin
                r_xfer_len <= r_xfer_len - 1;
                state      <= ST_READ_REU;
              end
            end
            2'b10: state <= ST_WRITE_REU;  // SWAP: write C64 data to REU
            default: state <= ST_DONE;
          endcase
        end
      end

      // -- WRITE REU: free-running SDRAM write ------------------------------
      // Assert reu_mem_valid immediately; advance on reu_mem_ready.
      //
      // Types using this state: 00 (C64->REU), 10 (SWAP)
      // exp_addr advances for all types (including SWAP which deferred it here)
      ST_WRITE_REU: begin
        if (!reu_mem_valid) begin
          reu_mem_addr  <= r_exp_addr;
          reu_mem_din   <= r_c64_data;
          reu_mem_we    <= 1'b1;
          reu_mem_valid <= 1'b1;
        end
        if (reu_mem_valid && reu_mem_ready) begin
          reu_mem_valid <= 1'b0;
          reu_mem_we    <= 1'b0;
          if (!r_addr_ctrl[0]) r_exp_addr <= r_exp_addr + 1;
          // both 00 and 10 share the same loop-or-done logic
          if (r_xfer_len == 16'd1)
            state <= ST_DONE;
          else begin
            r_xfer_len <= r_xfer_len - 1;
            state      <= ST_READ_C64;
          end
        end
      end

      // -- DONE: release DMA, set interrupt flags, optional autoload --------
      ST_DONE: begin
        if (phi2_p && vic_ba2) begin
          // set EOB unless a verify fault fired before the last byte
          if (!(r_int[0] && r_xfer_len != 16'd1)) begin
            r_int[1] <= 1'b1;
          end

          // autoload: restore shadow registers
          if (r_cmd[5]) begin
            r_c64_addr <= r_c64_addr_shadow;
            r_exp_addr <= r_exp_addr_shadow;
            r_xfer_len <= r_xfer_len_shadow;
          end

          // clear execute; force FF00-decode on (hardware behaviour post-transfer)
          r_cmd[7] <= 1'b0;
          r_cmd[4] <= 1'b1;

          state <= ST_IDLE;
        end
      end

      default: state <= ST_IDLE;
    endcase
  end
end

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
