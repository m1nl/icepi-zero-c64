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
// Based on MiSTer c1530.vhd, cleaned-up and rewritten to FSM
// Commodore 1530 to SD card host (read only) by Dar (darfpga@aol.fr)
// 25-Mars-2019
// ---------------------------------------------------------------------------

`default_nettype none
`timescale 1 ns / 1 ps
module c64_tape (
  input wire clk,
  input wire reset,
  input wire phi2_l,

  input  wire [7:0] tap_fifo_rd_data,
  input  wire       tap_fifo_rd_valid,
  output wire       tap_fifo_rd_en,

  input wire tape_play_toggle,

  output wire cass_sense_n,
  output  reg cass_read = 1'b1,

  input wire cass_motor_n,

  output reg act
);

localparam [23:0] TAP_OVERFLOW = 20000;  // in cycles

localparam [7:0] HEADER_LENGTH      = 8'h14;
localparam [7:0] TAP_VERSION_OFFSET = 8'h0c;
localparam [7:0] SIGNATURE_LENGTH   = 8'h0c;

localparam [8*SIGNATURE_LENGTH-1:0] SIGNATURE = "C64-TAPE-RAW";

wire [7:0] signature_byte [0:SIGNATURE_LENGTH-1];

genvar i;
generate
  for (i = 0; i < SIGNATURE_LENGTH; i = i + 1) begin
    assign signature_byte[i] = SIGNATURE[8*(SIGNATURE_LENGTH-i)-1 -: 8];
  end
endgenerate

localparam STATE_DRAIN  = 0;
localparam STATE_IDLE   = 1;
localparam STATE_HEADER = 2;
localparam STATE_MOTOR  = 3;
localparam STATE_PLAY   = 4;

reg [2:0] state;

localparam integer CASS_RUN_DELAY       = 10000;  // in cycles
localparam integer CASS_RUN_DELAY_WIDTH = $clog2(CASS_RUN_DELAY);

reg [CASS_RUN_DELAY_WIDTH-1:0] cass_run_counter = CASS_RUN_DELAY[CASS_RUN_DELAY_WIDTH-1:0];

reg cass_run_n = 1'b1;

reg [1:0] tap_version;

reg [23:0] wave_cnt;
reg [23:0] wave_len;

reg [23:0] wave_len_next;
reg        wave_len_next_valid;

reg [1:0] wave_24bits_len;

reg [7:0] header_bytes;

reg [19:0] act_cnt;
reg [19:0] act_period;

assign tap_fifo_rd_en = (state == STATE_DRAIN) || (state == STATE_HEADER) ||
  (state == STATE_PLAY && !wave_len_next_valid);

assign cass_sense_n = ~(state != STATE_IDLE);

always @(posedge clk) begin
  if (reset) begin
    act     <= 1'b0;
    act_cnt <= 0;

  end else if (phi2_l) begin
    if (act_period == 0) begin
      act     <= 0;
      act_cnt <= 0;

    end else if (act_cnt > act_period) begin
      act     <= ~act;
      act_cnt <= 0;

    end else begin
      act_cnt <= act_cnt + 1;
    end
  end
end

