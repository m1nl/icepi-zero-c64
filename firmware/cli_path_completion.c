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

#include <stdlib.h>
#include <string.h>

#include "cli_path_completion.h"
#include "ff.h"
#include "sdcard_paths.h"

static inline bool whitespace(char c) { return c == ' ' || c == '\t'; }

bool cli_directory_prompt_update(struct embedded_cli *cli) {
    const char *path = sdcard_current_directory();
    size_t length = strlen(path);
    const char *prefix = "";

    if (length > PATH_DISPLAY_MAX) {
        prefix = "...";
        path += length - (PATH_DISPLAY_MAX - 3);
        // Keep a UTF-8 character intact at the shortened path's boundary.
        while (((unsigned char)*path & 0xc0) == 0x80)
            path++;
    }

    char displayed[PATH_DISPLAY_MAX + 1];

    size_t i = 0;
    for (; path[i]; i++) {
        unsigned char c = path[i];
        displayed[i] = c < 0x20 || c == 0x7f ? '?' : c;
    }

    displayed[i] = 0;

    char prompt[PATH_DISPLAY_MAX + 24];
    const char start[] = "\e[92;1m";

    size_t position = sizeof(start) - 1;
    memcpy(prompt, start, position);

    size_t prefix_length = strlen(prefix);
    memcpy(prompt + position, prefix, prefix_length);

    position += prefix_length;
    memcpy(prompt + position, displayed, i);

    position += i;
    strcpy(prompt + position, "\e[0m> ");

    return embedded_cli_set_prompt(cli, prompt);
}

static bool path_command(const char *command, int len) {
    static const char *commands[] = {"ls", "mount", "cart_load", "tape_load", "cd"};
    for (unsigned int i = 0; i < sizeof(commands) / sizeof(commands[0]); i++) {
        if ((int)strlen(commands[i]) == len && strncmp(command, commands[i], len) == 0)
            return true;
    }
    return false;
}

/* Decode only the path before the cursor, using the CLI's quote/escape rules. */
static bool path_prefix(const struct embedded_cli *cli, char *path, char *quote, bool *directories_only) {
    int pos = 0;
    while (pos < cli->cursor && whitespace(cli->buffer[pos]))
        pos++;

    int command = pos;
    while (pos < cli->cursor && !whitespace(cli->buffer[pos]))
        pos++;

    if (pos == cli->cursor || !path_command(cli->buffer + command, pos - command))
        return false;

    *directories_only = pos - command == 2 && strncmp(cli->buffer + command, "cd", 2) == 0;
    while (pos < cli->cursor && whitespace(cli->buffer[pos]))
        pos++;

    int len = 0;
    *quote = 0;

    while (pos < cli->cursor) {
        char c = cli->buffer[pos++];
        if (*quote) {
            if (c == *quote)
                *quote = 0;
            else
                path[len++] = c;
        } else if (c == '\\') {
            if (pos == cli->cursor)
                return false;
            path[len++] = cli->buffer[pos++];
        } else if (c == '\'' || c == '"') {
            *quote = c;
        } else if (whitespace(c)) {
            return false; /* Cursor is past the first argument. */
        } else {
            path[len++] = c;
        }
    }
    path[len] = 0;

    /* Completing inside a filename would duplicate its existing suffix. */
    if (cli->cursor < cli->len) {
        char next = cli->buffer[cli->cursor];
        if (*quote ? next != *quote : !whitespace(next))
            return false;
    }

    return true;
}

static inline char fold_case(char c) { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c; }

static bool matches(const FILINFO *info, const char *prefix) {
    if (strcmp(info->fname, ".") == 0 || strcmp(info->fname, "..") == 0)
        return false;

    /* Avoid injecting terminal controls from directory entries. */
    for (const char *p = info->fname; *p; p++) {
        if ((unsigned char)*p < 0x20 || *p == 0x7f)
            return false;
    }

    for (int i = 0; prefix[i]; i++) {
        if (!info->fname[i] || fold_case(prefix[i]) != fold_case(info->fname[i]))
            return false;
    }

    return true;
}

/* Encode the added suffix so embedded_cli_argc returns the actual filename.
 * Quotes in a quoted filename are emitted by closing, escaping and reopening
 * the quote: the CLI treats backslashes inside quotes as literal characters.
 */
