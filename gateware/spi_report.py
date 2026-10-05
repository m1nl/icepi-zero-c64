# ---------------------------------------------------------------------------
# Copyright 2026 Mateusz Nalewajski
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# ---------------------------------------------------------------------------
# Co-developed by GPT-6.1 Sol
# ---------------------------------------------------------------------------
# Receive-only MCU SPI, mode 1, MSB first.
# ---------------------------------------------------------------------------

from pathlib import Path

from litex.gen import LiteXModule
from litex.soc.interconnect import wishbone
from litex.soc.interconnect.csr import CSRStatus
from migen import (
    Cat,
    ClockSignal,
    Constant,
    If,
    Instance,
    Module,
    Mux,
    ResetSignal,
    Signal,
)


class SPIReport(LiteXModule):
    def __init__(self, platform, pads, debug=0):
        self.bus = bus = wishbone.Interface(data_width=32, addressing="word")
        self.status = CSRStatus(
            2,
            name="status",
            description=(
                "Bit 0: unread buffer bytes (fifo not empty). "
                "Bit 1: SPI selected or receive bits still being recorded."
            ),
        )
        self.irq = Signal()
        # LiteX's IRQ discovery expects module.ev.irq. A plain Module avoids
        # adding EventManager pending/enable CSRs: memory reads clear the IRQ.
        self.ev = Module()
        self.ev.irq = self.irq

        not_empty = Signal()
        receiving = Signal()
        read_ack = Signal()
        read_data = Signal(8)
        write_count = Signal(32)
        head_info = Signal(32)
        lane_data = Signal(32)
        result = Signal(32)
        transfer = Signal()

        self.comb += [
            transfer.eq(bus.cyc & bus.stb & ~bus.ack),
            bus.err.eq(0),
            # A byte load needs data in its selected bus lane. Word loads
            # select lane zero and return a zero-extended eight-bit value.
            lane_data.eq(
                Mux(
                    bus.sel[0],
                    read_data,
                    Mux(
                        bus.sel[1],
                        Cat(Constant(0, 8), read_data),
                        Mux(bus.sel[2], Cat(Constant(0, 16), read_data), Cat(Constant(0, 24), read_data)),
                    ),
                )
            ),
            result.eq(Mux(bus.adr[1], Mux(bus.adr[0], head_info, write_count), lane_data)),
            read_ack.eq(transfer & ~bus.we & ~bus.adr[1] & (bus.sel != 0)),
            self.status.status.eq(Cat(not_empty, receiving)),
        ]

        # Capture the current head and pop it on the same edge. Registered
        # response stays stable even if SPI writes while ACK is asserted.
        self.sync += [bus.ack.eq(transfer), If(transfer, bus.dat_r.eq(result))]
        platform.add_source(str(Path(__file__).resolve().parent / "spi_report" / "report_slave.v"))

        self.specials += Instance(
            "spi_report_slave",
            p_DEBUG=debug,
            i_clk=ClockSignal(),
            i_reset=ResetSignal(),
            i_spi_cs_n=pads.cs_n,
            i_spi_clk=pads.clk,
            i_spi_mosi=pads.mosi,
            i_rd_ack=read_ack,
            o_rd_data=read_data,
            o_not_empty=not_empty,
            o_receiving=receiving,
            o_irq=self.irq,
            o_wr_count=write_count,
            o_head_info=head_info,
        )
