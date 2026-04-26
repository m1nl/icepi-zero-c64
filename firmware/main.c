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
#include <libbase/jsmn.h>
#include <libbase/uart.h>

#include "ff.h"
#include "heap.h"
#include "spisdcard.h"

#include "c64_disk.h"
#include "c64_event.h"
#include "c64_tape.h"
#include "embedded_cli.h"
#include "input.h"
#include "power.h"

#include "main.h"

static struct embedded_cli cli;

static FATFS fs;

static volatile int c64_console_active = 0;

static int read_file_to_mem(const char *path, void *dst, size_t size) {
    int ret = -1;
    FRESULT res;
    FIL f;
    size_t br;

    res = f_mount(&fs, "", 1);
    if (res != FR_OK) {
        printf("read_file_to_mem: mount failed");
        goto unmount;
    }

    res = f_open(&f, path, FA_READ);
    if (res != FR_OK) {
        printf("read_file_to_mem: unable to open file %s", path);
        goto unmount;
    }

    res = f_read(&f, dst, size, &br);
    f_close(&f);
    if (res != FR_OK || br == 0) {
        printf("read_file_to_mem: failed to read file %s", path);
        goto unmount;
    }

    ret = br;

    flush_cpu_dcache();
    flush_l2_cache();

unmount:
    f_unmount("");
    return ret;
}

static int c64_flags_save(void) {
    int ret = -1;
    FRESULT res;
    FIL f;
    UINT bw;
    char *buf;
    uint32_t flags = c64_control_flags_read();
    int pos = 0;

    buf = malloc(FLAGS_JSON_MAX);
    if (!buf)
        return -1;

    buf[pos++] = '{';
    buf[pos++] = '\n';
    for (int i = 0; i < FLAG_DEFS_COUNT; i++) {
        int val = (flags >> flag_defs[i].bit) & 1;
        const char *name = flag_defs[i].name;
        buf[pos++] = ' ';
        buf[pos++] = ' ';
        buf[pos++] = '"';
        for (int k = 0; name[k]; k++)
            buf[pos++] = name[k];
        buf[pos++] = '"';
        buf[pos++] = ':';
        buf[pos++] = ' ';
        buf[pos++] = '0' + val;
        if (i < FLAG_DEFS_COUNT - 1)
            buf[pos++] = ',';
        buf[pos++] = '\n';
    }
    buf[pos++] = '}';
    buf[pos++] = '\n';

    res = f_mount(&fs, "", 1);
    if (res != FR_OK) {
        printf("c64_flags_save: mount failed (%d)\n", res);
        free(buf);
        return -1;
    }
    res = f_open(&f, FLAGS_JSON_PATH, FA_WRITE | FA_CREATE_ALWAYS);
    if (res != FR_OK) {
        printf("c64_flags_save: open failed (%d)\n", res);
        goto unmount;
    }
    f_write(&f, buf, pos, &bw);
    f_close(&f);
unmount:
    f_unmount("");
    free(buf);

    return ret;
}

#define JSMNTOK_COUNT (FLAG_DEFS_COUNT * 2 + 2)

static int c64_flags_load(void) {
    int ret = -1;
    FRESULT res;
    FIL f;
    UINT br;
    char *buf;
    jsmn_parser p;
    jsmntok_t *tok;
    int r;

    buf = malloc(FLAGS_JSON_MAX);
    tok = malloc(sizeof(jsmntok_t) * JSMNTOK_COUNT);
    if (!buf || !tok)
        return -1;

    res = f_mount(&fs, "", 1);
    if (res != FR_OK)
        goto unmount;

    res = f_open(&f, FLAGS_JSON_PATH, FA_READ);
    if (res != FR_OK)
        goto unmount;

    res = f_read(&f, buf, FLAGS_JSON_MAX - 1, &br);
    f_close(&f);
    if (res != FR_OK || br == 0)
        goto unmount;
    buf[br] = '\0';

    jsmn_init(&p);
    r = jsmn_parse(&p, buf, br, tok, JSMNTOK_COUNT);
    if (r < 1 || tok[0].type != JSMN_OBJECT) {
        printf("c64_flags_load: JSON parse error\n");
        goto unmount;
    }

    uint32_t flags = c64_control_flags_read();

    for (int i = 1; i + 1 < r; i += 2) {
        if (tok[i].type != JSMN_STRING)
            continue;
        int klen = tok[i].end - tok[i].start;
        const char *key = buf + tok[i].start;
        int val = (buf[tok[i + 1].start] == '1') ? 1 : 0;

        for (int j = 0; j < FLAG_DEFS_COUNT; j++) {
            if ((int)strlen(flag_defs[j].name) == klen && strncmp(flag_defs[j].name, key, klen) == 0) {
                if (val)
                    flags |= (1u << flag_defs[j].bit);
                else
                    flags &= ~(1u << flag_defs[j].bit);
                break;
            }
        }
    }

    c64_control_flags_write(flags);
    printf("c64_flags_load: flags loaded from " FLAGS_JSON_PATH "\n");
    ret = 0;

unmount:
    f_unmount("");
    free(tok);
    free(buf);
    return ret;
}

