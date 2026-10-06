import subprocess
import tempfile
import unittest
from pathlib import Path


class CLIPathCompletionTest(unittest.TestCase):
    def test_path_completion(self):
        firmware = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / 'completion_test'
            subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                            '-I', str(firmware),
                            str(firmware / 'tests' / 'cli_path_completion_test.c'),
                            str(firmware / 'cli_path_completion.c'),
                            str(firmware / 'sdcard_paths.c'),
                            str(firmware / 'embedded_cli.c'), '-o', str(binary)],
                           check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)
