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

#ifndef C64_CART_H
#define C64_CART_H

#include <stddef.h>
#include <stdint.h>

#define CRT_ID_NORMAL 0
#define CRT_ID_ACTION_REPLAY 1
#define CRT_ID_SIMONS_BASIC 4
#define CRT_ID_OCEAN 5
#define CRT_ID_C64GS 15
#define CRT_ID_DINAMIC 17
#define CRT_ID_MAGIC_DESK 19
#define CRT_ID_EASY_FLASH 32
#define CRT_ID_EASY_FLASH_2 33
#define CRT_ID_RETRO_REPLAY 36
#define CRT_ID_GMOD_2 60
#define CRT_ID_MAGIC_DESK_2 85

typedef struct {
    uint16_t bank;
    uint16_t load_addr;
    uint16_t size;
    const uint8_t *data;
} crt_chip_t;

typedef struct {
    uint16_t id;
    char name[33];
    uint8_t exrom;
    uint8_t game;
    int num_chips;
    crt_chip_t *chips;
    uint8_t *_buf; /* raw file data; chip->data pointers alias into this */
} crt_t;

int c64_cart_load(const char *path, void *rom_load_address);

int crt_open(const char *path, crt_t *cart);
void crt_close(crt_t *cart);
uint16_t crt_get_id(const crt_t *cart);
const char *crt_get_name(const crt_t *cart);
void crt_get_lines(const crt_t *cart, uint8_t *exrom, uint8_t *game);
int crt_get_chip_count(const crt_t *cart);
const crt_chip_t *crt_get_chip(const crt_t *cart, int index);

#endif /* C64_CART_H */
