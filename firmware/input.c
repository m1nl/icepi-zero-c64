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

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <generated/csr.h>
#include <generated/mem.h>
#include <irq.h>
#include <libbase/console.h>
#include <libbase/uart.h>

#include "heap.h"

#include "c64_event.h"

#include "input.h"

static volatile uint8_t hid_keycode = 0;
static volatile uint8_t hid_ascii_pending = 0;
static volatile uint8_t hid_modifiers = 0;

static volatile uint8_t hid_control_state = 0;
static volatile char hid_control_pending[10];

static volatile uint8_t alt_callback_pending = 0;

#define HID_MOD_ALT (0x04 | 0x40)
#define HID_MOD_CTRL (0x01 | 0x10)

static void (*alt_callback)(char) = 0;

static const uint8_t hid_to_ascii[128] = {
    0,    0,   0,    0,    'a',  'b',  'c', 'd', 'e', 'f', 'g', 'h',  'i', 'j', 'k',  'l', 'm', 'n', 'o',
    'p',  'q', 'r',  's',  't',  'u',  'v', 'w', 'x', 'y', 'z', '1',  '2', '3', '4',  '5', '6', '7', '8',
    '9',  '0', '\n', 0x1b, '\b', '\t', ' ', '-', '=', '[', ']', '\\', 0,   ';', '\'', '`', ',', '.', '/',
    0,    0,   0,    0,    0,    0,    0,   0,   0,   0,   0,   0,    0,   0,   0,    0,   0,   0,   0,
    0x7f, 0,   0,    0,    0,    0,    0,   0,   0,   0,   0,   0,    0,   0,   0,    0,   0,   0,   0,
    0,    0,   0,    0,    0,    0,    0,   0,   0,   0,   0,   0,    0,   0,   0,    0,   0,   0,   0,
    0,    0,   0,    0,    0,    0,    0,   0,   0,   0,   0,   0,    0,   0,
};

static const uint8_t hid_to_ascii_shift[128] = {
    0,   0,   0,   0,   'A', 'B', 'C', 'D', 'E', 'F', 'G',  'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',  'P',  'Q',  'R',
    'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '!', '@', '#',  '$', '%', '^', '&', '*', '(', ')', '\n', 0x1b, '\b', '\t',
    ' ', '_', '+', '{', '}', '|', 0,   ':', '"', '~', '<',  '>', '?', 0,   0,   0,   0,   0,   0,    0,    0,    0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0x7f, 0,   0,   0,   0,   0,   0,   0,   0,    0,    0,    0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,   0,   0,   0,   0,   0,   0,   0,    0,    0,    0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,   0,   0,   0,   0,   0,   0,
};

static uint8_t hid_keycode_to_ascii(uint8_t keycode, uint8_t modifiers) {
    if (keycode >= 128)
        return 0;
    int shift = (modifiers & 0x22) != 0;
    return shift ? hid_to_ascii_shift[keycode] : hid_to_ascii[keycode];
}

static uint8_t hid_keycode_to_control(uint8_t keycode, uint8_t modifiers) {
    switch (keycode) {
        case 0x51:
            return 'B'; // up
        case 0x52:
            return 'A'; // down
    }
    return 0;
}

static void write_ps2(char c) {
    c64_control_ps2_character_data_write(c);
    c64_control_ps2_character_valid_write(~c64_control_ps2_character_valid_read());
    busy_wait(1);
}

#define PS2_F0 0xF0
#define PS2_E0 0xE0
#define PS2_SHIFT 0x12
#define PS2_CTRL 0x14

static const uint8_t ascii_to_ps2[128] = {
    0x00, 0x1C, 0x32, 0x21, 0x23, 0x24, 0x2B, 0x34, 0x66, 0x0D, 0x5A, 0x42, 0x4B, 0x5A, 0x31, 0x44, 0x4D, 0x15, 0x2D,
    0x1B, 0x2C, 0x3C, 0x2A, 0x1D, 0x22, 0x35, 0x1A, 0x76, 0x00, 0x00, 0x00, 0x00, 0x29, 0x16, 0x52, 0x26, 0x25, 0x2E,
    0x3D, 0x52, 0x46, 0x45, 0x3E, 0x55, 0x41, 0x4E, 0x49, 0x4A, 0x45, 0x16, 0x1E, 0x26, 0x25, 0x2E, 0x36, 0x3D, 0x3E,
    0x46, 0x4C, 0x4C, 0x41, 0x55, 0x49, 0x4A, 0x1E, 0x1C, 0x32, 0x21, 0x23, 0x24, 0x2B, 0x34, 0x33, 0x43, 0x3B, 0x42,
    0x4B, 0x3A, 0x31, 0x44, 0x4D, 0x15, 0x2D, 0x1B, 0x2C, 0x3C, 0x2A, 0x1D, 0x22, 0x35, 0x1A, 0x54, 0x5D, 0x5B, 0x36,
    0x4E, 0x0E, 0x1C, 0x32, 0x21, 0x23, 0x24, 0x2B, 0x34, 0x33, 0x43, 0x3B, 0x42, 0x4B, 0x3A, 0x31, 0x44, 0x4D, 0x15,
    0x2D, 0x1B, 0x2C, 0x3C, 0x2A, 0x1D, 0x22, 0x35, 0x1A, 0x00, 0x5D, 0x00, 0x0E, 0x66};