static bool append_suffix(struct embedded_cli *cli, const char *suffix, char quote, bool finish_file) {
    char encoded[EMBEDDED_CLI_MAX_LINE];
    int len = 0;

    for (; *suffix; suffix++) {
        char c = *suffix;
        int needed = quote ? (c == quote ? 4 : 1) : (whitespace(c) || c == '\\' || c == '\'' || c == '"' ? 2 : 1);

        if (len + needed >= (int)sizeof(encoded))
            return false;

        if (quote && c == quote) {
            encoded[len++] = quote;
            encoded[len++] = '\\';
            encoded[len++] = c;
            encoded[len++] = quote;

        } else {
            if (!quote && needed == 2)
                encoded[len++] = '\\';

            encoded[len++] = c;
        }
    }

    if (finish_file && cli->cursor == cli->len) {
        if (len + (quote ? 2 : 1) >= (int)sizeof(encoded))
            return false;

        if (quote)
            encoded[len++] = quote;

        encoded[len++] = ' ';
    }
    /* The whole completion must fit; never insert a truncated filename. */
    if (cli->len + len >= EMBEDDED_CLI_MAX_LINE)
        return false;

    encoded[len] = 0;

    return embedded_cli_insert_text(cli, encoded);
}

struct completion_workspace {
    char path[EMBEDDED_CLI_MAX_LINE];
    char directory[EMBEDDED_CLI_MAX_LINE];
    char common[FF_MAX_LFN + 2];

    FATFS fs;
};

static void complete_path(struct embedded_cli *cli, struct completion_workspace *workspace) {
    char *path = workspace->path;
    char *directory = workspace->directory;
    char *common = workspace->common;
    char quote;

    bool directories_only;

    FILINFO *entries = NULL;
    size_t entry_count = 0;

    if (cli->done || cli->have_escape || cli->have_csi)
        return;

#if EMBEDDED_CLI_HISTORY_LEN
    if (cli->searching)
        return;
#endif
    if (!path_prefix(cli, path, &quote, &directories_only))
        return;

    char *prefix = NULL;
    for (char *p = path; *p; p++) {
        if (*p == '/')
            prefix = p;
    }

    if (prefix) {
        int len = prefix - path + 1;
        memcpy(directory, path, len);
        directory[len] = 0;
        prefix++;

    } else {
        strcpy(directory, ".");
        prefix = path;
    }

    FRESULT result = f_mount(&workspace->fs, "", 1);
    if (result != FR_OK)
        goto unmount;

    result = sdcard_read_directory(directory, &entries, &entry_count);
    if (result != FR_OK)
        goto unmount;

    unsigned int count = 0;
    bool is_directory = false;

    for (size_t entry = 0; entry < entry_count; entry++) {
        const FILINFO *info = &entries[entry];
        if ((directories_only && !(info->fattrib & AM_DIR)) || !matches(info, prefix))
            continue;

        if (count++ == 0) {
            strcpy(common, info->fname);
            is_directory = (info->fattrib & AM_DIR) != 0;

        } else {
            int i = 0;
            while (common[i] && info->fname[i] && fold_case(common[i]) == fold_case(info->fname[i]))
                i++;
            common[i] = 0;
        }
    }

    if (result != FR_OK || count == 0)
        goto unmount;

    if (count == 1 && is_directory) {
        int len = strlen(common);
        common[len] = '/';
        common[len + 1] = 0;
    }

    if (strlen(common) > strlen(prefix) || count == 1) {
        append_suffix(cli, common + strlen(prefix), quote, count == 1 && !is_directory);

    } else {
        embedded_cli_puts(cli, "\n");
        for (size_t entry = 0; entry < entry_count; entry++) {
            const FILINFO *info = &entries[entry];
            if ((directories_only && !(info->fattrib & AM_DIR)) || !matches(info, prefix))
                continue;
            embedded_cli_puts(cli, info->fname);
            embedded_cli_puts(cli, info->fattrib & AM_DIR ? "/\n" : "\n");
        }

        embedded_cli_prompt(cli);
        embedded_cli_puts(cli, cli->buffer);

        for (int i = cli->cursor; i < cli->len; i++)
            embedded_cli_puts(cli, "\x1b[1D");
    }

unmount:
    free(entries);
    f_unmount("");
}

void cli_path_complete(struct embedded_cli *cli) {
    struct completion_workspace *workspace = malloc(sizeof(*workspace));

    if (!workspace)
        return;

    complete_path(cli, workspace);
    free(workspace);
}
