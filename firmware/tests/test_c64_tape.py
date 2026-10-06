import subprocess
import tempfile
import unittest
from pathlib import Path


class C64TapeTest(unittest.TestCase):
    def test_dma_padding_and_start_failure(self):
        firmware = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            includes = Path(tmp)
            generated = includes / 'generated'
            generated.mkdir()
            (generated / 'csr.h').write_text('''#include <stdint.h>
void tap_dma_enable_write(uint32_t);
void tap_dma_base_write(uint64_t);
void tap_dma_length_write(uint32_t);
void tap_dma_loop_write(uint32_t);
uint32_t tap_dma_error_read(void);
uint32_t c64_control_tape_cass_sense_read(void);
uint32_t c64_control_tape_play_read(void);
void c64_control_tape_play_write(uint32_t);
uint32_t c64_control_ev_enable_read(void);
void c64_control_ev_enable_write(uint32_t);
''')
            (includes / 'irq.h').write_text('')
            (includes / 'system.h').write_text('''void busy_wait(unsigned int);
void flush_cpu_dcache(void);
void flush_l2_cache(void);
''')
            binary = includes / 'test'
            subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                            '-I', str(includes), '-I', str(firmware),
                            str(firmware / 'tests' / 'c64_tape_test.c'),
                            '-o', str(binary)], check=True)
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)
