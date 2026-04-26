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

#include <stddef.h>
#include <stdio.h>

#include "heap.h"
#include "tlsf.h"

__attribute__((noreturn)) void __assert_no_args(void);
__attribute__((noreturn)) void __assert_no_args(void) {
    printf("assert failed\n");
    while (1)
        ;
}

extern char _fheap;
extern char _eheap;

static tlsf_t _tlsf;

void heap_init(void) {
    size_t size = (size_t)(&_eheap - &_fheap);
    _tlsf = tlsf_create_with_pool(&_fheap, size);
    printf("heap: %u bytes at 0x%08lx\n", (unsigned)size, (unsigned long)&_fheap);
}

void *malloc(size_t size) { return tlsf_malloc(_tlsf, size); }

void *realloc(void *ptr, size_t size) { return tlsf_realloc(_tlsf, ptr, size); }

void free(void *ptr) { tlsf_free(_tlsf, ptr); }

int memcmp(const void *s1, const void *s2, size_t n) {
    const unsigned char *p1 = (const unsigned char *)s1;
    const unsigned char *p2 = (const unsigned char *)s2;

    while (n--) {
        if (*p1 != *p2)
            return *p1 - *p2;
        p1++;
        p2++;
    }

    return 0;
}
