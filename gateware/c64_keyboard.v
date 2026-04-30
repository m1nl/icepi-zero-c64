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
// Based on MiSTer fpga64_keyboard.vhd
// cleaned-up, rewritten to Verilog and extended
// ---------------------------------------------------------------------------
// Copyright 2005-2008 by Peter Wendrich (pwsoft@syntiac.com)
// http://www.syntiac.com/fpga64.html
// ---------------------------------------------------------------------------
// 'Joystick emulation on keypad' additions by
// Mark McDougall (msmcdoug@iinet.net.au)
// ---------------------------------------------------------------------------

`default_nettype none
`timescale 1 ns / 1 ps
module c64_keyboard #(
  parameter BACKWARDS_READING_ENABLED = 1,
  parameter CLK_FREQUENCY = 31_527_778
) (
  input wire clk,
  input wire reset,

  input wire enable,

  input  wire [7:0] pa_out,
  output wire [7:0] pa_in,
  input  wire [7:0] ddra,

  input  wire [7:0] pb_out,
  output wire [7:0] pb_in,
  input  wire [7:0] ddrb,

  output reg restore_toggle,
  input wire restore_toggle_ack,

  output reg tape_play_pulse,
  output reg overlay_pulse,
  output reg reset_pulse,
  output reg freeze_pulse,

  output wire pot_x,
  output wire pot_y,

  input wire [1:0] joy_emulation,
  input wire       joy_invert,
  input wire       joy_button_space,

  input wire [9:0] joy_a,
  input wire [9:0] joy_b,

  input wire       hid_key_report,
  input wire [7:0] hid_key_modifiers,
  input wire [7:0] hid_key_0,
  input wire [7:0] hid_key_1,
  input wire [7:0] hid_key_2,
  input wire [7:0] hid_key_3,

  output wire       ps2_fifo_rd_en,
  input  wire [7:0] ps2_fifo_rd_data,
  input  wire       ps2_fifo_rd_valid
);

wire [7:0] pa_out_od     = (~ddra | pa_out);
wire [7:0] pb_out_biased = (~ddrb | pb_out);

localparam integer KEYBOARD_FREQUENCY = 120;  // ~ 8ms
localparam integer KEYBOARD_FREQUENCY_WIDTH = $clog2(CLK_FREQUENCY + KEYBOARD_FREQUENCY + 1);

reg [KEYBOARD_FREQUENCY_WIDTH-1:0] ps2_fifo_rd_en_cnt = 0;

assign ps2_fifo_rd_en = (ps2_fifo_rd_en_cnt >= CLK_FREQUENCY[KEYBOARD_FREQUENCY_WIDTH-1:0]);

always @(posedge clk) begin
  if (reset)
    ps2_fifo_rd_en_cnt <= 0;
  else begin
    ps2_fifo_rd_en_cnt <= ps2_fifo_rd_en_cnt +
      KEYBOARD_FREQUENCY[KEYBOARD_FREQUENCY_WIDTH-1:0];

    if (ps2_fifo_rd_en)
      ps2_fifo_rd_en_cnt <= ps2_fifo_rd_en_cnt +
        KEYBOARD_FREQUENCY[KEYBOARD_FREQUENCY_WIDTH-1:0] -
        CLK_FREQUENCY[KEYBOARD_FREQUENCY_WIDTH-1:0];
  end
end

reg key_restore;
reg key_restore_i;

always @(posedge clk) begin
  if (reset) begin
    restore_toggle <= 1'b0;
    key_restore_i  <= 1'b0;
  end else if (enable) begin
    if (key_restore && !key_restore_i)
      restore_toggle <= 1'b1;
    else if (restore_toggle_ack)
      restore_toggle <= 1'b0;

    key_restore_i <= key_restore;
  end
end

reg key_tape_play;
reg key_tape_play_i;

always @(posedge clk) begin
  if (reset) begin
    tape_play_pulse <= 1'b0;
    key_tape_play_i  <= 1'b0;
  end else if (enable) begin
    if (key_tape_play && !key_tape_play_i)
      tape_play_pulse <= 1'b1;
    else
      tape_play_pulse <= 1'b0;

    key_tape_play_i <= key_tape_play;
  end
end

localparam KEY_SYSRQ = 8'h46;

wire joy_overlay;
wire key_overlay      = hid_keys[0] == KEY_SYSRQ;
wire overlay_combined = key_overlay || joy_overlay;

reg overlay_combined_i;

// game_sel OR game_x + game_y
assign joy_overlay = joy_a == 10'b0100000000 ||
                     joy_a == 10'b0011000000 ||
                     joy_b == 10'b0100000000 ||
                     joy_b == 10'b0011000000;

always @(posedge clk) begin
  if (reset) begin
    overlay_pulse      <= 1'b0;
    overlay_combined_i <= 1'b0;
  end else begin
    if (overlay_combined && !overlay_combined_i)
      overlay_pulse <= 1'b1;
    else
      overlay_pulse <= 1'b0;

    overlay_combined_i <= overlay_combined;
  end
end

localparam KEY_PAGE_BREAK = 8'h48;

wire joy_reset;
wire key_reset = hid_keys[0] == KEY_PAGE_BREAK;
wire reset_combined = key_reset || joy_reset;

reg reset_combined_i;

