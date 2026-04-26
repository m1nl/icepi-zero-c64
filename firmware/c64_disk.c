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

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <system.h>

#include <crc.h>
#include <generated/csr.h>
#include <irq.h>

#include "ff.h"
#include "spisdcard.h"

#include "c64_disk.h"
#include "c64_disk_internal.h"

#include "c64_event.h"

extern char _fdrive_shmem;
extern char _edrive_shmem;

#define WRITE_COMMIT_INTERVAL_CYCLES (5 * CONFIG_CLOCK_FREQUENCY) // commit changes every 5 seconds

static char *mounted_path;

static uint8_t *d64_data;
static size_t d64_size;

static volatile int d64_dirty;
static volatile uint64_t write_commit_cycles;

static void serve_lba(uint32_t lba_req, uint32_t cnt) {
    uint8_t *dst = (uint8_t *)&_fdrive_shmem;
    uint32_t buf_size = (uint32_t)(&_edrive_shmem - &_fdrive_shmem);
    uint32_t copy_bytes = cnt * D64_SECTOR_SIZE;
    uint32_t offset = lba_req * D64_SECTOR_SIZE;

    if (!d64_data || offset > d64_size) {
        memset(dst, 0, copy_bytes);
        goto exit;
    }

    if (copy_bytes > buf_size)
        copy_bytes = buf_size;

    size_t avail = d64_size - offset;
    if (copy_bytes > avail)
        copy_bytes = avail;

    memcpy(dst, d64_data + offset, copy_bytes);

exit:
    flush_cpu_dcache();
    flush_l2_cache();
}

static void store_lba(uint32_t lba_req, uint32_t cnt) {
    uint8_t *src = (uint8_t *)&_fdrive_shmem;
    uint32_t buf_size = (uint32_t)(&_edrive_shmem - &_fdrive_shmem);
    uint32_t copy_bytes = cnt * D64_SECTOR_SIZE;
    uint32_t offset = lba_req * D64_SECTOR_SIZE;

    if (!d64_data || offset > d64_size)
        return;

    if (copy_bytes > buf_size)
        copy_bytes = buf_size;

    size_t avail = d64_size - offset;
    if (copy_bytes > avail)
        copy_bytes = avail;

    memcpy(d64_data + offset, src, copy_bytes);

    d64_dirty = 1;
    timer0_uptime_latch_write(1);
    write_commit_cycles = timer0_uptime_cycles_read() + WRITE_COMMIT_INTERVAL_CYCLES;
}

void c64_disk_isr(uint32_t pending) {
    if (pending & EV_BLOCK_WR) {
        if (!c64_control_img_readonly_read()) {
            uint32_t req_lba = c64_control_block_lba_read();
            uint32_t req_cnt = c64_control_block_cnt_read();

            store_lba(req_lba, req_cnt);
        }

        c64_control_block_ack_write(~c64_control_block_ack_read());
    }

    if (pending & EV_BLOCK_RD) {
        uint32_t req_lba = c64_control_block_lba_read();
        uint32_t req_cnt = c64_control_block_cnt_read();

        serve_lba(req_lba, req_cnt);
        c64_control_block_ack_write(~c64_control_block_ack_read());
    }
}