static void c64_flag(int bit, int val) {
    uint32_t flags = c64_control_flags_read();

    if (val == -1)
        flags ^= (1u << bit);
    else if (val == 0)
        flags &= ~(1u << bit);
    else
        flags |= (1u << bit);
    c64_control_flags_write(flags);
    printf("%s = %d\n", flag_defs[bit].name, flags & (1u << bit) ? 1 : 0);
    c64_flags_save();
}

static int c64_cart_load(void) {
    int ret;
    FRESULT res;
    FILINFO fno;

    res = f_mount(&fs, "", 1);
    if (res != FR_OK) {
        printf("c64_cart_load: sdcard mount failed (err %d)\n", res);
        return -1;
    }

    res = f_stat(C64_AR_PATH, &fno);
    f_unmount("");

    if (res != FR_OK) {
        printf("c64_cart_load: cartridge ROM not found in path %s", C64_AR_PATH);
        return -1;
    }

    ret = read_file_to_mem(C64_AR_PATH, (uint8_t *)C64_AR_BASE, C64_AR_SIZE);

    if (ret > 0) {
        printf("c64_cart_load: copied %d bytes from %s into %p", ret, C64_AR_PATH, (uint8_t *)C64_AR_BASE);
    }

    return ret;
}

static void c64_init_mem(uint8_t *mem, int size, int pattern) {
    int i;

    // First two entries = 0
    mem[0] = 0x00;
    mem[1] = 0x00;

    // Pattern or zero fill
    for (i = 2; i < size; i++) {
        if (pattern && (((i - 2) % 8) < 4))
            mem[i] = 0xFF; // all 1s
        else
            mem[i] = 0x00; // all 0s
    }

    flush_cpu_dcache();
    flush_l2_cache();
}

static void c64_reset_cpu(void) {
    int flags = c64_control_flags_read();
    int cart_present = flags & (1 << FLAG_CART_PRESENT);

    c64_control_cpu_reset_req_write(1);
    busy_wait(1);

    c64_init_mem((uint8_t *)C64_RAM_BASE, C64_RAM_SIZE, !cart_present);
    busy_wait(1);

    c64_control_cpu_reset_req_write(0);
}

/*-----------------------------------------------------------------------*/
/* Help                                                                  */
/*-----------------------------------------------------------------------*/

static void help_cmd(void) {
    puts("\n\nicepi-zero-c64 built "__DATE__
         " "__TIME__
         "\n");
    puts("Available commands:");
    puts("help                  - Show this command");
    puts("reboot                - Reboot CPU");
    puts("sdcard_reset          - Reset SD card");
    puts("ls [path]             - List SD card directory");
    puts("hexdump <addr> [len]  - Hex dump memory (len default 256)");
    puts("console               - Redirect serial console to C64");
    puts("mount <path> [0|1]    - Mount D64 disk image (1 for read-write)");
    puts("umount                - Unmount D64 disk image");
    puts("format <path> <label> - Format D64 disk image");
    puts("sync                  - Commit changes to D64 disk image");
    puts("tape_load <path>      - Load TAP file");
    puts("tape_eject            - Eject TAP file");
    puts("flags                 - Show current flags");
    puts("flag <name> [0|1]     - Set or toggle a flag bit (auto-saved)");
    puts("reset                 - Reset C64 CPU");
    puts("pause                 - Pause C64 CPU");
    puts("resume                - Resume C64 CPU");
    puts("power                 - Report INA219 power from UPS board");
}

/*-----------------------------------------------------------------------*/
/* Commands                                                              */
/*-----------------------------------------------------------------------*/

static void console_cmd(void) {
    printf("\e[92;1mterminal is redirected to C64, press ctrl+c to break\e[0m\n");
    c64_console_active = 1;
}

static void reboot_cmd(void) { ctrl_reset_write(1); }

static void flags_cmd(void) {
    uint32_t flags = c64_control_flags_read();
    printf("flags = 0x%04lx\n", (unsigned long)flags);
    for (int i = 0; i < FLAG_DEFS_COUNT; i++)
        printf("  [%2d] %-24s = %d  %s\n", flag_defs[i].bit, flag_defs[i].name, (int)((flags >> flag_defs[i].bit) & 1),
               flag_defs[i].desc);
}

