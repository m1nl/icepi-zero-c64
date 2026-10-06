import subprocess
import tempfile
import unittest
from pathlib import Path


class FlagCommandTest(unittest.TestCase):
    def test_names_numbers_actions_and_invalid_arguments(self):
        firmware = Path(__file__).resolve().parents[1]
        main = (firmware / 'main.c').read_text()
        # Exercise the actual command and register update without the SoC main loop.
        update = main[main.index('static void c64_flag('):main.index('static int c64_default_cart_load(')]
        command = main[main.index('static void flag_cmd('):main.index('static void c64_init_cmd(')]
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'test.c'
            source.write_text('''#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "main.h"
static uint32_t flags;
static unsigned int writes, saves;
static uint32_t c64_control_flags_read(void) { return flags; }
static void c64_control_flags_write(uint32_t value) { flags = value; writes++; }
static int c64_flags_save(void) { saves++; return 0; }
''' + update + command + r'''
static void run(const char *name, const char *action) {
    char *args[] = {(char *)name, (char *)action};
    flag_cmd(action ? 2 : 1, args);
}
int main(void) {
    const char *enable[] = {"1", "enable", "on"};
    const char *disable[] = {"0", "disable", "off"};
    for (int i = 0; i < FLAG_DEFS_COUNT; i++) {
        char number[16];
        snprintf(number, sizeof(number), "%d", flag_defs[i].bit);
        uint32_t mask = 1u << flag_defs[i].bit;
        for (int form = 0; form < 2; form++) {
            const char *identifier = form ? number : flag_defs[i].name;
            for (int action = 0; action < 3; action++) {
                flags = 0xaaaaaaaa & ~mask;
                uint32_t before = flags;
                run(identifier, enable[action]);
                assert(flags == (before | mask));
                run(identifier, disable[action]);
                assert(flags == before);
            }
            run(identifier, "toggle");
            assert(flags & mask);
            run(identifier, NULL);
            assert(!(flags & mask));
        }
    }
    run("09", "1"); // Numbers are decimal, including leading zeroes.
    assert(flags & (1u << 9));
    uint32_t before = flags;
    unsigned int before_writes = writes, before_saves = saves;
    const char *invalid_ids[] = {"", "-1", "+1", "15", "31", "32", "6x", "unknown",
                                 "999999999999999999999999999999"};
    for (unsigned int i = 0; i < sizeof(invalid_ids) / sizeof(invalid_ids[0]); i++)
        run(invalid_ids[i], "enable");
    const char *invalid_actions[] = {"", "2", "-1", "1x", "enabled", "garbage"};
    for (unsigned int i = 0; i < sizeof(invalid_actions) / sizeof(invalid_actions[0]); i++)
        run("overlay", invalid_actions[i]);
    char *args[] = {"overlay", "1", "extra"};
    flag_cmd(0, args);
    flag_cmd(3, args);
    assert(flags == before && writes == before_writes && saves == before_saves);
    assert(writes == saves);
    puts("PASS");
    return 0;
}
''')
            binary = Path(tmp) / 'test'
            subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                            '-I', str(firmware), str(source), '-o', str(binary)], check=True)
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)