int c64_disk_mount(const char *path, int rw) {
    static FATFS fs;
    FIL fil;
    FRESULT res;
    UINT br;
    int ret = -1;

    c64_disk_umount();

    res = f_mount(&fs, "", 1);
    if (res != FR_OK) {
        printf("c64_disk_mount: sdcard mount failed (err %d)\n", res);
        return -1;
    }

    res = f_open(&fil, path, FA_READ);
    if (res != FR_OK) {
        printf("c64_disk_mount: cannot open '%s' (err %d)\n", path, res);
        goto exit;
    }

    size_t size = f_size(&fil);

    if (d64_data) {
        free(d64_data);
        d64_data = NULL;
        d64_size = 0;
    }

    d64_data = malloc(size);
    if (!d64_data) {
        printf("c64_disk_mount: malloc failed for %u bytes\n", size);
        f_close(&fil);
        goto exit;
    }

    res = f_read(&fil, d64_data, size, &br);
    f_close(&fil);

    if (res != FR_OK || br != size) {
        printf("c64_disk_mount: read failed (err %d, got %u of %u)\n", res, br, size);
        free(d64_data);
        d64_data = NULL;
        goto exit;
    }

    mounted_path = malloc(strlen(path) + 1);
    if (!mounted_path) {
        printf("c64_disk_mount: malloc failed");
        goto exit;
    }
    strcpy(mounted_path, path);

    d64_size = size;
    d64_dirty = 0;

    uint32_t img_id = 0;
    if (d64_size > TRACK18_OFFSET + 0xA4) {
        img_id = ((uint32_t)d64_data[TRACK18_OFFSET + 0xA2] << 8) | (uint32_t)d64_data[TRACK18_OFFSET + 0xA3];
    }

    c64_control_img_size_write(d64_size);
    c64_control_img_id_write(img_id);
    c64_control_img_readonly_write(!rw);
    c64_control_img_mounted_write(~c64_control_img_mounted_read());

    printf("c64_disk_mount: mounted '%s' (%u bytes, id=0x%04lx)\n", path, d64_size, (unsigned long)img_id);
    ret = 0;

exit:
    f_unmount("");
    return ret;
}

void c64_disk_umount(void) {
    if (d64_dirty) {
        c64_disk_commit();
    }

    d64_size = 0;
    d64_dirty = 0;

    uint8_t *dst = (uint8_t *)&_fdrive_shmem;
    uint32_t buf_size = (uint32_t)(&_edrive_shmem - &_fdrive_shmem);
    memset(dst, 0, buf_size);

    if (d64_data) {
        free(d64_data);
        d64_data = NULL;
    }

    if (mounted_path) {
        free(mounted_path);
        mounted_path = NULL;
    }

    flush_cpu_dcache();
    flush_l2_cache();

    c64_control_img_size_write(0);
    c64_control_img_id_write(0);
    c64_control_img_readonly_write(0);
    c64_control_img_mounted_write(~c64_control_img_mounted_read());
}

int c64_disk_commit(void) {
    static FATFS fs;
    FIL fil;
    FRESULT res;
    UINT br, bw;
    int ret = -1;

    if (mounted_path == NULL) {
        printf("c64_disk_commit: no image mounted\n");
        d64_dirty = 0;
        return -1;
    }

    if (c64_control_img_readonly_read()) {
        printf("c64_disk_commit: image is mounted read-only\n");
        d64_dirty = 0;
        return -1;
    }

    res = f_mount(&fs, "", 1);
    if (res != FR_OK) {
        printf("c64_disk_commit: sdcard commit failed (err %d)\n", res);
        return -1;
    }

    irq_setmask(irq_getmask() & ~(1 << C64_CONTROL_INTERRUPT));

    res = f_open(&fil, mounted_path, FA_WRITE | FA_CREATE_ALWAYS);
    if (res != FR_OK) {
        printf("c64_disk_commit: cannot open '%s' (err %d)\n", mounted_path, res);
        goto exit;
    }

    res = f_write(&fil, d64_data, d64_size, &bw);
    if (res != FR_OK || bw != d64_size) {
        printf("c64_disk_commit: write error\n");
        f_close(&fil);
        goto exit;
    }

    f_close(&fil);

    int crc_mem = crc32(d64_data, d64_size);

    irq_setmask(irq_getmask() | (1 << C64_CONTROL_INTERRUPT));

    res = f_open(&fil, mounted_path, FA_READ);
    if (res != FR_OK) {
        printf("c64_disk_commit: cannot open '%s' (err %d)\n", mounted_path, res);
        goto exit;
    }

    size_t size = f_size(&fil);

    if (size != d64_size) {
        printf("c64_disk_commit: size check failed (got %u of %u)\n", size, d64_size);
        f_close(&fil);
        goto exit;
    }

    uint8_t *d64_data_written = malloc(size);
    if (!d64_data_written) {
        printf("c64_disk_commit: malloc failed for %u bytes\n", size);
        f_close(&fil);
        goto exit;
    }

    res = f_read(&fil, d64_data_written, size, &br);
    f_close(&fil);

    if (res != FR_OK || br != size) {
        printf("c64_disk_commit: read failed (err %d, got %u of %u)\n", res, br, size);
        free(d64_data_written);
        goto exit;
    }

    int crc_written = crc32(d64_data_written, size);
    free(d64_data_written);

    if (crc_mem != crc_written) {
        printf("c64_disk_commit: CRC validation failed (got %u, expected %u)\n", crc_written, crc_mem);
        goto exit;
    }

    d64_dirty = 0;

    printf("c64_disk_commit: commited '%s' (%u bytes)\n", mounted_path, d64_size);
    ret = 0;

exit:
    irq_setmask(irq_getmask() | (1 << C64_CONTROL_INTERRUPT));

    timer0_uptime_latch_write(1);
    write_commit_cycles = timer0_uptime_cycles_read() + WRITE_COMMIT_INTERVAL_CYCLES;

    f_unmount("");
    return ret;
}

