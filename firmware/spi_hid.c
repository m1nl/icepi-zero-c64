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
// Co-developed by GPT-6.1 Sol
// ---------------------------------------------------------------------------
// FPGA-Companion SPI HID reports -> C64 keyboard events and joystick state.
// ---------------------------------------------------------------------------

#include <generated/csr.h>
#include <generated/mem.h>
#include <irq.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "spi_hid.h"

#define SRAM_FUNC __attribute__((section(".sramfunc"), noinline))
#define REPORT_CAPACITY 12 /* Four header bytes + eight-byte Pause make. */
#define QUEUE_SIZE 32
#define QUEUE_MASK (QUEUE_SIZE - 1)
#define RECEIVING 2

#ifndef SPI_HID_DEBUG
#define SPI_HID_DEBUG 0
#endif

// VexRiscv drives SEL=1111 on every load, including byte loads. Read the
// aligned 32-bit FIFO port and take bits 7:0; nonzero byte offsets otherwise
// extract zeros from the peripheral's zero-extended response.
#ifndef SPI_HID_READ32
#define SPI_HID_READ32(offset) (*(volatile uint32_t *)(SPI_REPORT_BASE + (offset)))
#endif

#define HEAD_INFO_OFFSET 12
#define HEAD_START 1u
#define HEAD_LEVEL_MASK 0x1eu
#define HEAD_OVERRUN_MASK (~31u)

static uint32_t last_overrun;
static uint8_t report[REPORT_CAPACITY];
static uint8_t report_length;
static uint8_t report_active;

struct ps2_sequence {
    uint8_t length;
    uint8_t event;
    uint8_t usage;
    uint8_t bytes[8];
};

// IRQ produces complete sequences; foreground consumes them. Keep PS/2
// prefixes and their key bytes together, including when console input runs.
static struct ps2_sequence queue[QUEUE_SIZE];
static volatile uint8_t queue_head;
static volatile uint8_t queue_tail;
static volatile uint32_t dropped_reports;

#if SPI_HID_DEBUG
#define DEBUG_QUEUE_SIZE 8
struct debug_report {
    uint8_t length;
    uint8_t reason;
    uint8_t bytes[REPORT_CAPACITY];
};
static struct debug_report debug_queue[DEBUG_QUEUE_SIZE];
static volatile uint8_t debug_head, debug_tail;
static volatile uint32_t debug_lost, debug_irq_count;

#ifdef CSR_TIMER0_UPTIME_CYCLES_ADDR
static uint64_t debug_next_status;
#endif

// Copy a bounded record in IRQ context. Serial output runs only in service().
static void SRAM_FUNC debug_capture(uint8_t reason) {
    if (!report_active)
        return;
    uint8_t head = debug_head;
    uint8_t next = (head + 1) & (DEBUG_QUEUE_SIZE - 1);
    if (next == debug_tail) {
        debug_lost++;
        return;
    }
    debug_queue[head].length = report_length;
    debug_queue[head].reason = reason;
    for (uint8_t i = 0; i < report_length; i++)
        debug_queue[head].bytes[i] = report[i];
    __asm__ volatile("" ::: "memory");
    debug_head = next;
}

