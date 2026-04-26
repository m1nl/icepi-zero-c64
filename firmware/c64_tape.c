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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <system.h>

#include <generated/csr.h>
#include <irq.h>

#include "ff.h"
#include "spisdcard.h"

#include "c64_event.h"
#include "c64_tape.h"

#define TAP_FILE_PADDING_LENGTH 32  // pad TAP file with some additional delays
#define TAP_FILE_PADDING_VALUE 0x2a // pad TAP file with some additional delays

static uint8_t *tap_data;
static uint32_t tap_size;
static volatile int tap_play_running;
static volatile int tap_play_running_next;

void c64_tape_isr(uint32_t pending) {
    if (pending & EV_TAPE_STOP) {
        tap_play_running_next = 0;
    }

    if (pending & EV_TAPE_PLAY) {
        if (tap_data && !tap_play_running) {
            tap_play_running_next = 1;

        } else {
            tap_play_running_next = 0;
        }
    }
}

static void c64_tape_stop(void) {
    tap_dma_enable_write(0);
    busy_wait(5);

    if (c64_control_tape_cass_sense_read()) {
        c64_control_tape_play_write(~c64_control_tape_play_read());
    }
}

static void c64_tape_start(void) {
    tap_dma_enable_write(0);
    tap_dma_base_write((uint64_t)(uintptr_t)tap_data);
    tap_dma_length_write(tap_size);
    tap_dma_loop_write(0);
    tap_dma_enable_write(1);
    busy_wait(5);

    if (!c64_control_tape_cass_sense_read()) {
        c64_control_tape_play_write(~c64_control_tape_play_read());
    }
}

int c64_tape_load(const char *path) {
    static FATFS fs;
    FIL fil;
    FRESULT res;
    UINT br;
    int ret = -1;

    c64_tape_stop();

    res = f_mount(&fs, "", 1);
    if (res != FR_OK) {
        printf("c64_tape_load: sdcard mount failed (err %d)\n", res);
        return -1;
    }

    res = f_open(&fil, path, FA_READ);
    if (res != FR_OK) {
        printf("c64_tape_load: cannot open '%s' (err %d)\n", path, res);
        goto unmount;
    }

    uint32_t size = f_size(&fil);

    if (tap_data) {
        free(tap_data);
        tap_data = NULL;
        tap_size = 0;
    }

    tap_data = malloc(size + TAP_FILE_PADDING_LENGTH);
    if (!tap_data) {
        printf("c64_tape_load: malloc failed for %lu bytes\n", (unsigned long)(size + TAP_FILE_PADDING_LENGTH));
        f_close(&fil);
        goto unmount;
    }

    res = f_read(&fil, tap_data, size, &br);
    f_close(&fil);

    if (res != FR_OK || br != size) {
        printf("c64_tape_load: read failed (err %d, got %u of %lu)\n", res, br, (unsigned long)size);
        free(tap_data);
        tap_data = NULL;
        goto unmount;
    }

    memset(tap_data + size, TAP_FILE_PADDING_VALUE, TAP_FILE_PADDING_LENGTH);
    tap_size = size + TAP_FILE_PADDING_LENGTH;

    flush_cpu_dcache();
    flush_l2_cache();

    printf("c64_tape_load: loaded '%s' (%lu bytes)\n", path, (unsigned long)tap_size);
    ret = 0;

unmount:
    f_unmount("");
    return ret;
}

void c64_tape_eject(void) {
    c64_tape_stop();

    if (tap_data) {
        free(tap_data);
        tap_data = NULL;
        tap_size = 0;
    }
}

void c64_tape_init(void) { c64_control_ev_enable_write(c64_control_ev_enable_read() | EV_TAPE_PLAY | EV_TAPE_STOP); }

int c64_tape_service(void) {
    if (tap_play_running_next && !tap_play_running) {
        fputs("\n", stdout);
        c64_tape_start();
        tap_play_running = 1;
        printf("c64_tape: play started\n");
        return 1;
    }

    if (!tap_play_running_next && tap_play_running) {
        fputs("\n", stdout);
        c64_tape_stop();
        tap_play_running = 0;
        printf("c64_tape: play stopped\n");
        return 1;
    }

    return 0;
}