// game_sel + game_sta OR game_a + game_b + game_x + game_y
assign joy_reset = joy_a == 10'b1100000000 ||
                   joy_b == 10'b1100000000 ||
                   joy_a == 10'b0011110000 ||
                   joy_b == 10'b0011110000;

always @(posedge clk) begin
  if (reset) begin
    reset_pulse      <= 1'b0;
    reset_combined_i <= 1'b0;
  end else if (enable) begin
    if (reset_combined && !reset_combined_i)
      reset_pulse <= 1'b1;
    else
      reset_pulse <= 1'b0;

    reset_combined_i <= reset_combined;
  end
end

localparam KEY_F12 = 8'h45;

wire key_freeze = hid_keys[0] == KEY_F12;
wire freeze_combined = key_freeze;

reg freeze_combined_i;

always @(posedge clk) begin
  if (reset) begin
    freeze_pulse      <= 1'b0;
    freeze_combined_i <= 1'b0;
  end else if (enable) begin
    if (freeze_combined && !freeze_combined_i)
      freeze_pulse <= 1'b1;
    else
      freeze_pulse <= 1'b0;

    freeze_combined_i <= freeze_combined;
  end
end

reg ps2_extended;
reg ps2_pressed = 1'b1;

wire hid_pressed;
wire hid_released;
wire hid_changed;

wire [7:0] hid_key;
wire [7:0] hid_keys [0:3];

reg [7:0] hid_key_modifiers_i;
reg [7:0] hid_keys_i [0:3];
reg [1:0] hid_counter = 3;
reg       hid_enable;

assign hid_keys[0] = hid_key_0;
assign hid_keys[1] = hid_key_1;
assign hid_keys[2] = hid_key_2;
assign hid_keys[3] = hid_key_3;

assign hid_pressed  = hid_keys_i[hid_counter] == 0 && hid_keys[hid_counter] != 0;
assign hid_released = hid_keys_i[hid_counter] != 0 && hid_keys[hid_counter] == 0;
assign hid_changed  = hid_keys_i[hid_counter] != 0 && hid_keys[hid_counter] != 0 &&
  hid_keys_i[hid_counter] != hid_keys[hid_counter];

assign hid_key = hid_pressed  ? hid_keys[hid_counter]   :
                 hid_released ? hid_keys_i[hid_counter] :
                 hid_changed  ? hid_keys_i[hid_counter] : 0;

reg key_return;
reg key_space;
reg key_runstop;

reg key_left;
reg key_right;
reg key_up;
reg key_down;

reg key_1;
reg key_2;
reg key_3;
reg key_4;
reg key_5;
reg key_6;
reg key_7;
reg key_8;
reg key_9;
reg key_0;

reg key_F1;
reg key_F2;
reg key_F3;
reg key_F4;
reg key_F5;
reg key_F6;
reg key_F7;
reg key_F8;

reg key_Q;
reg key_W;
reg key_E;
reg key_R;
reg key_T;
reg key_Y;
reg key_U;
reg key_I;
reg key_O;
reg key_P;

reg key_A;
reg key_S;
reg key_D;
reg key_F;
reg key_G;
reg key_H;
reg key_J;
reg key_K;
reg key_L;

reg key_Z;
reg key_X;
reg key_C;
reg key_V;
reg key_B;
reg key_M;
reg key_N;

reg key_exclamation;
reg key_at;
reg key_hash;
reg key_dollar;
reg key_percent;
reg key_arrow_left;
reg key_arrow_up;
reg key_and;
reg key_star;
reg key_parenthesis_left;
reg key_parenthesis_right;

reg key_comma;
reg key_dot;
reg key_angle_left;
reg key_angle_right;
reg key_slash;
reg key_question;

reg key_semicolon;
reg key_colon;
reg key_quote;

reg key_bracket_left;
reg key_bracket_right;

reg key_minus;
reg key_equal;
reg key_plus;

reg key_home;
reg key_cls;
reg key_del;
reg key_ins;

reg key_pound;

reg key_caps;
reg key_ctrl;
reg key_commodore;

reg key_shiftl;
reg key_shiftr;

reg key_shift;

wire joy_emulation_enabled = |joy_emulation;

wire [6:0] joy_a_combined;
wire [6:0] joy_b_combined;

wire [6:0] joy_a_i;
wire [6:0] joy_b_i;

wire joy_keyboard_control;
wire joy_button_space_i;

wire key_up_i;
wire key_down_i;
wire key_left_i;
wire key_right_i;

wire key_space_i;
wire key_return_i;
wire key_F1_i;
wire key_F3_i;

