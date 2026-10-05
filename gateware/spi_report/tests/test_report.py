"""Run with: venv/bin/python -m unittest discover -s gateware/spi_report/tests -v."""
import subprocess
import json
import tempfile
import unittest
from pathlib import Path

from migen import Record
from migen.fhdl import verilog

from boards.platforms.icepi_zero import Platform
from gateware.spi_report import SPIReport


class SPIReportTest(unittest.TestCase):
    def test_c64_joystick_sources(self):
        root = Path(__file__).resolve().parents[3]
        bench = Path(__file__).with_name("c64_joystick_tb.v")
        with tempfile.TemporaryDirectory() as tmp:
            binary = str(Path(tmp) / "joysticks")
            # Test c64_top's real combining/synchronizing logic without its
            # unrelated C64 cores; USB outputs are driven by the testbench.
            subprocess.run(["iverilog", "-g2012", "-i", "-s", "c64_joystick_tb",
                            "-o", binary, str(root / "gateware" / "c64_top.v"), str(bench)],
                           check=True, capture_output=True, text=True, timeout=30)
            result = subprocess.run(["vvp", binary], check=True, capture_output=True,
                                    text=True, timeout=10)
            self.assertIn("PASS", result.stdout)

    def test_optional_expansion_pins(self):
        # MiSTle IcePi carrier wiring, ordered UDLRAB for the core/USB interface.
        locations = {"joya": ["T2", "K3", "R1", "R2", "G3", "E1"],
                     "joyb": ["H2", "G1", "L2", "J1", "F3", "G2"],
                     "led_g": ["E3"], "led_y": ["P1"], "led_r": ["N1"]}
        for leds in (False, True):
            for joysticks in (False, True):
                with self.subTest(leds=leds, joysticks=joysticks):
                    platform = Platform()
                    platform.request("spi_report")
                    platform.request("iec")
                    if leds:
                        for name in ("led_g", "led_y", "led_r"):
                            platform.request(name)
                    if joysticks:
                        platform.request("joya")
                        platform.request("joyb")
                    if not (leds or joysticks):
                        platform.request("debug")
                    seen = set()
                    for signal, pins, others, resource in platform.constraint_manager.get_sig_constraints():
                        self.assertFalse(seen.intersection(pins), (resource, pins))
                        seen.update(pins)
                        name = resource[0]
                        if name in ("joya", "joyb"):
                            self.assertEqual(pins, locations[name])
                            pull = "PULLMODE=UP"
                        elif name in ("led_g", "led_y", "led_r"):
                            self.assertEqual(pins, locations[name])
                            pull = "PULLMODE=DOWN"
                        else:
                            continue
                        self.assertTrue(any(getattr(item, "misc", None) == pull for item in others))

    def test_carrier_spi_pins(self):
        locations = {"cs_n": "N4", "clk": "L1", "mosi": "J2",
                     "miso": "F2", "irq_n": "P2"}
        platform = Platform()
        platform.request("spi_report")
        platform.request("iec")
        platform.request("gpio")
        seen = set()
        checked = set()
        for signal, pins, others, resource in platform.constraint_manager.get_sig_constraints():
            self.assertFalse(seen.intersection(pins), (resource, pins))
            seen.update(pins)
            if resource[0] == "spi_report":
                name = resource[2]
                self.assertEqual(pins, [locations[name]], name)
                self.assertTrue(any(getattr(item, "misc", None) == "PULLMODE=UP"
                                    for item in others), name)
                checked.add(name)
        self.assertEqual(checked, set(locations))

    def test_single_read_lutram(self):
        source = Path(__file__).resolve().parents[1] / "report_slave.v"
        with tempfile.TemporaryDirectory() as tmp:
            rtl = Path(tmp) / "rtl.json"
            mapped = Path(tmp) / "mapped.json"
            subprocess.run(["yosys", "-Q", "-T", "-p",
                f"read_verilog {source}; hierarchy -top spi_report_slave; "
                f"proc; opt; scc -expect 0; memory_collect; write_json {rtl}; "
                f"synth_ecp5 -top spi_report_slave; write_json {mapped}"],
                check=True, capture_output=True, text=True, timeout=30)
            cells = json.loads(rtl.read_text())["modules"]["spi_report_slave"]["cells"]
            memories = [cell for cell in cells.values() if cell["type"] == "$mem_v2"]
            self.assertEqual(len(memories), 1)
            parameters = memories[0]["parameters"]
            for name, expected in {"WIDTH": 8, "SIZE": 8, "RD_PORTS": 1,
                                   "WR_PORTS": 1, "RD_CLK_ENABLE": 0,
                                   "WR_CLK_ENABLE": 1}.items():
                self.assertEqual(int(parameters[name], 2), expected, name)
            cells = json.loads(mapped.read_text())["modules"]["spi_report_slave"]["cells"]
            self.assertEqual(sum(cell["type"] == "TRELLIS_DPR16X4"
                                 for cell in cells.values()), 2)

    def test_spi_and_wishbone(self):
        self.check_spi_and_wishbone()

    def test_spi_and_wishbone_debug(self):
        self.check_spi_and_wishbone(debug=1)

    def check_spi_and_wishbone(self, debug=None):
        pads = Record([("cs_n", 1), ("clk", 1), ("mosi", 1)], name="spi")
        kwargs = {} if debug is None else {"debug": debug}
        dut = SPIReport(Platform(), pads, **kwargs)
        self.assertEqual([csr.name for csr in dut.get_csrs()], ["status"])
        ports = {pads.cs_n, pads.clk, pads.mosi, dut.bus.cyc, dut.bus.stb,
                 dut.bus.we, dut.bus.adr, dut.bus.sel, dut.bus.ack,
                 dut.bus.dat_r, dut.status.status, dut.irq}
        with tempfile.TemporaryDirectory() as tmp:
            top = Path(tmp) / "top.v"
            top.write_text(str(verilog.convert(dut, ios=ports, name="spi_report_top")))
            binary = Path(tmp) / "sim"
            subprocess.run(["iverilog", "-g2012", "-s", "tb",
                            f"-Ptb.DEBUG={debug or 0}", "-o", str(binary),
                            str(top), str(Path(__file__).parents[1] / "report_slave.v"),
                            str(Path(__file__).with_name("report_tb.v"))], check=True)
            result = subprocess.run(["vvp", str(binary)], text=True,
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
