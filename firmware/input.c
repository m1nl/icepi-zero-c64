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
#include "spi_hid.h"

static volatile uint8_t hid_keycode = 0;
static volatile uint8_t hid_ascii_pending = 0;
static volatile uint8_t hid_modifiers = 0;

static volatile uint8_t hid_control_state = 0;
static volatile char hid_control_pending[10];
static volatile int8_t hid_fkey_pending = -1;

static volatile uint8_t alt_callback_pending = 0;

#define HID_MOD_ALT (0x04 | 0x40)
#define HID_MOD_CTRL (0x01 | 0x10)

static void (*alt_callback)(char) = 0;
static void (*reset_callback)(void) = 0;
static uint8_t spi_modifiers;
static uint8_t spi_forwarded[32];
static uint8_t spi_print_down, spi_pause_down;
#define OVERLAY_MASK (1u << 6)
static void handle_spi_key(uint8_t event, uint8_t usage, const uint8_t *ps2, uint8_t length);

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

static int8_t hid_keycode_to_fkey(uint8_t keycode) {
    if (keycode >= 0x3A && keycode <= 0x45)
        return keycode - 0x3A;
    return -1;
}

static uint8_t hid_keycode_to_control(uint8_t keycode) {
    switch (keycode) {
        case 0x51:
            return 'B'; // down
        case 0x52:
            return 'A'; // up
        case 0x50:
            return 'D'; // left
        case 0x4f:
            return 'C'; // right
    }
    return 0;
}

static void write_ps2(char c) {
    c64_control_ps2_character_data_write(c);
    c64_control_ps2_character_valid_write(~c64_control_ps2_character_valid_read());
    // The C64 keyboard consumes one PS/2 byte at 120 Hz. Pace foreground
    // writes so its 16-byte input queue cannot fill; IRQ reception stays live.
    busy_wait(9);
}

#define PS2_F0 0xF0
#define PS2_E0 0xE0
#define PS2_SHIFT 0x12
#define PS2_CTRL 0x14

static const uint8_t fkey_ps2[12] = {
    0x05, 0x06, 0x04, 0x0C, // F1-F4
    0x03, 0x0B, 0x83, 0x0A, // F5-F8
    0x01, 0x09, 0x78, 0x07, // F9-F12
};

static void send_ps2_fkey(int n) {
    if (n < 0 || n > 11)
        return;
    uint8_t scan = fkey_ps2[n];
    write_ps2(scan);
    busy_wait(10);
    write_ps2(PS2_F0);
    write_ps2(scan);
}

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
void input_register_reset_callback(void (*callback)(void)) { reset_callback = callback; }