static void debug_service(void) {
    uint8_t tail = debug_tail;
    if (tail != debug_head) {
        __asm__ volatile("" ::: "memory");
        struct debug_report entry = debug_queue[tail];
        debug_tail = (tail + 1) & (DEBUG_QUEUE_SIZE - 1);
        const char *reason = entry.reason == 1 ? "partial/overrun" : entry.reason == 2 ? "oversize" : "report";
        printf("[spi] %s len=%u:", reason, (unsigned int)entry.length);
        for (uint8_t i = 0; i < entry.length; i++)
            printf(" %02x", (unsigned int)entry.bytes[i]);
        printf("\n");
    }

#ifdef CSR_TIMER0_UPTIME_CYCLES_ADDR
    timer0_uptime_latch_write(1);
    uint64_t now = timer0_uptime_cycles_read();
    if (now >= debug_next_status) {
        debug_next_status = now + CONFIG_CLOCK_FREQUENCY;
        uint32_t info = SPI_HID_READ32(HEAD_INFO_OFFSET);
        printf("[spi] status=%02x bytes=%lu level=%u overruns=%lu irq=%lu "
               "dropped=%lu log_lost=%lu mask=%08x pending=%08x\n",
               (unsigned int)spi_report_status_read(), (unsigned long)SPI_HID_READ32(8),
               (unsigned int)((info >> 1) & 15), (unsigned long)(info >> 5), (unsigned long)debug_irq_count,
               (unsigned long)dropped_reports, (unsigned long)debug_lost, irq_getmask(), irq_pending());
    }
#endif
}
#else
#define debug_capture(reason) ((void)0)
#define debug_service() ((void)0)
#endif

static int SRAM_FUNC valid_sequence(const uint8_t *bytes, uint8_t length) {
    static const uint8_t print_make[] = {0xe0, 0x12, 0xe0, 0x7c};
    static const uint8_t print_break[] = {0xe0, 0xf0, 0x7c, 0xe0, 0xf0, 0x12};
    static const uint8_t pause_make[] = {0xe1, 0x14, 0x77, 0xe1, 0xf0, 0x14, 0xf0, 0x77};

    if (length == 4)
        return memcmp(bytes, print_make, 4) == 0;
    if (length == 6)
        return memcmp(bytes, print_break, 6) == 0;
    if (length == 8)
        return memcmp(bytes, pause_make, 8) == 0;
    if (length == 0 || length > 3)
        return 0;

    uint8_t key = bytes[length - 1];

    if (key == 0 || key == 0xe0 || key == 0xe1 || key == 0xf0)
        return 0;

    return length == 1 || (length == 2 && (bytes[0] == 0xe0 || bytes[0] == 0xf0)) ||
           (length == 3 && bytes[0] == 0xe0 && bytes[1] == 0xf0);
}

static void SRAM_FUNC finish_report(void) {
    if (!report_active)
        return;

    debug_capture(0);

    report_active = 0;

    if (report_length < 4 || report_length > REPORT_CAPACITY || report[0] != 1)
        return;

    if (report[1] == 3) {
        // hid.c: target, command, port, RLDUABXY, analog X/Y, extra buttons.
        if (report_length != 7 || report[2] > 1) {
            dropped_reports++;
            return;
        }

        uint8_t joy = report[3];
        uint16_t state =
            (joy & 0xf0) | ((joy & 0x01) << 3) | ((joy & 0x02) << 1) | ((joy & 0x04) >> 1) | ((joy & 0x08) >> 3);

        // Extra bits 2/3 are Back/Select and Start in companion mappings.
        state |= (uint16_t)(report[6] & 0x0c) << 6;

        // Write the whole state immediately, including releases. Keeping this
        // out of the keyboard queue avoids PS/2 pacing delaying joystick input.
        if (report[2] == 0)
            c64_control_companion_joy_a_write(state);
        else
            c64_control_companion_joy_b_write(state);
        return;
    }

    // ps2helper.c: target, command, legacy HID event, full HID usage,
    // followed by the already translated PS/2 make/break sequence.
    if (report[1] != 1)
        return;

    uint8_t length = report_length - 4;
    // Keep header-only releases (notably Pause) and unsupported usages too:
    // firmware needs their HID event even when the PS/2 suffix is empty.
    if (length && !valid_sequence(report + 4, length)) {
        dropped_reports++;
        return;
    }

    uint8_t head = queue_head;
    uint8_t next = (head + 1) & QUEUE_MASK;

    if (next == queue_tail) {
        dropped_reports++;
        return;
    }

    queue[head].length = length;
    queue[head].event = report[2];
    queue[head].usage = report[3];

    for (uint8_t i = 0; i < length; i++)
        queue[head].bytes[i] = report[4 + i];

    __asm__ volatile("" ::: "memory");
    queue_head = next;
}

