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

import os
from math import log2

from litex.gen import *
from migen import *
from migen.genlib.cdc import MultiReg, PulseSynchronizer


class TinySDRAMPort(Record):
    def __init__(self, burst_length=1):
        self.data_width = burst_length * 16
        Record.__init__(
            self,
            [
                ("cmd_addr", 24),
                ("cmd_we", 1),
                ("cmd_valid", 1),
                ("cmd_ready", 1),
                ("wdata", self.data_width),
                ("wdata_we", burst_length * 2),
                ("wdata_ready", 1),
                ("rdata", self.data_width),
                ("rdata_valid", 1),
                ("init_complete", 1),
            ],
        )


class TinySDRAM(Module):
    def __init__(
        self,
        platform,
        pads,
        clk_freq,
        clk_domain="sys",
        p0_burst_length=1,
        p1_burst_length=2,
        cas_latency=2,
        allow_standby=1,
    ):
        self.p0 = p0 = TinySDRAMPort(p0_burst_length)
        self.p1 = p1 = TinySDRAMPort(p1_burst_length)

        self.init_complete = Signal()

        init_complete = Signal()

        p0_cmd_valid = Signal()
        p0_cmd_ready = Signal()
        p0_wdata_ready = Signal()
        p0_rdata_valid = Signal()

        p1_cmd_valid = Signal()
        p1_cmd_ready = Signal()
        p1_wdata_ready = Signal()
        p1_rdata_valid = Signal()

        if clk_domain != "sys":
            # I know this CDC sucks, but given that we have FSM attached to P0 / P1 ports
            # waiting for rdata_valid / wdata_ready, delayed deassertion cmd_ready
            # should not be a big issue...
            self.specials += [
                MultiReg(init_complete, self.init_complete, odomain="sys"),
                MultiReg(p0.cmd_valid, p0_cmd_valid, odomain=clk_domain),
                MultiReg(p0_cmd_ready, p0.cmd_ready, odomain="sys"),
                MultiReg(p1.cmd_valid, p1_cmd_valid, odomain=clk_domain),
                MultiReg(p1_cmd_ready, p1.cmd_ready, odomain="sys"),
            ]

            self.submodules.p0_wdata_ready_ps = p0_wdata_ready_ps = PulseSynchronizer(clk_domain, "sys")
            self.comb += p0_wdata_ready_ps.i.eq(p0_wdata_ready)
            self.comb += p0.wdata_ready.eq(p0_wdata_ready_ps.o)

            self.submodules.p0_rdata_valid_ps = p0_rdata_valid_ps = PulseSynchronizer(clk_domain, "sys")
            self.comb += p0_rdata_valid_ps.i.eq(p0_rdata_valid)
            self.comb += p0.rdata_valid.eq(p0_rdata_valid_ps.o)

            self.submodules.p1_wdata_ready_ps = p1_wdata_ready_ps = PulseSynchronizer(clk_domain, "sys")
            self.comb += p1_wdata_ready_ps.i.eq(p1_wdata_ready)
            self.comb += p1.wdata_ready.eq(p1_wdata_ready_ps.o)

            self.submodules.p1_rdata_valid_ps = p1_rdata_valid_ps = PulseSynchronizer(clk_domain, "sys")
            self.comb += p1_rdata_valid_ps.i.eq(p1_rdata_valid)
            self.comb += p1.rdata_valid.eq(p1_rdata_valid_ps.o)

        else:
            self.comb += [
                self.init_complete.eq(init_complete),
                p0_cmd_valid.eq(p0.cmd_valid),
                p0.cmd_ready.eq(p0_cmd_ready),
                p0.wdata_ready.eq(p0_wdata_ready),
                p0.rdata_valid.eq(p0_rdata_valid),
                p1_cmd_valid.eq(p1.cmd_valid),
                p1.cmd_ready.eq(p1_cmd_ready),
                p1.wdata_ready.eq(p1_wdata_ready),
                p1.rdata_valid.eq(p1_rdata_valid),
            ]

        self.comb += [
            p0.init_complete.eq(self.init_complete),
            p1.init_complete.eq(self.init_complete),
        ]

        self.specials += Instance(
            "tiny_sdram",
            p_CLOCK_SPEED=int(clk_freq),
            p_P0_BURST_LENGTH=p0_burst_length,
            p_P1_BURST_LENGTH=p1_burst_length,
            p_CAS_LATENCY=cas_latency,
            p_ALLOW_STANDBY=allow_standby,
            i_clk=ClockSignal(clk_domain),
            i_reset=ResetSignal(clk_domain),
            o_init_complete=init_complete,
            i_p0_cmd_addr=p0.cmd_addr,
            i_p0_cmd_we=p0.cmd_we,
            i_p0_cmd_valid=p0_cmd_valid,
            o_p0_cmd_ready=p0_cmd_ready,
            i_p0_wdata=p0.wdata,
            i_p0_wdata_we=p0.wdata_we,
            o_p0_wdata_ready=p0_wdata_ready,
            o_p0_rdata=p0.rdata,
            o_p0_rdata_valid=p0_rdata_valid,
            i_p1_cmd_addr=p1.cmd_addr,
            i_p1_cmd_we=p1.cmd_we,
            i_p1_cmd_valid=p1_cmd_valid,
            o_p1_cmd_ready=p1_cmd_ready,
            i_p1_wdata=p1.wdata,
            i_p1_wdata_we=p1.wdata_we,
            o_p1_wdata_ready=p1_wdata_ready,
            o_p1_rdata=p1.rdata,
            o_p1_rdata_valid=p1_rdata_valid,
            io_SDRAM_DQ=pads.dq,
            o_SDRAM_A=pads.a,
            o_SDRAM_DQM=pads.dm,
            o_SDRAM_BA=pads.ba,
            o_SDRAM_nCS=pads.cs_n,
            o_SDRAM_nWE=pads.we_n,
            o_SDRAM_nRAS=pads.ras_n,
            o_SDRAM_nCAS=pads.cas_n,
            o_SDRAM_CKE=pads.cke,
        )

        gateware_dir = os.path.dirname(__file__)
        platform.add_source(os.path.join(gateware_dir, "tiny_sdram.sv"))


