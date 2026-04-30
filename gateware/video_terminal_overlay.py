#
# This file is part of LiteX.
#
# Copyright (c) 2021-2022 Florent Kermarrec <florent@enjoy-digital.fr>
# Copyright (c) 2021 Romain Dolbeau <romain@dolbeau.org>
# Copyright (c) 2022 Franck Jullien <franck.jullien@collshade.fr>
# SPDX-License-Identifier: BSD-2-Clause

# Adapted and modified for Icepi Zero C64 project by m1nl

import math
import os

from litex.gen import *
from litex.soc.interconnect import stream
from migen import *


def import_bdf_font(filename):
    import csv

    font = [0] * 16 * 256
    with open(filename) as f:
        reader = csv.reader(f, delimiter=" ")
        char = None
        bitmap_enable = False
        bitmap_index = 0
        for l in reader:
            if l[0] == "ENCODING":
                char = int(l[1], 0)
            if l[0] == "ENDCHAR":
                bitmap_enable = False
            if bitmap_enable:
                if char < 256:
                    font[char * 16 + bitmap_index] = int("0x" + l[0], 0)
                bitmap_index += 1
            if l[0] == "BITMAP":
                bitmap_enable = True
                bitmap_index = 0
    return font


class CSIInterpreter(LiteXModule):
    # FIXME: Very basic/minimal implementation for now.
    esc_start = 0x1B
    csi_start = ord("[")
    csi_param_min = 0x30
    csi_param_max = 0x3F

    def __init__(self, enable=True):
        self.sink = sink = stream.Endpoint([("data", 8)])
        self.source = source = stream.Endpoint([("data", 8)])

        self.color = Signal(4)
        self.clear_xy = Signal()
        self.clear_x = Signal()
        self.reset_x = Signal()
        self.dec_y = Signal()
        self.incr_y = Signal()
        self.incr_x = Signal()
        self.dec_x = Signal()

        # # #

        if not enable:
            self.comb += self.sink.connect(self.source)
            return

        csi_count = Signal(3)
        csi_bytes = Array([Signal(8) for _ in range(8)])
        csi_final = Signal(8)

        self.fsm = fsm = FSM(reset_state="RECOPY")
        fsm.act(
            "RECOPY",
            sink.connect(source),
            If(
                sink.valid & (sink.data == self.esc_start),
                source.valid.eq(0),
                sink.ready.eq(1),
                NextState("GET-CSI-START"),
            ),
        )
        fsm.act(
            "GET-CSI-START",
            sink.ready.eq(1),
            If(
                sink.valid,
                If(sink.data == self.csi_start, NextValue(csi_count, 0), NextState("GET-CSI-PARAMETERS")).Else(
                    NextState("RECOPY")
                ),
            ),
        )
        fsm.act(
            "GET-CSI-PARAMETERS",
            If(
                sink.valid,
                If(
                    (sink.data >= self.csi_param_min) & (sink.data <= self.csi_param_max),
                    sink.ready.eq(1),
                    NextValue(csi_count, csi_count + 1),
                    NextValue(csi_bytes[csi_count], sink.data),
                ).Else(NextState("GET-CSI-FINAL")),
            ),
        )
        fsm.act("GET-CSI-FINAL", sink.ready.eq(1), NextValue(csi_final, sink.data), NextState("DECODE-CSI"))
        fsm.act(
            "DECODE-CSI",
            If(
                csi_final == ord("m"),
                If(
                    (csi_bytes[0] == ord("9")) and (csi_bytes[1] == ord("2")),
                    NextValue(self.color, 1),  # FIXME: Add Palette.
                ).Else(
                    NextValue(self.color, 0),  # FIXME: Add Palette.
                ),
            ),
            If(csi_final == ord("J"), self.clear_xy.eq(1)),
            If(csi_final == ord("K"), self.clear_x.eq(1)),
            If(csi_final == ord("G"), self.reset_x.eq(1)),
            If(csi_final == ord("A"), self.dec_y.eq(1)),  # FIXME: Support multiple columns / lines
            If(csi_final == ord("B"), self.incr_y.eq(1)),
            If(csi_final == ord("C"), self.incr_x.eq(1)),
            If(csi_final == ord("D"), self.dec_x.eq(1)),
            NextState("RECOPY"),
        )


class VideoOverlay(Record):
    def __init__(self):
        Record.__init__(
            self,
            [("rgb", 24), ("x", 11), ("y", 10), ("valid", 1)],
        )


