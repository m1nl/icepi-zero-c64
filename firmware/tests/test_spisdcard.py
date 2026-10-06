import subprocess
import tempfile
import unittest
from pathlib import Path


class SpiSdcardTest(unittest.TestCase):
    def test_reads_writes_and_stalled_transfers(self):
        firmware = Path(__file__).resolve().parents[1]
        software = firmware.parent / 'litex_src/litex/litex/soc/software'
        with tempfile.TemporaryDirectory() as tmp:
            includes = Path(tmp)
            generated = includes / 'generated'
            generated.mkdir()
            for name in ('csr', 'mem', 'soc'):
                (generated / f'{name}.h').write_text('')
            (includes / 'system.h').write_text('')
            binary = includes / 'test'
            subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                            '-I', str(includes), '-I', str(firmware), '-I', str(software),
                            str(firmware / 'tests/spisdcard_test.c'),
                            '-o', str(binary)], check=True)
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)