# TinySDRAMWishboneAdapter ----------------------------------------------------------------------------


class TinySDRAMWishboneAdapter(LiteXModule):
    def __init__(self, wishbone, port, base_address=0x00000000):
        wishbone_data_width = len(wishbone.dat_w)
        port_data_width = 2 ** int(log2(len(port.wdata)))  # Round to lowest power 2

        assert wishbone.addressing == "word"
        assert wishbone_data_width == port_data_width

        # # #

        aborted = Signal()
        offset = base_address >> log2_int(port.data_width // 8)

        self.fsm = fsm = FSM(reset_state="CMD")
        self.comb += [
            port.cmd_addr.eq(wishbone.adr - offset),
            port.cmd_we.eq(wishbone.we),
        ]
        fsm.act(
            "CMD",
            port.cmd_valid.eq(wishbone.cyc & wishbone.stb),
            If(port.cmd_valid & port.cmd_ready & wishbone.we, NextState("WRITE")),
            If(port.cmd_valid & port.cmd_ready & ~wishbone.we, NextState("READ")),
            NextValue(aborted, 0),
        )
        self.comb += [
            port.wdata.eq(wishbone.dat_w),
            port.wdata_we.eq(wishbone.sel),
        ]
        fsm.act(
            "WRITE",
            port.cmd_valid.eq(0),
            NextValue(aborted, ~wishbone.cyc | aborted),
            If(
                port.wdata_ready,
                wishbone.ack.eq(wishbone.cyc & ~aborted),
                NextState("CMD"),
            ),
        )
        fsm.act(
            "READ",
            port.cmd_valid.eq(0),
            NextValue(aborted, ~wishbone.cyc | aborted),
            If(
                port.rdata_valid,
                wishbone.ack.eq(wishbone.cyc & ~aborted),
                wishbone.dat_r.eq(port.rdata),
                NextState("CMD"),
            ),
        )