class VideoTerminalOverlay(LiteXModule):
    def __init__(self, hstart=132, vstart=16, hres=720, vres=576, with_csi_interpreter=True):
        self.enable = Signal(reset=1)
        self.uart_sink = uart_sink = stream.Endpoint([("data", 8)])
        self.video_overlay = video_overlay = VideoOverlay()

        # # #

        csi_width = 8 if with_csi_interpreter else 0

        # Font Mem.
        # ---------
        # FIXME: Store Font in LiteX?
        if not os.path.exists("ter-u16b.bdf"):
            os.system("wget https://github.com/enjoy-digital/litex/files/6076336/ter-u16b.txt")
            os.system("mv ter-u16b.txt ter-u16b.bdf")
        font = import_bdf_font("ter-u16b.bdf")
        font_width = 8
        font_height = 16
        font_mem = Memory(width=8, depth=4096, init=font)
        font_rdport = font_mem.get_port(has_re=True)
        self.specials += font_mem, font_rdport

        # Terminal Mem.
        # -------------
        term_columns = int(min(math.floor(hres / font_width), 128))  # 128 is max when using 7 bits for x_term
        term_columns_2 = int(2 ** math.ceil(math.log2(term_columns)))  # next power of two bigger or equal term_columns
        term_lines = int(min(math.floor(vres / font_height), 64))  # 64 is max when using 6 bits for y_term
        term_depth = term_columns_2 * term_lines
        term_init = [ord(c) for c in [" "] * term_columns_2 * term_lines]
        term_mem = Memory(width=font_width + csi_width, depth=term_depth, init=term_init)
        term_wrport = term_mem.get_port(write_capable=True)
        term_rdport = term_mem.get_port(has_re=True)
        self.specials += term_mem, term_wrport, term_rdport

        # UART Terminal Fill.
        # -------------------

        # Optional CSI Interpreter.
        self.csi_interpreter = CSIInterpreter(enable=with_csi_interpreter)
        self.comb += uart_sink.connect(self.csi_interpreter.sink)
        uart_sink = self.csi_interpreter.source
        self.comb += term_wrport.dat_w[font_width:].eq(self.csi_interpreter.color)

        self.uart_fifo = stream.SyncFIFO([("data", 8)], 8)
        self.comb += uart_sink.connect(self.uart_fifo.sink)
        uart_sink = self.uart_fifo.source

        # UART Reception and Terminal Fill.
        x_term = Signal(7)
        x_term_i = Signal(7)
        y_term = Signal(6)
        y_term_rollover = Signal()
        self.comb += term_wrport.adr.eq(x_term | (y_term << 7))
        self.uart_fsm = uart_fsm = FSM(reset_state="RESET")
        uart_fsm.act("RESET", NextValue(x_term, 0), NextValue(x_term_i, 0), NextValue(y_term, 0), NextState("CLEAR-XY"))
        uart_fsm.act(
            "CLEAR-XY",
            term_wrport.we.eq(1),
            term_wrport.dat_w[:font_width].eq(ord(" ")),
            NextValue(y_term_rollover, 0),
            NextValue(x_term, x_term + 1),
            If(
                x_term == (term_columns - 1),
                NextValue(x_term, 0),
                NextValue(y_term, y_term + 1),
                If(y_term == (term_lines - 1), NextValue(y_term, 0), NextState("IDLE")),
            ),
        )
        uart_fsm.act(
            "IDLE",
            If(
                uart_sink.valid,
                If(uart_sink.data == ord("\n"), uart_sink.ready.eq(1), NextState("INCR-Y"))  # Ack sink.
                .Elif(uart_sink.data == ord("\r"), uart_sink.ready.eq(1), NextState("RST-X"))  # Ack sink.
                .Elif(uart_sink.data == ord("\b"), uart_sink.ready.eq(1), NextState("DEC-X"))  # Ack sink.
                .Else(NextState("WRITE")),
            ),
            If(self.csi_interpreter.clear_xy, NextValue(x_term, 0), NextState("CLEAR-XY")),
            If(self.csi_interpreter.clear_x, NextState("CLEAR-X")),
            If(self.csi_interpreter.reset_x, NextState("RST-X")),
            If(self.csi_interpreter.dec_y, NextState("DEC-Y")),
            If(self.csi_interpreter.incr_y, NextState("INCR-Y")),
            If(self.csi_interpreter.incr_x, NextState("INCR-X")),
            If(self.csi_interpreter.dec_x, NextState("DEC-X")),
            NextValue(x_term_i, x_term),
        )
        uart_fsm.act(
            "WRITE",
            uart_sink.ready.eq(1),
            term_wrport.we.eq(1),
            term_wrport.dat_w[:font_width].eq(uart_sink.data),
            NextState("INCR-X"),
        )
        uart_fsm.act(
            "CLEAR",
            uart_sink.ready.eq(1),
            term_wrport.we.eq(1),
            term_wrport.dat_w[:font_width].eq(ord(" ")),
            NextState("IDLE"),
        )
        uart_fsm.act("RST-X", NextValue(x_term, 0), NextState("IDLE"))
        uart_fsm.act("DEC-X", NextValue(x_term, x_term - 1), If(x_term == 0, NextValue(x_term, 0)), NextState("CLEAR"))
        uart_fsm.act(
            "INCR-X",
            NextValue(x_term, x_term + 1),
            NextState("IDLE"),
            If(x_term == (term_columns - 1), NextValue(x_term_i, 0), NextState("INCR-Y")),
        )
        uart_fsm.act("RST-Y", NextValue(y_term, 0), NextValue(x_term_i, 0), NextState("CLEAR-X"))
        uart_fsm.act(
            "DEC-Y",
            NextValue(y_term, y_term - 1),
            If(y_term == 0, NextValue(y_term, 0), NextState("IDLE")),
        )
        uart_fsm.act(
            "INCR-Y",
            NextValue(y_term, y_term + 1),
            NextValue(x_term, 0),
            NextState("CLEAR-X"),
            If(y_term == (term_lines - 1), NextValue(y_term_rollover, 1), NextState("RST-Y")),
        )
        uart_fsm.act(
            "CLEAR-X",
            NextValue(x_term, x_term + 1),
            term_wrport.we.eq(1),
            term_wrport.dat_w[:font_width].eq(ord(" ")),
            If(x_term == (term_columns - 1), NextValue(x_term, x_term_i), NextState("IDLE")),
        )

        # Video Generation.
        # -----------------

        pipeline_delay = 2 - 1  # Video generation pipeline delay is 2, but 1 is expected by video sink.

        hcount = Signal(len(video_overlay.x))
        vcount = Signal(len(video_overlay.y))
        self.comb += [hcount.eq(video_overlay.x - hstart + pipeline_delay), vcount.eq(video_overlay.y - vstart)]

        ce = Signal()
        self.comb += ce.eq(
            ((video_overlay.x + pipeline_delay) >= hstart)
            & ((video_overlay.x + pipeline_delay) < (hstart + hres))
            & (video_overlay.y >= vstart)
            & (video_overlay.y < (vstart + vres))
        )

        # Compute X/Y position.
        shift_x = log2_int(font_width)
        shift_y = log2_int(font_height)
        x = hcount[shift_x:]
        y = vcount[shift_y:]

        y_rollover = Signal(len(y_term))
        y_rollover_sum = Signal(len(y_rollover) + 1)

        self.comb += y_rollover_sum.eq(y + y_term + 1)
        self.comb += [
            If(~y_term_rollover, y_rollover.eq(y)).Else(
                y_rollover.eq(Mux(y_rollover_sum >= term_lines, y_rollover_sum - term_lines, y_rollover_sum))
            )
        ]

        # Get character from Terminal Mem.
        term_dat_r = Signal(font_width)
        self.comb += term_rdport.re.eq(ce)
        self.comb += term_rdport.adr.eq(x + y_rollover * term_columns_2)
        self.comb += [
            term_dat_r.eq(term_rdport.dat_r[:font_width]),
            If(
                (x >= term_columns) | (y >= term_lines),
                term_dat_r.eq(ord(" ")),  # Out of range, generate space.
            ),
        ]

        # Delay signals in pipeline
        ce_d = Signal()
        ce_d2 = Signal()
        vcount_d = Signal(len(vcount))
        hcount_d = Signal(len(hcount))
        hcount_d2 = Signal(len(hcount))

        self.sync += ce_d.eq(ce)
        self.sync += ce_d2.eq(ce_d)
        self.sync += vcount_d.eq(vcount)
        self.sync += hcount_d.eq(hcount)
        self.sync += hcount_d2.eq(hcount_d)

        # Translate character to video data through Font Mem.
        self.comb += font_rdport.re.eq(ce_d)
        self.comb += font_rdport.adr.eq(term_dat_r * font_height + vcount_d[:4])
        bit = Signal()
        cases = {}
        for i in range(font_width):
            cases[i] = [bit.eq(font_rdport.dat_r[font_width - 1 - i])]
        self.comb += Case(hcount_d2[:shift_x], cases)
        # FIXME: Add Palette.
        cursor = Signal()
        rgb = Signal(len(video_overlay.rgb))
        self.comb += cursor.eq((hcount_d2[shift_x:] == x_term) & (y_rollover == y_term))
        self.comb += [
            If(
                bit,
                Case(
                    term_rdport.dat_r[font_width:],
                    {
                        0: [rgb.eq(0xFFFFFF)],
                        1: [rgb.eq(0x89E234)],
                    },
                ),
            ).Else(
                rgb.eq(0x000000),
            )
        ]
        self.comb += video_overlay.rgb.eq(Mux(cursor, ~rgb, rgb))
        video_overlay.valid.eq(ce_d2)
