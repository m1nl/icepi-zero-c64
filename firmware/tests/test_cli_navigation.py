import subprocess
import tempfile
import unittest
from pathlib import Path


class CliNavigationTest(unittest.TestCase):
    def test_home_end_encodings_and_terminal_output(self):
        firmware = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / 'test'
            subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                            '-I', str(firmware),
                            str(firmware / 'tests/cli_navigation_test.c'),
                            str(firmware / 'embedded_cli.c'), '-o', str(binary)], check=True)
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)