static void ascii_to_petscii_upper_str(char *s, size_t len) {
    while (*s && (len--)) {
        char c = *s;

        // lowercase → uppercase
        if (c >= 'a' && c <= 'z') {
            c -= 32;
        }

        // optional: clamp to printable PETSCII range
        if (c < 0x20 || c > 0x7E) {
            c = ' '; // replace invalid chars with space
        }

        *s = c;
        s++;
    }
}

int c64_disk_format(const char *path, const char *label) {
    c64_disk_umount();

    size_t size = D64_SECTOR_SIZE * D64_SECTOR_COUNT;

    d64_data = malloc(size);
    if (!d64_data) {
        printf("c64_disk_mount: malloc failed for %u bytes\n", size);
        c64_disk_umount();
        return -1;
    }

    memset(d64_data, 0, size);

    mounted_path = malloc(strlen(path) + 1);
    if (!mounted_path) {
        printf("c64_disk_mount: malloc failed");
        c64_disk_umount();
        return -1;
    }
    strcpy(mounted_path, path);

    timer0_uptime_latch_write(1);
    uint64_t x = timer0_uptime_cycles_read() + (uint32_t)d64_data;

    // mix high and low halves
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;

    uint8_t id0 = 65 + (x % 25);
    uint8_t id1 = 65 + ((x >> 8) % 25);

    memcpy(d64_data + TRACK18_OFFSET, format_track_18, sizeof(format_track_18));
    memset(d64_data + TRACK18_OFFSET + BAM_DISK_NAME_OFFSET, BAM_DISK_NAME_PAD, BAM_DISK_NAME_SIZE);

    size_t label_len = strlen(label);

    if (label_len > BAM_DISK_NAME_SIZE)
        label_len = BAM_DISK_NAME_SIZE;

    memcpy(d64_data + TRACK18_OFFSET + BAM_DISK_NAME_OFFSET, label, label_len);
    ascii_to_petscii_upper_str((char *)d64_data + TRACK18_OFFSET + BAM_DISK_NAME_OFFSET, label_len);

    d64_data[TRACK18_OFFSET + BAM_DISK_ID_OFFSET] = id0;
    d64_data[TRACK18_OFFSET + BAM_DISK_ID_OFFSET + 1] = id1;

    d64_size = size;
    d64_dirty = 1;

    if (c64_disk_commit() < 0) {
        c64_disk_umount();
        return -1;
    }

    uint32_t img_id = (id1 << 8) | id0;

    c64_control_img_size_write(d64_size);
    c64_control_img_id_write(img_id);
    c64_control_img_readonly_write(0);
    c64_control_img_mounted_write(~c64_control_img_mounted_read());

    printf("c64_disk_format: mounted '%s' (%u bytes, id=0x%04lx)\n", path, d64_size, (unsigned long)img_id);

    return 0;
}

void c64_disk_init(void) { c64_control_ev_enable_write(c64_control_ev_enable_read() | EV_BLOCK_RD | EV_BLOCK_WR); }

int c64_disk_service(void) {
    if (d64_dirty) {
        timer0_uptime_latch_write(1);
        if (timer0_uptime_cycles_read() > write_commit_cycles) {
            fputs("\n", stdout);
            c64_disk_commit();
            return 1;
        }
    }
    return 0;
}