static void flag_cmd(int argc, char **argv) {
    if (argc != 1 && argc != 2) {
        printf("usage: flag <name> [0|1]\n");
        return;
    }
    const char *name = argv[0];
    int val = -1;
    if (argc == 2)
        val = (int)strtoul(argv[1], NULL, 0);
    for (int i = 0; i < FLAG_DEFS_COUNT; i++) {
        if (strcmp(flag_defs[i].name, name) == 0) {
            c64_flag(flag_defs[i].bit, val);
            return;
        }
    }
    printf("flag: unknown flag: %s\n", name);
}

static void c64_reset_cmd(void) { c64_reset_cpu(); }

static void c64_pause_cmd(void) { c64_control_cpu_pause_req_write(1); }

static void c64_resume_cmd(void) { c64_control_cpu_pause_req_write(0); }

static void sdcard_reset_cmd(void) { spisdcard_init(); }

static void ls_cmd(int argc, char **argv) {
    FRESULT res;
    DIR dir;
    FILINFO fno;

    int mounted = 0;

    res = f_mount(&fs, "", 1);
    if (res != FR_OK) {
        printf("ls: sdcard mount failed (err %d)\n", res);
        goto exit;
    }

    mounted = 1;

    const char *dirpath = (argc == 0) ? "/" : argv[0];
    res = f_opendir(&dir, dirpath);
    if (res != FR_OK) {
        printf("ls: cannot open '%s' (err %d)\n", dirpath, res);
        goto exit;
    }

    printf("Contents of %s:\n", dirpath);
    for (int i = 1;; i++) {
        res = f_readdir(&dir, &fno);
        if (res != FR_OK || fno.fname[0] == '\0')
            break;
        if (fno.fattrib & AM_DIR)
            printf("     [DIR]  %s\n", fno.fname);
        else
            printf("  %8lu  %s\n", (unsigned long)fno.fsize, fno.fname);

        if (i % 20 == 0) {
            printf("\e[92;1mpress esc to break, any other key to continue\e[0m\n");

            if (input_block() == 0x1b)
                break;
        }
    }

    f_closedir(&dir);

exit:
    if (mounted) {
        f_unmount("");
    }
}

static void hexdump_cmd(int argc, char **argv) {
    if (argc != 1 && argc != 2) {
        printf("usage: hexdump <addr> [len]\n");
        return;
    }
    uint32_t addr = (uint32_t)strtoul(argv[0], NULL, 0);
    uint32_t len = 256;
    if (argc == 2)
        len = (uint32_t)strtoul(argv[1], NULL, 0);

    const uint8_t *p = (const uint8_t *)addr;
    for (uint32_t i = 0; i < len; i += 16) {
        printf("%08lx  ", (unsigned long)(addr + i));
        for (uint32_t j = 0; j < 16; j++) {
            if (i + j < len)
                printf("%02x ", p[i + j]);
            else
                printf("   ");
            if (j == 7)
                printf(" ");
        }
        printf(" |");
        for (uint32_t j = 0; j < 16 && i + j < len; j++) {
            uint8_t c = p[i + j];
            printf("%c", (c >= 0x20 && c < 0x7f) ? c : '.');
        }
        printf("|\n");
    }
}

static void c64_disk_mount_cmd(int argc, char **argv) {
    if (argc != 1 && argc != 2) {
        printf("usage: mount <path> [0|1]\n");
        return;
    }

    const char *path = argv[0];
    int rw = 0;
    if (argc == 2)
        rw = argv[1][0] == '1';

    c64_disk_mount(path, rw);
}

static void c64_disk_format_cmd(int argc, char **argv) {
    if (argc != 2) {
        printf("usage: format <path> <label>\n");
        return;
    }

    const char *path = argv[0];
    const char *label = argv[1];

    c64_disk_format(path, label);
}

static void c64_tape_load_cmd(int argc, char **argv) {
    if (argc != 1) {
        printf("usage: tape_load <path>\n");
        return;
    }

    const char *path = argv[0];
    c64_tape_load(path);
}

/*-----------------------------------------------------------------------*/
/* Console service / Main                                                */
/*-----------------------------------------------------------------------*/

static void posix_putch(void *data, char ch, bool is_last) {
    FILE *fp = data;
    fputc(ch, fp);
}

static int get_command_code(const char *cmd) {
    for (int i = 0; i < COMMAND_MAX; i++) {
        if (strcmp(cmd, commands[i]) == 0) {
            return i;
        }
    }
    return -1;
}

