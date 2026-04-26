#!/usr/bin/env python3

#
# This file is part of LiteX-Boards.
#
# Copyright (c) 2020 Florent Kermarrec <florent@enjoy-digital.fr>
# SPDX-License-Identifier: BSD-2-Clause

# Adapted and modified for Icepi Zero C64 project by m1nl

from litex.build.io import DDROutput
from litex.gen import *
from litex.soc.cores.bitbang import I2CMaster
from litex.soc.cores.clock import *
from litex.soc.cores.dma import *
from litex.soc.integration.builder import *
from litex.soc.integration.soc import SoCRegion
from litex.soc.integration.soc_core import *
from litex.soc.interconnect import stream, wishbone
from migen import *

from boards.platforms import icepi_zero
from gateware.c64_top import C64Top
from gateware.tiny_sdram import TinySDRAM, TinySDRAMWishboneAdapter
from gateware.video_terminal_overlay import VideoTerminalOverlay

# CRG ----------------------------------------------------------------------------------------------

SYS_CLK_FREQUENCY = 31.43e6
TMDS_CLK_FREQUENCY = SYS_CLK_FREQUENCY * 35 / 40
USB_CLK_FREQ = 60e6


class _CRG(LiteXModule):
    def __init__(
        self, platform, sys_clk_freq, sdram_rate="1:1", tmds_clk_freq=TMDS_CLK_FREQUENCY, usb_clk_freq=USB_CLK_FREQ
    ):
        self.rst = Signal()
        self.cd_sys = ClockDomain()
        if sdram_rate == "1:3":
            self.cd_sys3x = ClockDomain()
            self.cd_sys3x_ps = ClockDomain()
        else:
            self.cd_sys_ps = ClockDomain()
        self.cd_usb = ClockDomain()
        self.cd_tmds = ClockDomain()
        self.cd_tmds5x = ClockDomain()

        # Clock
        clk50 = platform.request("clk50")
        rst = platform.request("rst")

        # PLL
        self.pll = pll = ECP5PLL()
        self.comb += pll.reset.eq(~rst)
        pll.register_clkin(clk50, 50e6)
        pll.create_clkout(self.cd_sys, sys_clk_freq, margin=1e-3)
        pll.create_clkout(self.cd_usb, usb_clk_freq)

        if sdram_rate == "1:3":
            pll.create_clkout(self.cd_sys3x, 3 * sys_clk_freq)
            pll.create_clkout(self.cd_sys3x_ps, 3 * sys_clk_freq, phase=90)
        else:
            pll.create_clkout(
                self.cd_sys_ps, sys_clk_freq, phase=45
            )  # TODO: also remove extra CL delay (SETTING_USE_FAST_INPUT_REGISTER)

        # SDRAM clock
        sdram_clk = ClockSignal("sys3x_ps" if sdram_rate == "1:3" else "sys_ps")
        self.specials += DDROutput(1, 0, platform.request("sdram_clock"), sdram_clk)

        # Video clock
        self.video_pll = video_pll = ECP5PLL()
        self.comb += video_pll.reset.eq(~rst)
        video_pll.register_clkin(self.cd_sys.clk, sys_clk_freq)
        video_pll.create_clkout(self.cd_tmds, tmds_clk_freq, margin=1e-3)
        video_pll.create_clkout(self.cd_tmds5x, tmds_clk_freq * 5)


# BaseSoC ------------------------------------------------------------------------------------------


