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

#include <generated/csr.h>

#include "ff.h"

#include "c64_cart.h"

#define CRT_SIG "C64 CARTRIDGE   "
#define CRT_SIG_LEN 16
#define CRT_HDR_MIN 0x40
#define CHIP_SIG "CHIP"
#define CHIP_SIG_LEN 4
#define CHIP_HDR_SIZE 16
#define CHIP_TYPE_ROM 0
#define CHIP_TYPE_RAM 1
#define CHIP_TYPE_FLASH 2

static inline uint16_t rd_u16_be(const uint8_t *p) { return ((uint16_t)p[0] << 8) | p[1]; }

static inline uint32_t rd_u32_be(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static const uint16_t supported_ids[] = {CRT_ID_NORMAL,       CRT_ID_ACTION_REPLAY, CRT_ID_SIMONS_BASIC,
                                         CRT_ID_OCEAN,        CRT_ID_C64GS,         CRT_ID_DINAMIC,
                                         CRT_ID_MAGIC_DESK,   CRT_ID_EASY_FLASH,    CRT_ID_EASY_FLASH_2,
                                         CRT_ID_RETRO_REPLAY, CRT_ID_GMOD_2,        CRT_ID_MAGIC_DESK_2};

static inline int is_supported_id(uint16_t id) {
    for (size_t i = 0; i < sizeof(supported_ids) / sizeof(supported_ids[0]); i++) {
        if (supported_ids[i] == id)
            return 1;
    }
    return 0;
}

#define CART_ROM_LO 0x8000
#define CART_ROM_HI 0xa000
#define CART_ROM_UMAX 0xe000

int c64_cart_load(const char *path, void *rom_load_address) {
    crt_t cart;
    int i;
    int ret = -1;

    ret = crt_open(path, &cart);
    if (ret < 0) {
        return ret;
    }

    for (i = 0; i < cart.num_chips; i++) {
        uint32_t offset = UINT32_MAX;

        if (cart.chips[i].load_addr == CART_ROM_LO)
            offset = (cart.chips[i].bank * 2) * 0x2000;
        if (cart.chips[i].load_addr == CART_ROM_HI || cart.chips[i].load_addr == CART_ROM_UMAX)
            offset = (cart.chips[i].bank * 2 + 1) * 0x2000;

        if (offset == UINT32_MAX) {
            printf("c64_cart_load: invalid load address 0x%04x\n", cart.chips[i].load_addr);
            goto cleanup;
        }

        memcpy(rom_load_address + offset, cart.chips[i].data, cart.chips[i].size);
    }

    uint16_t cart_flags =
        ((uint16_t)(cart.id & 0xff)) | ((uint16_t)(cart.exrom == 1) << 8) | ((uint16_t)(cart.game == 1) << 9);
    c64_control_cart_flags_write(cart_flags);

    ret = 0;

cleanup:
    crt_close(&cart);

    return ret;
}

int crt_open(const char *path, crt_t *cart) {
    static FATFS fs;
    FIL fil;
    FRESULT res;
    UINT br;
    int ret = -1;

    memset(cart, 0, sizeof(*cart));

    res = f_mount(&fs, "", 1);
    if (res != FR_OK) {
        printf("crt_open: sdcard mount failed (err %d)\n", res);
        return -1;
    }

    res = f_open(&fil, path, FA_READ);
    if (res != FR_OK) {
        printf("crt_open: cannot open '%s' (err %d)\n", path, res);
        goto exit_unmount;
    }

    size_t size = f_size(&fil);

    if (size < CRT_HDR_MIN) {
        printf("crt_open: file too small (%u bytes)\n", size);
        f_close(&fil);
        goto exit_unmount;
    }

    cart->_buf = malloc(size);
    if (!cart->_buf) {
        printf("crt_open: malloc failed for %u bytes\n", size);
        f_close(&fil);
        goto exit_unmount;
    }

    res = f_read(&fil, cart->_buf, size, &br);
    f_close(&fil);

    if (res != FR_OK || br != size) {
        printf("crt_open: read failed (err %d, got %u of %u)\n", res, br, size);
        goto exit_free;
    }

    if (memcmp(cart->_buf, CRT_SIG, CRT_SIG_LEN) != 0) {
        printf("crt_open: invalid signature\n");
        goto exit_free;
    }

    uint32_t hdr_len = rd_u32_be(cart->_buf + 0x10);
    if (hdr_len < CRT_HDR_MIN || hdr_len > size) {
        printf("crt_open: invalid header length %lu\n", (unsigned long)hdr_len);
        goto exit_free;
    }

    cart->id = rd_u16_be(cart->_buf + 0x16);
    if (!is_supported_id(cart->id)) {
        printf("crt_open: unsupported cart type %u\n", cart->id);
        goto exit_free;
    }

    cart->exrom = cart->_buf[0x18];
    cart->game = cart->_buf[0x19];

    memcpy(cart->name, cart->_buf + 0x20, 32);
    cart->name[32] = '\0';

    /* count ROM chips */
    int num_chips = 0;
    uint32_t pos = hdr_len;

    while (pos + CHIP_HDR_SIZE <= size) {
        if (memcmp(cart->_buf + pos, CHIP_SIG, CHIP_SIG_LEN) != 0)
            break;

        uint32_t pkt_len = rd_u32_be(cart->_buf + pos + 4);
        if (pkt_len < CHIP_HDR_SIZE || pos + pkt_len > size)
            break;

        uint16_t type = rd_u16_be(cart->_buf + pos + 8);
        if (type == CHIP_TYPE_ROM || type == CHIP_TYPE_FLASH)
            num_chips++;
        pos += pkt_len;
    }

    if (num_chips == 0) {
        printf("crt_open: no ROM chips found\n");
        goto exit_free;
    }

    cart->chips = malloc(num_chips * sizeof(crt_chip_t));
    if (!cart->chips) {
        printf("crt_open: malloc failed for chip table\n");
        goto exit_free;
    }

    /* fill chip table */
    int idx = 0;
    pos = hdr_len;

    while (pos + CHIP_HDR_SIZE <= size && idx < num_chips) {
        if (memcmp(cart->_buf + pos, CHIP_SIG, CHIP_SIG_LEN) != 0)
            break;
        uint32_t pkt_len = rd_u32_be(cart->_buf + pos + 4);
        if (pkt_len < CHIP_HDR_SIZE || pos + pkt_len > size)
            break;
        uint16_t type = rd_u16_be(cart->_buf + pos + 8);
        if (type == CHIP_TYPE_ROM || type == CHIP_TYPE_FLASH) {
            cart->chips[idx].bank = rd_u16_be(cart->_buf + pos + 0x0a);
            cart->chips[idx].load_addr = rd_u16_be(cart->_buf + pos + 0x0c);
            cart->chips[idx].size = rd_u16_be(cart->_buf + pos + 0x0e);
            cart->chips[idx].data = cart->_buf + pos + CHIP_HDR_SIZE;
            idx++;
        }
        pos += pkt_len;
    }

    cart->num_chips = idx;

    printf("crt_open: '%s' type=%u exrom=%u game=%u chips=%d\n", cart->name, cart->id, cart->exrom, cart->game,
           cart->num_chips);

    ret = 0;
    goto exit_unmount;

exit_free:
    if (cart->chips) {
        free(cart->chips);
        cart->chips = NULL;
    }
    free(cart->_buf);
    cart->_buf = NULL;

exit_unmount:
    f_unmount("");
    return ret;
}

void crt_close(crt_t *cart) {
    if (!cart)
        return;
    if (cart->chips) {
        free(cart->chips);
        cart->chips = NULL;
    }
    if (cart->_buf) {
        free(cart->_buf);
        cart->_buf = NULL;
    }
    memset(cart, 0, sizeof(*cart));
}

uint16_t crt_get_id(const crt_t *cart) { return cart->id; }

const char *crt_get_name(const crt_t *cart) { return cart->name; }

void crt_get_lines(const crt_t *cart, uint8_t *exrom, uint8_t *game) {
    *exrom = cart->exrom;
    *game = cart->game;
}

int crt_get_chip_count(const crt_t *cart) { return cart->num_chips; }

const crt_chip_t *crt_get_chip(const crt_t *cart, int index) {
    if (index < 0 || index >= cart->num_chips)
        return NULL;
    return &cart->chips[index];
}