static int console_service(void) {
    char c = input_nonblock();

    if (!c || c == '\t')
        return 0;

    if (!embedded_cli_insert_char(&cli, c))
        return 0;

    int argc = 0;
    char **argv;

    argc = embedded_cli_argc(&cli, &argv);

    if (argc == 0) {
        embedded_cli_prompt(&cli);
        return 0;
    }

    char *command = argv[0];
    int show_prompt = 1;

    argc--;
    argv++;

    switch (get_command_code(command)) {
        case COMMAND_HELP:
            help_cmd();
            break;
        case COMMAND_REBOOT:
            reboot_cmd();
            break;
        case COMMAND_SDCARD_RESET:
            sdcard_reset_cmd();
            break;
        case COMMAND_LS:
            ls_cmd(argc, argv);
            break;
        case COMMAND_HEXDUMP:
            hexdump_cmd(argc, argv);
            break;
        case COMMAND_MOUNT:
            c64_disk_mount_cmd(argc, argv);
            break;
        case COMMAND_UMOUNT:
            c64_disk_umount();
            break;
        case COMMAND_FORMAT:
            c64_disk_format_cmd(argc, argv);
            break;
        case COMMAND_SYNC:
            c64_disk_commit();
            break;
        case COMMAND_TAPE_LOAD:
            c64_tape_load_cmd(argc, argv);
            break;
        case COMMAND_TAPE_EJECT:
            c64_tape_eject();
            break;
        case COMMAND_FLAGS:
            flags_cmd();
            break;
        case COMMAND_FLAG:
            flag_cmd(argc, argv);
            break;
        case COMMAND_CONSOLE:
            console_cmd();
            show_prompt = 0;
            break;
        case COMMAND_C64_RESET:
            c64_reset_cmd();
            break;
        case COMMAND_C64_PAUSE:
            c64_pause_cmd();
            break;
        case COMMAND_C64_RESUME:
            c64_resume_cmd();
            break;
        case COMMAND_POWER:
            power_report();
            break;
        default:
            embedded_cli_puts(&cli, "unknown command\n");
            break;
    }

    return show_prompt;
}

static void alt_callback(char c) {
    switch (c) {
        case 'j':
            c64_flag(FLAG_JOY_INVERT, -1);
            break;
        case 'k':
            c64_flag(FLAG_JOY_EMULATION_0, -1);
            break;
        case 's':
            c64_flag(FLAG_SID_MODEL, -1);
            break;
        case 'c':
            c64_flag(FLAG_CIA_MODEL, -1);
            break;
        case 'd':
            c64_flag(FLAG_SID_DUAL, -1);
            break;
    }
}

static int c64_isr(uint32_t pending) {
    if (pending & EV_OVERLAY) {
        uint32_t flags = c64_control_flags_read();
        flags ^= (1 << FLAG_OVERLAY);
        c64_control_flags_write(flags);
    }

    if (pending & EV_RESET_REQ) {
        c64_reset_cpu();
    }

    return 0;
}

static void c64_init(void) {
    c64_flags_load();

    if (c64_cart_load() < 0) {
        uint32_t flags = c64_control_flags_read();
        flags &= ~(1 << FLAG_CART_PRESENT);
        c64_control_flags_write(flags);
    }

    c64_reset_cpu();
    c64_control_ev_enable_write(EV_OVERLAY | EV_HID_KEY | EV_RESET_REQ);
}

static void c64_disable_overlay(void) {
    uint32_t flags = c64_control_flags_read();
    flags &= ~(1 << FLAG_OVERLAY);
    c64_control_flags_write(flags);
}

static void c64_control_isr(void) {
    uint32_t pending = c64_control_ev_pending_read();
    c64_control_ev_pending_write(pending);

    input_isr(pending);
    c64_disk_isr(pending);
    c64_tape_isr(pending);
    c64_isr(pending);
}

int main(void) {
    irq_setmask(0);
    irq_setie(1);

    uart_init();
    heap_init();

    input_init();

    c64_init();
    c64_disk_init();
    c64_tape_init();

    help_cmd();
    busy_wait(2000);
    c64_disable_overlay();

    irq_attach(C64_CONTROL_INTERRUPT, c64_control_isr);
    irq_setmask(irq_getmask() | (1 << C64_CONTROL_INTERRUPT));

    input_register_alt_callback(alt_callback);

    embedded_cli_init(&cli, "\e[92;1micepi-c64\e[0m> ", posix_putch, stdout);

    int show_prompt = 1;

    while (1) {
        if (c64_console_active) {
            if (c64_console() < 0) {
                c64_console_active = 0;
                show_prompt |= 1;
            }
        } else {
            if (show_prompt) {
                embedded_cli_prompt(&cli);
                show_prompt = 0;
            }
            show_prompt |= console_service();
        }

        show_prompt |= input_service();
        show_prompt |= c64_disk_service();
        show_prompt |= c64_tape_service();
    }

    return 0;
}