static int ascii_needs_shift(char c) {
    static const char shifted[] = "!@#$%^&*()_+{}|:\"<>?~";
    if (c >= 'A' && c <= 'Z')
        return 1;
    for (int i = 0; shifted[i]; i++)
        if (shifted[i] == c)
            return 1;
    return 0;
}

static int ascii_is_ctrl(char c) {
    uint8_t v = (uint8_t)c;
    if (v == '\n' || v == '\r' || v == '\t' || v == '\b' || v == 0x7f || v == 0x1b)
        return 0;
    return v >= 1 && v <= 26;
}

static void send_ps2_extended(uint8_t scan) {
    write_ps2(PS2_E0);
    write_ps2(scan);
    busy_wait(10);
    write_ps2(PS2_E0);
    write_ps2(PS2_F0);
    write_ps2(scan);
}

static void send_ps2_for_char(char c) {
    uint8_t v = (uint8_t)c;
    uint8_t scan;
    int needs_shift = 0;
    int needs_ctrl = 0;

    if (v == 0x7f) {
        write_ps2(0x66);
        busy_wait(10);
        write_ps2(PS2_F0);
        write_ps2(0x66);
        return;
    }

    if (ascii_is_ctrl(c)) {
        needs_ctrl = 1;
        uint8_t base = 'a' + v - 1;
        scan = ascii_to_ps2[(uint8_t)base];
    } else {
        if (v < 128) {
            scan = ascii_to_ps2[v];
            needs_shift = ascii_needs_shift(c);
        } else {
            return;
        }
    }

    if (!scan)
        return;

    if (needs_ctrl)
        write_ps2(PS2_CTRL);
    if (needs_shift)
        write_ps2(PS2_SHIFT);
    write_ps2(scan);
    busy_wait(10);
    write_ps2(PS2_F0);
    write_ps2(scan);
    if (needs_shift) {
        write_ps2(PS2_F0);
        write_ps2(PS2_SHIFT);
    }
    if (needs_ctrl) {
        write_ps2(PS2_F0);
        write_ps2(PS2_CTRL);
    }
}

void input_register_alt_callback(void (*callback)(char)) { alt_callback = callback; }

int c64_console(void) {
    char c;

    c = input_nonblock();

    if (c == 0x03)
        return -1;

    if (c == 0x1b) {
        char c2 = input_block();
        if (c2 == '[') {
            char c3 = input_block();
            if (c3 == 'A') {
                send_ps2_extended(0x75);
                return 0;
            } else if (c3 == 'B') {
                send_ps2_extended(0x72);
                return 0;
            } else if (c3 == 'C') {
                send_ps2_extended(0x74);
                return 0;
            } else if (c3 == 'D') {
                send_ps2_extended(0x6B);
                return 0;
            }
            if (c3)
                send_ps2_for_char(c3);
        }
        if (c2)
            send_ps2_for_char(c2);
    }

    if (c)
        send_ps2_for_char(c);

    return 0;
}

char input_nonblock(void) {
    char res;

    if ((res = hid_control_pending[hid_control_state])) {
        hid_control_state++;
        return res;
    }

    if (hid_ascii_pending) {
        res = hid_ascii_pending;
        hid_ascii_pending = 0;
        return res;
    }

    if (readchar_nonblock())
        return getchar();

    return '\0';
}

char input_block(void) {
    while (!readchar_nonblock() && hid_ascii_pending == 0) {
        busy_wait(1);
    }

    return input_nonblock();
}

void input_isr(uint32_t pending) {
    if (pending & EV_HID_KEY) {
        uint8_t keycode = c64_control_hid_key_0_read();
        if (hid_keycode != keycode) {
            uint8_t ascii = 0;
            uint8_t control = 0;

            hid_modifiers = c64_control_hid_key_modifiers_read();
            hid_keycode = keycode;

            if (hid_modifiers & HID_MOD_CTRL && ((ascii = hid_keycode_to_ascii(keycode, hid_modifiers)))) {
                switch (ascii) {
                    case 'c':
                        hid_ascii_pending = 0x03;
                        break;
                    case 'r':
                        hid_ascii_pending = 0x12;
                        break;
                }
            } else if (hid_modifiers & HID_MOD_ALT && ((ascii = hid_keycode_to_ascii(keycode, hid_modifiers))))
                alt_callback_pending = ascii;
            else if ((ascii = hid_keycode_to_ascii(keycode, hid_modifiers)))
                hid_ascii_pending = ascii;
            else if ((control = hid_keycode_to_control(keycode, hid_modifiers))) {
                hid_control_pending[0] = '\x1b';
                hid_control_pending[1] = '[';
                hid_control_pending[2] = control;
                hid_control_pending[3] = '\0';
                hid_control_state = 0;
            }
        }
    }
}

void input_init(void) {
    hid_control_state = 0;
    memset((void *)hid_control_pending, 0, sizeof(hid_control_pending));

    c64_control_ev_enable_write(c64_control_ev_enable_read() | EV_HID_KEY);
}

int input_service(void) {
    if (alt_callback_pending) {
        fputc('\n', stdout);
        alt_callback((char)alt_callback_pending);
        alt_callback_pending = 0;
        return 1;
    }
    return 0;
}