void spi_hid_init(void) {
    queue_head = queue_tail = 0;
    report_active = report_length = 0;
    dropped_reports = 0;

    c64_control_companion_joy_a_write(0);
    c64_control_companion_joy_b_write(0);

#if SPI_HID_DEBUG
    debug_head = debug_tail = 0;
    debug_lost = debug_irq_count = 0;
#ifdef CSR_TIMER0_UPTIME_CYCLES_ADDR
    debug_next_status = 0;
#endif
    printf("[spi] debug enabled: base=%08lx irq=%u mode=1\n", (unsigned long)SPI_REPORT_BASE,
           (unsigned int)SPI_REPORT_INTERRUPT);
    printf("[spi] CS=GPIO18/N4 SCK=GPIO24/L1 MOSI=GPIO25/J2 "
           "MISO=GPIO21/F2 IRQN=GPIO22/P2 (unused)\n");
#endif

    // Drain up to the eight pre-initialization bytes. New traffic is parsed
    // only once its packet-start marker reaches the FIFO head.
    for (uint8_t i = 0; i < 8; i++) {
        if (!(SPI_HID_READ32(HEAD_INFO_OFFSET) & HEAD_LEVEL_MASK))
            break;
        (void)SPI_HID_READ32(0);
    }

    last_overrun = SPI_HID_READ32(HEAD_INFO_OFFSET) & HEAD_OVERRUN_MASK;
}

static void SRAM_FUNC drain_reports(void) {
    // Bound ISR work; unread bytes keep the level interrupt asserted.
    for (uint8_t i = 0; i < 32; i++) {
        uint32_t info = SPI_HID_READ32(HEAD_INFO_OFFSET);
        uint32_t overrun = info & HEAD_OVERRUN_MASK;

        if (overrun != last_overrun) {
            debug_capture(1);
            dropped_reports++;
            report_active = 0;
            last_overrun = overrun;
        }

        if (!(info & HEAD_LEVEL_MASK))
            break;
        // Each aligned word load consumes one byte and returns it in bits 7:0.
        uint8_t byte = (uint8_t)SPI_HID_READ32(0);
        uint32_t after = SPI_HID_READ32(HEAD_INFO_OFFSET);

        if ((after & HEAD_OVERRUN_MASK) != overrun) {
            // A full write changed the head between metadata and data reads.
            // Its old start marker cannot be paired safely with this byte.
            debug_capture(1);
            dropped_reports++;
            report_active = 0;
            last_overrun = after & HEAD_OVERRUN_MASK;
            continue;
        }

        if (info & HEAD_START) {
            finish_report();
            report_length = 0;
            report_active = 1;
        }

        if (report_active) {
            if (report_length < REPORT_CAPACITY)
                report[report_length++] = byte;
            else {
                debug_capture(2);
                dropped_reports++;
                report_active = 0;
            }
        }
    }

    if (!(spi_report_status_read() & RECEIVING) && !(SPI_HID_READ32(HEAD_INFO_OFFSET) & HEAD_LEVEL_MASK))
        finish_report();
}

void SRAM_FUNC spi_hid_isr(void) {
#if SPI_HID_DEBUG
    debug_irq_count++;
#endif
    drain_reports();
}

void spi_hid_service(spi_hid_key_handler handle_key) {
    // CS may rise after the final byte IRQ has already been drained. Finalize
    // that report here, briefly masking only SPI while touching parser state.
    unsigned int mask = irq_getmask();

    irq_setmask(mask & ~(1u << SPI_REPORT_INTERRUPT));
    drain_reports();
    irq_setmask(mask);
    debug_service();

    uint8_t tail = queue_tail;
    if (tail == queue_head)
        return;

    struct ps2_sequence sequence = queue[tail];

    __asm__ volatile("" ::: "memory");
    queue_tail = (tail + 1) & QUEUE_MASK;
    handle_key(sequence.event, sequence.usage, sequence.bytes, sequence.length);
}
