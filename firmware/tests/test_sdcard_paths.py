import subprocess
import tempfile
import unittest
from pathlib import Path


class SdcardPathsTest(unittest.TestCase):
    def test_current_directory_and_sorted_listing(self):
        firmware = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / 'test'
            subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                            '-I', str(firmware),
                            str(firmware / 'tests/sdcard_paths_test.c'),
                            str(firmware / 'sdcard_paths.c'), '-o', str(binary)], check=True)
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)