class BaseSoC(SoCCore):
    mem_map = {
        **SoCCore.mem_map,
        **{"spiflash": 0x20000000, "drive_shmem": 0x50000000, "drive_rom": 0x60000000},
    }

    def __init__(
        self,
        device="LFE5U-25F",
        toolchain="trellis",
        sys_clk_freq=SYS_CLK_FREQUENCY,
        tmds_clk_freq=TMDS_CLK_FREQUENCY,
        sdram_rate="1:1",
        l2_size=0,
        with_spi_flash=True,
        **kwargs,
    ):
        platform = icepi_zero.Platform(device=device, toolchain=toolchain)

        # CRG --------------------------------------------------------------------------------------
        uart_name = kwargs.get("uart_name", "serial")
        self.crg = _CRG(platform, sys_clk_freq, sdram_rate=sdram_rate)

        # SoCCore ----------------------------------------------------------------------------------
        SoCCore.__init__(self, platform, sys_clk_freq, ident="LiteX SoC on Icepi Zero", **kwargs)

        # SDR SDRAM --------------------------------------------------------------------------------
        sdram_size = 0x2000000

        self.tiny_sdram = TinySDRAM(
            platform,
            platform.request("sdram"),
            p0_burst_length=1,
            p1_burst_length=2,
            clk_domain="sys3x" if sdram_rate == "1:3" else "sys",
            clk_freq=sys_clk_freq * (3 if sdram_rate == "1:3" else 1),
        )

        main_ram_region = SoCRegion(origin=self.mem_map.get("main_ram"), size=sdram_size, mode="rwx")
        self.bus.add_region("main_ram", main_ram_region)

        sdram_wb = wishbone.Interface(
            data_width=self.bus.data_width, address_width=self.bus.address_width, addressing="word"
        )
        self.bus.add_slave(name="main_ram", slave=sdram_wb)
        self.sdram_wb_bridge = TinySDRAMWishboneAdapter(
            wishbone=sdram_wb, port=self.tiny_sdram.p1, base_address=self.bus.regions["main_ram"].origin
        )

        # SPI Flash --------------------------------------------------------------------------------
        if with_spi_flash:
            from litespi.modules import W25Q128JV
            from litespi.opcodes import SpiNorFlashOpCodes as Codes

            bios_flash_offset = 0x200000
            bios_flash_size = 0x10000
            self.add_spi_flash(mode="4x", module=W25Q128JV(Codes.READ_1_1_4), with_master=False)
            self.bus.add_region(
                "rom",
                SoCRegion(
                    origin=self.bus.regions["spiflash"].origin + bios_flash_offset,
                    size=bios_flash_size,
                    linker=True,
                    mode="rx",
                ),
            )
            self.cpu.set_reset_address(self.bus.regions["rom"].origin)

        # System I2C (behing multiplexer) ----------------------------------------------------------
        i2c_pads = platform.request("i2c")
        self.i2c = I2CMaster(i2c_pads)

        # TMDS -------------------------------------------------------------------------------------
        tmds = platform.request("gpdi")

        self.tmds_0 = Signal(10)
        self.tmds_1 = Signal(10)
        self.tmds_2 = Signal(10)

        drive_pols = []
        for pol in ["p", "n"]:
            if hasattr(tmds, f"clk_{pol}"):
                drive_pols.append(pol)

        for pol in drive_pols:
            self.specials += DDROutput(
                i1={"p": 1, "n": 0}[pol],
                i2={"p": 0, "n": 1}[pol],
                o=getattr(tmds, f"clk_{pol}"),
                clk=ClockSignal("tmds"),
            )

        for pol in drive_pols:
            for i, port in enumerate([self.tmds_0, self.tmds_1, self.tmds_2]):
                # 10:2 Gearbox.
                # data_in = Endpoint([("data", 10)])
                # data_in.ready.eq(gb.sink.ready)
                gearbox = ClockDomainsRenamer("tmds5x")(stream.Gearbox(i_dw=10, o_dw=2, msb_first=False))
                self.comb += gearbox.sink.data.eq(port)
                self.comb += gearbox.sink.valid.eq(1)
                self.add_module(f"tmds_{i}_gearbox_{pol}", gearbox)

                # 2:1 Output DDR.
                data_o = getattr(tmds, f"data{i}_{pol}")
                self.comb += gearbox.source.ready.eq(1)
                self.specials += DDROutput(
                    clk=ClockSignal("tmds5x"),
                    i1=gearbox.source.data[0],
                    i2=gearbox.source.data[1],
                    o=data_o,
                )

        # Block device shared memory ---------------------------------------------------------------
        drive_shmem_size = 8192
        drive_shmem_bus = wishbone.Interface(
            data_width=self.bus.data_width, address_width=self.bus.address_width, bursting=self.bus.bursting
        )
        self.drive_shmem = wishbone.SRAM(drive_shmem_size, bus=drive_shmem_bus, name="drive_shmem")
        self.bus.add_slave(
            name="drive_shmem",
            slave=self.drive_shmem.bus,
            region=SoCRegion(origin=self.mem_map["drive_shmem"], size=drive_shmem_size, mode="rw"),
        )
        self.drive_shmem_port = self.drive_shmem.mem.get_port(
            has_re=False, write_capable=True, we_granularity=8, mode=WRITE_FIRST
        )

        # 1541 drive ROM ---------------------------------------------------------------------------
        drive_rom_size = 16384
        drive_rom_bus = wishbone.Interface(
            data_width=self.bus.data_width, address_width=self.bus.address_width, bursting=self.bus.bursting
        )
        self.drive_rom = wishbone.SRAM(drive_rom_size, bus=drive_rom_bus, name="drive_rom")
        self.bus.add_slave(
            name="drive_rom",
            slave=self.drive_rom.bus,
            region=SoCRegion(origin=self.mem_map["drive_rom"], size=drive_rom_size, mode="rw"),
        )
        self.drive_rom_port = self.drive_rom.mem.get_port(
            has_re=False, write_capable=False, mode=WRITE_FIRST
        )  # mode has to be the same as the other port

        # Tape player DMA --------------------------------------------------------------------------
        tap_dma_bus = wishbone.Interface(data_width=self.bus.data_width, address_width=self.bus.address_width, mode="r")
        self.bus.add_master(master=tap_dma_bus, name="tap_dma")
        self.tap_dma = tap_dma = WishboneDMAReader(bus=tap_dma_bus, with_csr=True)

        # C64 Top ----------------------------------------------------------------------------------
        self.c64_top = C64Top(
            platform,
            sdram_port=self.tiny_sdram.p0,  # p0 has priority over p1
            drive_shmem=self.drive_shmem_port,
            drive_rom=self.drive_rom_port,
            leds=platform.request_all("user_led"),
            tmds_0=self.tmds_0,
            tmds_1=self.tmds_1,
            tmds_2=self.tmds_2,
            usb_0=platform.request("usb", 1),  # swap USB inputs
            usb_1=platform.request("usb", 0),
            iec=platform.request("iec", 0),
            sys_clk_freq=sys_clk_freq,
            clk_domain="sys",
            tmds_clk_freq=tmds_clk_freq,
            tmds_clk_domain="tmds",
            usb_clk_domain="usb",
        )

        self.tap_converter = tap_converter = stream.Converter(self.bus.data_width, 8, reverse=True)
        self.tap_fifo = tap_fifo = stream.SyncFIFO([("data", 8)], 32, buffered=True)
        self.comb += [
            tap_dma.source.connect(tap_converter.sink),
            tap_converter.source.connect(tap_fifo.sink),
            tap_fifo.source.connect(self.c64_top.tap_sink),
        ]

        self.c64_control = self.c64_top.control
        self.irq.add("c64_control", use_loc_if_exists=True)

        # Video Terminal ---------------------------------------------------------------------------
        # margin = 2
        # hstart=132 + margin (margin), vstart = 16 + margin (margin); adjust hres and vres accordingly
        self.video_terminal = vt = ClockDomainsRenamer("tmds")(
            VideoTerminalOverlay(hstart=134, vstart=18, hres=716, vres=572)
        )

        self.video_terminal_uart_cdc = uart_cdc = stream.ClockDomainCrossing([("data", 8)], cd_from="sys", cd_to="tmds")
        self.comb += [
            uart_cdc.sink.valid.eq(self.uart.tx_fifo.source.valid & self.uart.tx_fifo.source.ready),
            uart_cdc.sink.data.eq(self.uart.tx_fifo.source.data),
            uart_cdc.source.connect(vt.uart_sink),
        ]
        self.comb += [
            self.c64_top.video_overlay.rgb.eq(vt.video_overlay.rgb),
            self.c64_top.video_overlay.valid.eq(1),
            vt.video_overlay.x.eq(self.c64_top.video_overlay.x),
            vt.video_overlay.y.eq(self.c64_top.video_overlay.y),
        ]


