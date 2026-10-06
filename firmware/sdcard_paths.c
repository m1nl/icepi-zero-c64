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

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "sdcard_paths.h"

static char *current_directory;

const char *sdcard_current_directory(void) { return current_directory ? current_directory : "/"; }

FRESULT sdcard_resolve_path(const char *path, char resolved[SDCARD_PATH_MAX]) {
    if (!path)
        return FR_INVALID_NAME;

    // Only the SD card's single volume is supported.
    if (path[0] == '0' && path[1] == ':')
        path += 2;

    if (strchr(path, ':'))
        return FR_INVALID_NAME;

    strcpy(resolved, *path == '/' || *path == '\\' ? "/" : sdcard_current_directory());
    size_t length = strlen(resolved);

    while (*path) {
        while (*path == '/' || *path == '\\')
            path++;

        const char *component = path;
        while (*path && *path != '/' && *path != '\\')
            path++;

        size_t size = path - component;
        if (!size || (size == 1 && component[0] == '.'))
            continue;

        if (size == 2 && component[0] == '.' && component[1] == '.') {
            while (length > 1 && resolved[length - 1] != '/')
                length--;
            if (length > 1)
                length--;
            resolved[length] = 0;
            continue;
        }

        size_t separator = length > 1 ? 1 : 0;
        if (size >= SDCARD_PATH_MAX - length - separator)
            return FR_INVALID_NAME;

        if (separator)
            resolved[length++] = '/';

        memcpy(resolved + length, component, size);
        length += size;
        resolved[length] = 0;
    }

    return FR_OK;
}

FRESULT sdcard_change_directory(const char *path) {
    char *resolved = malloc(SDCARD_PATH_MAX);
    FATFS *fs = malloc(sizeof(*fs));

    if (!resolved || !fs) {
        free(resolved);
        free(fs);
        return FR_NOT_ENOUGH_CORE;
    }

    FRESULT result = sdcard_resolve_path(path, resolved);
    if (result == FR_OK) {
        DIR dir;
        result = f_mount(fs, "", 1);

        if (result == FR_OK) {
            result = f_opendir(&dir, resolved);

            if (result == FR_OK) {
                result = f_closedir(&dir);

                if (result == FR_OK) {
                    free(current_directory);
                    current_directory = resolved;
                    resolved = NULL;
                }
            }
        }
        f_unmount("");
    }

    free(resolved);
    free(fs);

    return result;
}

static inline unsigned char fold_case(unsigned char c) { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c; }

static int compare_entries(const void *left, const void *right) {
    const FILINFO *a = left, *b = right;

    int a_directory = (a->fattrib & AM_DIR) != 0;
    int b_directory = (b->fattrib & AM_DIR) != 0;

    if (a_directory != b_directory)
        return b_directory - a_directory;

    const unsigned char *p = (const unsigned char *)a->fname;
    const unsigned char *q = (const unsigned char *)b->fname;

    while (*p && fold_case(*p) == fold_case(*q)) {
        p++;
        q++;
    }

    int order = (int)fold_case(*p) - (int)fold_case(*q);

    return order ? order : strcmp(a->fname, b->fname);
}

static inline void swap_entries(FILINFO *a, FILINFO *b) {
    FILINFO temporary = *a;
    *a = *b;
    *b = temporary;
}

static void sift_entries(FILINFO *entries, size_t count, size_t root) {
    while (root < count / 2) {
        size_t child = root * 2 + 1;

        if (child + 1 < count && compare_entries(&entries[child], &entries[child + 1]) < 0)
            child++;

        if (compare_entries(&entries[root], &entries[child]) >= 0)
            return;

        swap_entries(&entries[root], &entries[child]);
        root = child;
    }
}

// LiteX's minimal libc has no qsort; heapsort needs no extra allocation.
static void sort_entries(FILINFO *entries, size_t count) {
    for (size_t i = count / 2; i > 0; i--)
        sift_entries(entries, count, i - 1);

    while (count > 1) {
        swap_entries(&entries[0], &entries[--count]);
        sift_entries(entries, count, 0);
    }
}

FRESULT sdcard_read_directory(const char *path, FILINFO **entries, size_t *count) {
    DIR dir;
    *entries = NULL;
    *count = 0;
    char *resolved = malloc(SDCARD_PATH_MAX);

    if (!resolved)
        return FR_NOT_ENOUGH_CORE;

    FRESULT result = sdcard_resolve_path(path, resolved);
    if (result == FR_OK)
        result = f_opendir(&dir, resolved);

    free(resolved);

    if (result != FR_OK)
        return result;

    size_t capacity = 0;
    while (1) {
        if (*count == capacity) {
            if (capacity > SIZE_MAX / 2 / sizeof(**entries)) {
                result = FR_NOT_ENOUGH_CORE;
                break;
            }

            size_t next = capacity ? capacity * 2 : 32;
            FILINFO *grown = realloc(*entries, next * sizeof(**entries));
            if (!grown) {
                result = FR_NOT_ENOUGH_CORE;
                break;
            }

            *entries = grown;
            capacity = next;
        }

        FILINFO *info = &(*entries)[*count];
        result = f_readdir(&dir, info);

        if (result != FR_OK || !info->fname[0])
            break;

        if (strcmp(info->fname, ".") != 0 && strcmp(info->fname, "..") != 0)
            (*count)++;
    }

    FRESULT closed = f_closedir(&dir);

    if (result == FR_OK)
        result = closed;

    if (result != FR_OK) {
        free(*entries);
        *entries = NULL;
        *count = 0;

    } else if (*count > 1) {
        sort_entries(*entries, *count);
    }

    return result;
}
