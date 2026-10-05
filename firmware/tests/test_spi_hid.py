"""Run with: python3 -m unittest discover -s firmware/tests -v."""
import subprocess
import tempfile
import unittest
from pathlib import Path


class CompanionHIDTest(unittest.TestCase):
    def test_irq_to_ps2(self):
        firmware = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            includes = Path(tmp)
            generated = includes / "generated"
            generated.mkdir()
            (generated / "csr.h").write_text(
                "#include <stdint.h>\nuint32_t spi_report_status_read(void);\n"
                "void c64_control_companion_joy_a_write(uint32_t);\n"
                "void c64_control_companion_joy_b_write(uint32_t);\n"
                "#define CSR_TIMER0_UPTIME_CYCLES_ADDR 0\n"
                "#define CONFIG_CLOCK_FREQUENCY 1000000\n"
                "void timer0_uptime_latch_write(uint32_t);\n"
                "uint64_t timer0_uptime_cycles_read(void);\n")
            (generated / "mem.h").write_text(
                "#define SPI_REPORT_BASE 0xb0000000u\n"
                "#define SPI_HID_READ8(offset) test_read_byte(offset)\n"
                "#define SPI_HID_READ32(offset) test_read_word(offset)\n")
            (includes / "irq.h").write_text(
                "#define SPI_REPORT_INTERRUPT 2\n"
                "unsigned int irq_getmask(void);\nvoid irq_setmask(unsigned int);\n"
                "unsigned int irq_pending(void);\n")
            binary = includes / "test"
            for debug in (0, 1):
                with self.subTest(debug=debug):
                    subprocess.run(["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                                    f"-DSPI_HID_DEBUG={debug}",
                                    "-I", str(includes), "-I", str(firmware),
                                    str(firmware / "tests" / "spi_hid_test.c"),
                                    "-o", str(binary)], check=True)
                    result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("PASS", result.stdout)
                    if debug:
                        self.assertIn("[spi] report len=5: 01 01 04 04 1c", result.stdout)
                        self.assertIn("[spi] report len=5: 01 01 2c 2c 29", result.stdout)
                        self.assertIn("[spi] report len=6: 01 01 ac 2c f0 29", result.stdout)
                        self.assertIn("[spi] report len=6: 01 02 01 ff 01 00", result.stdout)
                        self.assertIn("[spi] report len=12: 01 01 48 48 e1 14 77 e1 f0 14 f0 77", result.stdout)
                        self.assertIn("[spi] status=00 bytes=", result.stdout)
                        self.assertIn("overruns=4 irq=0 dropped=1", result.stdout)
                    else:
                        self.assertNotIn("[spi]", result.stdout)


if __name__ == "__main__":
    unittest.main()