# Build --------------------------------------------------------------------------------------------


def main():
    from litex.build.parser import LiteXArgumentParser

    parser = LiteXArgumentParser(platform=icepi_zero.Platform, description="LiteX SoC on Icepi Zero.")
    parser.add_target_argument("--device", default="LFE5U-25F", help="FPGA device (LFE5U-25F).")
    parser.add_target_argument("--sdram-rate", default="1:3", help="SDRAM Rate (1:1 or 1:3).")
    parser.add_target_argument("--with-spi-flash", action="store_true", help="Enable memory-mapped SPI flash.")
    parser.add_target_argument("--sys-clk-freq", default=SYS_CLK_FREQUENCY, type=float, help="System clock frequency.")

    parser.set_defaults(
        sys_clk_freq=SYS_CLK_FREQUENCY,
        integrated_main_ram_size=0,
        integrated_rom_size=0,
        integrated_sram_size=8192,
        l2_size=0,
        bios_lto=True,
        with_spi_flash=True,
        cpu_variant="lite",
        timer_uptime=True,
        libc_mode="minimal",
        yosys_flow3=True,
        yosys_abc9=True,
    )
    args = parser.parse_args()

    soc = BaseSoC(
        device=args.device,
        toolchain=args.toolchain,
        sys_clk_freq=args.sys_clk_freq,
        sdram_rate=args.sdram_rate,
        with_spi_flash=args.with_spi_flash,
        **parser.soc_argdict,
    )

    soc.add_spi_sdcard()

    builder = Builder(soc, **parser.builder_argdict)
    if args.build:
        soc.platform.toolchain._yosys_cmds.append("stat -hierarchy")
        builder.build(**parser.toolchain_argdict)

    if args.load:
        prog = soc.platform.create_programmer()
        prog.load_bitstream(builder.get_bitstream_filename(mode="sram", ext=".bit"))


if __name__ == "__main__":
    main()
