#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cli_path_completion.h"
#include "ff.h"
#include "sdcard_paths.h"

struct entry { const char *name; BYTE attributes; };
static const struct entry root[] = {
    {"games", AM_DIR}, {"My Games", AM_DIR},
    {"demo.d64", 0}, {"demo2.d64", 0}, {"cartridge.crt", 0},
    {"tape.tap", 0}, {"Bob's disk.d64", 0}, {"one two.d64", 0},
};
static const struct entry games[] = {{"nested.d64", 0}};
static const struct entry *entries;
static int entry_count, index_in_dir, mounts, closes, unmounts;
static bool mount_error, open_error, read_error, allow_long_directory;
static char output[32768];
static size_t output_len;

FRESULT f_mount(FATFS *fs, const TCHAR *path, BYTE opt) {
    (void)path;
    (void)opt;
    if (!fs) {
        unmounts++;
        return FR_OK;
    }
    mounts++;
    return mount_error ? FR_NOT_READY : FR_OK;
}

FRESULT f_opendir(DIR *dir, const TCHAR *path) {
    (void)dir;
    if (open_error)
        return FR_NO_PATH;
    if (allow_long_directory && strlen(path) >= 40) {
        entries = games;
        entry_count = sizeof(games) / sizeof(games[0]);
        index_in_dir = 0;
        return FR_OK;
    }
    if (strcmp(path, "/") == 0) {
        entries = root;
        entry_count = sizeof(root) / sizeof(root[0]);
    } else if (strcmp(path, "games/") == 0 || strcmp(path, "/games/") == 0 || strcmp(path, "/games") == 0 ||
               strcmp(path, "My Games/") == 0 || strcmp(path, "/My Games") == 0) {
        entries = games;
        entry_count = sizeof(games) / sizeof(games[0]);
    } else {
        return FR_NO_PATH;
    }
    index_in_dir = 0;
    return FR_OK;
}

FRESULT f_readdir(DIR *dir, FILINFO *info) {
    (void)dir;
    if (!info) {
        index_in_dir = 0;
        return FR_OK;
    }
    if (read_error && index_in_dir == 1)
        return FR_DISK_ERR;
    memset(info, 0, sizeof(*info));
    if (index_in_dir < entry_count) {
        strcpy(info->fname, entries[index_in_dir].name);
        info->fattrib = entries[index_in_dir++].attributes;
    }
    return FR_OK;
}

FRESULT f_closedir(DIR *dir) {
    (void)dir;
    closes++;
    return FR_OK;
}

static void put_char(void *data, char c, bool is_last) {
    (void)data;
    (void)is_last;
    assert(output_len + 1 < sizeof(output));
    output[output_len++] = c;
    output[output_len] = 0;
}

static void set_line(struct embedded_cli *cli, const char *line) {
    embedded_cli_insert_char(cli, 3);
    for (; *line; line++)
        embedded_cli_insert_char(cli, *line);
    output_len = 0;
    output[0] = 0;
    mounts = closes = unmounts = 0;
    mount_error = open_error = read_error = false;
}

static void left(struct embedded_cli *cli, int count) {
    while (count--) {
        embedded_cli_insert_char(cli, '\x1b');
        embedded_cli_insert_char(cli, '[');
        embedded_cli_insert_char(cli, 'D');
    }
}

static void expect_line(const struct embedded_cli *cli, const char *line) {
    assert(strcmp(cli->buffer, line) == 0);
    assert(cli->len == (int)strlen(line));
}

static void expect_path(struct embedded_cli *cli, const char *path) {
    embedded_cli_insert_char(cli, '\n');
    char **argv;
    assert(embedded_cli_argc(cli, &argv) == 2);
    assert(strcmp(argv[1], path) == 0);
}