assign joy_a_combined = (joy_emulation[0] ? {1'b0, key_space, key_F, key_right, key_left, key_down, key_up} : 7'b0) | joy_a[6:0];
assign joy_b_combined = (joy_emulation[1] ? {1'b0, key_space, key_F, key_right, key_left, key_down, key_up} : 7'b0) | joy_b[6:0];

assign joy_a_i = (joy_keyboard_control || joy_reset) ? 7'b0 : (joy_invert ? joy_b_combined[6:0] : joy_a_combined[6:0]);
assign joy_b_i = (joy_keyboard_control || joy_reset) ? 7'b0 : (joy_invert ? joy_a_combined[6:0] : joy_b_combined[6:0]);

assign pot_x = (pa_out_od[6] && joy_a_i[5]) || (pa_out_od[7] && joy_b_i[5]);  // B
assign pot_y = (pa_out_od[6] && joy_a_i[6]) || (pa_out_od[7] && joy_b_i[6]);  // X

assign joy_keyboard_control = enable && !joy_reset && (joy_a[7] || joy_b[7]);  // Y
assign joy_button_space_i   = enable && !joy_reset && joy_button_space && (joy_a[5] || joy_b[5]);  // B

assign key_up_i    = (!joy_emulation_enabled && key_up)    || (joy_keyboard_control && (joy_a[0] || joy_b[0]));
assign key_down_i  = (!joy_emulation_enabled && key_down)  || (joy_keyboard_control && (joy_a[1] || joy_b[1]));
assign key_left_i  = (!joy_emulation_enabled && key_left)  || (joy_keyboard_control && (joy_a[2] || joy_b[2]));
assign key_right_i = (!joy_emulation_enabled && key_right) || (joy_keyboard_control && (joy_a[3] || joy_b[3]));

assign key_F1_i    = key_F1 || (joy_keyboard_control && (joy_a[9] || joy_b[9]));  // game_sta
assign key_F3_i    = key_F3 || (joy_keyboard_control && (joy_a[8] || joy_b[8]));  // game_sel

assign key_return_i = key_return || (joy_keyboard_control && (joy_a[4] || joy_b[4]));  // A
assign key_space_i  = key_space  || (joy_keyboard_control && (joy_a[5] || joy_b[5])) || joy_button_space_i;  // B

wire mod_shift;
wire shift;

assign mod_shift = key_shiftl | key_shiftr;

assign shift = key_left_i | key_up_i | key_caps | key_ins | key_F2 |
  key_F4 | key_F6 | key_F8 | key_exclamation | key_quote | key_hash |
  key_dollar | key_percent | key_and | key_parenthesis_left |
  key_parenthesis_right | key_bracket_left | key_bracket_right |
  key_angle_left | key_angle_right | key_question;

// Output assignments for pa_in (reading A, scan pattern on B)
assign pa_in[0] = pa_out_od[0] & ~joy_b_i[0] &
  (!BACKWARDS_READING_ENABLED |
   ((pb_out_biased[0] | ~(key_del | key_ins)) &
    (pb_out_biased[1] | ~key_return_i) &
    (pb_out_biased[2] | ~(key_left_i | key_right_i)) &
    (pb_out_biased[3] | ~(key_F7 | key_F8)) &
    (pb_out_biased[4] | ~(key_F1_i | key_F2)) &
    (pb_out_biased[5] | ~(key_F3_i | key_F4)) &
    (pb_out_biased[6] | ~(key_F5 | key_F6)) &
    (pb_out_biased[7] | ~(key_up_i | key_down_i))
   ));

assign pa_in[1] = pa_out_od[1] & ~joy_b_i[1] &
  (!BACKWARDS_READING_ENABLED |
   ((pb_out_biased[0] | ~(key_3 | key_hash)) &
    (pb_out_biased[1] | ~key_W) &
    (pb_out_biased[2] | ~key_A) &
    (pb_out_biased[3] | ~(key_4 | key_dollar)) &
    (pb_out_biased[4] | ~key_Z) &
    (pb_out_biased[5] | ~key_S) &
    (pb_out_biased[6] | ~key_E) &
    (pb_out_biased[7] | 1)  // ignore shiftl
   ));

assign pa_in[2] = pa_out_od[2] & ~joy_b_i[2] &
  (!BACKWARDS_READING_ENABLED |
   ((pb_out_biased[0] | ~(key_5 | key_percent)) &
    (pb_out_biased[1] | ~key_R) &
    (pb_out_biased[2] | ~key_D) &
    (pb_out_biased[3] | ~(key_6 | key_and)) &
    (pb_out_biased[4] | ~key_C) &
    (pb_out_biased[5] | ~(!joy_emulation_enabled & key_F)) &
    (pb_out_biased[6] | ~key_T) &
    (pb_out_biased[7] | ~key_X)
   ));

assign pa_in[3] = pa_out_od[3] & ~joy_b_i[3] &
  (!BACKWARDS_READING_ENABLED |
   ((pb_out_biased[0] | ~key_7) &
    (pb_out_biased[1] | ~key_Y) &
    (pb_out_biased[2] | ~key_G) &
    (pb_out_biased[3] | ~(key_8 | key_parenthesis_left)) &
    (pb_out_biased[4] | ~key_B) &
    (pb_out_biased[5] | ~key_H) &
    (pb_out_biased[6] | ~key_U) &
    (pb_out_biased[7] | ~key_V)
   ));

assign pa_in[4] = pa_out_od[4] & ~joy_b_i[4] &
  (!BACKWARDS_READING_ENABLED |
   ((pb_out_biased[0] | ~(key_9 | key_parenthesis_right)) &
    (pb_out_biased[1] | ~key_I) &
    (pb_out_biased[2] | ~key_J) &
    (pb_out_biased[3] | ~key_0) &
    (pb_out_biased[4] | ~key_M) &
    (pb_out_biased[5] | ~key_K) &
    (pb_out_biased[6] | ~key_O) &
    (pb_out_biased[7] | ~key_N)
   ));

assign pa_in[5] = pa_out_od[5] &
  (!BACKWARDS_READING_ENABLED |
   ((pb_out_biased[0] | ~key_plus) &
    (pb_out_biased[1] | ~key_P) &
    (pb_out_biased[2] | ~key_L) &
    (pb_out_biased[3] | ~key_minus) &
    (pb_out_biased[4] | ~(key_dot | key_angle_right)) &
    (pb_out_biased[5] | ~(key_colon | key_bracket_left)) &
    (pb_out_biased[6] | ~key_at) &
    (pb_out_biased[7] | ~(key_comma | key_angle_left))
   ));

assign pa_in[6] = pa_out_od[6] &
  (!BACKWARDS_READING_ENABLED |
   ((pb_out_biased[0] | ~key_pound) &
    (pb_out_biased[1] | ~key_star) &
    (pb_out_biased[2] | ~(key_semicolon | key_bracket_right)) &
    (pb_out_biased[3] | ~(key_home | key_cls)) &
    (pb_out_biased[4] | ~(key_shift | shift)) &
    (pb_out_biased[5] | ~key_equal) &
    (pb_out_biased[6] | ~key_arrow_up) &
    (pb_out_biased[7] | ~(key_slash | key_question))
   ));

assign pa_in[7] = pa_out_od[7] &
  (!BACKWARDS_READING_ENABLED |
   ((pb_out_biased[0] | ~(key_1 | key_exclamation)) &
    (pb_out_biased[1] | ~key_arrow_left) &
    (pb_out_biased[2] | ~key_ctrl) &
    (pb_out_biased[3] | ~(key_2 | key_quote)) &
    (pb_out_biased[4] | ~key_space_i) &
    (pb_out_biased[5] | ~(key_commodore | key_caps)) &
    (pb_out_biased[6] | ~key_Q) &
    (pb_out_biased[7] | ~key_runstop)
   ));

// Output assignments for pb_in (reading B, scan pattern on A)
assign pb_in[0] = pb_out_biased[0] & ~joy_a_i[0] &
   ((pa_out_od[0] | ~(key_del | key_ins)) &
    (pa_out_od[1] | ~(key_3 | key_hash)) &
    (pa_out_od[2] | ~(key_5 | key_percent)) &
    (pa_out_od[3] | ~key_7) &
    (pa_out_od[4] | ~(key_9 | key_parenthesis_right)) &
    (pa_out_od[5] | ~key_plus) &
    (pa_out_od[6] | ~key_pound) &
    (pa_out_od[7] | ~(key_1 | key_exclamation))
   );

assign pb_in[1] = pb_out_biased[1] & ~joy_a_i[1] &
   ((pa_out_od[0] | ~key_return_i) &
    (pa_out_od[1] | ~key_W) &
    (pa_out_od[2] | ~key_R) &
    (pa_out_od[3] | ~key_Y) &
    (pa_out_od[4] | ~key_I) &
    (pa_out_od[5] | ~key_P) &
    (pa_out_od[6] | ~key_star) &
    (pa_out_od[7] | ~key_arrow_left)
   );

assign pb_in[2] = pb_out_biased[2] & ~joy_a_i[2] &
   ((pa_out_od[0] | ~(key_left_i | key_right_i)) &
    (pa_out_od[1] | ~key_A) &
    (pa_out_od[2] | ~key_D) &
    (pa_out_od[3] | ~key_G) &
    (pa_out_od[4] | ~key_J) &
    (pa_out_od[5] | ~key_L) &
    (pa_out_od[6] | ~(key_semicolon | key_bracket_right)) &
    (pa_out_od[7] | ~key_ctrl)
   );

assign pb_in[3] = pb_out_biased[3] & ~joy_a_i[3] &
   ((pa_out_od[0] | ~(key_F7 | key_F8)) &
    (pa_out_od[1] | ~(key_4 | key_dollar)) &
    (pa_out_od[2] | ~(key_6 | key_and)) &
    (pa_out_od[3] | ~(key_8 | key_parenthesis_left)) &
    (pa_out_od[4] | ~key_0) &
    (pa_out_od[5] | ~key_minus) &
    (pa_out_od[6] | ~(key_home | key_cls)) &
    (pa_out_od[7] | ~(key_2 | key_quote))
   );

assign pb_in[4] = pb_out_biased[4] & ~joy_a_i[4] &
   ((pa_out_od[0] | ~(key_F1_i | key_F2)) &
    (pa_out_od[1] | ~key_Z) &
    (pa_out_od[2] | ~key_C) &
    (pa_out_od[3] | ~key_B) &
    (pa_out_od[4] | ~key_M) &
    (pa_out_od[5] | ~(key_dot | key_angle_right)) &
    (pa_out_od[6] | ~(key_shift | shift)) &
    (pa_out_od[7] | ~key_space_i)
   );

assign pb_in[5] = pb_out_biased[5] &
   ((pa_out_od[0] | ~(key_F3_i | key_F4)) &
    (pa_out_od[1] | ~key_S) &
    (pa_out_od[2] | ~(!joy_emulation_enabled & key_F)) &
    (pa_out_od[3] | ~key_H) &
    (pa_out_od[4] | ~key_K) &
    (pa_out_od[5] | ~(key_colon | key_bracket_left)) &
    (pa_out_od[6] | ~key_equal) &
    (pa_out_od[7] | ~(key_commodore | key_caps))
   );

assign pb_in[6] = pb_out_biased[6] &
   ((pa_out_od[0] | ~(key_F5 | key_F6)) &
    (pa_out_od[1] | ~key_E) &
    (pa_out_od[2] | ~key_T) &
    (pa_out_od[3] | ~key_U) &
    (pa_out_od[4] | ~key_O) &
    (pa_out_od[5] | ~key_at) &
    (pa_out_od[6] | ~key_arrow_up) &
    (pa_out_od[7] | ~key_Q)
   );

assign pb_in[7] = pb_out_biased[7] &
   ((pa_out_od[0] | ~(key_up_i | key_down_i)) &
    (pa_out_od[1] | 1) &  // ignore shiftl
    (pa_out_od[2] | ~key_X) &
    (pa_out_od[3] | ~key_V) &
    (pa_out_od[4] | ~key_N) &
    (pa_out_od[5] | ~(key_comma | key_angle_left)) &
    (pa_out_od[6] | ~(key_slash | key_question)) &
    (pa_out_od[7] | ~key_runstop)
   );

always @(posedge clk) begin
  if (reset) begin
    hid_counter <= 3;

    ps2_extended <= 1'b0;
    ps2_pressed  <= 1'b1;

    key_restore   <= 1'b0;
    key_tape_play <= 1'b0;

    key_return    <= 1'b0;
    key_space     <= 1'b0;
    key_runstop   <= 1'b0;

    key_left      <= 1'b0;
    key_right     <= 1'b0;
    key_up        <= 1'b0;
    key_down      <= 1'b0;

    key_1         <= 1'b0;
    key_2         <= 1'b0;
    key_3         <= 1'b0;
    key_4         <= 1'b0;
    key_5         <= 1'b0;
    key_6         <= 1'b0;
    key_7         <= 1'b0;
    key_8         <= 1'b0;
    key_9         <= 1'b0;
    key_0         <= 1'b0;

    key_F1        <= 1'b0;
    key_F2        <= 1'b0;
    key_F3        <= 1'b0;
    key_F4        <= 1'b0;
    key_F5        <= 1'b0;
    key_F6        <= 1'b0;
    key_F7        <= 1'b0;
    key_F8        <= 1'b0;

    key_Q         <= 1'b0;
    key_W         <= 1'b0;
    key_E         <= 1'b0;
    key_R         <= 1'b0;
    key_T         <= 1'b0;
    key_Y         <= 1'b0;
    key_U         <= 1'b0;
    key_I         <= 1'b0;
    key_O         <= 1'b0;
    key_P         <= 1'b0;

    key_A         <= 1'b0;
    key_S         <= 1'b0;
    key_D         <= 1'b0;
    key_F         <= 1'b0;
    key_G         <= 1'b0;
    key_H         <= 1'b0;
    key_J         <= 1'b0;
    key_K         <= 1'b0;
    key_L         <= 1'b0;

    key_Z         <= 1'b0;
    key_X         <= 1'b0;
    key_C         <= 1'b0;
    key_V         <= 1'b0;
    key_B         <= 1'b0;
    key_M         <= 1'b0;
    key_N         <= 1'b0;

    key_exclamation        <= 1'b0;
    key_at                 <= 1'b0;
    key_hash               <= 1'b0;
    key_dollar             <= 1'b0;
    key_percent            <= 1'b0;
    key_arrow_left         <= 1'b0;
    key_arrow_up           <= 1'b0;
    key_and                <= 1'b0;
    key_star               <= 1'b0;
    key_parenthesis_left   <= 1'b0;
    key_parenthesis_right  <= 1'b0;

    key_comma              <= 1'b0;
    key_dot                <= 1'b0;
    key_angle_left         <= 1'b0;
    key_angle_right        <= 1'b0;
    key_slash              <= 1'b0;
    key_question           <= 1'b0;

    key_semicolon          <= 1'b0;
    key_colon              <= 1'b0;
    key_quote              <= 1'b0;

    key_bracket_left       <= 1'b0;
    key_bracket_right      <= 1'b0;

    key_minus              <= 1'b0;
    key_equal              <= 1'b0;
    key_plus               <= 1'b0;

    key_home               <= 1'b0;
    key_cls                <= 1'b0;
    key_del                <= 1'b0;
    key_ins                <= 1'b0;

    key_pound              <= 1'b0;

    key_caps               <= 1'b0;
    key_ctrl               <= 1'b0;
    key_commodore          <= 1'b0;

    key_shiftl             <= 1'b0;
    key_shiftr             <= 1'b0;
    key_shift              <= 1'b0;

  end else if (ps2_fifo_rd_en && ps2_fifo_rd_valid) begin
    if (ps2_fifo_rd_data == 8'hE0) begin
      ps2_extended <= 1'b1;

    end else if (ps2_fifo_rd_data == 8'hF0) begin
      ps2_pressed <= 1'b0;

    end else if (ps2_fifo_rd_data == 8'h0D) begin
      key_commodore <= 1'b1;

    end else begin
      ps2_extended <= 1'b0;
      ps2_pressed  <= 1'b1;

      if (!ps2_pressed) begin
        key_commodore <= 1'b0;
      end

      case (ps2_fifo_rd_data)
        8'h05: key_F1 <= ps2_pressed;
        8'h06: key_F2 <= ps2_pressed;
        8'h04: key_F3 <= ps2_pressed;
        8'h0C: key_F4 <= ps2_pressed;
        8'h03: key_F5 <= ps2_pressed;
        8'h0B: key_F6 <= ps2_pressed;
        8'h83: key_F7 <= ps2_pressed;
        8'h0A: key_F8 <= ps2_pressed;
        8'h75: if (ps2_extended) begin
          key_up <= ps2_pressed;
        end
        8'h72: if (ps2_extended) begin
          key_down <= ps2_pressed;
        end
        8'h6B: if (ps2_extended) begin
          key_left <= ps2_pressed;
        end
        8'h74: if (ps2_extended) begin
          key_right <= ps2_pressed;
        end
        8'h4E: begin
          key_minus <= ps2_pressed & ~mod_shift;
          key_tape_play <= ps2_pressed & mod_shift;
        end
        8'h54: begin
          key_bracket_left <= ps2_pressed & ~mod_shift;
          key_arrow_left <= ps2_pressed & mod_shift;
        end
        8'h5b: begin
          key_bracket_right <= ps2_pressed & ~mod_shift;
          key_F1 <= ps2_pressed & mod_shift;
        end
        8'h55: begin
          key_equal <= ps2_pressed & ~mod_shift;
          key_plus <= ps2_pressed & mod_shift;
        end
        8'h12: begin key_shiftl <= ps2_pressed; key_shift <= key_shift & ps2_pressed; end
        8'h59: begin key_shiftr <= ps2_pressed; key_shift <= key_shift & ps2_pressed; end
        8'h14: key_ctrl <= ps2_pressed;
        8'h15: begin key_Q <= ps2_pressed; key_shift <= mod_shift; end
        8'h1D: begin key_W <= ps2_pressed; key_shift <= mod_shift; end
        8'h24: begin key_E <= ps2_pressed; key_shift <= mod_shift; end
        8'h2D: begin key_R <= ps2_pressed; key_shift <= mod_shift; end
        8'h2C: begin key_T <= ps2_pressed; key_shift <= mod_shift; end
        8'h35: begin key_Y <= ps2_pressed; key_shift <= mod_shift; end
        8'h3C: begin key_U <= ps2_pressed; key_shift <= mod_shift; end
        8'h43: begin key_I <= ps2_pressed; key_shift <= mod_shift; end
        8'h44: begin key_O <= ps2_pressed; key_shift <= mod_shift; end
        8'h4D: begin key_P <= ps2_pressed; key_shift <= mod_shift; end
        8'h1C: begin key_A <= ps2_pressed; key_shift <= mod_shift; end
        8'h1B: begin key_S <= ps2_pressed; key_shift <= mod_shift; end
        8'h23: begin key_D <= ps2_pressed; key_shift <= mod_shift; end
        8'h2B: begin key_F <= ps2_pressed; key_shift <= mod_shift; end
        8'h34: begin key_G <= ps2_pressed; key_shift <= mod_shift; end
        8'h33: begin key_H <= ps2_pressed; key_shift <= mod_shift; end
        8'h3B: begin key_J <= ps2_pressed; key_shift <= mod_shift; end
        8'h42: begin key_K <= ps2_pressed; key_shift <= mod_shift; end
        8'h4B: begin key_L <= ps2_pressed; key_shift <= mod_shift; end
        8'h1A: begin key_Z <= ps2_pressed; key_shift <= mod_shift; end
        8'h22: begin key_X <= ps2_pressed; key_shift <= mod_shift; end
        8'h21: begin key_C <= ps2_pressed; key_shift <= mod_shift; end
        8'h2A: begin key_V <= ps2_pressed; key_shift <= mod_shift; end
        8'h32: begin key_B <= ps2_pressed; key_shift <= mod_shift; end
        8'h31: begin key_N <= ps2_pressed; key_shift <= mod_shift; end
        8'h3A: begin key_M <= ps2_pressed; key_shift <= mod_shift; end
        8'h16: begin
          key_1 <= ps2_pressed & ~mod_shift;
          key_exclamation <= ps2_pressed & mod_shift;
        end
        8'h1E: begin
          key_2 <= ps2_pressed & ~mod_shift;
          key_at <= ps2_pressed & mod_shift;
        end
        8'h26: begin
          key_3 <= ps2_pressed & ~mod_shift;
          key_hash <= ps2_pressed & mod_shift;
        end
        8'h25: begin
          key_4 <= ps2_pressed & ~mod_shift;
          key_dollar <= ps2_pressed & mod_shift;
        end
        8'h2E: begin
          key_5 <= ps2_pressed & ~mod_shift;
          key_percent <= ps2_pressed & mod_shift;
        end
        8'h36: begin
          key_6 <= ps2_pressed & ~mod_shift;
          key_arrow_up <= ps2_pressed & mod_shift;
        end
        8'h3D: begin
          key_7 <= ps2_pressed & ~mod_shift;
          key_and <= ps2_pressed & mod_shift;
        end
        8'h3E: begin
          key_8 <= ps2_pressed & ~mod_shift;
          key_star <= ps2_pressed & mod_shift;
        end
        8'h46: begin
          key_9 <= ps2_pressed & ~mod_shift;
          key_parenthesis_left <= ps2_pressed & mod_shift;
        end
        8'h45: begin
          key_0 <= ps2_pressed & ~mod_shift;
          key_parenthesis_right <= ps2_pressed & mod_shift;
        end
        8'h29: key_space <= ps2_pressed;
        8'h5A: key_return <= ps2_pressed;
        8'h66: key_del <= ps2_pressed;
        8'h71: if (ps2_extended) begin
          key_del <= ps2_pressed;
        end
        8'h69: if (ps2_extended) begin
          key_restore <= ps2_pressed;
        end
        8'h6C: if (ps2_extended) begin
          key_home <= ps2_pressed & ~mod_shift;
          key_cls <= ps2_pressed & mod_shift;
        end
        8'h70: if (ps2_extended) begin
          key_ins <= ps2_pressed;
        end
        8'h41: begin
          key_comma <= ps2_pressed & ~mod_shift;
          key_angle_left <= ps2_pressed & mod_shift;
        end
        8'h49: begin
          key_dot <= ps2_pressed & ~mod_shift;
          key_angle_right <= ps2_pressed & mod_shift;
        end
        8'h4A: begin
          key_slash <= ps2_pressed & ~mod_shift;
          key_question <= ps2_pressed & mod_shift;
        end
        8'h4C: begin
          key_colon <= ps2_pressed & mod_shift;
          key_semicolon <= ps2_pressed & ~mod_shift;
        end
        8'h11: key_commodore <= ps2_pressed;
        8'h58: key_caps <= ps2_pressed;
        8'h5D: begin
          key_runstop <= ps2_pressed;
          key_shift <= mod_shift;
          key_tape_play <= ps2_pressed & mod_shift;
        end
        8'h52: begin
          key_pound <= ps2_pressed & ~mod_shift;
          key_quote <= ps2_pressed & mod_shift;
        end
        8'h76: begin
          key_runstop <= ps2_pressed;
          key_restore <= ps2_pressed;
        end
        default: ;
      endcase
    end
  end else if (hid_enable) begin
    hid_key_modifiers_i <= hid_key_modifiers;

    if (hid_key_modifiers[0] != hid_key_modifiers_i[0])
      key_ctrl <= hid_key_modifiers[0];

    if (hid_key_modifiers[4] != hid_key_modifiers_i[4])
      key_ctrl <= hid_key_modifiers[4];

    if (hid_key_modifiers[1] != hid_key_modifiers_i[1]) begin
      key_shiftl <= hid_key_modifiers[1];

      if (!hid_key_modifiers[1])
        key_shift <= 0;
    end

    if (hid_key_modifiers[5] != hid_key_modifiers_i[5]) begin
      key_shiftr <= hid_key_modifiers[5];

      if (!hid_key_modifiers[5])
        key_shift <= 0;
    end

    if (hid_key_modifiers[2] != hid_key_modifiers_i[2])
      key_commodore <= hid_key_modifiers[2];

    if (hid_key_modifiers[6] != hid_key_modifiers_i[6])
      key_commodore <= hid_key_modifiers[2];

    if (hid_key_modifiers_i == hid_key_modifiers) begin
      if (!hid_changed) begin
        hid_counter             <= hid_counter - 1;
        hid_keys_i[hid_counter] <= hid_keys[hid_counter];

      end else begin
        hid_keys_i[hid_counter] <= 8'h00;
      end

      case (hid_key)
        8'h04: begin key_A <= hid_pressed; key_shift <= mod_shift; end
        8'h05: begin key_B <= hid_pressed; key_shift <= mod_shift; end
        8'h06: begin key_C <= hid_pressed; key_shift <= mod_shift; end
        8'h07: begin key_D <= hid_pressed; key_shift <= mod_shift; end
        8'h08: begin key_E <= hid_pressed; key_shift <= mod_shift; end
        8'h09: begin key_F <= hid_pressed; key_shift <= mod_shift; end
        8'h0A: begin key_G <= hid_pressed; key_shift <= mod_shift; end
        8'h0B: begin key_H <= hid_pressed; key_shift <= mod_shift; end
        8'h0C: begin key_I <= hid_pressed; key_shift <= mod_shift; end
        8'h0D: begin key_J <= hid_pressed; key_shift <= mod_shift; end
        8'h0E: begin key_K <= hid_pressed; key_shift <= mod_shift; end
        8'h0F: begin key_L <= hid_pressed; key_shift <= mod_shift; end
        8'h10: begin key_M <= hid_pressed; key_shift <= mod_shift; end
        8'h11: begin key_N <= hid_pressed; key_shift <= mod_shift; end
        8'h12: begin key_O <= hid_pressed; key_shift <= mod_shift; end
        8'h13: begin key_P <= hid_pressed; key_shift <= mod_shift; end
        8'h14: begin key_Q <= hid_pressed; key_shift <= mod_shift; end
        8'h15: begin key_R <= hid_pressed; key_shift <= mod_shift; end
        8'h16: begin key_S <= hid_pressed; key_shift <= mod_shift; end
        8'h17: begin key_T <= hid_pressed; key_shift <= mod_shift; end
        8'h18: begin key_U <= hid_pressed; key_shift <= mod_shift; end
        8'h19: begin key_V <= hid_pressed; key_shift <= mod_shift; end
        8'h1A: begin key_W <= hid_pressed; key_shift <= mod_shift; end
        8'h1B: begin key_X <= hid_pressed; key_shift <= mod_shift; end
        8'h1C: begin key_Y <= hid_pressed; key_shift <= mod_shift; end
        8'h1D: begin key_Z <= hid_pressed; key_shift <= mod_shift; end
        8'h1E: begin
          key_1 <= hid_pressed & ~mod_shift;
          key_exclamation <= hid_pressed & mod_shift;
        end
        8'h1F: begin
          key_2 <= hid_pressed & ~mod_shift;
          key_at <= hid_pressed & mod_shift;
        end
        8'h20: begin
          key_3 <= hid_pressed & ~mod_shift;
          key_hash <= hid_pressed & mod_shift;
        end
        8'h21: begin
          key_4 <= hid_pressed & ~mod_shift;
          key_dollar <= hid_pressed & mod_shift;
        end
        8'h22: begin
          key_5 <= hid_pressed & ~mod_shift;
          key_percent <= hid_pressed & mod_shift;
        end
        8'h23: begin
          key_6 <= hid_pressed & ~mod_shift;
          key_arrow_up <= hid_pressed & mod_shift;
        end
        8'h24: begin
          key_7 <= hid_pressed & ~mod_shift;
          key_and <= hid_pressed & mod_shift;
        end
        8'h25: begin
          key_8 <= hid_pressed & ~mod_shift;
          key_star <= hid_pressed & mod_shift;
        end
        8'h26: begin
          key_9 <= hid_pressed & ~mod_shift;
          key_parenthesis_left <= hid_pressed & mod_shift;
        end
        8'h27: begin
          key_0 <= hid_pressed & ~mod_shift;
          key_parenthesis_right <= hid_pressed & mod_shift;
        end
        8'h28, 8'h58: begin key_return <= hid_pressed; key_shift <= mod_shift; end
        8'h29: begin
          key_runstop <= hid_pressed;
          key_restore <= hid_pressed;
        end
        8'h2A: begin key_del <= hid_pressed; key_shift <= mod_shift; end
        8'h2B: begin key_restore <= hid_pressed; key_shift <= mod_shift; end
        8'h2C: begin key_space <= hid_pressed; key_shift <= mod_shift; end
        8'h2D: begin
          key_minus <= hid_pressed & ~mod_shift;
          key_tape_play <= hid_pressed & mod_shift;
        end
        8'h2E: begin
          key_equal <= hid_pressed & ~mod_shift;
          key_plus <= hid_pressed & mod_shift;
        end
        8'h2F: begin
          key_bracket_left <= hid_pressed & ~mod_shift;
          key_arrow_left <= hid_pressed & mod_shift;
        end
        8'h30: begin
          key_bracket_right <= hid_pressed & ~mod_shift;
          key_F1 <= hid_pressed & mod_shift;
        end
        8'h32: begin
          key_runstop <= hid_pressed;
          key_shift <= mod_shift;
          key_tape_play <= hid_pressed & mod_shift;
        end
        8'h33: begin
          key_colon <= hid_pressed & mod_shift;
          key_semicolon <= hid_pressed & ~mod_shift;
        end
        8'h34: begin
          key_pound <= hid_pressed & ~mod_shift;
          key_quote <= hid_pressed & mod_shift;
        end
        8'h35: begin key_runstop <= hid_pressed; key_shift <= mod_shift; end
        8'h36: begin
          key_comma <= hid_pressed & ~mod_shift;
          key_angle_left <= hid_pressed & mod_shift;
        end
        8'h37: begin
          key_dot <= hid_pressed & ~mod_shift;
          key_angle_right <= hid_pressed & mod_shift;
        end
        8'h38: begin
          key_slash <= hid_pressed & ~mod_shift;
          key_question <= hid_pressed & mod_shift;
        end
        8'h39: key_caps <= hid_pressed;
        8'h3A: key_F1 <= hid_pressed;
        8'h3B: key_F2 <= hid_pressed;
        8'h3C: key_F3 <= hid_pressed;
        8'h3D: key_F4 <= hid_pressed;
        8'h3E: key_F5 <= hid_pressed;
        8'h3F: key_F6 <= hid_pressed;
        8'h40: key_F7 <= hid_pressed;
        8'h41: key_F8 <= hid_pressed;
        8'h49: key_ins <= hid_pressed;
        8'h4A: begin
          key_home <= hid_pressed & ~mod_shift;
          key_cls <= hid_pressed & mod_shift;
        end
        8'h4C: key_del <= hid_pressed;
        8'h4F: key_right <= hid_pressed;
        8'h50: key_left <= hid_pressed;
        8'h51: key_down <= hid_pressed;
        8'h52: key_up <= hid_pressed;
        default: ;
      endcase
    end
  end else if (shift) begin
    key_shift <= 0;
  end
end

always @(posedge clk) begin
  if (reset)
    hid_enable <= 1'b0;
  else if (enable && hid_key_report)
    hid_enable <= 1'b1;
  else if (hid_counter == 0 && !hid_changed)
    hid_enable <= 1'b0;
end

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
