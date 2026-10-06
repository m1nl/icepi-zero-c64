"""Run with: venv/bin/python -m unittest discover -s gateware/tests -v."""
import unittest

from migen import Memory
from migen.sim import run_simulation

from gateware.video_terminal_overlay import VideoTerminalOverlay


class VideoTerminalOverlayTest(unittest.TestCase):
    def simulate(self, check, with_csi_interpreter=True, lines=2):
        dut = VideoTerminalOverlay(hres=80, vres=16 * lines,
                                   with_csi_interpreter=with_csi_interpreter)
        memory = next(s for s in dut._fragment.specials
                      if isinstance(s, Memory) and s.depth == 10 * lines)
        write_port = next(p for p in memory.ports if p.we is not None)
        read_port = next(p for p in memory.ports if p.we is None)
        idle = dut.uart_fsm.ongoing("IDLE")

        def send(data):
            for byte in data:
                yield dut.uart_sink.data.eq(byte)
                yield dut.uart_sink.valid.eq(1)
                yield
                for _ in range(200):
                    if (yield dut.uart_sink.ready):
                        break
                    yield
                else:
                    self.fail("UART input stalled")
            yield dut.uart_sink.valid.eq(0)

        def settle():
            for _ in range(100):
                yield
            self.assertTrue((yield idle))

        def contents(displayed=False):
            values = []
            for row in range(lines):
                address = row * 10
                if displayed:
                    yield dut.video_overlay.x.eq(131)
                    yield dut.video_overlay.y.eq(16 + row * 16)
                    yield
                    address = (yield read_port.adr)
                for column in range(10):
                    values.append((yield memory[address + column]) & 0xff)
            return bytes(values)

        run_simulation(dut, check(send, settle, contents, write_port))

    def test_cursor_movement_preserves_text_and_clamps_at_edges(self):
        def check(send, settle, contents, port):
            yield from settle()
            yield from send(b"abcdef\x1b[1D\x1b[D")
            yield from settle()
            self.assertEqual((yield port.adr), 4)
            self.assertEqual((yield from contents()), b"abcdef" + b" " * 14)
            yield from send(b"\x1b[1C\x1b[C")
            yield from settle()
            self.assertEqual((yield port.adr), 6)
            yield from send(b"\x1b[H\x1b[D")
            yield from settle()
            self.assertEqual((yield port.adr), 0)
            yield from send(b"\x1b[F\x1b[C")
            yield from settle()
            self.assertEqual((yield port.adr), 9)
            self.assertEqual((yield from contents()), b"abcdef" + b" " * 14)

        self.simulate(check)

    def test_firmware_home_end_and_editing(self):
        def check(send, settle, contents, port):
            yield from settle()
            # The CLI implements Home/End with repeated one-column moves.
            yield from send(b"> abc\x1b[1D\x1b[1D\x1b[1D")
            yield from settle()
            self.assertEqual((yield port.adr), 2)
            self.assertEqual((yield from contents())[:5], b"> abc")
            yield from send(b"\x1b[1C\x1b[1C\x1b[1C\b")
            yield from settle()
            self.assertEqual((yield port.adr), 4)
            self.assertEqual((yield from contents())[:5], b"> ab ")
            yield from send(b"Z")
            yield from settle()
            self.assertEqual((yield from contents())[:5], b"> abZ")

        self.simulate(check)

    def test_commands_wait_for_initial_clear_and_stay_ordered(self):
        def check(send, settle, contents, port):
            # Queue input while the terminal is still clearing its RAM.
            yield from send(b"abc\x1b[DZ\x1b[CQ")
            yield from settle()
            self.assertEqual((yield port.adr), 5)
            self.assertEqual((yield from contents()), b"abZ Q" + b" " * 15)

        self.simulate(check)

    def test_plain_terminal_backspace_and_wrap(self):
        def check(send, settle, contents, port):
            yield from settle()
            yield from send(b"abcdefghijK\bL")
            yield from settle()
            self.assertEqual((yield port.adr), 11)
            self.assertEqual((yield from contents()), b"abcdefghijL" + b" " * 9)

        self.simulate(check, with_csi_interpreter=False)

    def test_vertical_cursor_preserves_column_text_and_screen_edges(self):
        def check(send, settle, contents, port):
            yield from settle()
            yield from send(b"first\nsecond\nthird")
            yield from settle()
            expected = b"first     second    third     "
            self.assertEqual((yield from contents(True)), expected)
            for command, address in [(b"\x1b[A", 15), (b"\x1b[A", 5),
                                     (b"\x1b[A", 5), (b"\x1b[B", 15),
                                     (b"\x1b[B", 25), (b"\x1b[B", 25)]:
                yield from send(command)
                yield from settle()
                self.assertEqual((yield port.adr), address)
                self.assertEqual((yield from contents(True)), expected)

        self.simulate(check, lines=3)

    def test_wrapped_home_end_and_redraw_preserve_following_text(self):
        def check(send, settle, contents, port):
            yield from settle()
            yield from send(b"> abcdefghijk")
            yield from settle()
            expected = b"> abcdefghijk" + b" " * 7
            yield from send(b"\x1b[1D" * 11)
            yield from settle()
            self.assertEqual((yield port.adr), 2)
            self.assertEqual((yield from contents()), expected)
            yield from send(b"\x1b[1C" * 11)
            yield from settle()
            self.assertEqual((yield port.adr), 13)
            yield from send(b"\x1b[1D" * 4 + b"Z")
            yield from settle()
            self.assertEqual((yield port.adr), 10)
            self.assertEqual((yield from contents()), b"> abcdefgZijk" + b" " * 7)
            yield from send(b"\b")
            yield from settle()
            self.assertEqual((yield port.adr), 9)
            self.assertEqual((yield from contents()), b"> abcdefg ijk" + b" " * 7)

        self.simulate(check)

    def test_navigation_after_scroll_keeps_display_origin_fixed(self):
        def check(send, settle, contents, port):
            yield from settle()
            # Four full rows leave physical row 1 at the visible bottom.
            yield from send(b"0123456789abcdefghijABCDEFGHIJklmnopqrstUV")
            yield from settle()
            expected = b"ABCDEFGHIJklmnopqrstUV        "
            self.assertEqual((yield from contents(True)), expected)
            yield from send(b"\x1b[A")
            yield from settle()
            self.assertEqual((yield port.adr), 2)
            self.assertEqual((yield from contents(True)), expected)
            yield from send(b"\x1b[A\x1b[A")
            yield from settle()
            self.assertEqual((yield port.adr), 22)
            self.assertEqual((yield from contents(True)), expected)
            yield from send(b"\x1b[B\x1b[B\x1b[B\x1b[D\x1b[D\x1b[D")
            yield from settle()
            self.assertEqual((yield port.adr), 9)
            self.assertEqual((yield from contents(True)), expected)
            yield from send(b"Z")
            yield from settle()
            self.assertEqual((yield port.adr), 10)
            self.assertEqual((yield from contents(True)), b"ABCDEFGHIJklmnopqrsZUV        ")

        self.simulate(check, lines=3)

    def test_backspace_does_not_cross_explicit_newline(self):
        def check(send, settle, contents, port):
            yield from settle()
            yield from send(b"abc\n\b\x1b[D")
            yield from settle()
            self.assertEqual((yield port.adr), 10)
            self.assertEqual((yield from contents()), b"abc" + b" " * 17)

        self.simulate(check)
