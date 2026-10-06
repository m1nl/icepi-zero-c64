#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "embedded_cli.h"

static char output[8192];
static size_t output_length;

static void put_char(void *data, char ch, bool is_last) {
    (void)data; (void)is_last;
    assert(output_length + 1 < sizeof(output));
    output[output_length++] = ch;
    output[output_length] = 0;
}
static void send(struct embedded_cli *cli, const char *text) {
    while (*text) assert(!embedded_cli_insert_char(cli, *text++));
}
static void clear_output(void) { output_length = 0; output[0] = 0; }
static void expect_moves(char direction, int count) {
    const char *move = direction == 'D' ? "\x1b[1D" : "\x1b[1C";
    assert(output_length == (size_t)count * 4);
    for (int i = 0; i < count; i++) assert(memcmp(output + i * 4, move, 4) == 0);
}

int main(void) {
    const char *home[] = {"\x1b[H", "\x1b[1~", "\x1b[7~", "\x1bOH"};
    const char *end[] = {"\x1b[F", "\x1b[4~", "\x1b[8~", "\x1bOF"};
    struct embedded_cli cli;
    assert(embedded_cli_init(&cli, "/games> ", put_char, NULL) == 0);
    for (size_t i = 0; i < sizeof(home) / sizeof(home[0]); i++) {
        embedded_cli_insert_char(&cli, 3);
        send(&cli, "abcdefghijklmnop"); // Long enough to wrap in the framebuffer tests.
        clear_output();
        send(&cli, home[i]);
        assert(cli.cursor == 0 && cli.len == 16);
        expect_moves('D', 16);
        clear_output();
        send(&cli, home[i]);
        expect_moves('D', 0);
        clear_output();
        send(&cli, end[i]);
        assert(cli.cursor == 16);
        expect_moves('C', 16);
        clear_output();
        send(&cli, end[i]);
        expect_moves('C', 0);
        send(&cli, home[i]);
        send(&cli, "Z");
        assert(strcmp(cli.buffer, "Zabcdefghijklmnop") == 0 && cli.cursor == 1);
        clear_output();
        send(&cli, end[i]);
        assert(cli.cursor == 17);
        expect_moves('C', 16);
        send(&cli, "\b");
        assert(strcmp(cli.buffer, "Zabcdefghijklmno") == 0 && cli.cursor == 16);
    }
    // SS3 recognition must not change ordinary printable O characters.
    embedded_cli_insert_char(&cli, 3);
    send(&cli, "FOO");
    assert(strcmp(cli.buffer, "FOO") == 0);
    free(cli.buffer);
    free(cli.history);
    free(cli.prompt);
    puts("PASS");
    return 0;
}