static int vt_num_to_fkey(int num) {
    switch (num) {
        case 11:
            return 0;
        case 12:
            return 1;
        case 13:
            return 2;
        case 14:
            return 3;
        case 15:
            return 4;
        case 17:
            return 5;
        case 18:
            return 6;
        case 19:
            return 7;
        case 20:
            return 8;
        case 21:
            return 9;
        case 23:
            return 10;
        case 24:
            return 11;
    }
    return -1;
}

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
            } else if (c3 >= '0' && c3 <= '9') {
                int num = c3 - '0';
                char cx;
                while ((cx = input_block()) != '~' && cx >= '0' && cx <= '9')
                    num = num * 10 + (cx - '0');
                int fkey = vt_num_to_fkey(num);
                if (fkey >= 0)
                    send_ps2_fkey(fkey);
                return 0;
            }
            if (c3)
                send_ps2_for_char(c3);
        } else if (c2 == 'O') {
            char c3 = input_block();
            if (c3 == 'P') {
                send_ps2_fkey(0);
                return 0;
            }
            if (c3 == 'Q') {
                send_ps2_fkey(1);
                return 0;
            }
            if (c3 == 'R') {
                send_ps2_fkey(2);
                return 0;
            }
            if (c3 == 'S') {
                send_ps2_fkey(3);
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
    for (;;) {
        char c = input_nonblock();
        if (c)
            return c;
        spi_hid_service(handle_spi_key);
        busy_wait(1);
    }
}

// Both native USB HID and the companion use the same console translation.
static void hid_process_press(uint8_t keycode, uint8_t modifiers) {
    uint8_t ascii = 0;
    uint8_t control = 0;

    int8_t fkey = hid_keycode_to_fkey(keycode);

    if (modifiers & HID_MOD_CTRL && ((ascii = hid_keycode_to_ascii(keycode, modifiers)))) {
        switch (ascii) {
            case 'c':
                hid_ascii_pending = 0x03;
                break;
            case 'r':
                hid_ascii_pending = 0x12;
                break;
        }

    } else if (modifiers & HID_MOD_ALT && ((ascii = hid_keycode_to_ascii(keycode, modifiers)))) {
        alt_callback_pending = ascii;
    } else if (fkey >= 0) {
        if (c64_control_flags_read() & OVERLAY_MASK) {
            static const uint8_t numbers[12] = {11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23, 24};
            hid_control_pending[0] = '\x1b';
            hid_control_pending[1] = '[';
            hid_control_pending[2] = '0' + numbers[fkey] / 10;
            hid_control_pending[3] = '0' + numbers[fkey] % 10;
            hid_control_pending[4] = '~';
            hid_control_pending[5] = '\0';
            hid_control_state = 0;
        } else {
            hid_fkey_pending = fkey;
        }
    } else if ((ascii = hid_keycode_to_ascii(keycode, modifiers))) {
        hid_ascii_pending = ascii;
    } else if ((control = hid_keycode_to_control(keycode))) {
        hid_control_pending[0] = '\x1b';
        hid_control_pending[1] = '[';
        hid_control_pending[2] = control;
        hid_control_pending[3] = '\0';
        hid_control_state = 0;
    }
}

static void sync_spi_modifiers(void) {
    static const uint16_t scans[8] = {0x14, 0x12, 0x11, 0x11f, 0x114, 0x59, 0x111, 0x127};

    for (uint8_t i = 0; i < 8; i++) {
        uint8_t bit = 1u << i;

        // Modifier usages E0..E7 share the last byte of the forwarded bitmap.
        if ((spi_modifiers & bit) && !(spi_forwarded[28] & bit)) {
            if (scans[i] & 0x100)
                write_ps2(PS2_E0);

            write_ps2((char)scans[i]);
            spi_forwarded[28] |= bit;
        }
    }
}

static void handle_spi_key(uint8_t event, uint8_t usage, const uint8_t *ps2, uint8_t length) {
    int pressed = !(event & 0x80);
    int modifier = usage < 8 && (event & 0x7f) == 0x68 + usage;

    if (modifier) {
        if (pressed)
            spi_modifiers |= 1u << usage;
        else
            spi_modifiers &= ~(1u << usage);
        usage += 0xe0;
    }

    // Handle these globally and consume both their make and break packets.
    // Their synthetic PS/2 Shift/Ctrl bytes must never reach the C64 decoder.
    if (!modifier && usage == 0x46) {
        if (pressed && !spi_print_down) {
            uint32_t flags = c64_control_flags_read() ^ OVERLAY_MASK;
            c64_control_flags_write(flags);
            if (!(flags & OVERLAY_MASK))
                sync_spi_modifiers();
        }
        spi_print_down = pressed;
        return;
    }

    if (!modifier && usage == 0x48) {
        if (pressed && !spi_pause_down && reset_callback) {
            reset_callback();
            memset(spi_forwarded, 0, sizeof(spi_forwarded));
        }
        spi_pause_down = pressed;
        return;
    }

    uint8_t *forwarded = &spi_forwarded[usage >> 3];
    uint8_t bit = 1u << (usage & 7);

    if (!pressed) {
        // A key pressed before opening the overlay still needs its break.
        // Keys captured by the overlay must not leak a break after closing it.
        if (*forwarded & bit) {
            for (uint8_t i = 0; i < length; i++)
                write_ps2((char)ps2[i]);
            *forwarded &= ~bit;
        }
        return;
    }

    if (c64_control_flags_read() & OVERLAY_MASK) {
        if (!modifier)
            hid_process_press(usage, spi_modifiers);
        return;
    }

    // Restore modifiers held across closing the overlay or resetting the C64.
    if (!modifier)
        sync_spi_modifiers();

    for (uint8_t i = 0; i < length; i++)
        write_ps2((char)ps2[i]);

    if (length)
        *forwarded |= bit;
}

void __attribute__((section(".sramfunc"), noinline)) input_isr(uint32_t pending) {
    if (pending & EV_HID_KEY) {
        uint8_t keycode = c64_control_hid_key_0_read();
        hid_modifiers = c64_control_hid_key_modifiers_read();

        if (hid_keycode != keycode) {
            hid_keycode = keycode;
            hid_process_press(keycode, hid_modifiers);
        }
    }
}

void input_init(void) {
    spi_hid_init();
    spi_modifiers = spi_print_down = spi_pause_down = 0;
    memset(spi_forwarded, 0, sizeof(spi_forwarded));
    hid_control_state = 0;
    hid_fkey_pending = -1;
    memset((void *)hid_control_pending, 0, sizeof(hid_control_pending));

    c64_control_ev_enable_write(c64_control_ev_enable_read() | EV_HID_KEY);
}

int input_service(void) {
    spi_hid_service(handle_spi_key);

    if (alt_callback_pending) {
        fputc('\n', stdout);
        if (alt_callback)
            alt_callback((char)alt_callback_pending);
        alt_callback_pending = 0;
        return 1;
    }

    if (hid_fkey_pending >= 0) {
        send_ps2_fkey(hid_fkey_pending);
        hid_fkey_pending = -1;
        return 1;
    }

    return 0;
}