always @(posedge clk) begin
  if (reset) begin
    cass_read        <= 1'b1;
    cass_run_n       <= 1'b1;
    cass_run_counter <= CASS_RUN_DELAY[CASS_RUN_DELAY_WIDTH-1:0];
    act_period       <= 0;

    state <= STATE_DRAIN;

    header_bytes <= 8'd0;
    tap_version  <= 2'b00;

    wave_cnt <= 24'd0;
    wave_len <= 24'd0;

    wave_len_next       <= 24'd0;
    wave_len_next_valid <= 1'b0;

    wave_24bits_len <= 2'd0;

  end else begin
    case (state)
      STATE_DRAIN: begin
        cass_read  <= 1'b1;
        cass_run_n <= 1'b1;
        act_period <= (4095 << 4);

        if (!tap_fifo_rd_valid)
          state <= STATE_IDLE;
      end
      STATE_IDLE: begin
        cass_read  <= 1'b1;
        cass_run_n <= 1'b1;
        act_period <= 0;

        wave_cnt <= 24'd0;
        wave_len <= 24'd0;

        wave_len_next       <= 24'd0;
        wave_len_next_valid <= 1'b0;

        wave_24bits_len <= 2'd0;

        header_bytes <= 8'd0;
        tap_version  <= 2'b00;

        if (tape_play_toggle)
          state <= STATE_HEADER;
      end
      STATE_HEADER: begin
        cass_read  <= 1'b1;
        cass_run_n <= 1'b1;
        act_period <= (4095 << 6);

        if (tape_play_toggle)
          state <= STATE_DRAIN;

        if (tap_fifo_rd_valid && tap_fifo_rd_en) begin
          if (header_bytes < SIGNATURE_LENGTH) begin
            if (tap_fifo_rd_data != signature_byte[header_bytes[3:0]]) begin
              state <= STATE_DRAIN;
            end

          end else if (header_bytes == TAP_VERSION_OFFSET) begin
            tap_version <= tap_fifo_rd_data[1:0];
          end

          header_bytes <= header_bytes + 1;

          if (header_bytes == HEADER_LENGTH - 1)
            state <= STATE_MOTOR;
        end
      end
      STATE_MOTOR: begin
        act_period <= (4095 << 8);

        if (tape_play_toggle) begin
          state <= STATE_DRAIN;
        end

        if (cass_run_n != cass_motor_n) begin
          cass_run_n       <= cass_motor_n;
          cass_run_counter <= CASS_RUN_DELAY[CASS_RUN_DELAY_WIDTH-1:0];

        end else if (cass_run_counter != 0) begin
          if (phi2_l) cass_run_counter <= cass_run_counter - 1;
        end else if (!cass_run_n && !cass_motor_n) begin
          state <= STATE_PLAY;
        end
      end
      STATE_PLAY: begin
        cass_run_n <= 1'b0;

        if (act_cnt == 0) begin
          act_period <= (wave_len_next > 4095) ? (4095 << 8) :
            {wave_len_next[11:0], {8{1'b0}}};
        end

        if (tape_play_toggle) begin
          state <= STATE_DRAIN;
        end

        if (tap_fifo_rd_valid && tap_fifo_rd_en) begin
          if (wave_24bits_len == 3) begin
            wave_len_next[7:0] <= tap_fifo_rd_data;
            wave_24bits_len    <= 2;

          end else if (wave_24bits_len == 2) begin
            wave_len_next[15:8] <= tap_fifo_rd_data;
            wave_24bits_len     <= 1;

          end else if (wave_24bits_len == 1) begin
            wave_len_next[23:16] <= tap_fifo_rd_data;
            wave_len_next_valid  <= 1'b1;
            wave_24bits_len      <= 0;

          end else begin
            if (tap_fifo_rd_data == 8'd0) begin
              wave_len_next <= TAP_OVERFLOW;

              if (tap_version == 2'b00) begin
                wave_len_next_valid <= 1'b1;
                wave_24bits_len     <= 0;

              end else begin
                wave_len_next_valid <= 1'b0;
                wave_24bits_len     <= 3;
              end

            end else begin
              wave_len_next       <= {13'b0, tap_fifo_rd_data, 3'b0};
              wave_len_next_valid <= 1'b1;
            end
          end
        end

        if (cass_motor_n) begin
          state <= STATE_MOTOR;

        end else if (phi2_l) begin
          if (wave_cnt == wave_len) begin
            if (wave_len_next_valid) begin
              wave_len            <= wave_len_next;
              wave_len_next_valid <= 1'b0;
              wave_cnt            <= 24'd1;

              cass_read <= (tap_version == 2'b10) ? ~cass_read : 1'b0;

            end else if (wave_len != 24'd0) begin
              state <= STATE_DRAIN;
            end

          end else begin
            wave_cnt <= wave_cnt + 1;

            if (tap_version != 2'b10 && wave_cnt == {1'b0, wave_len[23:1]})
              cass_read <= 1'b1;
          end
        end
      end
      default: begin
        state <= STATE_DRAIN;
      end
    endcase
  end
end

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