int main(void) {
    struct embedded_cli cli;
    assert(embedded_cli_init(&cli, "> ", put_char, NULL) == 0);
    const char *commands[] = {"ls", "mount", "cart_load", "tape_load"};
    for (unsigned int i = 0; i < sizeof(commands) / sizeof(commands[0]); i++) {
        char line[80], expected[80];
        snprintf(line, sizeof(line), "%s cart", commands[i]);
        snprintf(expected, sizeof(expected), "%s cartridge.crt ", commands[i]);
        set_line(&cli, line);
        cli_path_complete(&cli);
        expect_line(&cli, expected);
        assert(mounts == 1 && closes == 1 && unmounts == 1);
    }

    set_line(&cli, "ls ga");
    cli_path_complete(&cli);
    expect_line(&cli, "ls games/");
    cli_path_complete(&cli);
    expect_line(&cli, "ls games/nested.d64 ");

    set_line(&cli, "mount /games/ne");
    cli_path_complete(&cli);
    expect_line(&cli, "mount /games/nested.d64 ");

    set_line(&cli, "tape_load TA");
    cli_path_complete(&cli);
    expect_line(&cli, "tape_load TApe.tap ");

    set_line(&cli, "ls ");
    cli_path_complete(&cli);
    expect_line(&cli, "ls ");
    assert(strstr(output, "games/\r\n") && strstr(output, "cartridge.crt\r\n"));
    assert(strstr(output, "> ls "));
    const char *ordered[] = {"games/\r\n", "My Games/\r\n", "Bob's disk.d64\r\n",
                             "cartridge.crt\r\n", "demo.d64\r\n", "demo2.d64\r\n",
                             "one two.d64\r\n", "tape.tap\r\n"};
    const char *previous = output;
    for (unsigned int i = 0; i < sizeof(ordered) / sizeof(ordered[0]); i++) {
        const char *found = strstr(previous, ordered[i]);
        assert(found);
        previous = found + strlen(ordered[i]);
    }

    set_line(&cli, "cd ");
    cli_path_complete(&cli);
    expect_line(&cli, "cd ");
    assert(strstr(output, "games/\r\n") && strstr(output, "My Games/\r\n"));
    assert(!strstr(output, "cartridge.crt"));
    set_line(&cli, "cd ga");
    cli_path_complete(&cli);
    expect_line(&cli, "cd games/");
    assert(sdcard_change_directory("games") == FR_OK);
    set_line(&cli, "mount ne");
    cli_path_complete(&cli);
    expect_line(&cli, "mount nested.d64 ");
    set_line(&cli, "mount /cart");
    cli_path_complete(&cli);
    expect_line(&cli, "mount /cartridge.crt ");
    set_line(&cli, "mount ../cart");
    cli_path_complete(&cli);
    expect_line(&cli, "mount ../cartridge.crt ");
    set_line(&cli, "cd ne");
    cli_path_complete(&cli);
    expect_line(&cli, "cd ne"); // Files never complete for cd.
    assert(sdcard_change_directory("/") == FR_OK);

    set_line(&cli, "mount de");
    cli_path_complete(&cli);
    expect_line(&cli, "mount demo");
    output_len = 0;
    cli_path_complete(&cli);
    expect_line(&cli, "mount demo");
    assert(strstr(output, "demo.d64") && strstr(output, "demo2.d64"));
    assert(cli.cursor == cli.len);

    set_line(&cli, "mount cart 1");
    left(&cli, 2);
    cli_path_complete(&cli);
    expect_line(&cli, "mount cartridge.crt 1");
    assert(cli.cursor == 19);
    embedded_cli_insert_char(&cli, '\n');
    char **argv;
    assert(embedded_cli_argc(&cli, &argv) == 3);
    assert(strcmp(argv[1], "cartridge.crt") == 0 && strcmp(argv[2], "1") == 0);

    set_line(&cli, "ls My");
    cli_path_complete(&cli);
    expect_line(&cli, "ls My\\ Games/");
    cli_path_complete(&cli);
    expect_path(&cli, "My Games/nested.d64");

    set_line(&cli, "mount one");
    cli_path_complete(&cli);
    expect_path(&cli, "one two.d64");

    set_line(&cli, "mount \"one");
    cli_path_complete(&cli);
    expect_line(&cli, "mount \"one two.d64\" ");
    expect_path(&cli, "one two.d64");

    set_line(&cli, "mount 'Bob");
    cli_path_complete(&cli);
    expect_path(&cli, "Bob's disk.d64");

    set_line(&cli, "mount \"cart\" 1");
    left(&cli, 3);
    cli_path_complete(&cli);
    expect_line(&cli, "mount \"cartridge.crt\" 1");

    const char *ignored[] = {"mount", "mo", "help cart", "mount cart 1",
                             "mount not-found", "ls missing/ne", "ls ga\\"};
    for (unsigned int i = 0; i < sizeof(ignored) / sizeof(ignored[0]); i++) {
        set_line(&cli, ignored[i]);
        cli_path_complete(&cli);
        expect_line(&cli, ignored[i]);
    }
    set_line(&cli, "mount cartridge.crt");
    left(&cli, 6);
    cli_path_complete(&cli);
    expect_line(&cli, "mount cartridge.crt");
    assert(mounts == 0);

    for (int error = 0; error < 3; error++) {
        set_line(&cli, "ls ga");
        mount_error = error == 0;
        open_error = error == 1;
        read_error = error == 2;
        cli_path_complete(&cli);
        expect_line(&cli, "ls ga");
        assert(unmounts == 1);
        assert(closes == (error == 2));
        assert(output_len == 0);
    }

    char full[EMBEDDED_CLI_MAX_LINE];
    strcpy(full, "mount cart ");
    memset(full + 11, 'x', sizeof(full) - 12);
    full[sizeof(full) - 1] = 0;
    set_line(&cli, full);
    left(&cli, cli.len - 10);
    cli_path_complete(&cli);
    expect_line(&cli, full);
    assert(cli.cursor == 10);

    set_line(&cli, "ls ga");
    embedded_cli_insert_char(&cli, 0x12);
    cli_path_complete(&cli);
    assert(mounts == 0);

    set_line(&cli, "");
    assert(sdcard_change_directory("/") == FR_OK);
    assert(cli_directory_prompt_update(&cli));
    assert(strcmp(cli.prompt, "\e[92;1m/\e[0m> ") == 0);
    assert(sdcard_change_directory("games") == FR_OK);
    assert(cli_directory_prompt_update(&cli));
    assert(strcmp(cli.prompt, "\e[92;1m/games\e[0m> ") == 0);
    assert(sdcard_change_directory("missing") == FR_NO_PATH);
    assert(strcmp(cli.prompt, "\e[92;1m/games\e[0m> ") == 0);
    set_line(&cli, "ls /demo");
    cli_path_complete(&cli);
    assert(strstr(output, "\e[92;1m/games\e[0m> ls /demo"));

    char long_directory[101];
    memset(long_directory, 'x', sizeof(long_directory) - 1);
    long_directory[0] = '/';
    long_directory[62] = '\xc3';
    long_directory[63] = '\xa9'; // Shortening begins inside this UTF-8 character.
    long_directory[100] = 0;
    allow_long_directory = true;
    assert(sdcard_change_directory(long_directory) == FR_OK);
    assert(cli_directory_prompt_update(&cli));
    assert(strstr(cli.prompt, "...") && !strchr(cli.prompt, '\xa9'));
    assert(strlen(cli.prompt) <= 40 + strlen("\e[92;1m\e[0m> "));
    assert(strcmp(sdcard_current_directory(), long_directory) == 0);
    char resolved[SDCARD_PATH_MAX];
    assert(sdcard_resolve_path("image.d64", resolved) == FR_OK);
    assert(strncmp(resolved, long_directory, strlen(long_directory)) == 0);
    assert(strcmp(resolved + strlen(long_directory), "/image.d64") == 0);
    assert(sdcard_change_directory("/") == FR_OK);
    assert(cli_directory_prompt_update(&cli));
    assert(strcmp(cli.prompt, "\e[92;1m/\e[0m> ") == 0);

    free(cli.buffer);
    free(cli.history);
    free(cli.prompt);
    puts("PASS");
    return 0;
}
