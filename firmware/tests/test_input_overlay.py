import subprocess
import tempfile
import unittest
from pathlib import Path


class InputOverlayTest(unittest.TestCase):
    def test_companion_overlay_routing(self):
        firmware = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            includes = Path(tmp)
            generated = includes / 'generated'
            generated.mkdir()
            (generated / 'mem.h').write_text('')
            (generated / 'csr.h').write_text('''#include <stdint.h>
uint32_t c64_control_flags_read(void);
void c64_control_flags_write(uint32_t);
uint32_t c64_control_hid_key_0_read(void);
uint32_t c64_control_hid_key_modifiers_read(void);
uint32_t c64_control_ev_enable_read(void);
void c64_control_ev_enable_write(uint32_t);
void c64_control_ps2_character_data_write(uint32_t);
void c64_control_ps2_character_valid_write(uint32_t);
uint32_t c64_control_ps2_character_valid_read(void);
''')
            (includes / 'irq.h').write_text('')
            libbase = includes / 'libbase'
            libbase.mkdir()
            (libbase / 'console.h').write_text('void busy_wait(unsigned int);\n')
            (libbase / 'uart.h').write_text('int readchar_nonblock(void);\n')
            binary = includes / 'test'
            subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                            '-I', str(includes), '-I', str(firmware),
                            str(firmware / 'tests' / 'input_overlay_test.c'),
                            '-o', str(binary)], check=True)
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)
